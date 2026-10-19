/**
 * Thread runtime: one pi-durable session (SQLite file). The thread shows one conversation at a time,
 * the active branch; edits and regenerations fork new conversations (see branches.ts).
 */
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ConversationBusy, createRegistry, Harness, watchEvents, type AgentEventStream, type Conversation } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import type { ContainerRef, ModelRef, Snapshot } from "@piopio/protocol";
import { EngineError, type ModelHub } from "../models.js";
import { contentText, TimelineBuilder, type PiContentBlock } from "../timeline/builder.js";
import { DurableEventMapper } from "../timeline/pi-durable.js";
import { computeBranches, type ConversationNode, type ViewEntry } from "./branches.js";
import { recorder } from "./recorder.js";
import { Emitter, type Runtime, type WhenBusy } from "./runtime.js";

const ctx = BACKGROUND_CONTEXT;

/** What the catalog remembers about a thread's branches. */
export type BranchState = { active?: string; activity: Record<string, number> };

type RawEntry = { id: string | number; kind: string; conversationId: string | number; model?: { role: string; content: unknown }[] };

export type ThreadOpenOptions = {
	ref: ContainerRef;
	file: string;
	hub: ModelHub;
	model: ModelRef;
	thinking?: string;
	branches?: BranchState;
	/** Persists branch state changes (active branch, last activity). */
	onBranchState?: (state: BranchState) => void;
};

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
	) {
		this.builder = new TimelineBuilder(ref);
		this.mapper = new DurableEventMapper(this.builder, (id) => this.queueTexts.get(id));
		this.branchState = branches ?? { activity: {} };
	}

	static async open(options: ThreadOpenOptions): Promise<ThreadRuntime> {
		const storage = await openNodeSqliteStorage(options.file);
		const harness = await Harness.open(storage, { models: options.hub.models, registry: createRegistry() }, ctx);
		const runtime = new ThreadRuntime(options.ref, options.hub, harness, options.model, options.thinking, options.branches, options.onBranchState);
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

	/** Shows `conversation`: a fresh snapshot (with branch switchers) replaces the transcript. */
	private async attach(conversation: Conversation, emit: boolean): Promise<void> {
		await this.stream?.stop();
		this.active = conversation;
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
		this.builder.setState({ model: this.model, ...(this.thinking ? { thinking: this.thinking } : {}) });
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

	async submit(text: string, options: { whenBusy: WhenBusy; requestId?: string }) {
		await this.switching;
		await this.hub.ensureCredential(this.model.provider);
		const busy = this.builder.status === "running";
		try {
			const submission = await this.active.submit({ type: "input", content: text, whenBusy: options.whenBusy, ...(options.requestId ? { requestId: options.requestId } : {}) }, ctx);
			this.queueTexts.set(String(submission.id), text);
			this.mapper.refreshQueue();
			this.emitter.emit(this.builder.flush());
		} catch (error) {
			if (error instanceof ConversationBusy) throw new EngineError("BUSY", "The thread is busy.");
			throw error;
		}
		this.touch(String(this.active.id));
		return { disposition: busy ? ("queued" as const) : ("started" as const) };
	}

	async abort(): Promise<void> {
		await this.active.abort(ctx);
	}

	async configure(change: { model?: ModelRef; thinking?: string }): Promise<void> {
		if (change.model && !this.hub.models.getModel(change.model.provider, change.model.id)) {
			throw new EngineError("INVALID", `Unknown model ${change.model.provider}/${change.model.id}`);
		}
		if (change.model) this.model = change.model;
		if (change.thinking) this.thinking = change.thinking === "default" ? undefined : change.thinking;
		await this.active.configure(
			{
				...(change.model ? { model: { provider: change.model.provider, modelId: change.model.id } } : {}),
				...(change.thinking ? { thinkingLevel: change.thinking === "default" ? null : change.thinking } : {}),
			} as Parameters<Conversation["configure"]>[0],
			ctx,
		);
		this.builder.setState({ model: this.model, thinking: this.thinking ?? "default" });
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
		while (userIndex >= 0 && entries[userIndex]!.kind !== "pi.user") userIndex--;
		if (userIndex < 0) throw new EngineError("INVALID", "There is no message to ask again from.");
		const original = contentText(entries[userIndex]!.model?.[0]?.content as string | PiContentBlock[]);
		const previous = entries[userIndex - 1];
		const branch = previous
			? await this.active.fork(previous.id as never, { ownership: { kind: "ownerless" } } as never, ctx)
			: await this.harness.createConversation({ ownership: { kind: "ownerless" }, agent: this.agent() } as never, ctx);
		await this.switchTo(branch);
		await this.submit(text ?? original, { whenBusy: "followUp" });
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

	async close(): Promise<void> {
		await this.stream?.stop();
		await this.harness.close(ctx);
	}
}
