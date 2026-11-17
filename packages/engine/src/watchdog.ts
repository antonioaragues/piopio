/**
 * The Watchdog (docs/spec/17 §4, DP1): a part of the engine outside every conversation that notices when one is
 * stuck, and says so. It never stops or steers a conversation itself. Rules, no model:
 *
 * - **W1 Silent:** a running turn with nothing new (no item, no tool output) for `silentMs` (10 min).
 * - **W2 Looping:** the same tool call with the same arguments 3 times in a turn, or the same failing command 3 times.
 * - **W3 Waiting on you:** an approval or question unanswered for `waitingMs` (30 min): one reminder, not repeated.
 *
 * Where a note goes is the host's call (sessions.ts): a side conversation's or a subagent's to its parent, a board
 * helper's to the conversation that made the task, yours to Needs you, with a notification. W4 (parked or faulted)
 * and W5 (over budget) are already the agents' Inbox and the board's and agents' budgets.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { ContainerRef } from "@piopio/protocol";
import type { Runtime } from "./runtimes/runtime.js";

export type WatchdogRule = "silent" | "looping" | "waiting";

/** A note about one of your conversations, in Needs you until you dismiss it or it moves on. */
export type WatchdogNote = { id: string; ref: ContainerRef; title: string; rule: WatchdogRule; text: string; at: string };

export type WatchdogOptions = {
	/** W1: how long a running turn may go without anything new (default 10 min). */
	silentMs?: number;
	/** W3: how long an approval or question may wait before the reminder (default 30 min). */
	waitingMs?: number;
	/** How often the clock rules are checked (default 1 min). */
	tickMs?: number;
	now?: () => number;
};

export interface WatchdogHost {
	/** Sends the note where it belongs (a parent, a board's conversation); "you" when it's one of your own. */
	deliver(ref: ContainerRef, rule: WatchdogRule, text: string): "elsewhere" | "you";
	title(ref: ContainerRef): string;
	/** A notification on the Mac. */
	notify(ref: ContainerRef, title: string, message: string): void;
	/** Needs you's notes changed. */
	changed(): void;
}

type Watched = {
	ref: ContainerRef;
	running: boolean;
	lastAt: number;
	/** What's running now, for the silent note ("while running npm test"). */
	tool?: string;
	calls: Map<string, number>;
	failing: Map<string, number>;
	looped: Set<string>;
	silent: boolean;
	waitingSince?: number;
	waitingFor?: string;
	reminded: boolean;
};

const minutes = (ms: number) => {
	const m = Math.round(ms / 60_000);
	return m >= 1 ? `${m} minute${m === 1 ? "" : "s"}` : `${Math.round(ms / 1000)} seconds`;
};
const short = (text: string) => (text.length > 120 ? `${text.slice(0, 119)}…` : text);

export class Watchdog {
	private readonly watched = new Map<string, Watched>();
	private readonly seen = new WeakSet<Runtime>();
	private notes: WatchdogNote[] = [];
	private timer?: NodeJS.Timeout;
	private readonly silentMs: number;
	private readonly waitingMs: number;
	private readonly now: () => number;

	constructor(
		private readonly host: WatchdogHost,
		private readonly file: string,
		options: WatchdogOptions = {},
	) {
		this.silentMs = options.silentMs ?? 10 * 60_000;
		this.waitingMs = options.waitingMs ?? 30 * 60_000;
		this.now = options.now ?? Date.now;
		try {
			if (existsSync(file)) this.notes = JSON.parse(readFileSync(file, "utf8")) as WatchdogNote[];
		} catch {
			this.notes = [];
		}
		this.timer = setInterval(() => this.tick(), options.tickMs ?? 60_000);
		this.timer.unref?.();
	}

	stop(): void {
		clearInterval(this.timer);
	}

	list(): WatchdogNote[] {
		return this.notes;
	}

	dismiss(id: string): void {
		this.drop((n) => n.id === id);
	}

	/** Follows a conversation (a Build session or a chat) while it's open. */
	watch(ref: ContainerRef, runtime: Runtime): void {
		if (this.seen.has(runtime)) return;
		this.seen.add(runtime);
		const w: Watched = { ref, running: runtime.snapshot().state.status === "running", lastAt: this.now(), calls: new Map(), failing: new Map(), looped: new Set(), silent: false, reminded: false };
		this.watched.set(ref.id, w);
		runtime.onEvents((events) => {
			for (const e of events) this.event(w, e);
		});
	}

