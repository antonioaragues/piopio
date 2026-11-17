import type { SessionEvent } from "@piopio/protocol";

/** The same events with back-to-back text deltas of one part joined into one. Order is kept. */
export function coalesceDeltas(events: readonly SessionEvent[]): SessionEvent[] {
	const out: SessionEvent[] = [];
	for (const e of events) {
		const last = out[out.length - 1];
		if (e.type === "item.delta" && last?.type === "item.delta" && last.itemId === e.itemId && last.partIndex === e.partIndex && last.partType === e.partType) {
			out[out.length - 1] = { ...last, textDelta: last.textDelta + e.textDelta };
		} else out.push(e);
	}
	return out;
}

/**
 * Streaming emits a batch per token. Deltas wait up to `ms` and go out joined, in one notification;
 * anything else (state, approvals, new items) goes out at once, after the deltas before it.
 */
export class DeltaBatcher {
	private pending: SessionEvent[] = [];
	private timer: ReturnType<typeof setTimeout> | undefined;

	constructor(
		private readonly send: (events: SessionEvent[]) => void,
		private readonly ms = 16,
	) {}

	push(events: readonly SessionEvent[]): void {
		if (events.length === 0) return;
		this.pending.push(...events);
		if (events.every((e) => e.type === "item.delta")) this.timer ??= setTimeout(() => this.flush(), this.ms);
		else this.flush();
	}

	flush(): void {
		clearTimeout(this.timer);
		this.timer = undefined;
		if (this.pending.length === 0) return;
		const out = coalesceDeltas(this.pending);
		this.pending = [];
		this.send(out);
	}

	dispose(): void {
		clearTimeout(this.timer);
		this.timer = undefined;
		this.pending = [];
	}
}
