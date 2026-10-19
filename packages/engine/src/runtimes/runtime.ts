import type { Attachment, ContainerRef, ModelRef, SessionEvent, Snapshot } from "@piopio/protocol";

export type WhenBusy = "followUp" | "steer" | "reject";
export type SubmitOptions = { whenBusy: WhenBusy; requestId?: string; attachments?: Attachment[] };

/** One open session, whatever harness backs it. */
export interface Runtime {
	readonly ref: ContainerRef;
	snapshot(): Snapshot;
	/** Receives event batches until the returned function is called. */
	onEvents(listener: (events: SessionEvent[]) => void): () => void;
	submit(text: string, options: SubmitOptions): Promise<{ disposition: "started" | "queued" }>;
	abort(): Promise<void>;
	/** Changes the model and/or thinking level for the next request. */
	configure(change: { model?: ModelRef; thinking?: string; web?: boolean }): Promise<void>;
	close(): Promise<void>;
	// Optional capabilities (threads have all of them; build sessions only some, for now).
	edit?(itemId: string, text: string): Promise<void>;
	regenerate?(itemId: string): Promise<void>;
	switchBranch?(branch: string): Promise<void>;
	removeQueued?(queueId: string): Promise<void>;
	clearQueue?(): Promise<void>;
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
