/**
 * A conversation run by Claude Code (docs/spec/31, phase A1): the user's own `claude`, signed in with their plan,
 * driven through the Claude Agent SDK in streaming-input mode. Claude Code runs its own loop, tools and settings; this
 * runtime turns its messages into Piopio's timeline, its permission requests into Piopio's prompts (the composer tray),
 * and keeps Piopio's copy of the transcript (pi-shaped messages, as `TimelineBuilder` reads them) with Claude Code's
 * session id, so a reopened conversation shows its history and continues the same Claude Code session.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { ApprovalMode, Attachment, AttachmentInfo, ContainerRef, ModelRef, PromptResponse, Snapshot } from "@piopio/protocol";
import { CLAUDE_CODE, CLAUDE_CODE_NAME, type AgentMessage, type AgentPermissionMode, type AgentQuery, type AgentUserMessage, type CanUseTool, type ClaudeCodeAgent } from "../coding-agents.js";
import { EngineError } from "../models.js";
import { TimelineBuilder, type PiContentBlock, type PiMessage, type PiUsage, type ToolImageKeeper } from "../timeline/builder.js";
import { PromptBroker } from "./prompts.js";
import { Emitter, type Runtime, type SubmitOptions } from "./runtime.js";

type Stored = { version: 1; sessionId?: string; messages: PiMessage[] };
type Input = { text: string; attachments: (Attachment & { stored?: string })[] };

export type ClaudeCodeOpenOptions = {
	ref: ContainerRef;
	cwd: string;
	model: ModelRef;
	thinking?: string;
	/** Piopio's copy of the transcript (JSON). */
	file: string;
	agent: ClaudeCodeAgent;
	/** The conversation's approval mode, read when a session starts and when it changes (CA4). */
	approvalMode: () => ApprovalMode;
	/** A chat (no project): runs in its own folder, in Auto-edit, with no approval mode to show. */
	chat?: boolean;
	keepImages?: ToolImageKeeper;
	/** Something waits on the user (an approval, a question), for notifications. */
	onAttention?: (kind: "approval" | "question", message: string) => void;
};

/** Piopio's approval modes as Claude Code's permission modes (CA4). */
export function permissionMode(mode: ApprovalMode): AgentPermissionMode {
	if (mode === "read_only") return "plan";
	if (mode === "auto_edit") return "acceptEdits";
	if (mode === "full_auto") return "bypassPermissions";
	return "default";
}

/** Piopio's thinking levels as Claude Code's effort. */
function effortFor(thinking: string | undefined): string | undefined {
	if (!thinking || thinking === "default") return undefined;
	if (thinking === "off" || thinking === "minimal") return "low";
	return ["low", "medium", "high", "xhigh", "max"].includes(thinking) ? thinking : undefined;
}

/**
 * Claude Code's tools under Piopio's names, so the transcript gives them its file, diff and terminal details
 * (`timeline/tool-details.ts`); other tools keep their own names.
 */
export function piopioTool(name: string, input: Record<string, unknown>): { name: string; args: Record<string, unknown> } {
	const path = typeof input.file_path === "string" ? input.file_path : typeof input.notebook_path === "string" ? input.notebook_path : undefined;
	switch (name) {
		case "Bash":
			return { name: "bash", args: input };
		case "Read":
			return { name: "read", args: { ...input, ...(path ? { path } : {}) } };
		case "Write":
			return { name: "write", args: { ...input, ...(path ? { path } : {}) } };
		case "Edit":
		case "MultiEdit":
		case "NotebookEdit":
			return { name: "edit", args: { ...input, ...(path ? { path } : {}) } };
		case "Grep":
			return { name: "grep", args: input };
		case "Glob":
			return { name: "find", args: input };
		case "WebSearch":
			return { name: "web_search", args: input };
		case "WebFetch":
			return { name: "web_fetch", args: input };
		case "TodoWrite": {
			const todos = Array.isArray(input.todos) ? (input.todos as { content?: unknown; status?: unknown }[]) : [];
			const items = todos.map((t) => ({ text: String(t.content ?? ""), status: t.status === "completed" ? "done" : t.status === "in_progress" ? "in_progress" : "pending" }));
			return { name: "todo", args: { ...input, items } };
		}
		default:
			return { name, args: input };
	}
}

