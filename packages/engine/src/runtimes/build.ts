/** Build runtime: one pi-coding-agent SDK session, persisted as a pi CLI-compatible JSONL file. */
import { createAgentSession, DefaultResourceLoader, getAgentDir, SessionManager, SettingsManager, type AgentSession } from "@earendil-works/pi-coding-agent";
import { approvalsExtension, checkpointsExtension, notifyExtension, planExtension, subagentsExtension, todosExtension, type ApprovalMode, type Rule, type SubagentBridge } from "@piopio/pi-extensions";
import type { ApprovalRule, CheckpointItem, ContainerRef, FileChange, ModelRef, PromptResponse, Snapshot } from "@piopio/protocol";
import type { CheckpointStore } from "../checkpoints.js";
import { EngineError, type ModelHub } from "../models.js";
import { contentText, TimelineBuilder, type PiContentBlock, type PiMessage } from "../timeline/builder.js";
import { SdkEventMapper } from "../timeline/pi-sdk.js";
import { PromptBroker, uiBridge } from "./prompts.js";
import { recorder } from "./recorder.js";
import { Emitter, type Runtime, type SubmitOptions } from "./runtime.js";

/** pi session entry type for checkpoints (kept in the session file, not sent to the model). */
const CHECKPOINT_ENTRY = "piopio.checkpoint";

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
	/** Shadow-git snapshots of the working tree (docs/spec/05-build §7). */
	checkpoints: CheckpointStore;
	/** The session needs the user (a new prompt) or told them something (notify_user). */
	onAttention?: (kind: "waiting" | "notify", message: string) => void;
	/** Plan mode (piopio-plan), kept by the catalog so it survives a reopen. */
	plan: { active(): boolean; setActive(on: boolean): void };
	/** Runs `task` subagents as child sessions; absent for the children themselves (one level deep). */
	runTask?: SubagentBridge["run"];
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
		private readonly cwd: string,
		private readonly checkpoints: CheckpointStore,
		private readonly plan: BuildOpenOptions["plan"],
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
				// First, so the snapshot is taken before anything else can change files.
				checkpointsExtension({ snapshot: async (callId) => void (await runtime?.takeCheckpoint(callId)) }),
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
				todosExtension(),
				planExtension({
					active: o.plan.active,
					setActive: (on) => {
						o.plan.setActive(on);
						runtime?.planChanged();
					},
					propose: async (plan, signal) => {
						const response = await broker.ask({ kind: "plan", title: plan.summary, steps: plan.steps, callId: plan.callId }, signal);
						if (!response) return undefined;
						return { approved: response.decision === "allow" || response.decision === "always", ...(response.text ? { note: response.text } : {}) };
					},
				}),
				subagentsExtension(o.runTask ? { run: o.runTask } : undefined),
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
		runtime = new BuildRuntime(o.ref, o.hub, session, o.model, broker, o.approvals.mode, o.cwd, o.checkpoints, o.plan);
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

	// ── Checkpoints (docs/spec/05-build §7) ────────────────────────────────

	/**
	 * Snapshots the working tree, records it in the pi session file (a custom entry, not sent to the model)
	 * and shows it before the tool call it precedes.
	 */
	async takeCheckpoint(beforeCallId?: string, label?: string): Promise<CheckpointItem> {
		const previous = this.builder.checkpoints();
		const turns = (this.session.messages as PiMessage[]).filter((m) => m.role === "user").length;
		const name = label ?? (previous.length === 0 ? "Session start" : `Before turn ${turns}`);
		const snapshot = await this.checkpoints.snapshot(this.cwd, name);
		const item: CheckpointItem = {
			kind: "checkpoint",
			id: `cp:${snapshot.id.slice(0, 12)}:${Date.now().toString(36)}`,
			at: new Date().toISOString(),
			checkpointId: snapshot.id,
			label: name,
			...(previous.length > 0 ? { files: snapshot.files } : {}),
		};
		this.session.sessionManager.appendCustomEntry(CHECKPOINT_ENTRY, { ...item, ...(beforeCallId ? { beforeCallId } : {}) });
		this.builder.checkpoint(item, beforeCallId ? `tool:${beforeCallId}` : undefined);
		this.emitter.emit(this.builder.flush());
		return item;
	}

	/** Files that differ from the session's first checkpoint, or from the latest one. */
	async changes(since: "session" | "turn"): Promise<{ base?: string; files: FileChange[] }> {
		const base = this.base(since);
		return base ? { base, files: await this.checkpoints.changes(this.cwd, base) } : { files: [] };
	}

	async diff(path: string, since: "session" | "turn"): Promise<string> {
		const base = this.base(since);
		return base ? this.checkpoints.diff(this.cwd, base, path) : "";
	}

	/**
	 * Puts files back as they were at a checkpoint. The current state is checkpointed first ("Before restore"),
	 * and the agent gets a note listing what changed, so it re-reads those files.
	 */
	async restore(checkpointId: string, paths: string[] | undefined, dryRun: boolean): Promise<FileChange[]> {
		if (dryRun) {
			const files = await this.checkpoints.changes(this.cwd, checkpointId);
			return paths ? files.filter((f) => paths.includes(f.path)) : files;
		}
		if (this.session.isStreaming) throw new EngineError("BUSY", "Stop the agent before restoring files.");
		const target = this.builder.checkpoints().find((c) => c.checkpointId === checkpointId);
		await this.takeCheckpoint(undefined, "Before restore");
		const files = await this.checkpoints.restore(this.cwd, checkpointId, paths);
		if (files.length > 0) {
			const where = target ? `“${target.label}”` : "an earlier checkpoint";
			const list = files.map((f) => `- ${f.path} (${f.status === "added" ? "removed again" : f.status === "deleted" ? "brought back" : "reverted"})`).join("\n");
			await this.session.sendCustomMessage({
				customType: "piopio.restore",
				content: `The user restored ${paths ? "some files" : "the project"} to ${where}. These files changed on disk; re-read them before editing:\n${list}`,
				display: true,
				details: { summary: `Restored ${files.length === 1 ? files[0]!.path : `${files.length} files`} to ${where}. The agent was told.` },
			});
		}
		return files;
	}

	private base(since: "session" | "turn"): string | undefined {
		const all = this.builder.checkpoints();
		return (since === "session" ? all[0] : all.at(-1))?.checkpointId;
	}

	private mapper!: SdkEventMapper;

	/**
	 * Rebuilds the timeline from the session (pi messages plus Piopio's checkpoint entries). Also after a
	 * compaction or a jump in the session tree, when the messages change under the live numbering.
	 */
	private rebuild(emit: boolean): void {
		const messages = this.session.messages as unknown as PiMessage[];
		this.builder.reset(messages, (i) => SdkEventMapper.idOf(i), false);
		for (const entry of this.session.sessionManager.getBranch()) {
			if (entry.type !== "custom" || entry.customType !== CHECKPOINT_ENTRY) continue;
			const { beforeCallId, ...item } = entry.data as CheckpointItem & { beforeCallId?: string };
			this.builder.checkpoint(item, beforeCallId ? `tool:${beforeCallId}` : this.builder.firstAfter(item.at), false);
		}
		this.builder.setState({ model: this.model, thinking: this.session.thinkingLevel, approvalMode: this.approvalMode(), planMode: this.plan.active(), prompts: this.broker.list(), ...this.context() });
		this.mapper = new SdkEventMapper(this.builder, messages.length);
		if (emit) {
			this.builder.flush();
			this.builder.resnapshot();
			this.emitter.emit(this.builder.flush());
		}
	}

	planChanged(): void {
		this.builder.setState({ planMode: this.plan.active() });
		this.emitter.emit(this.builder.flush());
	}

	private attach(): void {
		this.rebuild(false);
		this.builder.flush();
		// Waiting on the user: the session shows "waiting for you" and an approval's tool card waits too.
		this.broker.onChange = (prompts, changed, added) => {
			if (changed.kind === "approval" && changed.callId) this.builder.toolStatus(changed.callId, added ? "pending_approval" : "running");
			const status = prompts.length > 0 ? "waiting_approval" : this.session.isStreaming ? "running" : this.builder.status === "waiting_approval" ? "running" : this.builder.status;
			this.builder.setState({ prompts, status });
			this.emitter.emit(this.builder.flush());
		};
		const record = recorder("pi-sdk", this.ref.id);
		this.unsubscribe = this.session.subscribe((event) => {
			record?.(event);
			this.mapper.apply(event as never);
			if (event.type === "message_end" || event.type === "agent_settled") this.builder.setState(this.context());
			this.emitter.emit(this.builder.flush());
			// Compaction replaces older messages with a summary: renumber from the session.
			if (event.type === "compaction_end") this.rebuild(true);
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

	async configure(change: { model?: ModelRef; thinking?: string; approvalMode?: ApprovalMode; planMode?: boolean }): Promise<void> {
		if (change.planMode !== undefined) this.plan.setActive(change.planMode);
		if (change.model) {
			const model = (await this.hub.buildRuntime()).getModel(change.model.provider, change.model.id);
			if (!model) throw new EngineError("INVALID", `Unknown model ${change.model.provider}/${change.model.id}`);
			await this.session.setModel(model);
			this.model = change.model;
		}
		if (change.thinking) this.session.setThinkingLevel(change.thinking as never);
		this.builder.setState({ model: this.model, thinking: this.session.thinkingLevel, approvalMode: this.approvalMode(), planMode: this.plan.active(), ...this.context() });
		this.emitter.emit(this.builder.flush());
	}

	// ── Composer and tree (docs/spec/05-build BR5, BR6) ─────────────────────

	/** pi prompt templates, skills and extension commands, for `/`. */
	commands(): { name: string; description: string; kind: "template" | "skill" | "extension"; hint?: string }[] {
		const templates = this.session.promptTemplates.map((t) => ({ name: t.name, description: t.description, kind: "template" as const, ...(t.argumentHint ? { hint: t.argumentHint } : {}) }));
		const skills = this.session.resourceLoader.getSkills().skills.map((s) => ({ name: `skill:${s.name}`, description: s.description, kind: "skill" as const }));
		const extensions = this.session.extensionRunner.getRegisteredCommands().map((c) => ({ name: c.invocationName, description: (c as { description?: string }).description ?? "", kind: "extension" as const }));
		return [...templates, ...skills, ...extensions].sort((a, b) => a.name.localeCompare(b.name));
	}

	/** Your messages in pi's session tree; `depth` grows at each branch point. */
	tree(): { entryId: string; text: string; at: string; depth: number; current: boolean; branches: number }[] {
		const onPath = new Set(this.session.sessionManager.getBranch().map((e) => e.id));
		const out: { entryId: string; text: string; at: string; depth: number; current: boolean; branches: number }[] = [];
		type Node = ReturnType<AgentSession["sessionManager"]["getTree"]>[number];
		const walk = (nodes: readonly Node[], depth: number) => {
			const nested = nodes.length > 1 ? depth + 1 : depth;
			for (const node of nodes) {
				const entry = node.entry as { id: string; type: string; timestamp?: string; message?: PiMessage };
				if (entry.type === "message" && entry.message?.role === "user") {
					const text = contentText((entry.message as { content: string | PiContentBlock[] }).content).replace(/\s+/g, " ").trim();
					out.push({ entryId: entry.id, text: text.slice(0, 140), at: entry.timestamp ?? "", depth: nested, current: onPath.has(entry.id), branches: node.children.length });
				}
				walk(node.children, nested);
			}
		};
		walk(this.session.sessionManager.getTree(), 0);
		return out;
	}

	/** Moves to another point of the tree (pi's /tree). Returns the message's text when it's one of yours. */
	async navigate(entryId: string): Promise<{ editorText?: string }> {
		if (this.session.isStreaming) throw new EngineError("BUSY", "Stop the agent before moving in the tree.");
		const result = await this.session.navigateTree(entryId);
		this.rebuild(true);
		return result.editorText ? { editorText: result.editorText } : {};
	}

	async compact(): Promise<void> {
		if (this.session.isStreaming) throw new EngineError("BUSY", "Wait for the agent to finish before compacting.");
		await this.session.compact();
		this.rebuild(true);
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
