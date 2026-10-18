/** Build runtime: one pi-coding-agent SDK session, persisted as a pi CLI-compatible JSONL file. */
import { createAgentSession, SessionManager, type AgentSession } from "@earendil-works/pi-coding-agent";
import type { ContainerRef, ModelRef, Snapshot } from "@piopio/protocol";
import { EngineError, type ModelHub } from "../models.js";
import { TimelineBuilder, type PiMessage } from "../timeline/builder.js";
import { SdkEventMapper } from "../timeline/pi-sdk.js";
import { recorder } from "./recorder.js";
import { Emitter, type Runtime, type WhenBusy } from "./runtime.js";

export type BuildOpenOptions = {
	ref: ContainerRef;
	hub: ModelHub;
	cwd: string;
	model: ModelRef;
	thinking?: string;
	/** Existing session file to resume; a new one is created when absent. */
	sessionFile?: string;
	/** Overrides pi's session directory (tests); default is pi's own (~/.pi/agent/sessions). */
	piSessionDir?: string;
	/** Overrides pi's agent dir (tests); default ~/.pi/agent. */
	piAgentDir?: string;
};

export class BuildRuntime implements Runtime {
	private readonly emitter = new Emitter();
	private readonly builder: TimelineBuilder;
	private unsubscribe?: () => void;

	private constructor(
		readonly ref: ContainerRef,
		private readonly hub: ModelHub,
		private readonly session: AgentSession,
		private model: ModelRef,
	) {
		this.builder = new TimelineBuilder(ref);
	}

	get sessionFile(): string | undefined {
		return this.session.sessionFile;
	}

	static async open(o: BuildOpenOptions): Promise<BuildRuntime> {
		await o.hub.ensureCredential(o.model.provider);
		const modelRuntime = await o.hub.buildRuntime();
		const model = modelRuntime.getModel(o.model.provider, o.model.id);
		if (!model) throw new EngineError("INVALID", `Unknown model ${o.model.provider}/${o.model.id}`);
		const sessionManager = o.sessionFile ? SessionManager.open(o.sessionFile) : SessionManager.create(o.cwd, o.piSessionDir);
		const { session } = await createAgentSession({
			cwd: o.cwd,
			...(o.piAgentDir ? { agentDir: o.piAgentDir } : {}),
			model,
			modelRuntime,
			sessionManager,
			...(o.thinking ? { thinkingLevel: o.thinking as never } : {}),
		});
		const runtime = new BuildRuntime(o.ref, o.hub, session, o.model);
		runtime.attach();
		return runtime;
	}

	private attach(): void {
		const messages = this.session.messages as unknown as PiMessage[];
		this.builder.reset(messages, (i) => SdkEventMapper.idOf(i), false);
		this.builder.setState({ model: this.model, thinking: this.session.thinkingLevel });
		this.builder.flush();
		const mapper = new SdkEventMapper(this.builder, messages.length);
		const record = recorder("pi-sdk", this.ref.id);
		this.unsubscribe = this.session.subscribe((event) => {
			record?.(event);
			mapper.apply(event as never);
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
		if (this.session.isStreaming) {
			if (options.whenBusy === "reject") throw new EngineError("BUSY", "The session is busy.");
			if (options.whenBusy === "steer") await this.session.steer(text);
			else await this.session.followUp(text);
			return { disposition: "queued" as const };
		}
		// prompt() resolves when the run settles; progress arrives through events.
		this.session.prompt(text).catch((error: unknown) => {
			this.builder.system(`sys:${Date.now()}`, "error", error instanceof Error ? error.message : String(error));
			this.builder.setState({ status: "idle" });
			this.emitter.emit(this.builder.flush());
		});
		return { disposition: "started" as const };
	}

	async abort(): Promise<void> {
		await this.session.abort();
	}

	async configure(change: { model?: ModelRef; thinking?: string }): Promise<void> {
		if (change.model) {
			const model = (await this.hub.buildRuntime()).getModel(change.model.provider, change.model.id);
			if (!model) throw new EngineError("INVALID", `Unknown model ${change.model.provider}/${change.model.id}`);
			await this.session.setModel(model);
			this.model = change.model;
		}
		if (change.thinking) this.session.setThinkingLevel(change.thinking as never);
		this.builder.setState({ model: this.model, thinking: this.session.thinkingLevel });
		this.emitter.emit(this.builder.flush());
	}

	async close(): Promise<void> {
		this.unsubscribe?.();
		this.session.dispose();
	}
}