/** An Edit's change as a unified patch (old lines out, new lines in), for the diff card. */
export function editPatch(input: Record<string, unknown>): string | undefined {
	const edits = Array.isArray(input.edits) ? (input.edits as { old_string?: unknown; new_string?: unknown }[]) : [{ old_string: input.old_string, new_string: input.new_string }];
	const hunks = edits.flatMap((e) => {
		if (typeof e.old_string !== "string" || typeof e.new_string !== "string") return [];
		const old = e.old_string.split("\n");
		const neu = e.new_string.split("\n");
		return [`@@ -1,${old.length} +1,${neu.length} @@\n${[...old.map((l) => `-${l}`), ...neu.map((l) => `+${l}`)].join("\n")}`];
	});
	return hunks.length ? hunks.join("\n") : undefined;
}

/** What an approval asks, in Piopio's words ("Run a command", "Edit notes.md"); the composer already names the agent. */
function approvalTitle(tool: string, input: Record<string, unknown>): { title: string; detail?: string } {
	const path = typeof input.file_path === "string" ? input.file_path : undefined;
	const file = path?.split("/").pop();
	if (tool === "Bash") return { title: "Run a command", ...(typeof input.command === "string" ? { detail: input.command } : {}) };
	if (tool === "Write") return { title: file ? `Write ${file}` : "Write a file", ...(path ? { detail: path } : {}) };
	if (tool === "Edit" || tool === "MultiEdit" || tool === "NotebookEdit") return { title: file ? `Edit ${file}` : "Edit a file", ...(path ? { detail: path } : {}) };
	if (tool === "WebFetch") return { title: "Open a page", ...(typeof input.url === "string" ? { detail: input.url } : {}) };
	if (tool.startsWith("mcp__")) return { title: `Use ${tool.split("__").slice(2).join("__") || tool}`, detail: JSON.stringify(input).slice(0, 400) };
	return { title: `Use ${tool}`, detail: JSON.stringify(input).slice(0, 400) };
}

/** The rule "Always allow" adds, in Piopio's words, from Claude Code's own suggestion. */
function ruleFor(tool: string, input: Record<string, unknown>, suggestions: unknown[] | undefined): { kind: "command" | "tool" | "path"; pattern: string } | undefined {
	if (!suggestions?.length) return undefined;
	if (tool === "Bash" && typeof input.command === "string") return { kind: "command", pattern: input.command.trim().split(/\s+/)[0] ?? input.command };
	if ((tool === "Write" || tool === "Edit" || tool === "MultiEdit") && typeof input.file_path === "string") return { kind: "path", pattern: `${dirname(input.file_path)}/**` };
	return { kind: "tool", pattern: tool };
}

const textOf = (content: unknown): string => {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return (content as { type?: string; text?: string }[]).map((b) => (b.type === "text" ? (b.text ?? "") : b.type === "image" ? "[image]" : "")).filter(Boolean).join("\n");
};

function imagesOf(content: unknown): PiContentBlock[] {
	if (!Array.isArray(content)) return [];
	return (content as { type?: string; source?: { type?: string; media_type?: string; data?: string } }[]).flatMap((b) =>
		b.type === "image" && b.source?.type === "base64" && b.source.data ? [{ type: "image" as const, mimeType: b.source.media_type ?? "image/png", data: b.source.data }] : [],
	);
}

function usageOf(u: unknown): PiUsage | undefined {
	if (!u || typeof u !== "object") return undefined;
	const x = u as { input_tokens?: number; output_tokens?: number; cache_read_input_tokens?: number; cache_creation_input_tokens?: number };
	// The plan pays, not Piopio's spending (CA6).
	return { input: x.input_tokens ?? 0, output: x.output_tokens ?? 0, cacheRead: x.cache_read_input_tokens ?? 0, cacheWrite: x.cache_creation_input_tokens ?? 0, cost: { total: 0 } };
}

/** A queue the SDK reads the user's messages from (streaming input); `end()` lets the session finish. */
class Inbox implements AsyncIterable<AgentUserMessage> {
	private queue: AgentUserMessage[] = [];
	private waiting?: (r: IteratorResult<AgentUserMessage>) => void;
	private ended = false;

	push(message: AgentUserMessage): void {
		if (this.waiting) {
			const w = this.waiting;
			this.waiting = undefined;
			w({ value: message, done: false });
		} else this.queue.push(message);
	}

	end(): void {
		this.ended = true;
		this.waiting?.({ value: undefined as never, done: true });
		this.waiting = undefined;
	}

