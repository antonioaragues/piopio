/**
 * Thread runtime: one pi-durable session (SQLite file). The thread shows one conversation at a time,
 * the active branch; edits and regenerations fork new conversations (see branches.ts).
 */
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ConversationBusy, createRegistry, Harness, watchEvents, type AgentEventStream, type Conversation, type Extension } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import type { Attachment, ContainerRef, ModelRef, Snapshot } from "@piopio/protocol";
import { asSubmitted, commandInput, isUserEntry, withText, type BuiltInput } from "../input.js";
import { createWebExtension, type WebOptions } from "../tools/web.js";
import { EngineError, type ModelHub } from "../models.js";
import { contentText, TimelineBuilder, type PiContentBlock } from "../timeline/builder.js";
import { DurableEventMapper } from "../timeline/pi-durable.js";
import { computeBranches, type ConversationNode, type ViewEntry } from "./branches.js";
import { recorder } from "./recorder.js";
import { Emitter, type Runtime, type SubmitOptions } from "./runtime.js";
import { attachChatMcp, type ChatMcp } from "../tools/mcp-chat.js";
import { exportConversation, importInto, type Portable } from "./transfer.js";
import { CONNECTORS_EXTENSION, durableConnectorsExtension, waitFor, type CallSite } from "../connectors/extension.js";
import type { ConnectorHub } from "../connectors/hub.js";
import type { Confirm } from "../connectors/tools.js";
import type { ApprovalItem } from "@piopio/protocol";

const ctx = BACKGROUND_CONTEXT;

/** What the catalog remembers about a thread's branches. */
export type BranchState = { active?: string; activity: Record<string, number> };

type RawEntry = { id: string | number; kind: string; conversationId: string | number; data?: unknown; model?: { role: string; content: unknown }[] };

export type ThreadOpenOptions = {
	ref: ContainerRef;
	file: string;
	hub: ModelHub;
	model: ModelRef;
	thinking?: string;
	branches?: BranchState;
	/** Persists branch state changes (active branch, last activity). */
	onBranchState?: (state: BranchState) => void;
	/** Web tools on (default) or off. */
	web?: boolean;
	webOptions?: WebOptions;
	/** More extensions (About me). */
	extensions?: Extension[];
	/** MCP servers, when Chat may use them. */
	mcp?: ChatMcp;
	/** Expands a `/command` (prompt templates, skills), or undefined. */
	expand?: (text: string) => string | undefined;
	/** Connected apps (docs/spec/12-connectors): their tools, asking here before a change. */
	connectors?: ConnectorHub;
};

/** A connector change waiting for the user in this thread. */
type PendingApproval = { item: ApprovalItem; resolve: (answer: { approved: boolean; always?: boolean; reason?: string }) => void };

export class ThreadRuntime implements Runtime {
	private readonly emitter = new Emitter();
	private readonly builder: TimelineBuilder;
	private readonly mapper: DurableEventMapper;
	private stream?: AgentEventStream;
	private active!: Conversation;
	private readonly queueTexts = new Map<string, string>();
	private branchState: BranchState;
	private switching: Promise<void> = Promise.resolve();

	private constructor(
		readonly ref: ContainerRef,
		private readonly hub: ModelHub,
		private readonly harness: Harness,
		private model: ModelRef,
		private thinking: string | undefined,
		branches: BranchState | undefined,
		private readonly onBranchState: ((state: BranchState) => void) | undefined,
		private web: boolean,
		private readonly webExtension: Extension,
	) {
		this.builder = new TimelineBuilder(ref);
		this.mapper = new DurableEventMapper(this.builder, (id) => this.queueTexts.get(id));
		this.branchState = branches ?? { activity: {} };
	}

