/**
 * Agent-to-agent (docs/spec/06-agents §7 AA1–AA7). Agents in the same engine reach each other in-process: A's
 * message lands in B's conversation with A (`agent:<A>`), where B answers it like any input.
 *
 * - `ask_agent` waits for B's answer (10 minutes by default); a later answer comes back to A's conversation as a
 *   follow-up. `tell_agent` doesn't wait.
 * - A may write to B only if B is in A's `tools.agents` and B accepts A (`acceptFrom`, default: every agent).
 * - Every message carries `{traceId, hop}`: hop 5 is refused, a pair may exchange 30 messages an hour, and a trace
 *   may spend $0.50 across all its agents (AA4). Each side keeps a log of what it sent and answered, from which the
 *   engine draws the trace tree (AA5).
 * - Answers in progress survive a restart: B answers when it comes back, and A gets it as a late reply.
 */
import { awaitWithContext, type Context } from "@earendil-works/chord/context";
import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ConversationId, type Harness } from "@earendil-works/pi-durable";
import type { AgentDefinition } from "./definition.js";

export const AGENT_ENTRY = "piopio.agent-msg";

export type AgentRef = { id: string; name: string };
export type Envelope = {
	id: string;
	mode: "ask" | "tell" | "reply";
	from: AgentRef;
	to: AgentRef;
	text: string;
	traceId: string;
	hop: number;
	/** The message that caused this one (the trace tree's parent). */
	parent?: string;
	/** An ask's id; a reply carries the ask's. */
	requestId?: string;
	at: string;
};

/** One message, as either side logged it (the trace view). */
export type PeerLog = {
	id: string;
	traceId: string;
	hop: number;
	parent?: string;
	mode: Envelope["mode"];
	from: AgentRef;
	to: AgentRef;
	text: string;
	at: string;
	status: "sent" | "waiting" | "replied" | "no_reply" | "failed";
	reply?: string;
	/** What answering it cost the receiver. */
	costUsd?: number;
	error?: string;
	/** Which side wrote this entry. */
	side: "out" | "in";
};

type Ask = { requestId: string; envelopeId: string; to: AgentRef; conversationId: string; question: string; status: "waiting" | "late" | "done" };
type Serving = { envelopeId: string; from: AgentRef; conversationId: string; mode: "ask" | "tell"; requestId?: string; traceId: string; hop: number; done?: boolean };

export type PeerState = {
	/** peer agent id → the conversation with it. */
	agents?: Record<string, string>;
	/** Side conversations (conversation id → peer id): a message nested in a trace that conversation is still answering. */
	peerSide?: Record<string, string>;
	peerLog?: PeerLog[];
	/** conversation id → the message being answered there (trace context for what it sends next). */
	inbound?: Record<string, { traceId: string; hop: number; envelopeId: string }>;
	asks?: Ask[];
	serving?: Serving[];
	/** peer id → when messages went to it (rate limit). */
	peerSent?: Record<string, number[]>;
};

export type Directory = { id: string; slug: string; name: string; acceptFrom?: string[] }[];

export interface PeerHost {
	readonly harness: Harness;
	readonly context: Context;
	definition(): AgentDefinition;
	now(): number;
	read(): Promise<PeerState>;
	write(change: (state: PeerState) => void): Promise<void>;
	/** The other agents in this engine. */
	directory(): Promise<Directory>;
	/** Hands a message to another agent; throws with the reason when it's refused. */
	deliver(to: string, envelope: Envelope): Promise<void>;
	/** What a trace has cost so far, across agents. */
	traceCost(traceId: string): Promise<number>;
	/** The conversation with another agent, made on first contact; `side` makes a fresh one for nested messages. */
	conversation(peerId: string, side?: boolean): Promise<{ id: ConversationId; submit: (input: never, context: Context) => Promise<{ wait(c: Context): Promise<{ status: string }> }> }>;
	/** Whether the agent may work now (pause, budget). */
	gate(): Promise<{ ok: true } | { ok: false; message: string }>;
	askTimeoutMs: number;
	/** Memory for answering: what's relevant to the message, into the conversation's notes. */
	recall?(conversationId: ConversationId, text: string): Promise<void>;
	onLog?(): void;
}

