/**
 * Overview › Disk (docs/spec/34 §7.1): what the data folder holds, by kind, and the one cleanup Piopio can do safely:
 * worktrees nothing uses any more. Sizes come from the data folder only; nothing outside it is measured or touched.
 */
import { execFile } from "node:child_process";
import { existsSync, lstatSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";
import type { StorageResult } from "@piopio/protocol";

const run = promisify(execFile);

/** Bytes under a path (files only, links not followed). */
export function sizeOf(path: string): number {
	let total = 0;
	const stack = [path];
	while (stack.length) {
		const p = stack.pop()!;
		let st;
		try {
			st = lstatSync(p);
		} catch {
			continue;
		}
		if (st.isSymbolicLink()) continue;
		if (st.isDirectory()) {
			try {
				for (const name of readdirSync(p)) stack.push(join(p, name));
			} catch {
				// unreadable: not counted
			}
		} else total += st.size;
	}
	return total;
}

/** Top-level names of the data folder, by what they are. Anything else counts as "Indexes and settings". */
const KINDS: { id: string; label: string; names: string[]; detail?: string }[] = [
	{ id: "conversations", label: "Conversations", names: ["chats", "threads", "agents", "scratch", "drafts"], detail: "chats and agents (Build sessions are pi's, in ~/.pi)" },
	{ id: "checkpoints", label: "Checkpoints", names: ["checkpoints"], detail: "Build's file history, per project" },
	{ id: "attachments", label: "Attachments", names: ["attachments"] },
	{ id: "memory", label: "Memory", names: ["memory.db", "memory.db-wal", "memory.db-shm"] },
	{ id: "library", label: "Library and apps", names: ["library-visuals", "apps-cache", "apps-history", "library.json", "apps.json"] },
	{ id: "logs", label: "Logs", names: ["logs"] },
];

export type Worktree = { path: string; project?: string; repo?: string; inUse: boolean };

/** Worktrees under <home>/worktrees/<project>/<session>, and whether a live session works in each. */
export function worktrees(home: string, inUse: ReadonlySet<string>, repoOf: (projectId: string) => string | undefined): Worktree[] {
	const root = join(home, "worktrees");
	if (!existsSync(root)) return [];
	const out: Worktree[] = [];
	for (const project of readdirSync(root)) {
		const dir = join(root, project);
		if (!lstatSync(dir).isDirectory()) continue;
		for (const name of readdirSync(dir)) {
			const path = join(dir, name);
			if (!lstatSync(path).isDirectory()) continue;
			const repo = repoOf(project);
			out.push({ path, project, ...(repo ? { repo } : {}), inUse: inUse.has(path) });
		}
	}
	return out;
}

/**
 * A worktree nothing uses may go when it holds nothing of yours: no uncommitted change (an empty folder, or a git
 * worktree whose status is clean). One with changes is left, whatever its session's state.
 */
export async function removable(w: Worktree): Promise<boolean> {
	if (w.inUse) return false;
	if (!existsSync(join(w.path, ".git"))) return readdirSync(w.path).length === 0;
	try {
		const { stdout } = await run("git", ["-C", w.path, "status", "--porcelain"], { timeout: 15_000 });
		return stdout.trim() === "";
	} catch {
		return false;
	}
}

/** Removes a worktree: through its repository when git knows it (so the branch's worktree entry goes too), else the folder. */
export async function removeWorktreeFolder(w: Worktree): Promise<void> {
	if (w.repo && existsSync(join(w.path, ".git"))) {
		try {
			await run("git", ["-C", w.repo, "worktree", "remove", w.path], { timeout: 30_000 });
			return;
		} catch {
			// not registered (any more): the folder below
		}
	}
	rmSync(w.path, { recursive: true, force: true });
}

export async function storage(home: string, trees: readonly Worktree[], projectName: (id: string) => string | undefined): Promise<StorageResult> {
	const items: StorageResult["items"] = [];
	const seen = new Set<string>(["worktrees"]);
	for (const k of KINDS) {
		let bytes = 0;
		for (const name of k.names) {
			seen.add(name);
			if (existsSync(join(home, name))) bytes += sizeOf(join(home, name));
		}
		items.push({ id: k.id, label: k.label, bytes, ...(k.detail ? { detail: k.detail } : {}) });
	}
	// Worktrees, per project, with what cleaning would free.
	const byProject = new Map<string, number>();
	let freesBytes = 0;
	let count = 0;
	for (const w of trees) {
		const bytes = sizeOf(w.path);
		byProject.set(w.project ?? "other", (byProject.get(w.project ?? "other") ?? 0) + bytes);
		if (await removable(w)) {
			freesBytes += bytes;
			count++;
		}
	}
	const treesTotal = [...byProject.values()].reduce((a, b) => a + b, 0);
	const detail = [...byProject].sort((a, b) => b[1] - a[1]).map(([id]) => projectName(id) ?? id).slice(0, 3).join(", ");
	items.push({
		id: "worktrees",
		label: "Worktrees",
		bytes: treesTotal,
		...(detail ? { detail } : {}),
		...(count ? { action: { id: "worktrees" as const, label: `Clean up ${count} unused worktree${count === 1 ? "" : "s"}`, freesBytes, count } } : {}),
	});
	let rest = 0;
	for (const name of readdirSync(home)) if (!seen.has(name) && !name.endsWith(".sock")) rest += sizeOf(join(home, name));
	items.push({ id: "other", label: "Indexes and settings", bytes: rest, detail: "search, usage, settings" });
	return { totalBytes: items.reduce((n, i) => n + i.bytes, 0), items: items.filter((i) => i.bytes > 0 || i.action), path: home };
}

export async function cleanWorktrees(trees: readonly Worktree[]): Promise<{ freedBytes: number; removed: number }> {
	let freedBytes = 0;
	let removed = 0;
	for (const w of trees) {
		if (!(await removable(w))) continue;
		const bytes = sizeOf(w.path);
		await removeWorktreeFolder(w);
		if (!existsSync(w.path)) {
			freedBytes += bytes;
			removed++;
		}
	}
	return { freedBytes, removed };
}
