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

/**
 * How long a coding agent's process (Claude Code, Codex, Antigravity CLI) stays alive with nothing to do. Each one
 * costs 40 to 300 MB (docs/research/memory-and-cpu.md); once ended, the next message resumes its session by id, as
 * after a restart. Node's timers pause while the Mac sleeps, so this is time awake.
 */
export const AGENT_IDLE_MS = 15 * 60_000;

/** AGENT_IDLE_MS, or PIOPIO_AGENT_IDLE_MS when set (tests, and trying it by hand). */
export function agentIdleMs(): number {
	const set = Number(process.env.PIOPIO_AGENT_IDLE_MS);
	return Number.isFinite(set) && set > 0 ? set : AGENT_IDLE_MS;
}

/** Calls `onIdle` once `ms` pass after `arm()` without a `disarm()`. Doesn't keep the engine running. */
export class IdleTimer {
	private timer?: ReturnType<typeof setTimeout>;

	constructor(
		private readonly ms: number,
		private readonly onIdle: () => void,
	) {}

	arm(): void {
		this.disarm();
		if (!(this.ms > 0)) return;
		this.timer = setTimeout(() => {
			this.timer = undefined;
			this.onIdle();
		}, this.ms);
		this.timer.unref?.();
	}

	disarm(): void {
		if (this.timer) clearTimeout(this.timer);
		this.timer = undefined;
	}
}
