/**
 * Checkpoints (docs/spec/05-build §7): snapshots of a working tree in a shadow git repository,
 * `<home>/checkpoints/<hash of the folder>.git`, so the user's own repository is never touched.
 * Untracked files are included; .gitignore applies, plus a few heavy folders and a per-file size cap.
 */
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, statSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { EngineError } from "./models.js";

export type FileChange = { path: string; status: "added" | "modified" | "deleted"; added: number; removed: number; binary?: boolean };
export type Checkpoint = { id: string; files: number };

/** Never snapshotted, even without a .gitignore. */
const DEFAULT_EXCLUDES = ["node_modules/", ".build/", "DerivedData/", ".venv/", "venv/", "__pycache__/", ".next/", ".turbo/", ".DS_Store", "*.xcuserstate"];
const MAX_FILE_BYTES = 20 * 1024 * 1024;
/** Retention (CK3): the newest 50 per folder, plus anything from the last 14 days. */
const KEEP_COUNT = 50;
const KEEP_MS = 14 * 24 * 60 * 60 * 1000;

export class CheckpointStore {
	private queues = new Map<string, Promise<unknown>>();
	private snapshots = 0;

	constructor(private readonly root: string) {}

	/** Records the folder as it is now. `files`: how many differ from the previous checkpoint. */
	snapshot(cwd: string, message: string): Promise<Checkpoint> {
		return this.serial(cwd, async () => {
			const git = await this.repo(cwd);
			await this.excludeLargeFiles(git, cwd);
			await git(["add", "-A", "."]);
			const tree = (await git(["write-tree"])).trim();
			const parent = (await git(["rev-parse", "-q", "--verify", "refs/piopio/latest"]).catch(() => "")).trim();
			const commit = (await git(["commit-tree", tree, ...(parent ? ["-p", parent] : []), "-m", message])).trim();
			await git(["update-ref", "refs/piopio/latest", commit]);
			await git(["update-ref", `refs/piopio/cp/${Date.now()}-${commit.slice(0, 12)}`, commit]);
			const files = parent ? (await git(["diff", "--no-renames", "--name-only", "-z", parent, commit])).split("\0").filter(Boolean).length : 0;
			if (++this.snapshots % 20 === 0) void this.prune(cwd).catch(() => undefined);
			return { id: commit, files };
		});
	}

	/** What differs between a checkpoint and the folder now. */
	changes(cwd: string, base: string): Promise<FileChange[]> {
		return this.serial(cwd, async () => {
			const git = await this.repo(cwd);
			await this.verify(git, base);
			await git(["add", "-A", "."]);
			return parseChanges(await git(["diff", "--cached", "--no-renames", "--name-status", "-z", base]), await git(["diff", "--cached", "--no-renames", "--numstat", "-z", base]));
		});
	}

	/** Unified diff of one file between a checkpoint and now. */
	diff(cwd: string, base: string, path: string): Promise<string> {
		return this.serial(cwd, async () => {
			const git = await this.repo(cwd);
			await this.verify(git, base);
			await git(["add", "-A", "--", path]).catch(() => undefined);
			return git(["diff", "--cached", "--no-renames", "--no-color", "-U4", base, "--", path]);
		});
	}

	/** Puts files back as they were at `target` (all of them, or `paths`). Returns what was changed. */
	restore(cwd: string, target: string, paths?: string[]): Promise<FileChange[]> {
		return this.serial(cwd, async () => {
			const git = await this.repo(cwd);
			await this.verify(git, target);
			await git(["add", "-A", "."]);
			let changes = parseChanges(await git(["diff", "--cached", "--no-renames", "--name-status", "-z", target]), await git(["diff", "--cached", "--no-renames", "--numstat", "-z", target]));
			if (paths) changes = changes.filter((c) => paths.includes(c.path));
			for (const c of changes.filter((c) => c.status === "added")) unlinkSync(join(cwd, c.path));
			const back = changes.filter((c) => c.status !== "added").map((c) => c.path);
			if (back.length) await git(["checkout", target, "--pathspec-from-file=-", "--pathspec-file-nul"], back.join("\0"));
			await git(["add", "-A", "."]);
			return changes;
		});
	}

	/** Drops checkpoints beyond the retention window, then lets git collect them. */
	async prune(cwd: string): Promise<number> {
		return this.serial(cwd, async () => {
			const git = await this.repo(cwd);
			const refs = (await git(["for-each-ref", "--format=%(refname)", "refs/piopio/cp/"])).split("\n").filter(Boolean).sort().reverse();
			const now = Date.now();
			const old = refs.slice(KEEP_COUNT).filter((ref) => now - Number(ref.split("/").at(-1)!.split("-")[0]) > KEEP_MS);
			for (const ref of old) await git(["update-ref", "-d", ref]);
			if (old.length) await git(["gc", "--auto", "--quiet"]).catch(() => undefined);
			return old.length;
		});
	}

