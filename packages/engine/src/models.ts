/**
 * Model access shared by every runtime (docs/spec/10-model-providers §10): one pi ModelRuntime, used by
 * pi-durable (chats, notebooks, agents) and pi-coding-agent (Build) alike, with its credentials in the app's
 * Keychain (`KeychainCredentialStore`). Providers are whatever pi supports; the OpenAI API alias lets an
 * OpenAI key sit next to ChatGPT sign-in.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall, type Model, type Api } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { ModelInfo, ModelRef, ProviderInfo } from "@piopio/protocol";
import { credentialSecret, KeychainCredentialStore } from "./credentials.js";
import { checkEndpoint, type Endpoint, endpointBilling, endpointConfig, Endpoints, isLocal } from "./endpoints.js";
import { billingLabel, connectMethods, FEATURED, openaiApiAlias, PREFERRED_MODEL, UTILITY_MODEL } from "./providers.js";
import type { SecretBroker } from "./secrets.js";

export const DEFAULT_MODEL: ModelRef = { provider: "openrouter", id: "anthropic/claude-haiku-5.5" };

type FauxHandle = ReturnType<typeof fauxProvider>;

export class ModelHub {
	readonly credentials: KeychainCredentialStore;
	readonly endpoints: Endpoints;
	readonly faux?: FauxHandle;
	private runtime?: ModelRuntime;
	private starting?: Promise<ModelRuntime>;
	/** Providers whose last request or refresh failed on auth, with what to tell the user. */
	private readonly problems = new Map<string, string>();
	/** Providers known to have a credential (refreshed by `connected()`), for the synchronous default model. */
	private connectedIds = new Set<string>();

	constructor(
		private readonly secrets: SecretBroker,
		private readonly options: { faux?: boolean; home?: string } = {},
	) {
		this.credentials = new KeychainCredentialStore(secrets, options.home ? join(options.home, "credentials.json") : undefined);
		this.endpoints = new Endpoints(options.home ? join(options.home, "endpoints.json") : undefined);
		if (options.faux) {
			this.faux = fauxProvider({ provider: "faux", tokensPerSecond: 40 });
			installEcho(this.faux);
		}
	}

	/** Creates the runtime once; every other method waits for it. */
	ready(): Promise<ModelRuntime> {
		this.starting ??= ModelRuntime.create({ credentials: this.credentials, modelsPath: null, refreshOnCreate: false }).then((rt) => {
			const openai = rt.getProvider("openai");
			if (openai?.auth.apiKey) rt.registerNativeProvider(openaiApiAlias(openai));
			if (this.faux) rt.registerNativeProvider(this.faux.provider);
			for (const e of this.endpoints.list()) rt.registerProvider(e.id, endpointConfig(e) as never);
			this.runtime = rt;
			return rt;
		});
		return this.starting;
	}

	/** The shared runtime (pi-ai `Models`). The engine awaits `ready()` before serving, so it's always there. */
	get models(): ModelRuntime {
		if (!this.runtime) throw new EngineError("ENGINE_UNAVAILABLE", "Models aren't loaded yet.");
		return this.runtime;
	}

	/** The model new sessions start with: OpenRouter's default when it's connected, else a connected provider's. */
	get defaultModel(): ModelRef {
		if (this.faux) return { provider: "faux", id: this.faux.getModel().id };
		if (this.connectedIds.size === 0 || this.connectedIds.has("openrouter")) return DEFAULT_MODEL;
		const provider = FEATURED.find((id) => this.connectedIds.has(id)) ?? [...this.connectedIds][0]!;
		return { provider, id: PREFERRED_MODEL[provider] ?? this.runtime?.getModels(provider)[0]?.id ?? DEFAULT_MODEL.id };
	}

	/** Makes sure the provider has a credential, asking the app's Keychain the first time. */
	async ensureCredential(provider: string): Promise<void> {
		if (provider === "faux" || this.endpoints.get(provider)?.keyless) return;
		if (await this.credentials.read(provider)) return;
		const name = this.runtime?.getProvider(provider)?.name ?? provider;
		throw new EngineError("AUTH", `${name} isn't connected. Connect it in Settings › Models.`);
	}

	/** Providers with a stored credential (not ambient ones: billing stays explicit). */
	async connected(): Promise<Set<string>> {
		const ids = new Set((await this.credentials.list()).map((c) => c.providerId));
		for (const e of this.endpoints.list()) ids.add(e.id);
		this.connectedIds = ids;
		return ids;
	}

	/** Chat models of the connected providers, each with its provider and who bills for it (FR2). */
	async listModels(refresh = false): Promise<ModelInfo[]> {
		const rt = await this.ready();
		const ids = await this.connected();
		if (refresh && ids.has("openrouter")) await rt.refresh({ providers: ["openrouter"] }).catch(() => undefined);
		const out: ModelInfo[] = [];
		if (this.faux) out.push(...rt.getModels("faux").map((m) => toInfo(m, "Faux", undefined)));
		for (const id of ids) {
			const provider = rt.getProvider(id);
			const endpoint = this.endpoints.get(id);
			if (endpoint && provider) {
				// Context sizes the server didn't report stay unknown (0) in the app.
				const known = new Map(endpoint.models.map((m) => [m.id, m.contextWindow ?? 0]));
				out.push(...rt.getModels(id).map((m) => ({ ...toInfo(m, endpoint.name, endpointBilling(endpoint)), contextWindow: known.get(m.id) ?? 0 })));
				continue;
			}
			const credential = await this.credentials.read(id).catch(() => undefined);
			if (!provider || !credential) continue;
			const billing = billingLabel(provider, credential.type);
			const available = await rt.getAvailable(id).catch(() => rt.getModels(id));
			out.push(...available.map((m) => toInfo(m, provider.name, billing)));
		}
		return out;
	}

	/** Every provider pi knows, featured first, with how it's connected (FR1). */
	async listProviders(connecting: (id: string) => boolean): Promise<ProviderInfo[]> {
		const rt = await this.ready();
		const ids = await this.connected();
		const providers = rt.getProviders().filter((p) => p.id !== "faux" && p.id !== "openai-codex" && !this.endpoints.get(p.id) && connectMethods(p).length > 0);
		const rank = (id: string) => (FEATURED.includes(id) ? FEATURED.indexOf(id) : FEATURED.length);
		providers.sort((a, b) => rank(a.id) - rank(b.id) || a.name.localeCompare(b.name));
		const out: ProviderInfo[] = [];
		for (const p of providers) {
			const credential = ids.has(p.id) ? await this.credentials.read(p.id).catch(() => undefined) : undefined;
			const problem = this.problems.get(p.id);
			const status: ProviderInfo["status"] = connecting(p.id) ? "connecting" : credential ? (problem ? "needs_attention" : "connected") : "not_connected";
			out.push({
				id: p.id,
				name: p.id === "openai" ? "ChatGPT" : p.name,
				methods: connectMethods(p),
				status,
				...(credential ? { connectedWith: credential.type, billing: billingLabel(p, credential.type) } : {}),
				...(credential && problem ? { message: problem } : {}),
				featured: FEATURED.includes(p.id),
				models: p.getModels().length,
			});
		}
		for (const e of this.endpoints.list()) {
			const problem = this.problems.get(e.id);
			out.push({
				id: e.id,
				name: e.name,
				methods: [],
				status: problem ? "needs_attention" : "connected",
				...(e.keyless ? {} : { connectedWith: "api_key" as const }),
				billing: endpointBilling(e),
				...(problem ? { message: problem } : {}),
				featured: false,
				models: e.models.length,
				endpoint: { baseUrl: e.baseUrl, local: isLocal(e.baseUrl), keyless: e.keyless },
			});
		}
		return out;
	}

	/** Checks a server; on an update without a key, with the stored one. */
	async checkEndpoint(baseUrl: string, key?: string, id?: string) {
		const stored = !key && id ? await this.credentials.read(id).catch(() => undefined) : undefined;
		return checkEndpoint(baseUrl, key ?? (stored?.type === "api_key" ? stored.key : undefined));
	}

	/** Adds or updates a custom endpoint: checks it, stores its key in the Keychain, registers it with pi. */
	async saveEndpoint(input: { id?: string; name: string; baseUrl: string; key?: string }): Promise<Endpoint> {
		const rt = await this.ready();
		const previous = input.id ? this.endpoints.get(input.id) : undefined;
		if (input.id && !previous) throw new EngineError("NOT_FOUND", `No endpoint ${input.id}`);
		const key = input.key?.trim() || undefined;
		const check = await this.checkEndpoint(input.baseUrl, key, previous?.id);
		if (!check.ok) throw new EngineError("INVALID", check.message);
		const id = previous?.id ?? this.endpoints.newId(input.name);
		if (key) await this.credentials.modify(id, async () => ({ type: "api_key", key }));
		const endpoint: Endpoint = {
			id,
			name: input.name.trim() || new URL(check.baseUrl).host,
			baseUrl: check.baseUrl,
			keyless: !key && (previous?.keyless ?? true),
			models: check.models,
			addedAt: previous?.addedAt ?? new Date().toISOString(),
		};
		this.endpoints.save(endpoint);
		if (rt.getProvider(id)) rt.unregisterProvider(id);
		rt.registerProvider(id, endpointConfig(endpoint) as never);
		this.problems.delete(id);
		await this.connected();
		return endpoint;
	}

	async removeEndpoint(id: string): Promise<void> {
		const rt = await this.ready();
		if (rt.getProvider(id)) rt.unregisterProvider(id);
		if (!this.endpoints.get(id)?.keyless) await this.credentials.delete(id);
		this.endpoints.remove(id);
		this.problems.delete(id);
		await this.connected();
	}

	/** Disconnects one provider: pi forgets it, the Keychain item goes. */
	async logout(provider: string): Promise<void> {
		const rt = await this.ready();
		await rt.logout(provider).catch(() => undefined);
		await this.credentials.delete(provider);
		this.problems.delete(provider);
		await this.connected();
	}

	/** A sign-in finished: the provider is fine again. */
	async signedIn(provider: string): Promise<void> {
		this.problems.delete(provider);
		await this.connected();
	}

	/** A request failed on auth: the provider shows "Needs attention" until it's connected again. */
	needsAttention(provider: string, message: string): void {
		if (this.problems.get(provider) === message) return;
		this.problems.set(provider, message);
		this.onProvidersChanged?.();
	}

	/** Set by the server: tells clients to list providers again. */
	onProvidersChanged?: () => void;

	/**
	 * One-off request to the utility model (commit messages, titles): cheap and fast. OpenRouter's when it's
	 * connected, else a connected provider's small model. `PIOPIO_UTILITY_MODEL` picks another OpenRouter model.
	 * Returns undefined with the scripted model or when nothing is connected.
	 */
	async utility(systemPrompt: string, prompt: string): Promise<string | undefined> {
		if (this.faux) return undefined;
		const rt = await this.ready();
		const ids = await this.connected();
		let ref: ModelRef | undefined;
		if (process.env.PIOPIO_UTILITY_MODEL && ids.has("openrouter")) ref = { provider: "openrouter", id: process.env.PIOPIO_UTILITY_MODEL };
		else {
			const provider = FEATURED.find((id) => ids.has(id)) ?? [...ids][0];
			if (provider) ref = { provider, id: UTILITY_MODEL[provider] ?? PREFERRED_MODEL[provider] ?? rt.getModels(provider)[0]?.id ?? "" };
		}
		if (!ref) return undefined;
		await this.ensureCredential(ref.provider);
		const model = rt.getModel(ref.provider, ref.id);
		if (!model) throw new EngineError("INVALID", `Unknown utility model ${ref.provider}/${ref.id}`);
		const reply = await rt.completeSimple(model, { systemPrompt, messages: [{ role: "user", content: prompt, timestamp: Date.now() }] });
		if (reply.stopReason === "error" || reply.stopReason === "aborted") throw new EngineError("MODEL_ERROR", reply.errorMessage ?? "The utility model failed.");
		return reply.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("").trim();
	}

	/** Drops cached credentials after the app changed a secret itself (the OpenRouter key field). */
	async forgetSecret(name: string): Promise<void> {
		this.secrets.forget(name);
		const provider = /^provider\.(.+)\.(apiKey|credential)$/.exec(name)?.[1];
		this.credentials.forget(provider);
		if (provider && name === credentialSecret(provider)) this.secrets.forget(name);
	}

	/** The runtime, for pi-coding-agent sessions (the same one pi-durable uses). */
	buildRuntime(): Promise<ModelRuntime> {
		return this.ready();
	}

	/** A stable id for this install, sent by some sign-in flows (OpenAI's agent host id). */
	deviceId(): string {
		const path = this.options.home ? join(this.options.home, "device-id") : undefined;
		if (path && existsSync(path)) return readFileSync(path, "utf8").trim();
		const id = randomUUID();
		if (path) writeFileSync(path, id, { mode: 0o600 });
		return id;
	}
}

