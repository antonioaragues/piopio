/** The usage ledger (docs/spec/34 §8.1, OV0): one row per request, grouped by day and by what spent it. */
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AssistantItem, Snapshot, SpendResult } from "@piopio/protocol";
import { afterAll, beforeAll, expect, test } from "vitest";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { type LedgerSource, rangeBounds, UsageLedger } from "../src/ledger.js";
import { fileAnswers, fileItems } from "../src/runtimes/segments.js";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

const chat: LedgerSource = { key: "t1", container: "t1", ref: { kind: "thread", id: "t1" }, title: "Trip", sourceKind: "thread", place: "mac" };
const build: LedgerSource = { key: "b1", container: "b1", ref: { kind: "build", id: "b1" }, title: "Fix login", sourceKind: "build", project: "/Users/me/Piopio/site", place: "mac" };
const rita = (conversation: string, automation?: string): LedgerSource => ({ key: `rita/${conversation}`, container: "rita", ref: { kind: "agent", id: "rita", conversationId: conversation }, title: "Rita", sourceKind: "agent", agent: "rita", ...(automation ? { automation } : {}), place: "mac" });

function answer(id: string, at: string, usd: number, tokens = 1000, model = "openrouter/anthropic/claude-sonnet-5.5"): AssistantItem {
	return { kind: "assistant", id, at, parts: [{ type: "text", text: "ok" }], status: "done", model, usage: { inputTokens: tokens, outputTokens: 100, cacheReadTokens: 0, cacheWriteTokens: 0, costUsd: usd } };
}

const now = new Date(2026, 10, 23, 15, 0);
const day = (d: number, h = 10) => new Date(2026, 10, d, h).toISOString();

test("each answer is one row: read again, live or after a branch was left, it isn't counted twice", () => {
	const ledger = new UsageLedger();
	const items = [answer("m1", day(20), 0.1), answer("m3", day(21), 0.2)];
	expect(ledger.recordItems(chat, items)).toBe(2);
	// The same answers again (a reopen, the backfill): nothing new.
	expect(ledger.recordItems(chat, items)).toBe(0);
	// A live answer and the same answer read back differ in `at` (start vs the message's timestamp): one request.
	expect(ledger.recordItems(chat, [{ ...items[0]!, at: day(20, 11) }])).toBe(0);
	// Another branch reuses an index id with different tokens: a different request, and the left one stays paid for.
	expect(ledger.recordItems(chat, [answer("m3", day(21), 0.05, 2000)])).toBe(1);
	const s = ledger.spend({ range: "month" }, {}, now);
	expect(s.calls).toBe(3);
	expect(s.knownUsd).toBeCloseTo(0.35);
	ledger.close();
});

