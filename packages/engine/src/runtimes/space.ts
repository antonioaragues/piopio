/**
 * Space runtime (docs/spec/04-chat §3): one pi-durable session per Space. Main, the root conversation, is the
 * organizer: for each message it answers, routes it to a topic, or creates a topic. Topics are ownerless
 * conversations. Main shows a routing card for each routed message; the reply itself lives in the topic.
 *
 * `@Topic …`, `/new <title>` and `/main …` let you decide instead of the organizer (S3). Wrong topic moves a
 * routed message and leaves a hint the organizer reads from then on (S2).
 */
import { randomUUID } from "node:crypto";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { configure, ConversationBusy, createRegistry, defineExtension, Harness, watchEvents, type AgentEventStream, type Conversation, type ConversationId, type Extension, type Tx } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import type { ContainerRef, MemoryItem, ModelRef, RoutingItem, SessionEvent, Snapshot, TimelineItem } from "@piopio/protocol";
import { buildInput, commandInput, USER_ENTRY, type BuiltInput } from "../input.js";
import { EngineError, type ModelHub } from "../models.js";
import { contentText, TimelineBuilder, type PiContentBlock } from "../timeline/builder.js";
import { DurableEventMapper } from "../timeline/pi-durable.js";
import { createWebExtension, type WebOptions } from "../tools/web.js";
import { Emitter, type Runtime, type SubmitOptions } from "./runtime.js";
import { SpaceFiles } from "./space-files.js";
import { attachChatMcp, MCP_EXTENSION, type ChatMcp } from "../tools/mcp-chat.js";
import { createToolSearchExtension } from "@earendil-works/pi-durable/tool-search";
import { exportConversation, importInto, type Portable } from "./transfer.js";
import { applyPatch, describe, diffFacts, lineCount, MemoryDoc, pushRevision, type MemoryAuthor, type MemoryState, type Proposal, type Revision } from "./space-memory.js";
import { MEMORY_TOOLS, organizerExtension, ROUTE_TOOLS, sharedExtension, SpaceDoc, topicExtension, type Hint, type Route, type SpaceHost, type SpaceState, type TopicRecord } from "./space-tools.js";

const ctx = BACKGROUND_CONTEXT;

/** A message the organizer (or you, with @topic) sent to a topic. */
const ROUTED_ENTRY = "piopio.routed";
/** In Main: a message you sent to a topic yourself (@topic, /new). */
const ROUTE_ENTRY = "piopio.route";
const MAX_HINTS = 20;

export type TopicSummary = { id: string; title: string; brief: string; summary?: string; lastActiveAt: string; lastReplyAt?: string; running: boolean; archived: boolean };
export type SpaceStats = { costUsd: number; files: number; memoryLines: number };
export type SpaceSettings = { memory: boolean; autoTidy: boolean };

export type SpaceOpenOptions = {
	ref: ContainerRef;
	file: string;
	hub: ModelHub;
	/** Topics' model (new topics), and the organizer's when it has none of its own. */
	model: ModelRef;
	organizerModel?: ModelRef;
	filesDir: string;
	/** The Space's name and instructions, read each request. */
	info: () => { name: string; instructions?: string };
	settings: () => SpaceSettings;
	webOptions?: WebOptions;
	/** More extensions for every conversation (About me). */
	extensions?: Extension[];
	/** MCP servers, when Chat may use them. */
	mcp?: ChatMcp;
	/** Expands a `/command` (prompt templates, skills), or undefined. */
	expand?: (text: string) => string | undefined;
	/** The topics or the header's numbers changed (sidebar, header). */
	onTopics?: (topics: TopicSummary[], stats: SpaceStats) => void;
};

type Live = { status: RoutingItem["status"]; preview?: string; replyItemId?: string };

export class SpaceRuntime implements Runtime, SpaceHost {
	private readonly views = new Map<string, Promise<SpaceView>>();
	private main!: SpaceView;
	private state: SpaceState = { topics: [], hints: [], reroutes: {} };
	private memory: MemoryState = { text: "", revisions: [], proposals: {} };
	readonly files: SpaceFiles;
	private readonly summarizing = new Set<string>();
	/** Live status of routed messages, by submission id. */
	private readonly live = new Map<string, Live>();
	private readonly tracked = new Set<string>();
	private docWatch?: { stop(): Promise<unknown> };
	private closed = false;

	private constructor(
		private readonly options: SpaceOpenOptions,
		private readonly harness: Harness,
		private readonly organizer: Extension,
		/** What topics run with: the web, shared, extra and MCP extensions, then the topic's own. */
		private readonly topicExtensions: Extension[],
		private model: ModelRef,
	) {
		this.files = new SpaceFiles(options.filesDir);
	}

	get ref(): ContainerRef {
		return this.options.ref;
	}

	static async open(options: SpaceOpenOptions): Promise<SpaceRuntime> {
		const storage = await openNodeSqliteStorage(options.file);
		const registry = createRegistry();
		// The extensions read the runtime through `host`, which is set once it exists.
		let host!: SpaceRuntime;
		const web = createWebExtension(options.hub, options.webOptions) as unknown as Extension;
		const organizer = organizerExtension(() => host) as unknown as Extension;
		const topic = topicExtension(() => host) as unknown as Extension;
		const shared = sharedExtension(() => host) as unknown as Extension;
		const extra = options.extensions ?? [];
		for (const e of [web, organizer, topic, shared, ...extra]) registry.install(e as never);
		const detachMcp = options.mcp ? await attachChatMcp(registry as never, options.mcp) : undefined;
		// Selected by name: MCP and tool_search count once they are installed (Chat MCP on, servers connected).
		const mcpByName = [defineExtension({ name: MCP_EXTENSION }), options.mcp?.toolSearch ?? createToolSearchExtension()] as unknown as Extension[];
		const mainExtensions = [organizer, shared, ...extra, ...mcpByName, web];
		const topicExtensions = [web, shared, ...extra, ...mcpByName, topic];
		const harness = await Harness.open(storage, { models: options.hub.models, registry, settings: { extensions: topicExtensions } } as never, ctx);
		host = new SpaceRuntime(options, harness, organizer, topicExtensions, options.model);
		host.detachMcp = detachMcp;
		const root = await harness.root(ctx, { agent: { model: modelOf(options.organizerModel ?? options.model), extensions: mainExtensions } } as never);
		host.state = clone((await harness.snapshot(SpaceDoc, ctx)) ?? undefined);
		// Spaces made before a tool set changed get the current one (a no-op when nothing changed).
		await harness.commit(async (tx) => {
			await configure(tx, root.id, { extensions: mainExtensions } as never);
			for (const t of host.state.topics) await configure(tx, Number(t.id) as never, { extensions: topicExtensions } as never);
		}, ctx);
		host.main = await SpaceView.attach(host, root, true);
		host.views.set("main", Promise.resolve(host.main));
		await host.watchState();
		await options.hub.ensureCredential(options.model.provider).catch(() => undefined);
		harness.resume();
		// Routed messages that were still being answered when the Space closed.
		for (const route of host.main.routes()) host.track(route);
		return host;
	}

