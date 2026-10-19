import { describe, expect, test } from "vitest";
import { computeBranches, type ConversationNode, type ViewEntry } from "../src/runtimes/branches.js";
import { describeModelError } from "../src/timeline/errors.js";

const e = (id: number, kind: string, conversationId: number): ViewEntry => ({ id: String(id), kind, conversationId: String(conversationId) });
const c = (id: number, parent?: [number, number]): ConversationNode => ({ id: String(id), ...(parent ? { parent: { conversationId: String(parent[0]), at: String(parent[1]) } } : {}) });

describe("computeBranches", () => {
	// root 1: 7 user, 10 answer, 11 user, 14 answer. Fork 15 at 10 (edited 11 → 21, 24). Fork 30 from 15 at 10 again.
	const conversations = [c(1), c(15, [1, 10]), c(30, [15, 10])];

	test("an edited message shows its position among the versions", () => {
		const view = [e(7, "pi.user", 1), e(10, "pi.assistant", 1), e(21, "pi.user", 15), e(24, "pi.assistant", 15)];
		const branches = computeBranches("15", view, conversations, {});
		expect(branches.get("21")).toEqual({ index: 1, count: 3, previous: "1", next: "30" });
		expect(branches.has("7")).toBe(false);
	});

	test("the original shows the switcher too", () => {
		const view = [e(7, "pi.user", 1), e(10, "pi.assistant", 1), e(11, "pi.user", 1), e(14, "pi.assistant", 1)];
		expect(computeBranches("1", view, conversations, {}).get("11")).toEqual({ index: 0, count: 3, next: "15" });
	});

	test("switching lands on the most recently active continuation of a version", () => {
		// 40 continues version 15 after a later point (24); it was active more recently than 15 itself.
		const all = [...conversations, c(40, [15, 24])];
		const view = [e(7, "pi.user", 1), e(10, "pi.assistant", 1), e(11, "pi.user", 1), e(14, "pi.assistant", 1)];
		expect(computeBranches("1", view, all, { "15": 1, "40": 2 }).get("11")?.next).toBe("40");
	});

	test("editing the first message groups parentless conversations", () => {
		const view = [e(50, "pi.user", 45), e(52, "pi.assistant", 45)];
		expect(computeBranches("45", view, [c(1), c(45)], {}).get("50")).toEqual({ index: 1, count: 2, previous: "1" });
	});
});

test("model errors become actionable messages", () => {
	expect(describeModelError('401 {"error":{"message":"User not found."}}').kind).toBe("auth");
	expect(describeModelError("402 Payment Required").kind).toBe("credits");
	expect(describeModelError("429 Too Many Requests").kind).toBe("rate_limit");
	expect(describeModelError("503 upstream overloaded").message).toContain("(503)");
	expect(describeModelError("TypeError: fetch failed").kind).toBe("network");
	expect(describeModelError("400 This model's maximum context length is 8192 tokens").kind).toBe("context");
	expect(describeModelError("something odd\nmore").message).toBe("something odd");
});
