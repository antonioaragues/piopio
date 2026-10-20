/**
 * Space runtime (docs/spec/04-chat §3): one pi-durable session per Space. Main, the root conversation, is the
 * organizer: for each message it answers, routes it to a topic, or creates a topic. Topics are ownerless
 * conversations. Main shows a routing card for each routed message; the reply itself lives in the topic.
 *
 * `@Topic …`, `/new <title>` and `/main …` let you decide instead of the organizer (S3). Wrong topic moves a
 * routed message and leaves a hint the organizer reads from then on (S2).
 */
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { Type } from "@earendil-works/pi-ai";
import {
	configure,
	ConversationBusy,
	createRegistry,
	defineDoc,
	defineExtension,
	defineTool,
	Harness,
	section,
	watchEvents,
	type AgentEventStream,
	type Conversation,
	type ConversationId,
	type Extension,
	type Tx,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import type { ContainerRef, ModelRef, RoutingItem, SessionEvent, Snapshot, TimelineItem } from "@piopio/protocol";
import { buildInput, USER_ENTRY, type BuiltInput } from "../input.js";
import { EngineError, type ModelHub } from "../models.js";
import { contentText, TimelineBuilder, type PiContentBlock } from "../timeline/builder.js";
import { DurableEventMapper } from "../timeline/pi-durable.js";
import { createWebExtension, type WebOptions } from "../tools/web.js";
import { Emitter, type Runtime, type SubmitOptions } from "./runtime.js";

const ctx = BACKGROUND_CONTEXT;

/** A message the organizer (or you, with @topic) sent to a topic. */
const ROUTED_ENTRY = "piopio.routed";
/** In Main: a message you sent to a topic yourself (@topic, /new). */
const ROUTE_ENTRY = "piopio.route";
const ORGANIZER_TOOLS = new Set(["route_to_topic", "create_topic"]);
const MAX_HINTS = 20;

type TopicRecord = { id: string; title: string; brief: string; status: "active" | "archived"; createdAt: string; lastActiveAt: string; lastReplyAt?: string };
type Hint = { message: string; wrong: string; right: string; at: string };
/** Where a routed message went: the organizer's tool result details, a route entry, or a reroute. */
type Route = { decision: "route" | "create"; topicId: string; topicTitle: string; reason: string; message: string; submissionId?: string; forced?: boolean; movedFrom?: string; at?: string };
type SpaceState = { topics: TopicRecord[]; hints: Hint[]; reroutes: Record<string, Route> };

/** The Space's topics, routing hints and moved messages (`piopio.space`). */
export const SpaceDoc = defineDoc<SpaceState>({ kind: "piopio.space", version: 1, scope: "session", initial: () => ({ topics: [], hints: [], reroutes: {} }) });

export type TopicSummary = { id: string; title: string; brief: string; lastActiveAt: string; lastReplyAt?: string; running: boolean };

export type SpaceOpenOptions = {
	ref: ContainerRef;
	file: string;
	hub: ModelHub;
	model: ModelRef;
	/** The Space's name and instructions, read each request. */
	info: () => { name: string; instructions?: string };
	webOptions?: WebOptions;
	/** The topics changed (sidebar). */
	onTopics?: (topics: TopicSummary[]) => void;
};

type Live = { status: RoutingItem["status"]; preview?: string; replyItemId?: string };

export class SpaceRuntime implements Runtime {
	private readonly views = new Map<string, Promise<SpaceView>>();
	private main!: SpaceView;
	private state: SpaceState = { topics: [], hints: [], reroutes: {} };
	/** Live status of routed messages, by submission id. */
	private readonly live = new Map<string, Live>();
	private readonly tracked = new Set<string>();
	private docWatch?: { stop(): Promise<unknown> };
	private closed = false;

	private constructor(
		private readonly options: SpaceOpenOptions,
		private readonly harness: Harness,
		private readonly organizer: Extension,
		private readonly topicExtension: Extension,
		private readonly web: Extension,
		private model: ModelRef,
	) {}

	get ref(): ContainerRef {
		return this.options.ref;
	}

	static async open(options: SpaceOpenOptions): Promise<SpaceRuntime> {
		const storage = await openNodeSqliteStorage(options.file);
		const registry = createRegistry();
		// The extensions read the runtime through `host`, which is set once it exists.
		let host!: SpaceRuntime;
		const web = createWebExtension(options.hub, options.webOptions) as unknown as Extension;
		const organizer = organizerExtension(() => host);
		const topic = topicExtension(() => host);
		for (const e of [web, organizer, topic]) registry.install(e as never);
		const harness = await Harness.open(storage, { models: options.hub.models, registry, settings: { extensions: [web, topic] } } as never, ctx);
		host = new SpaceRuntime(options, harness, organizer, topic, web, options.model);
		const root = await harness.root(ctx, { agent: { model: modelOf(options.model), extensions: [organizer, web] } } as never);
		host.state = clone((await harness.snapshot(SpaceDoc, ctx)) ?? undefined);
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
		// The watch needs the document to exist.
		await this.harness.commit(async (tx) => void (await tx.doc(SpaceDoc)), ctx);
		const watch = await this.harness.watchDoc(SpaceDoc, ctx);
		if (!watch) return;
		this.docWatch = watch;
		watch.start(async (value) => {
			this.state = clone(value ?? undefined);
			this.main.refreshRoutes();
			this.publishTopics();
		});
	}

	private publishTopics(): void {
		if (this.closed) return;
		const running = new Set<string>();
		for (const route of this.main.routes()) {
			const live = route.submissionId ? this.live.get(route.submissionId) : undefined;
			if (live && (live.status === "thinking" || live.status === "replying")) running.add(route.topicId);
		}
		for (const [id, view] of this.openViews) if (view.snapshot().state.status === "running") running.add(id);
		const topics = [...this.topics]
			.sort((a, b) => b.lastActiveAt.localeCompare(a.lastActiveAt))
			.map((t) => ({ id: t.id, title: t.title, brief: t.brief, lastActiveAt: t.lastActiveAt, ...(t.lastReplyAt ? { lastReplyAt: t.lastReplyAt } : {}), running: running.has(t.id) }));
		this.options.onTopics?.(topics);
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
		await configure(tx, record.id, { model: modelOf(this.model), extensions: [this.web, this.topicExtension] } as never);
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
	}

	private setLive(submissionId: string, live: Live): void {
		this.live.set(submissionId, live);
		this.main.refreshRoutes();
		this.publishTopics();
	}

	liveStatus(submissionId: string | undefined): Live {
		return (submissionId && this.live.get(submissionId)) || { status: "thinking" };
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
		if (change.model) this.model = change.model; // new topics
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
		await this.docWatch?.stop();
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

	static async attach(space: SpaceRuntime, conversation: Conversation, isMain: boolean): Promise<SpaceView> {
		const view = new SpaceView(space, conversation, isMain);
		if (!isMain) space.registerView(String(conversation.id), view);
		const stream = await space.watch(conversation.id);
		view.stream = stream;
		view.load(stream.snapshot as unknown as { entries?: RawEntry[] }, false);
		await view.settings();
		view.builder.flush();
		stream.start(async (events) => {
			for (const event of events) {
				const e = event as { type: string; entry?: RawEntry; toolCallId?: string };
				if (e.type === "snapshot") {
					view.load(event as never, true);
					continue;
				}
				if (e.entry) view.noteEntry(e.entry);
				view.mapper.apply(event as never);
			}
			view.emit(view.builder.flush());
		});
		return view;
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
		if (!this.isMain) return;
		for (const m of entry.model ?? []) {
			const result = m as { role: string; toolCallId?: string; toolName?: string; details?: Route };
			if (result.role === "toolResult" && result.toolName && ORGANIZER_TOOLS.has(result.toolName) && result.details?.topicId) {
				this.toolRoutes.set(result.toolCallId!, result.details);
				this.space.track(result.details);
			}
		}
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

	/** Statuses or moves changed: re-sends the routing cards. */
	refreshRoutes(): void {
		if (!this.isMain) return;
		const items = this.builder.snapshot().items.filter((i) => i.kind === "tool" && (ORGANIZER_TOOLS.has(i.tool) || i.id.startsWith("route:")));
		this.emitter.emit(items.map((item) => ({ type: "item.updated" as const, item: this.transform(item) })));
	}

	/** Main: organizer tool cards become routing cards. Topics: direct messages get their badge. */
	private transform(item: TimelineItem): TimelineItem {
		if (this.isMain && item.kind === "tool" && (ORGANIZER_TOOLS.has(item.tool) || item.id.startsWith("route:"))) {
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
		let input = buildInput(text, options.attachments);
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

// ── Extensions ───────────────────────────────────────────────────────────────

function organizerExtension(host: () => SpaceRuntime) {
	const routeTool = defineTool({
		name: "route_to_topic",
		description: "Send the user's latest message to an existing topic. The topic's agent answers it there; you don't answer it yourself.",
		parameters: Type.Object({
			topic: Type.String({ description: "The topic's id or exact title" }),
			reason: Type.String({ description: "One short line saying why it belongs there" }),
			message: Type.Optional(Type.String({ description: "The message as the topic should get it. Default: the user's words as written. Rewrite only to add context from Main that the topic needs." })),
		}),
		execute: async (args, api, context) => {
			const space = host();
			const topic = space.topic(args.topic);
			if (!topic) return { output: [{ type: "text", text: `No topic “${args.topic}”. Topics: ${space.topics.map((t) => `${t.id} “${t.title}”`).join(", ") || "none yet"}.` }], isError: true };
			const message = args.message?.trim() || (await lastUserText(api, context));
			const submissionId = await space.sendToTopic(topic.id, message, `route:${api.taskId}`, (id) => api.conversation(id, context) as never);
			await space.touchTopic(topic.id);
			const details: Route = { decision: "route", topicId: topic.id, topicTitle: topic.title, reason: args.reason, message, submissionId };
			return { output: [{ type: "text", text: `Sent to “${topic.title}”. Its agent answers there.` }], details: details as never, control: { terminate: true } };
		},
	});

	const createTool = defineTool({
		name: "create_topic",
		description: "Start a new topic for a new subject that will likely come back or needs depth, and send the user's latest message to it. Its agent answers there.",
		parameters: Type.Object({
			title: Type.String({ description: "A short title (2–5 words)" }),
			brief: Type.String({ description: "One or two sentences: what this topic is about, for its agent" }),
			reason: Type.String({ description: "One short line saying why this needs its own topic" }),
			message: Type.Optional(Type.String({ description: "The message as the topic should get it. Default: the user's words as written." })),
		}),
		execute: async (args, api, context) => {
			const space = host();
			const topic = await api.commit((tx) => space.createTopic(tx, args.title, args.brief), context);
			const message = args.message?.trim() || (await lastUserText(api, context));
			const submissionId = await space.sendToTopic(topic.id, message, `route:${api.taskId}`, (id) => api.conversation(id, context) as never);
			const details: Route = { decision: "create", topicId: topic.id, topicTitle: topic.title, reason: args.reason, message, submissionId };
			return { output: [{ type: "text", text: `Created “${topic.title}” and sent the message there. Its agent answers there.` }], details: details as never, control: { terminate: true } };
		},
	});

	return defineExtension({
		name: "piopio-space-organizer",
		tools: [routeTool, createTool],
		sections: [section("space-organizer", () => organizerPrompt(host()))],
	});
}

function organizerPrompt(space: SpaceRuntime): string {
	const { name, instructions } = space.info;
	const topics = space.topics.length
		? [...space.topics]
				.sort((a, b) => b.lastActiveAt.localeCompare(a.lastActiveAt))
				.map((t) => `- id ${t.id} · “${t.title}”${t.brief ? `: ${t.brief}` : ""} (last active ${t.lastActiveAt.slice(0, 16).replace("T", " ")})`)
				.join("\n")
		: "(no topics yet)";
	const hints = space.hints.length ? `\n\nCorrections the user made (route similar messages the same way):\n${space.hints.map((h) => `- “${h.message}” belongs in “${h.right}”, not “${h.wrong}”`).join("\n")}` : "";
	return `You are the organizer of the Space “${name}”, an area of the user's life or work. The user always writes to you, in Main. For each message, decide one of:
1. Route it: when it continues the subject of an existing topic, call route_to_topic.
2. Create a topic: when it starts a new subject that will likely come back or needs depth, call create_topic (it also sends the message there).
3. Answer it yourself, here: quick one-offs, questions about the Space or its topics, and questions across topics. Call no tool then.
When you route or create, the topic's agent answers in the topic, so don't answer the message yourself. The reason you give is shown to the user: one short line.${instructions ? `\n\nThe Space's instructions:\n${instructions}` : ""}

Topics, most recently active first:
${topics}${hints}`;
}

function topicExtension(host: () => SpaceRuntime) {
	return defineExtension({
		name: "piopio-space-topic",
		sections: [
			section("space-topic", (input) => {
				const space = host();
				const topic = space.topics.find((t) => t.id === String(input.conversationId));
				if (!topic) return undefined;
				const { name, instructions } = space.info;
				return `You are the agent for the topic “${topic.title}” in the Space “${name}”.${topic.brief ? ` ${topic.brief}` : ""}
Messages here come from the user: typed here, or routed from the Space's Main conversation by its organizer. Answer them fully here.${instructions ? `\n\nThe Space's instructions:\n${instructions}` : ""}`;
			}),
		],
	});
}

/** The newest user message of the calling conversation (what the organizer is deciding about). */
async function lastUserText(api: { commit: <T>(change: (tx: Tx) => Promise<T>, context: typeof ctx) => Promise<T>; conversationId: ConversationId }, context: typeof ctx): Promise<string> {
	return api.commit(async (tx) => {
		const page = await tx.scanEntries({ conversationId: api.conversationId, order: "descending" }, 50);
		for (const entry of page.items) {
			if (entry.kind === USER_ENTRY) return (entry.data as { text: string }).text;
			if (entry.kind === "pi.user") return contentText(entry.model?.[0]?.content as string | PiContentBlock[]);
		}
		return "";
	}, context);
}

function modelOf(model: ModelRef) {
	return { provider: model.provider, modelId: model.id };
}

function clone(state: Readonly<SpaceState> | undefined): SpaceState {
	return state ? (structuredClone(state) as SpaceState) : { topics: [], hints: [], reroutes: {} };
}