	[Symbol.asyncIterator](): AsyncIterator<AgentUserMessage> {
		return {
			next: () => {
				const next = this.queue.shift();
				if (next) return Promise.resolve({ value: next, done: false });
				if (this.ended) return Promise.resolve({ value: undefined as never, done: true });
				return new Promise((resolve) => (this.waiting = resolve));
			},
		};
	}
}

type Streaming = { id: string; index: number; messageId?: string; blocks: PiContentBlock[]; usage?: PiUsage; error?: string };

export class ClaudeCodeRuntime implements Runtime {
	readonly ref: ContainerRef;
	private readonly builder: TimelineBuilder;
	private readonly emitter = new Emitter();
	private readonly broker = new PromptBroker();
	private stored: Stored;
	private model: ModelRef;
	private thinking?: string;
	private query?: AgentQuery;
	private inbox?: Inbox;
	private current?: Streaming;
	private followUps: Input[] = [];
	private readonly toolStarted = new Map<string, { name: string; input: Record<string, unknown>; at: number }>();
	private stderr = "";
	private busy = false;
	/** Stopped by the user: the turn's "interrupted" result isn't an error. */
	private stopping = false;

	private constructor(private readonly options: ClaudeCodeOpenOptions) {
		this.ref = options.ref;
		this.model = options.model;
		if (options.thinking) this.thinking = options.thinking;
		this.builder = new TimelineBuilder(options.ref);
		if (options.keepImages) this.builder.keepImages = options.keepImages;
		this.stored = ClaudeCodeRuntime.load(options.file);
		this.builder.reset(this.stored.messages, (i) => `m${i}`, false);
		this.builder.setState({ status: "idle", model: this.model, prompts: [], ...(this.thinking ? { thinking: this.thinking } : {}), ...(options.chat ? {} : { approvalMode: options.approvalMode() }) });
		this.builder.flush();
		this.broker.onChange = (prompts, changed, added) => {
			if (changed.callId) this.builder.toolStatus(changed.callId, added ? "pending_approval" : "running");
			this.builder.setState({ prompts, status: prompts.length ? "waiting_approval" : this.busy ? "running" : "idle" });
			this.emit();
		};
		this.broker.onAdded = (prompt) => options.onAttention?.(prompt.kind === "question" ? "question" : "approval", prompt.title);
	}

	static async open(options: ClaudeCodeOpenOptions): Promise<ClaudeCodeRuntime> {
		return new ClaudeCodeRuntime(options);
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

	/** Claude Code's own session id, once it started one. */
	get sessionId(): string | undefined {
		return this.stored.sessionId;
	}

	snapshot(): Snapshot {
		return this.builder.snapshot();
	}

	onEvents(listener: (events: import("@piopio/protocol").SessionEvent[]) => void): () => void {
		return this.emitter.on(listener);
	}

	private emit(): void {
		this.emitter.emit(this.builder.flush());
	}

	respond(promptId: string, response: PromptResponse): void {
		this.broker.respond(promptId, response);
	}

	async submit(text: string, options: SubmitOptions): Promise<{ disposition: "started" | "queued" }> {
		const input: Input = { text, attachments: options.attachments ?? [] };
		if (this.busy) {
			if (options.whenBusy === "reject") throw new EngineError("BUSY", `${CLAUDE_CODE_NAME} is still working.`);
			// Steering and follow-ups both wait for the turn to end (A1).
			this.followUps.push(input);
			this.builder.setState({ queue: this.followUps.map((f, i) => ({ id: `q${i}`, mode: "followUp" as const, text: f.text })) });
			this.emit();
			return { disposition: "queued" };
		}
		await this.start(input);
		return { disposition: "started" };
	}

	private async start(input: Input): Promise<void> {
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
			await this.ensureQuery();
		} catch (error) {
			this.fail((error as Error).message);
			return;
		}
		this.inbox!.push({ type: "user", message: { role: "user", content: this.content(input) }, parent_tool_use_id: null });
	}

	/** The message as Claude Code reads it: words, text files inline, images as image blocks. */
	private content(input: Input): unknown {
		if (!input.attachments.length) return input.text;
		const blocks: unknown[] = [];
		for (const a of input.attachments) {
			if (a.kind === "image") blocks.push({ type: "image", source: { type: "base64", media_type: a.mimeType, data: a.data } });
			else blocks.push({ type: "text", text: `${a.path ?? a.name}:\n\n${a.text}` });
		}
		blocks.push({ type: "text", text: input.text });
		return blocks;
	}

