import { execFileSync } from "node:child_process";
import { createServer, type Server } from "node:http";
import { existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// GitHub (docs/spec/05-build G4–G8, 17 §5) against a fake API, with a bare repository standing in for github.com.

type Ref = { kind: string; id: string };
const open: { engine: Engine; client: TestClient; api: Server }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
		o.api.close();
	}
});

async function until<T>(get: () => Promise<T> | T, ok: (v: T) => boolean, ms = 20_000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 1500)}`);
		await new Promise((r) => setTimeout(r, 80));
	}
}

const sh = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, env: { ...process.env, GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@t" } }).toString();

/** The fake GitHub: what it was asked, and what it answers (changed by each test). */
function fakeGitHub() {
	const state = {
		pulls: [] as { title: string; body: string; head: string; base: string; draft: boolean }[],
		prState: "open" as "open" | "closed",
		merged: false,
		checks: [] as { name: string; status: string; conclusion: string | null; details_url?: string; html_url?: string; id: number }[],
		comments: [] as { id: number; user: { login: string; type?: string }; body: string; created_at: string; path?: string; line?: number }[],
		auth: [] as string[],
	};
	const pr = () => ({ number: 1, html_url: "https://github.com/acme/shop/pull/1", title: state.pulls[0]?.title ?? "", state: state.prState, merged: state.merged, draft: state.pulls[0]?.draft ?? false, head: { ref: state.pulls[0]?.head ?? "feature", sha: "abc123" }, base: { ref: state.pulls[0]?.base ?? "main" } });
	const server = createServer((req, res) => {
		state.auth.push(req.headers.authorization ?? "");
		let raw = "";
		req.on("data", (d) => (raw += d));
		req.on("end", () => {
			const send = (body: unknown, code = 200) => {
				res.writeHead(code, { "Content-Type": typeof body === "string" ? "text/plain" : "application/json" });
				res.end(typeof body === "string" ? body : JSON.stringify(body));
			};
			const url = req.url ?? "";
			if (url === "/user") return send({ login: "octo" });
			if (url.startsWith("/user/repos")) return send([{ full_name: "acme/shop", description: "The shop", private: true, clone_url: "https://github.com/acme/shop.git", updated_at: "2026-11-17T10:00:00Z", default_branch: "main" }]);
			if (req.method === "POST" && url === "/repos/acme/shop/pulls") {
				state.pulls.push(JSON.parse(raw));
				return send(pr(), 201);
			}
			if (url === "/repos/acme/shop/pulls/1") return send(pr());
			if (url.startsWith("/repos/acme/shop/commits/abc123/check-runs")) return send({ check_runs: state.checks });
			if (url.startsWith("/repos/acme/shop/commits/abc123/status")) return send({ statuses: [] });
			if (url.startsWith("/repos/acme/shop/pulls/1/comments")) return send(state.comments);
			if (url.startsWith("/repos/acme/shop/pulls/1/reviews")) return send([]);
			if (url.startsWith("/repos/acme/shop/issues/1/comments")) return send([]);
			if (url === "/repos/acme/shop/actions/jobs/42/logs") return send("setup\nrun tests\nFAIL test/cart.test.ts\n  expected 3, got 2\n");
			send({ message: "Not Found" }, 404);
		});
	});
	return { server, state };
}

async function start(pollMs = 60_000) {
	const { server, state } = fakeGitHub();
	await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
	const port = (server.address() as { port: number }).port;
	const home = mkdtempSync(join(tmpdir(), "piopio-gh-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), teamsDir: join(home, "Teams"), hooksPort: 0, github: { api: `http://127.0.0.1:${port}`, token: "t0ken", gh: false, pollMs }, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client, api: server });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	// A project whose origin is github.com/acme/shop, which git sends to a bare repository here.
	const bare = realpathSync(mkdtempSync(join(tmpdir(), "piopio-gh-bare-")));
	sh(bare, "init", "-q", "--bare", "-b", "main");
	const dir = realpathSync(mkdtempSync(join(tmpdir(), "piopio-gh-repo-")));
	sh(dir, "init", "-q", "-b", "main");
	writeFileSync(join(dir, "README.md"), "# Shop\n");
	sh(dir, "add", "-A");
	sh(dir, "commit", "-qm", "init");
	sh(dir, "remote", "add", "origin", "https://github.com/acme/shop.git");
	sh(dir, "config", `url.${bare}.insteadOf`, "https://github.com/acme/shop.git");
	sh(dir, "push", "-q", "origin", "main");
	const { project } = (await client.call("projects.add", { path: dir })) as { project: { id: string } };
	return { client, state, dir, bare, project: project.id, home };
}

