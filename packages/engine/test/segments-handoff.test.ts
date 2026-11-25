import { expect, test } from "vitest";
import type { Runtime, SubmitOptions } from "../src/runtimes/runtime.js";
import { SegmentedRuntime } from "../src/runtimes/segments.js";

// Re-audit 2026-11-25 §5.2: the summary for the first message after a switch was dropped before the message went, so
// when that message failed (no key, a network error) the new assistant never got what was said before.

test("the handoff summary stays for the next message when the first one fails, and goes once", async () => {
	const sent: SubmitOptions[] = [];
	let fail = true;
	const inner = {
		ref: { kind: "thread", id: "thr_1" },
		snapshot: () => ({ items: [], state: {} }),
		onEvents: () => () => {},
		submit: async (_text: string, options: SubmitOptions) => {
			sent.push(options);
			if (fail) throw new Error("no key");
			return { disposition: "started" as const };
		},
	} as unknown as Runtime;
	let marked = 0;
	const r = new SegmentedRuntime(inner, [], { summary: "what was said", sent: () => void marked++, from: { provider: "faux", id: "faux-1" } });
	await expect(r.submit("hi", { whenBusy: "followUp" })).rejects.toThrow("no key");
	expect(marked).toBe(0);
	expect(r.snapshot().state.handoff).toEqual({ from: { provider: "faux", id: "faux-1" } });
	fail = false;
	await r.submit("hi again", { whenBusy: "followUp" });
	await r.submit("and again", { whenBusy: "followUp" });
	expect(sent.map((o) => o.attachments?.map((a) => a.name) ?? [])).toEqual([["Conversation so far.md"], ["Conversation so far.md"], []]);
	expect(marked).toBe(1);
	expect(r.snapshot().state.handoff).toBeUndefined();
});
