/**
 * A local agent (docs/spec/06-agents §3, §5.4): one pi-durable session, one conversation per person. The owner's is
 * the agent's Chat (the in-app channel); other people's are reached through their channels, or, for now, the
 * channel simulator ("talk as María"). Before a turn the memory relevant to the message is recalled into the
 * system section; after it the message and the answer are retained in the person's partition (ME2, ME2a).
 * A turn's tool calls show as one `steps` line (UI2). Schedules, the heartbeat, reminders and triggers start runs,
 * each its own read-only conversation (`run:<id>`, 06 §6); what the agent sends on its own shows in the person's
 * conversation as an outbound message. Tool calls that need the owner show an approval item until answered, and
 * changes show result cards with Undo (06 §4.2, §9).
 */
import { durableConnectorsExtension } from "../connectors/extension.js";
import type { ConnectorHub } from "../connectors/hub.js";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ConversationBusy, createRegistry, Harness, watchEvents, type AgentEventStream, type Conversation, type Extension } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import type { ApprovalItem, ContainerRef, ModelRef, ResultItem, SessionEvent, Snapshot, TimelineItem } from "@piopio/protocol";
import { AGENT_ENTRY, AgentCore, type AgentCoreOptions, alwaysLabel, type Envelope, NOTICE_ENTRY, OUT_ENTRY, type AgentDefinition, type Approval, type MemoryProvider, type ResultCard, type RunRecord, type UndoRecord } from "@piopio/runtime";
import { buildInput } from "../input.js";
import { EngineError, type ModelHub } from "../models.js";
import { TimelineBuilder } from "../timeline/builder.js";
import { DurableEventMapper } from "../timeline/pi-durable.js";
import { groupSteps, StepsView } from "../timeline/steps.js";
import { createWebExtension, type WebOptions } from "../tools/web.js";
import { Emitter, type Runtime, type SubmitOptions } from "./runtime.js";

const ctx = BACKGROUND_CONTEXT;

export type AgentOpenOptions = {
	/** Connected apps: their tools, with changes going through the agent's approvals. */
	connectors?: ConnectorHub;
	ref: ContainerRef;
	file: string;
	hub: ModelHub;
	definition: () => AgentDefinition;
	instructions: () => string;
	memory: () => MemoryProvider;
	webOptions?: WebOptions;
	/** A person's conversation answered, a run started or settled, a message went out (catalog recency, sidebar). */
	onActivity?: () => void;
	/** Tests move the clock. */
	now?: () => Date;
	/** Pause, spend or the Inbox changed (catalog, badges). */
	onStatus?: () => void;
	/** An approval was asked or answered (notifications). */
	onApproval?: (approval: Approval) => void;
	/** Apple app tools through the Mac app (06 §4.1). */
	appTool?: AgentCoreOptions["appTool"];
	/** The other agents (06 §7). */
	peers?: AgentCoreOptions["peers"];
	askTimeoutMs?: number;
};

type RawEntry = { id: string | number; kind: string; data?: unknown; model?: { timestamp?: number }[] };

export class AgentRuntime implements Runtime {
	private readonly views = new Map<string, Promise<AgentView>>();
	/** The views attached, to route approvals and undos to their conversation. */
	readonly live = new Set<AgentView>();
	private owner!: AgentView;

	private constructor(
		private readonly options: AgentOpenOptions,
		private readonly harness: Harness,
		readonly core: AgentCore,
	) {}

	get ref(): ContainerRef {
		return this.options.ref;
	}

