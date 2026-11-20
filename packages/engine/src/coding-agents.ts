/**
 * Coding agents that run a whole conversation (docs/spec/31): the user's own Claude Code, signed in with their own plan,
 * driven through the Claude Agent SDK. This file finds it and describes it (version, sign-in, plan, models) for
 * Settings › Models and the model picker, and asks it one-off questions (titles, follow-ups: CA5). The conversation
 * itself runs in `runtimes/claude-code.ts`.
 */
import { spawn } from "node:child_process";
import type { ModelInfo, ModelRef, ProviderInfo } from "@piopio/protocol";
import { findAgent } from "./external-agents.js";
import { fakeClaudeQuery } from "./runtimes/claude-code-fake.js";
import { acpSpec } from "./acp.js";

/** The provider id of Claude Code's models: `{ provider: "claude-code", id: "opus" }`. */
export const CLAUDE_CODE = "claude-code";
export const CLAUDE_CODE_NAME = "Claude Code";

/** Claude Code, Antigravity CLI or Codex: an agent that runs a whole conversation (docs/spec/31). */
export const isCodingAgent = (provider: string | undefined): boolean => provider === CLAUDE_CODE || Boolean(acpSpec(provider));

/** A coding agent's name ("Claude Code", "Codex"). */
export const agentName = (provider: string): string => (provider === CLAUDE_CODE ? CLAUDE_CODE_NAME : (acpSpec(provider)?.name ?? provider));

/** The part of the Agent SDK's `Query` Piopio uses (an async stream of SDK messages plus a few controls). */
export interface AgentQuery extends AsyncIterable<AgentMessage> {
	interrupt(): Promise<unknown>;
	setModel(model?: string): Promise<void>;
	setPermissionMode(mode: AgentPermissionMode): Promise<void>;
	supportedModels(): Promise<AgentModel[]>;
	close(): void;
}
export type AgentPermissionMode = "default" | "acceptEdits" | "bypassPermissions" | "plan";
/** SDK messages, loosely: the runtime reads the fields it needs and ignores the rest. */
export type AgentMessage = { type: string; subtype?: string; [key: string]: unknown };
export type AgentModel = { value: string; displayName: string; description?: string; resolvedModel?: string };
/** What `canUseTool` gets and returns (the SDK's `CanUseTool`, narrowed). */
export type CanUseTool = (
	tool: string,
	input: Record<string, unknown>,
	options: { signal: AbortSignal; suggestions?: unknown[]; decisionReason?: string; blockedPath?: string; toolUseID?: string },
) => Promise<{ behavior: "allow"; updatedInput?: Record<string, unknown>; updatedPermissions?: unknown[] } | { behavior: "deny"; message: string; interrupt?: boolean }>;
export type AgentUserMessage = { type: "user"; message: { role: "user"; content: unknown }; parent_tool_use_id: null; session_id?: string };
export type QueryFn = (params: { prompt: string | AsyncIterable<AgentUserMessage>; options: Record<string, unknown> }) => AgentQuery;

/** The SDK's `query`, loaded on first use (it's only needed once someone uses Claude Code). */
export async function sdkQuery(): Promise<QueryFn> {
	const sdk = await import("@anthropic-ai/claude-agent-sdk");
	return sdk.query as unknown as QueryFn;
}

export type ClaudeCodeStatus = {
	path?: string;
	version?: string;
	signedIn: boolean;
	/** "pro", "max", "team"… from `claude auth status`. */
	plan?: string;
	/** "claude.ai" (a plan) or an API key. */
	method?: string;
	problem?: string;
};

/** Run a command and collect stdout (with a timeout; the app's engine has a short PATH, so commands get full paths). */
function run(path: string, args: string[], timeoutMs = 8000): Promise<{ stdout: string; code: number | null }> {
	return new Promise((resolve) => {
		const child = spawn(path, args, { stdio: ["ignore", "pipe", "ignore"] });
		let stdout = "";
		const timer = setTimeout(() => child.kill(), timeoutMs);
		child.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
		child.on("error", () => {
			clearTimeout(timer);
			resolve({ stdout, code: null });
		});
		child.on("close", (code) => {
			clearTimeout(timer);
			resolve({ stdout, code });
		});
	});
}

/** "pro" → "Claude Pro plan"; an API key → "Anthropic API". */
export function claudeBilling(status: Pick<ClaudeCodeStatus, "plan" | "method">): string {
	if (status.method && status.method !== "claude.ai") return "Anthropic API via Claude Code";
	const plan = status.plan?.trim();
	if (!plan) return "Claude plan";
	return `Claude ${plan.charAt(0).toUpperCase()}${plan.slice(1)} plan`;
}

const FALLBACK_MODELS: AgentModel[] = [
	{ value: "opus", displayName: "Opus" },
	{ value: "sonnet", displayName: "Sonnet" },
	{ value: "haiku", displayName: "Haiku" },
];

export type ClaudeCodeOptions = {
	/** Where `claude` is; by default the usual install folders (external-agents.ts). */
	find?: () => string | undefined;
	/** `claude auth status` and `claude --version`, replaceable in tests. */
	run?: typeof run;
	/** The Agent SDK's `query`, replaceable in tests. */
	query?: () => Promise<QueryFn>;
	/** A pretend Claude Code (PIOPIO_FAKE_CLAUDE_CODE=1): signed in, answers by echoing; for captures and tests. */
	fake?: boolean;
};

export class ClaudeCodeAgent {
	private cached?: { at: number; status: ClaudeCodeStatus };
	private modelList?: AgentModel[];
	private loadingModels?: Promise<AgentModel[]>;

	constructor(private readonly options: ClaudeCodeOptions = {}) {}

	get fake(): boolean {
		return this.options.fake ?? false;
	}