	private async ensureQuery(): Promise<void> {
		if (this.query) return;
		const status = await this.options.agent.status();
		if (!status.path) throw new EngineError("AUTH", `${CLAUDE_CODE_NAME} isn't installed on this Mac. Install it, or pick another model.`);
		if (!status.signedIn) throw new EngineError("AUTH", `${CLAUDE_CODE_NAME} is signed out. Run \`claude\` in Terminal to sign in, or pick another model.`);
		const query = await this.options.agent.queryFn();
		const mode = this.options.chat ? "acceptEdits" : permissionMode(this.options.approvalMode());
		const effort = effortFor(this.thinking);
		this.inbox = new Inbox();
		this.stderr = "";
		this.query = query({
			prompt: this.inbox,
			options: {
				cwd: this.options.cwd,
				pathToClaudeCodeExecutable: status.path,
				model: this.model.id,
				permissionMode: mode,
				...(mode === "bypassPermissions" ? { allowDangerouslySkipPermissions: true } : {}),
				canUseTool: this.canUseTool,
				includePartialMessages: true,
				thinking: { type: "adaptive", display: "summarized" },
				...(effort ? { effort } : {}),
				...(this.stored.sessionId ? { resume: this.stored.sessionId } : {}),
				// The user's own Claude Code setup applies: CLAUDE.md, their settings, MCP servers and skills (CA2).
				settingSources: ["user", "project", "local"],
				stderr: (data: string) => (this.stderr = (this.stderr + data).slice(-2000)),
			},
		});
		void this.pump(this.query);
	}

	private async pump(q: AgentQuery): Promise<void> {
		try {
			for await (const m of q) this.apply(m);
			if (this.busy) this.fail(this.stderr.trim().split("\n").pop() || `${CLAUDE_CODE_NAME} stopped.`);
		} catch (error) {
			const message = (error as Error).message || `${CLAUDE_CODE_NAME} stopped.`;
			// A session Claude Code no longer has: the next message starts a new one.
			if (/no conversation found|session.*not found/i.test(message + this.stderr) && this.stored.sessionId) {
				delete this.stored.sessionId;
				this.save();
			}
			if (this.busy) this.fail(message);
		} finally {
			if (this.query === q) {
				this.query = undefined;
				this.inbox = undefined;
			}
		}
	}

	private fail(message: string): void {
		this.endAssistant();
		this.builder.system(`e${Date.now()}`, "error", `${CLAUDE_CODE_NAME}: ${message}`);
		this.busy = false;
		this.followUps = [];
		this.builder.setState({ status: "idle", queue: [] });
		this.emit();
	}

	private apply(m: AgentMessage): void {
		if (m.parent_tool_use_id) return; // a subagent's inner messages (Claude Code's Task tool): its result arrives as the tool's output
		if (m.type === "system" && m.subtype === "init" && typeof m.session_id === "string") {
			if (this.stored.sessionId !== m.session_id) {
				this.stored.sessionId = m.session_id;
				this.save();
			}
			return;
		}
		if (m.type === "stream_event") return this.streamEvent(m.event as { type: string; index?: number; delta?: { type: string; text?: string; thinking?: string }; message?: { id?: string } });
		if (m.type === "assistant") return this.assistant(m);
		if (m.type === "user") return this.toolResults(m);
		if (m.type === "result") return this.result(m);
	}

	private beginAssistant(messageId?: string): Streaming {
		const index = this.stored.messages.length;
		// Reserved now, so the tool results that follow get the next places; filled in when the message ends.
		this.stored.messages.push({ role: "assistant", content: [], provider: CLAUDE_CODE, model: this.model.id, timestamp: Date.now() });
		const s: Streaming = { id: `m${index}`, index, blocks: [], ...(messageId ? { messageId } : {}) };
		this.current = s;
		this.builder.assistantStart(s.id, `${CLAUDE_CODE}/${this.model.id}`);
		return s;
	}

