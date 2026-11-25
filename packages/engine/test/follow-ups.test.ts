import { expect, test } from "vitest";
import type { TimelineItem } from "@piopio/protocol";
import { FOLLOW_UPS_PROMPT, followUpsFit, parseFollowUps } from "../src/sessions.js";

test("Ask next: suggestions only when the answer calls for a reply; [] means none", () => {
	expect(FOLLOW_UPS_PROMPT).toContain("[] for none");
	expect(FOLLOW_UPS_PROMPT).toContain("a finished task");
	expect(parseFollowUps("[]")).toEqual([]);
	expect(parseFollowUps('["Sí, arréglalo", " ", "No", "Más", "Cuatro"]')).toEqual(["Sí, arréglalo", "No", "Más"]);
	expect(parseFollowUps("not json")).toBeUndefined();
	expect(parseFollowUps('{"a":1}')).toBeUndefined();
});

test("Ask next: none after a card that asks already, nor after a note the user didn't write", () => {
	const at = "2026-11-17T10:00:00.000Z";
	const user = (text: string) => ({ kind: "user", id: `u${text.length}`, at, text }) as TimelineItem;
	const answer = { kind: "assistant", id: "a1", at, status: "done", parts: [{ type: "text", text: "Which one?" }] } as unknown as TimelineItem;
	const tool = (name: string) => ({ kind: "tool", id: `t-${name}`, at, callId: name, tool: name, status: "done" }) as unknown as TimelineItem;
	expect(followUpsFit([user("Fix it"), answer])).toBe(true);
	expect(followUpsFit([user("Design a dating app"), tool("side_offer"), answer])).toBe(false);
	expect(followUpsFit([user("Plan it"), tool("ask_user")])).toBe(false);
	expect(followUpsFit([user("Plan it"), { kind: "steps", id: "s1", at, tools: [tool("propose_plan")] } as unknown as TimelineItem, answer])).toBe(false);
	// An earlier turn's card doesn't count.
	expect(followUpsFit([user("Design a dating app"), tool("side_offer"), user("Now the protocol"), answer])).toBe(true);
	expect(followUpsFit([user("[Side] “About page” (bld_1) finished."), answer])).toBe(false);
	// An automation's run: nobody asked, so nobody's waiting to reply (until you write in it yourself).
	expect(followUpsFit([user("[Automation] “Morning brief” (every day at 8:00). Nobody started this conversation"), answer])).toBe(false);
	expect(followUpsFit([user("[Automation] “Morning brief”"), answer, user("Add the weather"), answer])).toBe(true);
	expect(followUpsFit([answer])).toBe(false);
});
