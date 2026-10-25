/**
 * Approvals and safety (docs/spec/06-agents §9 AS1–AS4), result cards with Undo (§4.2 RC1–RC5) and the Inbox (§12).
 *
 * - A tool call matched by `policies.requireApproval` waits in the tool task's `beforeTool` hook until the owner
 *   approves (as is, or edited), denies, or 24 hours pass. The wait is durable in effect: the decision lives in the
 *   agent's state doc, and after a restart the tool task runs its hook again and finds it.
 * - Contacts can't make the agent message third people (AS2).
 * - The month's spend comes from pi-durable's usage ledger. At 80% of the budget the owner is told; at 100% runs
 *   stop, tool calls are blocked and messages get a canned answer (AS3). Pausing stops everything at once (AS4).
 * - Tools that change something return a card and record how to reverse it; Undo works for 24 hours.
 * - The Inbox: approvals, messages the agent sent the owner on its own, failed runs, budget and pause notes.
 */
import { awaitWithContext, type Context } from "@earendil-works/chord/context";
import type { ConversationId, Harness, JsonObject } from "@earendil-works/pi-durable";
import type { AgentDefinition, Contact } from "./definition.js";

export type ApprovalStatus = "pending" | "approved" | "denied" | "expired" | "cancelled";
export type Approval = {
	id: string;
	conversationId: string;
	callId: string;
	tool: string;
	args: JsonObject;
	/** "Send to María: “…”". */
	title: string;
	/** Where it was asked: `person:<id>` or a run id. */
	from: string;
	/** What "Always allow" would allow (`send_message:to:maria`). */
	key: string;
	rule: string;
	requestedAt: string;
	expiresAt: number;
	status: ApprovalStatus;
	decidedAt?: string;
	/** Approved with these arguments instead. */
	editedArgs?: JsonObject;
	reason?: string;
};

/** What a tool changed (RC1). */
export type ResultCard = { kind: "reminder" | "message" | "memory" | "event" | "contact" | "note" | "music" | "shortcut"; title: string; detail?: string };
/** `app.tool`: an Apple app call that reverses another (§4.1). */
export type UndoKind = "reminder.cancel" | "reminder.restore" | "memory.forget" | "memory.restore" | "memory.unlearn" | "outbox.withdraw" | "app.tool";
export type UndoRecord = { id: string; kind: UndoKind; data: JsonObject; title: string; conversationId: string; at: string; until: number; status: "available" | "undone" | "failed"; error?: string };

export type InboxKind = "approval" | "message" | "run_failed" | "budget" | "paused";
export type InboxEntry = {
	id: string;
	kind: InboxKind;
	at: string;
	title: string;
	body: string;
	/** Waits for the owner (approvals while pending; the others until read). */
	needsYou: boolean;
	read?: boolean;
	approvalId?: string;
	/** The conversation it's about: `person:<id>` or `run:<id>`. */
	conversation?: string;
};

export type SafetyState = {
	approvals?: Approval[];
	/** Keys the owner always allows. */
	allowed?: string[];
	/** The session's total spend when the month started (pi-durable's usage is a running total). */
	spendBase?: { month: string; total: number };
	/** month → spend, as last measured. */
	spend?: Record<string, number>;
	/** The month the owner was told about 80% and 100%. */
	budgetWarned?: string;
	budgetStopped?: string;
	paused?: boolean;
	undos?: UndoRecord[];
	inbox?: InboxEntry[];
};

export type AgentStatus = { paused: boolean; spendUsd: number; budgetUsd?: number; inbox: number };

const DAY = 24 * 3600_000;
const MAX_KEPT = 300;
/** setTimeout's limit. */
const MAX_TIMER = 2 ** 31 - 1;

export interface SafetyHost {
	readonly harness: Harness;
	readonly context: Context;
	definition(): AgentDefinition;
	now(): number;
	read(): Promise<SafetyState>;
	write(change: (state: SafetyState) => void): Promise<void>;
	/** Who a conversation belongs to: a person, or a run (which acts for the owner). */
	whose(conversationId: ConversationId | string): Promise<{ contact?: Contact; runId?: string; peerId?: string }>;
	/** Writes a note into a person's conversation (the model reads it too, when `forModel` is given). */
	note(contactId: string, text: string, forModel?: string): Promise<void>;
	/** Stops every running turn and run. */
	abortAll(): Promise<void>;
	/** Puts held messages back on their way (after a pause). */
	release(): Promise<void>;
	/** Reverses a change; throws when it can't. */
	reverse(undo: UndoRecord): Promise<void>;
	onApproval?(approval: Approval): void;
	onUndo?(undo: UndoRecord): void;
	onStatus?(): void;
}