	static async open(options: AgentOpenOptions): Promise<AgentRuntime> {
		const storage = await openNodeSqliteStorage(options.file);
		const registry = createRegistry();
		const web = createWebExtension(options.hub, options.webOptions) as unknown as Extension;
		const wantsWeb = () => options.definition().tools.builtin.some((t) => t === "web_search" || t === "web_fetch");
		// Connected apps: changes ask through the agent's own approvals (durable), so the tool itself doesn't ask.
		const hub = options.connectors;
		const apps = hub ? (durableConnectorsExtension(hub, "agent", () => async () => ({ approved: true })) as unknown as Extension) : undefined;
		const hasApps = () => Boolean(hub && (hub.calendars("agent").length || hub.mailboxes("agent").length));
		const definition = () => withConnectorApprovals(options.definition(), hub);
		const harness = await Harness.open(storage, { models: options.hub.models, registry }, ctx);
		let runtime: AgentRuntime | undefined;
		const core = new AgentCore({
			harness,
			definition,
			instructions: options.instructions,
			memory: options.memory,
			extensions: () => [...(wantsWeb() ? [web] : []), ...(apps && hasApps() ? [apps] : [])],
			context: ctx,
			...(options.now ? { now: options.now } : {}),
			...(options.appTool ? { appTool: options.appTool } : {}),
			...(options.peers ? { peers: options.peers } : {}),
			...(options.askTimeoutMs ? { askTimeoutMs: options.askTimeoutMs } : {}),
			onPeerLog: () => options.onActivity?.(),
			onRun: () => options.onActivity?.(),
			onOutbound: () => options.onActivity?.(),
			onApproval: (approval) => {
				for (const view of runtime?.live ?? []) if (view.conversationId === approval.conversationId) view.approval(approval);
				options.onApproval?.(approval);
			},
			onUndo: (undo) => {
				for (const view of runtime?.live ?? []) if (view.conversationId === undo.conversationId) view.undone(undo);
			},
			onStatus: () => options.onStatus?.(),
		});
		for (const e of [web, core.extension, ...(apps ? [apps] : [])]) registry.install(e as never);
		runtime = new AgentRuntime(options, harness, core);
		runtime.owner = await runtime.view(ownerOf(options.definition()));
		await core.configureAll();
		harness.resume();
		await core.start();
		return runtime;
	}

	definition(): AgentDefinition {
		return this.options.definition();
	}

	/** A run's conversation, read-only. */
	async runView(runId: string): Promise<AgentView> {
		const key = `run:${runId}`;
		let pending = this.views.get(key);
		if (!pending) {
			pending = (async () => {
				const run = (await this.core.proactive.overview()).runs.find((r) => r.id === runId);
				if (!run) throw new EngineError("NOT_FOUND", `No run “${runId}”.`);
				const conversation = await this.harness.conversation(Number(run.conversationId) as never, ctx);
				if (!conversation) throw new EngineError("NOT_FOUND", "That run's conversation is gone.");
				return AgentView.attach(this, { run }, conversation);
			})();
			this.views.set(key, pending);
			pending.catch(() => this.views.delete(key));
		}
		return pending;
	}

	runs() {
		return this.core.proactive.overview();
	}

	/** The conversation with another agent (`agent:<id>`), read-only. */
	async peerView(peerId: string): Promise<AgentView> {
		const key = `agent:${peerId}`;
		let pending = this.views.get(key);
		if (!pending) {
			pending = (async () => {
				const peer = (await this.options.peers?.directory())?.find((a) => a.id === peerId);
				if (!peer) throw new EngineError("NOT_FOUND", `No agent “${peerId}”.`);
				const conversation = await this.core.agentConversation(peerId);
				return AgentView.attach(this, { peer: { id: peer.id, name: peer.name } }, conversation);
			})();
			this.views.set(key, pending);
			pending.catch(() => this.views.delete(key));
		}
		return pending;
	}

	/** Runs a schedule from the definition now, or any prompt (a manual run). */
	async runNow(scheduleId?: string, prompt?: string): Promise<RunRecord> {
		await this.ensureCredential();
		if (scheduleId) {
			const s = (this.options.definition().schedules ?? []).find((x) => x.id === scheduleId);
			if (!s) throw new EngineError("NOT_FOUND", `No schedule “${scheduleId}”.`);
			return this.core.proactive.startRun("manual", s.id, s.prompt, s.deliverTo);
		}
		if (!prompt?.trim()) throw new EngineError("INVALID", "Give a schedule or a prompt.");
		return this.core.proactive.startRun("manual", "manual", prompt.trim());
	}