	/** The SDK's `query` (or the fake one). */
	async queryFn(): Promise<QueryFn> {
		if (this.options.fake) return fakeClaudeQuery;
		return (this.options.query ?? sdkQuery)();
	}

	/** Found, signed in and which plan (cached for 30 s; `refresh` asks again). */
	async status(refresh = false): Promise<ClaudeCodeStatus> {
		if (!refresh && this.cached && Date.now() - this.cached.at < 30_000) return this.cached.status;
		const status = await this.probe();
		this.cached = { at: Date.now(), status };
		return status;
	}

	private async probe(): Promise<ClaudeCodeStatus> {
		if (this.options.fake) return { path: "/usr/local/bin/claude", version: "2.1.0 (Claude Code)", signedIn: true, plan: "pro", method: "claude.ai" };
		const path = (this.options.find ?? (() => findAgent("claude")))();
		if (!path) return { signedIn: false };
		const exec = this.options.run ?? run;
		const [version, auth] = await Promise.all([exec(path, ["--version"]), exec(path, ["auth", "status"])]);
		const out: ClaudeCodeStatus = { path, signedIn: false };
		const v = version.stdout.trim().split("\n")[0];
		if (v) out.version = v;
		try {
			const s = JSON.parse(auth.stdout) as { loggedIn?: boolean; authMethod?: string; subscriptionType?: string };
			out.signedIn = s.loggedIn === true;
			if (s.subscriptionType) out.plan = s.subscriptionType;
			if (s.authMethod) out.method = s.authMethod;
		} catch {
			out.problem = auth.code === null ? "Claude Code didn't answer." : "Couldn't read Claude Code's sign-in.";
		}
		if (!out.signedIn && !out.problem) out.problem = "Claude Code is signed out. Run `claude` in Terminal to sign in.";
		return out;
	}

	/** Ready to run a conversation. */
	async available(): Promise<boolean> {
		const s = await this.status();
		return Boolean(s.path) && s.signedIn;
	}

	/** The models Claude Code offers this account (its own list, without "Default"), cached once read. */
	async models(): Promise<AgentModel[]> {
		if (this.modelList) return this.modelList;
		this.loadingModels ??= this.readModels()
			.then((list) => (this.modelList = list.length ? list : FALLBACK_MODELS))
			.catch(() => FALLBACK_MODELS)
			.finally(() => (this.loadingModels = undefined));
		return this.loadingModels;
	}

	private async readModels(): Promise<AgentModel[]> {
		const status = await this.status();
		if (!status.path || !status.signedIn) return FALLBACK_MODELS;
		const query = await this.queryFn();
		const idle: AsyncIterable<AgentUserMessage> = { [Symbol.asyncIterator]: () => ({ next: () => new Promise(() => {}) }) };
		const q = query({ prompt: idle, options: { pathToClaudeCodeExecutable: status.path, settingSources: [], persistSession: false } });
		try {
			const list = await Promise.race([q.supportedModels(), new Promise<AgentModel[]>((_, reject) => setTimeout(() => reject(new Error("timeout")), 20_000))]);
			return list.filter((m) => m.value !== "default");
		} finally {
			q.close();
		}
	}

	/** Its models as the picker lists them, under its own section (docs/spec/31 §5). */
	async modelInfos(): Promise<ModelInfo[]> {
		const status = await this.status();
		if (!status.path || !status.signedIn) return [];
		const billing = claudeBilling(status);
		return (await this.models()).map((m) => ({
			provider: CLAUDE_CODE,
			id: m.value,
			name: m.displayName,
			// Claude Code manages the context itself; Piopio doesn't know the window.
			contextWindow: 0,
			maxOutputTokens: 0,
			pricing: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			supports: { vision: true, reasoning: true },
			providerName: CLAUDE_CODE_NAME,
			billing,
			agent: true,
		}));
	}

	/** Its row in Settings › Models › Agents on this Mac. */
	async providerInfo(): Promise<ProviderInfo> {
		const status = await this.status();
		const models = status.signedIn ? await this.models() : [];
		return {
			id: CLAUDE_CODE,
			name: CLAUDE_CODE_NAME,
			methods: [],
			status: !status.path ? "not_connected" : status.signedIn ? "connected" : "needs_attention",
			...(status.signedIn ? { billing: claudeBilling(status) } : {}),
			...(status.path && !status.signedIn && status.problem ? { message: status.problem } : {}),
			featured: false,
			models: models.length,
			kind: "agent",
			families: ["claude"],
			sampleModels: models.slice(0, 3).map((m) => m.displayName),
			agent: {
				...(status.path ? { path: status.path } : {}),
				...(status.version ? { version: status.version } : {}),
				signedIn: status.signedIn,
				install: "npm install -g @anthropic-ai/claude-code",
				signIn: "claude",
			},
		};
	}

	/**
	 * A one-off answer with no tools (titles, follow-ups, commit messages for a conversation on Claude Code: CA5), on
	 * its smallest model. Undefined when it can't answer.
	 */
	async complete(systemPrompt: string, prompt: string, model: ModelRef = { provider: CLAUDE_CODE, id: "haiku" }): Promise<string | undefined> {
		if (this.options.fake) return undefined;
		const status = await this.status();
		if (!status.path || !status.signedIn) return undefined;
		const query = await this.queryFn();
		const q = query({
			prompt,
			options: { pathToClaudeCodeExecutable: status.path, model: model.id, systemPrompt, tools: [], maxTurns: 1, settingSources: [], persistSession: false },
		});
		let text: string | undefined;
		try {
			for await (const m of q) {
				if (m.type === "result") {
					if (m.subtype === "success" && typeof m.result === "string") text = m.result.trim();
					break;
				}
			}
		} finally {
			q.close();
		}
		return text;
	}
}
