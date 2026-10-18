import type { ContainerRef, ModelRef, SessionEvent, Snapshot } from "@piopio/protocol";

export type WhenBusy = "followUp" | "steer" | "reject";

/** One open session, whatever harness backs it. */
export interface Runtime {
	readonly ref: ContainerRef;
	snapshot(): Snapshot;
	/** Receives event batches until the returned function is called. */
	onEvents(listener: (events: SessionEvent[]) => void): () => void;
	submit(text: string, options: { whenBusy: WhenBusy; requestId?: string }): Promise<{ disposition: "started" | "queued" }>;
	abort(): Promise<void>;
	/** Changes the model and/or thinking level for the next request. */
	configure(change: { model?: ModelRef; thinking?: string }): Promise<void>;
	close(): Promise<void>;
}

export class Emitter {
	private listeners = new Set<(events: SessionEvent[]) => void>();

	on(listener: (events: SessionEvent[]) => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	emit(events: SessionEvent[]): void {
		if (events.length === 0) return;
		for (const l of this.listeners) l(events);
	}
}
