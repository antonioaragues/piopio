import { afterEach, describe, expect, it, vi } from "vitest";
import type { SessionEvent } from "@piopio/protocol";
import { coalesceDeltas, DeltaBatcher } from "../src/timeline/delta-batcher.js";

const delta = (textDelta: string, itemId = "a", partIndex = 0): SessionEvent => ({ type: "item.delta", itemId, partIndex, partType: "text", textDelta });
const removed: SessionEvent = { type: "item.removed", itemId: "x" };

describe("coalesceDeltas", () => {
	it("joins back-to-back deltas of one part only", () => {
		expect(coalesceDeltas([delta("He"), delta("llo"), delta("!", "a", 1), removed, delta("?"), delta("?", "b")])).toEqual([
			delta("Hello"),
			delta("!", "a", 1),
			removed,
			delta("?"),
			delta("?", "b"),
		]);
	});
});

describe("DeltaBatcher", () => {
	afterEach(() => vi.useRealTimers());

	it("holds deltas for a frame and sends them joined", () => {
		vi.useFakeTimers();
		const sent: SessionEvent[][] = [];
		const b = new DeltaBatcher((e) => sent.push(e));
		b.push([delta("a")]);
		b.push([delta("b")]);
		expect(sent).toEqual([]);
		vi.advanceTimersByTime(16);
		expect(sent).toEqual([[delta("ab")]]);
	});

	it("sends anything else at once, after the deltas before it", () => {
		vi.useFakeTimers();
		const sent: SessionEvent[][] = [];
		const b = new DeltaBatcher((e) => sent.push(e));
		b.push([delta("a")]);
		b.push([removed]);
		expect(sent).toEqual([[delta("a"), removed]]);
		vi.advanceTimersByTime(16);
		expect(sent.length).toBe(1);
	});

	it("drops what is pending when disposed", () => {
		vi.useFakeTimers();
		const sent: SessionEvent[][] = [];
		const b = new DeltaBatcher((e) => sent.push(e));
		b.push([delta("a")]);
		b.dispose();
		vi.advanceTimersByTime(16);
		expect(sent).toEqual([]);
	});
});