	/** A webhook trigger fired: its prompt with the body in `{{body}}` runs (PR3). `deliveryId` makes a retry a no-op. */
	async trigger(triggerId: string, body: string, deliveryId?: string): Promise<RunRecord> {
		const t = (this.options.definition().triggers ?? []).find((x) => x.id === triggerId);
		if (!t) throw new EngineError("NOT_FOUND", `No trigger “${triggerId}”.`);
		await this.ensureCredential();
		const text = body.length > 20_000 ? `${body.slice(0, 20_000)}\n… (cut)` : body;
		const prompt = t.prompt.includes("{{body}}") ? t.prompt.replaceAll("{{body}}", text) : `${t.prompt}\n\n${text}`;
		return this.core.proactive.startRun("trigger", t.id, prompt, undefined, deliveryId ? `trigger:${t.id}:${deliveryId}` : undefined);
	}

	/** A person's conversation: `person:<contactId>`, or the owner's. */
	async view(contactId?: string): Promise<AgentView> {
		const id = contactId ?? ownerOf(this.options.definition());
		if (!this.core.contact(id)) throw new EngineError("NOT_FOUND", `No contact “${id}” in this agent.`);
		let pending = this.views.get(id);
		if (!pending) {
			pending = (async () => {
				const conversation = await this.core.conversation(id);
				return AgentView.attach(this, { contactId: id }, conversation);
			})();
			this.views.set(id, pending);
			pending.catch(() => this.views.delete(id));
		}
		return pending;
	}

	/** The definition changed: every conversation takes the new model and tools. */
	async reconfigure(): Promise<void> {
		await this.core.configureAll();
		for (const view of await Promise.allSettled(this.views.values())) if (view.status === "fulfilled") await view.value.reloadSettings();
	}

	/** Who has a conversation, with its last message (the Conversations tab). */
	async people(): Promise<{ contactId: string; started: boolean; lastAt?: string; preview?: string }[]> {
		const started = await this.core.people();
		const out = [];
		for (const c of this.options.definition().contacts) {
			if (!started[c.id]) {
				out.push({ contactId: c.id, started: false });
				continue;
			}
			const items = (await this.view(c.id)).snapshot().items.filter((i) => i.kind === "user" || i.kind === "assistant");
			const last = items.at(-1);
			const preview = last?.kind === "user" ? last.text : last?.kind === "assistant" ? last.parts.filter((p) => p.type === "text").map((p) => p.text).join("") : undefined;
			out.push({ contactId: c.id, started: true, ...(last ? { lastAt: last.at } : {}), ...(preview ? { preview: preview.replace(/\s+/g, " ").slice(0, 140) } : {}) });
		}
		return out;
	}

	/** Other agents it has talked with (the Conversations tab). */
	async peers(): Promise<{ id: string; name: string; lastAt?: string; preview?: string }[]> {
		const directory = (await this.options.peers?.directory()) ?? [];
		const out = [];
		for (const peerId of Object.keys((await this.core.peers.logs()).reduce((m, l) => ({ ...m, [l.from.id === this.ref.id ? l.to.id : l.from.id]: true }), {} as Record<string, boolean>))) {
			const peer = directory.find((a) => a.id === peerId);
			if (!peer || peer.id === this.ref.id) continue;
			const last = (await this.core.peers.logs()).filter((l) => l.from.id === peerId || l.to.id === peerId).at(-1);
			out.push({ id: peer.id, name: peer.name, ...(last ? { lastAt: last.at, preview: (last.reply ?? last.text).replace(/\s+/g, " ").slice(0, 140) } : {}) });
		}
		return out;
	}

	activity(): void {
		this.options.onActivity?.();
	}

	watch(conversation: Conversation): Promise<AgentEventStream> {
		return watchEvents(this.harness, conversation.id, ctx);
	}

	submission(id: string) {
		return this.harness.submission(Number(id) as never, ctx);
	}

	ensureCredential(): Promise<void> {
		const def = this.options.definition();
		const provider = def.models.default.includes(":") ? def.models.default.split(":")[0]! : "openrouter";
		return this.options.hub.ensureCredential(provider).catch(() => undefined);
	}

	// ── Runtime: the owner's conversation ──

	snapshot(): Snapshot {
		return this.owner.snapshot();
	}

	onEvents(listener: (events: SessionEvent[]) => void): () => void {
		return this.owner.onEvents(listener);
	}

	submit(text: string, options: SubmitOptions) {
		return this.owner.submit(text, options);
	}