test("a month by day and by what, model, project and place; unknown prices counted, never $0", () => {
	const ledger = new UsageLedger();
	ledger.recordItems(chat, [answer("m1", day(2), 0.5), answer("m2", day(2, 14), 0, 500, "openrouter/some/unpriced")]);
	ledger.recordItems(build, [answer("e1", day(10), 1.25)]);
	ledger.recordItems(rita("person:me"), [answer("8", day(10), 0.25)]);
	ledger.recordItems(rita("run:r1", "briefing"), [answer("12", day(22), 0.75)]);
	ledger.recordItems({ ...chat, key: "c1", container: "c1", place: "cloud" }, [answer("1", day(22), 0.1)]);
	// Last month and next month stay out of this month.
	ledger.recordItems(chat, [answer("old", new Date(2026, 9, 31, 23).toISOString(), 9), answer("new", new Date(2026, 11, 1, 0, 30).toISOString(), 9)]);

	const names = { agent: (id: string) => (id === "rita" ? "Rita" : undefined), automation: (id: string) => (id === "briefing" ? "Morning briefing" : undefined) };
	const s = ledger.spend({ range: "month" }, names, now);
	expect(s.days).toHaveLength(30);
	expect(s.days[0]!.day).toBe("2026-11-01");
	expect(s.calls).toBe(6);
	expect(s.unknownCalls).toBe(1);
	expect(s.knownUsd).toBeCloseTo(2.85);
	expect(s.forecastUsd).toBeGreaterThan(s.knownUsd);
	const d22 = s.days.find((d) => d.day === "2026-11-22")!;
	expect(d22.macUsd).toBeCloseTo(0.75);
	expect(d22.cloudUsd).toBeCloseTo(0.1);
	expect(d22.top[0]).toEqual({ label: "Morning briefing", usd: 0.75 });
	expect(Object.fromEntries(s.groups.map((g) => [g.id, g.usd]))).toEqual({ build: 1.25, "automation:briefing": 0.75, conversations: expect.closeTo(0.6), "agent:rita": 0.25 });
	expect(s.groups.find((g) => g.id === "conversations")!.unknownCalls).toBe(1);
	expect(s.groups.reduce((n, g) => n + g.share, 0)).toBeCloseTo(1);

	const byModel = ledger.spend({ range: "month", groupBy: "model" }, names, now).groups;
	expect(byModel.map((g) => g.label)).toEqual(["anthropic/claude-sonnet-5.5 · openrouter", "some/unpriced · openrouter"]);
	expect(ledger.spend({ range: "month", groupBy: "project" }, names, now).groups.map((g) => [g.label, g.usd])).toEqual([["No project", expect.closeTo(1.6)], ["site", 1.25]]);
	expect(ledger.spend({ range: "month", groupBy: "where" }, names, now).groups.map((g) => g.label)).toEqual(["This Mac", "Cloud"]);
	// An agent's "$… this month" opens Spend filtered to it: its conversations and its runs.
	expect(ledger.spend({ range: "month", filter: { agent: "rita" } }, names, now).knownUsd).toBeCloseTo(1);
	expect(ledger.spend({ range: "month", filter: { place: "cloud" } }, names, now).knownUsd).toBeCloseTo(0.1);

	// A row opens what it counts, costliest first.
	ledger.recordItems({ ...chat, key: "t2", container: "t2", ref: { kind: "thread", id: "t2" }, title: "Taxes" }, [answer("m1", day(3), 2)]);
	const items = ledger.items({ range: "month", groupBy: "what", group: "conversations" }, names, now);
	expect(items.map((i) => [i.title, i.calls])).toEqual([["Taxes", 1], ["Trip", 2], ["Trip", 1]]);
	ledger.close();
});

test("a plan's requests are tokens, never dollars", () => {
	const ledger = new UsageLedger();
	ledger.planOf = (provider) => provider === "claude-code";
	ledger.recordItems(chat, [answer("a", day(5), 0, 4000, "claude-code/opus"), answer("b", day(5), 0.3)]);
	const s = ledger.spend({ range: "month", groupBy: "model" }, {}, now);
	expect(s).toMatchObject({ knownUsd: 0.3, planCalls: 1, unknownCalls: 0 });
	expect(s.groups.find((g) => g.id === "claude-code/opus")).toMatchObject({ plan: true, usd: 0, tokens: 4100 });
	ledger.close();
});

test("costs outside the turns are rows of their own; Piopio's own work is its own row", () => {
	const ledger = new UsageLedger();
	ledger.resolve = (scope) => (scope === "t1" ? chat : scope === "rita" ? rita("person:me") : undefined);
	ledger.recordExtra({ at: day(3), scope: "app", kind: "utility", model: "openrouter/google/gemini-flash", usd: 0.01 }, "x1");
	ledger.recordExtra({ at: day(3), scope: "t1", kind: "web_search", model: "deepseek/deepseek-v4.1-flash", usd: 0.02 }, "x2");
	ledger.recordExtra({ at: day(4), scope: "rita", kind: "embeddings", model: "text-embedding", usd: null }, "x3");
	ledger.recordExtra({ at: day(6), scope: "app", kind: "utility", model: "apple/on-device", usd: 0 });
	const s = ledger.spend({ range: "month" }, { agent: () => "Rita" }, now);
	expect(s.calls).toBe(4);
	expect(s.unknownCalls).toBe(1);
	expect(Object.fromEntries(s.groups.map((g) => [g.id, g.calls]))).toEqual({ piopio: 2, conversations: 1, "agent:rita": 1 });
	ledger.close();
});

