/**
 * Automations (docs/spec/27 §5): one store, one clock, one set of watchers, one way to fire. A time automation sleeps
 * until its next fire (a fire missed while the engine was off runs once when it's back); folder and email ones are
 * handed to the watchers; webhook ones are called through the hooks endpoint, at their own address or one they had
 * before. A fire is a run: an agent's (its run machinery, 06 PR1) or Piopio's (a new conversation, in the project's
 * folder or loose). Rules live here, not in the prompts (26 §7.2): who may run what, where, and with which result.
 */
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname } from "node:path";
import { EngineError } from "../models.js";
import type { AutomationSummary } from "@piopio/runtime";
import { DEFAULT_BUDGET, nameOf, nextOf, parseWhen, PIOPIO, resultLabel, systemZone, whenLabel, type Automation, type AutomationRun, type ResultTo, type RunStatus, type Trigger } from "./model.js";
import { writeFileAtomic } from "../atomic.js";

/** `cloud`: it runs in your cloud (docs/spec/30 K1), which keeps its own automations. */
export type AgentInfo = { id: string; name: string; telegram: boolean; cloud?: boolean };

export type AutomationsHost = {
	file: string;
	runsFile: string;
	log(line: string): void;
	/** One of your agents. */
	agent(id: string): AgentInfo | undefined;
	/** A project by id: its name and folder. */
	project(id: string): { id: string; name: string; path: string } | undefined;
	/** Starts an agent's run with this prompt; `key` makes a repeated fire the same run. */
	runAgent(agentId: string, automation: Automation, prompt: string, key: string): Promise<{ runId: string; conversationId: string; status: RunStatus; summary?: string }>;
	/** Piopio: a new conversation (in the project's folder, or loose) with this first message. Its session id. */
	runPiopio(automation: Automation, text: string): Promise<string>;
	/** A Piopio run's conversation now: running, waiting on you, and its cost. */
	session?(id: string): Promise<{ running: boolean; waiting: boolean; costUsd: number; error?: string } | undefined>;
	/** Stops a Piopio run's conversation (its budget, or a skip). */
	stopSession?(id: string): Promise<void>;
	/** How many mailboxes are connected (an email automation needs one to see anything). */
	mailboxes?(): number;
	/** A webhook automation's address. */
	hookUrl?(id: string): string | undefined;
	/** Resolves when runs can reach their model's key (the app is connected, or it waited long enough). */
	ready?(): Promise<unknown>;
	/** The list or a run changed (the app lists again). */
	changed(): void;
	/** Folder and email automations changed: the watchers start or stop theirs. */
	watchesChanged(): void;
	now?: () => number;
};

/** What `add` and `update` take: the trigger as words (`when`), the rest as the model. */
export type AutomationInput = {
	name?: string;
	on?: Trigger;
	when?: string;
	folder?: string;
	from?: string;
	subject?: string;
	runsAs?: string;
	project?: string | null;
	prompt?: string;
	result?: ResultTo;
	deliverTo?: string;
	approval?: "wait" | "skip";
	budgetPerRunUsd?: number | null;
	enabled?: boolean;
};

type Store = { automations: Automation[]; fired: string[] };

const MAX_RUNS = 100;
const quote = (text: string) => text.split("\n").map((l) => `> ${l}`).join("\n");

export class Automations {
	private store: Store;
	private runs: AutomationRun[];
	private timer?: NodeJS.Timeout;
	private budgetTimer?: NodeJS.Timeout;
	private stopped = false;
	/** Agent runs that settled before `fire` recorded them (a fast run), by "<agent>/<run>". */
	private readonly early = new Map<string, { id: string; status: "running" | "done" | "failed" | "skipped"; summary?: string; sent: number; costUsd?: number }>();
	/** Removed while the engine runs, by id: a card's Redo brings one back (`restoreRemoved`). Not kept on disk. */
	private readonly removed = new Map<string, Automation>();

