/** Build runtime: one pi-coding-agent SDK session, persisted as a pi CLI-compatible JSONL file. */
import { codingConnectorsExtension } from "../connectors/extension.js";
import { codingBrowserExtension, type BrowserCall } from "../tools/browser-tools.js";
import { codingVisualsExtension, type VisualCheck } from "../tools/visuals.js";
import { codingAppsExtension } from "../tools/apps-tool.js";
import type { Apps, MakeContext } from "../apps.js";
import { groupOf } from "../connectors/permissions.js";
import type { ConnectorHub } from "../connectors/hub.js";
import {
	createAgentSession,
	createCodemodeExtension,
	createMcpExtension,
	createToolSearchExtension,
	DefaultResourceLoader,
	getAgentDir,
	ProjectTrustStore,
	SessionManager,
	SettingsManager,
	type AgentSession,
	type ExtensionFactory,
} from "@earendil-works/pi-coding-agent";
import { backgroundExtension, confine, diagnosticsExtension, ProcessManager, proxyEnv, sandboxProfile, sandboxUnavailable, type BackgroundProcess, type FilteredNetwork, type PlanHandle } from "@piopio/pi-extensions";
import { NetworkFilter } from "../network-filter.js";
import { codeReviewExtension, type ReviewBridge } from "../code-review.js";
import { approvalsExtension, checkpointsExtension, goalExtension, notifyExtension, planExtension, presentExtension, sandboxExtension, subagentsExtension, todosExtension, type ApprovalMode, type Question, type Rule, type SubagentBridge, type Verdict } from "@piopio/pi-extensions";
import type { ApprovalItem, ApprovalRule, BranchInfo, CheckpointItem, ContainerRef, FileChange, ModelRef, PromptResponse, SessionState, Snapshot, Usage } from "@piopio/protocol";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import type { CheckpointStore } from "../checkpoints.js";
import { EngineError, type ModelHub } from "../models.js";
import { contentText, TimelineBuilder, type PiContentBlock, type PiMessage, type ToolImageKeeper } from "@piopio/runtime";
import { sdkMessages, SdkEventMapper } from "../timeline/pi-sdk.js";
import { chatPromptExtension } from "../tools/chat-prompt.js";
import { sdkAsSent, sdkContent, sdkUser, sdkWithWords, TYPED_ENTRY, type ContentBlock, type SdkInput } from "../input.js";
import { chatProfileExtension, READ_ONLY_OFF, READ_ONLY_ON, WEB_TOOLS } from "../tools/chat-profile.js";
import { skillSource } from "../tools/chat-resources.js";
import type { WebOptions } from "../tools/web.js";
import { buildPromptExtension } from "../tools/build-prompt.js";
import { boardExtension, type BoardBridge } from "../work/extension.js";
import { sideExtension, type SideBridge } from "../tools/side.js";
import { automationsExtension, type PiopioAutomationsBridge } from "../automations/tools.js";
import { consultExtension, type ConsultBridge } from "../consult.js";
import { offersExtension, type OffersBridge } from "../offers.js";
import { guardsExtension } from "../tools/guards.js";
import { CONVERSATION_MIME, formatConversation, historySdkExtension, type HistoryBridge } from "../tools/history.js";
import { learnSdkExtension, type LearnBridge } from "../tools/learn.js";
import { withPiopioPrompts } from "./piopio-commands.js";
import { PromptBroker, uiBridge } from "./prompts.js";
import { ContextBreakdown } from "./context-breakdown.js";
import { recorder } from "./recorder.js";
import { Emitter, type Runtime, type SubmitOptions } from "./runtime.js";
import { promptSection, promptToolsExtension, type PromptEvent } from "../tools/prompt-sections.js";

type Input = SdkInput;

/**
 * A conversation without a project (docs/spec/18; one engine for conversations since 2026-11-15): a pi SDK session in
 * a folder of its own, with a chat's tools (the web, connected apps, MCP servers, the browser, About me) and none of a
 * folder conversation's: no files, commands, plans or approval modes. A connector change or a browser action asks with
 * a card in the transcript, as chats always did.
 */
export type ChatProfile = {
	/** The web tools, on or off for this conversation. */
	web: () => boolean;
	setWeb: (on: boolean) => void;
	/** More extensions: About me. */
	extensions?: ExtensionFactory[];
};

/** pi session entry type for checkpoints (kept in the session file, not sent to the model). */
const CHECKPOINT_ENTRY = "piopio.checkpoint";
/** pi session entry type for auto review's reason on a command it let run (shown on the command's card). */
const REVIEW_ENTRY = "piopio.review";

export type BuildOpenOptions = {
	/** A chat rather than a folder conversation (see ChatProfile). */
	chat?: ChatProfile;
	/** Keeps images that tools return (screenshots it read) for the transcript (attachment-files.ts). */
	keepImages?: ToolImageKeeper;
	/** The browser's tools (docs/spec/22), run by the Mac app for this session. */
	browser?: BrowserCall;
	/** The check after the agent's edits (05-build "Diagnostics"): the command for this folder, or undefined for none. */
	checkCommand?: (cwd: string) => string | undefined;
	/** A Build session in a project: the browser has the project preview (docs/spec/22 §6). */
	browserPreview?: boolean;
	/** Visuals drawn and checked by the Mac app (docs/spec/25 §3.2). */
	visuals?: VisualCheck;
	/** make_app (docs/spec/35 §14): the apps service, and where this conversation is. */
	apps?: { service: Apps; where: () => MakeContext };
	/** Connected apps: their tools, asking through Build's approval prompt before a change. */
	connectors?: ConnectorHub;
	/** Connectors and MCP servers this session turned off ("connector:<id>", "mcp:<server>"). */
	toolsOff?: () => string[];
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
	/**
	 * The project's network (docs/spec/39): filtered until it's trusted, read on every command; the sites it may reach
	 * besides the built-in ones, and how one becomes such a site (Always).
	 */
	network?: { filtered(): boolean; rules(): readonly string[]; addRule(pattern: string): void };
	/** Folders linked to the project (docs/spec/18 §18), read on every turn. */
	folders?: () => readonly { path: string; edit: boolean }[];
	/** Shadow-git snapshots of the working tree (docs/spec/05-build §7). */
	checkpoints: CheckpointStore;
	/** The session needs the user (a new prompt) or told them something (notify_user). */
	onAttention?: (kind: "waiting" | "notify", message: string) => void;
	/** Plan mode (piopio-plan), kept by the catalog so it survives a reopen. */
	/** What plan mode starts as where the session's file doesn't say (the extension keeps it there, plan.ts). */
	plan: { initial(): boolean };
	webOptions?: WebOptions;
	/** Where project trust is looked up (the project folder; differs from `cwd` for worktree sessions). */
	trustPath?: string;
	/** Auto review (Settings › Approvals): judges a command before you're asked; undefined when it's off or unsure. */
	review?: (command: string, request: string | undefined, signal: AbortSignal | undefined) => Promise<Verdict | undefined>;
	/** The project's other sessions, for search_conversations / read_conversation (tools/history.ts). */
	history?: HistoryBridge;
	/** /learn's card (tools/learn.ts, docs/spec/14 M5): where rules go, and whether About me takes facts. */
	learn?: LearnBridge;
	/** Shell commands run in macOS's sandbox (piopio-sandbox); read on every command. Default on. */
	sandbox?: () => boolean;
	/** Claude Code / Codex CLIs a task can go to (external-agents.ts). */
	externalAgents?: readonly string[];
	/** Runs `task` subagents as child sessions; absent for the children themselves (one level deep). */
	runTask?: SubagentBridge["run"];
	/** Non-blocking `task`, `task_wait` and `task_stop` (docs/spec/17 §3). */
	tasks?: Required<Pick<SubagentBridge, "start" | "wait" | "stop">>;
	/** The board's tools: Piopio's in a project with parallel work on, or a reviewer helper's verdict (docs/spec/26). */
	board?: BoardBridge;
	/** A review by an agent (05-build "Review by an agent"): this session reports its findings with report_findings. */
	codeReview?: ReviewBridge;
	/** Your agents, asked from this conversation with ask_agent or @Name (docs/spec/21 D6). */
	consult?: { bridge: ConsultBridge; from: () => string };
	/** Piopio's offers in a project: parallel work for divisible work, an agent or a routine for repeated work. */
	offers?: OffersBridge;
	/** Side conversations (docs/spec/24): your conversations, not a helper's or a subagent's. */
	side?: SideBridge;
	/** Automations (docs/spec/27 AU4): Piopio makes them by asking, in your conversations. */
	automations?: PiopioAutomationsBridge;
};