	// ── Views ────────────────────────────────────────────────────────────────

	/** Main (no id) or a topic's view. */
	async view(conversationId?: string): Promise<SpaceView> {
		if (!conversationId || conversationId === "main") return this.main;
		let pending = this.views.get(conversationId);
		if (!pending) {
			pending = (async () => {
				const conversation = await this.harness.conversation(Number(conversationId) as never, ctx);
				if (!conversation) throw new EngineError("NOT_FOUND", `No topic ${conversationId}`);
				const view = await SpaceView.attach(this, conversation, false);
				view.onEvents(() => this.publishTopics());
				return view;
			})();
			this.views.set(conversationId, pending);
			pending.catch(() => this.views.delete(conversationId));
		}
		return pending;
	}

	get settings(): SpaceSettings {
		return this.options.settings();
	}

	get memoryText(): string {
		return this.memory.text;
	}

	topic(idOrTitle: string): TopicRecord | undefined {
		const active = this.state.topics.filter((t) => t.status === "active");
		return active.find((t) => t.id === idOrTitle) ?? active.find((t) => t.title.toLowerCase() === idOrTitle.trim().replace(/^“|”$/g, "").toLowerCase());
	}

	get topics(): readonly TopicRecord[] {
		return this.state.topics.filter((t) => t.status === "active");
	}

	get hints(): readonly Hint[] {
		return this.state.hints;
	}

	get info() {
		return this.options.info();
	}

	private async watchState(): Promise<void> {
		// The watches need the documents to exist.
		await this.harness.commit(async (tx) => {
			await tx.doc(SpaceDoc);
			await tx.doc(MemoryDoc);
		}, ctx);
		this.memory = structuredClone((await this.harness.snapshot(MemoryDoc, ctx)) as MemoryState);
		const watch = await this.harness.watchDoc(SpaceDoc, ctx);
		if (watch) {
			this.docWatch = watch;
			watch.start(async (value) => {
				this.state = clone(value ?? undefined);
				this.refreshCards();
				this.publishTopics();
			});
		}
		const memory = await this.harness.watchDoc(MemoryDoc, ctx);
		if (memory) {
			this.memoryWatch = memory;
			memory.start(async (value) => {
				if (value) this.memory = structuredClone(value) as MemoryState;
				this.refreshCards();
				this.publishTopics();
			});
		}
	}

	private memoryWatch?: { stop(): Promise<unknown> };
	private detachMcp?: () => void;

	/** Routing and memory cards changed status: every open view re-sends its cards. */
	private refreshCards(): void {
		this.main.refreshCards();
		for (const view of this.openViews.values()) view.refreshCards();
	}

	private publishTopics(): void {
		if (this.closed) return;
		void this.publish();
	}

	private async publish(): Promise<void> {
		const running = new Set<string>();
		for (const route of this.main.routes()) {
			const live = route.submissionId ? this.live.get(route.submissionId) : undefined;
			if (live && (live.status === "thinking" || live.status === "replying")) running.add(route.topicId);
		}
		for (const [id, view] of this.openViews) if (view.snapshot().state.status === "running") running.add(id);
		const topics = [...this.state.topics]
			.sort((a, b) => b.lastActiveAt.localeCompare(a.lastActiveAt))
			.map((t) => ({ id: t.id, title: t.title, brief: t.brief, ...(t.summary ? { summary: t.summary } : {}), lastActiveAt: t.lastActiveAt, ...(t.lastReplyAt ? { lastReplyAt: t.lastReplyAt } : {}), running: running.has(t.id), archived: t.status === "archived" }));
		const usage = (await this.harness.usage(ctx).catch(() => undefined)) as { models?: Record<string, { cost?: { total?: number } }>; tools?: Record<string, { cost?: { total?: number } }> } | undefined;
		const costUsd = [...Object.values(usage?.models ?? {}), ...Object.values(usage?.tools ?? {})].reduce((sum, u) => sum + (u.cost?.total ?? 0), 0);
		if (this.closed) return;
		this.options.onTopics?.(topics, { costUsd, files: this.files.list().length, memoryLines: lineCount(this.memory.text) });
	}

	private openViews = new Map<string, SpaceView>();

	/** Called by topic views as they attach. */
	registerView(id: string, view: SpaceView): void {
		this.openViews.set(id, view);
	}

	// ── Topics and routing ───────────────────────────────────────────────────

	/** Creates a topic conversation in `tx` (an organizer tool's commit, or the host's). */
	async createTopic(tx: Tx, title: string, brief: string): Promise<TopicRecord> {
		const clean = title.trim().replace(/\s+/g, " ").slice(0, 80) || "Untitled topic";
		const doc = await tx.doc(SpaceDoc);
		const existing = doc.topics.find((t) => t.status === "active" && t.title.toLowerCase() === clean.toLowerCase());
		if (existing) return { ...existing };
		const record = await tx.createConversation({ ownership: { kind: "ownerless" } });
		await configure(tx, record.id, { model: modelOf(this.model), extensions: this.topicExtensions } as never);
		const now = new Date().toISOString();
		const topic: TopicRecord = { id: String(record.id), title: clean, brief: brief.trim(), status: "active", createdAt: now, lastActiveAt: now };
		doc.topics.push(topic);
		return topic;
	}

