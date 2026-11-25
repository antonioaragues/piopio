/**
 * A conversation's pull request (docs/spec/05-build G6–G8, 17 §5): drafting it, opening it from the conversation's
 * branch, its status, handing its comments or failing checks to the conversation, and the events Piopio polls for.
 *
 * A Build conversation owns at most one pull request, kept on its catalog entry (`pr`, with `prSeen` and
 * `prFailedSha` for what it was already told). Everything this needs from the conversations comes through
 * `PullRequestHost`, which Sessions implements: this file changes entries and asks the host to save them.
 */
import type { ContainerRef } from "@piopio/protocol";
import type { GitHub, PrStatus } from "../github.js";
import { git as runGit, status as gitStatus } from "../git.js";
import { EngineError } from "../models.js";
import type { Runtime } from "../runtimes/runtime.js";
import type { CatalogEntry } from "./catalog-entry.js";

export interface PullRequestHost {
	entry(ref: ContainerRef): CatalogEntry;
	entries(): Iterable<CatalogEntry>;
	runtime(ref: ContainerRef): Promise<Runtime>;
	/** The entry changed: write the catalog, and tell clients (`changed`). */
	save(): void;
	changed(entry: CatalogEntry): void;
	/** A message went in as yours, and the conversation was active now. */
	youWrote(ref: ContainerRef): void;
	touch(ref: ContainerRef): void;
	/** The utility model's answer, charged to `scope`; undefined when there's none. */
	utility(system: string, prompt: string, scope: string): Promise<string | undefined>;
	github(): GitHub | undefined;
	/** What the conversation's project wants told about its pull request. */
	prEventsFor(path: string): "off" | "tell" | "act";
	notify(entry: CatalogEntry, message: string): void;
}

export class PullRequests {
	constructor(private readonly host: PullRequestHost) {}

	private gh(): GitHub {
		const gh = this.host.github();
		if (!gh) throw new EngineError("INTERNAL", "GitHub isn't set up in this engine.");
		return gh;
	}

