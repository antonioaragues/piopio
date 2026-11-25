/**
 * Proactivity (docs/spec/06-agents §6 PR1–PR6): schedules, the heartbeat and reminders the agent sets are
 * pi-durable tasks that sleep until their next fire, so they survive restarts (a fire missed while the engine was
 * off happens once when it comes back). Each fire is a run: its own conversation (`run:<id>`), recorded with its
 * outcome. `send_message` delivers to a person's conversation (the in-app channel) unless quiet hours or the daily
 * limit hold it; held messages wait in the outbox, which a task flushes when they may go.
 */
import type { Context } from "@earendil-works/chord/context";
import { Type } from "typebox";
import { defineTask, defineTool, type ConversationId, type Harness, type JsonObject, type TaskId, UsageDoc } from "@earendil-works/pi-durable";
import { contactFor, cronError, type AgentDefinition } from "./definition.js";
import type { ResultCard, UndoKind } from "./safety.js";
import { passedText } from "../context/clock.js";
import { cronLabel, dayOf, inWindow, nextDay, nextFire, nextHeartbeat, windowEnd } from "./time.js";

export type RunKind = "schedule" | "heartbeat" | "reminder" | "trigger" | "manual" | "automation";
export type RunRecord = {
	id: string;
	/** A durable task reports how it ends (`settled.ts`); absent on runs started before that. */
	watched?: boolean;
	kind: RunKind;
	/** The schedule, reminder or trigger id. */
	source: string;
	prompt: string;
	firedAt: string;
	conversationId: string;
	deliverTo?: string;
	/** `skipped`: the agent was paused or out of budget when it fired. */
	status: "running" | "done" | "failed" | "skipped";
	/** The run's last answer, in a line. */
	summary?: string;
	sent: number;
	costUsd?: number;
	/** An automation's run (docs/spec/27): its name, what the run is told about its result, and its budget. */
	label?: string;
	note?: string;
	budgetUsd?: number;
};
/**
 * An event routine the agent set itself (the `watch` tool, docs/spec/19 S3): a webhook (it gets a URL), a folder (a file
 * appears or changes in it), or an email (from someone, or with words in the subject). The host does the watching
 * and calls `fireWatch` with what happened; each fire is a run, like a schedule's.
 */
export type Watch = {
	id: string;
	on: "webhook" | "folder" | "email";
	prompt: string;
	/** folder: an absolute path. */
	folder?: string;
	/** email: part of the sender's name or address, and part of the subject. */
	from?: string;
	subject?: string;
	deliverTo?: string;
	createdAt: string;
	by: string;
};
/** A reminder or schedule the agent made (the `schedule` tool). */
export type Reminder = { id: string; prompt: string; deliverTo?: string; at?: number; cron?: string; tz?: string; createdAt: string; by: string };
export type Outbound = { id: string; to: string; text: string; from: string; queuedAt: string; notBefore: number; reason: "quiet" | "limit" | "paused"; urgent?: boolean };
/** A schedule, the heartbeat or a reminder, with its next fire (the Runs tab). */
export type Upcoming = { id: string; kind: "schedule" | "heartbeat" | "reminder" | "watch"; label: string; next?: number; cron?: string };
/**
 * Automations (docs/spec/27): kept by the host, made and changed by the agent through its tools, always run as the
 * agent itself (AU5). The host checks the rules and answers in words the agent can act on.
 */
export type AutomationToolInput = {
	name?: string;
	on?: "time" | "email" | "folder" | "webhook";
	when?: string;
	folder?: string;
	from?: string;
	subject?: string;
	prompt?: string;
	result?: "chat" | "telegram" | "quiet";
	to?: string;
	approval?: "wait" | "skip";
	budget?: number;
	enabled?: boolean;
};
/** What a card shows (the app's creation card, 27 §4). */
export type AutomationSummary = { id: string; name: string; when: string; runsAs: string; does: string; tellsYou: string; runsOn: string; url?: string; next?: number };
export interface AutomationsBridge {
	add(input: AutomationToolInput, by: string): Promise<AutomationSummary>;
	/**
	 * One line per automation. `next: false` leaves out each one's next run time, for the system prompt: that time
	 * moves on every fire, and a section that changes is sent again and breaks the provider's prompt cache from there.
	 */
	list(options?: { next?: boolean }): Promise<string>;
	/** Returns the record before the change, for Undo. */
	change(id: string, input: AutomationToolInput): Promise<{ summary: AutomationSummary; before: JsonObject }>;
	remove(id: string): Promise<{ summary: AutomationSummary; before: JsonObject }>;
	/** Undo: removes a new one (`id`), or puts a record back as it was (`before`). */
	undo(data: { id?: string; before?: JsonObject }): Promise<void>;
}
export type ProactiveState = {
	runs?: RunRecord[];
	reminders?: Reminder[];
	watches?: Watch[];
	outbox?: Outbound[];
	/** day → messages sent that day; "day/contact" → to that person. */
	sent?: Record<string, number>;
	/** The day the owner was told the limit was hit. */
	limitNotice?: string;
	/** The conversation that owns the schedule tasks. */
	scheduler?: string;
	nextRun?: number;
};

const MAX_RUNS = 200;
/** Held while paused: far enough to never come up by itself (resuming releases it). */
const PAUSED = 10 * 365 * 24 * 3600_000;
export const OUT_ENTRY = "piopio.channel-out";
export const NOTICE_ENTRY = "piopio.notice";

