/**
 * Coding agents over the Agent Client Protocol (docs/spec/31, phase A3): Antigravity CLI (`agy acp`, Google's own ACP
 * server) and Codex (`codex-acp`, the ACP adapter for OpenAI's Codex). One client for both: a JSON-RPC connection over
 * the agent's stdio, and a description of each agent (how to start it, its modes, which setting is its thinking level,
 * how to install it and sign in). This file also finds them and reads what they offer (plan, models) for Settings ›
 * Models and the picker. Conversations run in `runtimes/acp.ts`.
 */
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ApprovalMode, ModelInfo, ProviderInfo } from "@piopio/protocol";

// ── The protocol ────────────────────────────────────────────────────────────

type Pending = { resolve: (v: unknown) => void; reject: (e: Error) => void };
export type AcpRequestHandler = (method: string, params: Record<string, unknown>) => Promise<unknown>;

export class AcpError extends Error {
	constructor(
		message: string,
		readonly code?: number,
	) {
		super(message);
	}
}

/** One agent process and the JSON-RPC conversation with it (newline-delimited, over stdio). */
export class AcpConnection {
	private readonly child: ChildProcessWithoutNullStreams;
	private buf = "";
	private nextId = 0;
	private readonly pending = new Map<number, Pending>();
	private closed = false;
	stderr = "";
	/** Notifications from the agent (`session/update`, `_auth/status_update`…). */
	onNotification?: (method: string, params: Record<string, unknown>) => void;
	/** Requests from the agent (`session/request_permission`…); unanswered ones get "method not found". */
	onRequest?: AcpRequestHandler;
	/** The process ended. */
	onExit?: (message: string) => void;

	constructor(command: string, args: readonly string[], cwd: string, env: NodeJS.ProcessEnv = process.env) {
		this.child = spawn(command, [...args], { cwd, env, stdio: ["pipe", "pipe", "pipe"] });
		this.child.stdout.setEncoding("utf8");
		this.child.stdout.on("data", (d: string) => this.read(d));
		this.child.stderr.on("data", (d: Buffer) => (this.stderr = (this.stderr + d.toString()).slice(-4000)));
		const end = (message: string) => {
			if (this.closed) return;
			this.closed = true;
			for (const p of this.pending.values()) p.reject(new AcpError(message));
			this.pending.clear();
			this.onExit?.(message);
		};
		this.child.on("error", (e) => end(e.message));
		this.child.on("exit", (code) => end(code ? `It stopped (exit ${code}). ${this.stderr.trim().split("\n").at(-1) ?? ""}`.trim() : "It stopped."));
	}

	get alive(): boolean {
		return !this.closed;
	}

	private read(data: string): void {
		this.buf += data;
		let i: number;
		while ((i = this.buf.indexOf("\n")) >= 0) {
			const line = this.buf.slice(0, i).trim();
			this.buf = this.buf.slice(i + 1);
			if (!line) continue;
			let m: { id?: number | string; method?: string; params?: Record<string, unknown>; result?: unknown; error?: { code?: number; message?: string } };
			try {
				m = JSON.parse(line);
			} catch {
				continue;
			}
			if (m.method && m.id !== undefined) void this.answer(m.id, m.method, m.params ?? {});
			else if (m.method) this.onNotification?.(m.method, m.params ?? {});
			else if (typeof m.id === "number" && this.pending.has(m.id)) {
				const p = this.pending.get(m.id)!;
				this.pending.delete(m.id);
				if (m.error) p.reject(new AcpError(m.error.message ?? "The agent refused.", m.error.code));
				else p.resolve(m.result);
			}
		}
	}

	private async answer(id: number | string, method: string, params: Record<string, unknown>): Promise<void> {
		try {
			if (!this.onRequest) throw new AcpError("Method not found", -32601);
			this.write({ jsonrpc: "2.0", id, result: await this.onRequest(method, params) });
		} catch (error) {
			this.write({ jsonrpc: "2.0", id, error: { code: (error as AcpError).code ?? -32603, message: (error as Error).message } });
		}
	}

	private write(message: unknown): void {
		if (!this.closed) this.child.stdin.write(`${JSON.stringify(message)}\n`);
	}