	async newTopic(title: string, brief: string): Promise<TopicRecord> {
		const topic = await this.harness.commit((tx) => this.createTopic(tx, title, brief), ctx);
		await this.refreshState();
		return topic;
	}

	/** Reads the Space doc now (the watch delivers it a moment later). */
	private async refreshState(): Promise<void> {
		this.state = clone((await this.harness.snapshot(SpaceDoc, ctx)) ?? undefined);
	}

	watch(conversationId: ConversationId): Promise<AgentEventStream> {
		return watchEvents(this.harness, conversationId, ctx);
	}

	/** Bumps a topic's recency (and its reply time, for the unread dot). */
	async touchTopic(topicId: string, replied = false): Promise<void> {
		if (this.closed) return;
		await this.harness.commit(async (tx) => {
			const topic = (await tx.doc(SpaceDoc)).topics.find((t) => t.id === topicId);
			if (!topic) return;
			const now = new Date().toISOString();
			topic.lastActiveAt = now;
			if (replied) topic.lastReplyAt = now;
		}, ctx);
	}

	/** Sends `text` to a topic as a routed message. */
	async sendToTopic(topicId: string, text: string, requestId: string, conversation?: (id: ConversationId) => Promise<{ submit: Conversation["submit"] } | undefined>): Promise<string> {
		const find = conversation ?? ((id: ConversationId) => this.harness.conversation(id, ctx));
		const topic = await find(Number(topicId) as never);
		if (!topic) throw new EngineError("NOT_FOUND", `No topic ${topicId}`);
		const submission = await topic.submit({ type: "input", content: text, entry: { kind: ROUTED_ENTRY, data: { text } }, whenBusy: "followUp", requestId } as never, ctx);
		return String(submission.id);
	}

	/** Follows a routed message until its topic answers, for the card's status and preview. */
	track(route: Route): void {
		const id = route.submissionId;
		if (!id || this.tracked.has(id)) return;
		this.tracked.add(id);
		if (!this.live.has(id)) this.live.set(id, { status: "thinking" });
		void this.view(route.topicId)
			.then((view) => {
				const off = view.onEvents((events) => {
					const live = this.live.get(id);
					if (live?.status !== "thinking") return;
					const writing = events.some((e) => (e.type === "item.added" || e.type === "item.updated") && e.item.kind === "assistant" && e.item.status === "streaming" && e.item.parts.some((p) => p.type === "text" && p.text));
					if (writing) this.setLive(id, { status: "replying" });
				});
				return this.settle(id, route.topicId).finally(off);
			})
			.catch(() => this.setLive(id, { status: "failed" }));
	}

	private async settle(submissionId: string, topicId: string): Promise<void> {
		const submission = await this.harness.submission(Number(submissionId) as never, ctx);
		if (!submission) return this.setLive(submissionId, { status: "failed" });
		const settled = (await submission.wait(ctx)) as { status: string; answer?: unknown };
		if (this.closed) return;
		if (settled.status !== "done" || settled.answer === undefined) return this.setLive(submissionId, { status: "failed" });
		const answer = await this.harness.commit((tx) => tx.entry(settled.answer as never), ctx);
		const message = answer?.model?.[0] as { content?: PiContentBlock[] } | undefined;
		const text = contentText(message?.content?.filter((b) => b.type === "text")).trim();
		const preview = text.split("\n").find((l) => l.trim())?.trim().slice(0, 160);
		this.setLive(submissionId, { status: "replied", ...(preview ? { preview } : {}), replyItemId: String(settled.answer) });
		await this.touchTopic(topicId, true);
		void this.summarize(topicId);
	}

	/** A topic answered (routed or direct): its one-line summary for the organizer and the sidebar. */
	async summarize(topicId: string): Promise<void> {
		if (this.summarizing.has(topicId) || this.closed) return;
		this.summarizing.add(topicId);
		try {
			const lines = await this.conversationText(topicId, 12_000);
			if (!lines.length) return;
			const lastReply = [...lines].reverse().find((l) => l.role === "assistant")?.text ?? "";
			const transcript = lines.map((l) => `${l.role === "user" ? "User" : "Assistant"}: ${l.text}`).join("\n\n");
			const summary =
				(await this.options.hub
					.utility("You summarize a conversation in one line for a sidebar: where it stands now, in at most 100 characters. No quotes, no preamble.", transcript)
					.catch(() => undefined)) ?? (lastReply.split("\n").find((l) => l.trim())?.trim() ?? "");
			const line = summary.replace(/\s+/g, " ").trim().slice(0, 140);
			if (!line || this.closed) return;
			await this.harness.commit(async (tx) => {
				const topic = (await tx.doc(SpaceDoc)).topics.find((t) => t.id === topicId);
				if (topic) topic.summary = line;
			}, ctx);
		} finally {
			this.summarizing.delete(topicId);
		}
	}

	/** User and assistant messages of a conversation, oldest first, the newest `maxChars`. */
	private async conversationText(conversationId: string, maxChars: number): Promise<{ role: "user" | "assistant"; text: string }[]> {
		const out: { role: "user" | "assistant"; text: string }[] = [];
		let total = 0;
		await this.harness.commit(async (tx) => {
			const page = await tx.scanEntries({ conversationId: Number(conversationId) as never, order: "descending" }, 400);
			for (const entry of page.items) {
				const line = entryText(entry as never);
				if (!line) continue;
				total += line.text.length;
				if (total > maxChars && out.length) break;
				out.unshift(line);
			}
		}, ctx);
		return out;
	}

	// ── Memory (S8) ──────────────────────────────────────────────────────────

	async updateMemory(by: MemoryAuthor, add: string[], remove: string[], section?: string): Promise<Revision> {
		const revision = await this.harness.commit(async (tx) => {
			const doc = await tx.doc(MemoryDoc);
			const before = doc.text;
			const patched = applyPatch(before, add, remove, section);
			const revision: Revision = { id: randomUUID(), at: new Date().toISOString(), by, summary: describe(patched.added, patched.removed), added: patched.added, removed: patched.removed, before, after: patched.text };
			if (!patched.added.length && !patched.removed.length) return revision;
			doc.text = patched.text;
			pushRevision(doc, revision);
			return revision;
		}, ctx);
		await this.refreshMemory();
		return revision;
	}

