import { expect, test } from "vitest";
import { goalExtension, MAX_COST_USD } from "../src/goal.js";

/** A stand-in for pi's API: the handlers and the command, the notes the goal writes, and a branch whose cost we set. */
function harness() {
	const handlers: Record<string, ((event: object, ctx: object) => unknown)[]> = {};
	const commands: Record<string, { handler: (args: string, ctx: object) => Promise<void> }> = {};
	const notes: string[] = [];
	const sent: string[] = [];
	const branch: object[] = [];
	const ctx = { sessionManager: { getBranch: () => branch }, ui: { notify: () => {} } };
	goalExtension()({
		on: (name: string, fn: (event: object, ctx: object) => unknown) => (handlers[name] ??= []).push(fn),
		registerCommand: (name: string, c: { handler: (args: string, ctx: object) => Promise<void> }) => (commands[name] = c),
		registerTool: () => {},
		appendEntry: (customType: string, data: unknown) => branch.push({ type: "custom", customType, data }),
		sendMessage: (m: { content: string }, o: { triggerTurn: boolean }) => (o.triggerTurn ? sent : notes).push(m.content),
		sendUserMessage: (text: string) => sent.push(text),
	} as never);
	const spend = (usd: number) => branch.push({ type: "message", message: { role: "assistant", usage: { cost: { total: usd } } } });
	const settle = () => {
		for (const fn of handlers.agent_before_settle ?? []) fn({ outcome: "completed" }, ctx);
		for (const fn of handlers.agent_settled ?? []) fn({ aborted: false }, ctx);
	};
	return { goal: (args: string) => commands.goal!.handler(args, ctx), spend, settle, notes, sent };
}

test("a goal stops at its budget of this session's model spend, counted from when it was set; continue gives it more", async () => {
	const h = harness();
	h.spend(10); // spent before the goal: not counted
	await h.goal("make the tests pass");
	expect(h.notes[0]).toContain(`up to 25 rounds or $${MAX_COST_USD.toFixed(2)}`);
	h.spend(3);
	h.settle();
	expect(h.sent.at(-1)).toContain("Round 2 of 25");
	h.spend(3);
	h.settle();
	expect(h.notes.at(-1)).toBe("Goal stopped at its budget: $6.00 spent, of $5.00, without being done. /goal continue gives it another $5.00.");
	const rounds = h.sent.length;
	h.settle(); // stopped: no more rounds
	expect(h.sent.length).toBe(rounds);
	await h.goal("continue");
	h.spend(1);
	h.settle();
	expect(h.sent.at(-1)).toContain("Keep going toward the goal");
	expect(h.notes.at(-1)).not.toContain("Goal stopped");
});