/** What proactivity needs of the agent core. */
export interface ProactiveHost {
	readonly harness: Harness;
	readonly context: Context;
	definition(): AgentDefinition;
	now(): number;
	/** The state doc, read and written. */
	read(): Promise<ProactiveState & { people: Record<string, string> }>;
	write(change: (state: ProactiveState & { people: Record<string, string> }) => void): Promise<void>;
	/** A person's conversation, made on first contact. */
	person(contactId: string): Promise<{ id: ConversationId; submit: (input: never, context: Context) => Promise<unknown> }>;
	/** A new conversation with the agent's model and tools. */
	newConversation(): Promise<ConversationId>;
	/** Submits `draft` there under a durable watcher that reports how it settles (`settled.ts`); `change` goes in the same commit. */
	submitWatched(conversationId: ConversationId, kind: "run", ref: string, draft: JsonObject, change: (state: ProactiveState) => void): Promise<void>;
	/** Memory for a run: what's relevant to its prompt, from the owner's and shared partitions. */
	recallForRun(conversationId: ConversationId, prompt: string): Promise<void>;
	/** Whether the agent may work now (pause, budget: 06 §9). */
	gate?(): Promise<{ ok: true } | { ok: false; message: string }>;
	paused?(): Promise<boolean>;
	/** Records how to undo a change; returns the id a result card carries (§4.2). */
	recordUndo?(kind: UndoKind, data: JsonObject, title: string, conversationId: ConversationId | string): Promise<string>;
	/** Someone was sent a message (the app shows it; channels deliver it). */
	onOutbound?(to: string, text: string, from: string): void;
	/** A run started or settled (the Runs tab). */
	onRun?(run: RunRecord): void;
	/** A webhook watch's address (the engine's local endpoint); absent where the host has none. */
	watchUrl?(id: string): string | undefined;
	/** Watches were added or removed: the host starts or stops watching. */
	onWatches?(): void;
	/** Automations (docs/spec/27): with this, the agent's tools are automate and friends, not schedule and watch. */
	automations?: AutomationsBridge;
}

type ScheduleInput = { key: string; sig: string };
type ScheduleState = { phase: "wait"; next: number } | { phase: "fire"; at: number };

export class Proactivity {
	readonly scheduleTask;
	readonly outboxTask;
	readonly tools;