	request<T = Record<string, unknown>>(method: string, params: unknown, timeoutMs = 0): Promise<T> {
		if (this.closed) return Promise.reject(new AcpError("The agent isn't running."));
		const id = ++this.nextId;
		return new Promise<T>((resolve, reject) => {
			const timer = timeoutMs ? setTimeout(() => {
				this.pending.delete(id);
				reject(new AcpError(`No answer to ${method}.`));
			}, timeoutMs) : undefined;
			this.pending.set(id, {
				resolve: (v) => {
					if (timer) clearTimeout(timer);
					resolve(v as T);
				},
				reject: (e) => {
					if (timer) clearTimeout(timer);
					reject(e);
				},
			});
			this.write({ jsonrpc: "2.0", id, method, params });
		});
	}

	notify(method: string, params: unknown): void {
		this.write({ jsonrpc: "2.0", method, params });
	}

	close(): void {
		if (this.closed) return;
		this.child.stdin.end();
		this.child.kill();
	}
}

/** What the client says it can do: nothing but the conversation (agents use their own files and terminal). */
export const CLIENT_CAPABILITIES = { fs: { readTextFile: false, writeTextFile: false }, terminal: false };

export type ConfigOption = { id: string; category?: string; currentValue?: string; options?: { value: string; name: string; description?: string }[] };

// ── The agents ──────────────────────────────────────────────────────────────

export type AcpAgentSpec = {
	/** The provider id of its models: `{ provider: "codex-cli", id: "gpt-6.2-sol" }`. */
	id: string;
	name: string;
	/** The command on PATH, and its arguments. */
	command: string;
	args: string[];
	/** Piopio's approval modes as the agent's own mode values (the setting whose category is "mode"). */
	modes: Record<ApprovalMode, string>;
	/** The setting that is its thinking level. */
	thinking: string;
	/** Its plan when it doesn't say. */
	plan: string;
	install: string;
	signIn: string;
	/** Sessions to remove after looking at what it offers (it keeps a history of them). */
	deleteProbe?: boolean;
};

export const ACP_AGENTS: readonly AcpAgentSpec[] = [
	{
		id: "antigravity-cli",
		name: "Antigravity CLI",
		command: "agy",
		args: ["acp"],
		modes: { read_only: "plan", ask: "default", auto_edit: "accept-edits", full_auto: "auto" },
		thinking: "thought_level",
		plan: "Google AI plan",
		install: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
		signIn: "agy",
	},
	{
		id: "codex-cli",
		name: "Codex",
		command: "codex-acp",
		args: [],
		// Codex's Read-only asks before any edit: Piopio's Read only refuses them, and Ask before edits asks.
		modes: { read_only: "read-only", ask: "read-only", auto_edit: "workspace-write", full_auto: "agent-full-access" },
		thinking: "reasoning_effort",
		plan: "ChatGPT plan",
		install: "npm install -g @openai/codex @agentclientprotocol/codex-acp",
		signIn: "codex login",
		deleteProbe: true,
	},
];

export const acpSpec = (provider: string | undefined): AcpAgentSpec | undefined => ACP_AGENTS.find((a) => a.id === provider);

