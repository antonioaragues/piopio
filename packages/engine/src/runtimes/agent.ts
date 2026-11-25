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
import { connectorTools, offeredNow } from "../connectors/tools.js";
import type { ConnectorHub } from "../connectors/hub.js";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ConversationBusy, createRegistry, Harness, type Conversation, type ConversationWatch, type Extension, type SubmissionDraft } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { createToolSearchExtension } from "@earendil-works/pi-durable/tool-search";
import type { ApprovalItem, AssistantItem, ContainerRef, ModelRef, ResultItem, SessionEvent, Snapshot, TimelineItem, UtilityChoice } from "@piopio/protocol";
import type { AgentFileInfo, AgentFilesBridge } from "@piopio/runtime";
import type { KeptAttachment } from "../attachment-files.js";
import { AGENT_ENTRY, AgentCore, type AgentCoreOptions, alwaysLabel, modelOf, type Envelope, LEARN_ENTRY, NOTICE_ENTRY, OUT_ENTRY, type AgentDefinition, type Approval, type MemoryProvider, type ResultCard, type RunRecord, type UndoRecord, DurableViewMapper, type DurableView, type Entry } from "@piopio/runtime";
import { BOT_TOKEN } from "../channels/telegram.js";
import { buildInput } from "../input.js";
import { EngineError, type ModelHub } from "../models.js";
import { emptyUsage, TimelineBuilder, toUsage, type PiMessage, type PiUsage } from "@piopio/runtime";

import { groupSteps, StepsView } from "../timeline/steps.js";
import { createWebExtension, type WebOptions } from "../tools/web.js";
import { durableBrowserExtension, type BrowserCall } from "../tools/browser-tools.js";
import { replacedVisuals } from "../tools/visuals.js";
import { Emitter, type Runtime, type SubmitOptions } from "./runtime.js";

const ctx = BACKGROUND_CONTEXT;
/** How much of a conversation a view loads: its newest entries (there is no loading earlier ones yet). */
const MAX_HISTORY = 5_000;

