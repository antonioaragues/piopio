/** Overview's Activity, Disk and Setup (docs/spec/34 OV2–OV3). */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ProviderInfo, SessionSummary, TimelineItem } from "@piopio/protocol";
import { expect, test } from "vitest";
import { activity, previousBounds } from "../src/activity.js";
import { type LedgerSource, UsageLedger } from "../src/ledger.js";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { setupMap } from "../src/setup.js";
import { cleanWorktrees, storage, worktrees } from "../src/storage.js";
import { TestClient } from "./client.js";

const now = new Date(2026, 10, 23, 15);
const at = (d: number, h = 10) => new Date(2026, 10, d, h).toISOString();
const chat: LedgerSource = { key: "t1", container: "t1", ref: { kind: "thread", id: "t1" }, title: "Trip", sourceKind: "thread", place: "mac" };

test("Activity counts what sessions show, once each, against the range before", () => {
	const ledger = new UsageLedger();
	const items = (d: number): TimelineItem[] => [
		{ kind: "user", id: `u${d}`, at: at(d), text: "hi" },
		{ kind: "tool", id: `tool:a${d}`, at: at(d), callId: `a${d}`, tool: "bash", args: {}, status: "done", durationMs: 60_000 },
		{ kind: "tool", id: `tool:w${d}`, at: at(d), callId: `w${d}`, tool: "edit", args: { path: "src/a.ts" }, status: "done" },
		{ kind: "tool", id: `tool:x${d}`, at: at(d), callId: `x${d}`, tool: "write", args: { path: `src/new${d}.ts` }, status: "done" },
		{ kind: "tool", id: `tool:d${d}`, at: at(d), callId: `d${d}`, tool: "bash", args: {}, status: "denied" },
		{ kind: "tool", id: `tool:b${d}`, at: at(d), callId: `b${d}`, tool: "read_file", args: {}, status: "error" },
		{ kind: "assistant", id: `e${d}`, at: at(d), parts: [], status: "error", errorKind: "rate_limit" },
		{ kind: "compaction", id: `c${d}`, at: at(d), summary: "…" },
		{ kind: "checkpoint", id: `k${d}`, at: at(d), checkpointId: "x", label: "Before turn 1", files: 3 },
	] as TimelineItem[];
	ledger.recordItems(chat, [...items(20), ...items(21)]);
	ledger.recordItems(chat, items(21)); // read again: nothing twice
	ledger.recordItems(chat, items(25 - 30)); // October 26: last month
	ledger.recordItems(chat, [{ kind: "tool", id: "tool:run", at: at(22), callId: "run", tool: "bash", args: {}, status: "running" } as TimelineItem]);
	const sessions = [
		{ ref: { kind: "thread", id: "t1" }, title: "Trip", createdAt: at(20), updatedAt: at(21) },
		{ ref: { kind: "build", id: "b1" }, title: "Fix", createdAt: at(21), updatedAt: at(22), pr: { repo: "a/b", number: 1, url: "", title: "", head: "h", base: "main", state: "merged" } },
		{ ref: { kind: "thread", id: "t2" }, title: "Sub", createdAt: at(21), updatedAt: at(21), parent: { id: "t1", callId: "x" } },
	] as SessionSummary[];
	const runs = [
		{ id: "r1", automation: "brief", firedAt: at(21), cause: "time" as const, status: "failed" as const },
		{ id: "r2", automation: "brief", firedAt: at(22), cause: "time" as const, status: "failed" as const },
		{ id: "r3", automation: "brief", firedAt: at(23), cause: "time" as const, status: "done" as const },
	];
	const r = activity("month", { ledger, sessions, runs, automationName: () => "Morning briefing", agentName: () => undefined, now });
	const row = (group: string, id: string) => r.groups.find((g) => g.id === group)!.rows.find((x) => x.id === id)!;
	expect(row("conversations", "messages")).toMatchObject({ value: 2, previous: 1 });
	expect(row("conversations", "started")).toMatchObject({ value: 1, previous: 0 });
	expect(row("conversations", "subagents").value).toBe(1);
	// src/a.ts twice is one file; two new ones: three.
	expect(row("build", "files")).toMatchObject({ value: 3, unit: "files" });
	expect(row("build", "prsMerged").value).toBe(1);
	expect(row("automations", "autoFailed")).toMatchObject({ value: 2, detail: "Morning briefing failed most" });
	expect(row("you", "toolCalls")).toMatchObject({ value: 10, detail: expect.stringMatching(/^bash, /) });
	expect(row("you", "denied").value).toBe(2);
	expect(row("reliability", "errors")).toMatchObject({ value: 2, detail: "mostly rate limit" });
	expect(row("reliability", "toolErrors").value).toBe(2);
	expect(row("reliability", "compactions").value).toBe(2);
	// The year of days starts the day Piopio did.
	expect(r.year[0]!.day).toBe("2026-10-26");
	expect(r.year.at(-1)!.day).toBe("2026-11-23");
	expect(r.year.find((d) => d.day === "2026-11-21")!.count).toBe(1);
	expect(previousBounds("7d", now).from.getDate()).toBe(10);
	ledger.close();
});