export class BuildRuntime implements Runtime {
	private readonly emitter = new Emitter();
	private readonly builder: TimelineBuilder;
	private readonly contextBreakdown: ContextBreakdown;
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
		private readonly plan: PlanHandle,
		private readonly chat?: ChatProfile,
	) {
		this.builder = new TimelineBuilder(ref);
		// A branched chat has its own copy of the source chat's folder: its cards open the copy (chatsFolderCopy).
		if (chat) this.builder.relocate = chatRelocate(cwd);
		this.contextBreakdown = new ContextBreakdown(session);
	}

	get sessionFile(): string | undefined {
		return this.session.sessionFile;
	}

	private pendingName?: string;

	/**
	 * The conversation's title, kept in pi's session too (its own name entry, what `/name` writes), so pi's CLI shows
	 * the same one and a later sync from the file agrees. While the agent works it waits for the run to end: the entry
	 * goes at the tip of the session.
	 */
	name(title: string): void {
		this.pendingName = undefined;
		if (!title || this.session.sessionName === title) return;
		if (this.session.isStreaming) this.pendingName = title;
		else this.session.setSessionName(title);
	}

	static async open(o: BuildOpenOptions): Promise<BuildRuntime> {
		await o.hub.ensureCredential(o.model.provider);
		const modelRuntime = await o.hub.buildRuntime();
		const model = modelRuntime.getModel(o.model.provider, o.model.id);
		if (!model) throw new EngineError("INVALID", `Unknown model ${o.model.provider}/${o.model.id}`);
		const sessionManager = o.sessionFile ? SessionManager.open(o.sessionFile) : SessionManager.create(o.cwd, o.piSessionDir);
		// Piopio's extensions (approvals, notify) join the user's and the project's, discovered as in the CLI.
		const broker = new PromptBroker();
		// Commands the agent leaves running (05-build §9 TM4).
		const processes = new ProcessManager();
		let runtime: BuildRuntime | undefined;
		let planHandle: PlanHandle | undefined;
		const agentDir = o.piAgentDir ?? getAgentDir();
		const settingsManager = SettingsManager.create(o.cwd, agentDir);
		// A filtered network's proxy (docs/spec/39), the session's own, started the first time a command needs it.
		let filter: NetworkFilter | undefined;
		let filterPort: number | undefined;
		const network = async (): Promise<FilteredNetwork | undefined> => {
			if (!o.network?.filtered()) return undefined;
			const net = o.network;
			filter ??= new NetworkFilter({
				rules: () => net.rules(),
				addRule: (pattern) => net.addRule(pattern),
				ask: async (host) => {
					const r = await broker.ask({
						kind: "approval",
						title: `Let this project's commands reach ${host}`,
						tool: "network",
						detail: host,
						reason: "This project isn't trusted yet, so its commands reach only package registries, GitHub and the sites you allow.",
						rule: { kind: "host", pattern: host },
					});
					return r?.decision === "always" ? "always" : r?.decision === "allow" ? "once" : r ? "deny" : undefined;
				},
			});
			filterPort = await filter.start();
			return { port: filterPort, refusedSince: (at) => filter!.refusedSince(at) };
		};
		// Started now when it's filtered, so the check after edits (which can't wait) finds it running.
		if (o.network?.filtered()) await network().catch(() => undefined);
		const resourceLoader = new DefaultResourceLoader({
			cwd: o.cwd,
			agentDir,
			settingsManager,
			// Piopio's /automation, /grill-me and /browser (docs/spec/32 CM3).
			promptsOverride: (base) => ({ ...base, prompts: withPiopioPrompts(base.prompts, { browser: Boolean(o.browser), automations: Boolean(o.automations), learn: Boolean(o.learn), project: Boolean(o.learn?.project()) }) }),
			extensionFactories: o.chat ? chatFactories(o, broker, () => runtime) : [
				// The pi CLI's built-ins (MCP servers, and codemode / tool search through which MCP tools are
				// reached). Replaceable: a user extension that registers the same tools or /mcp takes over.
				...piBuiltins(),
				// First, so the snapshot is taken before anything else can change files.
				checkpointsExtension({ snapshot: async (callId) => void (await runtime?.takeCheckpoint(callId)) }),
				// Piopio's preamble and guidelines in place of pi's (pi's named sections), before the others' sections.
				buildPromptExtension(),
				// Before approvals: a server turned off here is refused without asking.
				...(o.toolsOff ? [mcpOffExtension(o.toolsOff)] : []),
				notesExtension(o.cwd),
				...(o.folders ? [linkedFoldersExtension(o.folders)] : []),
				...(o.browser
					? [
							codingBrowserExtension(o.browser, (callId, signal) => async (request) => {
								const response = await broker.ask({ kind: "approval", title: request.title, tool: request.tool, callId }, signal);
								return { approved: response?.decision === "allow" || response?.decision === "always", ...(response?.decision === "always" ? { always: true } : {}), ...(response?.text ? { reason: response.text } : {}) };
							}, Boolean(o.browserPreview)),
						]
					: []),
				guardsExtension(),
				...(o.board ? [boardExtension(o.board)] : []),
				...(o.codeReview ? [codeReviewExtension(o.codeReview)] : []),
				...(o.consult ? [consultExtension(o.consult.bridge, o.consult.from)] : []),
				...(o.offers ? [offersExtension(o.offers)] : []),
				// Full access runs commands as before; otherwise they write only inside the project.
				sandboxExtension(
					{
						enabled: () => (o.sandbox?.() ?? true) && o.approvals.mode() !== "full_auto",
						// Linked folders that can be edited are writable like the project's own (18 §18).
						extraRoots: () => (o.folders?.() ?? []).filter((f) => f.edit).map((f) => f.path),
						network,
					},
					{ shellPath: () => settingsManager.getShellPath(), processes: () => processes },
				),
				backgroundExtension(() => processes),
				approvalsExtension({
					mode: o.approvals.mode,
					// Host rules are the network filter's (docs/spec/39), not a tool's.
					rules: () => o.approvals.rules().flatMap(({ kind, pattern }) => (kind === "host" ? [] : [{ kind, pattern }])),
					addRule: o.approvals.addRule,
					// Connectors' read capabilities (Read only lets them run; their own permissions still apply).
					readOnlyTool: (tool) => groupOf(tool)?.access === "read",
					ask: async (request, signal) => {
						let reason = request.reason;
						// Auto review (extensions review.ts): only a plain command that Auto-edit would ask about.
						if (o.review && o.approvals.mode() === "auto_edit" && request.tool === "bash" && !request.reason && request.input.outside_project !== true) {
							const command = String(request.input.command ?? "");
							const verdict = await o.review(command, runtime?.lastUserText(), signal).catch(() => undefined);
							if (verdict?.verdict === "allow") {
								runtime?.reviewed(request.callId, verdict.reason);
								return { decision: "allow" };
							}
							if (verdict) reason = `Auto review: ${verdict.reason}`;
						}
						const response = await broker.ask(
							{
								kind: "approval",
								title: request.title,
								detail: request.detail,
								tool: request.tool,
								callId: request.callId,
								...(reason ? { reason } : {}),
								...(request.rule ? { rule: request.rule } : {}),
							},
							signal,
						);
						if (!response) return { decision: "deny", note: "the run was stopped" };
						return { decision: response.decision ?? "deny", ...(response.text ? { note: response.text } : {}) };
					},
				}),
				// web_search's cost goes on this conversation, not on "the app" (as an agent's goes on the agent).
				chatProfileExtension(o.hub, { ...o.webOptions, scope: o.ref.id }, () => o.approvals.mode() === "read_only", () => true),
				...(o.connectors
					? [
							codingConnectorsExtension(o.connectors, (callId, signal) => async (request) => {
								const response = await broker.ask({ kind: "approval", title: request.title, tool: request.tool, callId }, signal);
								return { approved: response?.decision === "allow" || response?.decision === "always", ...(response?.decision === "always" && request.canAllowAlways ? { always: true } : {}), ...(response?.text ? { reason: response.text } : {}) };
							}, (id) => o.toolsOff?.().includes(`connector:${id}`) ?? false),
						]
					: []),
				todosExtension(),
				presentExtension(),
				codingVisualsExtension(o.visuals),
				...(o.apps
					? [
							codingAppsExtension(o.apps.service, o.apps.where, (callId, signal) => async (request) => {
								const response = await broker.ask({ kind: "approval", title: request.title, tool: request.tool, callId }, signal);
								return { approved: response?.decision === "allow" || response?.decision === "always", ...(response?.text ? { reason: response.text } : {}) };
							}),
						]
					: []),
				goalExtension(),
				...(o.history && !o.history.off() ? [historySdkExtension(o.history)] : []),
				...(o.learn ? [learnSdkExtension(o.learn)] : []),
				...(o.side ? [sideExtension(o.side)] : []),
				...(o.automations ? [automationsExtension(o.automations)] : []),
				planExtension(
					{
					initial: o.plan.initial,
					changed: () => runtime?.planChanged(),
					propose: async (plan, signal) => {
						const response = await broker.ask({ kind: "plan", title: plan.summary, steps: plan.steps, callId: plan.callId }, signal);
						if (!response) return undefined;
						return {
							approved: response.decision === "allow" || response.decision === "always",
							...(response.text ? { note: response.text } : {}),
							...(response.steps?.length ? { steps: response.steps } : {}),
							...(response.summary ? { summary: response.summary } : {}),
						};
					},
					},
					(handle) => (planHandle = handle),
				),
				// The project's check after the agent's edits, confined like its commands (05-build "Diagnostics"). After
				// approvals and plan mode: it runs the check as a baseline on the first edit's tool_call, and pi stops at
				// the first handler that blocks, so a denied or plan-mode edit never runs the project's scripts
				// (re-audit 2026-11-25 V2). Keep it after every extension that can block an edit.
				...(o.checkCommand
					? [
							diagnosticsExtension({
								command: o.checkCommand,
								shell: () => settingsManager.getShellPath() ?? process.env.SHELL ?? "/bin/sh",
								wrap: (command, cwd) => {
									const confined = (o.sandbox?.() ?? true) && o.approvals.mode() !== "full_auto" && process.platform === "darwin" && !sandboxUnavailable();
									// Filtered like the session's commands: through its proxy, or nowhere outside this Mac.
									const filtered = o.network?.filtered() ?? false;
									return confined ? confine(command, sandboxProfile(cwd, { filtered }), settingsManager.getShellPath() ?? process.env.SHELL ?? "/bin/sh", undefined, filtered && filterPort ? proxyEnv(filterPort) : {}) : command;
								},
							}),
						]
					: []),
				subagentsExtension(o.runTask ? { run: o.runTask, ...(o.tasks ?? {}), ...(o.externalAgents?.length ? { agents: o.externalAgents } : {}) } : undefined),
				notifyExtension(notifyBridge(o, broker, () => runtime)),
				// Last: pi's tools list and rules for Piopio's preamble, from the tools the others turned on.
				promptToolsExtension(),
			],
		});
		// Project trust, as the pi CLI decides it: the closest saved decision (~/.pi/agent/trust.json) for the
		// project or a parent, else trusted only with defaultProjectTrust "always". Untrusted projects don't
		// load their .pi extensions, settings, MCP servers, prompts or skills.
		const trustStore = new ProjectTrustStore(agentDir);
		const projectTrusted = () => {
			for (let dir = o.trustPath ?? o.cwd; ; dir = dirname(dir)) {
				const decision = trustStore.get(dir);
				if (decision !== null) return decision;
				if (dir === dirname(dir)) break;
			}
			return settingsManager.getDefaultProjectTrust() === "always";
		};
		await resourceLoader.reload({ resolveProjectTrust: async () => projectTrusted() });
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
		// The extension holds plan mode (in the session's entries); until it has loaded, what the session starts as.
		const plan: PlanHandle = { active: () => planHandle?.active() ?? o.plan.initial(), setActive: (on) => planHandle?.setActive(on) };
		runtime = new BuildRuntime(o.ref, o.hub, session, o.model, broker, o.approvals.mode, o.cwd, o.checkpoints, plan, o.chat);
		runtime.closeNetwork = () => filter?.close();
		if (!o.chat) runtime.useProcesses(processes);
		if (o.keepImages) runtime.builder.keepImages = o.keepImages;
		runtime.connectors = o.connectors;
		runtime.toolsOff = o.toolsOff;
		if (o.thinking) runtime.thinkingChosen = o.thinking;
		if (o.history) runtime.history = o.history;
		broker.onAdded = (prompt) => o.onAttention?.("waiting", prompt.detail ? `${prompt.title}: ${prompt.detail}` : prompt.title);
		const bound = runtime;
		await session.bindExtensions({ mode: "rpc", uiContext: uiBridge(broker, (level, text) => bound.note(level, text)) });
		runtime.applyMode();
		runtime.attach();
		return runtime;
	}

	private connectors?: ConnectorHub;
	private toolsOff?: () => string[];
	/** The thinking level you picked (a chat shows "default" until then). */
	private thinkingChosen?: string;

	/** What you last asked, for auto review. */
	lastUserText(): string | undefined {
		const last = [...(this.session.messages as PiMessage[])].reverse().find((m) => m.role === "user");
		return last ? contentText((last as { content: string | PiContentBlock[] }).content).trim() || undefined : undefined;
	}

	/** A note in the transcript (notify_user, extension notifications). */
	/** Auto review let a command run: its reason goes on the command's card, and stays in the session file. */
	reviewed(callId: string | undefined, reason: string): void {
		if (!callId) return;
		this.session.sessionManager.appendCustomEntry(REVIEW_ENTRY, { callId, reason });
		this.builder.toolReview(callId, reason);
		this.emitter.emit(this.builder.flush());
	}

	note(level: "info" | "warn" | "error", text: string): void {
		this.builder.system(`sys:${Date.now()}:${Math.random().toString(36).slice(2, 6)}`, level, text);
		this.emitter.emit(this.builder.flush());
	}

	respond(promptId: string, response: PromptResponse): void {
		this.broker.respond(promptId, response);
	}

	// ── A chat's cards (ChatProfile) ────────────────────────────────────────

	private readonly approvals = new Map<string, { item: ApprovalItem; resolve: (answer: { approved: boolean; always?: boolean; reason?: string }) => void }>();

	/** The folders of the skills pi found, which a chat's `read` may open. */
	skillDirs(): string[] {
		return this.session.resourceLoader.getSkills().skills.map((s) => s.baseDir);
	}

	/** A card in the transcript (Allow · Deny · Allow, don't ask again) until answered, or the turn stops. */
	approvalCard(_callId: string, signal: AbortSignal | undefined, request: { tool: string; title: string; args: Record<string, unknown>; always: string }): Promise<{ approved: boolean; always?: boolean; reason?: string }> {
		const id = `conn_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
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
			always: request.always,
			source: "connector",
		};
		return new Promise((resolve) => {
			this.approvals.set(id, { item, resolve });
			this.builder.insert(item);
			this.emitter.emit(this.builder.flush());
			signal?.addEventListener(
				"abort",
				() => {
					this.settle(id, "cancelled");
					resolve({ approved: false, reason: "The turn was stopped." });
				},
				{ once: true },
			);
		});
	}

	private settle(id: string, status: ApprovalItem["status"], reason?: string): void {
		const pending = this.approvals.get(id);
		if (!pending) return;
		this.approvals.delete(id);
		pending.item.status = status;
		if (reason) pending.item.reason = reason;
		this.emitter.emit([{ type: "item.updated", item: structuredClone(pending.item) }]);
	}

	/** The user's answer to a card (`sessions.decide`). */
	async decide(approvalId: string, decision: { approve: boolean; always?: boolean; reason?: string }): Promise<ApprovalItem["status"]> {
		const pending = this.approvals.get(approvalId);
		if (!pending) throw new EngineError("NOT_FOUND", "That request was already answered or has gone.");
		pending.resolve({ approved: decision.approve, ...(decision.always ? { always: true } : {}), ...(decision.reason ? { reason: decision.reason } : {}) });
		this.settle(approvalId, decision.approve ? "approved" : "denied", decision.reason);
		return decision.approve ? "approved" : "denied";
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
		this.builder.reset(sdkMessages(messages), (i) => SdkEventMapper.idOf(i), false);
		for (const entry of this.session.sessionManager.getBranch()) {
			if (entry.type === "custom" && entry.customType === REVIEW_ENTRY) {
				const { callId, reason } = entry.data as { callId: string; reason: string };
				this.builder.toolReview(callId, reason, false);
				continue;
			}
			if (entry.type !== "custom" || entry.customType !== CHECKPOINT_ENTRY) continue;
			const { beforeCallId, ...item } = entry.data as CheckpointItem & { beforeCallId?: string };
			this.builder.checkpoint(item, beforeCallId ? `tool:${beforeCallId}` : this.builder.firstAfter(item.at), false);
		}
		this.showTyped(false);
		this.builder.annotateBranches(this.versions(), false);
		this.builder.setState({ ...this.settings(), prompts: this.broker.list(), ...this.context(), usage: this.usage() });
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
		this.contextBreakdown.observeRequests();
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
			if (event.type === "message_end" || event.type === "agent_settled" || (event.type === "message_start" && event.message.role === "assistant")) {
				this.builder.setState(this.context());
			}
			if (event.type === "message_end" || event.type === "tool_execution_end" || event.type === "agent_settled") this.syncUsage();
			if (event.type === "agent_settled" && this.pendingName) this.name(this.pendingName);
			// A new message of yours may stand beside an earlier version (an edit, a retry): refresh the switchers once
			// pi has written it (after its message_end).
			if ((event.type === "message_start" && (event as { message?: PiMessage }).message?.role !== "user") || event.type === "agent_settled") {
				this.showTyped(true);
				this.builder.annotateBranches(this.versions());
			}
			this.emitter.emit(this.builder.flush());
			// Compaction replaces older messages with a summary: renumber from the session.
			if (event.type === "compaction_end") this.rebuild(true);
		});
	}

	/**
	 * What the session has cost: pi's own stats, which count every entry of the session (also what a compaction
	 * summarized away, another branch of the tree, and the summaries themselves), plus what its subagents cost (their
	 * own sessions; the cost is on each `task` result). The timeline only holds the messages in view, so it can't say.
	 */
	private usage(): Usage {
		const stats = this.session.getSessionStats();
		let tasks = 0;
		for (const entry of this.session.sessionManager.getEntries()) {
			if (entry.type !== "message") continue;
			const m = entry.message as { role: string; toolName?: string; details?: { costUsd?: unknown } };
			if (m.role === "toolResult" && m.toolName === "task" && typeof m.details?.costUsd === "number") tasks += m.details.costUsd;
		}
		return { inputTokens: stats.tokens.input, outputTokens: stats.tokens.output, cacheReadTokens: stats.tokens.cacheRead, cacheWriteTokens: stats.tokens.cacheWrite, costUsd: stats.cost + tasks };
	}

	/** The total follows pi's stats (the builder's own sum only covers what it has seen). */
	private syncUsage(): void {
		const usage = this.usage();
		const shown = this.builder.usage;
		if (JSON.stringify(usage) !== JSON.stringify(shown)) this.builder.setState({ usage });
	}

	/** The context meter (BR7): tokens in the model's context window. */
	private context(): Pick<SessionState, "context"> {
		const usage = this.session.getContextUsage();
		if (!usage) return { context: undefined };
		return { context: {
			tokens: usage.tokens,
			window: usage.contextWindow,
			...(usage.tokens === null ? {} : { breakdown: this.contextBreakdown.read(usage.tokens) }),
		} };
	}

	snapshot(): Snapshot {
		return this.builder.snapshot();
	}

	onEvents(listener: Parameters<Runtime["onEvents"]>[0]): () => void {
		return this.emitter.on(listener);
	}

	/** The project's other sessions (tools/history.ts), for `@conversation:<id>` mentions. */
	history?: HistoryBridge;

	/**
	 * `@conversation:<id>` (the composer's @ list): a bounded, read-only snapshot of that session goes into this one first,
	 * as a displayed note marked as background, and the mention reads as its title. Kept in the session file, so the
	 * model sees the same thing after a reload.
	 */
	private async expandReferences(text: string): Promise<string> {
		const ids = [...new Set([...text.matchAll(/@conversation:([A-Za-z0-9_-]+)/g)].map((m) => m[1]!))];
		if (ids.length === 0 || !this.history) return text;
		let out = text;
		for (const id of ids) {
			const c = await this.history.read(id, "user").catch(() => undefined);
			if (c && c !== "withheld") {
				await this.session.sendCustomMessage({ customType: "piopio.reference", content: formatConversation(id, c), display: true, details: { summary: `Included “${c.title}” as background` } }, { triggerTurn: false });
				out = out.replaceAll(`@conversation:${id}`, `“${c.title}” (the conversation included above)`);
			} else out = out.replaceAll(`@conversation:${id}`, `@conversation:${id} (not found in this project)`);
		}
		this.emitter.emit(this.builder.flush());
		return out;
	}

	async submit(raw: string, options: SubmitOptions) {
		await this.hub.ensureCredential(this.model.provider);
		// A chat's tools follow what's connected and turned off here (they can change between messages).
		if (this.chat) this.applyMode();
		const { text, attachments } = this.chat ? await this.chatReferences(raw) : { text: await this.expandReferences(raw), attachments: [] };
		const input = await this.inputOf(text, [...(options.attachments ?? []), ...attachments]);
		if (this.session.isStreaming) {
			if (options.whenBusy === "reject") throw new EngineError("BUSY", "The session is busy.");
			await this.queue(input, options.whenBusy === "steer" ? "steer" : "followUp");
			return { disposition: "queued" as const };
		}
		// pi refuses a prompt while a compaction runs (the Compact button, or an extension's): it waits for it instead.
		if (this.session.isCompacting || this.waiting.length > 0) {
			if (options.whenBusy === "reject") throw new EngineError("BUSY", "The session is compacting.");
			this.waiting.push(input);
			this.showWaiting();
			if (this.waiting.length === 1) void this.session.waitForIdle().then(() => this.sendWaiting());
			return { disposition: "queued" as const };
		}
		this.start(input);
		return { disposition: "started" as const };
	}

	/**
	 * `@conversation:<id>` in a chat: each one goes with the message as a file framed as background (a CHAT chip), and the
	 * mention reads as its title, so an edit or a retry sends it again.
	 */
	private async chatReferences(text: string): Promise<{ text: string; attachments: NonNullable<SubmitOptions["attachments"]> }> {
		const ids = [...new Set([...text.matchAll(/@conversation:([A-Za-z0-9_-]+)/g)].map((m) => m[1]!))];
		if (ids.length === 0 || !this.history) return { text, attachments: [] };
		const attachments: NonNullable<SubmitOptions["attachments"]> = [];
		let out = text;
		for (const id of ids) {
			const c = await this.history.read(id, "user").catch(() => undefined);
			if (c && c !== "withheld") {
				attachments.push({ kind: "text", name: c.title, mimeType: CONVERSATION_MIME, text: formatConversation(id, c) });
				out = out.replaceAll(`@conversation:${id}`, `“${c.title}”`);
			} else out = out.replaceAll(`@conversation:${id}`, `@conversation:${id} (not found among your chats)`);
		}
		return { text: out, attachments };
	}

	/** The words alone, or with the files sent along (in the message itself: `sdkContent`). */
	private async inputOf(text: string, attachments: SubmitOptions["attachments"]): Promise<Input> {
		if (!attachments?.length) return text;
		if (attachments.some((a) => a.kind === "image")) {
			const model = (await this.hub.buildRuntime()).getModel(this.model.provider, this.model.id);
			if (model && !model.input.includes("image")) throw new EngineError("INVALID", `${model.name} can't read images. Pick a model with vision.`);
		}
		return sdkContent(text, attachments);
	}

	private async queue(input: Input, mode: "steer" | "followUp"): Promise<void> {
		const [text, images] = typeof input === "string" ? [input, undefined] : [input.text, input.images];
		await (mode === "steer" ? this.session.steer(text, images) : this.session.followUp(text, images));
	}

	/** Messages sent during a compaction, in order; shown in the queue until it ends. */
	private waiting: Input[] = [];

	private static words(input: Input): string {
		return typeof input === "string" ? input : sdkUser([{ type: "text", text: input.text }, ...input.images]).text;
	}

	private showWaiting(): void {
		this.builder.setState({ queue: this.waiting.map((input, i) => ({ id: `wait:${i}`, mode: "followUp" as const, text: BuildRuntime.words(input) })) });
		this.emitter.emit(this.builder.flush());
	}

	private sendWaiting(): void {
		const [first, ...rest] = this.waiting.splice(0);
		this.showWaiting();
		if (first === undefined) return;
		this.start(first);
		// The run just started takes the rest as follow-ups, as if they had been sent while it ran.
		for (const input of rest) void this.queue(input, "followUp");
	}

	private start(input: Input): void {
		if (typeof input === "string" && input.startsWith("/")) this.typed.push(input);
		// The run resolves when it settles; progress arrives through events.
		const run = typeof input === "string" ? this.session.prompt(input) : this.session.prompt(input.text, { images: input.images, expandPromptTemplates: false });
		run.catch((error: unknown) => {
			if (typeof input === "string" && this.typed.includes(input)) this.typed.splice(this.typed.lastIndexOf(input), 1);
			this.builder.system(`sys:${Date.now()}`, "error", error instanceof Error ? error.message : String(error));
			this.builder.setState({ status: "idle" });
			this.emitter.emit(this.builder.flush());
		});
	}

	/** Withdraws one queued message (`steer:<n>`, `follow:<n>`, or `wait:<n>` during a compaction). */
	async removeQueued(queueId: string): Promise<void> {
		const [kind, n] = queueId.split(":");
		const i = Number(n);
		if (kind === "wait") {
			if (!(i >= 0 && i < this.waiting.length)) throw new EngineError("NOT_FOUND", "That message is no longer queued.");
			this.waiting.splice(i, 1);
			this.showWaiting();
			return;
		}
		const { steering, followUp } = this.session.clearQueue();
		const list = kind === "steer" ? steering : followUp;
		const found = i >= 0 && i < list.length;
		if (found) list.splice(i, 1);
		// The rest go back in order; if the run ended meanwhile, the first of them starts the next one.
		const rest: [string, "steer" | "followUp"][] = [...steering.map((t) => [t, "steer"] as [string, "steer"]), ...followUp.map((t) => [t, "followUp"] as [string, "followUp"])];
		for (const [text, mode] of rest) {
			if (this.session.isStreaming) await this.queue(text, mode);
			else this.start(text);
		}
		if (!found) throw new EngineError("NOT_FOUND", "That message is no longer queued.");
	}

	/**
	 * Stop: pi's abort keeps queued messages for the next prompt, which would send them along with whatever the user
	 * writes next. Stop drops them and says which, so nothing goes out that the user didn't see go.
	 */
	async abort(): Promise<void> {
		this.broker.cancelAll();
		const { steering, followUp } = this.session.clearQueue();
		const dropped = [...this.waiting.splice(0).map(BuildRuntime.words), ...steering, ...followUp];
		await this.session.abort();
		if (dropped.length === 0) return;
		const quote = (t: string) => `“${t.length > 80 ? `${t.slice(0, 79)}…` : t}”`;
		this.builder.system(`sys:${Date.now()}`, "info", `Stopped. Not sent: ${dropped.map(quote).join(", ")}`);
		this.builder.setState({ queue: [] });
		this.emitter.emit(this.builder.flush());
	}

	/**
	 * Context the model reads before the first message (docs/spec/18 §5, Continue in): a custom message in the pi
	 * session, shown in the transcript as one line (`summary`). It doesn't start a turn.
	 */
	/**
	 * A note this conversation reads on its next turn without starting one (a side conversation's report that
	 * shouldn't wake it, docs/spec/24 §5). It shows as a line with its summary.
	 */
	async sideNote(text: string, summary: string): Promise<void> {
		await this.session.sendCustomMessage({ customType: "piopio.side_note", content: [{ type: "text", text }], display: true, details: { summary } }, { triggerTurn: false });
		this.emitter.emit(this.builder.flush());
	}

	async seed(text: string, images: { type: "image"; data: string; mimeType: string }[], summary: string): Promise<void> {
		await this.session.sendCustomMessage({ customType: "piopio.continued", content: [{ type: "text", text }, ...images], display: true, details: { summary } }, { triggerTurn: false });
		this.emitter.emit(this.builder.flush());
	}

	/**
	 * The tools for the approval mode (docs/spec/18 §4): Read only drops bash, edit and write and adds the finders; any
	 * other mode brings them back. The web tools are on in every mode (the table in §4: "Reads, search, web"), so a
	 * quick lookup is a search, not the browser. Live: the next model request sees them (no reopen).
	 */
	applyMode(): void {
		if (this.chat) {
			const off = new Set([...CHAT_OFF, ...(this.chat.web() ? [] : ["web_search", "web_fetch"])]);
			// A connected app's tools only while one of its accounts is on here (as a chat always offered them).
			const apps = this.connectors;
			const appOff = (id: string) => this.toolsOff?.().includes(`connector:${id}`) ?? false;
			const calendars = apps ? apps.calendars("chat", appOff).length > 0 : false;
			const mailboxes = apps ? apps.mailboxes("chat", appOff).length > 0 : false;
			const wanted = (name: string) => !off.has(name) && (!name.startsWith("calendar_") || calendars) && (!name.startsWith("mail_") || mailboxes);
			// Deferred tools (an app's many tools) wait for tool_search; the ones it already loaded here stay.
			const loaded = new Set(this.session.getActiveToolNames());
			const offered = (t: { name: string; exposure?: string }) => (t.exposure === "deferred" || t.exposure === "hidden" ? loaded.has(t.name) : wanted(t.name));
			this.session.setActiveToolsByName(this.session.getAllTools().filter(offered).map((t) => t.name));
			return;
		}
		const readOnly = this.approvalMode() === "read_only";
		const known = new Set(this.session.getAllTools().map((t) => t.name));
		const active = new Set(this.session.getActiveToolNames());
		if (readOnly) for (const name of READ_ONLY_OFF) active.delete(name);
		for (const name of [...(readOnly ? READ_ONLY_ON : READ_ONLY_OFF), ...WEB_TOOLS]) if (known.has(name)) active.add(name);
		this.session.setActiveToolsByName([...active]);
	}

	/** What the session state says about its settings: a chat's (model, thinking, web), or a folder conversation's. */
	private settings() {
		// A chat says "default" until you pick a level, as chats always did.
		if (this.chat) return { model: this.model, thinking: this.thinkingChosen ?? "default", tools: { web: this.chat.web() } };
		return { model: this.model, thinking: this.session.thinkingLevel, approvalMode: this.approvalMode(), planMode: this.plan.active() };
	}

	async configure(change: { model?: ModelRef; thinking?: string; approvalMode?: ApprovalMode; planMode?: boolean; web?: boolean }): Promise<void> {
		if (change.planMode !== undefined && !this.chat) this.plan.setActive(change.planMode);
		if (change.web !== undefined && this.chat) this.chat.setWeb(change.web);
		if (change.approvalMode || change.web !== undefined) this.applyMode();
		if (change.model) {
			const model = (await this.hub.buildRuntime()).getModel(change.model.provider, change.model.id);
			if (!model) throw new EngineError("INVALID", `Unknown model ${change.model.provider}/${change.model.id}`);
			await this.session.setModel(model);
			this.model = change.model;
		}
		// "default" (a chat's menu): the level pi starts with.
		if (change.thinking) {
			this.thinkingChosen = change.thinking === "default" ? undefined : change.thinking;
			if (change.thinking !== "default") this.session.setThinkingLevel(change.thinking as never);
		}
		this.builder.setState({ ...this.settings(), ...this.context() });
		this.emitter.emit(this.builder.flush());
	}

	// ── Composer and tree (docs/spec/05-build BR5, BR6) ─────────────────────

	/** pi prompt templates, skills and extension commands, for `/`. */
	commands(): { name: string; description: string; kind: "template" | "skill" | "extension"; hint?: string; source?: string }[] {
		const templates = this.session.promptTemplates.map((t) => ({ name: t.name, description: t.description, kind: "template" as const, ...(t.argumentHint ? { hint: t.argumentHint } : {}) }));
		const skills = this.session.resourceLoader.getSkills().skills.map((s) => ({ name: `skill:${s.name}`, description: s.description, kind: "skill" as const, source: skillSource(s) }));
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

	// ── Rewind, retry, fork (docs/design chat v3, 14a–14b) ─────────────────

	/** The user message an item belongs to: itself, or the message that started its turn. */
	private turnOf(itemId: string): { index: number; items: Snapshot["items"] } {
		const items = this.builder.snapshot().items;
		let index = items.findIndex((i) => i.id === itemId || (i.kind === "tool" && `steps:${i.id}` === itemId));
		while (index >= 0 && items[index]!.kind !== "user") index--;
		if (index < 0) throw new EngineError("NOT_FOUND", "That message isn't in this session anymore.");
		return { index, items };
	}

	/**
	 * The pi entry of the user message at `index`: counted from the end, which compaction doesn't disturb (it only
	 * folds older messages into a summary).
	 */
	private userEntry(items: Snapshot["items"], index: number): string {
		const fromEnd = items.slice(index + 1).filter((i) => i.kind === "user").length;
		const entries = this.session.sessionManager.getBranch().filter((e) => e.type === "message" && (e as { message?: PiMessage }).message?.role === "user");
		const entry = entries[entries.length - 1 - fromEnd];
		if (!entry) throw new EngineError("NOT_FOUND", "That message isn't in this session anymore.");
		return entry.id;
	}

	/**
	 * Back to just before one of your messages. With `files`, the project goes back to the first checkpoint after it
	 * (saved before that turn changed anything), after checkpointing the current state. The message's text comes back
	 * for the composer. `dryRun` says which files would change and how many turns go.
	 */
	async rewind(itemId: string, files: boolean, dryRun: boolean): Promise<{ files: FileChange[]; turns: number; editorText?: string }> {
		const { index, items } = this.turnOf(itemId);
		const turns = items.slice(index).filter((i) => i.kind === "user").length;
		const checkpoint = items.slice(index + 1).find((i): i is CheckpointItem => i.kind === "checkpoint");
		const changed = files && checkpoint ? await this.checkpoints.changes(this.cwd, checkpoint.checkpointId) : [];
		if (dryRun) return { files: changed, turns };
		if (this.session.isStreaming) throw new EngineError("BUSY", "Stop the agent before rewinding.");
		const entryId = this.userEntry(items, index);
		if (checkpoint && changed.length > 0) {
			await this.takeCheckpoint(undefined, "Before rewind");
			await this.checkpoints.restore(this.cwd, checkpoint.checkpointId);
		}
		const result = await this.session.navigateTree(entryId);
		this.rebuild(true);
		return { files: changed, turns, ...(result.editorText ? { editorText: result.editorText } : {}) };
	}

	// ── Versions of a message (a chat's ‹ 1 / 2 ›; pi's session tree) ───────

	/** Retry: the turn's message again, as it was sent (its files too), as a new version beside it (files stay as they are). */
	async regenerate(itemId: string): Promise<void> {
		await this.again(itemId, sdkAsSent);
	}

	/** Your message with new words (its files stay): a new version beside the old one, answered again. */
	async edit(itemId: string, text: string): Promise<void> {
		await this.again(itemId, (content) => sdkWithWords(content, text));
	}

	private async again(itemId: string, change: (content: string | ContentBlock[]) => Input): Promise<void> {
		if (this.session.isStreaming) throw new EngineError("BUSY", "Stop the agent before asking again.");
		const { index, items } = this.turnOf(itemId);
		const entryId = this.userEntry(items, index);
		const entry = this.session.sessionManager.getEntry(entryId) as { message?: { content?: string | ContentBlock[] } } | undefined;
		const content = entry?.message?.content ?? "";
		await this.session.navigateTree(entryId);
		this.rebuild(true);
		this.start(change(content));
	}

	/** Shows another version (`BranchInfo.previous` / `next`: the newest end of that version). */
	async switchBranch(branch: string): Promise<void> {
		if (this.session.isStreaming) throw new EngineError("BUSY", "Stop the agent before switching versions.");
		if (!this.session.sessionManager.getEntry(branch)) throw new EngineError("NOT_FOUND", `No version ${branch}`);
		await this.session.navigateTree(branch);
		this.rebuild(true);
	}

	/** Your messages on the path, oldest first, with the user items they show as (matched from the end: compaction). */
	private userPath(): { entry: TreeEntry; itemId: string }[] {
		const onPath = (this.session.sessionManager.getBranch() as unknown as TreeEntry[]).filter(isUserEntry);
		const items = this.builder.currentItems.filter((i) => i.kind === "user");
		return onPath.flatMap((entry, k) => {
			const item = items[items.length - onPath.length + k];
			return item ? [{ entry, itemId: item.id }] : [];
		});
	}

	/** `/commands` sent and not yet written down (in order): each one belongs to the next message of yours pi writes. */
	private readonly typed: string[] = [];

	/** Messages that were a `/command`: noted once pi has written them, and shown as typed. */
	private showTyped(emit: boolean): void {
		const sm = this.session.sessionManager;
		const branch = sm.getBranch() as unknown as TreeEntry[];
		const noted = new Map(branch.flatMap((e) => (e.type === "custom" && e.customType === TYPED_ENTRY ? [[(e.data as { entryId: string }).entryId, (e.data as { text: string }).text] as const] : [])));
		if (this.typed.length) {
			const last = [...branch].reverse().find(isUserEntry);
			if (last && !noted.has(last.id)) {
				const text = this.typed.shift()!;
				sm.appendCustomEntry(TYPED_ENTRY, { text, entryId: last.id });
				noted.set(last.id, text);
			}
		}
		for (const { entry, itemId } of this.userPath()) {
			const typed = noted.get(entry.id);
			if (typed) this.builder.setUserText(itemId, typed, emit);
		}
	}

	/** For each message of yours with other versions (the same place in the tree): which one this is, and its neighbours. */
	private versions(): Map<string, BranchInfo> {
		const sm = this.session.sessionManager;
		type Entry = TreeEntry;
		const isUser = isUserEntry;
		const children = (id: string | null) => (id ? (sm.getChildren(id) as unknown as Entry[]) : sm.getTree().map((n) => n.entry as unknown as Entry));
		// Where versions part: the first entry above that isn't a note (a typed command, a model change), and what follows it.
		const forkPoint = (e: Entry): string | null => {
			let id = e.parentId;
			while (id) {
				const parent = sm.getEntry(id) as unknown as Entry | undefined;
				if (!parent || !isNote(parent)) break;
				id = parent.parentId;
			}
			return id;
		};
		const versionsAt = (id: string | null): Entry[] => children(id).flatMap((c) => (isNote(c) ? versionsAt(c.id) : isUser(c) ? [c] : []));
		const newest = (id: string): string => {
			for (;;) {
				const kids = sm.getChildren(id) as unknown as Entry[];
				if (kids.length === 0) return id;
				id = kids.reduce((a, b) => (b.timestamp > a.timestamp ? b : a)).id;
			}
		};
		const out = new Map<string, BranchInfo>();
		for (const { entry, itemId } of this.userPath()) {
			const around = versionsAt(forkPoint(entry));
			if (around.length < 2) continue;
			around.sort((a, b) => a.timestamp.localeCompare(b.timestamp));
			const i = around.findIndex((e) => e.id === entry.id);
			out.set(itemId, { index: i, count: around.length, ...(i > 0 ? { previous: newest(around[i - 1]!.id) } : {}), ...(i < around.length - 1 ? { next: newest(around[i + 1]!.id) } : {}) });
		}
		return out;
	}

	/** Fork from here: a new pi session file with the conversation up to the end of this item's turn. */
	forkFile(itemId: string): string {
		const { index, items } = this.turnOf(itemId);
		const branch = this.session.sessionManager.getBranch();
		const start = branch.findIndex((e) => e.id === this.userEntry(items, index));
		const next = branch.findIndex((e, i) => i > start && e.type === "message" && (e as { message?: PiMessage }).message?.role === "user");
		const leaf = branch[next > 0 ? next - 1 : branch.length - 1];
		const file = this.session.sessionFile;
		if (!leaf || !file) throw new EngineError("INVALID", "This session isn't saved yet.");
		// A second manager on the same file, so the open session keeps writing to its own.
		const path = SessionManager.open(file).createBranchedSession(leaf.id);
		if (!path) throw new EngineError("INVALID", "Couldn't create the new session.");
		return path;
	}

	/** Reads pi's resources again (a package was installed, turned off or removed), as pi's /reload does; not mid-run. */
	async reloadResources(): Promise<void> {
		if (this.session.isStreaming || this.session.isCompacting) return;
		await this.session.reload();
		this.applyMode();
	}

	async compact(): Promise<void> {
		if (this.session.isStreaming) throw new EngineError("BUSY", "Wait for the agent to finish before compacting.");
		await this.session.compact();
		this.rebuild(true);
	}

	/** The session's background commands (05-build §9 TM4): listed in its state as they start and end. */
	private processes?: ProcessManager;

	useProcesses(processes: ProcessManager): void {
		this.processes = processes;
		processes.onChange = (list: BackgroundProcess[]) => {
			this.builder.setState({ processes: list });
			this.emitter.emit(this.builder.flush());
		};
	}

	/** Ports this session's background commands serve on (the project preview, docs/spec/22 §6). */
	previewPorts(): Promise<number[]> {
		return this.processes?.ports() ?? Promise.resolve([]);
	}

	processOutput(id: string, since = 0) {
		if (!this.processes) throw new EngineError("INVALID", "This session has no background commands.");
		try {
			const r = this.processes.output(id, { since, markRead: false });
			return { text: r.text, next: r.next, process: r.process };
		} catch (error) {
			throw new EngineError("NOT_FOUND", (error as Error).message);
		}
	}

	async processStop(id: string) {
		if (!this.processes) throw new EngineError("INVALID", "This session has no background commands.");
		try {
			return { process: await this.processes.stop(id) };
		} catch (error) {
			throw new EngineError("NOT_FOUND", (error as Error).message);
		}
	}

	/** Stops the filtered network's proxy, if it started. */
	closeNetwork?: () => void;

	async close(): Promise<void> {
		this.closeNetwork?.();
		this.broker.cancelAll();
		this.unsubscribe?.();
		await this.processes?.stopAll();
		this.session.dispose();
	}
}