/** A conversation on a branch with one commit on it. */
async function onBranch(client: TestClient, dir: string) {
	const { ref } = (await client.call("sessions.create", { kind: "build", cwd: dir, approvalMode: "full_auto", workOn: { kind: "branch", branch: "feature" } })) as { ref: Ref };
	writeFileSync(join(dir, "cart.ts"), "export const total = 3;\n");
	sh(dir, "add", "-A");
	sh(dir, "commit", "-qm", "Add the cart total");
	return ref;
}

test("G4: signed in with a token; G6: a conversation's branch is pushed and its pull request opened, linked to it", async () => {
	const { client, state, dir, bare } = await start();
	expect(await client.call("github.status", {})).toEqual({ connected: true, via: "token", login: "octo" });
	const ref = await onBranch(client, dir);
	const draft = (await client.call("sessions.pr.draft", { ref })) as { title: string; body: string; head: string; base: string };
	expect(draft).toMatchObject({ head: "feature", base: "main" });
	expect(draft.body).toContain("Add the cart total");
	// Uncommitted work is refused: a PR takes only what's committed.
	writeFileSync(join(dir, "wip.txt"), "x");
	await expect(client.call("sessions.pr.create", { ref, title: "Cart total", body: draft.body })).rejects.toThrow(/Commit its changes first/);
	execFileSync("rm", [join(dir, "wip.txt")]);
	const { pr } = (await client.call("sessions.pr.create", { ref, title: "Cart total", body: draft.body, draft: true })) as { pr: { number: number; state: string; summary: string } };
	expect(pr).toMatchObject({ number: 1, state: "open", summary: "none" });
	expect(state.pulls).toEqual([{ title: "Cart total", body: draft.body, head: "feature", base: "main", draft: true }]);
	expect(sh(bare, "branch", "--list", "feature")).toContain("feature");
	expect(state.auth.every((a) => a === "Bearer t0ken")).toBe(true);
	const s = ((await client.call("sessions.list", { kind: "build" })).sessions as { ref: Ref; pr?: unknown }[]).find((x) => x.ref.id === ref.id);
	expect(s?.pr).toMatchObject({ repo: "acme/shop", number: 1, head: "feature", base: "main", state: "open" });
	// A conversation working on main itself can't open one.
	const { ref: onMain } = (await client.call("sessions.create", { kind: "build", cwd: dir, approvalMode: "full_auto" })) as { ref: Ref };
	sh(dir, "checkout", "-q", "main");
	await expect(client.call("sessions.pr.draft", { ref: onMain })).rejects.toThrow(/works on main itself/);
}, 30_000);

test("G7–G8: checks and review comments; Address comments and Fix CI hand them to the conversation", async () => {
	const { client, state, dir } = await start();
	const ref = await onBranch(client, dir);
	await client.call("sessions.pr.create", { ref, title: "Cart total", body: "" });
	state.checks = [{ name: "test", status: "completed", conclusion: "failure", details_url: "https://github.com/acme/shop/actions/runs/7/job/42", id: 9 }];
	state.comments = [
		{ id: 5, user: { login: "rita" }, body: "Use a constant for 3.", created_at: "2026-11-17T10:00:00Z", path: "cart.ts", line: 1 },
		{ id: 6, user: { login: "ci-bot", type: "Bot" }, body: "Coverage dropped.", created_at: "2026-11-17T10:01:00Z" },
	];
	const { pr } = (await client.call("sessions.pr.get", { ref })) as { pr: { summary: string; checks: { name: string; jobId?: number }[]; comments: { author: string; bot: boolean; path?: string }[] } };
	expect(pr.summary).toBe("failing");
	expect(pr.checks).toEqual([expect.objectContaining({ name: "test", jobId: 42 })]);
	expect(pr.comments.map((c) => [c.author, c.bot, c.path])).toEqual([["rita", false, "cart.ts"], ["ci-bot", true, undefined]]);
	await client.call("sessions.pr.address", { ref, what: "ci" });
	await client.call("sessions.pr.address", { ref, what: "comments" });
	const users = await until(async () => ((await client.call("sessions.open", { ref })).items as { kind: string; text?: string }[]).filter((i) => i.kind === "user").map((i) => i.text!), (u) => u.length >= 2);
	expect(users[0]).toContain("The checks on pull request #1 failed");
	expect(users[0]).toContain("expected 3, got 2");
	expect(users[0]).toContain("commit and push to feature");
	expect(users[1]).toContain("- rita on cart.ts:1: Use a constant for 3.");
	expect(users[1]).not.toContain("Coverage dropped");
}, 30_000);