	abort(): Promise<void> {
		return this.owner.abort();
	}

	async configure(): Promise<void> {
		throw new EngineError("INVALID", "An agent's model is part of its definition: change it in the Definition tab.");
	}

	removeQueued(queueId: string): Promise<void> {
		return this.owner.removeQueued(queueId);
	}

	clearQueue(): Promise<void> {
		return this.owner.clearQueue();
	}

	async close(): Promise<void> {
		this.core.close();
		for (const view of await Promise.allSettled(this.views.values())) if (view.status === "fulfilled") await view.value.stop();
		await this.harness.close(ctx);
	}
}

/** One person's conversation with the agent, as a session the client subscribes to. */
export class AgentView implements Runtime {
	private readonly emitter = new Emitter();
	private readonly builder: TimelineBuilder;
	private readonly mapper: DurableEventMapper;
	private readonly steps = new StepsView((items) => this.group(items));
	private stream?: AgentEventStream;
	private readonly queueTexts = new Map<string, string>();
	/** What the person said, for each turn still running (retained with the answer when it ends). */
	private readonly pending: { said: string; itemCount: number }[] = [];
	/** Messages the agent sent on its own (entry id → text and where from); shown as its, not the person's. */
	private readonly outbound = new Map<string, { text: string; from: string }>();
	/** This conversation's approvals, result cards (by tool call) and undo records. */
	private readonly approvals = new Map<string, Approval>();
	private readonly cards = new Map<string, { card: ResultCard; undo?: string }>();
	private readonly undos = new Map<string, UndoRecord>();
	/** Tool call id → its arguments, from the assistant's messages (for calls blocked before they ran). */
	private readonly calls = new Map<string, unknown>();
	readonly contactId?: string;
	readonly run?: RunRecord;
	readonly peer?: { id: string; name: string };
	/** Messages from other agents in this conversation (entry id → the envelope). */
	private readonly agentMsgs = new Map<string, Envelope & { late?: boolean }>();
	/** ask_agent / tell_agent results (call id → details). */
	private readonly peerCalls = new Map<string, { to?: { id: string; name: string }; traceId?: string; status?: string; reply?: string }>();

	private constructor(
		private readonly agent: AgentRuntime,
		who: { contactId: string } | { run: RunRecord } | { peer: { id: string; name: string } },
		private readonly conversation: Conversation,
	) {
		if ("run" in who) this.run = who.run;
		else if ("peer" in who) this.peer = who.peer;
		else this.contactId = who.contactId;
		this.builder = new TimelineBuilder(this.ref);
		this.mapper = new DurableEventMapper(this.builder, (id) => this.queueTexts.get(id));
	}

	get ref(): ContainerRef {
		return { ...this.agent.ref, conversationId: this.run ? `run:${this.run.id}` : this.peer ? `agent:${this.peer.id}` : `person:${this.contactId}` };
	}

	static async attach(agent: AgentRuntime, who: { contactId: string } | { run: RunRecord } | { peer: { id: string; name: string } }, conversation: Conversation): Promise<AgentView> {
		const view = new AgentView(agent, who, conversation);
		const stream = await agent.watch(conversation);
		view.stream = stream;
		view.load(stream.snapshot as never, false);
		for (const undo of await agent.core.safety.undos()) if (undo.conversationId === view.conversationId) view.undos.set(undo.id, undo);
		for (const approval of await agent.core.safety.approvals(view.conversationId)) view.approval(approval, false);
		view.steps.snapshot(view.items());
		agent.live.add(view);
		await view.settings();
		view.builder.flush();
		stream.start(async (events) => {
			let ended = false;
			for (const event of events as { type: string; entry?: RawEntry; entries?: RawEntry[] }[]) {
				if (event.type === "run_end") ended = true;
				if (event.type === "snapshot") {
					view.load(event as never, true);
					continue;
				}
				view.mapper.apply(event as never);
				if (event.entry) view.noteEntry(event.entry, true);
			}
			view.emit(view.builder.flush());
			if (ended) void view.turnEnded();
		});
		return view;
	}