/** The notes file New project makes (projects.ts). */
export const NOTES_FILE = "NOTES.md";

/** About 1,500 tokens of notes in every turn; the rest is in the file. */
const MAX_NOTES = 6_000;

/**
 * A project's shared notes (docs/spec/18 CF4): when the folder has a NOTES.md, every turn reads it, and the model is
 * asked to add what later conversations need. A plain file: the user reads and edits it in Finder or any editor.
 */
export function notesExtension(cwd: string): ExtensionFactory {
	const file = join(cwd, NOTES_FILE);
	return (pi) => {
		pi.on("before_agent_start", (event) => {
			let notes: string;
			try {
				notes = readFileSync(file, "utf8").trim();
			} catch {
				return undefined;
			}
			const shown = notes.length > MAX_NOTES ? `${notes.slice(0, MAX_NOTES)}\n\n[… the rest is in ${NOTES_FILE}]` : notes;
			promptSection(event as unknown as PromptEvent, "project-notes", `This project keeps shared notes in ${NOTES_FILE}, read by every conversation here. When something comes up that later conversations will need (a decision, a number, a date, a preference), add it to ${NOTES_FILE} as one short line, if you can edit files. The notes now:\n\n${shown}`);
			return undefined;
		});
	};
}

/**
 * Folders linked to the project (docs/spec/18 §18): every turn, the model is told where they are and whether it may
 * change them. Read is allowed anywhere already; writing to a read-only one asks, as anywhere outside the project.
 */