	constructor(private readonly host: AutomationsHost) {
		this.store = { automations: [], fired: [], ...readJson<Partial<Store>>(host.file) };
		this.runs = readJson<AutomationRun[]>(host.runsFile) ?? [];
	}

	private now(): number {
		return this.host.now?.() ?? Date.now();
	}

	// ── The list ──

	list(): Automation[] {
		return this.store.automations;
	}

	get(id: string): Automation {
		const a = this.store.automations.find((x) => x.id === id);
		if (!a) throw new EngineError("NOT_FOUND", `No automation ${id}.`);
		return a;
	}

	find(id: string): Automation | undefined {
		return this.store.automations.find((x) => x.id === id);
	}

	/** What a card shows (27 §4): when, who, what, where the result goes, where it runs. */
	summary(a: Automation): AutomationSummary {
		const piopio = a.runsAs === PIOPIO;
		const name = piopio ? "Piopio" : (this.host.agent(a.runsAs)?.name ?? "An agent");
		const project = a.project ? this.host.project(a.project)?.name : undefined;
		const url = a.on === "webhook" ? this.host.hookUrl?.(a.id) : undefined;
		const does = a.prompt.split("\n")[0]!.trim();
		return {
			id: a.id,
			name: a.name,
			when: whenLabel(a),
			runsAs: this.runnerName(a),
			does: does.length > 120 ? `${does.slice(0, 119).trimEnd()}…` : does,
			tellsYou: resultLabel(a.result, { piopio, name }, project),
			runsOn: "This Mac, only while it's awake",
			...(url ? { url } : {}),
			...(a.next ? { next: a.next } : {}),
		};
	}

	/** Who runs it, in words: "Piopio", "Piopio in shop", "Rita". */
	runnerName(a: Automation): string {
		if (a.runsAs === PIOPIO) return a.project ? `Piopio in ${this.host.project(a.project)?.name ?? "a project"}` : "Piopio";
		return this.host.agent(a.runsAs)?.name ?? "An agent that's gone";
	}

	/** A new automation: yours (the app), Piopio's or an agent's (their tools). Checked as a whole before it's kept. */
	add(input: AutomationInput, by: string, id?: string): Automation {
		const now = this.now();
		const a = this.validate(
			{
				id: id ?? `a${now.toString(36)}${Math.random().toString(36).slice(2, 5)}`,
				name: "",
				on: input.on ?? "time",
				runsAs: input.runsAs ?? PIOPIO,
				prompt: input.prompt ?? "",
				result: input.result ?? "chat",
				approval: input.approval ?? "wait",
				enabled: input.enabled ?? true,
				by,
				createdAt: new Date(now).toISOString(),
				runCount: 0,
				fresh: true,
			},
			input,
			true,
		);
		this.store.automations.push(a);
		this.saved(a.on !== "time");
		return a;
	}

	/** A change: any field, the trigger as words. The result is checked as a whole, as `add` does. */
	update(id: string, change: AutomationInput): Automation {
		const current = this.get(id);
		const triggerChanged = change.on !== undefined || change.when !== undefined || change.folder !== undefined || change.from !== undefined || change.subject !== undefined;
		const next = this.validate({ ...current }, change, triggerChanged);
		Object.assign(current, next);
		for (const key of Object.keys(current) as (keyof Automation)[]) if (next[key] === undefined) delete current[key];
		this.saved(true);
		return current;
	}

	remove(id: string): Automation {
		const a = this.get(id);
		this.store.automations = this.store.automations.filter((x) => x.id !== id);
		this.removed.set(id, structuredClone(a));
		this.saved(a.on !== "time");
		return a;
	}

	/** Redo of an Undo (a creation card): the one removed with this id comes back as it was. */
	restoreRemoved(id: string): Automation {
		if (this.find(id)) return this.get(id);
		const a = this.removed.get(id);
		if (!a) throw new EngineError("NOT_FOUND", "It can't come back any more. Ask again to make it.");
		const back = this.restore(a);
		this.removed.delete(id);
		return back;
	}

