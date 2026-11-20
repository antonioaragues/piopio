/**
 * A pretend ACP agent (PIOPIO_FAKE_ACP=1, tests and captures), run as `node acp-fake-agent.js <antigravity-cli|codex-cli>`.
 * It speaks ACP over stdio like Antigravity CLI and Codex do, and answers "Echo: <message>". Lines of a message script
 * tool calls first, asking permission as the real ones do:
 *   $ <command>                  an `execute` call (not run; its output says so)
 *   write: <path> | <content>    an `edit` call with a diff (the file is written once allowed)
 *   plan: <step> | <step>…       a plan update
 *   effort? / mode? / model?     answers with the session's setting
 * No imports from the project: Node runs it as it is.
 */
import { writeFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";

const agent = process.argv[2] ?? "antigravity-cli";
const isCodex = agent === "codex-cli";
let nextId = 1000;
let counter = 0;
const waiting = new Map<number, (result: any) => void>();
const sessions = new Map<string, { cwd: string; options: any[]; cancelled: boolean }>();

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
	const answer = q === "effort?" ? `Effort: ${setting(s, thinkingId)}` : q === "mode?" ? `Mode: ${setting(s, "mode")}` : q === "model?" ? `Model: ${setting(s, "model")}` : `Echo: ${[...resources, text].join("\n")}`;
	update(sessionId, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Thinking it over." } });
	for (const piece of answer.match(/.{1,12}/gs) ?? []) update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: piece } });
	update(sessionId, { sessionUpdate: "usage_update", used: 1200, size: 200000 });
	return { stopReason: "end_turn", usage: { inputTokens: 10, outputTokens: 5, cachedReadTokens: 0, cachedWriteTokens: 0 } };
}

async function handle(m: any): Promise<unknown> {
	const p = m.params ?? {};
	switch (m.method) {
		case "initialize":
			return { protocolVersion: 1, agentInfo: { name: `fake ${agent}`, version: "1.0.0-fake" }, agentCapabilities: { loadSession: true, sessionCapabilities: { close: {}, delete: {} } }, authMethods: [] };
		case "session/new": {
			const sessionId = `fake-acp-${process.pid}-${++counter}`;
			sessions.set(sessionId, { cwd: p.cwd, options: configOptions(), cancelled: false });
			if (isCodex) send({ jsonrpc: "2.0", method: "_auth/status_update", params: { authStatus: { kind: "account", label: "ChatGPT Plus" } } });
			return { sessionId, configOptions: sessions.get(sessionId)!.options, ...(isCodex ? {} : { _meta: { antigravity: { tier: { name: "Google AI Pro" } } } }) };
		}
		case "session/load": {
			sessions.set(p.sessionId, { cwd: p.cwd, options: configOptions(), cancelled: false });
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