export function linkedFoldersExtension(folders: () => readonly { path: string; edit: boolean }[]): ExtensionFactory {
	return (pi) => {
		pi.on("before_agent_start", (event) => {
			const list = folders();
			if (!list.length) return undefined;
			const lines = list.map((f) => `- ${f.path} (${f.edit ? "part of the project: you may change files here, under the same permissions" : "read only: read and search it, but don't change anything there"})`);
			promptSection(event as unknown as PromptEvent, "linked-folders", `Besides its own folder, this project uses these folders on the Mac. Use their absolute paths; look in them when the task concerns what they hold:\n${lines.join("\n")}`);
			return undefined;
		});
	};
}

/**
 * MCP servers a session turned off (docs/design/session-panel, step 3). pi connects the servers from mcp.json for every
 * session, so their tools are refused here instead, through pi's tool pipeline (codemode scripts included), and the
 * model is told which servers are off. Turning a server back on takes effect with the next call.
 */
/** An entry of pi's session tree, as Piopio reads it. */
type TreeEntry = { id: string; parentId: string | null; type: string; timestamp: string; customType?: string; data?: unknown; message?: PiMessage };

const isUserEntry = (e: TreeEntry) => e.type === "message" && e.message?.role === "user";

/** Entries that aren't part of the conversation: Piopio's notes, pi's model and thinking changes, labels. */
const isNote = (e: TreeEntry | undefined) => !!e && (e.message?.role === "system" || !["message", "custom_message", "compaction", "branch_summary"].includes(e.type));