test("PR events (17 §5): with Act, new comments, failing checks and the merge reach the conversation as [PR] messages; with Tell, a notification", async () => {
	const { client, state, dir, project } = await start(300);
	await client.call("projects.configure", { id: project, prEvents: "act" });
	const ref = await onBranch(client, dir);
	await client.call("sessions.pr.create", { ref, title: "Cart total", body: "" });
	const texts = async () => ((await client.call("sessions.open", { ref })).items as { kind: string; text?: string }[]).filter((i) => i.kind === "user").map((i) => i.text!);
	state.comments = [{ id: 7, user: { login: "rita" }, body: "Rename total.", created_at: "2026-11-17T10:00:00Z" }];
	state.checks = [{ name: "test", status: "completed", conclusion: "failure", details_url: "https://github.com/acme/shop/actions/runs/7/job/42", id: 9 }];
	const first = await until(texts, (t) => t.some((x) => x.startsWith("[PR]")));
	expect(first.find((x) => x.startsWith("[PR]"))).toMatch(/New review comments on #1:\n- rita: Rename total\.[\s\S]*The checks failed on #1/);
	// Seen once: the next poll doesn't repeat them.
	await new Promise((r) => setTimeout(r, 900));
	expect((await texts()).filter((x) => x.startsWith("[PR]"))).toHaveLength(1);
	state.merged = true;
	state.prState = "closed";
	await until(texts, (t) => t.some((x) => x === "[PR] Pull request #1 was merged."));
	// Tell: a notification, nothing in the conversation.
	await client.call("projects.configure", { id: project, prEvents: "tell" });
	const ref2 = await onBranch2(client, dir);
	state.pulls = [];
	state.merged = false;
	state.prState = "open";
	state.comments = [];
	state.checks = [];
	await client.call("sessions.pr.create", { ref: ref2, title: "More", body: "" });
	state.comments = [{ id: 8, user: { login: "rita" }, body: "Looks good.", created_at: "2026-11-17T11:00:00Z" }];
	await until(() => client.notifications.filter((n) => n.method === "session.attention" && (n.params as { ref: Ref }).ref.id === ref2.id), (n) => n.some((x) => (x.params as { message: string }).message === "1 new comment on #1"));
}, 40_000);

async function onBranch2(client: TestClient, dir: string) {
	sh(dir, "checkout", "-q", "main");
	const { ref } = (await client.call("sessions.create", { kind: "build", cwd: dir, approvalMode: "full_auto", workOn: { kind: "branch", branch: "more" } })) as { ref: Ref };
	writeFileSync(join(dir, "more.ts"), "export const more = 1;\n");
	sh(dir, "add", "-A");
	sh(dir, "commit", "-qm", "More");
	return ref;
}

test("G5: your repositories, and a clone that becomes a project", async () => {
	const { client, bare, home } = await start();
	expect(((await client.call("github.repos", {})) as { repos: { fullName: string; private: boolean }[] }).repos).toEqual([expect.objectContaining({ fullName: "acme/shop", private: true })]);
	const { project } = (await client.call("github.clone", { repo: bare })) as { project: { path: string; name: string } };
	expect(existsSync(join(project.path, "README.md"))).toBe(true);
	expect(project.path.startsWith(join(realpathSync(home), "Piopio"))).toBe(true);
}, 30_000);

test("the token reaches git in a file it includes for one run, never on its command line, and clone takes no options", async () => {
	const { GitHub } = await import("../src/github.js");
	const { checkout } = await import("../src/git.js");
	const home = realpathSync(mkdtempSync(join(tmpdir(), "piopio-gh-home-")));
	const repo = realpathSync(mkdtempSync(join(tmpdir(), "piopio-gh-repo-")));
	execFileSync("git", ["init", "-q"], { cwd: repo });
	const github = new GitHub({ get: async () => null, set: async () => {}, delete: async () => {} } as never, { token: "tok-123", gh: false, home });
	// git hears the header, though no argument carries it.
	const header = await github.git(repo, ["config", "--get-urlmatch", "http.extraheader", "https://github.com/acme/shop"]);
	expect(header.trim()).toBe(`AUTHORIZATION: basic ${Buffer.from("x-access-token:tok-123").toString("base64")}`);
	// The file is gone once git is done.
	expect(execFileSync("ls", ["-A", home], { encoding: "utf8" })).toBe("");
	for (const source of ["--upload-pack=touch /tmp/pwned", "ext::sh -c touch% /tmp/pwned"]) {
		await expect(github.clone(source, join(repo, "copy"))).rejects.toMatchObject({ code: "INVALID" });
	}
	await expect(checkout(repo, "topic", true, "--orphan")).rejects.toMatchObject({ code: "INVALID" });
});