	private streamEvent(e: { type: string; index?: number; delta?: { type: string; text?: string; thinking?: string }; message?: { id?: string } }): void {
		if (e.type === "message_start") {
			this.endAssistant();
			this.beginAssistant(e.message?.id);
		} else if (e.type === "content_block_delta" && this.current) {
			if (e.delta?.type === "text_delta") this.builder.assistantDelta(e.index ?? 0, "text", e.delta.text ?? "");
			else if (e.delta?.type === "thinking_delta") this.builder.assistantDelta(e.index ?? 0, "thinking", e.delta.thinking ?? "");
		} else if (e.type === "message_stop") {
			this.endAssistant();
		}
		this.emit();
	}

	private assistant(m: AgentMessage): void {
		const message = (m.message ?? {}) as { id?: string; content?: { type: string; text?: string; thinking?: string; id?: string; name?: string; input?: Record<string, unknown> }[]; usage?: unknown };
		let s = this.current;
		if (!s || (message.id && s.messageId && s.messageId !== message.id)) {
			this.endAssistant();
			s = this.beginAssistant(message.id);
		}
		s.messageId ??= message.id;
		for (const b of message.content ?? []) {
			if (b.type === "text" && b.text) s.blocks.push({ type: "text", text: b.text });
			else if (b.type === "thinking" && b.thinking) s.blocks.push({ type: "thinking", thinking: b.thinking });
			else if (b.type === "tool_use" && b.id && b.name) {
				const input = b.input ?? {};
				const tool = piopioTool(b.name, input);
				s.blocks.push({ type: "toolCall", id: b.id, name: tool.name, arguments: tool.args });
				this.toolStarted.set(b.id, { name: b.name, input, at: Date.now() });
			}
		}
		const usage = usageOf(message.usage);
		if (usage) s.usage = usage;
		if (typeof m.error === "string") s.error = m.error;
		this.emit();
	}

	/** Completes the answer being written, then shows its tool calls as running. */
	private endAssistant(): void {
		const s = this.current;
		if (!s) return;
		this.current = undefined;
		const message = {
			role: "assistant" as const,
			content: s.blocks,
			provider: CLAUDE_CODE,
			model: this.model.id,
			timestamp: (this.stored.messages[s.index]?.timestamp as number | undefined) ?? Date.now(),
			...(s.usage ? { usage: s.usage } : {}),
			...(s.error ? { stopReason: "error", errorMessage: s.error } : {}),
		};
		this.stored.messages[s.index] = message;
		this.save();
		this.builder.assistantEnd(message);
		for (const b of s.blocks) if (b.type === "toolCall") this.builder.toolStart(b.id, b.name, b.arguments);
	}

	private toolResults(m: AgentMessage): void {
		const content = (m.message as { content?: unknown } | undefined)?.content;
		if (!Array.isArray(content)) return;
		const results = (content as { type?: string; tool_use_id?: string; content?: unknown; is_error?: boolean }[]).filter((b) => b.type === "tool_result" && b.tool_use_id);
		if (!results.length) return;
		this.endAssistant();
		for (const r of results) {
			const callId = r.tool_use_id!;
			const started = this.toolStarted.get(callId);
			this.toolStarted.delete(callId);
			const tool = piopioTool(started?.name ?? "tool", started?.input ?? {});
			const output = textOf(r.content);
			const images = imagesOf(r.content);
			const patch = tool.name === "edit" && !r.is_error ? editPatch(started?.input ?? {}) : undefined;
			const piContent: PiContentBlock[] = [{ type: "text", text: output }, ...images];
			this.stored.messages.push({ role: "toolResult", toolCallId: callId, toolName: tool.name, content: piContent, ...(patch ? { details: { patch } } : {}), isError: Boolean(r.is_error), timestamp: Date.now() });
			this.builder.toolEnd(callId, output, Boolean(r.is_error), started ? Date.now() - started.at : undefined, { ...(patch ? { details: { patch } } : {}), content: piContent });
		}
		this.save();
		this.emit();
	}

	private result(m: AgentMessage): void {
		this.endAssistant();
		if (this.stopping) this.stopping = false;
		else if (m.subtype !== "success" || m.is_error === true) {
			const errors = Array.isArray(m.errors) ? (m.errors as string[]).join(" ") : "";
			const text = errors || (typeof m.result === "string" ? m.result : "") || `${CLAUDE_CODE_NAME} couldn't finish.`;
			if (m.subtype !== "success") this.builder.system(`e${Date.now()}`, "error", `${CLAUDE_CODE_NAME}: ${text}`);
		}
		this.busy = false;
		this.builder.setState({ status: this.broker.list().length ? "waiting_approval" : "idle" });
		this.emit();
		const next = this.followUps.shift();
		if (next) {
			this.builder.setState({ queue: this.followUps.map((f, i) => ({ id: `q${i}`, mode: "followUp" as const, text: f.text })) });
			void this.start(next);
		}
	}