/** The pi CLI's MCP servers, and codemode / tool search through which their tools are reached. */
function piBuiltins() {
	return [
		{ name: "codemode", factory: createCodemodeExtension(), replaceable: true, builtin: true },
		{ name: "tool-search", factory: createToolSearchExtension(), replaceable: true, builtin: true },
		{ name: "mcp", factory: createMcpExtension(), replaceable: true, builtin: true },
	];
}

/**
 * pi's tools a chat doesn't get: it has no folder of the user's to look in, and runs no commands. `read` stays, for
 * skills; `write` and `edit` stay for the files it makes for you, in its own folder only (`chatFilesOnly`).
 */
const CHAT_OFF = ["bash", "powershell", "grep", "find", "ls"];

/** `ask_user` and `notify_user`: a question waits on the session's question card, a notice is a note in the transcript. */
function notifyBridge(o: BuildOpenOptions, broker: PromptBroker, runtime: () => BuildRuntime | undefined) {
	return {
		ask: async (question: Question, signal: AbortSignal | undefined) => {
			const response = await broker.ask({ kind: "question", title: question.question, callId: question.callId, ...(question.options ? { options: question.options } : {}) }, signal);
			return response?.choice ?? response?.text;
		},
		notify: (message: string) => {
			runtime()?.note("info", message);
			o.onAttention?.("notify", message);
		},
	};
}