const MAX_HOPS = 4;
const MAX_LOG = 500;
const HOUR = 3600_000;

export class Peers {
	private readonly waiters = new Map<string, (reply: string) => void>();
	/** Answers that arrived before their ask started waiting. */
	private readonly early = new Map<string, string>();
	readonly tools;

	constructor(private readonly host: PeerHost) {
		this.tools = this.makeTools();
	}

	private get def(): AgentDefinition {
		return this.host.definition();
	}

	private get me(): AgentRef {
		return { id: this.def.id, name: this.def.name };
	}

	private id(prefix: string): string {
		return `${prefix}_${this.host.now().toString(36)}${Math.random().toString(36).slice(2, 7)}`;
	}

	private async log(entry: PeerLog): Promise<void> {
		await this.host.write((s) => void (s.peerLog = [...(s.peerLog ?? []).filter((e) => !(e.id === entry.id && e.side === entry.side)), entry].slice(-MAX_LOG)));
		this.host.onLog?.();
	}

	private async patchLog(id: string, side: PeerLog["side"], change: Partial<PeerLog>): Promise<void> {
		await this.host.write((s) => {
			const e = s.peerLog?.find((x) => x.id === id && x.side === side);
			if (e) Object.assign(e, change);
		});
		this.host.onLog?.();
	}

	/** The peer agent a conversation is with, if it's one. */
	async peerOf(conversationId: ConversationId | string): Promise<string | undefined> {
		const state = await this.host.read();
		return Object.entries(state.agents ?? {}).find(([, c]) => c === String(conversationId))?.[0] ?? state.peerSide?.[String(conversationId)];
	}

	// ── Sending (A's side) ──

	/** Who `ref` is (id, slug or name), and whether this agent may write to them (AA1). */
	private async resolve(ref: string): Promise<{ id: string; slug: string; name: string; acceptFrom?: string[] }> {
		const dir = await this.host.directory();
		const target = dir.find((a) => a.id === ref || a.slug === ref || a.name.toLowerCase() === ref.toLowerCase());
		const allowed = this.def.tools.agents ?? [];
		const reachable = dir.filter((a) => allowed.includes(a.id) || allowed.includes(a.slug)).map((a) => a.name);
		if (!target || !(allowed.includes(target.id) || allowed.includes(target.slug))) {
			throw new Error(reachable.length ? `You can write to: ${reachable.join(", ")}.` : "You can't write to other agents (none are listed in your definition).");
		}
		if (target.acceptFrom && !target.acceptFrom.includes(this.def.id) && !target.acceptFrom.includes(this.def.slug)) throw new Error(`${target.name} doesn't accept messages from you.`);
		return target;
	}