	/** The branch a conversation's pull request comes from, and the one it goes into. */
	private async branches(entry: CatalogEntry): Promise<{ cwd: string; head: string; base: string }> {
		if (entry.ref.kind !== "build" || !entry.cwd) throw new EngineError("INVALID", "Only a conversation in a project has a branch to open a pull request from.");
		const cwd = entry.cwd;
		const st = await gitStatus(cwd);
		if (!st.repo) throw new EngineError("INVALID", "This project isn't a git repository.");
		const head = entry.worktree?.branch ?? st.branch;
		if (!head) throw new EngineError("INVALID", "Check out a branch first.");
		let base = entry.worktree?.base;
		if (!base) base = (await runGit(cwd, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).catch(() => "")).trim().replace(/^origin\//, "") || "main";
		if (head === base) throw new EngineError("INVALID", `This conversation works on ${base} itself. Start it on a branch or in a worktree to open a pull request.`);
		return { cwd, head, base };
	}

	/** A title and body for the pull request: the utility model's, from the commits and diff, else from the conversation. */
	async draft(ref: ContainerRef): Promise<{ title: string; body: string; head: string; base: string }> {
		const entry = this.host.entry(ref);
		const { cwd, head, base } = await this.branches(entry);
		const commits = (await runGit(cwd, ["log", "--format=- %s", `${base}..${head}`]).catch(() => "")).trim();
		const stat = (await runGit(cwd, ["diff", "--stat", `${base}...${head}`]).catch(() => "")).trim();
		const diff = (await runGit(cwd, ["diff", `${base}...${head}`]).catch(() => "")).slice(0, 20_000);
		const asked = [...(await this.host.runtime(ref)).snapshot().items].filter((i) => i.kind === "user").map((i) => (i.kind === "user" ? i.text : "")).slice(0, 3).join("\n\n").slice(0, 3000);
		const reply = await this.host
			.utility(
				"You write a GitHub pull request for a change. Answer with JSON only: {\"title\": \"...\", \"body\": \"...\"}. The title: under 70 characters, imperative, no trailing period. The body: what changed and why in a few short paragraphs or a short list, then how it was checked if the commits or the request say so. Plain Markdown, no headings for a small change.",
				`What was asked:\n${asked}\n\nCommits:\n${commits}\n\nFiles:\n${stat}\n\nDiff:\n${diff}`,
				ref.id,
			)
			.catch(() => undefined);
		try {
			const json = reply ? (JSON.parse(/\{[\s\S]*\}/.exec(reply)?.[0] ?? "") as { title?: string; body?: string }) : undefined;
			if (json?.title?.trim()) return { title: json.title.trim().slice(0, 120), body: json.body?.trim() ?? "", head, base };
		} catch {
			// The plain draft below.
		}
		return { title: entry.title.slice(0, 120), body: [commits, stat ? `\n\`\`\`\n${stat}\n\`\`\`` : ""].filter(Boolean).join("\n"), head, base };
	}

	/** Pushes the conversation's branch and opens its pull request; the conversation owns it from then on (G6). */
	async create(ref: ContainerRef, input: { title: string; body: string; base?: string; draft?: boolean }): Promise<PrStatus> {
		const entry = this.host.entry(ref);
		const branches = await this.branches(entry);
		if ((await gitStatus(branches.cwd)).files.length) throw new EngineError("INVALID", "Commit its changes first: a pull request takes only what's committed.");
		const pr = await this.gh().createPullRequest(branches.cwd, { head: branches.head, base: input.base?.trim() || branches.base, title: input.title.trim(), body: input.body, ...(input.draft ? { draft: true } : {}) });
		entry.pr = { repo: pr.repo, number: pr.number, url: pr.url, title: pr.title, head: pr.head, base: pr.base, state: pr.state };
		entry.prSeen = [];
		this.host.save();
		this.host.changed(entry);
		return this.status(ref);
	}

	/** Its pull request now (G7); the conversation's summary follows. */
	async status(ref: ContainerRef): Promise<PrStatus> {
		const entry = this.host.entry(ref);
		if (!entry.pr) throw new EngineError("NOT_FOUND", "This conversation has no pull request.");
		const status = await this.gh().pullRequest(entry.pr.repo, entry.pr.number);
		const next = { ...entry.pr, title: status.title, state: status.state, checks: status.summary };
		if (JSON.stringify(next) !== JSON.stringify(entry.pr)) {
			entry.pr = next;
			this.host.save();
			this.host.changed(entry);
		}
		return status;
	}

	private static comments(status: PrStatus, only?: (c: PrStatus["comments"][number]) => boolean): string {
		return status.comments
			.filter((c) => !c.bot && (!only || only(c)))
			.map((c) => `- ${c.author}${c.path ? ` on ${c.path}${c.line ? `:${c.line}` : ""}` : ""}: ${c.body.trim().replace(/\n+/g, " ")}`)
			.join("\n");
	}

	private async logs(status: PrStatus): Promise<string> {
		const logs = await this.gh().failingLogs(status);
		return logs.map((l) => `${l.name}:\n\`\`\`\n${l.log}\n\`\`\``).join("\n\n");
	}

	/** Address comments (G7) or Fix CI (G8): what's on the PR, handed to the conversation as your request. */
	async address(ref: ContainerRef, what: "comments" | "ci"): Promise<void> {
		const entry = this.host.entry(ref);
		const status = await this.status(ref);
		const push = `When you're done, commit and push to ${status.head} so the pull request updates.`;
		let text: string;
		if (what === "comments") {
			const comments = PullRequests.comments(status);
			if (!comments) throw new EngineError("INVALID", "There are no review comments to address.");
			text = `Address the review comments on pull request #${status.number} (${status.url}):\n${comments}\n\nChange what they ask for, or say here why not. ${push}`;
		} else {
			const logs = await this.logs(status);
			if (!logs) throw new EngineError("INVALID", "No check is failing.");
			text = `The checks on pull request #${status.number} failed. The end of each failing job's log:\n\n${logs}\n\nFind the cause, fix it and run the check here if you can. ${push}`;
		}
		entry.prSeen = [...new Set([...(entry.prSeen ?? []), ...status.comments.map((c) => c.id)])];
		this.host.youWrote(ref);
		await (await this.host.runtime(ref)).submit(text, { whenBusy: "followUp" });
		this.host.touch(ref);
	}

	/**
	 * PR events go to the conversation that owns the PR (docs/spec/17 §5): new review comments (not bots'), checks that
	 * started failing on a new head, merged or closed. The project decides: off (the panel only), tell (a
	 * notification) or act (a `[PR]` follow-up the conversation works on).
	 */
	async poll(): Promise<void> {
		if (!this.host.github()) return;
		for (const entry of [...this.host.entries()]) {
			if (!entry.pr || entry.pr.state !== "open") continue;
			const before = entry.pr.state;
			const status = await this.status(entry.ref).catch(() => undefined);
			if (!status) continue;
			const mode = this.host.prEventsFor(entry.projectPath ?? entry.cwd ?? "");
			const seen = new Set(entry.prSeen ?? []);
			const fresh = status.comments.filter((c) => !c.bot && !seen.has(c.id));
			const failing = status.summary === "failing" && entry.prFailedSha !== status.headSha;
			entry.prSeen = status.comments.map((c) => c.id);
			if (failing) entry.prFailedSha = status.headSha;
			this.host.save();
			const events: string[] = [];
			const tell: string[] = [];
			if (fresh.length) {
				events.push(`[PR] New review comments on #${status.number}:\n${PullRequests.comments(status, (c) => fresh.includes(c))}\n\nAddress them (or say why not), then commit and push to ${status.head}.`);
				tell.push(`${fresh.length} new comment${fresh.length === 1 ? "" : "s"} on #${status.number}`);
			}
			if (failing) {
				events.push(`[PR] The checks failed on #${status.number}:\n\n${await this.logs(status).catch(() => "")}\n\nFix it, then commit and push to ${status.head}.`);
				tell.push(`checks failed on #${status.number}`);
			}
			if (status.state !== before) {
				events.push(`[PR] Pull request #${status.number} was ${status.state}.`);
				tell.push(`#${status.number} was ${status.state}`);
			}
			if (!events.length || mode === "off") continue;
			if (mode === "tell") {
				this.host.notify(entry, tell.join("; "));
				continue;
			}
			await (await this.host.runtime(entry.ref)).submit(events.join("\n\n"), { whenBusy: "followUp" }).catch(() => undefined);
			this.host.touch(entry.ref);
		}
	}
}