function toInfo(m: Model<Api>, providerName: string, billing: string | undefined): ModelInfo {
	return {
		provider: m.provider,
		id: m.id,
		name: m.name,
		contextWindow: m.contextWindow,
		maxOutputTokens: m.maxTokens,
		pricing: { input: m.cost.input, output: m.cost.output, cacheRead: m.cost.cacheRead, cacheWrite: m.cost.cacheWrite },
		supports: { vision: m.input.includes("image"), reasoning: m.reasoning },
		providerName,
		...(billing ? { billing } : {}),
	};
}

/**
 * Faux model that answers "Echo: <last user text>" forever (dev and tests). Lines of the message can
 * script tool calls first, one per step, for Build demos:
 *   $ <command>                      bash
 *   read: <path>                     read
 *   write: <path> | <content>        write (\n in content for new lines)
 *   edit: <path> | <old> | <new>     edit
 *   ask: <question> | <option>…      ask_user
 *   todo: <item> (done) | <item> (in_progress) | <item>…   todo
 *   plan: <summary> | <step>…          propose_plan
 *   task: <title> | <prompt>           task (a subagent)
 *   call: <tool> | <JSON arguments>    any tool (MCP tools in tests)
 */
function installEcho(faux: FauxHandle): void {
	const step = (context: { messages: readonly { role: string; content: unknown }[] }) => {
		faux.appendResponses([step]);
		const lastUser = context.messages.map((m) => m.role).lastIndexOf("user");
		const last = context.messages[lastUser];
		const text = typeof last?.content === "string" ? last.content : Array.isArray(last?.content) ? (last.content as { type: string; text?: string }[]).map((b) => b.text ?? "").join("") : "";
		const script = scriptedTools(text);
		const done = context.messages.slice(lastUser + 1).filter((m) => m.role === "toolResult").length;
		const next = script[done];
		if (next) return fauxAssistantMessage([fauxToolCall(next.name, next.args as Parameters<typeof fauxToolCall>[1])], { stopReason: "toolUse" });
		return fauxAssistantMessage([fauxText(`Echo: ${text}`)]);
	};
	faux.setResponses([step]);
}