	/** Your edit in the memory editor. */
	async setMemory(text: string): Promise<void> {
		await this.harness.commit(async (tx) => {
			const doc = await tx.doc(MemoryDoc);
			const after = text.trim();
			if (after === doc.text) return;
			const { added, removed } = diffFacts(doc.text, after);
			pushRevision(doc, { id: randomUUID(), at: new Date().toISOString(), by: { kind: "user" }, summary: added.length || removed.length ? describe(added, removed) : "Edited the text", added, removed, before: doc.text, after });
			doc.text = after;
		}, ctx);
		await this.refreshMemory();
	}

	/** Undo on a memory card: takes that change back, keeping later ones. */
	async undoMemory(revisionId: string): Promise<void> {
		await this.harness.commit(async (tx) => {
			const doc = await tx.doc(MemoryDoc);
			const revision = doc.revisions.find((r) => r.id === revisionId);
			if (!revision) throw new EngineError("NOT_FOUND", "That memory change is no longer in the history.");
			if (revision.undone) return;
			const patched = applyPatch(doc.text, revision.removed, revision.added);
			revision.undone = true;
			pushRevision(doc, { id: randomUUID(), at: new Date().toISOString(), by: { kind: "user" }, summary: `Undid: ${revision.summary}`, added: patched.added, removed: patched.removed, before: doc.text, after: patched.text });
			doc.text = patched.text;
		}, ctx);
		await this.refreshMemory();
	}

	/** Puts the memory back as it was after a change (the editor's history). */
	async restoreMemory(revisionId: string): Promise<void> {
		const revision = this.memory.revisions.find((r) => r.id === revisionId);
		if (!revision) throw new EngineError("NOT_FOUND", "That version is no longer in the history.");
		await this.setMemory(revision.after);
	}

	async proposeMemory(topicId: string, add: string[], remove: string[], reason: string): Promise<Proposal> {
		const topic = this.topic(topicId);
		const proposal: Proposal = { id: randomUUID(), at: new Date().toISOString(), topicId, title: topic?.title ?? "a topic", added: add.map((a) => a.trim()).filter(Boolean), removed: remove.map((r) => r.trim()).filter(Boolean), reason, status: "pending" };
		await this.harness.commit(async (tx) => {
			(await tx.doc(MemoryDoc)).proposals[proposal.id] = proposal;
		}, ctx);
		await this.refreshMemory();
		return proposal;
	}

	/** Save or Dismiss on a topic's proposal. */
	async decideProposal(proposalId: string, accept: boolean): Promise<void> {
		const proposal = this.memory.proposals[proposalId];
		if (!proposal) throw new EngineError("NOT_FOUND", "No such proposal.");
		if (proposal.status !== "pending") return;
		const revision = accept ? await this.updateMemory({ kind: "topic", topicId: proposal.topicId, title: proposal.title }, proposal.added, proposal.removed) : undefined;
		await this.harness.commit(async (tx) => {
			const p = (await tx.doc(MemoryDoc)).proposals[proposalId];
			if (!p) return;
			p.status = accept ? "saved" : "dismissed";
			if (revision) p.revisionId = revision.id;
		}, ctx);
		await this.refreshMemory();
	}

	memoryInfo(): { text: string; revisions: Omit<Revision, "before" | "after">[]; proposals: Omit<Proposal, "status" | "revisionId">[] } {
		return {
			text: this.memory.text,
			revisions: [...this.memory.revisions].reverse().map(({ before: _b, after: _a, ...r }) => r),
			proposals: Object.values(this.memory.proposals)
				.filter((p) => p.status === "pending")
				.map(({ status: _s, revisionId: _r, ...p }) => p),
		};
	}

	revision(id: string): Revision | undefined {
		return this.memory.revisions.find((r) => r.id === id);
	}

	proposal(id: string): Proposal | undefined {
		return this.memory.proposals[id];
	}

	private async refreshMemory(): Promise<void> {
		this.memory = structuredClone((await this.harness.snapshot(MemoryDoc, ctx)) as MemoryState);
		this.refreshCards();
		this.publishTopics();
	}

	// ── Housekeeping (S9) ────────────────────────────────────────────────────

	async renameTopic(topicId: string, title: string): Promise<void> {
		const clean = title.trim().replace(/\s+/g, " ").slice(0, 80);
		if (!clean) throw new EngineError("INVALID", "The topic needs a title.");
		if (this.topics.some((t) => t.id !== topicId && t.title.toLowerCase() === clean.toLowerCase())) throw new EngineError("CONFLICT", `There is already a topic “${clean}”.`);
		await this.editTopic(topicId, (t) => void (t.title = clean));
	}

	async archiveTopic(topicId: string, archived: boolean): Promise<void> {
		await this.editTopic(topicId, (t) => {
			t.status = archived ? "archived" : "active";
			if (!archived) delete t.mergedInto;
		});
	}

	/** Summarizes `from` into `into`'s brief and archives `from`. Returns the summary. */
	async mergeTopics(fromId: string, intoId: string): Promise<string> {
		if (fromId === intoId) throw new EngineError("INVALID", "A topic can't be merged into itself.");
		const from = this.state.topics.find((t) => t.id === fromId), into = this.topic(intoId);
		if (!from || !into) throw new EngineError("NOT_FOUND", "No such topic.");
		const lines = await this.conversationText(fromId, 16_000);
		const transcript = lines.map((l) => `${l.role === "user" ? "User" : "Assistant"}: ${l.text}`).join("\n\n");
		const summary =
			(transcript
				? await this.options.hub
						.utility("Summarize this conversation so another conversation can continue the subject: the decisions, facts and open questions, in at most 6 short bullet points. No preamble.", transcript)
						.catch(() => undefined)
				: undefined) ??
			[from.brief, from.summary].filter(Boolean).join(" ") ??
			"";
		await this.harness.commit(async (tx) => {
			const doc = await tx.doc(SpaceDoc);
			const a = doc.topics.find((t) => t.id === intoId), b = doc.topics.find((t) => t.id === fromId);
			if (!a || !b) return;
			a.brief = `${a.brief}${a.brief ? "\n\n" : ""}Merged from “${b.title}”:\n${summary || "(no history)"}`.slice(0, 4000);
			a.lastActiveAt = new Date().toISOString();
			b.status = "archived";
			b.mergedInto = intoId;
		}, ctx);
		await this.refreshState();
		this.publishTopics();
		return summary || "(no history)";
	}

