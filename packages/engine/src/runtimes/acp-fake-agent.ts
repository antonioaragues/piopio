/**
 * A pretend ACP agent (PIOPIO_FAKE_ACP=1, tests and captures), run as `node acp-fake-agent.js <antigravity-cli|codex-cli>`.
 * It speaks ACP over stdio like Antigravity CLI and Codex do, and answers "Echo: <message>". Lines of a message script
 * tool calls first, asking permission as the real ones do:
 *   $ <command>                  an `execute` call (not run; its output says so)
 *   write: <path> | <content>    an `edit` call with a diff (the file is written once allowed)
 *   plan: <step> | <step>…       a plan update
 *   call: <tool> | <JSON>        one of Piopio's tools, through the "piopio" MCP server the session was given (HTTP for
 *                                the Codex flavor, the stdio bridge for the Antigravity one, as the real agents)
 *   effort? / mode? / model?     answers with the session's setting
 *   process?                     answers with this process's id
 * No imports from the project: Node runs it as it is.
 */
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";

const agent = process.argv[2] ?? "antigravity-cli";
const isCodex = agent === "codex-cli";
let nextId = 1000;
let counter = 0;
const waiting = new Map<number, (result: any) => void>();
const sessions = new Map<string, { cwd: string; options: any[]; cancelled: boolean; mcp: any[]; instructions: string }>();
/** The instructions a session was started with: ACP's `systemPrompt` (Codex) or Antigravity's `_meta`. */
const instructionsOf = (p: any): string => (isCodex ? (p.systemPrompt?.content ?? []).map((c: any) => c.text).join("") : (p._meta?.antigravity?.systemPrompt?.append ?? ""));