export type AgentOpenOptions = {
	/** Connected apps: their tools, with changes going through the agent's approvals. */
	connectors?: ConnectorHub;
	/** More extensions, asked for at each run (About me when it's shared with agents). */
	extraExtensions?: () => Extension[];
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
	/** A person's turn ended with this answer (channels send it back where the message came from). */
	/** A turn ended: what was said, the answer, and the visuals it showed (docs/spec/25 §8). */
	onAnswer?: (contactId: string, said: string, answer: string, visuals: { title: string; html: string }[]) => void;
	/** The agent sent a message on its own (channels deliver it). */
	onOutbound?: (to: string, text: string, from: string) => void;
	/** The owner pasted a Telegram bot token in the chat: connect it and say what happened (docs/spec/19 S4). */
	connectTelegram?: (token: string) => Promise<string>;
	/** The agent sets itself up (docs/spec/19 S2): saved to its definition and instructions; returns what they were. */
	updateSelf?: AgentCoreOptions["updateSelf"];
	/** Event routines (docs/spec/19 S3): a webhook watch's URL, and a notice that the agent's watches changed. */
	watchUrl?: (watchId: string) => string | undefined;
	onWatches?: () => void;
	/** Automations (docs/spec/27): the agent makes its own through these; the engine keeps and fires them. */
	automations?: AgentCoreOptions["automations"];
	/** A run started or settled (an automation's run follows it). */
	onRun?: (run: RunRecord) => void;
	/** Files kept in its folder (docs/spec/06-agents §14): what it reads, and keeping what the owner sends. */
	files?: { bridge: AgentFilesBridge; keep(attachments: readonly KeptAttachment[], from: string): AgentFileInfo[] };
	/** Apple app tools through the Mac app (06 §4.1). */
	appTool?: AgentCoreOptions["appTool"];
	/** Piopio's browser through the Mac app (docs/spec/22 W3), offered when the definition turns it on. */
	browser?: BrowserCall;
	/** The other agents (06 §7). */
	peers?: AgentCoreOptions["peers"];
	askTimeoutMs?: number;
	/** Tests: the utility model for learned facts (default: the engine's), and how quiet a conversation must be. */
	learn?: AgentCoreOptions["learn"];
	learnQuietMs?: number;
	onLearned?: AgentCoreOptions["onLearned"];
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
		private readonly storage?: Awaited<ReturnType<typeof openNodeSqliteStorage>>,
	) {}

	/**
	 * Every priced answer in the agent, in all its conversations (people, runs, other agents, its own tasks), as the
	 * usage ledger reads them (docs/spec/34 §8.1): a view shows only a window of the latest entries. Ids are the entry
	 * ids the views use, so an answer a view already showed is the same row. Usage and model only.
	 */
	async answers(): Promise<AssistantItem[]> {
		if (!this.storage) return [];
		const out = new Map<string, AssistantItem>();
		let cursor: unknown;
		do {
			const page = await this.storage.scanConversations({}, 100, cursor as never, ctx);
			for (const record of page.items) {
				const conversation = await this.harness.conversation(record.id, ctx);
				let at: unknown;
				do {
					const entries = await conversation!.entries({}, 200, at as never, ctx);
					for (const entry of entries.items) {
						const m = (entry as { kind?: string; model?: PiMessage[] }).kind === "pi.assistant" ? (entry as { model?: PiMessage[] }).model?.[0] : undefined;
						if (m?.role !== "assistant" || out.has(String(entry.id))) continue;
						const a = m as Extract<PiMessage, { role: "assistant" }>;
						const usage = toUsage(a.usage);
						if (!usage) continue;
						out.set(String(entry.id), { kind: "assistant", id: String(entry.id), at: new Date(typeof a.timestamp === "number" ? a.timestamp : Date.now()).toISOString(), parts: [], status: "done", usage, ...(a.model ? { model: a.provider ? `${a.provider}/${a.model}` : a.model } : {}) });
					}
					at = entries.next;
				} while (at);
			}
			cursor = page.next;
		} while (cursor);
		return [...out.values()];
	}

	get ref(): ContainerRef {
		return this.options.ref;
	}

	static async open(options: AgentOpenOptions): Promise<AgentRuntime> {
		const storage = await openNodeSqliteStorage(options.file);
		const registry = createRegistry();
		const web = createWebExtension(options.hub, { ...options.webOptions, scope: options.ref.id }) as unknown as Extension;
		const wantsWeb = () => options.definition().tools.builtin.some((t) => t === "web_search" || t === "web_fetch");
		// Connected apps: changes ask through the agent's own approvals (durable), so the tool itself doesn't ask.
		const hub = options.connectors;
		// Rebuilt when the connected apps' tools change (Linear connected while the agent is open), so they're offered.
		let built: { key: string; extensions: Extension[] } | undefined;
		const toolSearch = createToolSearchExtension() as unknown as Extension;
		const appExtensions = (): Extension[] => {
			if (!hub || !(hub.calendars("agent").length || hub.mailboxes("agent").length || hub.mcpUses("agent").length)) return [];
			const tools = connectorTools(hub, "agent").filter((t) => offeredNow(t.name, hub, "agent"));
			const key = tools.map((t) => `${t.name}${t.deferred ? "*" : ""}`).join(",");
			if (built?.key !== key) {
				const apps = durableConnectorsExtension(hub, "agent", () => async () => ({ approved: true })) as unknown as Extension;
				// Apps with many tools: the agent finds the rest with tool_search.
				built = { key, extensions: tools.some((t) => t.deferred) ? [apps, toolSearch] : [apps] };
			}
			return built.extensions;
		};
		const definition = () => withConnectorApprovals(options.definition(), hub);
		// The browser (docs/spec/22 W3): acting on a site it isn't allowed asks the owner like its other approvals.
		let runtime: AgentRuntime | undefined;
		const browser = options.browser
			? (durableBrowserExtension(options.browser, (call, context) => async (request) => {
					const core = runtime?.core;
					if (!core) return { approved: false, reason: "the agent isn't ready" };
					const site = request.site;
					const page = typeof request.args.url === "string" ? request.args.url : undefined;
					return core.safety.ask({ callId: `${call.callId}:site:${site}`, tool: "browser_site", args: { site, ...(page ? { page } : {}) }, key: `browser_site:${site}` }, call.conversationId as never, context as never);
				}) as unknown as Extension)
			: undefined;
		const wantsBrowser = () => Boolean(browser && options.definition().tools.browser);
		const harness = await Harness.open(storage, { models: options.hub.models, registry }, ctx);
		// The extra extensions (writing, About me, visuals) must be installed too, or their tools are never offered and
		// their sections never read: a conversation's config names extensions, the registry holds them. Installing by
		// name replaces, so this is safe on every read.
		const extras = () => {
			const list = options.extraExtensions?.() ?? [];
			for (const e of list) registry.install(e as never);
			return list;
		};
		const core = new AgentCore({
			harness,
			definition,
			instructions: options.instructions,
			memory: options.memory,
			extensions: () => {
				const apps = appExtensions();
				for (const e of apps) registry.install(e as never);
				return [...(wantsWeb() ? [web] : []), ...(wantsBrowser() ? [browser!] : []), ...apps, ...extras()];
			},
			context: ctx,
			...(options.now ? { now: options.now } : {}),
			...(options.appTool ? { appTool: options.appTool } : {}),
			...(options.peers ? { peers: options.peers } : {}),
			...(options.askTimeoutMs ? { askTimeoutMs: options.askTimeoutMs } : {}),
			// Learned facts (docs/spec/14-memory M2) on the utility model, after a conversation goes quiet.
			// On the agent's own provider (automatic), unless its models.utility or Settings › Models says otherwise.
			learn: options.learn ?? ((system, prompt) => {
				const { provider, modelId } = modelOf(options.definition().models.default);
				return options.hub.utility(system, prompt, options.ref.id, { model: { provider, id: modelId }, ...agentUtility(options.definition().models.utility) });
			}),
			// Web search and learned facts are recorded under this agent's id (scope): they count toward its budget.
			extraSpend: (month) => options.hub.extraCosts.monthUsd(options.ref.id, month),
			...(options.learnQuietMs ? { learnQuietMs: options.learnQuietMs } : {}),
			...(options.onLearned ? { onLearned: options.onLearned } : {}),
			onPeerLog: () => options.onActivity?.(),
			onRun: (run) => {
				options.onActivity?.();
				options.onRun?.(run);
				// Its owner's conversation shows each run as a divider (docs/spec/21 D3), placed when it fired.
				for (const view of runtime?.live ?? []) if (view.isOwner) view.runLine(run, true);
			},
			onOutbound: (to, text, from) => {
				options.onActivity?.();
				options.onOutbound?.(to, text, from);
			},
			onApproval: (approval) => {
				for (const view of runtime?.live ?? []) if (view.conversationId === approval.conversationId) view.approval(approval);
				options.onApproval?.(approval);
			},
			onUndo: (undo) => {
				for (const view of runtime?.live ?? []) if (view.conversationId === undo.conversationId) view.undone(undo);
			},
			onStatus: () => options.onStatus?.(),
			...(options.watchUrl ? { watchUrl: options.watchUrl } : {}),
			...(options.onWatches ? { onWatches: options.onWatches } : {}),
			...(options.automations ? { automations: options.automations } : {}),
			...(options.files ? { files: options.files.bridge } : {}),
			...(options.updateSelf ? { updateSelf: options.updateSelf } : {}),
		});
		for (const e of [web, core.extension, ...(browser ? [browser] : []), ...appExtensions()]) registry.install(e as never);
		runtime = new AgentRuntime(options, harness, core, storage);
		runtime.owner = await runtime.view(ownerOf(options.definition()));
		await core.configureAll();
		harness.resume();
		await core.start();
		return runtime;
	}

	definition(): AgentDefinition {
		return this.options.definition();
	}

	/** Keeps the files the owner sent (06 §14 FL2) and says, for the model, what each was kept as. */
	keepFiles(attachments: readonly KeptAttachment[], contactId: string): string | undefined {
		const def = this.options.definition();
		if (!this.options.files || !attachments.length || !def.tools.builtin.includes("files") || contactId !== ownerOf(def)) return undefined;
		const kept = this.options.files.keep(attachments, contactId);
		return kept.length ? `[Kept in your files: ${kept.map((f) => f.name).join(", ")}]` : undefined;
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
	/** Now: a schedule, or a prompt. A trial run (right after it's set up, docs/spec/21 D4) says so in the chat. */
	async runNow(scheduleId?: string, prompt?: string, trial = false): Promise<RunRecord> {
		await this.ensureCredential();
		if (scheduleId) {
			const s = (this.options.definition().schedules ?? []).find((x) => x.id === scheduleId);
			if (!s) throw new EngineError("NOT_FOUND", `No schedule “${scheduleId}”.`);
			return this.core.proactive.startRun("manual", trial ? "trial" : s.id, s.prompt, s.deliverTo);
		}
		if (!prompt?.trim()) throw new EngineError("INVALID", "Give a schedule or a prompt.");
		return this.core.proactive.startRun("manual", trial ? "trial" : "manual", prompt.trim());
	}

	/** A webhook trigger fired: its prompt with the body in `{{body}}` runs (PR3). `deliveryId` makes a retry a no-op. */
	async trigger(triggerId: string, body: string, deliveryId?: string): Promise<RunRecord> {
		const t = (this.options.definition().triggers ?? []).find((x) => x.id === triggerId);
		if (!t) {
			// A webhook routine the agent set itself (the `watch` tool).
			const w = (await this.core.proactive.watches()).find((x) => x.id === triggerId && x.on === "webhook");
			if (!w) throw new EngineError("NOT_FOUND", `No trigger “${triggerId}”.`);
			const run = await this.fireWatch(w.id, body, deliveryId ?? `${Date.now()}`);
			if (!run) throw new EngineError("NOT_FOUND", `No trigger “${triggerId}”.`);
			return run;
		}
		await this.ensureCredential();
		const text = body.length > 20_000 ? `${body.slice(0, 20_000)}\n… (cut)` : body;
		const prompt = t.prompt.includes("{{body}}") ? t.prompt.replaceAll("{{body}}", text) : `${t.prompt}\n\n${text}`;
		return this.core.proactive.startRun("trigger", t.id, prompt, undefined, deliveryId ? `trigger:${t.id}:${deliveryId}` : undefined);
	}

	/**
	 * An automation fired (docs/spec/27): a run with its prompt, told where its result goes and its budget. `key` makes
	 * the same fire the same run.
	 */
	async runAutomation(automation: { id: string; name: string; result: string; deliverTo?: string; budgetPerRunUsd?: number }, prompt: string, key: string): Promise<RunRecord> {
		await this.ensureCredential();
		const owner = ownerOf(this.options.definition());
		const to = automation.deliverTo ?? owner;
		const note =
			automation.result === "quiet"
				? `Only message “${to}” if something needs their attention; otherwise send nothing.`
				: automation.result === "telegram"
					? `Send the result to “${to}” with send_message; it goes to them on Telegram.`
					: `Send the result to “${to}” with send_message, even when it's short.`;
		return this.core.proactive.startRun("automation", automation.id, prompt, automation.deliverTo, key, { label: automation.name, note, ...(automation.budgetPerRunUsd ? { budgetUsd: automation.budgetPerRunUsd } : {}) });
	}

	/** The reminders and watches it set itself, handed to automations (docs/spec/27 §6), and its runs. */
	async handOver() {
		const legacy = await this.core.proactive.handOver();
		return { ...legacy, runs: legacy.runs.length ? legacy.runs : (await this.core.proactive.overview()).runs };
	}

	/** Something a routine waits for happened (a file, an email, a webhook): a run (docs/spec/19 S3). */
	async fireWatch(watchId: string, happened: string, key: string): Promise<RunRecord | undefined> {
		await this.ensureCredential();
		return this.core.proactive.fireWatch(watchId, happened, key);
	}

	/** Its first words to the owner, written by the engine (an agent that interviews, docs/spec/19 S2). */
	greet(text: string, suggestions?: string[]): Promise<void> {
		return this.core.proactive.greet(text, suggestions);
	}

	/** The routines the agent set that wait for events. */
	watches() {
		return this.core.proactive.watches();
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

	answered(contactId: string, said: string, answer: string, visuals: { title: string; html: string }[] = []): void {
		this.options.onAnswer?.(contactId, said, answer, visuals);
	}

	/** A note in the owner's conversation, from the app (not the agent, not seen by the model). */
	notice(text: string): Promise<void> {
		return this.core.proactive.notice(text);
	}

	connectTelegram(token: string): Promise<string> | undefined {
		return this.options.connectTelegram?.(token);
	}

	/**
	 * The conversation's history, then a watch of its state (read in that order, so the watch is newer). The history
	 * is pi-durable's raw entries, which a compaction never changes: reading the model's context here
	 * (`Conversation.context()`) dropped from the chat everything a compaction had summarized. The newest
	 * `MAX_HISTORY` entries, oldest first.
	 */
	async watch(conversation: Conversation): Promise<{ transcript: Entry[]; watch: ConversationWatch }> {
		const newest: Entry[] = [];
		let cursor: unknown;
		do {
			const page = await conversation.entries({ order: "descending" }, 500, cursor as never, ctx);
			newest.push(...(page.items as unknown as Entry[]));
			cursor = page.next;
		} while (cursor && newest.length < MAX_HISTORY);
		return { transcript: newest.slice(0, MAX_HISTORY).reverse(), watch: await conversation.watch(ctx) };
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
	private readonly mapper: DurableViewMapper<TimelineItem>;
	private readonly steps = new StepsView((items) => this.group(items), () => this.items());
	private watch?: ConversationWatch;
	private readonly queueTexts = new Map<string, string>();
	/** What the person said, for each turn still running (retained with the answer when it ends). */
	private readonly pending: { said: string; itemCount: number }[] = [];
	/** Messages the agent sent on its own (entry id → text and where from); shown as its, not the person's. */
	private readonly outbound = new Map<string, { text: string; from: string; suggestions?: string[] }>();
	/** This conversation's approvals, result cards (by tool call) and undo records. */
	private readonly approvals = new Map<string, Approval>();
	private readonly cards = new Map<string, { card: ResultCard; undo?: string }>();
	private readonly undos = new Map<string, UndoRecord>();
	/** What the agent learned after quiet moments (entry id → the changes and their undo), shown as memory cards. */
	private readonly learned = new Map<string, { changes: { action: string; text: string }[]; undo?: string; at: string }>();
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
		this.mapper = new DurableViewMapper<TimelineItem>(this.builder, (id) => this.queueTexts.get(id));
	}

	get ref(): ContainerRef {
		return { ...this.agent.ref, conversationId: this.run ? `run:${this.run.id}` : this.peer ? `agent:${this.peer.id}` : `person:${this.contactId}` };
	}

	static async attach(agent: AgentRuntime, who: { contactId: string } | { run: RunRecord } | { peer: { id: string; name: string } }, conversation: Conversation): Promise<AgentView> {
		const view = new AgentView(agent, who, conversation);
		const { transcript, watch } = await agent.watch(conversation);
		view.watch = watch;
		view.load(transcript, watch.value as unknown as DurableView);
		for (const undo of await agent.core.safety.undos()) if (undo.conversationId === view.conversationId) view.undos.set(undo.id, undo);
		for (const approval of await agent.core.safety.approvals(view.conversationId)) view.approval(approval, false);
		if (view.isOwner) for (const run of (await agent.runs()).runs) view.runLine(run, false);
		view.steps.snapshot(view.items());
		agent.live.add(view);
		await view.settings();
		view.builder.flush();
		watch.start(async (call) => {
			if (call.kind !== "value") return;
			const { appended, runEnded } = view.mapper.apply(call.value as unknown as DurableView);
			for (const entry of appended) view.noteEntry(entry as RawEntry, true);
			view.syncUsage(call.value as unknown as DurableView);
			view.emit(view.builder.flush());
			if (runEnded) void view.turnEnded();
		});
		return view;
	}

	/** The transcript, with outbound messages and notices in place. */
	private load(transcript: Entry[], first: DurableView): void {
		const newer = this.mapper.load(transcript, first, false);
		for (const entry of [...transcript, ...newer]) this.noteEntry(entry as RawEntry, false);
		this.syncUsage(first);
	}

	/**
	 * The conversation's total follows pi-durable's usage document: every response, summary and tool result that
	 * reported usage, also failed attempts and what a compaction summarized away. The timeline only sums the entries in
	 * the model's context, so it can't say.
	 */
	private syncUsage(view: DurableView): void {
		const doc = view.docs["pi.usage"] as { models?: Record<string, PiUsage>; tools?: Record<string, PiUsage> } | undefined;
		if (!doc) return;
		const usage = emptyUsage();
		for (const u of [...Object.values(doc.models ?? {}), ...Object.values(doc.tools ?? {})]) {
			const add = toUsage(u);
			if (!add) continue;
			usage.inputTokens += add.inputTokens;
			usage.outputTokens += add.outputTokens;
			usage.cacheReadTokens += add.cacheReadTokens;
			usage.cacheWriteTokens += add.cacheWriteTokens;
			usage.costUsd += add.costUsd;
		}
		if (JSON.stringify(usage) !== JSON.stringify(this.builder.usage)) this.builder.setState({ usage });
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

	/** The owner's conversation: where runs show as dividers. */
	get isOwner(): boolean {
		return !!this.contactId && this.contactId === ownerOf(this.agent.definition());
	}

	private readonly runLines = new Map<string, TimelineItem>();

	/**
	 * A run as a line in the owner's conversation (docs/spec/21 D3, design 2a): "Automatic run · nothing new, didn't
	 * write · $0.0004"; a run that wrote shows its message after it. Placed when it fired; updated when it ends.
	 */
	runLine(run: RunRecord, live: boolean): void {
		// An automation's run says which one (docs/spec/27 §4): "From Daily price check · …".
		const how = run.source === "trial" ? "Trial run" : run.kind === "manual" ? "Run now" : run.kind === "automation" ? `From ${run.label ?? "an automation"}` : "Automatic run";
		const short = (t: string) => t.replace(/\s+/g, " ").trim().slice(0, 120);
		const what =
			run.status === "running"
				? "working…"
				: run.status === "skipped"
					? "skipped: paused or over its budget"
					: run.status === "failed"
						? `failed${run.summary ? `: ${short(run.summary)}` : ""}`
						: run.sent === 0
							? "nothing new, didn't write"
							: run.sent === 1
								? "wrote to you"
								: `wrote to you ${run.sent} times`;
		const cost = run.costUsd ? ` · $${run.costUsd < 0.01 ? run.costUsd.toFixed(4) : run.costUsd.toFixed(2)}` : "";
		const item: TimelineItem = {
			kind: "system",
			id: `run:${run.id}`,
			at: run.firedAt,
			level: run.status === "failed" ? "warn" : "info",
			text: `${how} · ${what}${cost}`,
			run: { id: run.id, status: run.status, sent: run.sent, ...(run.summary ? { summary: run.summary } : {}), ...(run.costUsd !== undefined ? { costUsd: run.costUsd } : {}), ...(run.kind === "automation" ? { automation: { id: run.source, name: run.label ?? "Automation" } } : {}) },
		};
		const had = this.runLines.has(item.id);
		this.runLines.set(item.id, item);
		if (had) {
			if (live) this.emit([{ type: "item.updated", item }]);
			return;
		}
		this.builder.insert(item, this.builder.firstAfter(run.firedAt), live);
		if (live) this.emit(this.builder.flush());
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
		const learnedId = [...this.learned].find(([, l]) => l.undo === undo.id)?.[0];
		if (learnedId) this.emit([{ type: "item.updated", item: this.learnedItem(learnedId) }]);
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
		// A question to the owner stays on its own: the app shows it with answers to tap (docs/spec/21 D4).
		// Files it handed over (06 §14) are cards of their own too.
		for (const item of groupSteps(items, (tool) => tool.tool === "ask_owner" || tool.tool === "present_files")) {
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
			const data = entry.data as { text: string; from: string; suggestions?: string[] };
			this.outbound.set(id, data);
			// The model reads it as a note; it arrives as a user message, or (as a write) only as an entry.
			this.builder.user(id, data.text, entry.model?.[0]?.timestamp);
		} else if (entry.kind === LEARN_ENTRY) {
			const data = entry.data as { changes: { action: string; text: string }[]; undo?: string; at: string };
			this.learned.set(id, data);
			this.builder.insert(this.learnedItem(id), live ? undefined : this.builder.firstAfter(data.at), live);
		} else if (entry.kind === NOTICE_ENTRY) {
			const data = entry.data as { text: string; at: string };
			const item: TimelineItem = { kind: "system", id: `notice:${id}`, at: data.at, level: "info", text: data.text };
			this.builder.insert(item, live ? undefined : this.builder.firstAfter(data.at), live);
		}
	}

	/** A learning step as a memory card: one fact, or "Learned 3 facts" with each on its own line; Undo takes all back. */
	private learnedItem(id: string): ResultItem {
		const l = this.learned.get(id)!;
		const replaced = l.changes.some((c) => c.action !== "added");
		const title = l.changes.length === 1 ? (replaced ? "Updated memory" : "Learned") : `Learned ${l.changes.length} facts`;
		const card: ResultCard = { kind: "memory", title, detail: l.changes.map((c) => c.text).join("\n") };
		return this.resultItem(`learned:${id}`, l.at, { card, ...(l.undo ? { undo: l.undo } : {}) });
	}

	/** The builder's items as the client sees them: outbound notes become the agent's messages. */
	private items(): TimelineItem[] {
		return this.builder.snapshot().items.map((item) => {
			const out = item.kind === "user" ? this.outbound.get(item.id) : undefined;
			if (out) return { kind: "assistant", id: item.id, at: item.at, parts: [{ type: "text", text: out.text }], status: "done", outbound: { from: out.from, ...(out.suggestions ? { suggestions: out.suggestions } : {}) } };
			const msg = item.kind === "user" ? this.agentMsgs.get(item.id) : undefined;
			if (msg) return { kind: "agent_msg", id: item.id, at: item.at, fromAgent: msg.from, toAgent: msg.to, text: msg.text, direction: "in", mode: msg.late ? "reply" : msg.mode, traceId: msg.traceId };
			if (item.kind === "tool" && (item.tool === "ask_agent" || item.tool === "tell_agent")) return this.agentCall(item);
			if (item.kind === "result" && item.callId.startsWith("learned:")) return this.learnedItem(item.callId.slice("learned:".length));
			const approval = item.kind === "approval" ? this.approvals.get(item.approvalId) : undefined;
			if (item.kind === "system" && this.runLines.has(item.id)) return this.runLines.get(item.id)!;
			return approval ? this.approvalItem(approval) : item;
		});
	}

	private emit(events: SessionEvent[]): void {
		const shown = events.map((e) => (e.type === "resnapshot" ? { ...e, snapshot: { ...e.snapshot, items: this.items() } } : e));
		const out = this.steps.events(shown);
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
		// Only the last version of each: one a later call replaced isn't sent (docs/spec/25 §3.4).
		const replaced = replacedVisuals(items);
		const visuals = items.flatMap((i) => {
			if (i.kind !== "tool" || i.tool !== "show_visual" || i.status === "error" || replaced.has(i.id)) return [];
			const a = (i.args ?? {}) as { title?: unknown; html?: unknown };
			return typeof a.html === "string" && a.html.trim() ? [{ title: typeof a.title === "string" && a.title.trim() ? a.title.trim() : "Visual", html: a.html }] : [];
		});
		this.agent.answered(this.contactId, turn.said, text, visuals);
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
		// A Telegram bot token pasted by the owner never reaches the model or the transcript (docs/spec/19 S4).
		const token = BOT_TOKEN.exec(text)?.[1];
		if (token && this.contactId === ownerOf(this.agent.definition())) {
			const said = await this.agent.connectTelegram(token);
			if (said) {
				await this.agent.notice(said);
				this.agent.activity();
				return { disposition: "started" as const };
			}
		}
		// /pause, /resume, and messages while paused or out of budget (06 §9 AS3–AS4) don't start a turn.
		if (await this.agent.core.intercept(this.contactId, text)) {
			this.agent.activity();
			return { disposition: "started" as const };
		}
		const busy = this.builder.status === "running";
		await this.agent.ensureCredential();
		await this.agent.core.beforeTurn(this.contactId, this.conversation.id, text).catch(() => undefined);
		const input = buildInput(text, options.attachments);
		// What the owner sent is kept in its files (06 §14): the model reads where, just before the words.
		const kept = this.agent.keepFiles(options.attachments ?? [], this.contactId);
		if (kept && Array.isArray(input.content)) input.content.splice(input.content.length - 1, 0, { type: "text", text: kept });
		try {
			const submission = await this.conversation.submit(
				{ type: "input", content: input.content, ...(input.entry ? { entry: input.entry } : {}), whenBusy: options.whenBusy, ...(options.requestId ? { requestId: options.requestId } : {}) } as SubmissionDraft,
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

	async stop(): Promise<void> {
		this.agent.live.delete(this);
		await this.watch?.stop();
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
		for (const g of hub.capabilities(c.id)) {
			if (g.permission === "ask") for (const t of g.tools) asked.add(t);
			// Sending and deleting (mail_send, calendar_delete_event, an MCP app's delete tools) ask whenever they're on.
			if ((g.access === "send" || g.access === "destructive") && g.permission !== "off") for (const t of g.tools) asked.add(t);
		}
	}
	const rules = [...new Set([...(def.policies?.requireApproval ?? []), ...asked])];
	return { ...def, policies: { ...def.policies, requireApproval: rules } };
}

/** An agent definition's `models.utility`: "auto", "on-device", "off", or a model id ("provider:model"). */
export function agentUtility(value: string | undefined): { choice?: UtilityChoice } {
	if (!value || value === "auto") return {};
	if (value === "on-device") return { choice: "on_device" };
	if (value === "off") return { choice: "off" };
	const { provider, modelId } = modelOf(value);
	return { choice: { provider, id: modelId } };
}