	private async editTopic(topicId: string, change: (t: TopicRecord) => void): Promise<void> {
		if (!this.state.topics.some((t) => t.id === topicId)) throw new EngineError("NOT_FOUND", `No topic ${topicId}`);
		await this.harness.commit(async (tx) => {
			const topic = (await tx.doc(SpaceDoc)).topics.find((t) => t.id === topicId);
			if (topic) change(topic);
		}, ctx);
		await this.refreshState();
		this.publishTopics();
	}

	/** search_space: lines of Main, every topic and the memory that contain `query`. */
	async search(query: string, limit = 30): Promise<string[]> {
		const q = query.trim().toLowerCase();
		if (!q) return [];
		const hits: string[] = [];
		const add = (where: string, text: string) => {
			for (const line of text.split("\n")) {
				if (hits.length >= limit) return;
				if (line.toLowerCase().includes(q)) hits.push(`${where}: ${line.trim().slice(0, 200)}`);
			}
		};
		add("Memory", this.memory.text);
		const conversations: [string, string][] = [["Main", String(this.main.conversationId)], ...this.state.topics.map((t): [string, string] => [`“${t.title}”${t.status === "archived" ? " (archived)" : ""}`, t.id])];
		for (const [where, id] of conversations) {
			for (const line of await this.conversationText(id, 200_000)) add(`${where} · ${line.role === "user" ? "you" : "assistant"}`, line.text);
			if (hits.length >= limit) break;
		}
		return hits;
	}

	// ── Moving conversations (S5, S9, S11) ───────────────────────────────────

	/** Copies a thread's messages into a new topic named after it, or into `topicId`. Returns the topic's id. */
	async importTopic(target: { topicId: string } | { title: string; brief: string }, entries: readonly Portable[], from: { title: string }): Promise<string> {
		const topicId = await this.harness.commit(async (tx) => {
			const topic = "topicId" in target ? this.state.topics.find((t) => t.id === target.topicId) : await this.createTopic(tx, target.title, target.brief);
			if (!topic) throw new EngineError("NOT_FOUND", "No such topic.");
			await importInto(tx, Number(topic.id) as never, entries, from);
			const doc = (await tx.doc(SpaceDoc)).topics.find((t) => t.id === topic.id);
			if (doc) doc.lastActiveAt = new Date().toISOString();
			return topic.id;
		}, ctx);
		await this.refreshState();
		await this.openViews.get(topicId)?.reload();
		this.publishTopics();
		void this.summarize(topicId);
		return topicId;
	}

	/** A topic's messages, to promote it to a thread. */
	async exportTopic(topicId: string): Promise<{ title: string; entries: Portable[] }> {
		const topic = this.state.topics.find((t) => t.id === topicId);
		const conversation = topic && (await this.harness.conversation(Number(topicId) as never, ctx));
		if (!topic || !conversation) throw new EngineError("NOT_FOUND", `No topic ${topicId}`);
		return { title: topic.title, entries: await exportConversation(conversation) };
	}

	/** Files were added or removed (the header's count). */
	filesChanged(): void {
		this.publishTopics();
	}

	// ── Settings (§3.6) ──────────────────────────────────────────────────────

	/** The organizer's model (Main). */
	async setOrganizerModel(model: ModelRef): Promise<void> {
		await this.main.configure({ model });
	}

	/** The topics' model: new topics, and every existing one. */
	async setTopicModel(model: ModelRef): Promise<void> {
		this.model = model;
		await this.harness.commit(async (tx) => {
			for (const t of this.state.topics) await configure(tx, Number(t.id) as never, { model: modelOf(model) } as never);
		}, ctx);
		for (const view of this.openViews.values()) await view.reloadSettings();
	}

	private setLive(submissionId: string, live: Live): void {
		this.live.set(submissionId, live);
		this.main.refreshCards();
		this.publishTopics();
	}

	liveStatus(submissionId: string | undefined): Live {
		return (submissionId && this.live.get(submissionId)) || { status: "thinking" };
	}

	expand(text: string): string | undefined {
		return this.options.expand?.(text);
	}

	reroute(itemId: string): Route | undefined {
		return this.state.reroutes[itemId];
	}

	/** You sent a message to a topic yourself: `@Topic …` or `/new Title`. */
	async forceRoute(text: string, topic: TopicRecord, decision: "route" | "create", message: string): Promise<void> {
		const submissionId = message ? await this.sendToTopic(topic.id, message, `force:${Date.now()}:${topic.id}`) : undefined;
		const route: Route = {
			decision,
			topicId: topic.id,
			topicTitle: topic.title,
			reason: decision === "create" ? "You started this topic" : "You chose this topic",
			message,
			forced: true,
			at: new Date().toISOString(),
			...(submissionId ? { submissionId } : {}),
		};
		await this.main.write(ROUTE_ENTRY, { text, ...route });
		this.track(route);
		await this.touchTopic(topic.id);
	}