	/** Builds, checks (hops, rate, trace budget) and delivers a message. */
	private async send(mode: "ask" | "tell", ref: string, text: string, conversationId: string): Promise<{ envelope: Envelope; to: AgentRef }> {
		const target = await this.resolve(ref);
		const state = await this.host.read();
		const context = state.inbound?.[conversationId];
		const traceId = context?.traceId ?? this.id("trc");
		const hop = (context?.hop ?? 0) + 1;
		if (hop > MAX_HOPS) throw new Error(`Too many hops between agents (${hop} > ${MAX_HOPS}): answer with what you have.`);
		const now = this.host.now();
		const recent = (state.peerSent?.[target.id] ?? []).filter((t) => t > now - HOUR);
		const perHour = this.def.policies?.agentMessagesPerHour ?? 30;
		if (recent.length >= perHour) throw new Error(`You've written to ${target.name} ${recent.length} times in the last hour (limit ${perHour}).`);
		const budget = this.def.policies?.traceBudgetUsd ?? 0.5;
		const spent = await this.host.traceCost(traceId);
		if (spent >= budget) throw new Error(`This exchange between agents has cost $${spent.toFixed(2)}, its limit is $${budget.toFixed(2)}.`);
		const to = { id: target.id, name: target.name };
		const envelope: Envelope = {
			id: this.id("amsg"),
			mode,
			from: this.me,
			to,
			text,
			traceId,
			hop,
			...(context ? { parent: context.envelopeId } : {}),
			...(mode === "ask" ? { requestId: this.id("ask") } : {}),
			at: new Date(now).toISOString(),
		};
		await this.host.write((s) => void (s.peerSent = { ...(s.peerSent ?? {}), [target.id]: [...recent, now] }));
		await this.log({ id: envelope.id, traceId, hop, ...(envelope.parent ? { parent: envelope.parent } : {}), mode, from: this.me, to, text, at: envelope.at, status: mode === "ask" ? "waiting" : "sent", side: "out" });
		if (mode === "ask") await this.host.write((s) => void (s.asks = [...(s.asks ?? []), { requestId: envelope.requestId!, envelopeId: envelope.id, to, conversationId, question: text, status: "waiting" as const }].slice(-MAX_LOG)));
		try {
			await this.host.deliver(target.id, envelope);
		} catch (error) {
			await this.patchLog(envelope.id, "out", { status: "failed", error: (error as Error).message });
			await this.host.write((s) => void (s.asks = (s.asks ?? []).filter((a) => a.requestId !== envelope.requestId)));
			throw error;
		}
		return { envelope, to };
	}

	/** B's answer arrived: to the waiting tool call, or as a follow-up in A's conversation. */
	async receiveReply(envelope: Envelope): Promise<void> {
		const ask = (await this.host.read()).asks?.find((a) => a.requestId === envelope.requestId);
		if (!ask) return;
		await this.patchLog(ask.envelopeId, "out", { status: "replied", reply: envelope.text });
		if (ask.status === "waiting") {
			await this.host.write((s) => void (s.asks = (s.asks ?? []).filter((a) => a.requestId !== ask.requestId)));
			const waiter = this.waiters.get(ask.requestId);
			if (waiter) waiter(envelope.text);
			else this.early.set(ask.requestId, envelope.text);
			return;
		}
		// Too late for the tool call (timed out, or the engine restarted): it comes back as a new message.
		await this.host.write((s) => void (s.asks = (s.asks ?? []).filter((a) => a.requestId !== ask.requestId)));
		const conversation = await this.host.harness.conversation(Number(ask.conversationId) as never, this.host.context);
		if (!conversation) return;
		await conversation.submit(
			{
				type: "input",
				content: `(${envelope.from.name} answered your earlier question “${ask.question.slice(0, 200)}”:)\n${envelope.text}`,
				entry: { kind: AGENT_ENTRY, data: { ...envelope, late: true } },
				whenBusy: "followUp",
				requestId: `late:${envelope.id}`,
			} as never,
			this.host.context,
		);
	}

	// ── Receiving (B's side) ──

