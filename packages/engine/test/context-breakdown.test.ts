import { expect, test } from "vitest";
import { scaleTo } from "../src/runtimes/context-breakdown.js";

test("the categories are scaled to pi's total and keep their shares", () => {
	const groups = [
		{ kind: "instructions" as const, tokens: 300, parts: [{ label: "Piopio guidelines", tokens: 300 }] },
		{ kind: "conversation" as const, tokens: 700, parts: [{ label: "Your messages", tokens: 500 }, { label: "Thinking", tokens: 200 }] },
	];
	const scaled = scaleTo(groups, 2_000);
	expect(scaled.map((g) => g.tokens)).toEqual([600, 1_400]);
	expect(scaled[1]!.parts).toEqual([{ label: "Your messages", tokens: 1_000 }, { label: "Thinking", tokens: 400 }]);
	expect(scaleTo(groups, 500).reduce((n, g) => n + g.tokens, 0)).toBe(500);
});

test("nothing to spread leaves the estimates as they are", () => {
	expect(scaleTo([], 1_000)).toEqual([]);
	const empty = [{ kind: "tools" as const, tokens: 0, parts: [] }];
	expect(scaleTo(empty, 1_000)).toBe(empty);
});