	/** Undo of a removal or a change: it comes back as it was (a once whose moment has passed doesn't). */
	restore(a: Automation): Automation {
		a = { ...a };
		if (a.on === "time") {
			a.next = nextOf(a, this.now());
			if (a.next === undefined) throw new EngineError("INVALID", "Its moment has passed.");
		}
		this.store.automations = [...this.store.automations.filter((x) => x.id !== a.id), a];
		this.saved(a.on !== "time");
		return a;
	}

	/** You opened it: the "New" badge goes. */
	opened(id: string): void {
		const a = this.get(id);
		if (!a.fresh) return;
		delete a.fresh;
		this.saved(false);
	}

	/** The rules (27 §5): who runs it, where, with which result; the trigger as words. Throws what to do instead. */
	private validate(base: Automation, input: AutomationInput, trigger: boolean): Automation {
		const a: Automation = { ...base };
		const now = this.now();
		if (input.prompt !== undefined) a.prompt = input.prompt.trim();
		if (!a.prompt) throw new EngineError("INVALID", "Say what should happen then.");
		if (input.name !== undefined) a.name = input.name.trim();
		if (!a.name) a.name = nameOf(a.prompt);
		if (input.runsAs !== undefined) a.runsAs = input.runsAs.trim() || PIOPIO;
		const piopio = a.runsAs === PIOPIO;
		const agent = piopio ? undefined : this.host.agent(a.runsAs);
		if (!piopio && !agent) throw new EngineError("INVALID", `No agent “${a.runsAs}”. Run it as Piopio or as one of your agents.`);
		// A cloud agent's automations live up there, as its schedules and reminders: it makes them itself.
		if (agent?.cloud && (input.runsAs !== undefined || trigger || input.enabled === true)) throw new EngineError("INVALID", `${agent.name} runs in your cloud, which keeps its own automations. Ask it in its chat (“every weekday at 8, …”), or move it to this Mac first.`);
		if (input.project !== undefined) {
			if (input.project) a.project = input.project;
			else delete a.project;
		}
		if (a.project) {
			if (!piopio) throw new EngineError("INVALID", "Only Piopio works in a project. Run it as Piopio there (its prompt can ask an agent with @Name), or leave the project out.");
			const project = this.host.project(a.project);
			if (!project) throw new EngineError("INVALID", `No project “${a.project}”.`);
			a.project = project.id;
		}
		if (input.result !== undefined) a.result = input.result;
		// Piopio has no channels (AU7): a conversation, or only if it needs you. An agent: its chat, Telegram, or quiet.
		if (piopio && (a.result === "chat" || a.result === "telegram")) {
			if (input.result === "telegram") throw new EngineError("INVALID", "Piopio has no channels. Its result opens a conversation, or stays quiet unless it needs you. To be told on Telegram, run it as an agent that has Telegram.");
			a.result = "conversation";
		}
		if (!piopio && a.result === "conversation") a.result = "chat";
		if (!piopio && a.result === "telegram" && !agent!.telegram) throw new EngineError("INVALID", `${agent!.name} isn't connected to Telegram. Connect it first, or tell the user in ${agent!.name}'s chat.`);
		if (input.deliverTo !== undefined) {
			if (input.deliverTo && !piopio) a.deliverTo = input.deliverTo;
			else delete a.deliverTo;
		}
		if (piopio) delete a.deliverTo;
		if (input.approval !== undefined) a.approval = input.approval;
		if (input.budgetPerRunUsd !== undefined) {
			if (input.budgetPerRunUsd === null) delete a.budgetPerRunUsd;
			else if (!(input.budgetPerRunUsd > 0)) throw new EngineError("INVALID", "A budget per run is more than $0.");
			else a.budgetPerRunUsd = input.budgetPerRunUsd;
		}
		if (a.budgetPerRunUsd === undefined) a.budgetPerRunUsd = piopio ? DEFAULT_BUDGET.piopio : DEFAULT_BUDGET.agent;
		if (input.enabled !== undefined) a.enabled = input.enabled;
		if (trigger) {
			if (input.on !== undefined) a.on = input.on;
			for (const key of ["cron", "at", "tz", "folder", "from", "subject"] as const) if (input.on !== undefined && input.on !== base.on) delete a[key];
			if (a.on === "time") {
				if (input.when !== undefined || (a.cron === undefined && a.at === undefined)) {
					const tz = systemZone();
					const when = parseWhen(input.when ?? "", tz, now);
					if ("error" in when) throw new EngineError("INVALID", when.error);
					delete a.cron;
					delete a.at;
					Object.assign(a, when, { tz });
				}
				delete a.folder;
				delete a.from;
				delete a.subject;
			} else {
				delete a.cron;
				delete a.at;
				delete a.tz;
				delete a.next;
				if (a.on === "folder") {
					const folder = (input.folder ?? a.folder ?? "").trim();
					if (!/^(\/|~\/)/.test(folder)) throw new EngineError("INVALID", "Give the folder as an absolute path (/Users/…) or one starting with ~/.");
					a.folder = folder;
					delete a.from;
					delete a.subject;
				} else if (a.on === "email") {
					const from = (input.from ?? a.from ?? "").trim();
					const subject = (input.subject ?? a.subject ?? "").trim();
					if (!from && !subject) throw new EngineError("INVALID", "Say whose emails (from) or which subject to watch for.");
					if (input.on === "email" && this.host.mailboxes?.() === 0) throw new EngineError("INVALID", "No mailbox is connected, so nothing would see that email. Tell the user to connect Gmail or Outlook in Settings › Connected apps, then ask again.");
					if (from) a.from = from;
					else delete a.from;
					if (subject) a.subject = subject;
					else delete a.subject;
					delete a.folder;
				} else {
					delete a.folder;
					delete a.from;
					delete a.subject;
				}
			}
		}
		if (a.on === "time") a.next = nextOf(a, now);
		return a;
	}