function scriptedTools(text: string): { name: string; args: Record<string, unknown> }[] {
	const calls: { name: string; args: Record<string, unknown> }[] = [];
	for (const line of text.split("\n").map((l) => l.trim())) {
		const parts = (rest: string) => rest.split("|").map((p) => p.trim().replaceAll("\\n", "\n"));
		if (line.startsWith("$ ")) calls.push({ name: "bash", args: { command: line.slice(2) } });
		else if (line.startsWith("read: ")) calls.push({ name: "read", args: { path: line.slice(6).trim() } });
		else if (line.startsWith("write: ")) {
			const [path, content = ""] = parts(line.slice(7));
			calls.push({ name: "write", args: { path, content } });
		} else if (line.startsWith("call: ")) {
			const at = line.indexOf("|");
			calls.push({ name: line.slice(6, at).trim(), args: JSON.parse(line.slice(at + 1)) as Record<string, unknown> });
		} else if (line.startsWith("todo: ")) {
			const items = parts(line.slice(6)).map((p) => {
				const m = /^(.*?)\s*\((done|in_progress|pending)\)$/.exec(p);
				return m ? { text: m[1]!, status: m[2]! } : { text: p, status: "pending" };
			});
			calls.push({ name: "todo", args: { items } });
		} else if (line.startsWith("plan: ")) {
			const [summary, ...steps] = parts(line.slice(6));
			calls.push({ name: "propose_plan", args: { summary, steps } });
		} else if (line.startsWith("task: ")) {
			const [description, ...prompt] = parts(line.slice(6));
			calls.push({ name: "task", args: { description, prompt: prompt.join(" | ").replaceAll(" ; ", "\n") } });
		} else if (line.startsWith("ask: ")) {
			const [question, ...options] = parts(line.slice(5));
			calls.push({ name: "ask_user", args: { question, ...(options.length ? { options } : {}) } });
		} else if (line.startsWith("edit: ")) {
			const [path, oldText = "", newText = ""] = parts(line.slice(6));
			calls.push({ name: "edit", args: { path, edits: [{ oldText, newText }] } });
		}
	}
	return calls;
}