	constructor(private readonly host: ProactiveHost) {
		const self = this;
		this.scheduleTask = defineTask<ScheduleInput, ScheduleState, null>({
			name: "piopio.schedule",
			version: 1,
			initial: () => ({ phase: "wait", next: 0 }),
			phases: {
				wait: async (task, runtime, context) => {
					const spec = await self.spec(task.input.key);
					if (!spec || spec.sig !== task.input.sig) return runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: null } }), context);
					let next = task.state.checkpoint.next;
					if (!next) {
						const computed = spec.next(runtime.now());
						if (computed === undefined) return runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: null } }), context);
						return runtime.commit(() => ({ status: "running", checkpoint: { phase: "wait", next: computed } }), context);
					}
					// A durable sleep (pi-durable 1.4): no invocation held, survives restarts, resumes at "fire".
					return runtime.sleepUntil(next, { phase: "fire", at: next }, context);
				},
				fire: async (task, runtime, context) => {
					const at = task.state.checkpoint.at;
					const spec = await self.spec(task.input.key);
					if (spec && spec.sig === task.input.sig && !(await spec.skip?.())) {
						await self.startRun(spec.kind, spec.source, spec.prompt, spec.deliverTo, `${task.input.key}@${at}`);
					}
					if (spec?.once) await self.host.write((s) => void (s.reminders = (s.reminders ?? []).filter((r) => `rem:${r.id}` !== task.input.key)));
					const next = spec && !spec.once ? spec.next(Math.max(at, runtime.now())) : undefined;
					await runtime.commit(() => (next === undefined ? { status: "terminal", outcome: { status: "completed", result: null } } : { status: "running", checkpoint: { phase: "wait", next } }), context);
				},
			},
			abort: async (_task, runtime, context) => runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
		});

		this.outboxTask = defineTask<Record<string, never>, { phase: "wait" } | { phase: "flush" }, null>({
			name: "piopio.outbox",
			version: 1,
			initial: () => ({ phase: "wait" }),
			phases: {
				wait: async (_task, runtime, context) => {
					const state = await self.host.read();
					const pending = state.outbox ?? [];
					if (!pending.length) return runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: null } }), context);
					return runtime.sleepUntil(Math.min(...pending.map((o) => o.notBefore)), { phase: "flush" }, context);
				},
				flush: async (_task, runtime, context) => {
					await self.flush();
					await runtime.commit(() => ({ status: "running", checkpoint: { phase: "wait" } }), context);
				},
			},
			abort: async (_task, runtime, context) => runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
		});

		this.tools = this.makeTools();
	}

	private get def(): AgentDefinition {
		return this.host.definition();
	}

	/** The agent's time zone: its own, else the machine's. */
	get tz(): string {
		return this.def.timezone ?? Intl.DateTimeFormat().resolvedOptions().timeZone;
	}

	private get owner(): string {
		return this.def.contacts.find((c) => c.role === "owner")?.id ?? "owner";
	}

	/** What a schedule key stands for now (the definition or the reminders may have changed since). */
	private async spec(key: string): Promise<{ kind: RunKind; source: string; prompt: string; deliverTo?: string; sig: string; once?: boolean; next(after: number): number | undefined; skip?(): Promise<boolean> } | undefined> {
		const def = this.def;
		if (key.startsWith("def:")) {
			const s = (def.schedules ?? []).find((x) => `def:${x.id}` === key);
			if (!s || cronError(s.cron)) return undefined;
			const tz = s.tz ?? this.tz;
			return { kind: "schedule", source: s.id, prompt: s.prompt, ...(s.deliverTo ? { deliverTo: s.deliverTo } : {}), sig: `${s.cron}|${tz}`, next: (after) => nextFire(s.cron, tz, after) };
		}
		if (key === "heartbeat") {
			const h = def.heartbeat;
			if (!h) return undefined;
			return {
				kind: "heartbeat",
				source: "heartbeat",
				prompt: h.prompt,
				sig: `${h.every}|${h.activeHours ?? ""}|${this.tz}`,
				next: (after) => nextHeartbeat(h.every, h.activeHours, this.tz, after),
				// PR2: skipped when this month's runs used more than 80% of the budget.
				skip: async () => {
					const budget = def.policies?.budgetUsdPerMonth;
					if (!budget) return false;
					const month = new Date(this.host.now()).toISOString().slice(0, 7);
					const spent = ((await this.host.read()).runs ?? []).filter((r) => r.firedAt.startsWith(month)).reduce((s, r) => s + (r.costUsd ?? 0), 0);
					return spent > budget * 0.8;
				},
			};
		}
		if (key.startsWith("rem:")) {
			const r = ((await this.host.read()).reminders ?? []).find((x) => `rem:${x.id}` === key);
			if (!r) return undefined;
			const tz = r.tz ?? this.tz;
			return { kind: "reminder", source: r.id, prompt: r.prompt, ...(r.deliverTo ? { deliverTo: r.deliverTo } : {}), sig: `${r.at ?? ""}|${r.cron ?? ""}|${tz}`, once: r.at !== undefined, next: (after) => (r.at !== undefined ? (r.at > after - 60_000 ? r.at : undefined) : nextFire(r.cron!, tz, after)) };
		}
		return undefined;
	}

	private async scheduler(): Promise<ConversationId> {
		const state = await this.host.read();
		if (state.scheduler) return Number(state.scheduler) as never;
		const id = await this.host.newConversation();
		await this.host.write((s) => void (s.scheduler = String(id)));
		return id;
	}

	/** One live task per schedule (definition, heartbeat, reminders); stale ones are aborted, changed ones replaced. */
	async reconcile(): Promise<void> {
		const { harness, context } = this.host;
		const reminders = (await this.host.read()).reminders ?? [];
		const keys = [...(this.def.schedules ?? []).map((s) => `def:${s.id}`), ...(this.def.heartbeat ? ["heartbeat"] : []), ...reminders.map((r) => `rem:${r.id}`)];
		const wanted = new Map<string, string>();
		for (const key of keys) {
			const spec = await this.spec(key);
			if (spec) wanted.set(key, spec.sig);
		}
		const live = await this.liveTasks("piopio.schedule");
		const have = new Map<string, TaskId>();
		for (const t of live) {
			const input = t.input as ScheduleInput;
			if (wanted.get(input.key) === input.sig && !have.has(input.key)) have.set(input.key, t.id);
			else await harness.abortTask(t.id, context);
		}
		const owner = await this.scheduler();
		const missing = [...wanted].filter(([key]) => !have.has(key));
		if (missing.length) {
			await harness.commit(async (tx) => {
				for (const [key, sig] of missing) await tx.createTask(this.scheduleTask, { key, sig }, { ownership: { kind: "conversation" }, conversationId: owner, background: true });
			}, context);
		}
		if ((await this.host.read()).outbox?.length) await this.ensureOutbox();
	}

	private async liveTasks(kind: string) {
		const { harness, context } = this.host;
		const out = [];
		for (const status of ["pending", "running", "waiting", "sleeping"] as const) {
			out.push(...(await harness.commit(async (tx) => (await tx.scanTasks({ kind, status }, 500)).items, context)));
		}
		return out;
	}

	private async ensureOutbox(): Promise<void> {
		if ((await this.liveTasks("piopio.outbox")).length) return;
		const owner = await this.scheduler();
		await this.host.harness.commit(async (tx) => void (await tx.createTask(this.outboxTask, {}, { ownership: { kind: "conversation" }, conversationId: owner, background: true })), this.host.context);
	}

	// ── Runs ──

	/** Starts a run: its own conversation, the prompt submitted once (`requestKey` makes a repeated fire a no-op). */
	async startRun(kind: RunKind, source: string, prompt: string, deliverTo?: string, requestKey?: string, extra?: { label?: string; note?: string; budgetUsd?: number }): Promise<RunRecord> {
		const key = requestKey ?? `${kind}:${source}@${this.host.now()}`;
		const existing = ((await this.host.read()).runs ?? []).find((r) => r.id === runId(key));
		if (existing) return existing;
		const gate = (await this.host.gate?.()) ?? { ok: true as const };
		if (!gate.ok) {
			const skipped: RunRecord = { id: runId(key), kind, source, prompt, firedAt: new Date(this.host.now()).toISOString(), conversationId: "", status: "skipped", summary: gate.message, sent: 0, costUsd: 0, ...extras(extra) };
			await this.host.write((s) => void (s.runs = [...(s.runs ?? []), skipped].slice(-MAX_RUNS)));
			this.host.onRun?.(skipped);
			return skipped;
		}
		const conversationId = await this.host.newConversation();
		const run: RunRecord = { id: runId(key), watched: true, kind, source, prompt, firedAt: new Date(this.host.now()).toISOString(), conversationId: String(conversationId), ...(deliverTo ? { deliverTo } : {}), status: "running", sent: 0, ...extras(extra) };
		await this.host.recallForRun(conversationId, prompt).catch(() => undefined);
		// The run's record and the task that submits its prompt and reports its end go in one commit. No process
		// waits for the answer, and a restart loses nothing.
		await this.host.submitWatched(conversationId, "run", run.id, { type: "input", content: prompt, requestId: key }, (s) => {
			s.runs = [...(s.runs ?? []), run].slice(-MAX_RUNS);
		});
		this.host.onRun?.(run);
		return run;
	}

	/** A run's submission settled (its watcher says so): done with an answer, failed otherwise. */
	settled(runId: string, status: string): Promise<void> {
		return this.settle(runId, status === "done" ? "done" : "failed");
	}

	/** Runs left running by an engine from before runs had a watcher: followed in memory, as they were. */
	async resumeRuns(): Promise<void> {
		for (const run of ((await this.host.read()).runs ?? []).filter((r) => r.status === "running" && !r.watched)) {
			const conversation = await this.host.harness.conversation(Number(run.conversationId) as never, this.host.context);
			if (!conversation) continue;
			void conversation.waitForIdle(this.host.context).then(() => this.settle(run.id, "done"), () => undefined);
		}
	}

	private async settle(id: string, status: "done" | "failed"): Promise<void> {
		const run = ((await this.host.read()).runs ?? []).find((r) => r.id === id);
		if (!run) return;
		const { costUsd, summary } = await this.spentIn(run.conversationId);
		let settled: RunRecord | undefined;
		await this.host.write((s) => {
			const r = (s.runs ?? []).find((x) => x.id === id);
			if (!r) return;
			r.status = status;
			r.costUsd = costUsd;
			if (summary) r.summary = summary.split("\n").find((l) => l.trim())!.trim().slice(0, 200);
			settled = { ...r };
		});
		if (settled) this.host.onRun?.(settled);
	}

	/**
	 * What a conversation has cost so far, and its last answer. The cost is pi-durable's usage document for it: every
	 * response, summary and tool result that reported usage, also failed attempts and what a compaction summarized
	 * away (the active transcript alone would miss those, and a run's budget with them).
	 */
	async spentIn(conversationId: string): Promise<{ costUsd: number; summary: string }> {
		const id = Number(conversationId) as never;
		const conversation = await this.host.harness.conversation(id, this.host.context);
		const entries = conversation ? ((await conversation.context(this.host.context)).entries as unknown as readonly { kind: string; model?: { role: string; content?: unknown }[] }[]) : [];
		const usage = conversation ? await this.host.harness.snapshot(UsageDoc, id, this.host.context) : undefined;
		let costUsd = 0;
		for (const u of [...Object.values(usage?.models ?? {}), ...Object.values(usage?.tools ?? {})]) costUsd += (u as { cost?: { total?: number } }).cost?.total ?? 0;
		let summary = "";
		for (const e of entries) {
			const m = e.model?.[0];
			if (m?.role !== "assistant") continue;
			const text = Array.isArray(m.content) ? (m.content as { type: string; text?: string }[]).filter((b) => b.type === "text").map((b) => b.text ?? "").join("") : "";
			if (text.trim()) summary = text.trim();
		}
		return { costUsd, summary };
	}

	/** An automation's run over its budget (docs/spec/27 AU8): the reason to stop, or undefined while there's room. */
	async overBudget(conversationId: ConversationId | string): Promise<string | undefined> {
		const run = await this.runOf(conversationId);
		if (!run?.budgetUsd || run.status !== "running") return undefined;
		const { costUsd } = await this.spentIn(run.conversationId);
		if (costUsd < run.budgetUsd) return undefined;
		return `This run reached its budget of $${run.budgetUsd.toFixed(2)}. Stop here: don't call more tools. Say in one or two lines what you did and what's left.`;
	}

	/** Runs (newest first), held messages, and what fires next: the Runs tab. */
	async overview(): Promise<{ runs: RunRecord[]; outbox: Outbound[]; upcoming: Upcoming[] }> {
		const state = await this.host.read();
		const upcoming: Upcoming[] = [];
		const next = new Map<string, number>();
		for (const t of await this.liveTasks("piopio.schedule")) {
			const cp = (t.state as { checkpoint?: ScheduleState }).checkpoint;
			const at = cp?.phase === "wait" ? cp.next : cp?.at;
			if (at) next.set((t.input as ScheduleInput).key, at);
		}
		const withNext = (key: string, u: Omit<Upcoming, "next">) => upcoming.push({ ...u, ...(next.has(key) ? { next: next.get(key)! } : {}) });
		for (const s of this.def.schedules ?? []) withNext(`def:${s.id}`, { id: s.id, kind: "schedule", label: `${s.cron} · ${s.prompt}`, cron: s.cron });
		if (this.def.heartbeat) withNext("heartbeat", { id: "heartbeat", kind: "heartbeat", label: `Every ${this.def.heartbeat.every}${this.def.heartbeat.activeHours ? ` (${this.def.heartbeat.activeHours})` : ""}` });
		for (const r of state.reminders ?? []) withNext(`rem:${r.id}`, { id: r.id, kind: "reminder", label: r.prompt, ...(r.cron ? { cron: r.cron } : {}) });
		for (const w of state.watches ?? []) upcoming.push({ id: w.id, kind: "watch", label: `${watchLabel(w)} · ${w.prompt}` });
		return { runs: [...(state.runs ?? [])].reverse(), outbox: state.outbox ?? [], upcoming };
	}

	/**
	 * When the agent next needs to be awake: its next schedule, heartbeat or reminder, or a held message's release.
	 * A task's own checkpoint wins when it has one; otherwise it's computed from the definition and the reminders,
	 * because a task just started may not have run yet. A host that sleeps between wakes (a Durable Object) sets its
	 * alarm from this.
	 */
	async nextWake(): Promise<number | undefined> {
		const state = await this.host.read();
		const now = this.host.now();
		const live = new Map<string, number>();
		for (const t of await this.liveTasks("piopio.schedule")) {
			const cp = (t.state as { checkpoint?: ScheduleState }).checkpoint;
			const at = cp?.phase === "wait" ? cp.next : cp?.at;
			if (at) live.set((t.input as ScheduleInput).key, at);
		}
		const keys = [...(this.def.schedules ?? []).map((s) => `def:${s.id}`), ...(this.def.heartbeat ? ["heartbeat"] : []), ...(state.reminders ?? []).map((r) => `rem:${r.id}`)];
		const times: number[] = [];
		for (const key of keys) {
			const at = live.get(key) ?? (await this.spec(key))?.next(now);
			if (at !== undefined) times.push(at);
		}
		for (const o of state.outbox ?? []) times.push(o.notBefore);
		return times.length ? Math.min(...times) : undefined;
	}

	/** The run a conversation belongs to. */
	async runOf(conversationId: ConversationId | string): Promise<RunRecord | undefined> {
		return ((await this.host.read()).runs ?? []).find((r) => r.conversationId === String(conversationId));
	}

	runPrompt(run: RunRecord): string {
		const what = run.kind === "automation" ? `the automation “${run.label ?? run.source}”` : run.kind === "schedule" ? `the schedule “${run.source}”` : run.kind === "heartbeat" ? "your heartbeat" : run.kind === "reminder" ? `a reminder you set (${run.source})` : run.kind === "trigger" ? `the trigger “${run.source}”` : "a manual run";
		const to = run.deliverTo ?? this.owner;
		return `This is an automatic run, started by ${what} at ${run.firedAt.slice(0, 16).replace("T", " ")} UTC. Nobody reads this conversation. To tell someone something, use send_message (usually to “${to}”). If there's nothing worth saying, don't send anything and answer “Nothing to report.”${run.note ? ` ${run.note}` : ""}`;
	}

	// ── Messages ──

	/** Sends now, or queues for after quiet hours or the daily limits (PR4, PR5), or until a pause ends (AS4). */
	async send(to: string, text: string, from: string, urgent = false): Promise<{ status: "sent" | "queued"; until?: number; reason?: "quiet" | "limit" | "paused"; outboxId?: string }> {
		const def = this.def;
		const contact = contactFor(def.contacts, to);
		if (!contact) throw new Error(`No contact “${to}”. Contacts: ${def.contacts.map((c) => `${c.id} (${c.name})`).join(", ")}.`);
		to = contact.id;
		const now = this.host.now();
		if (await this.host.paused?.()) return this.queue(to, text, from, now + PAUSED, "paused", urgent);
		const quiet = def.policies?.quietHours;
		if (quiet && inWindow(quiet, now, this.tz) && !(urgent && def.policies?.urgentBypassesQuiet)) return this.queue(to, text, from, windowEnd(quiet, now, this.tz), "quiet", urgent);
		const today = dayOf(now, this.tz);
		const state = await this.host.read();
		const max = def.policies?.maxOutboundPerDay;
		const perContact = def.policies?.maxOutboundPerContactPerDay;
		const overall = max !== undefined && (state.sent?.[today] ?? 0) >= max;
		if (overall || (perContact !== undefined && (state.sent?.[`${today}/${to}`] ?? 0) >= perContact)) {
			if (state.limitNotice !== today) {
				await this.notice(overall ? `${def.name} reached its limit of ${max} messages today; the rest wait until tomorrow.` : `${def.name} reached its limit of ${perContact} messages to ${this.name(to)} today; the rest wait until tomorrow.`);
				await this.host.write((s) => void (s.limitNotice = today));
			}
			return this.queue(to, text, from, nextDay(now, this.tz), "limit", urgent);
		}
		await this.deliver(to, text, from, today);
		return { status: "sent" };
	}

	private name(contactId: string): string {
		return this.def.contacts.find((c) => c.id === contactId)?.name ?? contactId;
	}

	private async queue(to: string, text: string, from: string, notBefore: number, reason: Outbound["reason"], urgent: boolean) {
		const id = `out_${this.host.now().toString(36)}_${Math.random().toString(36).slice(2, 6)}`;
		await this.host.write((s) => {
			s.outbox = [...(s.outbox ?? []), { id, to, text, from, queuedAt: new Date(this.host.now()).toISOString(), notBefore, reason, ...(urgent ? { urgent } : {}) }];
		});
		if (reason !== "paused") await this.ensureOutbox();
		return { status: "queued" as const, until: notBefore, reason, outboxId: id };
	}

	/** After a pause: what was held goes now (or waits for quiet hours and limits as usual). */
	async release(): Promise<void> {
		const now = this.host.now();
		await this.host.write((s) => {
			for (const o of s.outbox ?? []) if (o.reason === "paused") o.notBefore = now;
		});
		await this.flush();
		if ((await this.host.read()).outbox?.length) await this.ensureOutbox();
	}

	/** Undo: a held message that hasn't gone yet. */
	async withdraw(outboxId: string): Promise<void> {
		const held = ((await this.host.read()).outbox ?? []).some((o) => o.id === outboxId);
		if (!held) throw new Error("That message was already sent.");
		await this.host.write((s) => void (s.outbox = (s.outbox ?? []).filter((o) => o.id !== outboxId)));
	}

	/** Undo: a reminder the agent set. */
	async cancelReminder(id: string): Promise<void> {
		const had = ((await this.host.read()).reminders ?? []).some((r) => r.id === id);
		if (!had) throw new Error("That reminder already fired or was cancelled.");
		await this.host.write((s) => void (s.reminders = (s.reminders ?? []).filter((r) => r.id !== id)));
		await this.reconcile();
	}

	/** The event routines the agent set (the host watches them). */
	async watches(): Promise<Watch[]> {
		return (await this.host.read()).watches ?? [];
	}

	/** Something a watch waits for happened: a run with its prompt and what happened. `key` makes a repeat a no-op. */
	async fireWatch(id: string, happened: string, key: string): Promise<RunRecord | undefined> {
		const w = (await this.watches()).find((x) => x.id === id);
		if (!w) return undefined;
		const detail = happened.length > 20_000 ? `${happened.slice(0, 20_000)}\n… (cut)` : happened;
		const prompt = w.prompt.includes("{{body}}") ? w.prompt.replaceAll("{{body}}", detail) : `${w.prompt}\n\nWhat happened:\n${detail}`;
		return this.startRun("trigger", w.id, prompt, w.deliverTo, `watch:${w.id}:${key}`);
	}

	async cancelWatch(id: string): Promise<void> {
		if (!(await this.watches()).some((w) => w.id === id)) throw new Error("That routine was already removed.");
		await this.host.write((s) => void (s.watches = (s.watches ?? []).filter((w) => w.id !== id)));
		this.host.onWatches?.();
	}

	async restoreWatch(watch: Watch): Promise<void> {
		await this.host.write((s) => void (s.watches = [...(s.watches ?? []).filter((w) => w.id !== watch.id), watch]));
		this.host.onWatches?.();
	}

	/** Undo: a reminder that was cancelled comes back (unless its moment has passed). */
	async restoreReminder(reminder: Reminder): Promise<void> {
		if (reminder.at !== undefined && reminder.at <= this.host.now()) throw new Error("Its moment has passed.");
		await this.host.write((s) => void (s.reminders = [...(s.reminders ?? []).filter((r) => r.id !== reminder.id), reminder]));
		await this.reconcile();
	}

	/** Sends what may go now; the rest stays (with a new time) until it can. */
	async flush(): Promise<number> {
		const pending = (await this.host.read()).outbox ?? [];
		let sent = 0;
		for (const o of pending) {
			if (o.notBefore > this.host.now()) continue;
			await this.host.write((s) => void (s.outbox = (s.outbox ?? []).filter((x) => x.id !== o.id)));
			const result = await this.send(o.to, o.text, o.from, o.urgent);
			if (result.status === "sent") sent++;
		}
		return sent;
	}

	private async deliver(to: string, text: string, from: string, today: string): Promise<void> {
		const conversation = await this.host.person(to);
		const name = this.def.name;
		await conversation.submit({ type: "write", entry: { kind: OUT_ENTRY, data: { text, from }, model: [{ role: "user", content: `(${name} sent this message on its own${from.startsWith("run_") ? ", from an automatic run" : ""}:)\n${text}`, timestamp: this.host.now() }] } } as never, this.host.context);
		await this.host.write((s) => {
			s.sent = { ...(s.sent ?? {}), [today]: (s.sent?.[today] ?? 0) + 1, [`${today}/${to}`]: (s.sent?.[`${today}/${to}`] ?? 0) + 1 };
			const run = (s.runs ?? []).find((r) => r.id === from);
			if (run) run.sent += 1;
		});
		this.host.onOutbound?.(to, text, from);
	}

	/** The agent's first words in the owner's conversation, written by the host, not the model (docs/spec/19 S2). */
	async greet(text: string, suggestions?: string[]): Promise<void> {
		const conversation = await this.host.person(this.owner);
		await conversation.submit({ type: "write", entry: { kind: OUT_ENTRY, data: { text, from: "greeting", ...(suggestions?.length ? { suggestions } : {}) }, model: [{ role: "user", content: `(You opened the conversation with this message:)\n${text}`, timestamp: this.host.now() }] } } as never, this.host.context);
	}

	/** A note in someone's conversation, the owner's by default (not a message from the agent, not counted). */
	async notice(text: string, contactId = this.owner, forModel?: string): Promise<void> {
		const conversation = await this.host.person(contactId);
		const model = forModel ? { model: [{ role: "user", content: forModel, timestamp: this.host.now() }] } : {};
		await conversation.submit({ type: "write", entry: { kind: NOTICE_ENTRY, data: { text, at: new Date(this.host.now()).toISOString() }, ...model } } as never, this.host.context);
	}

	// ── Tools ──

	private makeTools() {
		const self = this;
		const sendTool = defineTool({
			name: "send_message",
			description: "Send a message to someone: the owner or one of the agent's contacts (by id). Use it in automatic runs, or to reach another person. Quiet hours and the daily limit may hold it until later.",
			parameters: Type.Object({ to: Type.String({ description: "A contact id, e.g. owner" }), text: Type.String(), urgent: Type.Optional(Type.Boolean({ description: "Only for what can't wait until morning" })) }),
			execute: async (args, api) => {
				const from = (await self.runOf(api.conversationId))?.id ?? `person:${await self.personOf(api.conversationId)}`;
				try {
					const r = await self.send(args.to, args.text, from, args.urgent ?? false);
					const when = r.until ? new Date(r.until).toISOString().slice(0, 16).replace("T", " ") : "";
					const name = self.def.contacts.find((c) => c.id === args.to)?.name ?? args.to;
					const why = r.reason === "quiet" ? "quiet hours" : r.reason === "limit" ? "daily limit" : "paused";
					const card: ResultCard = { kind: "message", title: r.status === "sent" ? `Sent to ${name}` : `Held for ${name} (${why})`, detail: args.text };
					const undo = r.outboxId ? await self.host.recordUndo?.("outbox.withdraw", { outboxId: r.outboxId }, `the message to ${name}`, api.conversationId) : undefined;
					const text = r.status === "sent" ? `Sent to ${args.to}.` : r.reason === "paused" ? "Held: the agent is paused; it goes when it's resumed." : `Held until ${when} UTC (${why}); it goes then.`;
					return { output: [{ type: "text", text }], details: { ...r, card, ...(undo ? { undo } : {}) } as never };
				} catch (error) {
					return { output: [{ type: "text", text: (error as Error).message }], isError: true };
				}
			},
		});

		const scheduleTool = defineTool({
			name: "schedule",
			description: "Set a reminder or a recurring task for yourself: at a moment (ISO date and time, e.g. 2026-10-23T09:00 local time), or on a cron (\"0 9 * * 1\"). When it fires you get the prompt in an automatic run.",
			parameters: Type.Object({
				when: Type.String({ description: "An ISO date-time in the agent's time zone, or a 5-field cron" }),
				prompt: Type.String({ description: "What to do then, e.g. “Remind Antonio to call the plumber”" }),
				to: Type.Optional(Type.String({ description: "Who it's usually for (a contact id). Default: the owner" })),
			}),
			execute: async (args, api) => {
				const now = self.host.now();
				const by = (await self.personOf(api.conversationId)) ?? "run";
				const reminder: Reminder = { id: `rem${now.toString(36)}`, prompt: args.prompt, ...(args.to ? { deliverTo: args.to } : {}), createdAt: new Date(now).toISOString(), by, tz: self.tz };
				if (!cronError(args.when)) reminder.cron = args.when;
				else {
					const at = parseLocal(args.when, self.tz);
					if (at === undefined) return { output: [{ type: "text", text: "Give an ISO date-time (2026-10-23T09:00) or a cron (0 9 * * 1)." }], isError: true };
					if (at <= now) return { output: [{ type: "text", text: passedText(now, self.tz) }], isError: true };
					reminder.at = at;
				}
				await self.host.write((s) => void (s.reminders = [...(s.reminders ?? []), reminder]));
				await self.reconcile();
				const next = reminder.at ?? nextFire(reminder.cron!, self.tz, now);
				const card: ResultCard = { kind: "reminder", title: reminder.cron ? cronLabel(reminder.cron) : `Reminder ${new Date(next).toISOString().slice(0, 16).replace("T", " ")} UTC`, detail: args.prompt };
				const undo = await self.host.recordUndo?.("reminder.cancel", { id: reminder.id }, `the reminder “${args.prompt.slice(0, 60)}”`, api.conversationId);
				return { output: [{ type: "text", text: `Scheduled ${reminder.id}: next ${new Date(next).toISOString().slice(0, 16).replace("T", " ")} UTC.` }], details: { id: reminder.id, next, card, ...(undo ? { undo } : {}) } as never };
			},
		});

		const listTool = defineTool({
			name: "list_schedules",
			description: "List the schedules (from your definition), and the reminders and event routines (watches) you set.",
			parameters: Type.Object({}),
			execute: async () => {
				const lines = [
					...(self.def.schedules ?? []).map((s) => `- ${s.id} (definition) ${s.cron}: ${s.prompt}`),
					...(self.def.heartbeat ? [`- heartbeat every ${self.def.heartbeat.every}`] : []),
					...((await self.host.read()).reminders ?? []).map((r) => `- ${r.id} (yours) ${r.cron ?? new Date(r.at!).toISOString().slice(0, 16)}: ${r.prompt}`),
					...((await self.host.read()).watches ?? []).map((w) => `- ${w.id} (yours) ${watchLabel(w)}${w.on === "webhook" && self.host.watchUrl?.(w.id) ? ` at ${self.host.watchUrl(w.id)}` : ""}: ${w.prompt}`),
				];
				return { output: [{ type: "text", text: lines.join("\n") || "No schedules." }] };
			},
		});

		const cancelTool = defineTool({
			name: "cancel_schedule",
			description: "Cancel a reminder or an event routine (watch) you set, by id. Schedules in your definition are changed by the owner.",
			parameters: Type.Object({ id: Type.String() }),
			execute: async (args, api) => {
				const watch = ((await self.host.read()).watches ?? []).find((w) => w.id === args.id);
				if (watch) {
					await self.cancelWatch(watch.id);
					const card: ResultCard = { kind: "reminder", title: "Routine removed", detail: `${watchLabel(watch)}: ${watch.prompt}` };
					const undo = await self.host.recordUndo?.("watch.restore", { watch }, `removing “${watch.prompt.slice(0, 60)}”`, api.conversationId);
					return { output: [{ type: "text", text: `Removed ${args.id}.` }], details: { card, ...(undo ? { undo } : {}) } as never };
				}
				const reminder = ((await self.host.read()).reminders ?? []).find((r) => r.id === args.id);
				if (!reminder) return { output: [{ type: "text", text: `No reminder ${args.id}.` }], isError: true };
				await self.host.write((s) => void (s.reminders = (s.reminders ?? []).filter((r) => r.id !== args.id)));
				await self.reconcile();
				const card: ResultCard = { kind: "reminder", title: "Reminder cancelled", detail: reminder.prompt };
				const undo = await self.host.recordUndo?.("reminder.restore", { reminder }, `cancelling “${reminder.prompt.slice(0, 60)}”`, api.conversationId);
				return { output: [{ type: "text", text: `Cancelled ${args.id}.` }], details: { card, ...(undo ? { undo } : {}) } as never };
			},
		});

		const watchTool = defineTool({
			name: "watch",
			description:
				"Set an event routine for yourself: when something happens, you get the prompt in an automatic run with what happened. on: \"email\" (a new email, from someone and/or with words in the subject, in the owner's connected mail), \"folder\" (a file appears or changes in a folder on this Mac), or \"webhook\" (you get a URL other apps can call; the request body comes with the run). For times use schedule instead.",
			parameters: Type.Object({
				on: Type.Union([Type.Literal("email"), Type.Literal("folder"), Type.Literal("webhook")]),
				prompt: Type.String({ description: "What to do then, e.g. “Summarize the invoice and tell Antonio the amount”" }),
				from: Type.Optional(Type.String({ description: "email: part of the sender's name or address" })),
				subject: Type.Optional(Type.String({ description: "email: words in the subject" })),
				folder: Type.Optional(Type.String({ description: "folder: an absolute path, or one starting with ~/" })),
				to: Type.Optional(Type.String({ description: "Who it's usually for (a contact id). Default: the owner" })),
			}),
			execute: async (args, api) => {
				const now = self.host.now();
				if (args.on === "email" && !args.from?.trim() && !args.subject?.trim()) return { output: [{ type: "text", text: "Say whose emails (from) or which subject to watch for." }], isError: true };
				if (args.on === "folder" && !/^(\/|~\/)/.test(args.folder?.trim() ?? "")) return { output: [{ type: "text", text: "Give the folder as an absolute path (/Users/…) or one starting with ~/." }], isError: true };
				const by = (await self.personOf(api.conversationId)) ?? "run";
				const watch: Watch = {
					id: `w${now.toString(36)}`,
					on: args.on,
					prompt: args.prompt,
					...(args.on === "folder" ? { folder: args.folder!.trim() } : {}),
					...(args.on === "email" && args.from?.trim() ? { from: args.from.trim() } : {}),
					...(args.on === "email" && args.subject?.trim() ? { subject: args.subject.trim() } : {}),
					...(args.to ? { deliverTo: args.to } : {}),
					createdAt: new Date(now).toISOString(),
					by,
				};
				await self.host.write((s) => void (s.watches = [...(s.watches ?? []), watch]));
				self.host.onWatches?.();
				const url = watch.on === "webhook" ? self.host.watchUrl?.(watch.id) : undefined;
				const card: ResultCard = { kind: "reminder", title: watchLabel(watch), detail: args.prompt };
				const undo = await self.host.recordUndo?.("watch.cancel", { id: watch.id }, `the routine “${args.prompt.slice(0, 60)}”`, api.conversationId);
				const text = `Set ${watch.id}: ${watchLabel(watch)}.${url ? ` Its URL (POST, from this Mac): ${url}` : ""}`;
				return { output: [{ type: "text", text }], details: { id: watch.id, card, ...(url ? { url } : {}), ...(undo ? { undo } : {}) } as never };
			},
		});

		return { send: sendTool, schedule: scheduleTool, list: listTool, cancel: cancelTool, watch: watchTool, ...this.automationTools() };
	}

	/**
	 * Automations (docs/spec/27): the agent makes, lists, changes and removes its own, always run as itself (AU5).
	 * Each change is a card with Undo. Absent when the host keeps no automations (the cloud, for now).
	 */
	private automationTools() {
		const self = this;
		const bridge = () => {
			const b = self.host.automations;
			if (!b) throw new Error("Automations aren't available here.");
			return b;
		};
		const fail = (error: unknown) => ({ output: [{ type: "text" as const, text: (error as Error).message }], isError: true });
		const card = (title: string, s: AutomationSummary): ResultCard => ({ kind: "automation", title, detail: `${s.when} · ${s.does}`, automation: s });
		const describe = (s: AutomationSummary) => `${s.id} “${s.name}”: ${s.when}; ${s.does}; tells: ${s.tellsYou}.${s.next ? ` First run ${new Date(s.next).toISOString().slice(0, 16).replace("T", " ")} UTC.` : ""}${s.url ? ` Its URL (POST, from this Mac): ${s.url}` : ""}`;
		const trigger = {
			on: Type.Optional(Type.Union([Type.Literal("time"), Type.Literal("email"), Type.Literal("folder"), Type.Literal("webhook")], { description: "What starts it (default time)" })),
			when: Type.Optional(Type.String({ description: "time: a 5-field cron (\"0 9 * * 1\" is Mondays at 9) or a local date-time once (2026-11-23T09:00)" })),
			from: Type.Optional(Type.String({ description: "email: part of the sender's name or address" })),
			subject: Type.Optional(Type.String({ description: "email: words in the subject" })),
			folder: Type.Optional(Type.String({ description: "folder: an absolute path, or one starting with ~/" })),
		};
		const rest = {
			name: Type.Optional(Type.String({ description: "A few words, e.g. “Weekly competitor brief”" })),
			result: Type.Optional(Type.Union([Type.Literal("chat"), Type.Literal("telegram"), Type.Literal("quiet")], { description: "Where the result goes: chat (your chat with the owner, the default), telegram (only if you're connected), quiet (only message when something needs them)" })),
			approval: Type.Optional(Type.Union([Type.Literal("wait"), Type.Literal("skip")], { description: "When a run needs the owner's OK: wait for it (default) or skip that run" })),
			budget: Type.Optional(Type.Number({ description: "USD per run; default 0.25" })),
		};
		const automate = defineTool({
			name: "automate",
			description:
				"Make an automation: work you'll do on your own, when nobody asks. A time (once or repeating), a new email, a file in a folder, or a URL other apps can call. Each time it fires you get the prompt in an automatic run. Use it when the owner asks for something regular or for later (\"every Monday at 9…\", \"remind me Thursday…\", \"when an invoice arrives…\"). It always runs as you, with your own tools, outside any project. Don't make one for work you can't do yourself: when the owner wants Piopio or another agent to do it, or wants a project's files read or changed, make nothing and tell them to ask Piopio (from Home, or in that project), which can.",
			parameters: Type.Object({ ...trigger, prompt: Type.String({ description: "What to do then, in plain words" }), ...rest, to: Type.Optional(Type.String({ description: "Who it's for (a contact id). Default: the owner" })) }),
			execute: async (args, api) => {
				try {
					const by = (await self.personOf(api.conversationId)) ?? "run";
					const s = await bridge().add(args as AutomationToolInput, by);
					const undo = await self.host.recordUndo?.("automation.remove", { id: s.id }, `the automation “${s.name}”`, api.conversationId);
					return { output: [{ type: "text", text: `Made ${describe(s)} The owner sees it in Automations.` }], details: { id: s.id, card: card(s.name, s), ...(undo ? { undo } : {}) } as never };
				} catch (error) {
					return fail(error);
				}
			},
		});
		const list = defineTool({
			name: "list_automations",
			description: "Your automations: what starts each one, what it does, where it tells, and when it runs next.",
			parameters: Type.Object({}),
			execute: async () => {
				try {
					return { output: [{ type: "text", text: await bridge().list() }] };
				} catch (error) {
					return fail(error);
				}
			},
		});
		const change = defineTool({
			name: "change_automation",
			description: "Change one of your automations, by id: its time or event, prompt, name, result, approval, budget, or pause it (enabled false) and resume it.",
			parameters: Type.Object({ id: Type.String(), ...trigger, prompt: Type.Optional(Type.String()), ...rest, enabled: Type.Optional(Type.Boolean()) }),
			execute: async (args, api) => {
				try {
					const { id, ...input } = args;
					const { summary, before } = await bridge().change(id, input as AutomationToolInput);
					const undo = await self.host.recordUndo?.("automation.restore", { before }, `the change to “${summary.name}”`, api.conversationId);
					return { output: [{ type: "text", text: `Changed ${describe(summary)}` }], details: { id, card: card(`Changed · ${summary.name}`, summary), ...(undo ? { undo } : {}) } as never };
				} catch (error) {
					return fail(error);
				}
			},
		});
		const cancel = defineTool({
			name: "cancel_automation",
			description: "Remove one of your automations, by id.",
			parameters: Type.Object({ id: Type.String() }),
			execute: async (args, api) => {
				try {
					const { summary, before } = await bridge().remove(args.id);
					const undo = await self.host.recordUndo?.("automation.restore", { before }, `removing “${summary.name}”`, api.conversationId);
					return { output: [{ type: "text", text: `Removed ${summary.id} “${summary.name}”.` }], details: { card: { kind: "automation", title: `Removed · ${summary.name}`, detail: summary.when }, ...(undo ? { undo } : {}) } as never };
				} catch (error) {
					return fail(error);
				}
			},
		});
		return { automate, listAutomations: list, changeAutomation: change, cancelAutomation: cancel };
	}

	/**
	 * Reminders and watches the agent set itself, handed over to the host's automations (docs/spec/27 §6) and cleared
	 * here, with its runs for their history. Returns nothing to hand over the second time.
	 */
	async handOver(): Promise<{ reminders: Reminder[]; watches: Watch[]; runs: RunRecord[] }> {
		const state = await this.host.read();
		const reminders = state.reminders ?? [];
		const watches = state.watches ?? [];
		if (!reminders.length && !watches.length) return { reminders, watches, runs: [] };
		await this.host.write((s) => {
			s.reminders = [];
			s.watches = [];
		});
		await this.reconcile();
		this.host.onWatches?.();
		return { reminders, watches, runs: state.runs ?? [] };
	}

	/** The reminders it set itself, as they are (moving an agent between the Mac and the cloud reads them). */
	async reminders(): Promise<Reminder[]> {
		return structuredClone((await this.host.read()).reminders ?? []);
	}

	/** Undo of an automation change (the host keeps them). */
	async undoAutomation(data: { id?: string; before?: JsonObject }): Promise<void> {
		if (!this.host.automations) throw new Error("Automations aren't available here.");
		await this.host.automations.undo(data);
	}

	private async personOf(conversationId: ConversationId | string): Promise<string | undefined> {
		const people = (await this.host.read()).people;
		return Object.entries(people).find(([, c]) => c === String(conversationId))?.[0];
	}
}