	/** The transcript, with outbound messages and notices in place. */
	private load(snapshot: { entries?: RawEntry[] }, emit: boolean): void {
		this.mapper.applySnapshot(snapshot as never, false);
		for (const entry of snapshot.entries ?? []) this.noteEntry(entry, false);
		if (emit) this.builder.resnapshot();
	}

	get conversationId(): string {
		return String(this.conversation.id);
	}

	/** ask_agent / tell_agent as a message to the other agent, with its answer once it comes (AA5). */
	private agentCall(item: Extract<TimelineItem, { kind: "tool" }>): TimelineItem {
		const args = (item.args ?? {}) as { agent?: string; message?: string };
		const d = this.peerCalls.get(item.callId);
		const me = { id: this.agent.ref.id, name: this.agent.definition().name };
		const failed = item.status === "error" || item.status === "interrupted";
		const status = item.status === "running" || item.status === "pending_approval" ? "waiting" : failed ? "failed" : ((d?.status as "replied" | "no_reply" | "sent") ?? "sent");
		const reply = failed ? item.output : d?.reply;
		return {
			kind: "agent_msg",
			id: item.id,
			at: item.at,
			fromAgent: me,
			toAgent: d?.to ?? { id: args.agent ?? "", name: args.agent ?? "agent" },
			text: args.message ?? "",
			direction: "out",
			mode: item.tool === "ask_agent" ? "ask" : "tell",
			status,
			...(reply ? { reply } : {}),
			...(d?.traceId ? { traceId: d.traceId } : {}),
		};
	}

	/** An approval asked here, or its answer: one item, placed when it was asked. */
	approval(approval: Approval, live = true): void {
		const had = this.approvals.has(approval.id);
		this.approvals.set(approval.id, approval);
		if (!had) this.builder.insert(this.approvalItem(approval), live ? undefined : this.builder.firstAfter(approval.requestedAt), live);
		if (live) this.emit(had ? [{ type: "item.updated", item: this.approvalItem(approval) }] : this.builder.flush());
	}

	undone(undo: UndoRecord): void {
		this.undos.set(undo.id, undo);
		const callId = [...this.cards].find(([, c]) => c.undo === undo.id)?.[0];
		if (callId) this.emit([{ type: "item.updated", item: { kind: "system", id: "touch", at: undo.at, level: "info", text: "" } }]);
	}

	private approvalItem(a: Approval): ApprovalItem {
		return {
			kind: "approval",
			id: `approval:${a.id}`,
			at: a.requestedAt,
			approvalId: a.id,
			tool: a.tool,
			title: a.title,
			args: a.args,
			status: a.status,
			...(a.editedArgs ? { editedArgs: a.editedArgs } : {}),
			...(a.reason ? { reason: a.reason } : {}),
			expiresAt: new Date(a.expiresAt).toISOString(),
			always: alwaysLabel(a.key, this.agent.definition()),
		};
	}

	/** Steps lines, each followed by the cards of what its tools changed (UI2: result cards stay visible). */
	private group(items: readonly TimelineItem[]): TimelineItem[] {
		const out: TimelineItem[] = [];
		for (const item of groupSteps(items)) {
			out.push(item);
			if (item.kind !== "steps") continue;
			for (const tool of item.tools) {
				const card = this.cards.get(tool.callId);
				if (card && tool.status === "done") out.push(this.resultItem(tool.callId, tool.at, card));
			}
		}
		return out;
	}

	private resultItem(callId: string, at: string, { card, undo }: { card: ResultCard; undo?: string }): ResultItem {
		const record = undo ? this.undos.get(undo) : undefined;
		const until = record ? record.until : Date.parse(at) + 24 * 3600_000;
		const status = record?.status === "undone" || record?.status === "failed" ? record.status : until < Date.now() ? ("expired" as const) : ("available" as const);
		return { kind: "result", id: `result:${callId}`, at, callId, card, ...(undo ? { undo: { id: undo, status, until: new Date(until).toISOString() } } : {}) };
	}