export class EngineError extends Error {
	constructor(
		readonly code: "NOT_FOUND" | "BUSY" | "AUTH" | "INVALID" | "CONFLICT" | "MODEL_ERROR" | "INTERNAL" | "ENGINE_UNAVAILABLE",
		message: string,
	) {
		super(message);
	}
}

/** What an OpenRouter key has spent: today, this month and in all (GET /api/v1/key, no cost). */
export async function providerUsage(key: string, fetchImpl: typeof fetch = fetch): Promise<{ todayUsd?: number; monthUsd?: number; totalUsd?: number } | undefined> {
	try {
		const response = await fetchImpl("https://openrouter.ai/api/v1/key", { headers: { authorization: `Bearer ${key.trim()}` }, signal: AbortSignal.timeout(15_000) });
		if (!response.ok) return undefined;
		const data = ((await response.json()) as { data?: { usage?: number; usage_daily?: number; usage_monthly?: number } }).data ?? {};
		return {
			...(typeof data.usage_daily === "number" ? { todayUsd: data.usage_daily } : {}),
			...(typeof data.usage_monthly === "number" ? { monthUsd: data.usage_monthly } : {}),
			...(typeof data.usage === "number" ? { totalUsd: data.usage } : {}),
		};
	} catch {
		return undefined;
	}
}