	/** A message from another agent: checked, then answered in the conversation with it. Throws when refused. */
	async receive(envelope: Envelope): Promise<void> {
		if (envelope.mode === "reply") return this.receiveReply(envelope);
		const accept = this.def.acceptFrom;
		const dir = await this.host.directory();
		const sender = dir.find((a) => a.id === envelope.from.id);
		if (accept && !accept.includes(envelope.from.id) && !(sender && accept.includes(sender.slug))) throw new Error(`${this.def.name} doesn't accept messages from ${envelope.from.name}.`);
		if (envelope.hop > MAX_HOPS) throw new Error("Too many hops.");
		const gate = await this.host.gate();
		if (!gate.ok) throw new Error(gate.message);
		// Answering in the usual conversation would wait behind a turn that is itself waiting on this trace (A asks B,
		// B asks A, A asks B again): such a message gets a side conversation.
		const main = (await this.host.read()).agents?.[envelope.from.id];
		const nested = main !== undefined && ((await this.host.read()).serving ?? []).some((s) => !s.done && s.conversationId === main && s.traceId === envelope.traceId);
		const conversation = await this.host.conversation(envelope.from.id, nested);
		const conversationId = String(conversation.id);
		await this.host.write((s) => {
			s.inbound = { ...(s.inbound ?? {}), [conversationId]: { traceId: envelope.traceId, hop: envelope.hop, envelopeId: envelope.id } };
			s.serving = [...(s.serving ?? []), { envelopeId: envelope.id, from: envelope.from, conversationId, mode: envelope.mode as "ask" | "tell", ...(envelope.requestId ? { requestId: envelope.requestId } : {}), traceId: envelope.traceId, hop: envelope.hop }].slice(-MAX_LOG);
		});
		await this.log({ id: envelope.id, traceId: envelope.traceId, hop: envelope.hop, ...(envelope.parent ? { parent: envelope.parent } : {}), mode: envelope.mode, from: envelope.from, to: envelope.to, text: envelope.text, at: envelope.at, status: envelope.mode === "ask" ? "waiting" : "sent", side: "in" });
		await this.host.recall?.(conversation.id, envelope.text).catch(() => undefined);
		const submission = await conversation.submit({ type: "input", content: envelope.text, entry: { kind: AGENT_ENTRY, data: envelope }, whenBusy: "followUp", requestId: `amsg:${envelope.id}` } as never, this.host.context);
		void submission.wait(this.host.context).then(
			() => this.answered(envelope.id),
			() => undefined,
		);
	}

	/** A message was answered: the answer goes back (asks), and the cost is logged. */
	private async answered(envelopeId: string): Promise<void> {
		const serving = (await this.host.read()).serving?.find((s) => s.envelopeId === envelopeId);
		if (!serving || serving.done) return;
		const { answer, costUsd } = await this.answerOf(serving.conversationId, envelopeId);
		await this.host.write((s) => {
			const x = s.serving?.find((y) => y.envelopeId === envelopeId);
			if (x) x.done = true;
			s.serving = (s.serving ?? []).filter((y) => !y.done);
		});
		await this.patchLog(envelopeId, "in", { status: serving.mode === "ask" ? (answer ? "replied" : "no_reply") : "sent", ...(answer ? { reply: answer } : {}), costUsd });
		if (serving.mode !== "ask") return;
		const reply: Envelope = {
			id: this.id("amsg"),
			mode: "reply",
			from: this.me,
			to: serving.from,
			text: answer || "(No answer.)",
			traceId: serving.traceId,
			hop: serving.hop,
			parent: envelopeId,
			requestId: serving.requestId!,
			at: new Date(this.host.now()).toISOString(),
		};
		await this.host.deliver(serving.from.id, reply).catch(() => undefined);
	}

	/** The last answer after a message in a conversation, and what producing it cost. */
	private async answerOf(conversationId: string, envelopeId: string): Promise<{ answer: string; costUsd: number }> {
		const conversation = await this.host.harness.conversation(Number(conversationId) as never, this.host.context);
		if (!conversation) return { answer: "", costUsd: 0 };
		const view = await conversation.viewState(this.host.context);
		const entries = view.value.entries as readonly { kind: string; data?: { id?: string }; model?: { role: string; content?: unknown; usage?: { cost?: { total?: number } } }[] }[];
		view.dispose();
		const start = entries.findIndex((e) => e.kind === AGENT_ENTRY && e.data?.id === envelopeId);
		let answer = "";
		let costUsd = 0;
		for (const e of entries.slice(start + 1)) {
			if (e.kind === AGENT_ENTRY || e.kind === "piopio.user") break;
			const m = e.model?.[0];
			if (m?.role !== "assistant") continue;
			costUsd += m.usage?.cost?.total ?? 0;
			const text = Array.isArray(m.content) ? (m.content as { type: string; text?: string }[]).filter((b) => b.type === "text").map((b) => b.text ?? "").join("") : "";
			if (text.trim()) answer = text.trim();
		}
		return { answer, costUsd };
	}