	// ── Runs ──

	/** Runs, newest first: one automation's, or everyone's. Their state is read again from the agent or the conversation. */
	async runsOf(id?: string, limit = 50): Promise<AutomationRun[]> {
		const list = this.runs.filter((r) => !id || r.automation === id).slice(-limit).reverse();
		for (const r of list) if (r.status === "running" || r.status === "waiting") await this.refresh(r).catch(() => undefined);
		return list;
	}

	/** A Piopio run's state, from its conversation. */
	private async refresh(r: AutomationRun): Promise<void> {
		if (r.agent || !r.conversation || !this.host.session) return;
		const s = await this.host.session(r.conversation);
		if (!s) return;
		// A turn that ended in an error (the model failed, the run threw) is a failed run, not a done one.
		const status: RunStatus = s.running ? "running" : s.waiting ? "waiting" : s.error ? "failed" : "done";
		if (status !== r.status || s.costUsd !== r.costUsd) {
			r.status = status;
			r.costUsd = s.costUsd;
			if (status === "failed") r.summary = s.error;
			this.saveRuns();
			if (status !== "running") this.host.changed();
		}
	}

	/** An agent's run started or settled (its onRun): the automation's run follows it. */
	agentRunChanged(agentId: string, run: { id: string; status: "running" | "done" | "failed" | "skipped"; summary?: string; sent: number; costUsd?: number }): void {
		const r = this.runs.find((x) => x.agent === agentId && x.agentRun === run.id);
		if (!r) {
			if (run.status !== "running") this.early.set(`${agentId}/${run.id}`, run);
			return;
		}
		// A skipped run stays skipped, but what it cost to get there still counts (A3).
		if (r.status === "skipped") {
			if (run.costUsd !== undefined && run.costUsd !== r.costUsd) {
				r.costUsd = run.costUsd;
				this.saveRuns();
				this.host.changed();
			}
			return;
		}
		r.status = run.status === "done" && run.sent === 0 ? "quiet" : run.status;
		if (run.summary) r.summary = run.summary;
		if (run.costUsd !== undefined) r.costUsd = run.costUsd;
		this.saveRuns();
		this.host.changed();
	}