	private noteEntry(entry: RawEntry, live: boolean): void {
		const id = String(entry.id);
		if (entry.kind === AGENT_ENTRY) this.agentMsgs.set(id, entry.data as Envelope);
		type Message = { role?: string; toolCallId?: string; toolName?: string; isError?: boolean; content?: unknown; details?: { card?: ResultCard; undo?: string; to?: { id: string; name: string }; traceId?: string; status?: string; reply?: string } };
		for (const m of (entry.model ?? []) as Message[]) {
			if (m.role === "assistant" && Array.isArray(m.content)) {
				for (const b of m.content as { type: string; id?: string; arguments?: unknown }[]) if (b.type === "toolCall" && b.id) this.calls.set(b.id, b.arguments);
			}
			if (m.role !== "toolResult" || !m.toolCallId) continue;
			if (m.details?.card) this.cards.set(m.toolCallId, { card: m.details.card, ...(m.details.undo ? { undo: m.details.undo } : {}) });
			if (m.toolName === "ask_agent" || m.toolName === "tell_agent") this.peerCalls.set(m.toolCallId, m.details ?? {});
			// A call that was blocked before it ran (denied, paused, not allowed) has no tool item: show it failed.
			if (m.isError && !this.builder.currentItems.some((i) => i.id === `tool:${m.toolCallId}`)) {
				const text = Array.isArray(m.content) ? (m.content as { text?: string }[]).map((b) => b.text ?? "").join("") : String(m.content ?? "");
				this.builder.toolStart(m.toolCallId, m.toolName ?? "tool", this.calls.get(m.toolCallId) ?? {});
				this.builder.toolEnd(m.toolCallId, text, true);
				if (!live) this.builder.flush();
			}
		}
		if (entry.kind === OUT_ENTRY) {
			const data = entry.data as { text: string; from: string };
			this.outbound.set(id, data);
			// The model reads it as a note; it arrives as a user message, or (as a write) only as an entry.
			this.builder.user(id, data.text, entry.model?.[0]?.timestamp);
		} else if (entry.kind === NOTICE_ENTRY) {
			const data = entry.data as { text: string; at: string };
			const item: TimelineItem = { kind: "system", id: `notice:${id}`, at: data.at, level: "info", text: data.text };
			this.builder.insert(item, live ? undefined : this.builder.firstAfter(data.at), live);
		}
	}

	/** The builder's items as the client sees them: outbound notes become the agent's messages. */
	private items(): TimelineItem[] {
		return this.builder.snapshot().items.map((item) => {
			const out = item.kind === "user" ? this.outbound.get(item.id) : undefined;
			if (out) return { kind: "assistant", id: item.id, at: item.at, parts: [{ type: "text", text: out.text }], status: "done", outbound: { from: out.from } };
			const msg = item.kind === "user" ? this.agentMsgs.get(item.id) : undefined;
			if (msg) return { kind: "agent_msg", id: item.id, at: item.at, fromAgent: msg.from, toAgent: msg.to, text: msg.text, direction: "in", mode: msg.late ? "reply" : msg.mode, traceId: msg.traceId };
			if (item.kind === "tool" && (item.tool === "ask_agent" || item.tool === "tell_agent")) return this.agentCall(item);
			const approval = item.kind === "approval" ? this.approvals.get(item.approvalId) : undefined;
			return approval ? this.approvalItem(approval) : item;
		});
	}

	private emit(events: SessionEvent[]): void {
		const shown = events.map((e) => (e.type === "resnapshot" ? { ...e, snapshot: { ...e.snapshot, items: this.items() } } : e));
		const out = this.steps.events(shown, () => this.items());
		if (out.length) this.emitter.emit(out);
	}

	private async settings(): Promise<void> {
		const agent = (await this.conversation.agent(ctx)) as { model?: { provider: string; id?: string; modelId?: string }; thinkingLevel?: string };
		const id = agent.model?.id ?? agent.model?.modelId;
		this.builder.setState({ ...(agent.model && id ? { model: { provider: agent.model.provider, id } as ModelRef } : {}), thinking: agent.thinkingLevel ?? "default", tools: { web: true } } as never);
	}

	async reloadSettings(): Promise<void> {
		await this.settings();
		this.emit(this.builder.flush());
	}

