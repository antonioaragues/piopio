/**
 * GitHub (docs/spec/05-build §8, G4–G8): who you are on GitHub, cloning, pull requests and what happens on them.
 *
 * - **G4 Auth:** `gh auth token` when the GitHub CLI is installed and signed in; else a token you paste, kept in the
 *   app's Keychain (`github.token`). The OAuth device flow waits for Piopio's own OAuth App (only the owner can
 *   register it).
 * - **G5 Clone** a repository of yours, or any URL.
 * - **G6 Create PR** from a branch: pushed with your token, then opened through the API.
 * - **G7** A PR's state, checks, reviews and comments. **G8** The failing checks' logs (GitHub Actions jobs).
 *
 * The API and the token can be pointed elsewhere for tests (`api`, `token`).
 */
import { spawn } from "node:child_process";
import { EngineError } from "./models.js";
import { git } from "./git.js";

export const SECRET_GITHUB = "github.token";

export type GitHubOptions = { api?: string; token?: string; gh?: boolean };

export type Repo = { owner: string; name: string };
export type RepoInfo = { fullName: string; description?: string; private: boolean; cloneUrl: string; updatedAt: string; defaultBranch: string };

export type PullRequest = { repo: string; number: number; url: string; title: string; state: "open" | "closed" | "merged"; draft: boolean; head: string; base: string; headSha: string };
export type Check = { name: string; status: "queued" | "in_progress" | "completed"; conclusion?: string; url?: string; jobId?: number };
export type PrComment = { id: string; author: string; bot: boolean; body: string; at: string; url?: string; path?: string; line?: number; kind: "review" | "comment" | "verdict" };
export type PrStatus = PullRequest & { checks: Check[]; summary: "pending" | "passing" | "failing" | "none"; comments: PrComment[] };

type Secrets = { get(name: string, purpose: string): Promise<string | null>; set(name: string, value: string): Promise<void>; delete(name: string): Promise<void> };

/** owner/name from a GitHub remote URL (https or ssh), or undefined. */
export function parseRepo(url: string): Repo | undefined {
	const m = /github\.com[:/]([^/]+)\/([^/]+?)(?:\.git)?\/?$/.exec(url.trim());
	return m ? { owner: m[1]!, name: m[2]! } : undefined;
}

function run(command: string, args: string[], timeoutMs = 5000): Promise<string | undefined> {
	return new Promise((resolve) => {
		const child = spawn(command, args, { env: { ...process.env, GH_PROMPT_DISABLED: "1" } });
		let out = "";
		const timer = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
		child.stdout.setEncoding("utf8").on("data", (d: string) => (out += d));
		child.on("error", () => (clearTimeout(timer), resolve(undefined)));
		child.on("close", (code) => (clearTimeout(timer), resolve(code === 0 ? out.trim() : undefined)));
	});
}

export class GitHub {
	private readonly api: string;

	constructor(
		private readonly secrets: Secrets,
		private readonly options: GitHubOptions = {},
	) {
		this.api = (options.api ?? "https://api.github.com").replace(/\/$/, "");
	}

	/** The token to use, and where it came from. */
	async token(): Promise<{ token: string; via: "gh" | "token" } | undefined> {
		if (this.options.token) return { token: this.options.token, via: "token" };
		if (this.options.gh !== false) {
			const fromGh = await run("gh", ["auth", "token"]);
			if (fromGh) return { token: fromGh, via: "gh" };
		}
		const saved = await this.secrets.get(SECRET_GITHUB, "Pull requests and checks on GitHub").catch(() => null);
		return saved ? { token: saved, via: "token" } : undefined;
	}

	private async request<T>(path: string, init: { method?: string; body?: unknown; text?: boolean } = {}): Promise<T> {
		const auth = await this.token();
		if (!auth) throw new EngineError("AUTH", "Not signed in to GitHub: sign in with `gh auth login`, or add a token in Settings › Git & GitHub.");
		const res = await fetch(`${this.api}${path}`, {
			method: init.method ?? "GET",
			headers: { Authorization: `Bearer ${auth.token}`, Accept: init.text ? "application/vnd.github.v3.raw" : "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Piopio", ...(init.body ? { "Content-Type": "application/json" } : {}) },
			...(init.body ? { body: JSON.stringify(init.body) } : {}),
			redirect: "follow",
		});
		if (!res.ok) {
			const detail = await res.text().catch(() => "");
			const message = (() => {
				try {
					const j = JSON.parse(detail) as { message?: string; errors?: { message?: string }[] };
					return [j.message, ...(j.errors ?? []).map((e) => e.message)].filter(Boolean).join(": ");
				} catch {
					return detail.slice(0, 200);
				}
			})();
			throw new EngineError(res.status === 401 ? "AUTH" : res.status === 404 ? "NOT_FOUND" : "INVALID", `GitHub said ${res.status}${message ? `: ${message}` : ""}`);
		}
		return (init.text ? await res.text() : await res.json()) as T;
	}