	private async verify(git: Git, sha: string): Promise<void> {
		if (!/^[0-9a-f]{7,64}$/.test(sha)) throw new EngineError("INVALID", "Not a checkpoint id.");
		await git(["cat-file", "-e", `${sha}^{commit}`]).catch(() => {
			throw new EngineError("NOT_FOUND", "That checkpoint is gone (older than the retention window).");
		});
	}

	private async repo(cwd: string): Promise<Git> {
		if (!existsSync(cwd)) throw new EngineError("NOT_FOUND", `No such folder: ${cwd}`);
		const gitDir = join(this.root, `${createHash("sha256").update(cwd).digest("hex").slice(0, 16)}.git`);
		const git = gitRunner(gitDir, cwd);
		if (!existsSync(join(gitDir, "HEAD"))) {
			mkdirSync(gitDir, { recursive: true });
			await git(["init", "-q"]);
			mkdirSync(join(gitDir, "info"), { recursive: true });
			appendFileSync(join(gitDir, "info", "exclude"), `${DEFAULT_EXCLUDES.join("\n")}\n`);
			appendFileSync(join(gitDir, "piopio-folder"), `${cwd}\n`);
		}
		return git;
	}

	/** New or changed files over the cap stay out of checkpoints. */
	private async excludeLargeFiles(git: Git, cwd: string): Promise<void> {
		const candidates = (await git(["ls-files", "-z", "--others", "--modified", "--exclude-standard"])).split("\0").filter(Boolean);
		const large = candidates.filter((path) => {
			try {
				return statSync(join(cwd, path)).size > MAX_FILE_BYTES;
			} catch {
				return false;
			}
		});
		if (large.length) appendFileSync(join(await this.gitDirOf(git), "info", "exclude"), `${large.map((p) => `/${p}`).join("\n")}\n`);
	}

	private async gitDirOf(git: Git): Promise<string> {
		return (await git(["rev-parse", "--absolute-git-dir"])).trim();
	}

	/** One git operation at a time per folder: they share the shadow index. */
	private serial<T>(cwd: string, task: () => Promise<T>): Promise<T> {
		const previous = this.queues.get(cwd) ?? Promise.resolve();
		const next = previous.catch(() => undefined).then(task);
		this.queues.set(cwd, next);
		return next;
	}
}

type Git = (args: string[], stdin?: string) => Promise<string>;

/** git with the shadow repository, isolated from the user's git settings and hooks. */
function gitRunner(gitDir: string, workTree: string): Git {
	const env: NodeJS.ProcessEnv = {
		PATH: process.env.PATH ?? "/usr/bin:/bin",
		HOME: process.env.HOME,
		GIT_DIR: gitDir,
		GIT_WORK_TREE: workTree,
		GIT_AUTHOR_NAME: "Piopio",
		GIT_AUTHOR_EMAIL: "checkpoints@piopio.app",
		GIT_COMMITTER_NAME: "Piopio",
		GIT_COMMITTER_EMAIL: "checkpoints@piopio.app",
		GIT_CONFIG_NOSYSTEM: "1",
		GIT_TERMINAL_PROMPT: "0",
	};
	const config = ["-c", "core.hooksPath=/dev/null", "-c", "core.autocrlf=false", "-c", "core.fsmonitor=false", "-c", "core.quotePath=false", "-c", "commit.gpgSign=false", "-c", "gc.auto=256"];
	return (args, stdin) =>
		new Promise((resolve, reject) => {
			const child = spawn("git", [...config, ...args], { cwd: workTree, env });
			let out = "";
			let err = "";
			child.stdout.setEncoding("utf8").on("data", (d: string) => (out += d));
			child.stderr.setEncoding("utf8").on("data", (d: string) => (err += d));
			child.on("error", reject);
			child.on("close", (code) => (code === 0 ? resolve(out) : reject(new Error(`git ${args[0]}: ${err.trim() || `exit ${code}`}`))));
			child.stdin.end(stdin ?? "");
		});
}

/** `--name-status -z` and `--numstat -z` output → changes. */
function parseChanges(nameStatus: string, numstat: string): FileChange[] {
	const stats = new Map<string, { added: number; removed: number; binary: boolean }>();
	for (const entry of numstat.split("\0").filter(Boolean)) {
		const [added, removed, path] = entry.split("\t");
		if (path) stats.set(path, { added: added === "-" ? 0 : Number(added), removed: removed === "-" ? 0 : Number(removed), binary: added === "-" });
	}
	const parts = nameStatus.split("\0").filter(Boolean);
	const changes: FileChange[] = [];
	for (let i = 0; i + 1 < parts.length; i += 2) {
		const code = parts[i]![0];
		const path = parts[i + 1]!;
		const s = stats.get(path) ?? { added: 0, removed: 0, binary: false };
		changes.push({ path, status: code === "A" ? "added" : code === "D" ? "deleted" : "modified", added: s.added, removed: s.removed, ...(s.binary ? { binary: true } : {}) });
	}
	return changes.sort((a, b) => a.path.localeCompare(b.path));
}