	/** Wrong topic (S2): sends the message to another (or a new) topic and records the correction. */
	async moveRoute(itemId: string, target: { topicId?: string; newTopic?: string }): Promise<void> {
		const route = this.main.routeFor(itemId);
		if (!route) throw new EngineError("NOT_FOUND", "That message wasn't routed.");
		if (!route.message) throw new EngineError("INVALID", "There is no message to move.");
		let topic = target.topicId ? this.topic(target.topicId) : undefined;
		if (target.newTopic) topic = await this.newTopic(target.newTopic, `Started from: ${route.message.slice(0, 200)}`);
		if (!topic) throw new EngineError("NOT_FOUND", "No such topic.");
		if (topic.id === route.topicId) return;
		const submissionId = await this.sendToTopic(topic.id, route.message, `reroute:${itemId}:${topic.id}`);
		const moved: Route = { ...route, decision: target.newTopic ? "create" : "route", topicId: topic.id, topicTitle: topic.title, reason: `You moved this from ${route.topicTitle}`, submissionId, movedFrom: route.movedFrom ?? route.topicTitle };
		await this.harness.commit(async (tx) => {
			const doc = await tx.doc(SpaceDoc);
			doc.reroutes[itemId] = moved;
			doc.hints.push({ message: route.message.slice(0, 200), wrong: route.topicTitle, right: topic!.title, at: new Date().toISOString() });
			if (doc.hints.length > MAX_HINTS) doc.hints.splice(0, doc.hints.length - MAX_HINTS);
		}, ctx);
		await this.refreshState();
		this.track(moved);
		await this.touchTopic(topic.id);
	}

	// ── Runtime (Main) ───────────────────────────────────────────────────────

	snapshot(): Snapshot {
		return this.main.snapshot();
	}

	onEvents(listener: (events: SessionEvent[]) => void): () => void {
		return this.main.onEvents(listener);
	}

	submit(text: string, options: SubmitOptions) {
		return this.main.submit(text, options);
	}

	abort(): Promise<void> {
		return this.main.abort();
	}

	async configure(change: { model?: ModelRef; thinking?: string }): Promise<void> {
		await this.main.configure(change);
	}

	removeQueued(queueId: string): Promise<void> {
		return this.main.removeQueued(queueId);
	}

	clearQueue(): Promise<void> {
		return this.main.clearQueue();
	}

	submissionHandle(id: string) {
		return this.harness.submission(Number(id) as never, ctx);
	}

	ensureCredential(): Promise<void> {
		return this.options.hub.ensureCredential(this.model.provider);
	}

	async close(): Promise<void> {
		this.closed = true;
		this.detachMcp?.();
		await this.docWatch?.stop();
		await this.memoryWatch?.stop();
		for (const view of await Promise.allSettled(this.views.values())) if (view.status === "fulfilled") await view.value.stop();
		await this.harness.close(ctx);
	}
}

/** One conversation of a Space (Main or a topic), as a session the client subscribes to. */
export class SpaceView implements Runtime {
	private readonly emitter = new Emitter();
	private readonly builder: TimelineBuilder;
	private readonly mapper: DurableEventMapper;
	private stream?: AgentEventStream;
	private readonly queueTexts = new Map<string, string>();
	/** Entry kinds by id (topics badge direct messages). */
	private readonly kinds = new Map<string, string>();
	/** Main: the organizer's routes by tool call id, and your own by route entry id. */
	private readonly toolRoutes = new Map<string, Route>();
	private readonly entryRoutes = new Map<string, Route>();
	/** Memory tool results by call id: the revision (update_memory) or proposal (propose_memory). */
	private readonly memoryCalls = new Map<string, { revisionId?: string; proposalId?: string }>();

	private constructor(
		private readonly space: SpaceRuntime,
		private readonly conversation: Conversation,
		readonly isMain: boolean,
	) {
		this.builder = new TimelineBuilder(this.ref);
		this.mapper = new DurableEventMapper(this.builder, (id) => this.queueTexts.get(id));
	}

	get ref(): ContainerRef {
		return this.isMain ? this.space.ref : { ...this.space.ref, conversationId: String(this.conversation.id) };
	}

	get conversationId(): ConversationId {
		return this.conversation.id;
	}

	static async attach(space: SpaceRuntime, conversation: Conversation, isMain: boolean): Promise<SpaceView> {
		const view = new SpaceView(space, conversation, isMain);
		if (!isMain) space.registerView(String(conversation.id), view);
		await view.start(false);
		await view.settings();
		view.builder.flush();
		return view;
	}

	/** Watches the conversation; `emit` sends the fresh state as a resnapshot (after a reload). */
	private async start(emit: boolean): Promise<void> {
		const { space, conversation, isMain } = this;
		const stream = await space.watch(conversation.id);
		this.stream = stream;
		this.load(stream.snapshot as unknown as { entries?: RawEntry[] }, emit);
		stream.start(async (events) => {
			if (stream !== this.stream) return;
			let finished = false;
			for (const event of events) {
				const e = event as { type: string; entry?: RawEntry; toolCallId?: string };
				if (e.type === "snapshot") {
					this.load(event as never, true);
					continue;
				}
				if (e.type === "run_end") finished = true;
				if (e.entry) this.noteEntry(e.entry);
				this.mapper.apply(event as never);
			}
			this.emit(this.builder.flush());
			// A topic answered a message typed in it: unread dot and summary (routed ones are followed by `track`).
			if (finished && !isMain) {
				const id = String(conversation.id);
				void space.touchTopic(id, true).then(() => space.summarize(id));
			}
		});
	}

	/** Entries were added outside a run (an imported thread): rebuilds the transcript. */
	async reload(): Promise<void> {
		await this.stream?.stop();
		await this.start(true);
	}

	private load(snapshot: { entries?: RawEntry[] }, emit: boolean): void {
		const entries = snapshot.entries ?? [];
		this.kinds.clear();
		for (const entry of entries) this.noteEntry(entry, false);
		this.mapper.applySnapshot(snapshot as never, false);
		if (this.isMain) for (const [id, route] of this.entryRoutes) this.insertRoute(id, route, false);
		if (emit) this.emit([{ type: "resnapshot", snapshot: this.builder.snapshot() }]);
	}

	/** Remembers entry kinds and routes, and shows your own routes (they have no model message). */
	private noteEntry(entry: RawEntry, live = true): void {
		const id = String(entry.id);
		this.kinds.set(id, entry.kind);
		for (const m of entry.model ?? []) {
			const result = m as { role: string; toolCallId?: string; toolName?: string; details?: unknown };
			if (result.role !== "toolResult" || !result.toolName) continue;
			if (MEMORY_TOOLS.has(result.toolName) && result.details) this.memoryCalls.set(result.toolCallId!, result.details as { revisionId?: string; proposalId?: string });
			const route = result.details as Route | undefined;
			if (this.isMain && ROUTE_TOOLS.has(result.toolName) && route?.topicId) {
				this.toolRoutes.set(result.toolCallId!, route);
				this.space.track(route);
			}
		}
		if (!this.isMain) return;
		if (entry.kind === ROUTE_ENTRY) {
			const route = entry.data as Route & { text: string };
			this.entryRoutes.set(id, route);
			if (live) this.insertRoute(id, route, true);
		}
	}