	/** A turn ended: retain what was said and the answer (in the background; failures only lose that memory). */
	private async turnEnded(): Promise<void> {
		const turn = this.pending.shift();
		if (!turn || !this.contactId) return;
		const items = this.builder.snapshot().items.slice(turn.itemCount);
		const answer = [...items].reverse().find((i) => i.kind === "assistant" && i.parts.some((p) => p.type === "text" && p.text.trim()));
		const text = answer?.kind === "assistant" ? answer.parts.filter((p) => p.type === "text").map((p) => p.text).join("") : "";
		await this.agent.core.afterTurn(this.contactId, turn.said, text, { ref: `person:${this.contactId}`, ...(answer ? { itemId: answer.id } : {}) }).catch(() => undefined);
		await this.agent.core.safety.checkBudget().catch(() => undefined);
		this.agent.activity();
	}

	snapshot(): Snapshot {
		return { ...this.builder.snapshot(), items: this.group(this.items()) };
	}

	onEvents(listener: (events: SessionEvent[]) => void): () => void {
		return this.emitter.on(listener);
	}

	async submit(text: string, options: SubmitOptions) {
		if (!this.contactId) throw new EngineError("INVALID", this.peer ? "A conversation between agents is read-only." : "A run's conversation is read-only.");
		// /pause, /resume, and messages while paused or out of budget (06 §9 AS3–AS4) don't start a turn.
		if (await this.agent.core.intercept(this.contactId, text)) {
			this.agent.activity();
			return { disposition: "started" as const };
		}
		const busy = this.builder.status === "running";
		await this.agent.ensureCredential();
		await this.agent.core.beforeTurn(this.contactId, this.conversation.id, text).catch(() => undefined);
		const input = buildInput(text, options.attachments);
		try {
			const submission = await this.conversation.submit(
				{ type: "input", content: input.content, ...(input.entry ? { entry: input.entry } : {}), whenBusy: options.whenBusy, ...(options.requestId ? { requestId: options.requestId } : {}) } as Parameters<Conversation["submit"]>[0],
				ctx,
			);
			this.queueTexts.set(String(submission.id), text);
			this.pending.push({ said: text, itemCount: this.builder.snapshot().items.length });
			this.mapper.refreshQueue();
			this.emit(this.builder.flush());
		} catch (error) {
			if (error instanceof ConversationBusy) throw new EngineError("BUSY", "This conversation is busy.");
			throw error;
		}
		this.agent.activity();
		return { disposition: busy ? ("queued" as const) : ("started" as const) };
	}

	async abort(): Promise<void> {
		await this.conversation.abort(ctx);
	}

	async configure(): Promise<void> {
		throw new EngineError("INVALID", "An agent's model is part of its definition: change it in the Definition tab.");
	}

	async removeQueued(queueId: string): Promise<void> {
		const submission = await this.agent.submission(queueId);
		if (!submission) throw new EngineError("NOT_FOUND", "That message is no longer queued.");
		await submission.abort(ctx);
	}

	async clearQueue(): Promise<void> {
		for (const q of this.builder.snapshot().state.queue) await this.removeQueued(q.id).catch(() => undefined);
	}

	async stop(): Promise<void> {
		this.agent.live.delete(this);
		await this.stream?.stop();
	}

	/** Person views close with their agent. */
	async close(): Promise<void> {}
}

function ownerOf(definition: AgentDefinition): string {
	return definition.contacts.find((c) => c.role === "owner")?.id ?? "owner";
}

/** Connector writes, sends and deletes need the owner's OK in agents too (docs/spec/12 §1), except writes they said not to ask about. */
function withConnectorApprovals(def: AgentDefinition, hub: ConnectorHub | undefined): AgentDefinition {
	if (!hub || hub.accounts().length === 0) return def;
	// A tool asks when any connected app's setting for it asks; sending and deleting always do (when not off).
	const asked = new Set<string>();
	for (const c of hub.definitions) {
		if (!hub.accounts(c.id).length) continue;
		for (const g of hub.capabilities(c.id)) if (g.permission === "ask") for (const t of g.tools) asked.add(t);
		for (const t of ["calendar_delete_event", "mail_send"]) if (hub.permission(c.id, t) !== "off") asked.add(t);
	}
	const rules = [...new Set([...(def.policies?.requireApproval ?? []), ...asked])];
	return { ...def, policies: { ...def.policies, requireApproval: rules } };
}
