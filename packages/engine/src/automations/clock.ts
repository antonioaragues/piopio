/**
 * The automations' clock (docs/spec/27 §5, "One scheduler"): one pi-durable task per time automation, sleeping until
 * its next fire. The sleep is stored, so it survives a restart, and a fire missed while the engine was off is due when
 * it's back. A fire cut off by a crash runs its phase again; the service's fire key keeps that from running twice.
 *
 * The Harness here runs tasks only: it has no models and no conversation anyone talks to. Its tasks belong to its root
 * conversation because every pi-durable task has one.
 *
 * Waking is the host's (`onWake`): pi-durable says when the earliest sleep is due and this arms the timer. A timer set
 * before the Mac slept counts on a clock that stopped meanwhile, so it's armed again on wake and at least every hour.
 */
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels, InMemoryCredentialStore } from "@earendil-works/pi-ai";
import { createRegistry, defineExtension, defineTask, Harness, MemoryStorage, type TaskId, type Wake } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";

const ctx = BACKGROUND_CONTEXT;
const TASK = "piopio.automation";
const HOUR = 3_600_000;

/** `sig`: the automation's trigger as it was when the task was made; a changed trigger gets a new task. */
type Input = { id: string; sig: string };
type State = { phase: "wait" } | { phase: "fire"; at: number };

export type ClockHost = {
	/** The SQLite file the sleeps are kept in; in memory without one (tests). */
	file?: string;
	now?: () => number;
	log(line: string): void;
	/** The time automations that should be sleeping now. */
	wanted(): Input[];
	/** When this automation fires next; undefined once it's gone, paused, done, or its trigger changed. */
	next(id: string, sig: string): number | undefined;
	/** Its moment came. Sets its next fire before it returns, and doesn't throw. */
	fire(id: string, at: number): Promise<void>;
};

export class AutomationClock {
	private timer?: NodeJS.Timeout;
	private closed = false;
	private line: Promise<unknown> = Promise.resolve();

	private constructor(
		private readonly harness: Harness,
		private readonly task: ReturnType<typeof defineClockTask>,
		private readonly host: ClockHost,
	) {}

	static async open(host: ClockHost): Promise<AutomationClock> {
		const task = defineClockTask(host);
		const registry = createRegistry();
		registry.install(defineExtension({ name: "piopio.automations", tasks: [task] }));
		// The list and each next fire live in the service's store; this file only holds the sleeps, which `reconcile`
		// makes again. So a file that won't open costs nothing but a log line.
		const storage = host.file
			? await openNodeSqliteStorage(host.file).catch((error: unknown) => {
					host.log(`Automations' clock: ${host.file} didn't open (${(error as Error).message}); keeping its sleeps in memory.`);
					return new MemoryStorage();
				})
			: new MemoryStorage();
		let clock: AutomationClock | undefined;
		const harness = await Harness.open(
			storage,
			{
				// No generation ever runs here: an empty model set.
				models: createModels({ credentials: new InMemoryCredentialStore() }),
				registry,
				...(host.now ? { now: host.now } : {}),
				onWake: (wake) => clock?.arm(wake),
				onReport: (report) => host.log(`Automations' clock: ${report.kind}: ${(report.error as Error | undefined)?.message ?? ""}`),
			},
			ctx,
		);
		clock = new AutomationClock(harness, task, host);
		harness.resume();
		clock.arm(harness.wake());
		return clock;
	}

	private now(): number {
		return this.host.now?.() ?? Date.now();
	}

	/** Sleeps until pi-durable's earliest sleep is due, then lets it run what's due. */
	private arm(wake: Wake): void {
		clearTimeout(this.timer);
		if (this.closed || wake.at === undefined) return;
		this.timer = setTimeout(
			() => {
				if (this.closed) return;
				this.harness.resume();
				this.arm(this.harness.wake());
			},
			Math.min(Math.max(wake.at - this.now(), 0), HOUR),
		);
		this.timer.unref?.();
	}

	/** After the Mac slept: what fell due meanwhile runs now. */
	woke(): void {
		if (!this.closed) this.arm(this.harness.wake());
	}

	/** One live task per wanted automation; the others (gone, paused, a changed trigger) are aborted. */
	reconcile(): Promise<void> {
		const run = this.line.then(() => (this.closed ? undefined : this.sync()));
		this.line = run.catch((error: unknown) => this.host.log(`Automations' clock: ${(error as Error).message}`));
		return this.line as Promise<void>;
	}

	private async sync(): Promise<void> {
		const wanted = new Map(this.host.wanted().map((w) => [w.id, w.sig]));
		const have = new Set<string>();
		for (const status of ["pending", "running", "waiting", "sleeping"] as const) {
			const live = await this.harness.commit(async (tx) => (await tx.scanTasks({ kind: TASK, status }, 1000)).items, ctx);
			for (const t of live) {
				const input = t.input as Input;
				if (wanted.get(input.id) === input.sig && !have.has(input.id)) have.add(input.id);
				else await this.harness.abortTask(t.id as TaskId, ctx);
			}
		}
		const missing = [...wanted].filter(([id]) => !have.has(id));
		if (!missing.length) return;
		const root = await this.harness.root(ctx);
		await this.harness.commit(async (tx) => {
			for (const [id, sig] of missing) await tx.createTask(this.task, { id, sig }, { ownership: { kind: "conversation" }, conversationId: root.id, background: true });
		}, ctx);
	}

	async close(): Promise<void> {
		this.closed = true;
		clearTimeout(this.timer);
		await this.line;
		await this.harness.close(ctx).catch(() => undefined);
	}
}

function defineClockTask(host: ClockHost) {
	return defineTask<Input, State, null>({
		name: TASK,
		version: 1,
		initial: () => ({ phase: "wait" }),
		phases: {
			wait: async (task, runtime, context) => {
				const next = host.next(task.input.id, task.input.sig);
				if (next === undefined) return runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: null } }), context);
				// A durable sleep: no invocation held, kept across restarts, resumed at "fire".
				return runtime.sleepUntil(next, { phase: "fire", at: next }, context);
			},
			fire: async (task, runtime, context) => {
				const { id, sig } = task.input;
				const at = task.state.checkpoint.at;
				if (host.next(id, sig) !== undefined) await host.fire(id, at);
				// A fire that left the same moment standing would spin: only a later one keeps the task.
				const next = host.next(id, sig);
				await runtime.commit(() => (next !== undefined && next > at ? { status: "running", checkpoint: { phase: "wait" } } : { status: "terminal", outcome: { status: "completed", result: null } }), context);
			},
		},
		abort: async (_task, runtime, context) => runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
	});
}
