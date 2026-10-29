import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { DebateItem, SessionEventsNotification, Snapshot } from "@piopio/protocol";
import { afterEach, expect, test, vi } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// Each turn is a scripted model run; a debate takes a few seconds.
vi.setConfig({ testTimeout: 60_000 });

type Ctx = { home: string; engine: Engine; client: TestClient };
const open: Ctx[] = [];

async function start(home = mkdtempSync(join(tmpdir(), "piopio-debate-"))): Promise<Ctx> {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), hooksPort: 0, allowPrivateFetch: true, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0" });
	const ctx = { home, engine, client };
	open.push(ctx);
	return ctx;
}

async function stop(ctx: Ctx) {
	ctx.client.close();
	await ctx.engine.stop();
	open.splice(open.indexOf(ctx), 1);
}

afterEach(async () => {
	for (const ctx of [...open]) await stop(ctx);
});

const faux = { provider: "faux", id: "faux-1" };
const participants = [
	{ role: "author", model: faux },
	{ role: "reviewer", model: faux },
];
/** A line the scripted model turns into a tool call when it reads it. */
const call = (tool: string, args: unknown) => `call: ${tool} | ${JSON.stringify(args)}`;

/**
 * A review that agrees in round 2: each side's words carry the other's next tool call, so the scripted model plays
 * both. The author's v1 gets an objection (O1), v2 fixes it and the reviewer approves.
 */
function agreeingGoal() {
	const approve = call("debate_review", { objections: [{ id: "O1", text: "Add a rollback plan", severity: "blocking", status: "resolved", note: "Covered now" }], approve: true });
	const revise = call("debate_submit", { draft: `Migration plan v2, with rollback\n${approve}`, changes: ["O1: added a rollback section"] });
	const object = call("debate_review", { objections: [{ text: `Add a rollback plan\n${revise}`, severity: "blocking", status: "open" }], approve: false });
	return call("debate_submit", { draft: `Migration plan v1\n${object}`, changes: [] });
}

const debateStatus = (subscriptionId: string, status: string) => (n: SessionEventsNotification) =>
	n.subscriptionId === subscriptionId && n.events.some((e) => (e.type === "state" && e.state.debate?.status === status && e.state.status === "idle") || (e.type === "resnapshot" && e.snapshot.state.debate?.status === status && e.snapshot.state.status === "idle"));

const debateItems = (s: Snapshot) => s.items.filter((i): i is DebateItem => i.kind === "debate").map((i) => `${i.event}:${i.title}`);

test("a review agrees in round 2, shows each turn, and goes on as a chat with the author after a restart", async () => {
	const a = await start();
	const goal = agreeingGoal();
	const { ref } = await a.client.call("sessions.create", { kind: "thread", debate: { style: "review", goal, criteria: "Covers rollback", participants, maxRounds: 4 } });
	const sub = await a.client.call("sessions.subscribe", { ref });
	await a.client.waitFor(debateStatus(sub.subscriptionId, "agreed"), 40_000);

	const s: Snapshot = await a.client.call("sessions.open", { ref });
	const debate = s.state.debate!;
	expect(debate.status).toBe("agreed");
	expect(debate.drafts.map((d) => [d.version, d.round, d.text.split("\n")[0]])).toEqual([
		[1, 1, "Migration plan v1"],
		[2, 2, "Migration plan v2, with rollback"],
	]);
	expect(debate.objections.map((o) => [o.id, o.status, o.severity])).toEqual([["O1", "resolved", "blocking"]]);
	expect(debate.objections[0]!.history.map((h) => h.action)).toEqual(["raised", "resolved"]);
	expect(debate.participants.map((p) => p.label)).toEqual(["Faux Model (author)", "Faux Model (reviewer)"]);
	expect(debateItems(s)).toEqual([
		"round:Round 1",
		"turn:Draft v1",
		"turn:1 objection open · 1 blocking",
		"round:Round 2",
		"turn:Draft v2 · 1 change",
		"turn:Approved",
		"result:Agreed after 2 rounds",
	]);
	// The goal is the first message; the tool calls show only as turn summaries.
	expect(s.items[1]).toMatchObject({ kind: "user", text: goal });
	expect(s.items.some((i) => i.kind === "tool" && i.tool.startsWith("debate_"))).toBe(false);
	const result = s.items.find((i): i is DebateItem => i.kind === "debate" && i.event === "result")!;
	expect(result.draft?.startsWith("Migration plan v2")).toBe(true);
	const [summary] = (await a.client.call("sessions.list")).sessions;
	expect(summary.debate).toEqual({ status: "agreed" });
	expect(summary.title).toMatch(/^call: debate/); // titled from the goal

	// After the result, you talk to the author.
	const before = a.client.events.length;
	await a.client.call("sessions.submit", { ref, input: { text: "make it shorter" } });
	await a.client.waitFor((n) => a.client.events.indexOf(n) >= before && n.events.some((e) => (e.type === "item.added" || e.type === "item.updated" || e.type === "item.replaced") && e.item.kind === "assistant" && e.item.status === "done" && e.item.parts.some((p) => p.text === "Echo: make it shorter")), 20_000);
	const chat: Snapshot = await a.client.call("sessions.open", { ref });
	const answer = chat.items.at(-1)!;
	expect(answer).toMatchObject({ kind: "assistant", speaker: { role: "author" } });
	expect(chat.items.at(-2)).toMatchObject({ kind: "user", text: "make it shorter" });

	await stop(a);
	const b = await start(a.home);
	const reopened: Snapshot = await b.client.call("sessions.open", { ref });
	expect(reopened.items.map((i) => i.id)).toEqual(chat.items.map((i) => i.id));
	expect(reopened.state.debate?.status).toBe("agreed");
	expect(reopened.state.usage).toEqual(chat.state.usage);
});

