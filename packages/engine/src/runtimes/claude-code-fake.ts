/**
 * A pretend Claude Code with the Agent SDK's `query` shape (PIOPIO_FAKE_CLAUDE_CODE=1, tests): it answers
 * "Echo: <message>", and lines of the message script tool calls first, asking through `canUseTool` as the real one
 * does:
 *   write: <path> | <content>     Write (the file is written once allowed)
 *   $ <command>                    Bash (not run; the output says so)
 *   ask: <question> | <option>…    AskUserQuestion
 *   call: <tool> | <JSON arguments>  one of Piopio's tools, through the "piopio" MCP server it was given (as the real one)
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import type { AgentMessage, AgentModel, AgentPermissionMode, AgentQuery, AgentUserMessage, CanUseTool, QueryFn } from "../coding-agents.js";

let counter = 0;
/** Each query is one Claude Code process: "process?" says which, and whether it resumed a session. */
let queries = 0;

export const fakeClaudeQuery: QueryFn = ({ prompt, options }) => new FakeQuery(prompt, options);

export const FAKE_MODELS: AgentModel[] = [
	{ value: "opus", displayName: "Opus 5.5", description: "Best for everyday, complex tasks" },
	{ value: "sonnet", displayName: "Sonnet 5.5", description: "Efficient for routine tasks" },
	{ value: "haiku", displayName: "Haiku 5.5", description: "Fastest for quick answers" },
];

class FakeQuery implements AgentQuery {
	model: string;
	mode: AgentPermissionMode;
	private interrupted = false;
	private closed = false;
	private readonly sessionId: string;
	private readonly instance = ++queries;
	private mcp?: Promise<Client>;

	constructor(
		private readonly prompt: string | AsyncIterable<AgentUserMessage>,
		private readonly options: Record<string, unknown>,
	) {
		this.model = (options.model as string | undefined) ?? "opus";
		this.mode = (options.permissionMode as AgentPermissionMode | undefined) ?? "default";
		this.sessionId = (options.resume as string | undefined) ?? `fake-session-${++counter}`;
	}

	/** A client of the in-process "piopio" MCP server the runtime passed. */
	private piopio(): Promise<Client> {
		this.mcp ??= (async () => {
			const server = (this.options.mcpServers as { piopio?: { instance: { connect: (t: unknown) => Promise<void> } } } | undefined)?.piopio;
			if (!server) throw new Error("No piopio MCP server.");
			const [client, transport] = InMemoryTransport.createLinkedPair();
			await server.instance.connect(transport);
			const c = new Client({ name: "fake-claude-code", version: "1.0.0" });
			await c.connect(client);
			return c;
		})();
		return this.mcp;
	}

	private costSoFar = 0;

	async interrupt(): Promise<void> {
		this.interrupted = true;
	}
	async setModel(model?: string): Promise<void> {
		if (model) this.model = model;
	}
	async setPermissionMode(mode: AgentPermissionMode): Promise<void> {
		this.mode = mode;
	}
	async supportedModels(): Promise<AgentModel[]> {
		return FAKE_MODELS;
	}
	close(): void {
		this.closed = true;
	}

	async *[Symbol.asyncIterator](): AsyncIterator<AgentMessage> {
		// PIOPIO_FAKE_CLAUDE_KEY=1: signed in with an API key, not a plan (its cost is spending, CA6).
		yield { type: "system", subtype: "init", session_id: this.sessionId, model: this.model, permissionMode: this.mode, apiKeySource: process.env.PIOPIO_FAKE_CLAUDE_KEY === "1" ? "ANTHROPIC_API_KEY" : "none" };
		const messages: AsyncIterable<AgentUserMessage> =
			typeof this.prompt === "string" ? (async function* (p: string) { yield { type: "user", message: { role: "user", content: p }, parent_tool_use_id: null } as AgentUserMessage; })(this.prompt) : this.prompt;
		for await (const m of messages) {
			if (this.closed) return;
			this.interrupted = false;
			yield* this.turn(textOf(m.message.content));
			if (this.closed) return;
		}
	}