	// ── G4 ──

	/** Signed in or not, how, and as whom. */
	async status(): Promise<{ connected: boolean; via?: "gh" | "token"; login?: string; error?: string }> {
		const auth = await this.token();
		if (!auth) return { connected: false };
		try {
			const me = await this.request<{ login: string }>("/user");
			return { connected: true, via: auth.via, login: me.login };
		} catch (error) {
			return { connected: false, via: auth.via, error: (error as Error).message };
		}
	}

	/** A token you paste: checked, then kept in the Keychain. */
	async setToken(token: string): Promise<string> {
		const res = await fetch(`${this.api}/user`, { headers: { Authorization: `Bearer ${token.trim()}`, Accept: "application/vnd.github+json", "User-Agent": "Piopio" } });
		if (!res.ok) throw new EngineError("AUTH", "GitHub didn't accept that token.");
		const me = (await res.json()) as { login: string };
		await this.secrets.set(SECRET_GITHUB, token.trim());
		return me.login;
	}

	async signOut(): Promise<void> {
		await this.secrets.delete(SECRET_GITHUB);
	}

	/** git with your token on github.com URLs, so pushing and cloning private repos work without a credential helper. */
	async git(cwd: string, args: string[], timeoutMs = 120_000): Promise<string> {
		const auth = await this.token();
		const header = auth ? ["-c", `http.https://github.com/.extraheader=AUTHORIZATION: basic ${Buffer.from(`x-access-token:${auth.token}`).toString("base64")}`] : [];
		return git(cwd, [...header, ...args], { timeoutMs });
	}

	// ── G5 ──

	async repos(): Promise<RepoInfo[]> {
		const list = await this.request<{ full_name: string; description: string | null; private: boolean; clone_url: string; updated_at: string; default_branch: string }[]>("/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member");
		return list.map((r) => ({ fullName: r.full_name, ...(r.description ? { description: r.description } : {}), private: r.private, cloneUrl: r.clone_url, updatedAt: r.updated_at, defaultBranch: r.default_branch }));
	}

	/** Clones into `dest` (which must not exist). `source` is owner/name or a URL. */
	async clone(source: string, dest: string): Promise<void> {
		const url = /^[\w.-]+\/[\w.-]+$/.test(source.trim()) ? `https://github.com/${source.trim()}.git` : source.trim();
		const parent = dest.split("/").slice(0, -1).join("/") || "/";
		await this.git(parent, ["clone", "--quiet", url, dest], 600_000);
	}

	// ── G6 ──

	/** The GitHub repository a folder's `origin` points to. */
	async repoOf(cwd: string): Promise<Repo> {
		const url = (await git(cwd, ["config", "--get", "remote.origin.url"]).catch(() => "")).trim();
		const repo = parseRepo(url);
		if (!repo) throw new EngineError("INVALID", url ? "Its origin isn't a GitHub repository." : "This repository has no origin on GitHub.");
		return repo;
	}

	/** Pushes `head` to origin, then opens the pull request into `base`. */
	async createPullRequest(cwd: string, input: { head: string; base: string; title: string; body: string; draft?: boolean }): Promise<PullRequest> {
		const repo = await this.repoOf(cwd);
		await this.git(cwd, ["push", "--quiet", "-u", "origin", `${input.head}:${input.head}`]);
		const pr = await this.request<RawPr>(`/repos/${repo.owner}/${repo.name}/pulls`, { method: "POST", body: { title: input.title, body: input.body, head: input.head, base: input.base, draft: input.draft ?? false } });
		return toPr(`${repo.owner}/${repo.name}`, pr);
	}

	// ── G7 ──