/** A chat's extensions (ChatProfile): its prompt and tools, and cards in the transcript where Build would ask. */
function chatFactories(o: BuildOpenOptions, broker: PromptBroker, runtime: () => BuildRuntime | undefined) {
	const card = (callId: string, signal: AbortSignal | undefined) => (request: { tool: string; title: string; args: Record<string, unknown>; always: string }) => runtime()!.approvalCard(callId, signal, request);
	return [
		...piBuiltins(),
		chatPromptExtension(o.chat!.web),
		...(o.toolsOff ? [mcpOffExtension(o.toolsOff)] : []),
		skillsOnlyRead(o.cwd, () => runtime()?.skillDirs() ?? []),
		chatFilesOnly(o.cwd),
		// The files it made, as cards to open or save (as Claude.ai's present_files).
		presentExtension(),
		...(o.browser ? [codingBrowserExtension(o.browser, (callId, signal) => (request) => card(callId, signal)({ ...request, always: `Always allow ${request.site}` }))] : []),
		guardsExtension(),
		chatProfileExtension(o.hub, { ...o.webOptions, scope: o.ref.id }, () => false),
		codingVisualsExtension(o.visuals),
		...(o.apps ? [codingAppsExtension(o.apps.service, o.apps.where, (callId, signal) => (request) => card(callId, signal)({ ...request, always: "" }))] : []),
		// Questions for the user get the question card, as in Build, not a form drawn with show_visual.
		notifyExtension(notifyBridge(o, broker, runtime)),
		...(o.connectors
			? [
					codingConnectorsExtension(
						o.connectors,
						(callId, signal) => (request) => {
							const label = o.connectors!.definition(request.connector)?.name ?? request.connector;
							return card(callId, signal)({ tool: request.tool, title: request.title, args: request.args, always: request.canAllowAlways ? `Don't ask again for this in ${label}` : "" });
						},
						(id) => o.toolsOff?.().includes(`connector:${id}`) ?? false,
					),
				]
			: []),
		// Off in Settings › Memory: no tools (docs/spec/14 M4); @conversation still works.
		...(o.history && !o.history.off() ? [historySdkExtension(o.history)] : []),
		// /learn (docs/spec/14 M5): in a chat, facts about you and skills.
		...(o.learn ? [learnSdkExtension(o.learn)] : []),
		...(o.side ? [sideExtension(o.side)] : []),
		...(o.automations ? [automationsExtension(o.automations)] : []),
		// /goal: it keeps going on its own until the goal is met (docs/spec/32 CM4), bounded as in Build.
		goalExtension(),
		...(o.chat!.extensions ?? []),
		// Last: pi's tools list and rules for the chat's preamble, from the tools the others turned on.
		promptToolsExtension(),
	];
}