function extras(extra?: { label?: string; note?: string; budgetUsd?: number }) {
	return { ...(extra?.label ? { label: extra.label } : {}), ...(extra?.note ? { note: extra.note } : {}), ...(extra?.budgetUsd ? { budgetUsd: extra.budgetUsd } : {}) };
}

function runId(key: string): string {
	let h = 5381;
	for (const ch of key) h = ((h * 33) ^ ch.charCodeAt(0)) >>> 0;
	return `run_${h.toString(36)}${key.length.toString(36)}`;
}

/** "2026-10-23T09:00" (wall clock in `tz`), or with an offset or Z. */
export function parseLocal(text: string, tz: string): number | undefined {
	const t = text.trim();
	if (/[zZ]|[+-]\d\d:?\d\d$/.test(t)) {
		const ms = Date.parse(t);
		return Number.isNaN(ms) ? undefined : ms;
	}
	const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?$/.exec(t);
	if (!m) return undefined;
	// Find the UTC moment whose wall clock in `tz` is this (two passes absorb the offset).
	const want = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4] ?? 9), Number(m[5] ?? 0));
	let guess = want;
	for (let i = 0; i < 2; i++) {
		const f = new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric" });
		const p = Object.fromEntries(f.formatToParts(new Date(guess)).map((x) => [x.type, x.value]));
		const seen = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day), Number(p.hour) % 24, Number(p.minute));
		guess += want - seen;
	}
	return guess;
}

/** "When an email from the bank arrives", "When a file appears in ~/Downloads", "When its URL is called". */
export function watchLabel(w: Pick<Watch, "on" | "from" | "subject" | "folder">): string {
	if (w.on === "email") return `When an email${w.from ? ` from ${w.from}` : ""}${w.subject ? ` about “${w.subject}”` : ""} arrives`;
	if (w.on === "folder") return `When a file appears or changes in ${w.folder}`;
	return "When its URL is called";
}