/** Calls a tool of the session's "piopio" MCP server: by HTTP, or by starting its command and talking over stdio. */
async function callPiopio(server: any, name: string, args: unknown): Promise<any> {
	const messages = [
		{ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "fake-acp-agent", version: "1" } } },
		{ jsonrpc: "2.0", method: "notifications/initialized" },
		{ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name, arguments: args } },
	];
	if (server.type === "http") {
		let result: any;
		for (const m of messages) {
			const res = await fetch(server.url, { method: "POST", headers: { "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify(m) });
			if (res.status === 202) continue;
			const body = await res.json();
			if (body.id === 2) result = body.result ?? { content: [{ type: "text", text: body.error?.message }], isError: true };
		}
		return result;
	}
	const child = spawn(server.command, server.args, { stdio: ["pipe", "pipe", "inherit"] });
	return new Promise((resolve) => {
		let buf = "";
		child.stdout.setEncoding("utf8");
		child.stdout.on("data", (d: string) => {
			buf += d;
			for (const line of buf.split("\n").slice(0, -1)) {
				const m = JSON.parse(line);
				if (m.id === 2) {
					resolve(m.result ?? { content: [{ type: "text", text: m.error?.message }], isError: true });
					child.kill();
				}
			}
			buf = buf.slice(buf.lastIndexOf("\n") + 1);
		});
		for (const m of messages) child.stdin.write(`${JSON.stringify(m)}\n`);
	});
}

const models = isCodex
	? [{ value: "gpt-6.2-sol", name: "6.2 Sol" }, { value: "gpt-6.2-astra", name: "6.2 Astra" }, { value: "gpt-6-luna", name: "6 Luna" }]
	: [{ value: "gemini-4-neon", name: "Gemini 4 Neon" }, { value: "gemini-4-argon", name: "Gemini 4 Argon" }, { value: "gemini-3.8-flash", name: "Gemini 3.8 Flash" }];
const thinkingId = isCodex ? "reasoning_effort" : "thought_level";
const modes = isCodex ? ["read-only", "workspace-write", "agent", "agent-full-access"] : ["default", "accept-edits", "auto", "plan"];

function configOptions() {
	return [
		{ id: "model", name: "Model", category: "model", type: "select", currentValue: models[0]!.value, options: models },
		{ id: thinkingId, name: "Thinking", category: "thought_level", type: "select", currentValue: "high", options: ["low", "medium", "high", "xhigh"].map((v) => ({ value: v, name: v })) },
		{ id: "mode", name: "Mode", category: "mode", type: "select", currentValue: modes[0], options: modes.map((v) => ({ value: v, name: v })) },
	];
}

const send = (m: unknown) => process.stdout.write(`${JSON.stringify(m)}\n`);
const update = (sessionId: string, u: unknown) => send({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update: u } });
const ask = (method: string, params: unknown) =>
	new Promise<any>((resolve) => {
		const id = ++nextId;
		waiting.set(id, resolve);
		send({ jsonrpc: "2.0", id, method, params });
	});
const setting = (s: { options: any[] }, id: string) => s.options.find((o) => o.id === id)?.currentValue;

async function prompt(sessionId: string, blocks: any[]) {
	const s = sessions.get(sessionId)!;
	s.cancelled = false;
	const text = blocks.filter((b) => b.type === "text").map((b) => b.text).join("\n");
	const resources = blocks.filter((b) => b.type === "resource").map((b) => b.resource?.text ?? "");
	for (const line of text.split("\n")) {
		if (s.cancelled) break;
		const plan = /^plan:\s*(.+)$/.exec(line);
		if (plan) {
			update(sessionId, { sessionUpdate: "plan", entries: plan[1]!.split("|").map((c, i) => ({ content: c.trim(), status: i === 0 ? "in_progress" : "pending", priority: "medium" })) });
			continue;
		}
		const call_ = /^call:\s*([a-z_]+)\s*\|\s*(.*)$/.exec(line);
		if (call_) {
			const toolCallId = `call_fake_${++counter}`;
			const args = JSON.parse(call_[2]!);
			if (isCodex) {
				// As Codex 0.170 with codex-acp 2.7 does: an MCP call is kind "execute" with its server, tool and arguments,
				// and the permission request names only the call (unless the mode lets everything run).
				update(sessionId, { sessionUpdate: "tool_call", toolCallId, kind: "execute", status: "pending", rawInput: { server: "piopio", tool: call_[1], arguments: args, command: `mcp.piopio.${call_[1]}` } });
				if (setting(s, "mode") !== "agent-full-access") {
					const answer = await ask("session/request_permission", { sessionId, toolCall: { toolCallId }, options: [{ optionId: "allow", name: "Allow", kind: "allow_once" }, { optionId: "deny", name: "Deny", kind: "reject_once" }] });
					if (answer?.outcome?.optionId !== "allow") {
						update(sessionId, { sessionUpdate: "tool_call_update", toolCallId, status: "failed", content: [{ type: "content", content: { type: "text", text: "Denied." } }] });
						continue;
					}
				}
			} else {
				// As Antigravity CLI 1.5 does: "Run mcp_piopio_<tool>", its arguments with a summary of its own, a permission
				// request for it unless the mode lets everything run, and no result in its update (Piopio shows its own).
				const call = { toolCallId, kind: "other", title: `Run mcp_piopio_${call_[1]}`, status: "pending", rawInput: { ...args, toolSummary: "Doing it" } };
				update(sessionId, { sessionUpdate: "tool_call", ...call });
				if (setting(s, "mode") !== "auto") {
					const answer = await ask("session/request_permission", { sessionId, toolCall: call, options: [{ optionId: "allow", name: "Allow", kind: "allow_once" }, { optionId: "deny", name: "Deny", kind: "reject_once" }] });
					if (answer?.outcome?.optionId !== "allow") {
						update(sessionId, { sessionUpdate: "tool_call_update", toolCallId, status: "failed" });
						continue;
					}
				}
				const server = s.mcp.find((m) => m.name === "piopio");
				const r = server ? await callPiopio(server, call_[1]!, args) : { isError: true };
				update(sessionId, { sessionUpdate: "tool_call_update", toolCallId, status: r?.isError ? "failed" : "completed" });
				continue;
			}
			const server = s.mcp.find((m) => m.name === "piopio");
			const r = server ? await callPiopio(server, call_[1]!, args) : { content: [{ type: "text", text: "No piopio server." }], isError: true };
			update(sessionId, { sessionUpdate: "tool_call_update", toolCallId, status: r?.isError ? "failed" : "completed", content: (r?.content ?? []).map((c: any) => ({ type: "content", content: c })) });
			continue;
		}
		const bash = /^\$\s*(.+)$/.exec(line);
		const write = /^write:\s*(.+?)\s*\|\s*(.*)$/.exec(line);
		if (!bash && !write) continue;
		const toolCallId = `call_fake_${++counter}`;
		const path = write ? (isAbsolute(write[1]!) ? write[1]! : join(s.cwd, write[1]!)) : undefined;
		const call = bash
			? { toolCallId, kind: "execute", title: bash[1], status: "pending", rawInput: { command: bash[1] } }
			: { toolCallId, kind: "edit", title: `File ${write![1]}`, status: "pending", locations: [{ path }], rawInput: { path }, content: [{ type: "diff", path, oldText: null, newText: write![2] }] };
		update(sessionId, { sessionUpdate: "tool_call", ...call });
		const auto = setting(s, "mode") === (isCodex ? "agent-full-access" : "auto") || (write && setting(s, "mode") === (isCodex ? "workspace-write" : "accept-edits"));
		const answer = auto
			? { outcome: { outcome: "selected", optionId: "allow" } }
			: await ask("session/request_permission", { sessionId, toolCall: call, options: [{ optionId: "allow", name: "Allow", kind: "allow_once" }, { optionId: "always", name: "Always", kind: "allow_always" }, { optionId: "deny", name: "Deny", kind: "reject_once" }] });
		const allowed = answer?.outcome?.outcome === "selected" && answer.outcome.optionId !== "deny";
		if (allowed && write) writeFileSync(path!, write[2]!);
		update(sessionId, {
			sessionUpdate: "tool_call_update",
			toolCallId,
			status: allowed ? "completed" : "failed",
			content: allowed ? (write ? call.content : [{ type: "content", content: { type: "text", text: `(pretend) ran ${bash![1]}` } }]) : [{ type: "content", content: { type: "text", text: "The user said no." } }],
			...(bash && allowed ? { _meta: { terminal_exit: { exit_code: 0 } } } : {}),
		});
	}
	if (s.cancelled) return { stopReason: "cancelled" };
	const q = text.trim();
	const answer = q === "instructions?" ? `Instructions: ${s.instructions || "none"}` : q === "effort?" ? `Effort: ${setting(s, thinkingId)}` : q === "mode?" ? `Mode: ${setting(s, "mode")}` : q === "model?" ? `Model: ${setting(s, "model")}` : q === "process?" ? `Process: ${process.pid}` : `Echo: ${[...resources, text].join("\n")}`;
	update(sessionId, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Thinking it over." } });
	for (const piece of answer.match(/.{1,12}/gs) ?? []) update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: piece } });
	update(sessionId, { sessionUpdate: "usage_update", used: 1200, size: 200000 });
	return { stopReason: "end_turn", usage: { inputTokens: 10, outputTokens: 5, cachedReadTokens: 0, cachedWriteTokens: 0 } };
}

