/**
 * Git for Build (docs/spec/05-build §8, G1–G3, BP5): status, branches, commit, push/pull/fetch and worktrees,
 * run with the user's own git and settings (unlike checkpoints). Never prompts: credentials come from the
 * user's helpers (Keychain, gh), and a missing one is reported as an error.
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname } from "node:path";
import { EngineError } from "./models.js";

export type GitFile = {
	path: string;
	/** For display: what happened to the file, staged or not. */
	status: "added" | "modified" | "deleted" | "renamed" | "conflicted" | "untracked";
	staged: boolean;
	/** Renames: the old path. */
	from?: string;
};
export type GitStatus = { repo: boolean; branch?: string; detached?: boolean; upstream?: string; ahead: number; behind: number; files: GitFile[] };
export type GitBranch = { name: string; upstream?: string; lastCommitAt?: string; current: boolean };

export async function git(cwd: string, args: string[], options: { stdin?: string; timeoutMs?: number } = {}): Promise<string> {
	return new Promise((resolve, reject) => {
		const child = spawn("git", args, {
			cwd,
			env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_ASKPASS: "", SSH_ASKPASS: "", GIT_SSH_COMMAND: process.env.GIT_SSH_COMMAND ?? "ssh -o BatchMode=yes", LC_ALL: "C" },
		});
		let out = "";
		let err = "";
		const timer = setTimeout(() => child.kill("SIGTERM"), options.timeoutMs ?? 60_000);
		child.stdout.setEncoding("utf8").on("data", (d: string) => (out += d));
		child.stderr.setEncoding("utf8").on("data", (d: string) => (err += d));
		child.on("error", (e) => {
			clearTimeout(timer);
			reject(new EngineError("INVALID", `git is not available: ${e.message}`));
		});
		child.on("close", (code) => {
			clearTimeout(timer);
			if (code === 0) resolve(out);
			else reject(new EngineError("INVALID", friendly(args[0] ?? "git", (err || out).trim(), code)));
		});
		child.stdin.end(options.stdin ?? "");
	});
}

/** Branch, upstream, ahead/behind and changed files (porcelain v2). `repo: false` outside a repository. */
export async function status(cwd: string): Promise<GitStatus> {
	let out: string;
	try {
		out = await git(cwd, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]);
	} catch (error) {
		if (String((error as Error).message).includes("not a git repository")) return { repo: false, ahead: 0, behind: 0, files: [] };
		throw error;
	}
	const result: GitStatus = { repo: true, ahead: 0, behind: 0, files: [] };
	const records = out.split("\0");
	for (let i = 0; i < records.length; i++) {
		const r = records[i]!;
		if (r.startsWith("# branch.head ")) {
			const head = r.slice(14);
			if (head === "(detached)") result.detached = true;
			else result.branch = head;
		} else if (r.startsWith("# branch.upstream ")) result.upstream = r.slice(18);
		else if (r.startsWith("# branch.ab ")) {
			const [a, b] = r.slice(12).split(" ");
			result.ahead = Math.abs(Number(a));
			result.behind = Math.abs(Number(b));
		} else if (r.startsWith("1 ") || r.startsWith("2 ")) {
			const parts = r.split(" ");
			const xy = parts[1]!;
			const path = parts.slice(r.startsWith("1 ") ? 8 : 9).join(" ");
			const staged = xy[0] !== ".";
			const code = staged ? xy[0]! : xy[1]!;
			const file: GitFile = { path, status: code === "A" ? "added" : code === "D" ? "deleted" : code === "R" ? "renamed" : "modified", staged };
			if (r.startsWith("2 ")) file.from = records[++i]!;
			result.files.push(file);
		} else if (r.startsWith("u ")) result.files.push({ path: r.split(" ").slice(10).join(" "), status: "conflicted", staged: false });
		else if (r.startsWith("? ")) result.files.push({ path: r.slice(2), status: "untracked", staged: false });
	}
	result.files.sort((a, b) => a.path.localeCompare(b.path));
	return result;
}

/** Local branches, most recently committed first. */
export async function branches(cwd: string): Promise<GitBranch[]> {
	const out = await git(cwd, ["for-each-ref", "--sort=-committerdate", "--format=%(HEAD)%00%(refname:short)%00%(upstream:short)%00%(committerdate:iso-strict)", "refs/heads/"]);
	return out
		.split("\n")
		.filter(Boolean)
		.map((line) => {
			const [head, name, upstream, date] = line.split("\0");
			return { name: name!, current: head === "*", ...(upstream ? { upstream } : {}), ...(date ? { lastCommitAt: date } : {}) };
		});
}