test("ranges are local days; 12 months is by month; the forecast waits for day 5", () => {
	const { from, to } = rangeBounds("7d", now);
	expect(from.getDate()).toBe(17);
	expect(to.getDate()).toBe(24);
	const ledger = new UsageLedger();
	ledger.recordItems(chat, [answer("a", new Date(2026, 0, 15).toISOString(), 1), answer("b", day(2), 1)]);
	const year = ledger.spend({ range: "12m" }, {}, now);
	expect(year.days.map((d) => d.day)).toEqual(["2025-12", "2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09", "2026-10", "2026-11"]);
	expect(year.knownUsd).toBe(2);
	expect(ledger.spend({ range: "month" }, {}, new Date(2026, 10, 3)).forecastUsd).toBeUndefined();
	expect(ledger.csv("month", now).csv.split("\n")[1]).toMatch(/^.+,mac,turn,t1,,,,openrouter,openrouter\/anthropic\/claude-sonnet-5\.5,,1000,100,0,0,1,false$/);
	ledger.close();
});

test("a stored conversation's answers on every branch count, not only the one it shows", () => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-ledger-file-"));
	const sm = SessionManager.create(dir, dir);
	const usage = (input: number, usd: number) => ({ input, output: 50, cacheRead: 0, cacheWrite: 0, totalTokens: input + 50, cost: { input: usd, output: 0, cacheRead: 0, cacheWrite: 0, total: usd } });
	const said = (text: string, input: number, usd: number, at: number) => {
		sm.appendMessage({ role: "user", content: text, timestamp: at } as never);
		return sm.appendMessage({ role: "assistant", content: [{ type: "text", text: "ok" }], provider: "openrouter", model: "a/b", api: "openai-completions", usage: usage(input, usd), stopReason: "stop", timestamp: at + 1 } as never);
	};
	const first = said("one", 100, 0.1, Date.parse(day(4)));
	said("two", 200, 0.2, Date.parse(day(4, 11)));
	// Back to the first answer and on from there: "two" is on a branch you left.
	sm.branch(first);
	said("two, again", 210, 0.25, Date.parse(day(4, 12)));
	const file = sm.getSessionFile()!;
	const ref = { kind: "build" as const, id: "b9" };
	expect(fileItems(ref, { sessionFile: file }).filter((i) => i.kind === "assistant")).toHaveLength(2);
	const answers = fileAnswers({ sessionFile: file });
	expect(answers).toHaveLength(3);
	const ledger = new UsageLedger();
	const source = { ...build, key: "b9", container: "b9", ref };
	// What the session shows (live or reopened), then the whole file: the left branch is added, nothing twice.
	ledger.recordItems(source, fileItems(ref, { sessionFile: file }));
	expect(ledger.recordItems(source, answers, true)).toBe(1);
	// …and again, and what's shown again: still three requests.
	ledger.recordItems(source, answers, true);
	ledger.recordItems(source, fileItems(ref, { sessionFile: file }));
	expect(ledger.spend({ range: "month" }, {}, now)).toMatchObject({ calls: 3, knownUsd: expect.closeTo(0.55) });
	ledger.close();
});

// ── In the engine ──

beforeAll(() => {
	process.env.PIOPIO_FAKE_CLAUDE_CODE = "1";
	process.env.PIOPIO_FAKE_CLAUDE_KEY = "1";
});
afterAll(() => {
	delete process.env.PIOPIO_FAKE_CLAUDE_CODE;
	delete process.env.PIOPIO_FAKE_CLAUDE_KEY;
});

async function start(home: string) {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	return { client, stop: async () => (client.close(), await engine.stop()) };
}

async function idleWithAnswers(client: TestClient, ref: unknown, n: number): Promise<Snapshot> {
	for (let i = 0; i < 300; i++) {
		const s: Snapshot = await client.call("sessions.open", { ref });
		if (s.state.status === "idle" && s.items.filter((x) => x.kind === "assistant").length >= n) return s;
		await new Promise((r) => setTimeout(r, 30));
	}
	throw new Error("no answer");
}