	/** An agent's run waits for your OK (AU8, `wait`), or goes on once you answered: the run says so. */
	agentRunWaiting(agentId: string, agentRun: string, waiting: string | undefined): void {
		const r = this.runs.find((x) => x.agent === agentId && x.agentRun === agentRun);
		if (!r || (r.status !== "running" && r.status !== "waiting")) return;
		const status = waiting ? "waiting" : "running";
		if (r.status === status) return;
		r.status = status;
		if (waiting) r.summary = `Waiting for your OK: ${waiting}`;
		else delete r.summary;
		this.saveRuns();
		this.host.changed();
	}

	/** A run that needed your approval and is set to skip (AU8): it ends as skipped. */
	skipped(match: { agent: string; agentRun: string } | { conversation: string }, why: string): AutomationRun | undefined {
		const r = this.runs.find((x) => ("conversation" in match && !x.agent ? x.conversation === match.conversation : "agent" in match && x.agent === match.agent && x.agentRun === match.agentRun));
		if (!r) return undefined;
		r.status = "skipped";
		r.summary = why;
		this.saveRuns();
		this.host.changed();
		return r;
	}

	/** An automation's latest run (the list's last-run column). */
	lastRun(id: string): AutomationRun | undefined {
		for (let i = this.runs.length - 1; i >= 0; i--) if (this.runs[i]!.automation === id) return this.runs[i];
		return undefined;
	}

	/** The automation a run belongs to (approvals, budgets). */
	runOf(match: { agent: string; agentRun: string } | { conversation: string }): { run: AutomationRun; automation?: Automation } | undefined {
		const r = this.runs.find((x) => ("conversation" in match && !x.agent ? x.conversation === match.conversation : "agent" in match && x.agent === match.agent && x.agentRun === match.agentRun));
		return r ? { run: r, automation: this.find(r.automation) } : undefined;
	}

	/**
	 * Fires: a run with the prompt (and what happened, for an event). `key` keeps the same event or time from running
	 * twice. A paused automation runs only when you ask (Run now).
	 */
	async fire(id: string, cause: AutomationRun["cause"], happened?: string, key?: string): Promise<AutomationRun | undefined> {
		const a = this.get(id);
		if (!a.enabled && cause !== "now") return undefined;
		const dedupe = key ? `${a.id}:${key}` : undefined;
		if (dedupe && this.store.fired.includes(dedupe)) return [...this.runs].reverse().find((r) => r.automation === a.id);
		if (dedupe) this.store.fired = [...this.store.fired, dedupe].slice(-500);
		const now = this.now();
		a.runCount++;
		a.lastRun = new Date(now).toISOString();
		this.save();
		// What happened goes where the prompt asks for it ({{body}}, as webhook triggers had), or after it.
		const detail = happened?.trim().slice(0, 20_000) ?? "";
		const prompt = a.prompt.includes("{{body}}") ? a.prompt.replaceAll("{{body}}", detail) : `${a.prompt}${detail ? `\n\nWhat happened:\n${quote(detail)}` : ""}`;
		const run: AutomationRun = { id: `ar${now.toString(36)}${Math.random().toString(36).slice(2, 5)}`, automation: a.id, firedAt: new Date(now).toISOString(), cause, status: "running" };
		try {
			if (a.runsAs === PIOPIO) {
				const text = `[Automation] “${a.name}” (${whenLabel(a)}). Nobody started this conversation: the automation did.${a.result === "quiet" ? " If nothing needs the user, end with one line saying so." : ""} Its budget is $${(a.budgetPerRunUsd ?? DEFAULT_BUDGET.piopio).toFixed(2)}.\n\n${prompt}`;
				run.conversation = await this.host.runPiopio(a, text);
				run.summary = "Opened a conversation";
				this.watchBudgets();
			} else {
				if (!this.host.agent(a.runsAs)) throw new EngineError("NOT_FOUND", "Its agent is gone.");
				const started = await this.host.runAgent(a.runsAs, a, prompt, `auto:${a.id}:${key ?? `${cause}@${now}`}`);
				run.agent = a.runsAs;
				run.agentRun = started.runId;
				run.conversation = `run:${started.runId}`;
				run.status = started.status === "done" ? "done" : started.status;
				if (started.summary) run.summary = started.summary;
			}
		} catch (error) {
			run.status = "failed";
			run.summary = (error as Error).message;
			this.host.log(`Automation ${a.id}: ${(error as Error).message}`);
		}
		if (!this.runs.some((r) => r.agent && r.agent === run.agent && r.agentRun === run.agentRun)) this.runs.push(run);
		this.runs = this.runs.slice(-this.maxRuns());
		// The agent's run may have settled before it was recorded here.
		const early = run.agent ? this.early.get(`${run.agent}/${run.agentRun}`) : undefined;
		if (early) {
			this.early.delete(`${run.agent}/${run.agentRun}`);
			this.agentRunChanged(run.agent!, early);
		}
		this.saveRuns();
		this.host.changed();
		return run;
	}

