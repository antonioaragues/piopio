/**
 * A conversation run by an ACP agent (docs/spec/31, phase A3): Antigravity CLI or Codex, started from the user's own
 * install and sign-in. One agent process per open conversation; its `session/update`s become Piopio's timeline, its
 * permission requests Piopio's prompts (the composer tray), and Piopio's approval mode, model and thinking level its
 * session settings. The transcript is kept as Piopio's own copy (pi-shaped messages, as for Claude Code) with the
 * agent's session id, which is loaded again when the conversation reopens.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { ApprovalMode, Attachment, AttachmentInfo, ContainerRef, ModelRef, PromptResponse, SessionEvent, Snapshot } from "@piopio/protocol";
import { AcpConnection, CLIENT_CAPABILITIES, type AcpAgent, type ConfigOption } from "../acp.js";
import { EngineError } from "../models.js";
import { emptyUsage, TimelineBuilder, type PiContentBlock, type PiMessage, type ToolImageKeeper } from "../timeline/builder.js";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { bridgeScript, type ToolServer } from "../tool-server.js";
import { collectTools, PIOPIO_MCP, type CapturedTool } from "./claude-code-tools.js";
import type { ToolAsk } from "./claude-code.js";
import { PromptBroker } from "./prompts.js";
import { agentIdleMs, Emitter, IdleTimer, type Runtime, type SubmitOptions } from "./runtime.js";

type Stored = { version: 1; sessionId?: string; messages: PiMessage[] };
type Input = { text: string; attachments: (Attachment & { stored?: string })[] };
type Streaming = { id: string; index: number; blocks: PiContentBlock[]; lastKind?: "text" | "thinking"; part: number };
type ToolState = { name: string; args: Record<string, unknown>; at: number; terminal: string; exitCode?: number; done: boolean };
/** A tool call as ACP describes it (`tool_call` and `tool_call_update`). */
type AcpToolCall = {
	toolCallId: string;
	title?: string;
	kind?: string;
	status?: string;
	rawInput?: Record<string, unknown>;
	rawOutput?: { output?: unknown; exit_code?: unknown } & Record<string, unknown>;
	locations?: { path: string }[];
	content?: ({ type: "content"; content: { type: string; text?: string; data?: string; mimeType?: string } } | { type: "diff"; path: string; oldText?: string | null; newText: string } | { type: "terminal"; terminalId: string })[];
	_meta?: { terminal_output_delta?: { data?: string }; terminal_exit?: { exit_code?: number } };
};

export type AcpOpenOptions = {
	ref: ContainerRef;
	cwd: string;
	model: ModelRef;
	thinking?: string;
	file: string;
	agent: AcpAgent;
	approvalMode: () => ApprovalMode;
	/** A chat (no project): its own folder, in Auto-edit. */
	chat?: boolean;
	keepImages?: ToolImageKeeper;
	onAttention?: (message: string) => void;
	/** Piopio's own tools (docs/spec/31 CA8), served to the agent as the MCP server "piopio" by `toolServer`. */
	tools?: (ask: ToolAsk) => ExtensionFactory[];
	toolServer?: ToolServer;
	/** How long the agent's process may sit idle before it's ended (its session loaded again on the next message). */
	idleMs?: number;
};