	private insertRoute(entryId: string, route: Route & { text?: string }, emit: boolean): void {
		const at = route.at ?? new Date().toISOString();
		const before = emit ? undefined : this.builder.firstAfter(at);
		this.builder.insert({ kind: "user", id: `${entryId}:you`, at, text: (route as { text?: string }).text ?? route.message }, before, emit);
		this.builder.insert({ kind: "tool", id: `route:${entryId}`, at, callId: `route:${entryId}`, tool: "route_to_topic", args: {}, status: "done" }, before, emit);
	}

	/** Routes in this Main, oldest first, as currently shown (after moves). */
	routes(): Route[] {
		const ids = [...this.toolRoutes.keys()].map((c) => `tool:${c}`).concat([...this.entryRoutes.keys()].map((e) => `route:${e}`));
		return ids.map((id) => this.routeFor(id)).filter((r): r is Route => Boolean(r));
	}

	routeFor(itemId: string): Route | undefined {
		const original = itemId.startsWith("tool:") ? this.toolRoutes.get(itemId.slice(5)) : itemId.startsWith("route:") ? this.entryRoutes.get(itemId.slice(6)) : undefined;
		if (!original) return undefined;
		return this.space.reroute(itemId) ?? original;
	}

	/** Statuses, moves or memory changed: re-sends the routing and memory cards. */
	refreshCards(): void {
		const items = this.builder.snapshot().items.filter((i) => i.kind === "tool" && (ROUTE_TOOLS.has(i.tool) || MEMORY_TOOLS.has(i.tool) || i.id.startsWith("route:")));
		this.emitter.emit(items.map((item) => ({ type: "item.updated" as const, item: this.transform(item) })));
	}

	async reloadSettings(): Promise<void> {
		await this.settings();
		this.emit(this.builder.flush());
	}

	/** A memory tool's card: what changed, and whether it stands (Undo) or waits for you (Save, Dismiss). */
	private memoryCard(item: Extract<TimelineItem, { kind: "tool" }>): MemoryItem {
		const call = this.memoryCalls.get(item.callId);
		const args = (item.args ?? {}) as { add?: string[]; remove?: string[]; reason?: string };
		const base = { kind: "memory" as const, id: item.id, at: item.at, action: item.tool === "propose_memory" ? ("proposed" as const) : ("saved" as const) };
		if (item.status === "error" || (item.status !== "running" && item.status !== "pending_approval" && !call)) {
			return { ...base, added: args.add ?? [], removed: args.remove ?? [], status: "failed", ...(item.output ? { reason: item.output } : {}) };
		}
		if (call?.proposalId) {
			const p = this.space.proposal(call.proposalId);
			return { ...base, added: p?.added ?? args.add ?? [], removed: p?.removed ?? args.remove ?? [], ...(p?.reason ? { reason: p.reason } : {}), status: p?.status ?? "pending", proposalId: call.proposalId, ...(p?.revisionId ? { revisionId: p.revisionId } : {}) };
		}
		if (call?.revisionId) {
			const r = this.space.revision(call.revisionId);
			return { ...base, added: r?.added ?? [], removed: r?.removed ?? [], status: r?.undone ? "undone" : "saved", revisionId: call.revisionId };
		}
		return { ...base, added: args.add ?? [], removed: args.remove ?? [], status: "pending" };
	}

	/** Main: organizer tool cards become routing cards. Memory tools become memory cards. Topics: direct messages get their badge. */
	private transform(item: TimelineItem): TimelineItem {
		if (item.kind === "tool" && MEMORY_TOOLS.has(item.tool)) return this.memoryCard(item);
		if (this.isMain && item.kind === "tool" && (ROUTE_TOOLS.has(item.tool) || item.id.startsWith("route:"))) {
			const route = this.routeFor(item.id);
			if (!route) {
				const args = (item.args ?? {}) as { topic?: string; title?: string; reason?: string; message?: string };
				const title = args.title ?? this.space.topic(args.topic ?? "")?.title ?? args.topic ?? "a topic";
				const failed = item.status === "error" || item.status === "interrupted";
				return { kind: "routing", id: item.id, at: item.at, decision: item.tool === "create_topic" ? "create" : "route", topicId: "", topicTitle: title, reason: failed ? (item.output ?? "Couldn't route this message.") : (args.reason ?? ""), message: args.message ?? "", status: failed ? "failed" : "thinking" };
			}
			const live = route.submissionId ? this.space.liveStatus(route.submissionId) : { status: "replied" as const };
			return {
				kind: "routing",
				id: item.id,
				at: item.at,
				decision: route.decision,
				topicId: route.topicId,
				topicTitle: this.space.topic(route.topicId)?.title ?? route.topicTitle,
				reason: route.reason,
				message: route.message,
				status: live.status,
				...(live.preview ? { preview: live.preview } : {}),
				...(live.replyItemId ? { replyItemId: live.replyItemId } : {}),
				...(route.forced ? { forced: true } : {}),
				...(route.movedFrom ? { movedFrom: route.movedFrom } : {}),
			};
		}
		if (!this.isMain && item.kind === "user") {
			const kind = this.kinds.get(item.id);
			if (kind && kind !== ROUTED_ENTRY) return { ...item, direct: true };
		}
		return item;
	}

	private emit(events: SessionEvent[]): void {
		if (events.length === 0) return;
		this.emitter.emit(
			events.map((e) => {
				switch (e.type) {
					case "item.added":
					case "item.updated":
						return { ...e, item: this.transform(e.item) };
					case "item.replaced":
						return { ...e, item: this.transform(e.item) };
					case "resnapshot":
						return { ...e, snapshot: { ...e.snapshot, items: e.snapshot.items.map((i) => this.transform(i)) } };
					default:
						return e;
				}
			}),
		);
	}