/** Switches branch, or creates one (from `base`, default HEAD). Uncommitted changes come along, as with git. */
export async function checkout(cwd: string, branch: string, create = false, base?: string): Promise<void> {
	validBranch(branch);
	await git(cwd, create ? ["switch", "-c", branch, ...(base ? [base] : [])] : ["switch", branch]);
}

/** Commits `paths` (or everything that changed), including new and deleted files. Returns the new commit. */
export async function commit(cwd: string, message: string, options: { paths?: string[]; amend?: boolean } = {}): Promise<string> {
	if (!message.trim() && !options.amend) throw new EngineError("INVALID", "Write a commit message first.");
	const amend = options.amend ? ["--amend"] : [];
	const text = message.trim() ? ["-m", message.trim()] : ["--no-edit"];
	if (options.paths?.length) {
		await git(cwd, ["add", "-A", "--", ...options.paths]);
		await git(cwd, ["commit", "-q", ...text, ...amend, "--only", "--", ...options.paths]);
	} else {
		await git(cwd, ["add", "-A"]);
		await git(cwd, ["commit", "-q", ...text, ...amend]);
	}
	return (await git(cwd, ["rev-parse", "HEAD"])).trim();
}

/**
 * What a commit message is written from: the diff of tracked files (staged or not) and the start of new
 * files. Read-only: the user's index is not touched.
 */
export async function diffForMessage(cwd: string, paths?: string[], maxChars = 24_000): Promise<string> {
	const s = await status(cwd);
	const chosen = paths?.length ? s.files.filter((f) => paths.includes(f.path)) : s.files;
	const tracked = chosen.filter((f) => f.status !== "untracked").map((f) => f.path);
	let out = "";
	if (tracked.length) {
		out += await git(cwd, ["diff", "HEAD", "--no-color", "-U2", "--", ...tracked]).catch(() => git(cwd, ["diff", "--cached", "--no-color", "-U2", "--", ...tracked]));
	}
	for (const f of chosen.filter((f) => f.status === "untracked").slice(0, 20)) {
		const head = await readHead(`${cwd}/${f.path}`, 60);
		out += `\nnew file: ${f.path}\n${head}\n`;
	}
	return out.length > maxChars ? `${out.slice(0, maxChars)}\n… (diff truncated)` : out;
}

async function readHead(file: string, lines: number): Promise<string> {
	try {
		const { readFile } = await import("node:fs/promises");
		const text = await readFile(file, "utf8");
		if (text.includes("\0")) return "(binary)";
		return text.split("\n").slice(0, lines).map((l) => `+${l}`).join("\n");
	} catch {
		return "";
	}
}

/** Push, creating the upstream on the first push (G3). */
export async function push(cwd: string): Promise<string> {
	const s = await status(cwd);
	if (!s.branch) throw new EngineError("INVALID", "Check out a branch before pushing.");
	if (s.upstream) return git(cwd, ["push"], { timeoutMs: 120_000 });
	const remote = (await git(cwd, ["remote"])).split("\n").filter(Boolean);
	if (!remote.length) throw new EngineError("INVALID", "This repository has no remote to push to.");
	const target = remote.includes("origin") ? "origin" : remote[0]!;
	return git(cwd, ["push", "-u", target, s.branch], { timeoutMs: 120_000 });
}

export const pull = (cwd: string) => git(cwd, ["pull", "--ff-only"], { timeoutMs: 120_000 });
export const fetchAll = (cwd: string) => git(cwd, ["fetch", "--all", "--prune"], { timeoutMs: 120_000 });

// ── Worktrees (BP5) ───────────────────────────────────────────────────────

/** A new worktree at `path` on a new branch from `base`. */
export async function addWorktree(repo: string, path: string, branch: string, base: string): Promise<void> {
	validBranch(branch);
	mkdirSync(dirname(path), { recursive: true });
	await git(repo, ["worktree", "add", "-q", "-b", branch, path, base]);
}

/**
 * Merges a worktree's branch into `base` in the main checkout, then removes the worktree and the branch.
 * The worktree must have no uncommitted changes, and the main checkout must be on `base`.
 */