async function handle(m: any): Promise<unknown> {
	const p = m.params ?? {};
	switch (m.method) {
		case "initialize":
			return { protocolVersion: 1, agentInfo: { name: `fake ${agent}`, version: "1.0.0-fake" }, agentCapabilities: { loadSession: true, sessionCapabilities: { close: {}, delete: {}, ...(isCodex ? { systemPrompt: {} } : {}) }, ...(isCodex ? { mcpCapabilities: { http: true, sse: false } } : { _meta: { antigravity: { systemPrompt: { append: true } } } }) }, authMethods: [] };
		case "session/new": {
			const sessionId = `fake-acp-${process.pid}-${++counter}`;
			sessions.set(sessionId, { cwd: p.cwd, options: configOptions(), cancelled: false, mcp: p.mcpServers ?? [], instructions: instructionsOf(p) });
			if (isCodex) send({ jsonrpc: "2.0", method: "_auth/status_update", params: { authStatus: { kind: "account", label: "ChatGPT Plus" } } });
			return { sessionId, configOptions: sessions.get(sessionId)!.options, ...(isCodex ? {} : { _meta: { antigravity: { tier: { name: "Google AI Pro" } } } }) };
		}
		case "session/load": {
			sessions.set(p.sessionId, { cwd: p.cwd, options: configOptions(), cancelled: false, mcp: p.mcpServers ?? [], instructions: instructionsOf(p) });
			// The real agents replay the conversation; the client already has it.
			update(p.sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "(replayed history)" } });
			return { configOptions: sessions.get(p.sessionId)!.options };
		}
		case "session/set_config_option": {
			const s = sessions.get(p.sessionId)!;
			const o = s.options.find((x) => x.id === p.configId);
			if (o) o.currentValue = p.value;
			return { configOptions: s.options };
		}
		case "session/prompt":
			return prompt(p.sessionId, p.prompt ?? []);
		case "session/close":
		case "session/delete":
			sessions.delete(p.sessionId);
			return {};
		default:
			throw Object.assign(new Error("Method not found"), { code: -32601 });
	}
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d: string) => {
	buf += d;
	let i: number;
	while ((i = buf.indexOf("\n")) >= 0) {
		const line = buf.slice(0, i).trim();
		buf = buf.slice(i + 1);
		if (!line) continue;
		const m = JSON.parse(line);
		if (m.method === "session/cancel") {
			const s = sessions.get(m.params?.sessionId);
			if (s) s.cancelled = true;
		} else if (m.method && m.id !== undefined) {
			handle(m).then(
				(result) => send({ jsonrpc: "2.0", id: m.id, result }),
				(e) => send({ jsonrpc: "2.0", id: m.id, error: { code: e.code ?? -32603, message: e.message } }),
			);
		} else if (m.id !== undefined && waiting.has(m.id)) {
			waiting.get(m.id)!(m.result);
			waiting.delete(m.id);
		}
	}
});
process.stdin.on("end", () => process.exit(0));