	private async settings(): Promise<void> {
		const agent = (await this.conversation.agent(ctx)) as { model?: { provider: string; id?: string; modelId?: string }; thinkingLevel?: string };
		const id = agent.model?.id ?? agent.model?.modelId;
		this.builder.setState({ ...(agent.model && id ? { model: { provider: agent.model.provider, id } } : {}), thinking: agent.thinkingLevel ?? "default", tools: { web: true } } as never);
	}

	snapshot(): Snapshot {
		const snapshot = this.builder.snapshot();
		return { ...snapshot, items: snapshot.items.map((i) => this.transform(i)) };
	}

	onEvents(listener: (events: SessionEvent[]) => void): () => void {
		return this.emitter.on(listener);
	}

	async submit(text: string, options: SubmitOptions) {
		const busy = this.builder.status === "running";
		if (this.isMain && !options.attachments?.length) {
			const forced = await this.forced(text);
			if (forced) return { disposition: "started" as const };
		}
		let input = commandInput(text, options.attachments, this.space.expand(text));
		if (this.isMain && /^\/main\s/i.test(text)) {
			// /main …: the organizer answers here.
			const words = text.replace(/^\/main\s+/i, "");
			const base = buildInput(words, options.attachments);
			const note = "\n\n(The user asked you to answer this here in Main; don't route it.)";
			input = { content: typeof base.content === "string" ? words + note : [...base.content.slice(0, -1), { type: "text", text: words + note }], entry: { kind: USER_ENTRY, data: { text: words, attachments: base.entry?.data.attachments ?? [] } } };
		}
		await this.send(input, text, options);
		if (!this.isMain) await this.space.touchTopic(String(this.conversation.id));
		return { disposition: busy ? ("queued" as const) : ("started" as const) };
	}

	/** `@Topic …` and `/new Title` (S3). Returns false when the text is an ordinary message. */
	private async forced(text: string): Promise<boolean> {
		const create = /^\/new\s+([^\n]+)(?:\n([\s\S]*))?$/i.exec(text.trim());
		if (create) {
			const title = create[1]!.trim();
			const message = (create[2] ?? "").trim();
			const topic = await this.space.newTopic(title, message ? `Started from: ${message.slice(0, 200)}` : "");
			await this.space.forceRoute(text, topic, "create", message);
			return true;
		}
		if (!text.startsWith("@")) return false;
		const lower = text.slice(1).toLowerCase();
		const topic = [...this.space.topics].sort((a, b) => b.title.length - a.title.length).find((t) => lower.startsWith(t.title.toLowerCase()) && /^(\s|[,:]|$)/.test(lower.slice(t.title.length)));
		if (!topic) return false;
		const message = text.slice(1 + topic.title.length).replace(/^[\s,:]+/, "").trim();
		if (!message) throw new EngineError("INVALID", `Write a message after @${topic.title}.`);
		await this.space.ensureCredential();
		await this.space.forceRoute(text, topic, "route", message);
		return true;
	}

	private async send(input: BuiltInput, text: string, options: Omit<SubmitOptions, "attachments">): Promise<void> {
		await this.space.ensureCredential();
		try {
			const submission = await this.conversation.submit(
				{ type: "input", content: input.content, ...(input.entry ? { entry: input.entry } : {}), whenBusy: options.whenBusy, ...(options.requestId ? { requestId: options.requestId } : {}) } as Parameters<Conversation["submit"]>[0],
				ctx,
			);
			this.queueTexts.set(String(submission.id), text);
			this.mapper.refreshQueue();
			this.emit(this.builder.flush());
		} catch (error) {
			if (error instanceof ConversationBusy) throw new EngineError("BUSY", "This conversation is busy.");
			throw error;
		}
	}

	/** Appends a display entry (no model message): your own routes. */
	async write(kind: string, data: unknown): Promise<void> {
		await this.conversation.submit({ type: "write", entry: { kind, data } } as never, ctx);
	}

	async abort(): Promise<void> {
		await this.conversation.abort(ctx);
	}

	async configure(change: { model?: ModelRef; thinking?: string }): Promise<void> {
		await this.conversation.configure({ ...(change.model ? { model: modelOf(change.model) } : {}), ...(change.thinking ? { thinkingLevel: change.thinking === "default" ? null : change.thinking } : {}) } as never, ctx);
		await this.settings();
		this.emit(this.builder.flush());
	}

	async removeQueued(queueId: string): Promise<void> {
		const submission = await this.space.submissionHandle(queueId);
		if (!submission) throw new EngineError("NOT_FOUND", "That message is no longer queued.");
		await submission.abort(ctx);
	}

	async clearQueue(): Promise<void> {
		for (const q of this.builder.snapshot().state.queue) await this.removeQueued(q.id).catch(() => undefined);
	}

	async stop(): Promise<void> {
		await this.stream?.stop();
	}

	/** Topic views close with their Space. */
	async close(): Promise<void> {
		if (this.isMain) await this.space.close();
	}
}

type RawEntry = { id: string | number; kind: string; model?: { role: string }[]; data?: unknown };

function modelOf(model: ModelRef) {
	return { provider: model.provider, modelId: model.id };
}

function clone(state: Readonly<SpaceState> | undefined): SpaceState {
	return state ? (structuredClone(state) as SpaceState) : { topics: [], hints: [], reroutes: {} };
}

/** User and assistant text of entries, for search and summaries. */
function entryText(entry: { kind: string; data?: unknown; model?: readonly { role: string; content?: unknown }[] }): { role: "user" | "assistant"; text: string } | undefined {
	if (entry.kind === USER_ENTRY) return { role: "user", text: (entry.data as { text: string }).text };
	const m = entry.model?.[0];
	if (!m || (m.role !== "user" && m.role !== "assistant")) return undefined;
	const content = m.content as string | PiContentBlock[];
	const t = typeof content === "string" ? content : contentText(content.filter((b) => b.type === "text"));
	return t.trim() ? { role: m.role, text: t } : undefined;
}