const WRITES = new Set(["edit", "delete", "move", "execute"]);
const STALE_MODEL_WARNING = /^Warning: This session was recorded with model `[^`]+` but is resuming with `[^`]+`\.[^\n]*\n*/;

/** An ACP tool call under Piopio's names and arguments, so the transcript gives it its file, diff and terminal details. */
export function acpTool(call: Pick<AcpToolCall, "kind" | "title" | "rawInput" | "locations" | "content">): { name: string; args: Record<string, unknown> } {
	const raw = call.rawInput ?? {};
	const path = call.locations?.[0]?.path ?? (typeof raw.path === "string" ? raw.path : typeof raw.Path === "string" ? raw.Path : typeof raw.file_path === "string" ? raw.file_path : undefined);
	const diff = call.content?.find((c) => c.type === "diff") as { oldText?: string | null; newText: string; path: string } | undefined;
	switch (call.kind) {
		case "execute": {
			const command = typeof raw.command === "string" ? raw.command : Array.isArray(raw.command) ? raw.command.join(" ") : typeof raw.CommandLine === "string" ? raw.CommandLine : (call.title ?? "");
			return { name: "bash", args: { ...raw, command } };
		}
		case "edit":
			if (diff && !diff.oldText) return { name: "write", args: { ...raw, path: diff.path ?? path, content: diff.newText } };
			return { name: "edit", args: { ...raw, ...(path ? { path } : {}) } };
		case "read":
			return { name: "read", args: { ...raw, ...(path ? { path } : {}) } };
		case "search":
			return { name: "grep", args: { ...raw, pattern: call.title ?? "" } };
		case "fetch":
			return { name: "web_fetch", args: { ...raw, url: call.title ?? "" } };
		default:
			return { name: call.title?.split(/\s/)[0] || call.kind || "tool", args: raw };
	}
}

/** An edit's diff content as a unified patch, for the diff card. */
function patchOf(content: AcpToolCall["content"]): string | undefined {
	const diffs = (content ?? []).filter((c): c is { type: "diff"; path: string; oldText?: string | null; newText: string } => c.type === "diff");
	const hunks = diffs.map((d) => {
		const old = d.oldText ? d.oldText.replace(/\n$/, "").split("\n") : [];
		const neu = d.newText.replace(/\n$/, "").split("\n");
		return `@@ -${old.length ? 1 : 0},${old.length} +1,${neu.length} @@\n${[...old.map((l) => `-${l}`), ...neu.map((l) => `+${l}`)].join("\n")}`;
	});
	return hunks.length ? hunks.join("\n") : undefined;
}

export class AcpRuntime implements Runtime {
	readonly ref: ContainerRef;
	private readonly builder: TimelineBuilder;
	private readonly emitter = new Emitter();
	private readonly broker = new PromptBroker();
	private stored: Stored;
	private model: ModelRef;
	private thinking?: string;
	private conn?: AcpConnection;
	private sessionId?: string;
	private config: ConfigOption[] = [];
	/** While the agent replays a loaded session: its updates are history Piopio already has. */
	private loading = false;
	private busy = false;
	private stopping = false;
	private current?: Streaming;
	private followUps: Input[] = [];
	private readonly tools = new Map<string, ToolState>();
	private starting?: Promise<void>;
	/** Piopio's tools for this conversation, and their address at the tool server. */
	private piopio?: { tools: CapturedTool[]; url: string; close: () => void; prompt: () => Promise<string> };
	/** Calls to Piopio's tools the agent announced and the tool server hasn't run yet (their ids key the cards). */
	private piopioCalls: { id: string; name: string; input: string }[] = [];
	/** What Piopio's tools answered, by call: the card's output when the agent doesn't report it (Antigravity). */
	private readonly piopioResults = new Map<string, string>();
	private turnAbort = new AbortController();
	/** Ends the agent's process when the conversation has been idle a while, if it can load its session again. */
	private idle: IdleTimer;
	private canLoad = false;

	private constructor(private readonly options: AcpOpenOptions) {
		this.ref = options.ref;
		this.model = options.model;
		if (options.thinking) this.thinking = options.thinking;
		this.builder = new TimelineBuilder(options.ref);
		if (options.keepImages) this.builder.keepImages = options.keepImages;
		this.stored = AcpRuntime.load(options.file);
		this.builder.reset(this.stored.messages, (i) => `m${i}`, false);
		this.builder.setState({ status: "idle", model: this.model, prompts: [], ...(this.thinking ? { thinking: this.thinking } : {}), ...(options.chat ? {} : { approvalMode: options.approvalMode() }) });
		this.idle = new IdleTimer(options.idleMs ?? agentIdleMs(), () => {
			if (this.busy || this.starting || this.broker.list().length) return this.idle.arm();
			void this.endConnection();
		});
		this.builder.flush();
		this.broker.onChange = (prompts, changed, added) => {
			if (changed.callId) this.builder.toolStatus(changed.callId, added ? "pending_approval" : "running");
			this.builder.setState({ prompts, status: prompts.length ? "waiting_approval" : this.busy ? "running" : "idle" });
			this.emit();
		};
		this.broker.onAdded = (prompt) => options.onAttention?.(prompt.title);
	}

	static async open(options: AcpOpenOptions): Promise<AcpRuntime> {
		return new AcpRuntime(options);
	}

	private get name(): string {
		return this.options.agent.spec.name;
	}

	private static load(file: string): Stored {
		if (!existsSync(file)) return { version: 1, messages: [] };
		try {
			const s = JSON.parse(readFileSync(file, "utf8")) as Stored;
			return { version: 1, ...(s.sessionId ? { sessionId: s.sessionId } : {}), messages: Array.isArray(s.messages) ? s.messages : [] };
		} catch {
			return { version: 1, messages: [] };
		}
	}

	private save(): void {
		mkdirSync(dirname(this.options.file), { recursive: true });
		const tmp = `${this.options.file}.tmp`;
		writeFileSync(tmp, JSON.stringify(this.stored), { mode: 0o600 });
		renameSync(tmp, this.options.file);
	}

	snapshot(): Snapshot {
		return this.builder.snapshot();
	}

	onEvents(listener: (events: SessionEvent[]) => void): () => void {
		return this.emitter.on(listener);
	}

	private emit(): void {
		this.emitter.emit(this.builder.flush());
	}

	respond(promptId: string, response: PromptResponse): void {
		this.broker.respond(promptId, response);
	}

	// ── The session ──────────────────────────────────────────────────────────

	/** Starts the agent and its session once: the stored one loaded again when it can, else a new one. */
	private ensureSession(): Promise<void> {
		if (this.conn?.alive && this.sessionId) return Promise.resolve();
		this.starting ??= this.startSession().finally(() => (this.starting = undefined));
		return this.starting;
	}

	private async startSession(): Promise<void> {
		const status = await this.options.agent.status();
		const cmd = this.options.agent.command();
		if (!cmd || !status.path) throw new EngineError("AUTH", `${this.name} isn't installed on this Mac. Install it, or pick another model.`);
		if (!status.signedIn) throw new EngineError("AUTH", status.problem ?? `${this.name} is signed out. Run \`${this.options.agent.spec.signIn}\` in Terminal to sign in, or pick another model.`);
		const conn = new AcpConnection(cmd.command, cmd.args, this.options.cwd);
		this.conn = conn;
		conn.onNotification = (method, params) => {
			if (method === "session/update" && params.sessionId === this.sessionId) this.update(params.update as Record<string, unknown> & { sessionUpdate: string });
		};
		conn.onRequest = (method, params) => this.request(method, params);
		conn.onExit = (message) => {
			if (this.conn !== conn) return;
			this.conn = undefined;
			this.sessionId = undefined;
			this.broker.cancelAll();
			if (this.busy) this.fail(message);
		};
		type Caps = { loadSession?: boolean; mcpCapabilities?: { http?: boolean }; sessionCapabilities?: { systemPrompt?: unknown }; _meta?: { antigravity?: { systemPrompt?: { append?: unknown } } } };
		const init = await conn.request<{ agentCapabilities?: Caps }>("initialize", { protocolVersion: 1, clientCapabilities: CLIENT_CAPABILITIES }, 30_000);
		this.canLoad = Boolean(init.agentCapabilities?.loadSession);
		const mcpServers = await this.mcpServers(Boolean(init.agentCapabilities?.mcpCapabilities?.http));
		// What Piopio's tools add to the instructions (connected apps, About me, visuals), the way each agent takes it:
		// ACP's `systemPrompt` in append mode (Codex), or Antigravity's `_meta.antigravity.systemPrompt.append`.
		const append = (await this.piopio?.prompt().catch(() => "")) ?? "";
		const extra = append
			? {
					...(init.agentCapabilities?.sessionCapabilities?.systemPrompt ? { systemPrompt: { mode: "append", content: [{ type: "text", text: append }] } } : {}),
					...(init.agentCapabilities?._meta?.antigravity?.systemPrompt?.append ? { _meta: { antigravity: { systemPrompt: { append } } } } : {}),
				}
			: {};
		let session: { sessionId?: string; configOptions?: ConfigOption[] } | undefined;
		if (this.stored.sessionId && init.agentCapabilities?.loadSession) {
			this.loading = true;
			this.sessionId = this.stored.sessionId;
			session = await conn.request<{ configOptions?: ConfigOption[] }>("session/load", { sessionId: this.stored.sessionId, cwd: this.options.cwd, mcpServers, ...extra }, 60_000).catch(() => undefined);
			this.loading = false;
			if (session) session.sessionId = this.stored.sessionId;
		}
		if (!session) {
			session = await conn.request<{ sessionId: string; configOptions?: ConfigOption[] }>("session/new", { cwd: this.options.cwd, mcpServers, ...extra }, 60_000);
			this.stored.sessionId = session.sessionId;
			this.save();
		}
		this.sessionId = session.sessionId;
		this.config = session.configOptions ?? [];
		// A loaded session may say it's on the model it was recorded with while running another (Codex): set it anyway.
		await this.setOption("model", this.model.id, true);
		await this.applyThinking();
		await this.applyMode();
	}

	/**
	 * Piopio's tools as an MCP server the agent reaches: by address when it can use HTTP (Codex), else through the stdio
	 * bridge it starts (Antigravity CLI).
	 */
	private async mcpServers(http: boolean): Promise<unknown[]> {
		if (!this.options.tools || !this.options.toolServer) return [];
		if (!this.piopio) {
			const { tools: collected, prompt } = collectTools(this.options.tools(this.ask));
			if (!collected.length) return [];
			const tools = collected.map((t): CapturedTool => ({
				...t,
				execute: async (callId, params, signal, onUpdate, ctx) => {
					const r = await t.execute(callId, params, signal, onUpdate, ctx);
					this.piopioResults.set(callId, (r.content ?? []).flatMap((c) => (c.type === "text" ? [c.text ?? ""] : [])).join("\n"));
					return r;
				},
			}));
			const served = await this.options.toolServer.register({ tools: () => tools, callIdFor: (name, args) => this.callIdFor(name, args), signal: () => this.turnAbort.signal });
			this.piopio = { tools, prompt, ...served };
		}
		return http ? [{ type: "http", name: PIOPIO_MCP, url: this.piopio.url, headers: [] }] : [{ name: PIOPIO_MCP, command: process.execPath, args: [bridgeScript(), this.piopio.url], env: [] }];
	}

	/** One of Piopio's tools asks the user. */
	private ask: ToolAsk = (request, signal) => this.broker.ask({ kind: "approval", title: request.title, tool: request.tool, callId: request.callId }, signal);

	/**
	 * One of Piopio's tools, if the agent's tool call is one (agents name MCP tools in their own ways). Its calls are let
	 * through without asking, so a match is strict: a command, an edit or a move never is one, whatever its title says
	 * (a command's title is the command, and "echo web_fetch && …" isn't web_fetch), and the name is the whole call
	 * name or title, or the title as "mcp.piopio.search_conversations" (Codex) or "mcp_piopio_…" (Antigravity), with
	 * nothing after it but its arguments in parentheses: a permission request may not say what kind of call it is.
	 * Codex (codex-acp 2.7) sends an MCP call as kind "execute" with `rawInput` `{ server, tool, arguments }`: that
	 * structure, naming Piopio's server and one of its tools, is a match whatever the kind (a command's `rawInput` is
	 * its command line, never a server).
	 */
	private piopioName(call: Pick<AcpToolCall, "title" | "kind" | "rawInput"> & { name?: string }): string | undefined {
		if (!this.piopio) return undefined;
		const raw = call.rawInput as { server?: unknown; tool?: unknown } | undefined;
		if (raw?.server === PIOPIO_MCP && typeof raw.tool === "string") return this.piopio.tools.find((t) => t.name === raw.tool)?.name;
		if (WRITES.has(call.kind ?? "")) return undefined;
		// Antigravity CLI 1.5 titles them "Run mcp_piopio_browser_open".
		const title = (call.title ?? "").trim().replace(/^Run\s+(?=(?:mcp[._])?piopio)/, "");
		return this.piopio.tools.find((t) => call.name === t.name || title === t.name || new RegExp(`^(?:mcp[._])?piopio(?:\\.|__|_)${t.name}(?:\\(|$)`).test(title))?.name;
	}

	/** The agent's tool call for this run of one of Piopio's tools (same name and arguments, else same name). */
	private callIdFor(name: string, args: Record<string, unknown>): string {
		const json = JSON.stringify(args);
		const i = this.piopioCalls.findIndex((c) => c.name === name && c.input === json);
		const at = i >= 0 ? i : this.piopioCalls.findIndex((c) => c.name === name);
		if (at < 0) return `piopio-${Date.now()}`;
		return this.piopioCalls.splice(at, 1)[0]!.id;
	}

	/** Changes one of the session's settings when the agent offers that value. */
	private async setOption(id: string, value: string | undefined, force = false): Promise<void> {
		const option = this.config.find((o) => o.id === id || o.category === id);
		if (!value || !option || (option.currentValue === value && !force) || !option.options?.some((o) => o.value === value) || !this.conn || !this.sessionId) return;
		const r = await this.conn.request<{ configOptions?: ConfigOption[] }>("session/set_config_option", { sessionId: this.sessionId, configId: option.id, value }, 20_000).catch(() => undefined);
		if (r?.configOptions) this.config = r.configOptions;
		else option.currentValue = value;
	}

	private applyMode(): Promise<void> {
		const mode = this.options.chat ? "auto_edit" : this.options.approvalMode();
		return this.setOption("mode", this.options.agent.spec.modes[mode]);
	}

	/** Piopio's thinking level as the agent's ("off" is its lowest). */
	private applyThinking(): Promise<void> {
		if (!this.thinking || this.thinking === "default") return Promise.resolve();
		const levels = this.config.find((o) => o.id === this.options.agent.spec.thinking)?.options?.map((o) => o.value) ?? [];
		const wanted = this.thinking === "off" || this.thinking === "minimal" ? levels[0] : levels.includes(this.thinking) ? this.thinking : undefined;
		return this.setOption(this.options.agent.spec.thinking, wanted);
	}

	// ── Turns ────────────────────────────────────────────────────────────────

	async submit(text: string, options: SubmitOptions): Promise<{ disposition: "started" | "queued" }> {
		const input: Input = { text, attachments: options.attachments ?? [] };
		if (this.busy) {
			if (options.whenBusy === "reject") throw new EngineError("BUSY", `${this.name} is still working.`);
			this.followUps.push(input);
			this.builder.setState({ queue: this.followUps.map((f, i) => ({ id: `q${i}`, mode: "followUp" as const, text: f.text })) });
			this.emit();
			return { disposition: "queued" };
		}
		await this.start(input);
		return { disposition: "started" };
	}

	private async start(input: Input): Promise<void> {
		this.idle.disarm();
		this.busy = true;
		const index = this.stored.messages.length;
		const attachments: AttachmentInfo[] = input.attachments.map((a) => ({ name: a.name, kind: a.kind, ...(a.mimeType ? { mimeType: a.mimeType } : {}), ...(a.stored ? { stored: a.stored } : {}) }));
		const now = Date.now();
		this.stored.messages.push({ role: "user", content: input.text, timestamp: now, ...(attachments.length ? { attachments } : {}) } as PiMessage);
		this.save();
		this.builder.user(`m${index}`, input.text, now, attachments);
		this.builder.setState({ status: "running" });
		this.emit();
		try {
			await this.ensureSession();
		} catch (error) {
			this.fail((error as Error).message);
			return;
		}
		const prompt = [
			...input.attachments.map((a) => (a.kind === "image" ? { type: "image", data: a.data, mimeType: a.mimeType } : { type: "resource", resource: { uri: `file:///${encodeURIComponent(a.path ?? a.name)}`, mimeType: a.mimeType ?? "text/plain", text: a.text } })),
			{ type: "text", text: input.text },
		];
		this.conn!.request<{ stopReason?: string; usage?: Record<string, number> }>("session/prompt", { sessionId: this.sessionId, prompt })
			.then((r) => this.turnEnded(r))
			.catch((error: Error) => this.fail(error.message));
	}

	private fail(message: string): void {
		this.endAssistant();
		this.builder.system(`e${Date.now()}`, "error", `${this.name}: ${message}`);
		this.busy = false;
		this.stopping = false;
		this.followUps = [];
		this.builder.setState({ status: "idle", queue: [] });
		this.emit();
		this.armIdle();
	}

	private turnEnded(result: { stopReason?: string; usage?: Record<string, number> }): void {
		this.endAssistant();
		for (const [id, t] of this.tools) if (!t.done) this.endTool(id, { toolCallId: id, status: "failed" }, t);
		// The plan pays (CA6): tokens, no spending.
		const u = result.usage;
		if (u) {
			const usage = { input: u.inputTokens ?? 0, output: u.outputTokens ?? 0, cacheRead: u.cachedReadTokens ?? 0, cacheWrite: u.cachedWriteTokens ?? 0, cost: { total: 0 } };
			const last = [...this.stored.messages].reverse().find((m) => m.role === "assistant") as { usage?: typeof usage } | undefined;
			if (last) last.usage = usage;
			const cur = this.builder.snapshot().state.usage ?? emptyUsage();
			this.builder.setState({ usage: { ...cur, inputTokens: cur.inputTokens + usage.input, outputTokens: cur.outputTokens + usage.output, cacheReadTokens: cur.cacheReadTokens + usage.cacheRead, cacheWriteTokens: cur.cacheWriteTokens + usage.cacheWrite } });
			this.save();
		}
		if (result.stopReason === "refusal") this.builder.system(`e${Date.now()}`, "warn", `${this.name} declined to go on.`);
		else if (result.stopReason === "max_tokens" || result.stopReason === "max_turn_requests") this.builder.system(`e${Date.now()}`, "warn", `${this.name} stopped: it reached its limit for one turn.`);
		this.busy = false;
		this.stopping = false;
		this.piopioCalls = [];
		this.builder.setState({ status: this.broker.list().length ? "waiting_approval" : "idle" });
		this.emit();
		const next = this.followUps.shift();
		if (next) {
			this.builder.setState({ queue: this.followUps.map((f, i) => ({ id: `q${i}`, mode: "followUp" as const, text: f.text })) });
			void this.start(next);
		} else this.armIdle();
	}

	/** Only an agent that loads its sessions again is ended when idle: one that can't would forget the conversation. */
	private armIdle(): void {
		if (this.conn && this.canLoad && this.stored.sessionId) this.idle.arm();
	}

	/** Ends the agent's process; Piopio's tool server stays, for the session loaded on the next message. */
	private async endConnection(): Promise<void> {
		const conn = this.conn;
		const sessionId = this.sessionId;
		this.conn = undefined;
		this.sessionId = undefined;
		if (conn && sessionId) await conn.request("session/close", { sessionId }, 3000).catch(() => undefined);
		conn?.close();
	}

	// ── What the agent says ──────────────────────────────────────────────────

	private beginAssistant(): Streaming {
		const index = this.stored.messages.length;
		this.stored.messages.push({ role: "assistant", content: [], provider: this.options.agent.spec.id, model: this.model.id, timestamp: Date.now() });
		const s: Streaming = { id: `m${index}`, index, blocks: [], part: -1 };
		this.current = s;
		this.builder.assistantStart(s.id, `${this.options.agent.spec.id}/${this.model.id}`);
		return s;
	}

	private chunk(kind: "text" | "thinking", text: string): void {
		if (!text) return;
		const s = this.current ?? this.beginAssistant();
		if (s.lastKind !== kind) {
			s.part++;
			s.lastKind = kind;
			s.blocks.push(kind === "text" ? { type: "text", text: "" } : { type: "thinking", thinking: "" });
		}
		const block = s.blocks[s.blocks.length - 1]!;
		if (block.type === "text") block.text += text;
		else if (block.type === "thinking") block.thinking += text;
		this.builder.assistantDelta(s.part, kind, text);
	}

	private endAssistant(): void {
		const s = this.current;
		if (!s) return;
		this.current = undefined;
		// Codex warns, when a session loads, that it resumes on its default model; Piopio sets the recorded one right after.
		for (const b of s.blocks) if (b.type === "text") b.text = b.text.replace(STALE_MODEL_WARNING, "");
		const message = { role: "assistant" as const, content: s.blocks, provider: this.options.agent.spec.id, model: this.model.id, timestamp: (this.stored.messages[s.index]?.timestamp as number | undefined) ?? Date.now() };
		this.stored.messages[s.index] = message;
		this.save();
		this.builder.assistantEnd(message);
		for (const b of s.blocks) if (b.type === "toolCall") this.builder.toolStart(b.id, b.name, b.arguments);
	}

	private update(u: Record<string, unknown> & { sessionUpdate: string }): void {
		if (this.loading) return;
		const content = u.content as { type?: string; text?: string } | undefined;
		switch (u.sessionUpdate) {
			case "agent_message_chunk":
			case "agent_message":
				if (content?.type === "text") this.chunk("text", content.text ?? "");
				break;
			case "agent_thought_chunk":
			case "agent_thought":
				if (content?.type === "text") this.chunk("thinking", content.text ?? "");
				break;
			case "tool_call":
				this.toolCall(u as unknown as AcpToolCall);
				break;
			case "tool_call_update":
				this.toolUpdate(u as unknown as AcpToolCall);
				break;
			case "plan": {
				const entries = (u.entries as { content?: string; status?: string }[] | undefined) ?? [];
				this.builder.setState({ todos: entries.map((e) => ({ text: e.content ?? "", status: e.status === "completed" ? ("done" as const) : e.status === "in_progress" ? ("in_progress" as const) : ("pending" as const) })) });
				break;
			}
			case "usage_update":
				if (typeof u.used === "number" && typeof u.size === "number") this.builder.setState({ context: { tokens: u.used, window: u.size } });
				break;
			case "config_option_update":
				if (Array.isArray(u.configOptions)) this.config = u.configOptions as ConfigOption[];
				break;
		}
		this.emit();
	}

	/** A new tool call: it ends the answer so far and shows as running (its arguments may still grow). */
	private toolCall(call: AcpToolCall): void {
		if (this.tools.has(call.toolCallId)) return this.toolUpdate(call);
		const own = this.piopioName(call as AcpToolCall & { name?: string });
		// Codex wraps an MCP call's arguments: { server, tool, arguments }. Antigravity adds its own `toolSummary`.
		const { toolSummary: _summary, ...bare } = (call.rawInput ?? {}) as Record<string, unknown>;
		const ownArgs = (call.rawInput?.arguments && typeof call.rawInput.arguments === "object" ? call.rawInput.arguments : bare) as Record<string, unknown>;
		const tool = own ? { name: own, args: ownArgs } : acpTool(call);
		if (own) this.piopioCalls.push({ id: call.toolCallId, name: own, input: JSON.stringify(ownArgs) });
		const s = this.current ?? this.beginAssistant();
		s.blocks.push({ type: "toolCall", id: call.toolCallId, name: tool.name, arguments: tool.args });
		this.tools.set(call.toolCallId, { name: tool.name, args: tool.args, at: Date.now(), terminal: call._meta?.terminal_output_delta?.data ?? "", done: false });
		this.endAssistant();
		if (call.status === "completed" || call.status === "failed") this.endTool(call.toolCallId, call, this.tools.get(call.toolCallId)!);
	}

	private toolUpdate(call: AcpToolCall): void {
		const t = this.tools.get(call.toolCallId);
		if (!t || t.done) return;
		if (call._meta?.terminal_output_delta?.data) t.terminal += call._meta.terminal_output_delta.data;
		if (typeof call._meta?.terminal_exit?.exit_code === "number") t.exitCode = call._meta.terminal_exit.exit_code;
		if (call.status === "completed" || call.status === "failed") this.endTool(call.toolCallId, call, t);
		else if (t.terminal) this.builder.toolOutput(call.toolCallId, { set: t.terminal });
	}

	private endTool(id: string, call: AcpToolCall, t: ToolState): void {
		t.done = true;
		this.tools.delete(id);
		const texts = (call.content ?? []).flatMap((c) => (c.type === "content" && c.content.type === "text" ? [c.content.text ?? ""] : []));
		const images = (call.content ?? []).flatMap((c) => (c.type === "content" && c.content.type === "image" && c.content.data ? [{ type: "image" as const, data: c.content.data, mimeType: c.content.mimeType ?? "image/png" }] : []));
		// Codex reports an MCP tool's result as `rawOutput.result.content`.
		const mcp = (call.rawOutput?.result as { content?: { type: string; text?: string }[] } | undefined)?.content ?? [];
		const raw = typeof call.rawOutput?.output === "string" ? call.rawOutput.output : mcp.flatMap((c) => (c.type === "text" ? [c.text ?? ""] : [])).join("\n");
		let output = texts.join("\n") || t.terminal || raw || this.piopioResults.get(id) || "";
		this.piopioResults.delete(id);
		const exit = t.exitCode ?? (typeof call.rawOutput?.exit_code === "number" ? call.rawOutput.exit_code : undefined);
		const failed = call.status === "failed" || (exit !== undefined && exit !== 0);
		if (t.name === "bash" && exit !== undefined && !/exited with code/.test(output)) output = `${output}${output.endsWith("\n") || !output ? "" : "\n"}Command exited with code ${exit}`;
		const patch = t.name === "edit" || t.name === "write" ? patchOf(call.content) : undefined;
		const piContent: PiContentBlock[] = [{ type: "text", text: output }, ...images];
		this.stored.messages.push({ role: "toolResult", toolCallId: id, toolName: t.name, content: piContent, ...(patch && t.name === "edit" ? { details: { patch } } : {}), isError: failed, timestamp: Date.now() });
		this.save();
		this.builder.toolEnd(id, output, failed, Date.now() - t.at, { ...(patch && t.name === "edit" ? { details: { patch } } : {}), content: piContent });
	}

	// ── What the agent asks ──────────────────────────────────────────────────

	private async request(method: string, params: Record<string, unknown>): Promise<unknown> {
		if (method !== "session/request_permission") throw Object.assign(new Error("Method not found"), { code: -32601 });
		const call = (params.toolCall ?? {}) as AcpToolCall;
		const options = (params.options as { optionId: string; name: string; kind: string }[] | undefined) ?? [];
		const pick = (...kinds: string[]) => options.find((o) => kinds.includes(o.kind))?.optionId;
		// Piopio's own tools ask the user themselves where they need to (docs/spec/31 CA8). Codex's request names only the call.
		const known = this.tools.get(call.toolCallId);
		if (this.piopioName(call as AcpToolCall & { name?: string }) || (known && this.piopio?.tools.some((t) => t.name === known.name))) return { outcome: { outcome: "selected", optionId: pick("allow_once", "allow_always") } };
		const reject = { outcome: { outcome: "selected", optionId: pick("reject_once", "reject_always") } };
		// Read only refuses changes outright (an agent's "read-only" may still ask).
		if (!this.options.chat && this.options.approvalMode() === "read_only" && WRITES.has(call.kind ?? "")) return pick("reject_once", "reject_always") ? reject : { outcome: { outcome: "cancelled" } };
		// Codex's request may name only the call: the card then shows the call as Piopio already has it.
		const tool = known && !call.rawInput && !call.title ? { name: known.name, args: known.args } : acpTool(call);
		const file = typeof tool.args.path === "string" ? tool.args.path.split("/").pop() : undefined;
		const title = tool.name === "bash" ? "Run a command" : tool.name === "write" ? `Write ${file ?? "a file"}` : tool.name === "edit" ? `Edit ${file ?? "a file"}` : `Use ${call.title ?? tool.name}`;
		const detail = tool.name === "bash" ? String(tool.args.command ?? "") : typeof tool.args.path === "string" ? tool.args.path : undefined;
		const always = pick("allow_always");
		const answer = await this.broker.ask({
			kind: "approval",
			title,
			...(detail ? { detail } : {}),
			tool: tool.name,
			callId: call.toolCallId,
			...(always ? { rule: tool.name === "bash" ? { kind: "command" as const, pattern: String(tool.args.command ?? "").trim().split(/\s+/)[0] ?? "" } : { kind: "tool" as const, pattern: tool.name } } : {}),
		});
		if (!answer) return { outcome: { outcome: "cancelled" } };
		if (answer.decision === "always" && always) return { outcome: { outcome: "selected", optionId: always } };
		if (answer.decision === "allow" || answer.decision === "always") return { outcome: { outcome: "selected", optionId: pick("allow_once", "allow_always") } };
		return reject;
	}

	// ── Controls ─────────────────────────────────────────────────────────────

	async abort(): Promise<void> {
		this.turnAbort.abort();
		this.turnAbort = new AbortController();
		if (this.busy) this.stopping = true;
		this.followUps = [];
		this.broker.cancelAll();
		this.builder.setState({ queue: [] });
		this.emit();
		if (this.conn && this.sessionId) this.conn.notify("session/cancel", { sessionId: this.sessionId });
	}

	async configure(change: { model?: ModelRef; thinking?: string; approvalMode?: ApprovalMode }): Promise<void> {
		if (change.model) {
			if (change.model.provider !== this.options.agent.spec.id) throw new EngineError("INVALID", `This conversation runs in ${this.name}.`);
			this.model = change.model;
			await this.setOption("model", change.model.id);
			this.builder.setState({ model: this.model });
		}
		if (change.thinking) {
			if (change.thinking === "default") delete this.thinking;
			else this.thinking = change.thinking;
			await this.applyThinking();
			this.builder.setState(this.thinking ? { thinking: this.thinking } : {});
		}
		if (change.approvalMode && !this.options.chat) {
			await this.applyMode();
			this.builder.setState({ approvalMode: change.approvalMode });
		}
		this.emit();
	}

	async close(): Promise<void> {
		this.idle.disarm();
		this.broker.cancelAll();
		const conn = this.conn;
		this.conn = undefined;
		if (conn && this.sessionId) await conn.request("session/close", { sessionId: this.sessionId }, 3000).catch(() => undefined);
		conn?.close();
		this.piopio?.close();
		this.piopio = undefined;
	}
}