/** Where a chat's tool call points: `~/` expanded, relative to the chat's folder, symlinks resolved as far as they exist. */
function chatPath(cwd: string, raw: string): string {
	const logical = resolve(cwd, raw.startsWith("~/") ? join(homedir(), raw.slice(2)) : raw);
	// A new file doesn't exist yet: resolve its nearest existing folder (the chat's folder, under a /var → /private/var link).
	for (let dir = logical, rest = ""; ; rest = rest ? join(basename(dir), rest) : basename(dir), dir = dirname(dir)) {
		if (existsSync(dir)) return rest ? join(realpathSync(dir), rest) : realpathSync(dir);
		if (dirname(dir) === dir) return logical;
	}
}

/**
 * A file another chat made (`<scratch>/<other id>/<path>`), as this chat's copy of it when there is one: a branch
 * copies the folder, and the source chat (and its folder) may be deleted later.
 */
export function chatRelocate(cwd: string): (path: string) => string {
	const scratch = dirname(resolve(cwd));
	return (path) => {
		if (!path.startsWith(`${scratch}/`) || insideDir(path, resolve(cwd))) return path;
		const rest = path.slice(scratch.length + 1).split("/").slice(1).join("/");
		const copy = join(cwd, rest);
		return rest && existsSync(copy) ? copy : path;
	};
}

