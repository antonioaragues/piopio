/**
 * Files for @-mentions (docs/spec/05-build BR5): the project's files (git's view when it's a repository,
 * so .gitignore applies; otherwise a bounded walk), matched fuzzily on the path.
 */
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { git } from "./git.js";

const SKIP = new Set([".git", "node_modules", ".build", "DerivedData", "dist", "build", ".next", ".venv", "venv", "__pycache__", ".turbo", ".cache"]);
const MAX_FILES = 50_000;
const cache = new Map<string, { at: number; files: string[] }>();

export type FileMatch = { path: string; kind: "file" | "folder" };

export async function searchFiles(cwd: string, query: string, limit = 30): Promise<FileMatch[]> {
	const files = await listFiles(cwd);
	const folders = new Set<string>();
	for (const f of files) for (let i = f.indexOf("/"); i !== -1; i = f.indexOf("/", i + 1)) folders.add(f.slice(0, i));
	const candidates: FileMatch[] = [...[...folders].map((path) => ({ path, kind: "folder" as const })), ...files.map((path) => ({ path, kind: "file" as const }))];
	const q = query.trim().toLowerCase();
	if (!q) return candidates.filter((c) => !c.path.includes("/")).sort((a, b) => a.path.localeCompare(b.path)).slice(0, limit);
	const scored: { match: FileMatch; score: number }[] = [];
	for (const match of candidates) {
		const score = fuzzyScore(match.path, q);
		if (score !== undefined) scored.push({ match, score });
	}
	scored.sort((a, b) => b.score - a.score || a.match.path.length - b.match.path.length);
	return scored.slice(0, limit).map((s) => s.match);
}

/** Subsequence match: higher for consecutive runs, matches in the file name, and word starts. */
export function fuzzyScore(path: string, query: string): number | undefined {
	const lower = path.toLowerCase();
	const nameStart = lower.lastIndexOf("/") + 1;
	if (lower.slice(nameStart).startsWith(query)) return 1000 - path.length;
	if (lower.includes(query)) return 600 + (lower.indexOf(query) >= nameStart ? 200 : 0) - path.length;
	let score = 0;
	let at = 0;
	let run = 0;
	for (const ch of query) {
		const found = lower.indexOf(ch, at);
		if (found === -1) return undefined;
		run = found === at ? run + 1 : 0;
		score += 1 + run * 3 + (found >= nameStart ? 2 : 0) + (found === 0 || "/_-.".includes(lower[found - 1]!) ? 4 : 0);
		at = found + 1;
	}
	return score - path.length / 10;
}

async function listFiles(cwd: string): Promise<string[]> {
	const cached = cache.get(cwd);
	if (cached && Date.now() - cached.at < 10_000) return cached.files;
	let files: string[];
	try {
		files = (await git(cwd, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"])).split("\0").filter(Boolean).slice(0, MAX_FILES);
	} catch {
		files = walk(cwd);
	}
	cache.set(cwd, { at: Date.now(), files });
	return files;
}

function walk(root: string): string[] {
	const out: string[] = [];
	const visit = (dir: string, prefix: string) => {
		let entries;
		try {
			entries = readdirSync(dir, { withFileTypes: true });
		} catch {
			return;
		}
		for (const e of entries) {
			if (out.length >= MAX_FILES) return;
			if (SKIP.has(e.name) || (e.name.startsWith(".") && e.name !== ".github")) continue;
			const path = prefix ? `${prefix}/${e.name}` : e.name;
			if (e.isDirectory()) visit(join(dir, e.name), path);
			else if (e.isFile()) out.push(path);
		}
	};
	visit(root, "");
	return out;
}
