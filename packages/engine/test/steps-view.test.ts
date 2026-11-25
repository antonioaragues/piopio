/**
 * The folded view a subscriber gets (StepsView following the events itself, without copying the conversation): after
 * every batch, what the client builds from the events is the fold of the conversation as it is.
 */
import type { SessionEvent, TimelineItem } from "@piopio/protocol";
import { expect, test } from "vitest";
import { TimelineBuilder } from "@piopio/runtime";
import { groupSteps, StepsView } from "../src/timeline/steps.js";

/** What the app does with the events it receives. */
function applyAll(items: TimelineItem[], events: readonly SessionEvent[]): TimelineItem[] {
	let out = items.map((i) => structuredClone(i));
	const at = (id: string) => out.findIndex((i) => i.id === id);
	for (const e of JSON.parse(JSON.stringify(events)) as SessionEvent[]) {
		if (e.type === "resnapshot") out = e.snapshot.items;
		else if (e.type === "item.added") {
			const b = e.before ? at(e.before) : -1;
			if (b >= 0) out.splice(b, 0, e.item);
			else out.push(e.item);
		} else if (e.type === "item.updated") out[at(e.item.id)] = e.item;
		else if (e.type === "item.replaced") out[at(e.oldId)] = e.item;
		else if (e.type === "item.removed") out.splice(at(e.itemId), 1);
		else if (e.type === "item.delta") {
			const item = out[at(e.itemId)];
			if (item?.kind !== "assistant") throw new Error(`delta for ${e.itemId}, not shown as an answer`);
			const part = item.parts[e.partIndex];
			if (part) part.text += e.textDelta;
			else item.parts[e.partIndex] = { type: e.partType, text: e.textDelta };
		}
	}
	return out;
}

const assistant = (content: unknown[], stopReason = "stop") => ({ role: "assistant", content, stopReason, timestamp: Date.now(), provider: "p", model: "m" }) as never;

/** Two turns of a Build conversation, a step at a time: answers that stream, think, call tools and get renamed. */
function script(b: TimelineBuilder): (() => void)[] {
	const steps: (() => void)[] = [];
	for (const turn of [0, 1]) {
		steps.push(() => b.user(`u${turn}`, `Do thing ${turn}`));
		for (let k = 0; k < 3; k++) {
			const id = `a${turn}_${k}`;
			steps.push(() => b.assistantStart(id));
			steps.push(() => b.assistantDelta(0, "thinking", "Let me "));
			steps.push(() => b.assistantDelta(0, "thinking", "look."));
			steps.push(() => b.assistantEnd(assistant([{ type: "thinking", thinking: "Let me look." }]), k === 1 ? `${id}_final` : undefined));
			const call = `c${turn}_${k}`;
			steps.push(() => b.toolStart(call, k === 2 ? "show_visual" : "bash", { command: `ls ${k}` }));
			steps.push(() => b.toolOutput(call, { append: "line one\n" }));
			steps.push(() => b.toolOutput(call, { append: "line two\n" }));
			steps.push(() => b.toolEnd(call, "line one\nline two\n", k === 1, 12));
		}
		steps.push(() => b.assistantStart(`t${turn}`));
		for (const piece of ["Here ", "is ", "what ", "I found."]) steps.push(() => b.assistantDelta(0, "text", piece));
		steps.push(() => b.assistantEnd(assistant([{ type: "text", text: "Here is what I found." }])));
		steps.push(() => b.checkpoint({ kind: "checkpoint", id: `cp${turn}`, at: new Date().toISOString() } as never, `u${turn}`));
		if (turn === 0) steps.push(() => b.resnapshot());
	}
	return steps;
}

test.each([1, 2, 3, 5, 8])("the folded events rebuild the fold of the conversation, in batches of %i", (size) => {
	const b = new TimelineBuilder({ kind: "build", id: "s" });
	const view = new StepsView();
	let shown = view.snapshot(b.snapshot().items);
	const steps = script(b);
	for (let i = 0; i < steps.length; i += size) {
		for (const step of steps.slice(i, i + size)) step();
		shown = applyAll(shown, view.events(b.flush()));
		expect(shown).toEqual(JSON.parse(JSON.stringify(groupSteps(b.snapshot().items))));
	}
	// Folded for real: each turn's calls are steps lines, not one item per call.
	expect(shown.filter((i) => i.kind === "steps").length).toBeGreaterThan(0);
	expect(shown.some((i) => i.kind === "tool")).toBe(false);
});

test("an item the batch didn't change isn't sent again", () => {
	const b = new TimelineBuilder({ kind: "build", id: "s" });
	b.user("u0", "Hi");
	b.assistantStart("a0");
	b.assistantDelta(0, "text", "Hello");
	b.assistantEnd(assistant([{ type: "text", text: "Hello" }]));
	b.flush();
	const view = new StepsView();
	view.snapshot(b.snapshot().items);
	b.toolStart("c1", "bash", { command: "ls" });
	expect(view.events(b.flush()).map((e) => e.type)).toEqual(["item.added"]);
	b.toolOutput("c1", { append: "x" });
	const out = view.events(b.flush());
	expect(out.map((e) => [e.type, "item" in e ? e.item.id : ""])).toEqual([["item.updated", "steps:tool:c1"]]);
	// Text streamed into an answer goes as deltas, and the answer isn't re-sent when something else changes.
	b.assistantStart("a1");
	view.events(b.flush());
	b.assistantDelta(0, "text", "Done");
	b.toolOutput("c1", { append: "y" });
	expect(view.events(b.flush()).map((e) => e.type)).toEqual(["item.delta", "item.updated"]);
});