export class Safety {
	private readonly waiters = new Map<string, Set<(a: Approval) => void>>();
	private closing = false;

	constructor(private readonly host: SafetyHost) {}

	private get def(): AgentDefinition {
		return this.host.definition();
	}

	private get owner(): Contact | undefined {
		return this.def.contacts.find((c) => c.role === "owner");
	}

	private iso(t = this.host.now()): string {
		return new Date(t).toISOString();
	}

	/** The engine is stopping: waits end without cancelling their approvals (they come back after the restart). */
	close(): void {
		this.closing = true;
	}

	// ── Gate: pause and budget ──

	/** Whether the agent may work now: not paused, not over its budget. */
	async gate(): Promise<{ ok: true } | { ok: false; reason: "paused" | "budget"; message: string }> {
		const state = await this.host.read();
		if (state.paused) return { ok: false, reason: "paused", message: `${this.def.name} is paused.` };
		const budget = this.def.policies?.budgetUsdPerMonth;
		if (budget !== undefined && (await this.spend()) >= budget) {
			return { ok: false, reason: "budget", message: `${this.def.name} is out of budget this month ($${budget.toFixed(2)}).` };
		}
		return { ok: true };
	}

	/** This month's spend across every conversation and run (USD). */
	async spend(): Promise<number> {
		const usage = await this.host.harness.usage(this.host.context);
		let total = 0;
		for (const u of [...Object.values(usage.models), ...Object.values(usage.tools)]) total += (u as { cost?: { total?: number } }).cost?.total ?? 0;
		const month = this.iso().slice(0, 7);
		const state = await this.host.read();
		if (state.spendBase?.month === month) {
			const spent = Math.max(0, total - state.spendBase.total);
			if (Math.abs((state.spend?.[month] ?? -1) - spent) > 1e-9) await this.host.write((s) => void (s.spend = { ...(s.spend ?? {}), [month]: spent }));
			return spent;
		}
		// A new month (or the first measure): what was spent before belongs to earlier months.
		const base = state.spendBase ? total : 0;
		await this.host.write((s) => {
			s.spendBase = { month, total: base };
			s.spend = { ...(s.spend ?? {}), [month]: total - base };
		});
		return total - base;
	}

	/** After activity: tells the owner at 80% and at 100% of the budget, once a month each. */
	async checkBudget(): Promise<void> {
		const budget = this.def.policies?.budgetUsdPerMonth;
		if (budget === undefined) return;
		const spent = await this.spend();
		const month = this.iso().slice(0, 7);
		const state = await this.host.read();
		const money = (n: number) => `$${n.toFixed(2)}`;
		if (spent >= budget && state.budgetStopped !== month) {
			await this.host.write((s) => void (s.budgetStopped = month));
			const text = `${this.def.name} used its budget for this month (${money(spent)} of ${money(budget)}). Runs stopped and messages get a short “out of budget” answer until you raise the cap.`;
			await this.inbox({ kind: "budget", title: "Budget used up", body: text, needsYou: true });
			if (this.owner) await this.host.note(this.owner.id, text).catch(() => undefined);
		} else if (spent >= budget * 0.8 && spent < budget && state.budgetWarned !== month) {
			await this.host.write((s) => void (s.budgetWarned = month));
			const text = `${this.def.name} has used ${Math.round((spent / budget) * 100)}% of this month's budget (${money(spent)} of ${money(budget)}).`;
			await this.inbox({ kind: "budget", title: "80% of the budget", body: text, needsYou: false });
		}
		this.host.onStatus?.();
	}

	/** The kill switch (AS4): stops runs and turns now; messages wait until it's resumed. */
	async setPaused(paused: boolean): Promise<void> {
		const was = (await this.host.read()).paused ?? false;
		if (was === paused) return;
		await this.host.write((s) => void (s.paused = paused || undefined));
		if (paused) {
			await this.host.abortAll().catch(() => undefined);
			await this.inbox({ kind: "paused", title: "Paused", body: `${this.def.name} is paused: no runs, no messages until you resume it.`, needsYou: false, read: true });
		} else {
			await this.host.release().catch(() => undefined);
		}
		this.host.onStatus?.();
	}

