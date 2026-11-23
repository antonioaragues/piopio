/** Piopio this month and Cheaper next time (docs/spec/34 OV4, decisions OV3 and OV7). */
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AssistantItem, ModelInfo } from "@piopio/protocol";
import { expect, test } from "vitest";
import { Automations } from "../src/automations/service.js";
import { MonthBudget } from "../src/budget.js";
import { type LedgerSource, rangeBounds, UsageLedger } from "../src/ledger.js";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { lighterModel, suggestions } from "../src/suggest.js";
import { TestClient } from "./client.js";

const chat: LedgerSource = { key: "t1", container: "t1", ref: { kind: "thread", id: "t1" }, title: "Trip", sourceKind: "thread", place: "mac" };
let n = 0;
const answer = (usd: number, at = new Date(), model = "openrouter/anthropic/claude-opus-5.5", tokens = { input: 10_000, output: 1000, cacheRead: 0 }): AssistantItem => ({
	kind: "assistant", id: `m${n++}`, at: at.toISOString(), parts: [], status: "done", model,
	usage: { inputTokens: tokens.input + n, outputTokens: tokens.output, cacheReadTokens: tokens.cacheRead, cacheWriteTokens: 0, costUsd: usd },
});

test("a monthly budget: off until set, says 80% and 100% once each, and holds background work at 100% until your yes", () => {
	const now = new Date(2026, 10, 23, 12);
	const ledger = new UsageLedger();
	const budget = new MonthBudget(undefined, ledger, () => now);
	const said: (string | undefined)[] = [];
	budget.onChange = (e) => said.push(e.notify);
	let released = 0;
	budget.releaseAll = () => void released++;

	ledger.recordItems(chat, [answer(7, now)]);
	expect(budget.state()).toMatchObject({ state: "off", spentUsd: 7, month: "2026-11" });
	expect(budget.holdReason()).toBeUndefined();

	budget.set(10);
	expect(budget.state().state).toBe("ok");
	ledger.recordItems(chat, [answer(1.5, now)]);
	budget.check();
	budget.check();
	expect(budget.state().state).toBe("near");
	expect(said.filter(Boolean)).toEqual(["Piopio has spent $8.50 of its $10.00 budget for November."]);

	ledger.recordItems(chat, [answer(2, now)]);
	budget.check();
	expect(budget.state().state).toBe("over");
	expect(said.filter(Boolean)).toHaveLength(2);
	expect(budget.holdReason()).toBe("Waiting: Piopio is past its $10.00 budget for November ($10.50 spent)");

	// Last month's spend isn't this month's.
	ledger.recordItems(chat, [answer(50, new Date(2026, 9, 30))]);
	expect(budget.state().spentUsd).toBeCloseTo(10.5);

	// Your yes for the month: background work goes on, and what was held runs.
	released = 0;
	budget.allowMonth();
	expect(budget.state().state).toBe("allowed");
	expect(budget.holdReason()).toBeUndefined();
	expect(released).toBe(1);
	ledger.close();
});

test("raising the budget past what's spent lets what it held run", () => {
	const ledger = new UsageLedger();
	const budget = new MonthBudget(undefined, ledger);
	let released = 0;
	budget.releaseAll = () => void released++;
	ledger.recordItems(chat, [answer(3)]);
	budget.set(2);
	expect(budget.state().state).toBe("over");
	expect(released).toBe(0);
	budget.set(5);
	expect(budget.state().state).toBe("ok");
	expect(released).toBe(1);
	expect(() => budget.set(0)).toThrow(/more than \$0/);
	budget.set(null);
	expect(budget.state().state).toBe("off");
	ledger.close();
});

test("past the budget an automation's run waits; Run now doesn't; your yes runs the held one as it would have", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-budget-auto-"));
	let hold: string | undefined = "Waiting: over budget";
	const ran: string[] = [];
	let heldChanges = 0;
	const service = new Automations({
		file: join(home, "automations.json"),
		runsFile: join(home, "automation-runs.json"),
		log: () => {},
		agent: () => undefined,
		project: () => undefined,
		runAgent: async () => ({ runId: "r", conversationId: "c", status: "done" }),
		runPiopio: async (_a, text) => (ran.push(text), `ses_${ran.length}`),
		changed: () => {},
		watchesChanged: () => {},
		hold: () => hold,
		heldChanged: () => void heldChanges++,
	});
	const a = service.add({ runsAs: "piopio", when: "0 9 * * 1", prompt: "Weekly brief" }, "you");
	const held = (await service.fire(a.id, "time", undefined, "2026-11-23T09:00"))!;
	expect(held).toMatchObject({ status: "waiting", summary: "Waiting: over budget" });
	expect(ran).toEqual([]);
	expect(service.heldRuns()).toEqual([{ run: held.id, automation: a.id, name: a.name, at: held.firedAt }]);
	expect(heldChanges).toBe(1);
	// The same time again isn't a second held run.
	await service.fire(a.id, "time", undefined, "2026-11-23T09:00");
	expect(service.heldRuns()).toHaveLength(1);

	// Run now is your yes already.
	expect((await service.fire(a.id, "now"))!.status).toBe("running");
	expect(ran).toHaveLength(1);

	hold = undefined;
	await service.release(held.id);
	expect(ran).toHaveLength(2);
	expect(ran[1]).toContain("Weekly brief");
	expect(service.heldRuns()).toEqual([]);
	const after = (await service.runsOf(a.id)).find((r) => r.id === held.id)!;
	expect(after).toMatchObject({ status: "running", conversation: "ses_2" });
	expect(JSON.parse(readFileSync(join(home, "automation-runs.json"), "utf8")).some((r: { held?: unknown }) => r.held)).toBe(false);
});

