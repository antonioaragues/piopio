import { expect, test } from "vitest";
import { FailureGuard, FAILS_BEFORE_STOP } from "../src/context/failures.js";
import { memoryText } from "../src/agents/core.js";
import type { MemoryRecord } from "../src/memory/provider.js";

// docs/spec/27 §13: twenty `automate` calls in one turn, each with other arguments and the same error.
const fail = (text: string) => ({ output: [{ type: "text" as const, text }], isError: true });
const user = (text: string, timestamp: number) => [{ role: "user", timestamp, content: text }];

test("a tool failing the same way three times is told to stop, then blocked, and blocked calls end the run", () => {
	const g = new FailureGuard();
	g.request("c1", user("set my reminders", 1));
	const err = "No time: say when in the when field";
	expect(g.after("c1", { id: "1", name: "automate" }, fail(err))).toBeUndefined();
	// Another error, or another tool, counts on its own.
	expect(g.after("c1", { id: "2", name: "automate" }, fail("Budget reached"))).toBeUndefined();
	expect(g.after("c1", { id: "3", name: "remember" }, fail(err))).toBeUndefined();
	expect(g.after("c1", { id: "4", name: "automate" }, fail(err))).toBeUndefined();
	const third = g.after("c1", { id: "5", name: "automate" }, fail(err))!;
	expect(JSON.stringify(third.output)).toContain(`automate failed ${FAILS_BEFORE_STOP} times this turn`);
	expect(third.control?.terminate).toBeUndefined();

	// Stopped: the next calls are blocked; the second blocked one ends the run.
	expect(g.before("c1", { id: "6", name: "automate" })).toContain("Not run: automate already failed 3 times");
	expect(g.before("c1", { id: "6b", name: "list_automations" })).toBeUndefined();
	expect(g.after("c1", { id: "6", name: "automate" }, fail("blocked"))).toBeUndefined();
	g.before("c1", { id: "7", name: "automate" });
	expect(g.after("c1", { id: "7", name: "automate" }, fail("blocked"))?.control?.terminate).toBe(true);

	// Another conversation is untouched; a new message starts over (the same request again doesn't).
	expect(g.before("c2", { id: "8", name: "automate" })).toBeUndefined();
	g.request("c1", user("set my reminders", 1));
	expect(g.before("c1", { id: "9", name: "automate" })).toBeDefined();
	g.request("c1", user("try again, with a date", 2));
	expect(g.before("c1", { id: "10", name: "automate" })).toBeUndefined();
});

test("a success doesn't count, and a tool that works isn't stopped by its earlier failures alone", () => {
	const g = new FailureGuard();
	g.request("c", user("go", 1));
	g.after("c", { id: "1", name: "web_search" }, fail("timeout"));
	g.after("c", { id: "2", name: "web_search" }, { output: [{ type: "text", text: "results" }] });
	g.after("c", { id: "3", name: "web_search" }, fail("timeout"));
	expect(g.before("c", { id: "4", name: "web_search" })).toBeUndefined();
});

test("memory reads as current facts, with their ids, then earlier messages as said then", () => {
	const r = (id: string, kind: MemoryRecord["kind"], text: string): MemoryRecord => ({ id, kind, text, createdBy: "agent", at: "2026-11-21T10:00:00Z" });
	const text = memoryText([r("m1", "message", "Coche: ITV booked for 2 Dec"), r("f1", "fact", "ITV passed; next due 21 Nov 2028")]);
	expect(text).toBe("- (f1) [2026-11-21] ITV passed; next due 21 Nov 2028\n\nEarlier messages, as said then (where a fact above says otherwise, the fact is current):\n- [2026-11-21] Coche: ITV booked for 2 Dec");
	expect(memoryText([r("m1", "message", "hi")], true)).toBe("Earlier messages, as said then (where a fact above says otherwise, the fact is current):\n- (m1) [2026-11-21] hi");
	expect(memoryText([])).toBe("");
});