/** Where a command is: PATH, then the usual install folders (an app-launched engine has a short PATH). */
export function findCommand(name: string, env: NodeJS.ProcessEnv = process.env, home = homedir()): string | undefined {
	const dirs = [...(env.PATH ?? "").split(delimiter), join(home, ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", join(home, ".npm-global/bin"), join(home, ".bun/bin"), join(home, ".volta/bin")];
	for (const dir of dirs) if (dir && existsSync(join(dir, name))) return join(dir, name);
	return undefined;
}

/** The pretend ACP agent (PIOPIO_FAKE_ACP=1, tests and captures), run with this Node. */
export function fakeAgentCommand(spec: AcpAgentSpec): { command: string; args: string[] } {
	const here = dirname(fileURLToPath(import.meta.url));
	const script = [join(here, "runtimes", "acp-fake-agent.js"), join(here, "runtimes", "acp-fake-agent.ts")].find(existsSync)!;
	return { command: process.execPath, args: [script, spec.id] };
}

export type AcpStatus = {
	path?: string;
	version?: string;
	signedIn: boolean;
	plan?: string;
	problem?: string;
	/** Its models (the "model" setting's choices) and their descriptions. */
	models: { value: string; name: string; description?: string }[];
	/** Its thinking levels. */
	levels: string[];
};

/** One ACP agent on this Mac: found, signed in, what it offers (looked at once in a while, in a throwaway session). */
export class AcpAgent {
	private cached?: { at: number; status: AcpStatus };
	private probing?: Promise<AcpStatus>;

	constructor(
		readonly spec: AcpAgentSpec,
		private readonly options: { fake?: boolean; find?: (name: string) => string | undefined } = {},
	) {}

	/** How to start it: its command, or the pretend one. */
	command(): { command: string; args: string[] } | undefined {
		if (this.options.fake) return fakeAgentCommand(this.spec);
		const path = (this.options.find ?? findCommand)(this.spec.command);
		return path ? { command: path, args: this.spec.args } : undefined;
	}

	async status(refresh = false): Promise<AcpStatus> {
		if (!refresh && this.cached && Date.now() - this.cached.at < 10 * 60_000) return this.cached.status;
		this.probing ??= this.probe()
			.then((status) => {
				this.cached = { at: Date.now(), status };
				return status;
			})
			.finally(() => (this.probing = undefined));
		return this.probing;
	}

	private async probe(): Promise<AcpStatus> {
		const cmd = this.command();
		if (!cmd) return { signedIn: false, models: [], levels: [] };
		const dir = mkdtempSync(join(tmpdir(), "piopio-acp-"));
		const conn = new AcpConnection(cmd.command, cmd.args, dir);
		let plan: string | undefined;
		conn.onNotification = (method, params) => {
			const label = (params.authStatus as { label?: string } | undefined)?.label;
			if (method === "_auth/status_update" && label) plan = `${label} plan`;
		};
		const out: AcpStatus = { path: cmd.command === process.execPath ? `/usr/local/bin/${this.spec.command}` : cmd.command, signedIn: false, models: [], levels: [] };
		try {
			const init = await conn.request<{ agentInfo?: { version?: string }; agentCapabilities?: { sessionCapabilities?: Record<string, unknown> } }>("initialize", { protocolVersion: 1, clientCapabilities: CLIENT_CAPABILITIES }, 20_000);
			if (init.agentInfo?.version) out.version = init.agentInfo.version;
			const session = await conn.request<{ sessionId: string; configOptions?: ConfigOption[]; _meta?: { antigravity?: { tier?: { name?: string } } } }>("session/new", { cwd: dir, mcpServers: [] }, 30_000);
			out.signedIn = true;
			const tier = session._meta?.antigravity?.tier?.name;
			out.plan = tier ? `${tier} plan` : (plan ?? this.spec.plan);
			const options = session.configOptions ?? [];
			out.models = options.find((o) => o.category === "model" || o.id === "model")?.options ?? [];
			out.levels = (options.find((o) => o.id === this.spec.thinking)?.options ?? []).map((o) => o.value);
			const caps = init.agentCapabilities?.sessionCapabilities ?? {};
			if (this.spec.deleteProbe && "delete" in caps) await conn.request("session/delete", { sessionId: session.sessionId }, 10_000).catch(() => undefined);
			else if ("close" in caps) await conn.request("session/close", { sessionId: session.sessionId }, 10_000).catch(() => undefined);
		} catch (error) {
			const message = (error as Error).message;
			out.problem = /auth/i.test(message) ? `${this.spec.name} is signed out. Run \`${this.spec.signIn}\` in Terminal to sign in.` : `${this.spec.name} didn't start: ${message}`;
		} finally {
			conn.close();
			rmSync(dir, { recursive: true, force: true });
		}
		return out;
	}

	/** Its models as the picker lists them (docs/spec/31 §5). */
	async modelInfos(): Promise<ModelInfo[]> {
		const s = await this.status();
		if (!s.signedIn) return [];
		return s.models.map((m) => ({
			provider: this.spec.id,
			id: m.value,
			name: m.name,
			contextWindow: 0,
			maxOutputTokens: 0,
			pricing: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			supports: { vision: true, reasoning: s.levels.length > 0 },
			providerName: this.spec.name,
			...(s.plan ? { billing: s.plan } : {}),
			agent: true,
		}));
	}

	/** Its row in Settings › Models › Agents on this Mac. */
	async providerInfo(): Promise<ProviderInfo> {
		const s = await this.status();
		return {
			id: this.spec.id,
			name: this.spec.name,
			methods: [],
			status: !s.path ? "not_connected" : s.signedIn ? "connected" : "needs_attention",
			...(s.signedIn && s.plan ? { billing: s.plan } : {}),
			...(s.path && !s.signedIn && s.problem ? { message: s.problem } : {}),
			featured: false,
			models: s.models.length,
			kind: "agent",
			families: this.spec.id === "codex-cli" ? ["gpt"] : ["gemini", "claude"],
			sampleModels: s.models.slice(0, 3).map((m) => m.name),
			agent: { ...(s.path ? { path: s.path } : {}), ...(s.version ? { version: s.version } : {}), signedIn: s.signedIn, install: this.spec.install, signIn: this.spec.signIn },
		};
	}
}