	private async *turn(text: string): AsyncGenerator<AgentMessage> {
		const canUseTool = this.options.canUseTool as CanUseTool | undefined;
		const cwd = (this.options.cwd as string | undefined) ?? process.cwd();
		for (const line of text.split("\n")) {
			if (this.interrupted) break;
			const call = scripted(line, cwd);
			if (!call) continue;
			const id = `toolu_fake${++counter}`;
			yield* this.message([{ type: "tool_use", id, name: call.name, input: call.input }]);
			const auto = call.name.startsWith("mcp__") ? false : call.name !== "AskUserQuestion" && (this.mode === "bypassPermissions" || (this.mode === "acceptEdits" && call.name === "Write"));
			const decision = auto || !canUseTool ? { behavior: "allow" as const, updatedInput: call.input } : await canUseTool(call.name, call.input, { signal: new AbortController().signal, suggestions: [{ type: "addRules" }], toolUseID: id });
			if (this.interrupted) break;
			let output: string;
			let isError = false;
			if (decision.behavior === "deny") {
				output = decision.message;
				isError = true;
			} else if (call.name === "Write") {
				const path = call.input.file_path as string;
				mkdirSync(dirname(path), { recursive: true });
				writeFileSync(path, call.input.content as string);
				output = `File created successfully at: ${path}`;
			} else if (call.name.startsWith("mcp__piopio__")) {
				const r = (await (await this.piopio()).callTool({ name: call.name.slice("mcp__piopio__".length), arguments: call.input })) as { content?: { type: string; text?: string }[]; isError?: boolean };
				output = (r.content ?? []).map((c) => c.text ?? `[${c.type}]`).join("\n");
				isError = Boolean(r.isError);
			} else if (call.name === "AskUserQuestion") {
				output = `The user answered: ${JSON.stringify((decision.updatedInput as { answers?: unknown } | undefined)?.answers ?? {})}`;
			} else output = `(pretend) ran ${String(call.input.command)}`;
			yield { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: output, is_error: isError }] }, parent_tool_use_id: null };
		}
		if (this.interrupted) {
			yield { type: "result", subtype: "error_during_execution", is_error: true, errors: ["Interrupted"], session_id: this.sessionId };
			return;
		}
		// "effort?": which effort the session started with (thinking level tests).
		// "process?": which process this is, and whether it resumed the session (idle tests).
		const answer =
			text.trim() === "effort?"
				? `Effort: ${(this.options.effort as string | undefined) ?? "default"}`
				: text.trim() === "process?"
					? `Process: ${this.instance} ${this.options.resume ? `resumed ${String(this.options.resume)}` : "new"}`
					: `Echo: ${text}`;
		yield* this.message([{ type: "text", text: answer }], true);
		// As the SDK reports it: the query's running total, $0.01 a turn.
		this.costSoFar += 0.01;
		yield { type: "result", subtype: "success", is_error: false, result: `Echo: ${text}`, session_id: this.sessionId, total_cost_usd: this.costSoFar, usage: { input_tokens: 10, output_tokens: 5 } };
	}

	/** One API message: stream events around the SDK's assistant message, deltas for text. */
	private async *message(content: { type: string; [key: string]: unknown }[], stream = false): AsyncGenerator<AgentMessage> {
		const id = `msg_fake${++counter}`;
		yield { type: "stream_event", event: { type: "message_start", message: { id, model: this.model } }, parent_tool_use_id: null };
		if (stream) {
			for (const [index, block] of content.entries()) {
				if (block.type !== "text") continue;
				for (const piece of String(block.text).match(/.{1,12}/gs) ?? []) yield { type: "stream_event", event: { type: "content_block_delta", index, delta: { type: "text_delta", text: piece } }, parent_tool_use_id: null };
			}
		}
		yield { type: "assistant", message: { id, content, usage: { input_tokens: 10, output_tokens: 5 } }, parent_tool_use_id: null, session_id: this.sessionId };
		yield { type: "stream_event", event: { type: "message_stop" }, parent_tool_use_id: null };
	}
}

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return (content as { type?: string; text?: string }[]).filter((b) => b.type === "text").map((b) => b.text ?? "").join("\n");
}

function scripted(line: string, cwd: string): { name: string; input: Record<string, unknown> } | undefined {
	const write = /^write:\s*(.+?)\s*\|\s*(.*)$/.exec(line);
	if (write) return { name: "Write", input: { file_path: isAbsolute(write[1]!) ? write[1]! : join(cwd, write[1]!), content: write[2]!.replaceAll("\\n", "\n") } };
	const bash = /^\$\s*(.+)$/.exec(line);
	if (bash) return { name: "Bash", input: { command: bash[1]! } };
	const piopio = /^call:\s*([a-z_]+)\s*\|\s*(.*)$/.exec(line);
	if (piopio) return { name: `mcp__piopio__${piopio[1]}`, input: JSON.parse(piopio[2]!) as Record<string, unknown> };
	const ask = /^ask:\s*(.+)$/.exec(line);
	if (ask) {
		const [question, ...options] = ask[1]!.split("|").map((s) => s.trim());
		return { name: "AskUserQuestion", input: { questions: [{ question, header: "", options: options.map((label) => ({ label, description: "" })), multiSelect: false }] } };
	}
	return undefined;
}