/** "sk-or-v1-755…a30". */
export function keyHint(key: string): string {
	const k = key.trim();
	return k.length > 16 ? `${k.slice(0, 12)}…${k.slice(-3)}` : "••••";
}

/** Checks an OpenRouter key against GET /api/v1/key (no completion, no cost). */
export async function verifyProviderKey(provider: string, key: string, fetchImpl: typeof fetch = fetch): Promise<{ ok: boolean; message?: string; label?: string; usageUsd?: number; limitUsd?: number | null }> {
	if (provider !== "openrouter") return { ok: false, message: `${provider} keys can't be checked yet.` };
	if (!key.trim()) return { ok: false, message: "Paste a key first." };
	try {
		const response = await fetchImpl("https://openrouter.ai/api/v1/key", { headers: { authorization: `Bearer ${key.trim()}` }, signal: AbortSignal.timeout(15_000) });
		if (response.status === 401 || response.status === 403) return { ok: false, message: "OpenRouter didn't accept this key." };
		if (!response.ok) return { ok: false, message: `OpenRouter answered ${response.status}. Try again in a moment.` };
		const data = ((await response.json()) as { data?: { label?: string; usage?: number; limit?: number | null } }).data ?? {};
		return { ok: true, ...(data.label ? { label: data.label } : {}), ...(typeof data.usage === "number" ? { usageUsd: data.usage } : {}), limitUsd: data.limit ?? null };
	} catch {
		return { ok: false, message: "Can't reach OpenRouter. Check your connection." };
	}
}