export async function mergeWorktree(repo: string, path: string, branch: string, base: string): Promise<void> {
	const tree = await status(path);
	if (tree.files.length) throw new EngineError("CONFLICT", `Commit or discard the ${tree.files.length === 1 ? "change" : `${tree.files.length} changes`} in the worktree first.`);
	const main = await status(repo);
	if (main.branch !== base) throw new EngineError("CONFLICT", `The project is on ${main.branch ?? "a detached HEAD"}, not ${base}. Switch it to ${base} to merge.`);
	await git(repo, ["merge", "--no-edit", branch]).catch(async (error) => {
		await git(repo, ["merge", "--abort"]).catch(() => undefined);
		throw new EngineError("CONFLICT", `The merge has conflicts; nothing was changed. ${String((error as Error).message).split("\n")[0]}`);
	});
	await removeWorktree(repo, path, branch, false);
}

/** Removes the worktree and its branch (`force`: even with unmerged or uncommitted work). */
export async function removeWorktree(repo: string, path: string, branch: string, force: boolean): Promise<void> {
	if (existsSync(path)) await git(repo, ["worktree", "remove", ...(force ? ["--force"] : []), path]);
	else await git(repo, ["worktree", "prune"]);
	rmSync(path, { recursive: true, force: true });
	await git(repo, ["branch", force ? "-D" : "-d", branch]).catch(() => undefined);
}

/** `piopio/<slug>` from a prompt: lowercase words, at most 5. */
export function branchName(prompt: string): string {
	const words = prompt
		.toLowerCase()
		.normalize("NFD")
		.replace(/[̀-ͯ]/g, "")
		.replace(/[^a-z0-9\s-]/g, " ")
		.split(/\s+/)
		.filter((w) => w && !["the", "a", "an", "to", "and", "of", "for", "in", "on", "with", "please"].includes(w))
		.slice(0, 5);
	return `piopio/${words.join("-") || "session"}`;
}

function validBranch(name: string): void {
	if (!name || /\s|\.\.|[~^:?*[\\]|^-|\/$|\.lock$|@\{/.test(name)) throw new EngineError("INVALID", `“${name}” isn't a valid branch name.`);
}

/** Git's error, minus noise, with hints for the common cases. */
function friendly(command: string, message: string, code: number | null): string {
	if (/could not read Username|Authentication failed|Permission denied \(publickey\)|terminal prompts disabled/i.test(message)) {
		return `git ${command}: the remote needs credentials. Sign in with \`gh auth login\` or set up SSH keys, then try again.`;
	}
	if (/no upstream|has no upstream/i.test(message)) return `git ${command}: this branch has no upstream yet. Push it first.`;
	if (/Not possible to fast-forward|diverging branches/i.test(message)) return `git ${command}: your branch and the remote have diverged. Pull with a merge or rebase in a terminal.`;
	const first = message.split("\n").filter((l) => l && !l.startsWith("hint:")).slice(0, 3).join(" ");
	return `git ${command}: ${first || `exit ${code}`}`;
}

const MESSAGE_SYSTEM = `You write git commit messages. Reply with the message only: no quotes, no code fences, no preamble.
First line: an imperative summary of at most 72 characters (e.g. "Add reconnect with resume to the WebSocket transport").
If the change needs it, add a blank line and up to four short lines explaining what and why. Match the style of the repository's recent subjects.`;

/** A commit message for `paths`, from the diff, by the utility model. Without a model, a plain summary. */
export async function commitMessage(cwd: string, paths: string[] | undefined, utility: (system: string, prompt: string) => Promise<string | undefined>): Promise<string> {
	const diff = await diffForMessage(cwd, paths);
	if (!diff.trim()) throw new EngineError("INVALID", "Nothing to commit.");
	const recent = await git(cwd, ["log", "-8", "--format=%s"]).catch(() => "");
	const written = await utility(MESSAGE_SYSTEM, `${recent.trim() ? `Recent commit subjects:\n${recent.trim()}\n\n` : ""}Diff:\n${diff}`);
	if (written) return written.replace(/^```\w*\n?|```$/g, "").replace(/^["']|["']$/g, "").trim();
	const files = (await status(cwd)).files.filter((f) => !paths?.length || paths.includes(f.path)).map((f) => f.path);
	return files.length <= 3 ? `Update ${files.join(", ")}` : `Update ${files.length} files`;
}