const insideDir = (path: string, dir: string) => path === dir || path.startsWith(`${dir}/`);

/**
 * `write` and `edit` in a chat: inside its own folder only (the engine's scratch folder for it, which goes with the
 * chat). That's where the files it makes for you live; the user's own files stay out of reach, as before.
 */
function chatFilesOnly(cwd: string): ExtensionFactory {
	return (pi) => {
		pi.on("tool_call", (event) => {
			if (event.toolName !== "write" && event.toolName !== "edit") return undefined;
			const raw = String((event.input as { path?: unknown }).path ?? "");
			const own = chatPath(cwd, ".");
			return raw && insideDir(chatPath(cwd, raw), own)
				? undefined
				: { block: true, reason: "In a conversation without a project, files go in this conversation's own folder: use a plain file name, like report.md." };
		});
	};
}

/** `read` in a chat: a skill's files, and the files it made in its own folder (pi lists the skills for the model to read). */
function skillsOnlyRead(cwd: string, dirs: () => readonly string[]): ExtensionFactory {
	return (pi) => {
		pi.on("tool_call", (event) => {
			if (event.toolName !== "read") return undefined;
			const raw = String((event.input as { path?: unknown }).path ?? "");
			const path = resolve(cwd, raw.startsWith("~/") ? join(homedir(), raw.slice(2)) : raw);
			if (raw && insideDir(chatPath(cwd, raw), chatPath(cwd, "."))) return undefined;
			return dirs().some((d) => path === d || path.startsWith(`${d}/`)) ? undefined : { block: true, reason: "In a conversation without a project, read opens a skill's files and the files you made here only." };
		});
	};
}

function mcpOffExtension(toolsOff: () => string[]): ExtensionFactory {
	const servers = () => toolsOff().flatMap((t) => (t.startsWith("mcp:") ? [t.slice(4)] : []));
	return (pi) => {
		pi.on("before_agent_start", (event) => {
			const off = servers();
			promptSection(event as unknown as PromptEvent, "mcp-off", off.length ? `These MCP servers are turned off in this conversation, so don't use their tools: ${off.join(", ")}.` : undefined);
			return undefined;
		});
		pi.on("tool_call", (event) => {
			const hit = servers().find((s) => event.toolName.startsWith(`mcp__${s}__`) || event.toolName.startsWith(`mcp__${s.replace(/[^A-Za-z0-9_]/g, "_")}__`));
			return hit ? { block: true, reason: `The MCP server “${hit}” is turned off in this conversation. The user can turn it back on in the composer's + menu.` } : undefined;
		});
	};
}