test("Spend matches the conversation's own total, live and after a restart's backfill", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-ledger-"));
	const a = await start(home);
	const { ref } = await a.client.call("sessions.create", { kind: "thread", model: { provider: "claude-code", id: "opus" } });
	await a.client.call("sessions.submit", { ref, input: { text: "hello" } });
	await idleWithAnswers(a.client, ref, 1);
	await a.client.call("sessions.submit", { ref, input: { text: "again" } });
	const s = await idleWithAnswers(a.client, ref, 2);
	const live: SpendResult = await a.client.call("stats.spend", { range: "month" });
	expect(live.knownUsd).toBeCloseTo(s.state.usage.costUsd, 5);
	expect(live.groups.map((g) => g.id)).toEqual(["conversations"]);
	const { items } = await a.client.call("stats.items", { range: "month", groupBy: "what", group: "conversations" });
	expect(items).toMatchObject([{ ref: { kind: "thread", id: ref.id }, calls: 2 }]);
	await a.stop();

	const b = await start(home);
	const again: SpendResult = await b.client.call("stats.spend", { range: "month", groupBy: "model" });
	expect(again.calls).toBe(2);
	expect(again.knownUsd).toBeCloseTo(s.state.usage.costUsd, 5);
	const csv = await b.client.call("stats.export", { range: "month" });
	expect(csv.rows).toBe(2);
	expect(csv.csv).not.toContain("hello");
	await b.stop();
}, 60_000);

// extra-costs.db went into the ledger (re-audit 2026-11-25 P2): what Cost and an agent's budget read, from here.
test("known costs and missing prices stay apart, by conversation, by agent and in all", () => {
	const ledger = new UsageLedger();
	ledger.resolve = (scope) => (scope === "t1" ? chat : scope === "rita" ? rita("person:me") : undefined);
	ledger.recordCost("web_search", "model", 0.02, "t1");
	ledger.recordCost("web_search", "model", undefined, "t1");
	ledger.recordCost("utility", "model", Number.NaN, "t1");
	ledger.recordCost("embeddings", "model", 0.003);
	ledger.recordCost("utility", "model", 0.005, "rita");
	ledger.recordCost("utility", "model", 0.001, "gone");
	expect(ledger.costSummary("t1")).toMatchObject({ scope: "t1", calls: 3, knownUsd: 0.02, unknownCalls: 2 });
	expect(ledger.costSummary("rita")).toMatchObject({ calls: 1, knownUsd: 0.005 });
	// A scope nothing resolves (a conversation deleted since) still counts toward itself.
	expect(ledger.costSummary("gone")).toMatchObject({ calls: 1, knownUsd: 0.001 });
	expect(ledger.costSummary("other")).toMatchObject({ calls: 0, knownUsd: 0, unknownCalls: 0 });
	const all = ledger.costSummary();
	expect(all).toMatchObject({ scope: "app", calls: 6, unknownCalls: 2 });
	expect(all.knownUsd).toBeCloseTo(0.029);
	expect(all.breakdown.map((b) => b.kind).sort()).toEqual(["embeddings", "utility", "web_search"]);
	ledger.close();
});

test("an agent's costs for a month are read by range, the month's own and not the next one's", () => {
	const ledger = new UsageLedger();
	ledger.resolve = (scope) => (scope === "rita" ? rita("person:me") : undefined);
	for (const [at, usd] of [["2026-11-30T23:59:59.000Z", 1], ["2026-12-01T00:00:00.000Z", 2], ["2026-12-31T10:00:00.000Z", 3], ["2027-01-01T00:00:00.000Z", 4]] as const) {
		ledger.recordExtra({ at, scope: "rita", kind: "utility", model: "m", usd }, `r${at}`);
	}
	ledger.recordExtra({ at: "2026-12-02T00:00:00.000Z", scope: "rita", kind: "utility", model: "m", usd: null }, "unknown");
	ledger.recordExtra({ at: "2026-12-02T00:00:00.000Z", scope: "someone-else", kind: "utility", model: "m", usd: 9 }, "other");
	expect(ledger.costMonthUsd("rita", "2026-11")).toBe(1);
	expect(ledger.costMonthUsd("rita", "2026-12")).toBe(5);
	expect(ledger.costMonthUsd("rita", "2027-01")).toBe(4);
	expect(ledger.costMonthUsd("nobody", "2026-12")).toBe(0);
	ledger.close();
});