	async status(): Promise<AgentStatus> {
		const state = await this.host.read();
		const budget = this.def.policies?.budgetUsdPerMonth;
		return { paused: state.paused ?? false, spendUsd: await this.spend(), ...(budget !== undefined ? { budgetUsd: budget } : {}), inbox: this.count(state) };
	}

	// ── Approvals ──

	/** The `beforeTool` hook: blocks what's paused, over budget or not allowed; waits for approval where required. */
	async beforeTool(call: { id: string; name: string; arguments: unknown }, conversationId: ConversationId, context: Context): Promise<{ arguments?: JsonObject; block?: string } | undefined> {
		const gate = await this.gate();
		if (!gate.ok) return { block: `${gate.message} Nothing was done.` };
		const args = (call.arguments ?? {}) as JsonObject;
		const who = await this.host.whose(conversationId);
		const owner = this.owner;
		// AS2: a contact can't reach other agents through this one.
		if ((call.name === "ask_agent" || call.name === "tell_agent") && who.contact && who.contact.role !== "owner" && !who.peerId) {
			return { block: `Messages from ${who.contact.name} can't make you contact other agents.` };
		}
		// AS2: a contact can't make the agent message anyone but themselves and the owner.
		if (call.name === "send_message" && who.contact && who.contact.role !== "owner" && args.to !== who.contact.id && args.to !== owner?.id) {
			return { block: `Messages from ${who.contact.name} can't make you write to other people.` };
		}
		const rule = (this.def.policies?.requireApproval ?? []).find((r) => matches(r, call.name, args, owner?.id ?? "owner"));
		if (!rule) return undefined;
		const key = allowKey(call.name, args);
		let state = await this.host.read();
		if (state.allowed?.includes(key)) return undefined;
		let approval = state.approvals?.find((a) => a.conversationId === String(conversationId) && a.callId === call.id);
		if (!approval) {
			const now = this.host.now();
			const created: Approval = {
				id: `apr_${now.toString(36)}${Math.random().toString(36).slice(2, 6)}`,
				conversationId: String(conversationId),
				callId: call.id,
				tool: call.name,
				args,
				title: describe(call.name, args, this.def),
				from: who.runId ?? (who.peerId ? `agent:${who.peerId}` : `person:${who.contact?.id ?? "owner"}`),
				key,
				rule,
				requestedAt: this.iso(now),
				expiresAt: now + DAY,
				status: "pending",
			};
			await this.host.write((s) => void (s.approvals = [...(s.approvals ?? []), created].slice(-MAX_KEPT)));
			await this.inbox({ kind: "approval", title: `Approval · ${created.tool}`, body: created.title, needsYou: true, approvalId: created.id, conversation: who.runId ? `run:${who.runId}` : who.peerId ? `agent:${who.peerId}` : `person:${who.contact?.id ?? "owner"}` });
			this.host.onApproval?.(created);
			approval = created;
		}
		if (approval.status === "pending") approval = await this.wait(approval, context);
		state = await this.host.read();
		switch (approval.status) {
			case "approved":
				return approval.editedArgs ? { arguments: approval.editedArgs } : undefined;
			case "denied":
				return { block: `The owner declined this${approval.reason ? `: ${approval.reason}` : ""}. Don't try it again unless asked.` };
			case "expired":
				return { block: "No answer within 24 hours, so it wasn't done." };
			default:
				return { block: "The request was cancelled." };
		}
	}

	private async wait(approval: Approval, context: Context): Promise<Approval> {
		if (approval.expiresAt <= this.host.now()) return this.settle(approval.id, "expired");
		const decided = new Promise<Approval>((resolve) => {
			const set = this.waiters.get(approval.id) ?? new Set();
			set.add(resolve);
			this.waiters.set(approval.id, set);
		});
		const timer = setTimeout(() => void this.settle(approval.id, "expired"), Math.min(MAX_TIMER, approval.expiresAt - this.host.now()));
		try {
			return await awaitWithContext(decided, context);
		} catch (error) {
			// Stopped (the turn was aborted): the request goes too. Not when the engine is only stopping.
			if (!this.closing) await this.settle(approval.id, "cancelled").catch(() => undefined);
			throw error;
		} finally {
			clearTimeout(timer);
		}
	}

