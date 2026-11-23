/**
 * Noticing that the Mac slept. Node's timers run on a clock that stops while it sleeps, so a timer armed for an hour can
 * fire most of an hour after waking, and a connection open across the sleep may be half-dead. The wall clock doesn't
 * stop: a short timer that finds much more wall time gone by than it waited saw a sleep. In the engine, so it works with
 * the app closed (the LaunchAgent) too.
 */

/** How often it looks, and how much extra wall time counts as a sleep. */
export const WAKE_CHECK_MS = 15_000;
export const WAKE_SLACK_MS = 45_000;

export class WakeWatch {
	private timer?: NodeJS.Timeout;
	private last: number;
	private readonly listeners = new Set<(sleptMs: number) => void>();

	constructor(
		private readonly now: () => number = Date.now,
		private readonly everyMs = WAKE_CHECK_MS,
		private readonly slackMs = WAKE_SLACK_MS,
	) {
		this.last = now();
	}

	/** `listener(sleptMs)` after each wake, with about how long the Mac slept. */
	onWake(listener: (sleptMs: number) => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	start(): void {
		if (this.timer) return;
		this.last = this.now();
		this.timer = setInterval(() => this.check(), this.everyMs);
		this.timer.unref?.();
	}

	/** One look: the wake listeners run when much more wall time passed than the timer waited. */
	check(): void {
		const now = this.now();
		const gap = now - this.last - this.everyMs;
		this.last = now;
		if (gap < this.slackMs) return;
		for (const listener of [...this.listeners]) {
			try {
				listener(gap);
			} catch {
				// One part failing to catch up doesn't stop the others.
			}
		}
	}

	stop(): void {
		clearInterval(this.timer);
		this.timer = undefined;
	}
}