	static async open(options: ThreadOpenOptions): Promise<ThreadRuntime> {
		const storage = await openNodeSqliteStorage(options.file);
		const registry = createRegistry();
		const webExtension = createWebExtension(options.hub, options.webOptions) as unknown as Extension;
		registry.install(webExtension as never);
		for (const e of options.extensions ?? []) registry.install(e as never);
		const detachMcp = options.mcp ? await attachChatMcp(registry as never, options.mcp) : undefined;
		let runtime: ThreadRuntime | undefined;
		const connectors = options.connectors ? (durableConnectorsExtension(options.connectors, "chat", (site) => runtime!.confirmFor(site)) as unknown as Extension) : undefined;
		if (connectors) registry.install(connectors as never);
		const harness = await Harness.open(storage, { models: options.hub.models, registry }, ctx);
		runtime = new ThreadRuntime(options.ref, options.hub, harness, options.model, options.thinking, options.branches, options.onBranchState, options.web ?? true, webExtension);
		runtime.connectors = options.connectors;
		runtime.connectorsExtension = connectors;
		runtime.detachMcp = detachMcp;
		runtime.expand = options.expand;
		const root = await harness.root(ctx, { agent: runtime.agent() } as Parameters<Harness["root"]>[1]);
		const saved = options.branches?.active ? await harness.conversation(Number(options.branches.active) as never, ctx) : undefined;
		await runtime.attach(saved ?? root, false);
		// Finish any run a previous process left behind (needs the key, so ask first).
		await options.hub.ensureCredential(options.model.provider).catch(() => undefined);
		harness.resume();
		return runtime;
	}

	private agent() {
		return { model: { provider: this.model.provider, modelId: this.model.id }, ...(this.thinking ? { thinkingLevel: this.thinking } : {}) };
	}

	/** The thread's settings, applied to whichever branch is shown (branches made earlier may differ). */
	private async applySettings(conversation: Conversation): Promise<void> {
		this.appsOn = this.hasApps();
		const remove = [...(this.web ? [] : [this.webExtension]), ...(this.connectorsExtension && !this.appsOn ? [this.connectorsExtension] : [])];
		await conversation.configure(
			{
				model: { provider: this.model.provider, modelId: this.model.id },
				thinkingLevel: this.thinking ?? null,
				extensions: remove.length ? { remove } : null,
			} as unknown as Parameters<Conversation["configure"]>[0],
			ctx,
		);
	}

	// MARK: Connected apps

	connectors?: ConnectorHub;
	connectorsExtension?: Extension;
	/** Whether the connector tools were on when settings were last applied. */
	private appsOn = false;
	private readonly approvals = new Map<string, PendingApproval>();

	private hasApps(): boolean {
		return Boolean(this.connectors && (this.connectors.calendars("chat").length || this.connectors.mailboxes("chat").length));
	}