	private maxRuns(): number {
		return Math.max(MAX_RUNS, this.store.automations.length * MAX_RUNS);
	}

	/** A webhook: its own address (`a/<id>`), or one an automation had before (an agent's trigger, a project's routine). */
	async fireHook(first: string, second: string, body: string, delivery?: string): Promise<{ runId: string }> {
		const a = first === "a" ? this.find(second) : this.store.automations.find((x) => x.aliases?.includes(`${first}/${second}`));
		if (!a || a.on !== "webhook") throw new EngineError("NOT_FOUND", "No automation at this address.");
		// {{body}} in the prompt takes the body as it came (as webhook triggers did); otherwise it's said what happened.
		const happened = a.prompt.includes("{{body}}") ? body : `Its URL was called. Body:\n${body}`;
		const run = await this.fire(a.id, "event", happened, delivery ?? `${this.now()}`);
		if (!run) throw new EngineError("INVALID", "That automation is paused.");
		return { runId: run.id };
	}

	/** Folder and email automations, in the shape the watchers take. */
	watches(): { agentId: string; watches: { id: string; on: "folder" | "email"; prompt: string; folder?: string; from?: string; subject?: string; createdAt: string; by: string }[] }[] {
		const watches = this.store.automations
			.filter((a) => a.enabled && (a.on === "folder" || a.on === "email"))
			.map((a) => ({ id: a.id, on: a.on as "folder" | "email", prompt: a.prompt, ...(a.folder ? { folder: a.folder } : {}), ...(a.from ? { from: a.from } : {}), ...(a.subject ? { subject: a.subject } : {}), createdAt: a.createdAt, by: a.by }));
		return watches.length ? [{ agentId: "automations", watches }] : [];
	}

	// ── The clock ──

	/** Starts the clock: what's due fires (once, for what was missed while the engine was off). */
	start(): void {
		this.stopped = false;
		let changed = false;
		for (const a of this.store.automations) {
			if (a.on === "time" && a.next === undefined && a.cron) {
				a.next = nextOf(a, this.now());
				changed = true;
			}
		}
		if (changed) this.save();
		this.arm();
		this.watchBudgets();
	}

	stop(): void {
		this.stopped = true;
		clearTimeout(this.timer);
		clearInterval(this.budgetTimer);
	}