test("Disk: unused worktrees go only when clean; one in use or with changes stays", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-disk-ov-"));
	const repo = join(home, "repo");
	mkdirSync(repo);
	const git = (cwd: string, ...args: string[]) => execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" } });
	git(repo, "init", "-q", "-b", "main");
	writeFileSync(join(repo, "a.txt"), "a\n".repeat(1000));
	git(repo, "add", ".");
	git(repo, "commit", "-qm", "a");
	const dir = (s: string) => join(home, "worktrees", "prj_1", s);
	mkdirSync(join(home, "worktrees", "prj_1"), { recursive: true });
	for (const s of ["ses_done", "ses_live", "ses_dirty"]) git(repo, "worktree", "add", "-q", "-b", s, dir(s));
	writeFileSync(join(dir("ses_dirty"), "b.txt"), "unsaved");
	mkdirSync(join(home, "worktrees", "teams", "team_old"), { recursive: true });
	const trees = worktrees(home, new Set([dir("ses_live")]), (id) => (id === "prj_1" ? repo : undefined));
	const before = await storage(home, trees, (id) => (id === "prj_1" ? "Site" : undefined));
	const wt = before.items.find((i) => i.id === "worktrees")!;
	expect(wt.action).toMatchObject({ id: "worktrees", count: 2 });
	expect(wt.detail).toContain("Site");
	const done = await cleanWorktrees(trees);
	expect(done.removed).toBe(2);
	expect(done.freedBytes).toBe(wt.action!.freesBytes);
	expect(existsSync(dir("ses_done"))).toBe(false);
	expect(existsSync(join(home, "worktrees", "teams", "team_old"))).toBe(false);
	expect(existsSync(dir("ses_live"))).toBe(true);
	expect(existsSync(dir("ses_dirty"))).toBe(true);
	// git forgot the removed worktree; the branch stays.
	expect(git(repo, "worktree", "list")).not.toContain("ses_done");
	expect(git(repo, "branch", "--list", "ses_done")).toContain("ses_done");
});

const provider = (id: string, extra: Partial<ProviderInfo> = {}): ProviderInfo => ({ id, name: id === "openrouter" ? "OpenRouter" : id, methods: [], status: "connected", featured: false, models: 300, ...extra }) as ProviderInfo;