	/** Asks in this thread before a connector changes something: an approval card until answered or stopped. */
	confirmFor(site: CallSite): Confirm {
		return async (request) => {
			const id = `conn_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
			const label = this.connectors?.definition(request.connector)?.name ?? request.connector;
			const item: ApprovalItem = {
				kind: "approval",
				id: `approval:${id}`,
				at: new Date().toISOString(),
				approvalId: id,
				tool: request.tool,
				title: request.title,
				args: request.args,
				status: "pending",
				expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
				always: request.canAllowAlways ? `Don't ask again for this in ${label}` : "",
				source: "connector",
			};
			const decided = new Promise<{ approved: boolean; always?: boolean; reason?: string }>((resolve) => this.approvals.set(id, { item, resolve }));
			this.builder.insert(item);
			this.emitter.emit(this.builder.flush());
			try {
				return await waitFor(decided, site.context);
			} catch (error) {
				this.settle(id, "cancelled");
				throw error;
			}
		};
	}

	private settle(id: string, status: ApprovalItem["status"], reason?: string): void {
		const pending = this.approvals.get(id);
		if (!pending) return;
		this.approvals.delete(id);
		pending.item.status = status;
		if (reason) pending.item.reason = reason;
		this.emitter.emit([{ type: "item.updated", item: structuredClone(pending.item) }]);
	}

	/** The user's answer to a connector approval (`sessions.decide`). */
	async decide(approvalId: string, decision: { approve: boolean; always?: boolean; reason?: string }): Promise<ApprovalItem["status"]> {
		const pending = this.approvals.get(approvalId);
		if (!pending) throw new EngineError("NOT_FOUND", "That request was already answered or has gone.");
		pending.resolve({ approved: decision.approve, ...(decision.always ? { always: true } : {}), ...(decision.reason ? { reason: decision.reason } : {}) });
		this.settle(approvalId, decision.approve ? "approved" : "denied", decision.reason);
		return decision.approve ? "approved" : "denied";
	}

	private stateSettings() {
		return { model: this.model, thinking: this.thinking ?? "default", tools: { web: this.web } };
	}

	/** Shows `conversation`: a fresh snapshot (with branch switchers) replaces the transcript. */
	private async attach(conversation: Conversation, emit: boolean): Promise<void> {
		await this.stream?.stop();
		this.active = conversation;
		await this.applySettings(conversation);
		const view = await conversation.viewState(ctx);
		const inbox = (view.value.docs as Record<string, { items?: { id: unknown; content?: unknown }[] } | undefined>)["pi.inbox"]?.items ?? [];
		for (const item of inbox) {
			if (item.content !== undefined) this.queueTexts.set(String(item.id), contentText(item.content as string | PiContentBlock[]));
		}
		view.dispose();

		const stream = await watchEvents(this.harness, conversation.id, ctx);
		this.stream = stream;
		const record = recorder("pi-durable", this.ref.id);
		record?.(stream.snapshot);
		this.mapper.applySnapshot(stream.snapshot as never, false);
		this.builder.setState(this.stateSettings());
		this.builder.annotateBranches(await this.branches(), false);
		this.builder.flush();
		if (emit) this.emitter.emit([{ type: "resnapshot", snapshot: this.builder.snapshot() }]);
		stream.start(async (events) => {
			if (stream !== this.stream) return;
			let reannotate = false;
			for (const event of events) {
				record?.(event);
				this.mapper.apply(event as never);
				const e = event as { type: string; entry?: { kind?: string } };
				// A new user message may sit at a fork point (after an edit): refresh the switchers.
				if (e.type === "snapshot" || (e.type === "message_end" && e.entry?.kind === "pi.user")) reannotate = true;
			}
			if (reannotate) this.builder.annotateBranches(await this.branches());
			this.emitter.emit(this.builder.flush());
		});
	}

	private async branches() {
		const view = await this.active.viewState(ctx);
		const entries: ViewEntry[] = (view.value.entries as readonly RawEntry[]).map((e) => ({ id: String(e.id), kind: e.kind, conversationId: String(e.conversationId) }));
		view.dispose();
		const records = await this.harness.commit(async (tx) => (await tx.scanConversations({}, 10_000)).items, ctx);
		const nodes: ConversationNode[] = (records as readonly { id: unknown; parent?: { conversationId: unknown; at: unknown } }[]).map((r) => ({
			id: String(r.id),
			...(r.parent ? { parent: { conversationId: String(r.parent.conversationId), at: String(r.parent.at) } } : {}),
		}));
		return computeBranches(String(this.active.id), entries, nodes, this.branchState.activity);
	}

	private touch(conversationId: string): void {
		this.branchState = { active: conversationId, activity: { ...this.branchState.activity, [conversationId]: Date.now() } };
		this.onBranchState?.(this.branchState);
	}

	snapshot(): Snapshot {
		return this.builder.snapshot();
	}

	onEvents(listener: Parameters<Runtime["onEvents"]>[0]): () => void {
		return this.emitter.on(listener);
	}

	async submit(text: string, options: SubmitOptions) {
		const busy = this.builder.status === "running";
		await this.submitInput(commandInput(text, options.attachments, this.expand?.(text)), text, options);
		return { disposition: busy ? ("queued" as const) : ("started" as const) };
	}

	private async submitInput(input: BuiltInput, text: string, options: Omit<SubmitOptions, "attachments">): Promise<void> {
		await this.switching;
		if (Array.isArray(input.content) && input.content.some((b) => b.type === "image")) {
			const model = this.hub.models.getModel(this.model.provider, this.model.id);
			if (model && !model.input.includes("image")) throw new EngineError("INVALID", `${model.name} can't read images. Pick a model with vision.`);
		}
		await this.hub.ensureCredential(this.model.provider);
		// Apps connected or removed since the thread opened: offer their tools (or stop).
		if (this.hasApps() !== this.appsOn) await this.applySettings(this.active);
		try {
			const submission = await this.active.submit(
				{ type: "input", content: input.content, ...(input.entry ? { entry: input.entry } : {}), whenBusy: options.whenBusy, ...(options.requestId ? { requestId: options.requestId } : {}) } as Parameters<Conversation["submit"]>[0],
				ctx,
			);
			this.queueTexts.set(String(submission.id), text);
			this.mapper.refreshQueue();
			this.emitter.emit(this.builder.flush());
		} catch (error) {
			if (error instanceof ConversationBusy) throw new EngineError("BUSY", "The thread is busy.");
			throw error;
		}
		this.touch(String(this.active.id));
	}

	async abort(): Promise<void> {
		await this.active.abort(ctx);
	}

	async configure(change: { model?: ModelRef; thinking?: string; web?: boolean }): Promise<void> {
		if (change.model && !this.hub.models.getModel(change.model.provider, change.model.id)) {
			throw new EngineError("INVALID", `Unknown model ${change.model.provider}/${change.model.id}`);
		}
		if (change.model) this.model = change.model;
		if (change.thinking) this.thinking = change.thinking === "default" ? undefined : change.thinking;
		if (change.web !== undefined) this.web = change.web;
		await this.applySettings(this.active);
		this.builder.setState(this.stateSettings());
		this.emitter.emit(this.builder.flush());
	}

	// MARK: Branches

	async edit(itemId: string, text: string): Promise<void> {
		await this.rerun(itemId, text);
	}

	async regenerate(itemId: string): Promise<void> {
		await this.rerun(itemId);
	}

	/** Forks just before the user message at/before `itemId` and asks again (with `text`, or the original). */
	private async rerun(itemId: string, text?: string): Promise<void> {
		const view = await this.active.viewState(ctx);
		const entries = view.value.entries as readonly RawEntry[];
		view.dispose();
		const at = entries.findIndex((e) => String(e.id) === itemId);
		if (at < 0) throw new EngineError("NOT_FOUND", `No message ${itemId} in this branch`);
		let userIndex = at;
		while (userIndex >= 0 && !isUserEntry(entries[userIndex]!.kind)) userIndex--;
		if (userIndex < 0) throw new EngineError("INVALID", "There is no message to ask again from.");
		const userEntry = entries[userIndex]!;
		const stored = userEntry.model?.[0]?.content;
		const input = text === undefined ? asSubmitted(stored, userEntry) : withText(stored, userEntry, text);
		const displayText = text ?? (userEntry.kind === "piopio.user" ? (userEntry.data as { text: string }).text : contentText(stored as string | PiContentBlock[]));
		const previous = entries[userIndex - 1];
		const branch = previous
			? await this.active.fork(previous.id as never, { ownership: { kind: "ownerless" } } as never, ctx)
			: await this.harness.createConversation({ ownership: { kind: "ownerless" }, agent: this.agent() } as never, ctx);
		await this.switchTo(branch);
		await this.submitInput(input, displayText, { whenBusy: "followUp" });
	}

	async switchBranch(branch: string): Promise<void> {
		const conversation = await this.harness.conversation(Number(branch) as never, ctx);
		if (!conversation) throw new EngineError("NOT_FOUND", `No branch ${branch}`);
		await this.switchTo(conversation);
	}

	/** Starts a copied thread at a fork of the active branch ending at `itemId` (inclusive). */
	async startAt(itemId: string): Promise<void> {
		const fork = await this.active.fork(Number(itemId) as never, { ownership: { kind: "ownerless" } } as never, ctx);
		await this.switchTo(fork);
	}

	private async switchTo(conversation: Conversation): Promise<void> {
		const done = this.switching.then(async () => {
			this.touch(String(conversation.id));
			await this.attach(conversation, true);
		});
		this.switching = done.catch(() => undefined);
		await done;
	}

	// MARK: Queue

	async removeQueued(queueId: string): Promise<void> {
		const submission = await this.harness.submission(Number(queueId) as never, ctx);
		if (!submission) throw new EngineError("NOT_FOUND", "That message is no longer queued.");
		await submission.abort(ctx);
	}

	async clearQueue(): Promise<void> {
		for (const q of this.builder.snapshot().state.queue) await this.removeQueued(q.id).catch(() => undefined);
	}

	private detachMcp?: () => void;
	private expand?: (text: string) => string | undefined;

	// MARK: Moving (04-chat S5, S9)

	/** The shown branch's messages, to move into a Space. */
	exportEntries(): Promise<Portable[]> {
		return exportConversation(this.active);
	}

	/** Appends copied messages (a promoted topic) and shows them. */
	async importEntries(entries: readonly Portable[], from: { title: string }): Promise<void> {
		await this.harness.commit((tx) => importInto(tx, this.active.id, entries, from), ctx);
		await this.attach(this.active, true);
	}

	async close(): Promise<void> {
		this.detachMcp?.();
		await this.stream?.stop();
		await this.harness.close(ctx);
	}
}
