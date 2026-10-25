/**
 * Spike S7 (docs/spec/13-cloud-engine.md): Piopio's agent runtime (`AgentCore` from `@piopio/runtime`) inside the
 * AgentDO. pi-durable is opened by the Agents SDK `PiHarness` (S4); `AgentCore` goes on top of that harness, with the
 * built-in memory provider on this object's SQLite.
 *
 * What PiHarness doesn't do for us: wake the object for the agent's own timers. Schedules, reminders and the outbox
 * wait in pi-durable tasks (`runtime.sleep`), and pi's scheduler only runs while the object is in memory. `AgentWake`
 * is a Lifecycle job due at the agent's next wake (next fire, outbox release); when it runs, pi resumes, the sleeps
 * that are due return, and the job keeps the object awake until the runs they started settle.
 *
 * And the reverse: a sleeping task holds a timer, and a pending timer keeps a Durable Object in memory (billed, never
 * hibernating) until it fires, hours later. So between wakes the agent rests: when nothing runs, nobody watches and the
 * next wake is more than a minute away, pi's in-memory side is closed (durable state untouched) and the alarm is
 * the only timer left.
 */
import { BACKGROUND_CONTEXT, withAbortSignal, type Context } from "@earendil-works/chord/context";
import type { Conversation, Harness } from "@earendil-works/pi-durable";
import { AgentCore, BuiltinMemory, newDefinition, type AgentDefinition, type Sql } from "@piopio/runtime";
import { LifecycleCapability } from "agents/lifecycle";

/** How long one wake waits for runs before it hands over to the next alarm (alarms have a 15-minute limit). */
const RUN_WAIT_MS = 10 * 60_000;
/** While a run is still going, check again this often (and resume it there if the object was evicted). */
const HEARTBEAT_MS = 30_000;
/** After any activity, look again this much later and rest if there's nothing to do. */
const SETTLE_MS = 30_000;
/** Closer than this, the next wake is waited for in memory instead of resting. */
const REST_THRESHOLD_MS = 60_000;

/** The agent's definition, kept in the object's storage; a default one until the app deploys a real one. */
export type StoredAgent = { definition: AgentDefinition; instructions: string };

export function defaultAgent(id: string, model: string): StoredAgent {
	// The personal assistant: memory, reminders and messages on.
	return newDefinition({ id, slug: id, name: id, owner: "owner", model, template: "personal-assistant" });
}

/** `Sql` (synchronous, as the built-in memory provider wants) over a Durable Object's `ctx.storage.sql`. */
export function durableSql(storage: DurableObjectStorage): Sql {
	return {
		exec: (sql) => void storage.sql.exec(sql),
		run: (sql, ...params) => void storage.sql.exec(sql, ...(params as SqlStorageValue[])).toArray(),
		all: <T>(sql: string, ...params: unknown[]) => storage.sql.exec(sql, ...(params as SqlStorageValue[])).toArray() as T[],
	};
}

/** The agent on an open pi harness, and when it next needs to be awake. */
export class AgentHost {
	readonly core: AgentCore;
	readonly memory: BuiltinMemory;

	constructor(
		readonly pi: Harness,
		private readonly agent: () => StoredAgent,
		storage: DurableObjectStorage,
		context: Context,
		onChange: () => void,
	) {
		this.memory = new BuiltinMemory(durableSql(storage), () => crypto.randomUUID());
		this.core = new AgentCore({
			harness: pi,
			definition: () => this.agent().definition,
			instructions: () => this.agent().instructions,
			memory: () => this.memory,
			extensions: () => [],
			context,
			onRun: onChange,
			onStatus: onChange,
		});
	}

	/** The next time something of the agent's is due: a schedule or reminder, or a held message. */
	nextWake(): Promise<number | undefined> {
		return this.core.proactive.nextWake();
	}

	/** Runs started by a schedule, reminder or trigger that haven't settled. */
	async runningConversations(): Promise<Conversation[]> {
		const out: Conversation[] = [];
		for (const run of (await this.core.proactive.overview()).runs.filter((r) => r.status === "running")) {
			const c = await this.pi.conversation(Number(run.conversationId) as never, BACKGROUND_CONTEXT);
			if (c) out.push(c);
		}
		return out;
	}
}

/** What the wake job needs from the object. */
export type WakeHost = {
	agent(): Promise<AgentHost>;
	/** pi is open (the agent is in memory). */
	open(): boolean;
	/** A person's turn is going, or a client is watching a conversation. */
	busy(): Promise<boolean>;
	/** Close pi's in-memory side; durable state stays. */
	rest(): Promise<void>;
};

/**
 * The agent's wake: one Lifecycle job (`wake`), due at the agent's next wake, or sooner to check whether it can rest.
 * Its alarm restarts the object if it was evicted; opening pi resumes its tasks, and due sleeps return at once.
 */
export class AgentWake extends LifecycleCapability {
	private readonly settleMs: number;
	private readonly restThresholdMs: number;

	/** `timing` shortens the settle check and the rest threshold, for tests only. */
	constructor(
		private readonly host: WakeHost,
		timing?: { settleMs: number; restThresholdMs: number },
	) {
		super("piopio-agent");
		this.settleMs = timing?.settleMs ?? SETTLE_MS;
		this.restThresholdMs = timing?.restThresholdMs ?? REST_THRESHOLD_MS;
	}

	/** Moves the job to the agent's next wake, or to a settle check while pi is open. */
	async rearm(): Promise<number | undefined> {
		const next = await (await this.host.agent()).nextWake();
		const settle = this.host.open() ? Date.now() + this.settleMs : undefined;
		const time = Math.min(next ?? Infinity, settle ?? Infinity);
		if (time === Infinity) await this.lifecycle.jobs.cancel("wake");
		else await this.lifecycle.jobs.push({ id: "wake", fn: "wake", time, singleflight: true });
		return next;
	}

	async onJob(): Promise<{ rescheduleAt: number } | undefined> {
		const host = await this.host.agent();
		// Give due sleeps a turn of the scheduler, so the runs they start exist before we look.
		await new Promise((r) => setTimeout(r, 50));
		const running = await host.runningConversations();
		if (running.length > 0) {
			const budget = AbortSignal.timeout(RUN_WAIT_MS);
			const wait = Promise.all(running.map((c) => c.waitForIdle(withAbortSignal(budget, BACKGROUND_CONTEXT)).catch(() => undefined)));
			this.lifecycle.trackAlarmWork(wait);
			return { rescheduleAt: Date.now() + HEARTBEAT_MS };
		}
		if (await this.host.busy()) return { rescheduleAt: Date.now() + this.settleMs };
		const next = await host.nextWake();
		if (next === undefined || next - Date.now() > this.restThresholdMs) await this.host.rest();
		return next === undefined ? undefined : { rescheduleAt: Math.max(next, Date.now() + 1000) };
	}
}