	/** The owner's answer. `args` approves with changes; `always` stops asking for this kind of call. */
	async decide(approvalId: string, decision: { approve: boolean; args?: JsonObject; always?: boolean; reason?: string }): Promise<Approval> {
		const current = (await this.host.read()).approvals?.find((a) => a.id === approvalId);
		if (!current) throw new Error(`No approval ${approvalId}.`);
		if (current.status !== "pending") throw new Error(`That request was already ${current.status}.`);
		if (decision.approve && decision.always) await this.host.write((s) => void (s.allowed = [...new Set([...(s.allowed ?? []), current.key])]));
		return this.settle(approvalId, decision.approve ? "approved" : "denied", decision.args, decision.reason);
	}

	private async settle(id: string, status: ApprovalStatus, args?: JsonObject, reason?: string): Promise<Approval> {
		let settled: Approval | undefined;
		await this.host.write((s) => {
			const a = s.approvals?.find((x) => x.id === id);
			if (!a) return;
			if (a.status === "pending") {
				a.status = status;
				a.decidedAt = this.iso();
				if (args) a.editedArgs = args;
				if (reason) a.reason = reason;
			}
			settled = JSON.parse(JSON.stringify(a)) as Approval;
		});
		if (!settled) throw new Error(`No approval ${id}.`);
		for (const resolve of this.waiters.get(id) ?? []) resolve(settled);
		this.waiters.delete(id);
		this.host.onApproval?.(settled);
		this.host.onStatus?.();
		return settled;
	}

	async approvals(conversationId?: string): Promise<Approval[]> {
		const all = (await this.host.read()).approvals ?? [];
		return conversationId ? all.filter((a) => a.conversationId === conversationId) : all;
	}

	// ── Undo ──

	/** Records how to reverse a change (RC2); returns the undo id the card carries. */
	async recordUndo(kind: UndoKind, data: JsonObject, title: string, conversationId: ConversationId | string): Promise<string> {
		const now = this.host.now();
		const id = `und_${now.toString(36)}${Math.random().toString(36).slice(2, 6)}`;
		await this.host.write((s) => void (s.undos = [...(s.undos ?? []), { id, kind, data, title, conversationId: String(conversationId), at: this.iso(now), until: now + DAY, status: "available" as const }].slice(-MAX_KEPT)));
		return id;
	}

	async undos(): Promise<UndoRecord[]> {
		return (await this.host.read()).undos ?? [];
	}

	/** Reverses a change while its window lasts; the conversation gets a note, so the agent knows. */
	async undo(id: string): Promise<UndoRecord> {
		const record = (await this.host.read()).undos?.find((u) => u.id === id);
		if (!record) throw new Error(`No change ${id} to undo.`);
		if (record.status !== "available") throw new Error(record.status === "undone" ? "Already undone." : "That change can't be undone.");
		if (record.until < this.host.now()) throw new Error("Too late to undo (changes can be undone for 24 hours).");
		let error: string | undefined;
		try {
			await this.host.reverse(record);
		} catch (e) {
			error = (e as Error).message;
		}
		let out!: UndoRecord;
		await this.host.write((s) => {
			const u = s.undos!.find((x) => x.id === id)!;
			u.status = error ? "failed" : "undone";
			if (error) u.error = error;
			out = JSON.parse(JSON.stringify(u)) as UndoRecord;
		});
		this.host.onUndo?.(out);
		if (error) throw new Error(error);
		const who = await this.host.whose(record.conversationId);
		const contact = who.contact ?? this.owner;
		if (contact) await this.host.note(contact.id, `Undone: ${record.title}`, `(The owner undid this: ${record.title}.)`).catch(() => undefined);
		return out;
	}

	// ── Inbox ──

	async inbox(entry: Omit<InboxEntry, "id" | "at">): Promise<void> {
		const now = this.host.now();
		await this.host.write((s) => void (s.inbox = [...(s.inbox ?? []), { id: `ibx_${now.toString(36)}${Math.random().toString(36).slice(2, 6)}`, at: this.iso(now), ...entry }].slice(-MAX_KEPT)));
		this.host.onStatus?.();
	}