	private event(w: Watched, e: Parameters<Parameters<Runtime["onEvents"]>[0]>[0][number]): void {
		w.lastAt = this.now();
		if (e.type === "state") {
			if (e.state.status === "running" && !w.running) {
				// A new turn: what the last one did no longer counts, and its notes have moved on.
				w.running = true;
				w.calls.clear();
				w.failing.clear();
				w.looped.clear();
				w.silent = false;
				this.drop((n) => n.ref.id === w.ref.id);
			}
			if (e.state.status === "waiting_approval") {
				if (w.waitingSince === undefined) {
					w.waitingSince = this.now();
					w.waitingFor = e.state.prompts?.[0]?.title;
					w.reminded = false;
				}
			} else w.waitingSince = undefined;
			if (e.state.status === "idle" || e.state.status === "error") {
				w.running = false;
				w.tool = undefined;
				this.drop((n) => n.ref.id === w.ref.id && n.rule !== "looping");
			}
			return;
		}
		if ((e.type === "item.added" || e.type === "item.updated") && e.item.kind === "tool") {
			// Anything new from it means it isn't silent any more.
			if (w.silent) {
				w.silent = false;
				this.drop((n) => n.ref.id === w.ref.id && n.rule === "silent");
			}
			const item = e.item;
			if (item.status === "running") w.tool = item.tool === "bash" ? `\`${short(String((item.args as { command?: string } | undefined)?.command ?? "bash"))}\`` : item.tool;
			const sig = `${item.tool} ${JSON.stringify(item.args ?? {})}`;
			if (e.type === "item.added") {
				const n = (w.calls.get(sig) ?? 0) + 1;
				w.calls.set(sig, n);
				if (n >= 3 && !w.looped.has(sig)) {
					w.looped.add(sig);
					this.fire(w, "looping", `is repeating itself: it called ${item.tool} with the same arguments ${n} times in this turn (${short(JSON.stringify(item.args ?? {}))}).`);
				}
			}
			if (item.status === "error" && item.tool === "bash") {
				const command = String((item.args as { command?: string } | undefined)?.command ?? "");
				const n = (w.failing.get(command) ?? 0) + 1;
				w.failing.set(command, n);
				const failSig = `failing ${command}`;
				// The same call repeated has already said so: one cause, one note.
				if (n >= 3 && !w.looped.has(failSig) && !w.looped.has(sig)) {
					w.looped.add(failSig);
					this.fire(w, "looping", `is repeating itself: the same command failed ${n} times in this turn (\`${short(command)}\`).`);
				}
			}
			if (item.status !== "running") w.tool = undefined;
		}
	}

	/** The clock rules: W1 and W3. */
	tick(): void {
		const now = this.now();
		for (const w of this.watched.values()) {
			if (w.running && w.waitingSince === undefined && !w.silent && now - w.lastAt >= this.silentMs) {
				w.silent = true;
				this.fire(w, "silent", `looks stuck: nothing new for ${minutes(now - w.lastAt)}${w.tool ? ` while running ${w.tool}` : ""}.`);
			}
			if (w.waitingSince !== undefined && !w.reminded && now - w.waitingSince >= this.waitingMs) {
				w.reminded = true;
				this.host.notify(w.ref, this.host.title(w.ref), `Still waiting for you after ${minutes(now - w.waitingSince)}${w.waitingFor ? `: ${w.waitingFor}` : ""}`);
			}
		}
	}

	private fire(w: Watched, rule: WatchdogRule, text: string): void {
		if (this.host.deliver(w.ref, rule, text) === "elsewhere") return;
		const title = this.host.title(w.ref);
		this.notes = [...this.notes.filter((n) => !(n.ref.id === w.ref.id && n.rule === rule)), { id: `wd_${this.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`, ref: w.ref, title, rule, text: `It ${text}`, at: new Date(this.now()).toISOString() }];
		this.save();
		this.host.notify(w.ref, title, `It ${text}`);
	}

	private drop(which: (n: WatchdogNote) => boolean): void {
		const kept = this.notes.filter((n) => !which(n));
		if (kept.length === this.notes.length) return;
		this.notes = kept;
		this.save();
	}

	private save(): void {
		mkdirSync(dirname(this.file), { recursive: true });
		writeFileSync(this.file, JSON.stringify(this.notes, null, "\t"));
		this.host.changed();
	}
}
