/** Build runtime: one pi-coding-agent SDK session, persisted as a pi CLI-compatible JSONL file. */
import { createAgentSession, DefaultResourceLoader, getAgentDir, SessionManager, SettingsManager, type AgentSession } from "@earendil-works/pi-coding-agent";
import { approvalsExtension, notifyExtension, type ApprovalMode, type Rule } from "@piopio/pi-extensions";
import type { ApprovalRule, ContainerRef, ModelRef, PromptResponse, Snapshot } from "@piopio/protocol";
import { EngineError, type ModelHub } from "../models.js";
import { TimelineBuilder, type PiMessage } from "../timeline/builder.js";
import { SdkEventMapper } from "../timeline/pi-sdk.js";
import { PromptBroker, uiBridge } from "./prompts.js";
import { recorder } from "./recorder.js";
import { Emitter, type Runtime, type SubmitOptions } from "./runtime.js";

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
	/** Approval mode and the project's rules, read on every tool call (they can change mid-session). */
	approvals: { mode(): ApprovalMode; rules(): readonly ApprovalRule[]; addRule(rule: Rule): void };
	/** The session needs the user (a new prompt) or told them something (notify_user). */
	onAttention?: (kind: "waiting" | "notify", message: string) => void;
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
		private readonly broker: PromptBroker,
		private readonly approvalMode: () => ApprovalMode,
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
		// Piopio's extensions (approvals, notify) join the user's and the project's, discovered as in the CLI.
		const broker = new PromptBroker();
		let runtime: BuildRuntime | undefined;
		const agentDir = o.piAgentDir ?? getAgentDir();
		const settingsManager = SettingsManager.create(o.cwd, agentDir);
		const resourceLoader = new DefaultResourceLoader({
			cwd: o.cwd,
			agentDir,
			settingsManager,
			extensionFactories: [
				approvalsExtension({
					mode: o.approvals.mode,
					rules: () => o.approvals.rules().map(({ kind, pattern }) => ({ kind, pattern })),
					addRule: o.approvals.addRule,
					ask: async (request, signal) => {
						const response = await broker.ask(
							{
								kind: "approval",
								title: request.title,
								detail: request.detail,
								tool: request.tool,
								callId: request.callId,
								...(request.reason ? { reason: request.reason } : {}),
								...(request.rule ? { rule: request.rule } : {}),
							},
							signal,
						);
						if (!response) return { decision: "deny", note: "the run was stopped" };
						return { decision: response.decision ?? "deny", ...(response.text ? { note: response.text } : {}) };
					},
				}),
				notifyExtension({
					ask: async (question, signal) => {
						const response = await broker.ask({ kind: "question", title: question.question, callId: question.callId, ...(question.options ? { options: question.options } : {}) }, signal);
						return response?.choice ?? response?.text;
					},
					notify: (message) => {
						runtime?.note("info", message);
						o.onAttention?.("notify", message);
					},
				}),
			],
		});
		await resourceLoader.reload();
		const { session } = await createAgentSession({
			cwd: o.cwd,
			agentDir,
			model,
			modelRuntime,
			sessionManager,
			settingsManager,
			resourceLoader,
			...(o.thinking ? { thinkingLevel: o.thinking as never } : {}),
		});
		runtime = new BuildRuntime(o.ref, o.hub, session, o.model, broker, o.approvals.mode);
		broker.onAdded = (prompt) => o.onAttention?.("waiting", prompt.detail ? `${prompt.title}: ${prompt.detail}` : prompt.title);
		const bound = runtime;
		await session.bindExtensions({ mode: "rpc", uiContext: uiBridge(broker, (level, text) => bound.note(level, text)) });
		runtime.attach();
		return runtime;
	}

	/** A note in the transcript (notify_user, extension notifications). */
	note(level: "info" | "warn" | "error", text: string): void {
		this.builder.system(`sys:${Date.now()}:${Math.random().toString(36).slice(2, 6)}`, level, text);
		this.emitter.emit(this.builder.flush());
	}

	respond(promptId: string, response: PromptResponse): void {
		this.broker.respond(promptId, response);
	}

	private attach(): void {
		const messages = this.session.messages as unknown as PiMessage[];
		this.builder.reset(messages, (i) => SdkEventMapper.idOf(i), false);
		this.builder.setState({ model: this.model, thinking: this.session.thinkingLevel, approvalMode: this.approvalMode(), prompts: [], ...this.context() });
		this.builder.flush();
		// Waiting on the user: the session shows "waiting for you" and an approval's tool card waits too.
		this.broker.onChange = (prompts, changed, added) => {
			if (changed.kind === "approval" && changed.callId) this.builder.toolStatus(changed.callId, added ? "pending_approval" : "running");
			const status = prompts.length > 0 ? "waiting_approval" : this.session.isStreaming ? "running" : this.builder.status === "waiting_approval" ? "running" : this.builder.status;
			this.builder.setState({ prompts, status });
			this.emitter.emit(this.builder.flush());
		};
		const mapper = new SdkEventMapper(this.builder, messages.length);
		const record = recorder("pi-sdk", this.ref.id);
		this.unsubscribe = this.session.subscribe((event) => {
			record?.(event);
			mapper.apply(event as never);
			if (event.type === "message_end" || event.type === "agent_settled" || event.type === "compaction_end") this.builder.setState(this.context());
			this.emitter.emit(this.builder.flush());
		});
	}

	/** The context meter (BR7): tokens in the model's context window. */
	private context(): { context?: { tokens: number | null; window: number } } {
		const usage = this.session.getContextUsage();
		return usage ? { context: { tokens: usage.tokens, window: usage.contextWindow } } : {};
	}

	snapshot(): Snapshot {
		return this.builder.snapshot();
	}

	onEvents(listener: Parameters<Runtime["onEvents"]>[0]): () => void {
		return this.emitter.on(listener);
	}

	async submit(text: string, options: SubmitOptions) {
		if (options.attachments?.length) throw new EngineError("INVALID", "Build sessions don't take attachments yet; mention files with @ instead.");
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
		this.broker.cancelAll();
		await this.session.abort();
	}

	async configure(change: { model?: ModelRef; thinking?: string; approvalMode?: ApprovalMode }): Promise<void> {
		if (change.model) {
			const model = (await this.hub.buildRuntime()).getModel(change.model.provider, change.model.id);
			if (!model) throw new EngineError("INVALID", `Unknown model ${change.model.provider}/${change.model.id}`);
			await this.session.setModel(model);
			this.model = change.model;
		}
		if (change.thinking) this.session.setThinkingLevel(change.thinking as never);
		this.builder.setState({ model: this.model, thinking: this.session.thinkingLevel, approvalMode: this.approvalMode(), ...this.context() });
		this.emitter.emit(this.builder.flush());
	}

	async clearQueue(): Promise<void> {
		this.session.clearQueue();
	}

	async close(): Promise<void> {
		this.broker.cancelAll();
		this.unsubscribe?.();
		this.session.dispose();
	}
}