test("Setup: one map with a dot where something needs you and dashes where nothing uses it", () => {
	const map = setupMap({
		providers: [provider("openrouter", { billing: "OpenRouter credits" }), provider("openai", { status: "needs_attention", message: "key rejected" }), provider("xai")],
		codingAgents: [provider("claude-code", { agent: { path: "/bin/claude", signedIn: true, install: "", signIn: "" }, billing: "Claude subscription" })],
		connectors: [],
		mcp: [{ name: "linear", scope: "global", transport: "http", enabled: true }, { name: "old", scope: "global", transport: "stdio", enabled: false }] as never,
		memory: { semantic: false, reason: "off" },
		cloud: { connected: true, url: "https://piopio.me.workers.dev", reachable: false, agents: [] },
		agents: [
			{ id: "rita", name: "Rita", cloud: false, model: "openrouter/anthropic/claude-haiku-5.5", telegram: true, paused: false, overBudget: false, monthUsd: 0.3, automations: 1 },
			{ id: "quiet", name: "Quiet", cloud: false, model: "x/y", telegram: false, paused: false, overBudget: false, monthUsd: 0, automations: 0 },
			{ id: "up", name: "Up", cloud: true, model: "x/y", telegram: false, paused: false, overBudget: true, monthUsd: 2, automations: 0 },
		],
		automations: [{ id: "brief", name: "Morning briefing", runsAs: "rita", enabled: true, result: "telegram", nextRun: at(24, 7), monthUsd: 0.2, cloud: false }],
		projects: 2,
		defaultModel: "openrouter/anthropic/claude-sonnet-5.5",
		usedProviders: new Set(["openrouter"]),
		usedMcp: new Set(["linear"]),
	});
	const node = (id: string) => map.nodes.find((n) => n.id === id)!;
	expect(node("place:mac")).toMatchObject({ line: "2 projects · 2 agents · 1 automation" });
	expect(node("place:mac").agents!.map((a) => [a.name, a.state])).toEqual([["Rita", "ok"], ["Quiet", "unused"]]);
	expect(node("place:cloud")).toMatchObject({ state: "needs_you", reason: "not answering" });
	expect(node("place:cloud").agents![0]).toMatchObject({ name: "Up", state: "needs_you", reason: "out of budget this month" });
	expect(node("provider:openrouter")).toMatchObject({ state: "ok", line: "default · anthropic/claude-sonnet-5.5 · OpenRouter credits" });
	expect(node("provider:openai")).toMatchObject({ state: "needs_you", reason: "key rejected", open: { kind: "settings", pane: "providers", id: "openai" } });
	expect(node("provider:xai").state).toBe("unused");
	expect(node("coding:claude-code").state).toBe("unused");
	expect(node("mcp:linear").state).toBe("ok");
	expect(node("mcp:old").state).toBe("off");
	expect(map.edges).toContainEqual({ from: "channel:telegram:rita", to: "agent:rita" });
	expect(map.edges).toContainEqual({ from: "place:cloud", to: "provider:openrouter" });
	expect(map.rows.find((r) => r.id === "brief")).toMatchObject({ kind: "automation", runsOn: "mac", reachesYouIn: "Telegram", model: "openrouter/anthropic/claude-haiku-5.5", monthUsd: 0.2 });
	expect(map.rows.find((r) => r.id === "up")).toMatchObject({ runsOn: "cloud" });
});

test("in the engine: Activity, Disk and Setup answer", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-ov23-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	try {
		const { ref } = await client.call("sessions.create", { kind: "thread" });
		await client.call("sessions.submit", { ref, input: { text: "hello" } });
		for (let i = 0; i < 200; i++) {
			const r = await client.call("stats.activity", { range: "today" });
			if (r.groups[0].rows.find((x: { id: string }) => x.id === "messages").value === 1) break;
			await new Promise((res) => setTimeout(res, 30));
		}
		const a = await client.call("stats.activity", { range: "today" });
		expect(a.groups[0].rows.find((x: { id: string }) => x.id === "started").value).toBe(1);
		expect(a.groups[0].rows.find((x: { id: string }) => x.id === "messages").value).toBe(1);
		const disk = await client.call("stats.storage", {});
		expect(disk.path).toBe(home);
		expect(disk.totalBytes).toBeGreaterThan(0);
		expect(await client.call("stats.storage.clean", { action: "worktrees" })).toEqual({ freedBytes: 0, removed: 0 });
		const setup = await client.call("stats.setup", {});
		expect(setup.nodes.map((n: { id: string }) => n.id)).toContain("place:mac");
	} finally {
		client.close();
		await engine.stop();
	}
}, 60_000);
