/** Thread runtime: one pi-durable session (SQLite file) whose root conversation is the thread. */
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ConversationBusy, createRegistry, Harness, watchEvents, type AgentEventStream, type Conversation } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import type { ContainerRef, ModelRef, Snapshot } from "@piopio/protocol";
import { EngineError, type ModelHub } from "../models.js";
import { TimelineBuilder } from "../timeline/builder.js";
import { DurableEventMapper } from "../timeline/pi-durable.js";
import { recorder } from "./recorder.js";
import { Emitter, type Runtime, type WhenBusy } from "./runtime.js";

const ctx = BACKGROUND_CONTEXT;

export class ThreadRuntime implements Runtime {
	private readonly emitter = new Emitter();
	private readonly builder: TimelineBuilder;
	private readonly mapper: DurableEventMapper;
	private stream?: AgentEventStream;

	private constructor(
		readonly ref: ContainerRef,
		private readonly hub: ModelHub,
		private readonly harness: Harness,
		private readonly root: Conversation,
		private readonly model: ModelRef,
	) {
		this.builder = new TimelineBuilder(ref);
		this.mapper = new DurableEventMapper(this.builder);
	}

	static async open(options: { ref: ContainerRef; file: string; hub: ModelHub; model: ModelRef; thinking?: string }): Promise<ThreadRuntime> {
		const storage = await openNodeSqliteStorage(options.file);
		const harness = await Harness.open(storage, { models: options.hub.models, registry: createRegistry() }, ctx);
		const agent = { model: { provider: options.model.provider, modelId: options.model.id }, ...(options.thinking ? { thinkingLevel: options.thinking } : {}) };
		const root = await harness.root(ctx, { agent } as Parameters<Harness["root"]>[1]);
		const runtime = new ThreadRuntime(options.ref, options.hub, harness, root, options.model);
		await runtime.attach();
		// Finish any run a previous process left behind (needs the key, so ask first).
		await options.hub.ensureCredential(options.model.provider).catch(() => undefined);
		harness.resume();
		return runtime;
	}

	private async attach(): Promise<void> {
		this.stream = await watchEvents(this.harness, this.root.id, ctx);
		const record = recorder("pi-durable", this.ref.id);
		record?.(this.stream.snapshot);
		this.mapper.applySnapshot(this.stream.snapshot as never, false);
		this.builder.flush();
		this.stream.start(async (events) => {
			for (const event of events) {
				record?.(event);
				this.mapper.apply(event as never);
			}
			this.emitter.emit(this.builder.flush());
		});
	}

	snapshot(): Snapshot {
		return this.builder.snapshot();
	}

	onEvents(listener: Parameters<Runtime["onEvents"]>[0]): () => void {
		return this.emitter.on(listener);
	}

	async submit(text: string, options: { whenBusy: WhenBusy; requestId?: string }) {
		await this.hub.ensureCredential(this.model.provider);
		const busy = this.builder.status === "running";
		try {
			await this.root.submit({ type: "input", content: text, whenBusy: options.whenBusy, ...(options.requestId ? { requestId: options.requestId } : {}) }, ctx);
		} catch (error) {
			if (error instanceof ConversationBusy) throw new EngineError("BUSY", "The thread is busy.");
			throw error;
		}
		return { disposition: busy ? ("queued" as const) : ("started" as const) };
	}

	async abort(): Promise<void> {
		await this.root.abort(ctx);
	}

	async close(): Promise<void> {
		await this.stream?.stop();
		await this.harness.close(ctx);
	}
}