test("a nudge, the round limit, Keep going and a note from you", async () => {
	const a = await start();
	// One round: the reviewer objects, so it ends without agreement; Keep going adds a round where it agrees.
	const { ref } = await a.client.call("sessions.create", { kind: "thread", debate: { style: "review", goal: agreeingGoal(), participants, maxRounds: 1 } });
	const sub = await a.client.call("sessions.subscribe", { ref });
	await a.client.call("sessions.submit", { ref, input: { text: "Keep it under a page" } });
	await a.client.waitFor(debateStatus(sub.subscriptionId, "no_agreement"), 40_000);
	let s: Snapshot = await a.client.call("sessions.open", { ref });
	expect(s.state.debate?.reason).toBe("reached the round limit (1) with 1 objection open");
	expect(s.state.debate?.objections.map((o) => o.status)).toEqual(["open"]);
	expect(s.items.some((i) => i.kind === "user" && i.text === "Keep it under a page")).toBe(true);
	expect(s.state.queue).toEqual([]);

	await a.client.call("sessions.debate.continue", { ref, rounds: 2 });
	await a.client.waitFor(debateStatus(sub.subscriptionId, "agreed"), 40_000);
	s = await a.client.call("sessions.open", { ref });
	expect(s.state.debate?.maxRounds).toBe(3);
	expect(debateItems(s).filter((t) => t.startsWith("result:"))).toEqual(["result:No agreement after 1 round", "result:Agreed after 2 rounds"]);

	// An author that never calls its tool is asked once more, then the debate stops: there's nothing to review.
	const { ref: silent } = await a.client.call("sessions.create", { kind: "thread", debate: { style: "review", goal: "Write a haiku about rain", participants, maxRounds: 3 } });
	const sub2 = await a.client.call("sessions.subscribe", { ref: silent });
	await a.client.waitFor(debateStatus(sub2.subscriptionId, "stopped"), 40_000);
	const t: Snapshot = await a.client.call("sessions.open", { ref: silent });
	expect(t.state.debate?.reason).toBe("Faux Model (author) didn't submit a draft");
	expect(t.items.filter((i) => i.kind === "assistant").map((i) => (i.kind === "assistant" ? i.parts.map((p) => p.text).join("") : ""))).toEqual([
		expect.stringContaining("Echo: The user's goal"),
		"Echo: End your turn by calling debate_submit.",
	]);
	expect(debateItems(t)).toEqual(["round:Round 1", "turn:No draft this turn", "result:Stopped in round 1"]);
});

test("rejects a debate without a goal or with an unknown model, and stop ends one that's running", async () => {
	const a = await start();
	await expect(a.client.call("sessions.create", { kind: "thread", debate: { style: "review", goal: " ", participants, maxRounds: 3 } })).rejects.toMatchObject({ data: { code: "INVALID" } });
	await expect(a.client.call("sessions.create", { kind: "thread", debate: { style: "review", goal: "x", participants: [participants[0], { role: "reviewer", model: { provider: "faux", id: "nope" } }], maxRounds: 3 } })).rejects.toMatchObject({ data: { code: "INVALID" } });

	const { ref } = await a.client.call("sessions.create", { kind: "thread", debate: { style: "review", goal: agreeingGoal(), participants, maxRounds: 4 } });
	await a.client.call("sessions.subscribe", { ref });
	await a.client.call("sessions.debate.stop", { ref });
	const s: Snapshot = await a.client.call("sessions.open", { ref });
	expect(s.state.debate?.status).toBe("stopped");
	expect(s.state.status).toBe("idle");
	expect(debateItems(s).at(-1)).toMatch(/^result:Stopped in round \d/);
	await expect(a.client.call("sessions.debate.stop", { ref })).resolves.toEqual({});
});