const model = (id: string, input: number, output: number, cacheRead = input / 10): ModelInfo => ({
	provider: "openrouter", id, name: id.split("/")[1]!, contextWindow: 200_000, maxOutputTokens: 32_000,
	pricing: { input, output, cacheRead, cacheWrite: input * 1.25 }, supports: { vision: true, reasoning: true },
});
const models = [model("anthropic/claude-opus-5.5", 15, 75), model("anthropic/claude-sonnet-5.5", 3, 15), model("anthropic/claude-haiku-5.5", 1, 5), model("anthropic/claude-haiku-4.5", 0.8, 4), model("openai/gpt-6.2", 2, 8)];

test("the lighter model is the same maker's light one, never a heavier one", () => {
	expect(lighterModel("openrouter/anthropic/claude-opus-5.5", models)?.id).toBe("anthropic/claude-haiku-5.5");
	expect(lighterModel("openrouter/anthropic/claude-haiku-5.5", models)).toBeUndefined();
	expect(lighterModel("openrouter/openai/gpt-6.2", models)).toBeUndefined();
	expect(lighterModel("openrouter/unknown/x", models)).toBeUndefined();
});

test("Cheaper next time: at most three, each with its number and one action; none without a number", () => {
	const now = new Date(2026, 10, 23, 12);
	const ledger = new UsageLedger();
	const briefing: LedgerSource = { ...chat, key: "rita/run:r1", container: "rita", ref: { kind: "agent", id: "rita", conversationId: "run:r1" }, sourceKind: "agent", agent: "rita", automation: "briefing" };
	// 20 runs of 10k in and 1k out on Opus: $0.225 each, $4.50; on Haiku 5.5 about $0.015 each.
	ledger.recordItems(briefing, Array.from({ length: 20 }, () => answer(0.225, now)));
	// A cache-heavy conversation: 2M cache reads on Sonnet saved (3 - 0.3) × 2 = $5.40.
	ledger.recordItems(chat, [answer(1, now, "openrouter/anthropic/claude-sonnet-5.5", { input: 1000, output: 100, cacheRead: 2_000_000 })]);
	ledger.recordExtra({ at: now.toISOString(), scope: "app", kind: "utility", model: "openrouter/anthropic/claude-sonnet-5.5", usd: 0.3 });
	const { from, to } = rangeBounds("month", now);
	const rows = ledger.rows(from, to);
	const names = { automation: (id: string) => (id === "briefing" ? "Morning briefing" : undefined) };
	const list = suggestions(rows, { models, names, onDeviceOffer: true, rangeLabel: "this month" });
	expect(list.map((s) => s.id)).toEqual(["cache", "lighter:automation:briefing", "on_device"]);
	expect(list[1]!.text).toMatch(/^Morning briefing spent \$4\.50 on claude-opus-5\.5 this month; claude-haiku-5\.5 would have been about \$0\.3\d$/);
	expect(list[1]!.action).toEqual({ kind: "automation", id: "briefing", label: "Change model" });
	expect(list[0]).toMatchObject({ text: "Cache reads saved about $5.40 this month", savingUsd: expect.closeTo(5.4) });
	expect(list[0]!.action).toBeUndefined();
	expect(list[2]!.action).toEqual({ kind: "on_device", label: "Use on-device" });
	// Without the on-device model, that one isn't offered; with nothing to save, nothing is.
	expect(suggestions(rows, { models, names, onDeviceOffer: false, rangeLabel: "this month" }).map((s) => s.id)).not.toContain("on_device");
	expect(suggestions([], { models, names, onDeviceOffer: true, rangeLabel: "this month" })).toEqual([]);
	ledger.close();
});

test("in the engine: set a budget, read it, turn it off; Spend carries suggestions", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-budget-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	try {
		expect((await client.call("stats.budgets", {})).piopio).toMatchObject({ state: "off", held: [] });
		expect(await client.call("stats.budget.set", { monthUsd: 25 })).toMatchObject({ state: "ok", limitUsd: 25 });
		expect(JSON.parse(readFileSync(join(home, "budget.json"), "utf8"))).toMatchObject({ limitUsd: 25 });
		await expect(client.call("stats.budget.set", { monthUsd: -1 })).rejects.toThrow(/more than \$0/);
		expect(await client.call("stats.budget.set", { monthUsd: null })).toMatchObject({ state: "off" });
		expect((await client.call("stats.spend", { range: "month" })).suggestions).toEqual([]);
	} finally {
		client.close();
		await engine.stop();
	}
});
