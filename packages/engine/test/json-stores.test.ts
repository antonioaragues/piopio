import { mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { expect, test } from "vitest";
import { Endpoints } from "../src/endpoints.js";
import { BrowserSites } from "../src/tools/browser-tools.js";

// Every JSON file the engine writes and reads back goes through readJsonFile (a file that doesn't parse is moved aside,
// not reset and then written over) and is written with writeFileAtomic (re-audit 2026-11-25 §5.2: automations and work
// kept their own readers that started empty, and the next save lost what was there).

const SRC = join(import.meta.dirname, "..", "src");

/** The direct reads that stay, each a file the engine doesn't write back, or a read that throws instead of resetting. */
const DIRECT_READS: Record<string, { count: number; why: string }> = {
	"about-me.ts": { count: 1, why: "the pre-memory about-me.json, read once to move it into memory" },
	"agent-file-store.ts": { count: 2, why: "a deleted file's entry.json, written once at delete and read to restore or expire it" },
	"agent-files.ts": { count: 1, why: "agent.json: a broken one throws and is reported, nothing resets it" },
	"cloud.ts": { count: 1, why: "the Worker build's wrangler.json" },
	"mcp-probe.ts": { count: 1, why: "other apps' MCP configs, only read" },
	"packages.ts": { count: 1, why: "an installed package's package.json" },
	"project-trust.ts": { count: 1, why: "Claude Code's ~/.claude.json, only read" },
	"runtimes/segments.ts": { count: 2, why: "a coding agent's store, read for the timeline; its runtime owns the file" },
	"server.ts": { count: 2, why: "the browser MCP's state.json (another process's) and the legacy routines, read once" },
	"sessions.ts": { count: 1, why: "a coding agent's store, read for its session id; its runtime owns the file" },
	"user-hooks.ts": { count: 1, why: "a project's .claude/settings.json, only read" },
	"work/migrate.ts": { count: 1, why: "the legacy board files, read once to migrate them" },
};

function sources(dir: string): string[] {
	return readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? sources(join(dir, e.name)) : e.name.endsWith(".ts") ? [join(dir, e.name)] : []));
}

test("JSON stores are read with readJsonFile and written with writeFileAtomic", () => {
	const reads: Record<string, number> = {};
	const tmpWrites: string[] = [];
	for (const file of sources(SRC)) {
		const rel = relative(SRC, file);
		if (rel === "atomic.ts") continue;
		const text = readFileSync(file, "utf8");
		const n = text.split("JSON.parse(readFileSync(").length - 1;
		if (n) reads[rel] = n;
		if (/renameSync\(\s*tmp\b|\.tmp[`"]/.test(text)) tmpWrites.push(rel);
	}
	const expected = Object.fromEntries(Object.entries(DIRECT_READS).map(([f, r]) => [f, r.count]));
	// A new store: use readJsonFile (atomic.ts). A file Piopio only reads: add it to DIRECT_READS with why.
	expect(reads).toEqual(expected);
	// A temporary file and a rename: writeFileAtomic does that, and reaches the disk before the rename.
	expect(tmpWrites).toEqual([]);
});

test("a store that doesn't parse is moved aside, and the next save doesn't write over it", () => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-stores-"));
	const sites = join(dir, "browser-sites.json");
	writeFileSync(sites, '{"allowed": ["example.com"');
	const b = new BrowserSites(sites);
	expect(b.list()).toEqual([]);
	const aside = readdirSync(dir).find((f) => f.startsWith("browser-sites.json.corrupt-"));
	expect(aside && readFileSync(join(dir, aside), "utf8")).toBe('{"allowed": ["example.com"');

	// pi's models.json is yours and pi's too: one with an error isn't moved aside, and isn't written over.
	const models = join(dir, "models.json");
	writeFileSync(models, '{"providers": {');
	const endpoints = new Endpoints(models);
	expect(endpoints.list()).toEqual([]);
	expect(() => endpoints.write("custom-x", { baseUrl: "http://localhost:1/v1", api: "openai-completions", models: [] })).toThrow("left as it is");
	expect(readFileSync(models, "utf8")).toBe('{"providers": {');
	expect(statSync(join(dir, aside!)).size).toBeGreaterThan(0);
});