	/** Claude Code's permission requests, as Piopio's prompts (CA4). */
	private canUseTool: CanUseTool = async (tool, input, options) => {
		if (tool === "AskUserQuestion") return this.askQuestions(input, options.signal);
		if (tool === "ExitPlanMode") {
			if (!this.options.chat && this.options.approvalMode() === "read_only") {
				return { behavior: "deny", message: "This conversation is read only. The user can change its mode to let you make changes." };
			}
			const plan = typeof input.plan === "string" ? input.plan : "";
			const answer = await this.broker.ask({ kind: "confirm", title: `${CLAUDE_CODE_NAME}'s plan`, message: plan || "Start making changes?" }, options.signal);
			if (answer?.confirmed) return { behavior: "allow", updatedInput: input };
			return { behavior: "deny", message: answer ? "The user wants to keep planning." : "The plan wasn't answered." };
		}
		const { title, detail } = approvalTitle(tool, input);
		const rule = ruleFor(tool, input, options.suggestions);
		const tool_ = piopioTool(tool, input);
		const answer = await this.broker.ask(
			{
				kind: "approval",
				title,
				...(detail ? { detail } : {}),
				tool: tool_.name,
				...(options.toolUseID ? { callId: options.toolUseID } : {}),
				...(options.decisionReason ? { reason: options.decisionReason } : {}),
				...(rule ? { rule } : {}),
			},
			options.signal,
		);
		if (!answer) return { behavior: "deny", message: "The user stopped this.", interrupt: true };
		if (answer.decision === "allow" || answer.decision === "always") {
			return { behavior: "allow", updatedInput: input, ...(answer.decision === "always" && options.suggestions?.length ? { updatedPermissions: options.suggestions } : {}) };
		}
		return { behavior: "deny", message: answer.text?.trim() ? `The user said no: ${answer.text.trim()}` : "The user said no." };
	};

	private async askQuestions(input: Record<string, unknown>, signal: AbortSignal) {
		const questions = Array.isArray(input.questions) ? (input.questions as { question?: string; options?: { label?: string }[] }[]) : [];
		const answers: Record<string, string> = {};
		for (const q of questions) {
			if (!q.question) continue;
			const options = (q.options ?? []).map((o) => o.label ?? "").filter(Boolean);
			const answer = await this.broker.ask({ kind: "question", title: q.question, ...(options.length ? { options } : {}) }, signal);
			const said = answer?.choice ?? answer?.text;
			if (!said) return { behavior: "deny" as const, message: "The user didn't answer." };
			answers[q.question] = said;
		}
		return { behavior: "allow" as const, updatedInput: { ...input, answers } };
	}

	async abort(): Promise<void> {
		if (this.busy) this.stopping = true;
		this.followUps = [];
		this.broker.cancelAll();
		this.builder.setState({ queue: [] });
		this.emit();
		await this.query?.interrupt().catch(() => undefined);
	}

	async configure(change: { model?: ModelRef; thinking?: string; approvalMode?: ApprovalMode }): Promise<void> {
		if (change.model) {
			if (change.model.provider !== CLAUDE_CODE) throw new EngineError("INVALID", `This conversation runs in ${CLAUDE_CODE_NAME}. Start a new conversation to use another model.`);
			this.model = change.model;
			await this.query?.setModel(change.model.id).catch(() => undefined);
			this.builder.setState({ model: this.model });
		}
		if (change.thinking) {
			if (change.thinking === "default") delete this.thinking;
			else this.thinking = change.thinking;
			// Effort is set when Claude Code's session starts: the next one picks it up.
			this.builder.setState(this.thinking ? { thinking: this.thinking } : {});
		}
		if (change.approvalMode && !this.options.chat) {
			await this.query?.setPermissionMode(permissionMode(change.approvalMode)).catch(() => undefined);
			this.builder.setState({ approvalMode: change.approvalMode });
		}
		this.emit();
	}

	async close(): Promise<void> {
		this.broker.cancelAll();
		this.inbox?.end();
		this.query?.close();
		this.query = undefined;
		this.inbox = undefined;
	}
}
