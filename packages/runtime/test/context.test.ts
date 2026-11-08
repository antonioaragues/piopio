import { describe, expect, test } from "vitest";
import { clockLine, formatGap, localDate, stampMessages } from "../src/context/clock.js";
import { remindRepeats, stableJson } from "../src/context/repeats.js";
import { keepEnds } from "../src/context/spill.js";
import { trimResult } from "../src/context/extension.js";

const at = (iso: string) => Date.parse(iso);
const user = (text: string, iso: string) => ({ role: "user", content: text, timestamp: at(iso) });
const answer = (iso: string) => ({ role: "assistant", content: [{ type: "text", text: "ok" }], timestamp: at(iso) });

describe("clock", () => {
	test("the local date, not UTC's: past midnight in Madrid is already tomorrow", () => {
		expect(localDate(at("2026-11-08T23:30:00Z"), "Europe/Madrid")).toBe("2026-11-09");
		expect(localDate(at("2026-11-08T23:30:00Z"), "UTC")).toBe("2026-11-08");
		expect(clockLine(at("2026-11-08T13:05:00Z"), "Europe/Madrid")).toBe("[Sent Sun 8 Nov 2026, 14:05 (Europe/Madrid)]");
	});

	test("gaps read in the largest sensible unit", () => {
		expect(formatGap(30_000)).toBeUndefined();
		expect(formatGap(25 * 60_000)).toBe("25 minutes");
		expect(formatGap(60 * 60_000)).toBe("1 hour");
		expect(formatGap(3 * 24 * 3600_000)).toBe("3 days");
	});

	test("stamps the first message, one after a pause and a new day; not quick replies", () => {
		const messages = [
			user("hi", "2026-11-08T10:00:00Z"),
			answer("2026-11-08T10:00:05Z"),
			user("and this?", "2026-11-08T10:02:00Z"),
			answer("2026-11-08T10:02:05Z"),
			user("back again", "2026-11-11T09:00:00Z"),
		];
		const out = stampMessages(messages, "Europe/Madrid");
		expect(out[0]!.content).toBe("[Sent Sun 8 Nov 2026, 11:00 (Europe/Madrid)]\n\nhi");
		expect(out[2]).toBe(messages[2]);
		expect(out[4]!.content).toBe("[Sent Wed 11 Nov 2026, 10:00 (Europe/Madrid), 2 days after the previous message]\n\nback again");
		expect(messages[0]!.content).toBe("hi"); // not mutated
		// The same history always reads the same (the provider's prompt cache stays warm).
		expect(stampMessages(messages, "Europe/Madrid")).toEqual(out);
	});

	test("array content gets a leading text block; nothing to stamp returns the same array", () => {
		const m = [{ role: "user", content: [{ type: "text", text: "look" }], timestamp: at("2026-11-08T10:00:00Z") }];
		expect(stampMessages(m, "UTC")[0]!.content).toEqual([{ type: "text", text: "[Sent Sun 8 Nov 2026, 10:00 (UTC)]" }, { type: "text", text: "look" }]);
		const none = [answer("2026-11-08T10:00:00Z")];
		expect(stampMessages(none, "UTC")).toBe(none);
	});
});

describe("repeated calls", () => {
	const call = (id: string, args: object) => ({ role: "assistant", content: [{ type: "toolCall", id, name: "bash", arguments: args }] });
	const result = (id: string) => ({ role: "toolResult", toolCallId: id, content: [{ type: "text", text: "same error" }] });

	test("the 3rd identical call's result gets a note; argument order doesn't matter", () => {
		expect(stableJson({ b: 1, a: [2, { d: 1, c: 0 }] })).toBe(stableJson({ a: [2, { c: 0, d: 1 }], b: 1 }));
		const messages = [user("fix it", "2026-11-08T10:00:00Z"), call("1", { command: "npm test", t: 1 }), result("1"), call("2", { t: 1, command: "npm test" }), result("2"), call("3", { command: "npm test", t: 1 }), result("3")];
		const out = remindRepeats(messages);
		expect(out[2]).toBe(messages[2]);
		expect(out[4]).toBe(messages[4]);
		const last = out[6]!.content as { text: string }[];
		expect(last.at(-1)!.text).toContain("call number 3 to bash");
	});

	test("a new user message starts the count again", () => {
		const messages = [call("1", { command: "ls" }), result("1"), call("2", { command: "ls" }), result("2"), user("try again", "2026-11-08T10:00:00Z"), call("3", { command: "ls" }), result("3")];
		expect(remindRepeats(messages)).toBe(messages);
	});
});

describe("oversized results", () => {
	test("keeps both ends at line breaks and says what was cut", () => {
		const lines = Array.from({ length: 5000 }, (_, i) => `line ${i}`);
		const kept = keepEnds(lines.join("\n"), { maxLines: 300 });
		expect(kept.cut).toBe(true);
		expect(kept.text.startsWith("line 0\nline 1\n")).toBe(true);
		expect(kept.text.endsWith("line 4999")).toBe(true);
		expect(kept.text).toContain("4,700 lines");
		expect(keepEnds("short").cut).toBe(false);
	});

	test("one huge line keeps characters; small results stay as they are", () => {
		const kept = keepEnds("x".repeat(100_000), { maxChars: 3000 });
		expect(kept.text.length).toBeLessThan(3200);
		expect(kept.text).toContain("97,000 characters cut from the middle");
		expect(trimResult({ output: [{ type: "text", text: "fine" }] })).toBeUndefined();
		const trimmed = trimResult({ output: [{ type: "text", text: "a\n".repeat(30_000) }] });
		expect(trimmed?.output?.[0]).toMatchObject({ type: "text" });
	});
});