	/** After a restart: messages left being answered are followed again. */
	async resume(): Promise<void> {
		for (const s of (await this.host.read()).serving ?? []) {
			if (s.done) continue;
			const conversation = await this.host.harness.conversation(Number(s.conversationId) as never, this.host.context);
			if (!conversation) continue;
			void conversation.waitForIdle(this.host.context).then(() => this.answered(s.envelopeId), () => undefined);
		}
		// Asks whose tool call ended with the engine: their answers come back as follow-ups.
		await this.host.write((s) => {
			for (const a of s.asks ?? []) if (a.status === "waiting") a.status = "late";
		});
	}

	async logs(): Promise<PeerLog[]> {
		return (await this.host.read()).peerLog ?? [];
	}

	// ── Tools ──

	private makeTools() {
		const self = this;
		const agentParam = Type.String({ description: "The agent's name or id" });
		const ask = defineTool({
			name: "ask_agent",
			description: "Ask another of the owner's agents something and wait for its answer (up to a few minutes; a later answer comes back here as a new message).",
			parameters: Type.Object({ agent: agentParam, message: Type.String() }),
			execute: async (args, api, context) => {
				let sent: { envelope: Envelope; to: AgentRef };
				try {
					sent = await self.send("ask", args.agent, args.message, String(api.conversationId));
				} catch (error) {
					return { output: [{ type: "text", text: (error as Error).message }], isError: true };
				}
				const { envelope, to } = sent;
				const reply = await self.wait(envelope.requestId!, context);
				const details = { to, envelopeId: envelope.id, traceId: envelope.traceId, mode: "ask", ...(reply !== undefined ? { reply, status: "replied" } : { status: "no_reply" }) };
				return { output: [{ type: "text", text: reply !== undefined ? reply : `No answer from ${to.name} yet. When it answers, it comes back to this conversation.` }], details: details as never };
			},
		});
		const tell = defineTool({
			name: "tell_agent",
			description: "Tell another of the owner's agents something, without waiting for an answer (it may write back on its own).",
			parameters: Type.Object({ agent: agentParam, message: Type.String() }),
			execute: async (args, api) => {
				try {
					const { envelope, to } = await self.send("tell", args.agent, args.message, String(api.conversationId));
					return { output: [{ type: "text", text: `Told ${to.name}.` }], details: { to, envelopeId: envelope.id, traceId: envelope.traceId, mode: "tell", status: "sent" } as never };
				} catch (error) {
					return { output: [{ type: "text", text: (error as Error).message }], isError: true };
				}
			},
		});
		return { ask, tell };
	}

	/** Waits for an ask's answer up to the timeout; undefined when it's late. */
	private async wait(requestId: string, context: Context): Promise<string | undefined> {
		const early = this.early.get(requestId);
		if (early !== undefined) {
			this.early.delete(requestId);
			return early;
		}
		let timer: ReturnType<typeof setTimeout> | undefined;
		const answer = new Promise<string | undefined>((resolve) => {
			this.waiters.set(requestId, resolve);
			timer = setTimeout(() => resolve(undefined), this.host.askTimeoutMs);
		});
		try {
			const reply = await awaitWithContext(answer, context);
			if (reply === undefined) await this.host.write((s) => void (s.asks ?? []).filter((a) => a.requestId === requestId).forEach((a) => (a.status = "late")));
			return reply;
		} finally {
			clearTimeout(timer);
			this.waiters.delete(requestId);
		}
	}
}
