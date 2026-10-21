/**
 * Proactivity (docs/spec/06-agents §6 PR1–PR6): schedules, the heartbeat and reminders the agent sets are
 * pi-durable tasks that sleep until their next fire, so they survive restarts (a fire missed while the engine was
 * off happens once when it comes back). Each fire is a run: its own conversation (`run:<id>`), recorded with its
 * outcome. `send_message` delivers to a person's conversation (the in-app channel) unless quiet hours or the daily
 * limit hold it; held messages wait in the outbox, which a task flushes when they may go.
 */
import type { Context } from "@earendil-works/chord/context";
import { Type } from "@earendil-works/pi-ai";
import { defineTask, defineTool, type ConversationId, type Harness, type TaskId } from "@earendil-works/pi-durable";
import { cronError, type AgentDefinition } from "./definition.js";
import { dayOf, inWindow, nextDay, nextFire, nextHeartbeat, windowEnd } from "./time.js";

export type RunKind = "schedule" | "heartbeat" | "reminder" | "trigger" | "manual";
export type RunRecord = {
	id: string;
	kind: RunKind;
	/** The schedule, reminder or trigger id. */
	source: string;
	prompt: string;
	firedAt: string;
	conversationId: string;
	deliverTo?: string;
	status: "running" | "done" | "failed";
	/** The run's last answer, in a line. */
	summary?: string;
	sent: number;
	costUsd?: number;
};
/** A reminder or schedule the agent made (the `schedule` tool). */
export type Reminder = { id: string; prompt: string; deliverTo?: string; at?: number; cron?: string; tz?: string; createdAt: string; by: string };
export type Outbound = { id: string; to: string; text: string; from: string; queuedAt: string; notBefore: number; reason: "quiet" | "limit"; urgent?: boolean };
/** A schedule, the heartbeat or a reminder, with its next fire (the Runs tab). */
export type Upcoming = { id: string; kind: "schedule" | "heartbeat" | "reminder"; label: string; next?: number };
export type ProactiveState = {
	runs?: RunRecord[];
	reminders?: Reminder[];
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
	/** Memory for a run: what's relevant to its prompt, from the owner's and shared partitions. */
	recallForRun(conversationId: ConversationId, prompt: string): Promise<void>;
	/** Someone was sent a message (the app shows it; channels deliver it). */
	onOutbound?(to: string, text: string, from: string): void;
	/** A run started or settled (the Runs tab). */
	onRun?(run: RunRecord): void;
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
					await runtime.sleep(next, context);
					await runtime.commit(() => ({ status: "running", checkpoint: { phase: "fire", at: next } }), context);
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

		this.outboxTask = defineTask<Record<string, never>, { phase: "wait" }, null>({
			name: "piopio.outbox",
			version: 1,
			initial: () => ({ phase: "wait" }),
			phases: {
				wait: async (_task, runtime, context) => {
					const state = await self.host.read();
					const pending = state.outbox ?? [];
					if (!pending.length) return runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: null } }), context);
					await runtime.sleep(Math.min(...pending.map((o) => o.notBefore)), context);
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
		for (const status of ["pending", "running", "waiting"] as const) {
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
	async startRun(kind: RunKind, source: string, prompt: string, deliverTo?: string, requestKey?: string): Promise<RunRecord> {
		const key = requestKey ?? `${kind}:${source}@${this.host.now()}`;
		const existing = ((await this.host.read()).runs ?? []).find((r) => r.id === runId(key));
		if (existing) return existing;
		const conversationId = await this.host.newConversation();
		const run: RunRecord = { id: runId(key), kind, source, prompt, firedAt: new Date(this.host.now()).toISOString(), conversationId: String(conversationId), ...(deliverTo ? { deliverTo } : {}), status: "running", sent: 0 };
		await this.host.write((s) => {
			s.runs = [...(s.runs ?? []), run].slice(-MAX_RUNS);
		});
		await this.host.recallForRun(conversationId, prompt).catch(() => undefined);
		const conversation = await this.host.harness.conversation(conversationId, this.host.context);
		const submission = (await conversation!.submit({ type: "input", content: prompt, requestId: key } as never, this.host.context)) as { wait(c: Context): Promise<{ status: string }> };
		this.host.onRun?.(run);
		void submission.wait(this.host.context).then(
			(settled) => this.settle(run.id, settled.status === "done" ? "done" : "failed"),
			() => undefined,
		);
		return run;
	}

	/** Brings back the wait on runs a previous engine left running. */
	async resumeRuns(): Promise<void> {
		for (const run of ((await this.host.read()).runs ?? []).filter((r) => r.status === "running")) {
			const conversation = await this.host.harness.conversation(Number(run.conversationId) as never, this.host.context);
			if (!conversation) continue;
			void conversation.waitForIdle(this.host.context).then(() => this.settle(run.id, "done"), () => undefined);
		}
	}

	private async settle(id: string, status: "done" | "failed"): Promise<void> {
		const run = ((await this.host.read()).runs ?? []).find((r) => r.id === id);
		if (!run) return;
		const conversation = await this.host.harness.conversation(Number(run.conversationId) as never, this.host.context);
		const view = await conversation!.viewState(this.host.context);
		const entries = view.value.entries as readonly { kind: string; model?: { role: string; content?: unknown; usage?: { cost?: { total?: number } } }[] }[];
		view.dispose();
		let costUsd = 0;
		let summary = "";
		for (const e of entries) {
			const m = e.model?.[0];
			if (m?.role !== "assistant") continue;
			costUsd += m.usage?.cost?.total ?? 0;
			const text = Array.isArray(m.content) ? (m.content as { type: string; text?: string }[]).filter((b) => b.type === "text").map((b) => b.text ?? "").join("") : "";
			if (text.trim()) summary = text.trim();
		}
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
		for (const s of this.def.schedules ?? []) withNext(`def:${s.id}`, { id: s.id, kind: "schedule", label: `${s.cron} · ${s.prompt}` });
		if (this.def.heartbeat) withNext("heartbeat", { id: "heartbeat", kind: "heartbeat", label: `Every ${this.def.heartbeat.every}${this.def.heartbeat.activeHours ? ` (${this.def.heartbeat.activeHours})` : ""}` });
		for (const r of state.reminders ?? []) withNext(`rem:${r.id}`, { id: r.id, kind: "reminder", label: r.prompt });
		return { runs: [...(state.runs ?? [])].reverse(), outbox: state.outbox ?? [], upcoming };
	}

	/** The run a conversation belongs to. */
	async runOf(conversationId: ConversationId | string): Promise<RunRecord | undefined> {
		return ((await this.host.read()).runs ?? []).find((r) => r.conversationId === String(conversationId));
	}

	runPrompt(run: RunRecord): string {
		const what = run.kind === "schedule" ? `the schedule “${run.source}”` : run.kind === "heartbeat" ? "your heartbeat" : run.kind === "reminder" ? `a reminder you set (${run.source})` : run.kind === "trigger" ? `the trigger “${run.source}”` : "a manual run";
		const to = run.deliverTo ?? this.owner;
		return `This is an automatic run, started by ${what} at ${run.firedAt.slice(0, 16).replace("T", " ")} UTC. Nobody reads this conversation. To tell someone something, use send_message (usually to “${to}”). If there's nothing worth saying, don't send anything and answer “Nothing to report.”`;
	}

	// ── Messages ──

	/** Sends now, or queues for after quiet hours or the daily limits (PR4, PR5). */
	async send(to: string, text: string, from: string, urgent = false): Promise<{ status: "sent" | "queued"; until?: number; reason?: "quiet" | "limit" }> {
		const def = this.def;
		if (!def.contacts.some((c) => c.id === to)) throw new Error(`No contact “${to}”. Contacts: ${def.contacts.map((c) => c.id).join(", ")}.`);
		const now = this.host.now();
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

	private async queue(to: string, text: string, from: string, notBefore: number, reason: "quiet" | "limit", urgent: boolean) {
		await this.host.write((s) => {
			s.outbox = [...(s.outbox ?? []), { id: `out_${this.host.now().toString(36)}_${(s.outbox?.length ?? 0) + 1}`, to, text, from, queuedAt: new Date(this.host.now()).toISOString(), notBefore, reason, ...(urgent ? { urgent } : {}) }];
		});
		await this.ensureOutbox();
		return { status: "queued" as const, until: notBefore, reason };
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

	/** A note for the owner in their conversation (not a message from the agent, not counted). */
	private async notice(text: string): Promise<void> {
		const conversation = await this.host.person(this.owner);
		await conversation.submit({ type: "write", entry: { kind: NOTICE_ENTRY, data: { text, at: new Date(this.host.now()).toISOString() } } } as never, this.host.context);
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
					return { output: [{ type: "text", text: r.status === "sent" ? `Sent to ${args.to}.` : `Held until ${when} UTC (${r.reason === "quiet" ? "quiet hours" : "daily limit"}); it goes then.` }], details: r as never };
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
					if (at <= now) return { output: [{ type: "text", text: "That moment has passed." }], isError: true };
					reminder.at = at;
				}
				await self.host.write((s) => void (s.reminders = [...(s.reminders ?? []), reminder]));
				await self.reconcile();
				const next = reminder.at ?? nextFire(reminder.cron!, self.tz, now);
				return { output: [{ type: "text", text: `Scheduled ${reminder.id}: next ${new Date(next).toISOString().slice(0, 16).replace("T", " ")} UTC.` }], details: { id: reminder.id, next } as never };
			},
		});

		const listTool = defineTool({
			name: "list_schedules",
			description: "List the schedules (from your definition) and the reminders you set, with their next time.",
			parameters: Type.Object({}),
			execute: async () => {
				const lines = [
					...(self.def.schedules ?? []).map((s) => `- ${s.id} (definition) ${s.cron}: ${s.prompt}`),
					...(self.def.heartbeat ? [`- heartbeat every ${self.def.heartbeat.every}`] : []),
					...((await self.host.read()).reminders ?? []).map((r) => `- ${r.id} (yours) ${r.cron ?? new Date(r.at!).toISOString().slice(0, 16)}: ${r.prompt}`),
				];
				return { output: [{ type: "text", text: lines.join("\n") || "No schedules." }] };
			},
		});

		const cancelTool = defineTool({
			name: "cancel_schedule",
			description: "Cancel a reminder you set (by id). Schedules in your definition are changed by the owner.",
			parameters: Type.Object({ id: Type.String() }),
			execute: async (args) => {
				const had = ((await self.host.read()).reminders ?? []).some((r) => r.id === args.id);
				if (!had) return { output: [{ type: "text", text: `No reminder ${args.id}.` }], isError: true };
				await self.host.write((s) => void (s.reminders = (s.reminders ?? []).filter((r) => r.id !== args.id)));
				await self.reconcile();
				return { output: [{ type: "text", text: `Cancelled ${args.id}.` }] };
			},
		});

		return { send: sendTool, schedule: scheduleTool, list: listTool, cancel: cancelTool };
	}

	private async personOf(conversationId: ConversationId | string): Promise<string | undefined> {
		const people = (await this.host.read()).people;
		return Object.entries(people).find(([, c]) => c === String(conversationId))?.[0];
	}
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