	async pullRequest(repo: string, number: number): Promise<PrStatus> {
		const pr = toPr(repo, await this.request<RawPr>(`/repos/${repo}/pulls/${number}`));
		const [runs, statuses, reviewComments, reviews, issueComments] = await Promise.all([
			this.request<{ check_runs: { name: string; status: Check["status"]; conclusion: string | null; html_url?: string; details_url?: string; id: number }[] }>(`/repos/${repo}/commits/${pr.headSha}/check-runs?per_page=100`).catch(() => ({ check_runs: [] })),
			this.request<{ statuses: { context: string; state: string; target_url?: string }[] }>(`/repos/${repo}/commits/${pr.headSha}/status`).catch(() => ({ statuses: [] })),
			this.request<RawComment[]>(`/repos/${repo}/pulls/${number}/comments?per_page=100`).catch(() => []),
			this.request<{ id: number; user: RawUser; body: string; state: string; submitted_at?: string; html_url?: string }[]>(`/repos/${repo}/pulls/${number}/reviews?per_page=100`).catch(() => []),
			this.request<RawComment[]>(`/repos/${repo}/issues/${number}/comments?per_page=100`).catch(() => []),
		]);
		const checks: Check[] = [
			...runs.check_runs.map((c) => {
				const job = /\/job\/(\d+)/.exec(c.details_url ?? c.html_url ?? "")?.[1];
				return { name: c.name, status: c.status, ...(c.conclusion ? { conclusion: c.conclusion } : {}), ...(c.html_url ?? c.details_url ? { url: c.html_url ?? c.details_url } : {}), ...(job ? { jobId: Number(job) } : {}) };
			}),
			...statuses.statuses.map((s) => ({ name: s.context, status: s.state === "pending" ? ("in_progress" as const) : ("completed" as const), ...(s.state !== "pending" ? { conclusion: s.state === "success" ? "success" : "failure" } : {}), ...(s.target_url ? { url: s.target_url } : {}) })),
		];
		const failing = checks.some((c) => c.status === "completed" && c.conclusion && !["success", "neutral", "skipped"].includes(c.conclusion));
		const summary = !checks.length ? "none" : failing ? "failing" : checks.some((c) => c.status !== "completed") ? "pending" : "passing";
		const comments: PrComment[] = [
			...reviewComments.map((c) => ({ id: `rc${c.id}`, author: c.user.login, bot: c.user.type === "Bot", body: c.body, at: c.created_at, ...(c.html_url ? { url: c.html_url } : {}), ...(c.path ? { path: c.path } : {}), ...(c.line ?? c.original_line ? { line: (c.line ?? c.original_line)! } : {}), kind: "review" as const })),
			...reviews.filter((r) => r.body?.trim() || r.state === "CHANGES_REQUESTED").map((r) => ({ id: `rv${r.id}`, author: r.user.login, bot: r.user.type === "Bot", body: r.body?.trim() || (r.state === "CHANGES_REQUESTED" ? "Requested changes." : ""), at: r.submitted_at ?? "", ...(r.html_url ? { url: r.html_url } : {}), kind: "verdict" as const })),
			...issueComments.map((c) => ({ id: `ic${c.id}`, author: c.user.login, bot: c.user.type === "Bot", body: c.body, at: c.created_at, ...(c.html_url ? { url: c.html_url } : {}), kind: "comment" as const })),
		].sort((a, b) => a.at.localeCompare(b.at));
		return { ...pr, checks, summary, comments };
	}

	// ── G8 ──

	/** The end of each failing GitHub Actions job's log, to hand to the conversation. */
	async failingLogs(status: PrStatus, lines = 150): Promise<{ name: string; log: string }[]> {
		const failed = status.checks.filter((c) => c.status === "completed" && c.conclusion && !["success", "neutral", "skipped"].includes(c.conclusion));
		return Promise.all(
			failed.map(async (c) => {
				if (!c.jobId) return { name: c.name, log: `(No log: it isn't a GitHub Actions job.${c.url ? ` See ${c.url}` : ""})` };
				const text = await this.request<string>(`/repos/${status.repo}/actions/jobs/${c.jobId}/logs`, { text: true }).catch((error: unknown) => `(Couldn't read its log: ${(error as Error).message})`);
				return { name: c.name, log: text.split("\n").slice(-lines).join("\n") };
			}),
		);
	}
}

type RawUser = { login: string; type?: string };
type RawComment = { id: number; user: RawUser; body: string; created_at: string; html_url?: string; path?: string; line?: number | null; original_line?: number | null };
type RawPr = { number: number; html_url: string; title: string; state: "open" | "closed"; merged?: boolean; merged_at?: string | null; draft?: boolean; head: { ref: string; sha: string }; base: { ref: string } };

function toPr(repo: string, pr: RawPr): PullRequest {
	return { repo, number: pr.number, url: pr.html_url, title: pr.title, state: pr.merged || pr.merged_at ? "merged" : pr.state, draft: pr.draft ?? false, head: pr.head.ref, base: pr.base.ref, headSha: pr.head.sha };
}