	async markRead(ids: readonly string[]): Promise<void> {
		await this.host.write((s) => {
			for (const e of s.inbox ?? []) if (ids.includes(e.id)) e.read = true;
		});
		this.host.onStatus?.();
	}

	/** Entries newest first, approvals with their current state. */
	async entries(): Promise<(InboxEntry & { approval?: Approval })[]> {
		const state = await this.host.read();
		return [...(state.inbox ?? [])].reverse().map((e) => {
			const approval = e.approvalId ? state.approvals?.find((a) => a.id === e.approvalId) : undefined;
			return approval ? { ...e, needsYou: approval.status === "pending", approval } : e;
		});
	}

	/** What needs the owner: pending approvals, and unread entries that ask for them. */
	count(state: SafetyState): number {
		return (state.inbox ?? []).filter((e) => {
			if (e.approvalId) return state.approvals?.find((a) => a.id === e.approvalId)?.status === "pending";
			return e.needsYou && !e.read;
		}).length;
	}
}

/**
 * A `requireApproval` rule: `tool` or `tool:qualifier`, where the tool may use `*`. Qualifiers: `to_owner`,
 * `to_non_owner`, `to:<contactId>`, an HTTP method (`http_request:POST`), or `*`. `mcp:<server>:<tool>` matches an
 * MCP tool named `<server>_<tool>` (the Chat convention). An unknown qualifier asks, to be safe.
 */
export function matches(rule: string, tool: string, args: Record<string, unknown>, ownerId: string): boolean {
	const glob = (pattern: string, value: string) => new RegExp(`^${pattern.split("*").map((p) => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*")}$`).test(value);
	if (rule.startsWith("mcp:")) {
		const [, server = "*", name = "*"] = rule.split(":");
		return glob(`${server}_${name}`, tool);
	}
	const colon = rule.indexOf(":");
	const pattern = colon < 0 ? rule : rule.slice(0, colon);
	const qualifier = colon < 0 ? "*" : rule.slice(colon + 1);
	if (!glob(pattern, tool)) return false;
	if (qualifier === "*") return true;
	if (qualifier === "to_owner") return args.to === ownerId;
	if (qualifier === "to_non_owner") return typeof args.to === "string" && args.to !== ownerId;
	if (qualifier.startsWith("to:")) return args.to === qualifier.slice(3);
	if (/^[A-Z]+$/.test(qualifier)) return String(args.method ?? "GET").toUpperCase() === qualifier;
	return true;
}

/** What "Always allow" remembers: the tool, and for messages who they go to. */
export function allowKey(tool: string, args: Record<string, unknown>): string {
	if (tool === "send_message" && typeof args.to === "string") return `send_message:to:${args.to}`;
	if (typeof args.method === "string") return `${tool}:${args.method.toUpperCase()}`;
	return tool;
}

/** "Always allow …" in words, for an allow key. */
export function alwaysLabel(key: string, def: AgentDefinition): string {
	const [tool, qualifier, value] = key.split(":");
	if (tool === "send_message" && qualifier === "to") return `Always allow messages to ${def.contacts.find((c) => c.id === value)?.name ?? value}`;
	if (qualifier && /^[A-Z]+$/.test(qualifier)) return `Always allow ${qualifier} requests (${tool})`;
	return `Always allow ${tool}`;
}

/** One line for an approval request. */
export function describe(tool: string, args: Record<string, unknown>, def: AgentDefinition): string {
	const name = (id: unknown) => def.contacts.find((c) => c.id === id)?.name ?? String(id);
	const clip = (s: unknown, n = 160) => {
		const t = String(s ?? "").replace(/\s+/g, " ").trim();
		return t.length > n ? `${t.slice(0, n - 1)}…` : t;
	};
	if (tool === "send_message") return `Send to ${name(args.to)}: “${clip(args.text)}”`;
	if (tool === "schedule") return `Schedule “${clip(args.prompt, 100)}” for ${clip(args.when, 40)}`;
	if (tool === "cancel_schedule") return `Cancel the reminder ${clip(args.id, 40)}`;
	if (tool === "remember") return `Remember: “${clip(args.fact)}”`;
	if (tool === "forget") return `Forget the fact ${clip(args.id, 40)}`;
	if (tool === "http_request") return `${String(args.method ?? "GET").toUpperCase()} ${clip(args.url, 120)}`;
	return `${tool}(${clip(JSON.stringify(args), 140)})`;
}