	/** Sleeps until the next time automation (at most an hour, so a changed clock is picked up). */
	private arm(): void {
		clearTimeout(this.timer);
		if (this.stopped) return;
		const next = Math.min(...this.store.automations.filter((a) => a.enabled).map((a) => a.next ?? Infinity));
		if (!Number.isFinite(next)) return;
		this.timer = setTimeout(() => void this.tick().catch((error: unknown) => this.host.log(`Automations: ${(error as Error).message}`)), Math.min(Math.max(next - this.now(), 0), 3_600_000));
		this.timer.unref?.();
	}

	/** Fires what's due, then sets each one's next. A once that has fired is done and goes. */
	private async tick(): Promise<void> {
		const now = this.now();
		const due = this.store.automations.filter((a) => a.enabled && a.next !== undefined && a.next <= now);
		// Right after the engine starts, the app may not have handed over the keys yet: wait for it (at most a minute).
		if (due.length) await this.host.ready?.();
		for (const a of due) {
			const at = a.next!;
			a.next = nextOf(a, now);
			await this.fire(a.id, "time", undefined, `time:${Math.floor(at / 60_000)}`).catch((error: unknown) => this.host.log(`Automation ${a.id}: ${(error as Error).message}`));
		}
		if (due.length) {
			const done = this.store.automations.filter((a) => a.on === "time" && a.at !== undefined && a.next === undefined);
			if (done.length) this.store.automations = this.store.automations.filter((a) => !done.includes(a));
			this.save();
			this.host.changed();
		}
		this.arm();
	}

	/** While a Piopio run works, its cost is checked: over its budget, it stops and says so (AU8). */
	private watchBudgets(): void {
		if (this.budgetTimer || this.stopped || !this.host.session) return;
		this.budgetTimer = setInterval(() => void this.checkBudgets().catch(() => undefined), 15_000);
		this.budgetTimer.unref?.();
	}

	private async checkBudgets(): Promise<void> {
		const live = this.runs.filter((r) => !r.agent && r.conversation && (r.status === "running" || r.status === "waiting"));
		if (!live.length) {
			clearInterval(this.budgetTimer);
			this.budgetTimer = undefined;
			return;
		}
		for (const r of live) {
			await this.refresh(r);
			const budget = this.find(r.automation)?.budgetPerRunUsd;
			if (budget === undefined || (r.costUsd ?? 0) < budget || (r.status !== "running" && r.status !== "waiting")) continue;
			await this.host.stopSession?.(r.conversation!).catch(() => undefined);
			r.status = "failed";
			r.summary = `Stopped at its budget of $${budget.toFixed(2)}`;
			this.saveRuns();
			this.host.changed();
		}
	}

	// ── Keeping ──

	private saved(watches: boolean): void {
		this.save();
		this.arm();
		this.host.changed();
		if (watches) this.host.watchesChanged();
	}

	private save(): void {
		mkdirSync(dirname(this.host.file), { recursive: true });
		writeFileAtomic(this.host.file, JSON.stringify(this.store, null, "\t"));
	}

	private saveRuns(): void {
		mkdirSync(dirname(this.host.runsFile), { recursive: true });
		writeFileAtomic(this.host.runsFile, JSON.stringify(this.runs, null, "\t"));
	}

	/** The migration's records (27 §6), written before anything runs. Ids already here are kept as they are. */
	adopt(automations: Automation[], runs: AutomationRun[]): void {
		for (const a of automations) if (!this.store.automations.some((x) => x.id === a.id)) this.store.automations.push(a);
		for (const r of runs) if (!this.runs.some((x) => x.id === r.id)) this.runs.push(r);
		this.runs.sort((x, y) => x.firedAt.localeCompare(y.firedAt));
		this.saveRuns();
		this.saved(automations.some((a) => a.on === "folder" || a.on === "email"));
	}
}

function readJson<T>(file: string): T | undefined {
	if (!existsSync(file)) return undefined;
	try {
		return JSON.parse(readFileSync(file, "utf8")) as T;
	} catch {
		return undefined;
	}
}
