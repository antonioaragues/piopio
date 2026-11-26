/**
 * Model access shared by every runtime (docs/spec/10-model-providers §10): one pi ModelRuntime, used by
 * pi-durable (chats, agents) and pi-coding-agent (Build) alike, with its credentials in the app's
 * Keychain (`KeychainCredentialStore`). Providers are whatever pi supports; the OpenAI API alias lets an
 * OpenAI key sit next to ChatGPT sign-in.
 */
import { existsSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { fauxAssistantMessage, fauxProvider, fauxText, fauxThinking, fauxToolCall, type Model, type Api, type Provider } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { ModelInfo, ModelRef, ProviderInfo } from "@piopio/protocol";
import { credentialSecret, KeychainCredentialStore } from "./credentials.js";
import { checkEndpoint, type Endpoint, endpointBilling, type KnownModel, type EndpointFormat, Endpoints, isEmbedding, isLocal, ModelsFileError, piProvider } from "./endpoints.js";
import { billingLabel, connectMethods, FEATURED, SUBSCRIPTION_PROVIDERS, KEY_PAGES, maskKey, openaiApiAlias, POPULAR, PREFERRED_MODEL, providerFamilies, providerKind, UTILITY_MODEL, verifyKey } from "./providers.js";
import type { SecretBroker } from "./secrets.js";
import { withClaudeFlags } from "./openrouter-flags.js";
import { CLAUDE_CODE, ClaudeCodeAgent } from "./coding-agents.js";
import { ACP_AGENTS, AcpAgent } from "./acp.js";

export const DEFAULT_MODEL: ModelRef = { provider: "openrouter", id: "anthropic/claude-haiku-5.5" };

type FauxHandle = ReturnType<typeof fauxProvider>;

import { UsageLedger } from "./ledger.js";
import { MonthBudget } from "./budget.js";
import { OnDeviceModel, OnDeviceUnavailable } from "./on-device.js";
import type { UtilityChoice } from "@piopio/protocol";
import { readJsonFile, writeFileAtomic } from "./atomic.js";


/** How often a model list asks pi to check its catalog (pi itself skips pi.dev when it asked in the last four hours). */
const CATALOG_CHECK_MS = 3_600_000;

export class ModelHub {
	/** Every paid request, for Overview (docs/spec/34 §8.1), those outside conversations' turns included (`recordCost`). */
	readonly ledger: UsageLedger;
	/** Piopio this month (docs/spec/34 OV3): off until you set it. */
	readonly budget: MonthBudget;
	readonly credentials: KeychainCredentialStore;
	readonly endpoints: Endpoints;
	readonly faux?: FauxHandle;
	private runtime?: ModelRuntime;
	private starting?: Promise<ModelRuntime>;
	/** Providers whose last request or refresh failed on auth, with what to tell the user. */
	private readonly problems = new Map<string, string>();
	/** Providers known to have a credential (refreshed by `connected()`), for the synchronous default model. */
	private connectedIds = new Set<string>();

	readonly onDevice: OnDeviceModel;
	/** The user's Claude Code, which can run a whole conversation (docs/spec/31). Off in tests unless faked. */
	readonly claudeCode: ClaudeCodeAgent;
	/** Antigravity CLI and Codex, over ACP (docs/spec/31 A3). */
	readonly acpAgents: AcpAgent[];
	private agentsOn: boolean;
	/** The real Claude Code is looked for (not in faux runs unless faked). */
	private readonly claudeOn: boolean;
	/** Claude Code was found signed in at the last listing, for the synchronous default model. */
	private claudeCodeReady = false;
	/** The user's choice (Settings › Models); the server connects it to the settings file. Unset: automatic. */
	utilityChoice: () => UtilityChoice | undefined = () => undefined;

	constructor(
		private readonly secrets: SecretBroker,
		private readonly options: {
			faux?: boolean;
			home?: string;
			onDevice?: OnDeviceModel;
			claudeCode?: ClaudeCodeAgent;
			/** pi's folder: its `models.json` (your own providers, base URLs and model overrides) applies here too. */
			piAgentDir?: string;
			/** Follow pi's model catalog on pi.dev (models newer than this pi, for every provider). Off in tests. */
			remoteCatalog?: boolean;
			/** Where that catalog is asked for (tests); default pi.dev. */
			catalogBaseUrl?: string;
		} = {},
	) {
		this.onDevice = options.onDevice ?? new OnDeviceModel();
		// The real Claude Code is looked for except in faux runs (tests, captures), which get the pretend one on request.
		const fake = process.env.PIOPIO_FAKE_CLAUDE_CODE === "1";
		this.agentsOn = Boolean(options.claudeCode) || fake || !options.faux;
		this.claudeOn = this.agentsOn;
		this.claudeCode = options.claudeCode ?? new ClaudeCodeAgent({ fake });
		const fakeAcp = process.env.PIOPIO_FAKE_ACP === "1";
		this.acpAgents = fakeAcp || !options.faux ? ACP_AGENTS.map((spec) => new AcpAgent(spec, { fake: fakeAcp })) : [];
		this.agentsOn ||= fakeAcp;
		this.credentials = new KeychainCredentialStore(secrets, options.home ? join(options.home, "credentials.json") : undefined);
		// Custom endpoints are providers in pi's own models.json (endpoints.ts).
		this.endpoints = new Endpoints(this.modelsPath);
		this.ledger = new UsageLedger(options.home ? join(options.home, "usage.db") : undefined);
		this.ledger.planOf = (provider, usd) => this.billedToPlan(provider, usd);
		this.budget = new MonthBudget(options.home ? join(options.home, "budget.json") : undefined, this.ledger);
		this.ledger.onWrite = () => this.budget.written();
		this.loadVisibility();
		// What OpenRouter's own model list was cached in before pi's catalog was followed (docs/spec/10 §14).
		if (options.home) rmSync(join(options.home, "openrouter-models.json"), { force: true });
		if (options.faux) {
			// PIOPIO_FAUX_MODEL_NAME: captures of a long model name (the composer in a narrow column, docs/spec/37).
			const name = process.env.PIOPIO_FAUX_MODEL_NAME;
			this.faux = fauxProvider({ provider: "faux", tokensPerSecond: 40, ...(name ? { models: [{ id: "faux-1", name }] } : {}) });
			installEcho(this.faux);
		}
	}

	/** Creates the runtime once; every other method waits for it. */
	ready(): Promise<ModelRuntime> {
		const { piAgentDir, home } = this.options;
		this.starting ??= ModelRuntime.create({
			credentials: this.credentials,
			// pi's own models.json, as pi's CLI reads it. Without pi's folder (unit tests): none.
			modelsPath: this.modelsPath ?? null,
			// The refreshed catalogs are kept in Piopio's folder, not beside pi's: OpenRouter's is narrowed to the key in
			// the Keychain, which pi's CLI may not have.
			...(piAgentDir && home ? { modelsStorePath: join(home, "models-store.json") } : {}),
			// Nothing over the network, or from the Keychain, before the engine serves: `followCatalog` does it later.
			refreshOnCreate: false,
			...(this.options.catalogBaseUrl ? { catalogBaseUrl: this.options.catalogBaseUrl } : {}),
		}).then((rt) => {
			const openai = rt.getProvider("openai");
			if (openai?.auth.apiKey) rt.registerNativeProvider(openaiApiAlias(openai));
			// Claude through OpenRouter: the one flag pi's catalog lacks there (openrouter-flags.ts).
			const openrouter = rt.getProvider("openrouter");
			if (openrouter && !this.faux) rt.registerNativeProvider(withClaudeFlags(openrouter, this.anthropicCatalog(rt)));
			if (this.faux) rt.registerNativeProvider(this.faux.provider);
			this.runtime = rt;
			return rt;
		});
		return this.starting;
	}

	/** pi's catalog for Anthropic's own API, all of it (with or without an Anthropic key): what its models accept. */
	private anthropicCatalog(rt: ModelRuntime): readonly Model<Api>[] {
		const anthropic = rt.getProvider("anthropic");
		if (!anthropic) return [];
		return (anthropic.getAllModels?.call(anthropic) ?? anthropic.getModels()) as readonly Model<Api>[];
	}

	/** pi's `models.json`: in pi's folder, so pi's CLI reads the same one; in the engine's home when there's none. */
	private get modelsPath(): string | undefined {
		const dir = this.options.piAgentDir ?? this.options.home;
		return dir ? join(dir, "models.json") : undefined;
	}

	/** pi reads `models.json` again (after Piopio wrote an endpoint there). Nothing goes over the network. */
	private async reloadModelsFile(rt: ModelRuntime): Promise<void> {
		await rt.refresh({ allowNetwork: false }).catch(() => undefined);
	}

	private catalogRestored = false;
	private catalogChecked = 0;
	private catalogRefresh?: Promise<unknown>;

	/** The connected providers pi keeps a catalog for (not your own endpoints, not the scripted model). */
	private catalogProviders(rt: ModelRuntime, connected: Set<string>): string[] {
		return [...connected].filter((id) => !this.endpoints.get(id) && id !== "faux" && rt.getProvider(id));
	}

	/**
	 * Before a model list is read: pi's catalog as it should be seen. A refresh rebuilds a provider and, for a moment,
	 * leaves out the models that came from pi.dev, so one still running is waited for. The first list after a start
	 * restores the catalog kept from last time (no network); asking to refresh reads models.json again and waits for
	 * pi.dev (OpenRouter's is then narrowed to what your key may use).
	 */
	private async catalogReady(rt: ModelRuntime, connected: Set<string>, force: boolean): Promise<void> {
		await this.catalogRefresh;
		const providers = this.catalogProviders(rt, connected);
		if (!providers.length) return;
		if (!this.catalogRestored) {
			this.catalogRestored = true;
			await rt.refresh({ providers, allowNetwork: false }).catch(() => undefined);
		}
		if (!force) return;
		this.catalogChecked = Date.now();
		await rt.refresh({ providers, force: true }).catch(() => undefined);
	}

	/**
	 * After a model list was read: pi checks pi.dev for a newer catalog in the background (it asks at most every four
	 * hours). Started here, not before the list, so the list isn't read while providers are being rebuilt.
	 */
	private catalogLater(rt: ModelRuntime, connected: Set<string>): void {
		if (this.catalogRefresh || Date.now() - this.catalogChecked < CATALOG_CHECK_MS) return;
		const providers = this.catalogProviders(rt, connected);
		if (!providers.length) return;
		this.catalogChecked = Date.now();
		this.catalogRefresh = rt.refresh({ providers }).catch(() => undefined).finally(() => (this.catalogRefresh = undefined));
	}

	/** The shared runtime (pi-ai `Models`). The engine awaits `ready()` before serving, so it's always there. */
	get models(): ModelRuntime {
		if (!this.runtime) throw new EngineError("ENGINE_UNAVAILABLE", "Models aren't loaded yet.");
		return this.runtime;
	}

	/** The model new sessions start with: OpenRouter's default when it's connected, else a connected provider's. */
	get defaultModel(): ModelRef {
		if (this.faux) return { provider: "faux", id: this.faux.getModel().id };
		// Only Claude Code on this Mac: it runs new conversations (docs/spec/31 CA5).
		if (this.connectedIds.size === 0 && this.claudeCodeReady) return { provider: CLAUDE_CODE, id: "opus" };
		if (this.connectedIds.size === 0 || this.connectedIds.has("openrouter")) return DEFAULT_MODEL;
		const provider = FEATURED.find((id) => this.connectedIds.has(id)) ?? [...this.connectedIds][0]!;
		return { provider, id: PREFERRED_MODEL[provider] ?? this.runtime?.getModels(provider)[0]?.id ?? DEFAULT_MODEL.id };
	}

	/**
	 * A provider that runs on this Mac: an endpoint at localhost (Ollama, LM Studio, …). A server elsewhere, even
	 * yours, isn't: what goes to it leaves the Mac.
	 */
	isLocalProvider(provider: string): boolean {
		const endpoint = this.endpoints.get(provider);
		return Boolean(endpoint && isLocal(endpoint.baseUrl));
	}

	/** Makes sure the provider has a credential, asking the app's Keychain the first time. */
	async ensureCredential(provider: string): Promise<void> {
		if (provider === "faux" || this.endpoints.get(provider)?.keyless) return;
		if (await this.credentials.read(provider)) return;
		// With nothing connected, the conversation only has the default model: no provider was chosen, so none is named.
		if ((await this.connected()).size === 0) throw new EngineError("AUTH", "No model provider is connected. Connect one in Settings › Models.");
		const name = this.runtime?.getProvider(provider)?.name ?? provider;
		throw new EngineError("AUTH", `${name} isn't connected. Connect it in Settings › Models, or pick another model.`);
	}

	/**
	 * Requests through this provider are billed to a subscription, not per use (docs/spec/34 OV4): a coding agent on
	 * your plan, or a provider you signed in to with your subscription. `usd` is what the request reported.
	 */
	billedToPlan(provider: string, usd: number): boolean {
		// A coding agent charges a turn only when it's billed by key (Claude Code's runtime decides, CA6).
		if (provider === CLAUDE_CODE || this.acpAgents.some((a) => a.spec.id === provider)) return !(usd > 0);
		return this.credentials.typeOf(provider) === "oauth" && SUBSCRIPTION_PROVIDERS.has(provider);
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
		if (this.options.remoteCatalog) await this.catalogReady(rt, ids, refresh);
		else if (refresh && ids.has("openrouter")) await rt.refresh({ providers: ["openrouter"] }).catch(() => undefined);
		const out: ModelInfo[] = [];
		if (this.faux) out.push(...rt.getModels("faux").map((m) => toInfo(m, "Faux", undefined)));
		for (const id of ids) {
			const provider = rt.getProvider(id);
			const endpoint = this.endpoints.get(id);
			const hidden = new Set(this.hidden[id] ?? []);
			if (endpoint && provider) {
				out.push(...rt.getModels(id).filter((m) => !hidden.has(m.id)).map((m) => toInfo(m, endpoint.name, endpointBilling(endpoint))));
				continue;
			}
			const credential = await this.credentials.read(id).catch(() => undefined);
			if (!provider || !credential) continue;
			const billing = billingLabel(provider, credential.type);
			const available = await rt.getAvailable(id).catch(() => rt.getModels(id));
			out.push(...available.filter((m) => !hidden.has(m.id)).map((m) => toInfo(m, provider.name, billing)));
		}
		out.push(...(await this.agentModels()));
		if (this.options.remoteCatalog) this.catalogLater(rt, ids);
		return out;
	}

	/** Claude Code's models, when it's on this Mac and signed in. */
	private async agentModels(): Promise<ModelInfo[]> {
		if (!this.agentsOn) return [];
		const [claude, ...acp] = await Promise.all([this.claudeOn ? this.claudeCode.modelInfos().catch(() => []) : [], ...this.acpAgents.map((a) => a.modelInfos().catch(() => []))]);
		this.claudeCodeReady = claude.length > 0;
		return [...claude, ...acp.flat()];
	}

	/** Deletes a coding agent's own session (a deleted chat's, docs/spec/31); best effort. */
	async forgetAgentSession(provider: string, sessionId: string, cwd: string): Promise<void> {
		if (provider === CLAUDE_CODE) return this.claudeCode.deleteSession(sessionId, cwd);
		await this.acpAgents.find((a) => a.spec.id === provider)?.deleteSession(sessionId, cwd);
	}

	/** Coding agents on this Mac, found or not (Settings › Models › Agents on this Mac). */
	async listAgents(): Promise<ProviderInfo[]> {
		if (!this.agentsOn) return [];
		const [info, ...acp] = await Promise.all([this.claudeOn ? this.claudeCode.providerInfo().catch(() => undefined) : undefined, ...this.acpAgents.map((a) => a.providerInfo().catch(() => undefined))]);
		this.claudeCodeReady = info?.status === "connected";
		return [info, ...acp].filter((p): p is ProviderInfo => Boolean(p));
	}

	/** Every provider pi knows, featured first, with how it's connected (FR1). */
	async listProviders(connecting: (id: string) => boolean): Promise<ProviderInfo[]> {
		const rt = await this.ready();
		const ids = await this.connected();
		const providers = rt.getProviders().filter((p) => p.id !== "faux" && p.id !== "openai-codex" && !this.endpoints.get(p.id) && connectMethods(p).length > 0);
		const rank = (id: string) => (FEATURED.includes(id) ? FEATURED.indexOf(id) : FEATURED.length);
		providers.sort((a, b) => rank(a.id) - rank(b.id) || a.name.localeCompare(b.name));
		const out: ProviderInfo[] = [...(await this.listAgents())];
		for (const p of providers) {
			const credential = ids.has(p.id) ? await this.credentials.read(p.id).catch(() => undefined) : undefined;
			const problem = this.problems.get(p.id);
			const status: ProviderInfo["status"] = connecting(p.id) ? "connecting" : credential ? (problem ? "needs_attention" : "connected") : "not_connected";
			const models = p.getModels();
			out.push({
				id: p.id,
				name: p.id === "openai" ? "ChatGPT" : p.name,
				methods: connectMethods(p),
				status,
				...(credential ? { connectedWith: credential.type, billing: billingLabel(p, credential.type) } : {}),
				...(credential && problem ? { message: problem } : {}),
				featured: FEATURED.includes(p.id),
				models: models.length,
				kind: providerKind(p.id),
				...(POPULAR[p.id] ? { popular: POPULAR[p.id] } : {}),
				...(KEY_PAGES[p.id] ? { keyPage: KEY_PAGES[p.id] } : {}),
				families: providerFamilies(models),
				...(credential?.type === "api_key" && credential.key ? { keyHint: maskKey(credential.key) } : {}),
				...(this.hidden[p.id]?.length ? { hiddenModels: this.hidden[p.id]!.length } : {}),
				sampleModels: models.slice(0, 3).map((m) => m.name),
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
				endpoint: {
					baseUrl: e.baseUrl,
					local: isLocal(e.baseUrl),
					keyless: e.keyless,
					format: e.format,
					...(e.headers ? { headers: e.headers } : {}),
				},
				kind: "custom",
				...(!e.keyless ? await this.credentials.read(e.id).then((c) => (c?.type === "api_key" && c.key ? { keyHint: maskKey(c.key) } : {})).catch(() => ({})) : {}),
				...(this.hidden[e.id]?.length ? { hiddenModels: this.hidden[e.id]!.length } : {}),
				families: providerFamilies(e.models.map((m) => ({ id: m.id, name: m.id }))),
			});
		}
		return out;
	}

	/**
	 * What pi's catalog knows about a model id, for a custom endpoint serving it under the same name: the id as it is
	 * (`anthropic/claude-sonnet-5`, as OpenRouter and gateways name it) or its last part (`claude-sonnet-5`), without
	 * regard to case. Several providers list the same model: it reads images or thinks only when all of them say so,
	 * and its limits are the smallest. Other endpoints and the scripted model don't count.
	 */
	private knownModels(rt: ModelRuntime): (id: string) => KnownModel | undefined {
		const last = (id: string) => id.toLowerCase().split("/").at(-1)!;
		const byName = new Map<string, KnownModel>();
		for (const p of rt.getProviders()) {
			if (this.endpoints.get(p.id) || p.id === this.faux?.provider.id) continue;
			for (const m of p.getModels()) {
				const one: KnownModel = { vision: m.input.includes("image"), reasoning: Boolean(m.reasoning), contextWindow: m.contextWindow, maxTokens: m.maxTokens };
				for (const key of new Set([m.id.toLowerCase(), last(m.id)])) {
					const seen = byName.get(key);
					byName.set(key, seen ? { vision: seen.vision && one.vision, reasoning: seen.reasoning && one.reasoning, contextWindow: Math.min(seen.contextWindow, one.contextWindow), maxTokens: Math.min(seen.maxTokens, one.maxTokens) } : one);
				}
			}
		}
		return (id) => byName.get(id.toLowerCase()) ?? byName.get(last(id));
	}

	/** Checks a server; on an update without a key, with the stored one. */
	async checkEndpoint(baseUrl: string, key?: string, id?: string, options: { format?: EndpointFormat; headers?: Record<string, string> } = {}) {
		const stored = !key && id ? await this.credentials.read(id).catch(() => undefined) : undefined;
		const previous = id ? this.endpoints.get(id) : undefined;
		return checkEndpoint(baseUrl, key ?? (stored?.type === "api_key" ? stored.key : undefined), fetch, 8_000, { format: options.format ?? previous?.format ?? "openai", ...((options.headers ?? previous?.headers) ? { headers: options.headers ?? previous?.headers } : {}) });
	}

	/**
	 * Adds or updates a custom endpoint: checks it, stores its key in the Keychain, and writes its provider entry in
	 * pi's `models.json`, which pi then reads again. `force` saves it even when the server doesn't answer now.
	 */
	async saveEndpoint(input: { id?: string; name: string; baseUrl: string; key?: string; format?: EndpointFormat; headers?: Record<string, string>; contextWindow?: number; hidden?: string[]; force?: boolean }): Promise<Endpoint> {
		const rt = await this.ready();
		const previous = input.id ? this.endpoints.get(input.id) : undefined;
		if (input.id && !previous) throw new EngineError("NOT_FOUND", `No endpoint ${input.id}`);
		const key = input.key?.trim() || undefined;
		const format = input.format ?? previous?.format ?? "openai";
		const headers = input.headers ?? previous?.headers;
		const check = await this.checkEndpoint(input.baseUrl, key, previous?.id, { format, ...(headers ? { headers } : {}) });
		if (!check.ok && !input.force) throw new EngineError("INVALID", check.message);
		const id = previous?.id ?? this.endpoints.newId(input.name);
		let baseUrl = input.baseUrl.trim().replace(/\/+$/, "");
		if (!/^https?:\/\//.test(baseUrl)) baseUrl = `http://${baseUrl}`;
		const entry = piProvider(
			this.endpoints.raw(id),
			{
				name: input.name.trim() || (check.ok ? new URL(check.baseUrl).host : "Custom endpoint"),
				baseUrl: check.ok ? check.baseUrl : baseUrl,
				// An entry written by hand with another API keeps it unless you pick a format here.
				...(input.format || !previous ? { format } : {}),
				keyless: !key && (previous?.keyless ?? true),
				...(headers ? { headers } : {}),
			},
			check.ok ? check.models : undefined,
			{ ...(input.contextWindow ? { contextWindow: input.contextWindow } : {}), known: this.knownModels(rt) },
		);
		try {
			this.endpoints.write(id, entry);
		} catch (error) {
			if (error instanceof ModelsFileError) throw new EngineError("INVALID", error.message);
			throw error;
		}
		if (key) await this.credentials.modify(id, async () => ({ type: "api_key", key }));
		await this.reloadModelsFile(rt);
		if (input.hidden) this.setHidden(id, input.hidden);
		if (check.ok) this.problems.delete(id);
		else this.problems.set(id, check.message);
		await this.connected();
		return this.endpoints.get(id)!;
	}

	// ── Keys and visibility (Settings › Models) ──

	/** Models you hid from the picker, per provider (`model-visibility.json`). */
	private hidden: Record<string, string[]> = {};
	private get visibilityPath(): string | undefined {
		return this.options.home ? join(this.options.home, "model-visibility.json") : undefined;
	}

	private loadVisibility(): void {
		const path = this.visibilityPath;
		if (path) this.hidden = readJsonFile<Record<string, string[]>>(path, () => this.hidden);
	}

	setHidden(provider: string, hidden: string[]): void {
		if (hidden.length) this.hidden[provider] = [...new Set(hidden)];
		else delete this.hidden[provider];
		const path = this.visibilityPath;
		if (path) writeFileAtomic(path, `${JSON.stringify(this.hidden, null, "\t")}\n`, { mode: 0o600 });
	}

	/** Every model a connected provider offers, with whether it's hidden. */
	async providerModels(provider: string): Promise<{ id: string; name: string; contextWindow: number; hidden: boolean; embedding?: boolean }[]> {
		const rt = await this.ready();
		const hidden = new Set(this.hidden[provider] ?? []);
		return rt.getModels(provider).map((m) => ({ id: m.id, name: m.name, contextWindow: m.contextWindow, hidden: hidden.has(m.id), ...(isEmbedding(m.id) ? { embedding: true } : {}) }));
	}

	/** Checks a key against the provider's model list without saving it. */
	async verifyProviderKey(provider: string, key: string) {
		const rt = await this.ready();
		const p = rt.getProvider(provider);
		if (!p) throw new EngineError("NOT_FOUND", `Unknown provider ${provider}`);
		// No key: test the stored one ("Test connection").
		if (!key.trim()) {
			const stored = await this.credentials.read(provider).catch(() => undefined);
			if (stored?.type !== "api_key" || !stored.key) return { ok: null, message: "Signed in; it's checked on use." };
			const result = await verifyKey(p, stored.key);
			if (result.ok === false) this.needsAttention(provider, result.message ?? "The key was rejected.");
			else if (result.ok) this.problems.delete(provider);
			return result;
		}
		return verifyKey(p, key);
	}

	/** Connects a provider with an API key (replacing any credential it had). */
	async saveKey(provider: string, key: string): Promise<void> {
		const rt = await this.ready();
		if (!rt.getProvider(provider)) throw new EngineError("NOT_FOUND", `Unknown provider ${provider}`);
		const k = key.trim();
		if (!k) throw new EngineError("INVALID", "Paste a key first.");
		await this.credentials.modify(provider, async () => ({ type: "api_key", key: k }));
		this.problems.delete(provider);
		await this.connected();
	}

	async removeEndpoint(id: string): Promise<void> {
		const rt = await this.ready();
		const keyless = this.endpoints.get(id)?.keyless;
		try {
			this.endpoints.write(id, undefined);
		} catch (error) {
			if (error instanceof ModelsFileError) throw new EngineError("INVALID", error.message);
			throw error;
		}
		if (!keyless) await this.credentials.delete(id);
		await this.reloadModelsFile(rt);
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
	 * One-off request for background work (07-shared §1.3): titles, summaries, suggested replies,
	 * commit messages and learned facts. Automatic by default: the provider the conversation already uses
	 * (`model`), its small model when it has one (Haiku on OpenRouter), else that same model, so a chat on a local
	 * model stays local and one on OpenRouter uses OpenRouter. Without a conversation (commit messages), the default
	 * model's provider; with no provider connected, Apple's on-device model when it's there. The user can pin another
	 * choice in Settings › Models (`choice` overrides it: an agent's own `models.utility`).
	 */
	async utility(systemPrompt: string, prompt: string, scope?: string, request: { model?: ModelRef; choice?: UtilityChoice } = {}): Promise<string | undefined> {
		if (this.faux) return undefined;
		const choice = request.choice ?? this.utilityChoice() ?? "auto";
		if (choice === "off") return undefined;
		if (choice === "on_device") return this.onDeviceUtility(systemPrompt, prompt, scope);
		// A conversation on Claude Code asks Claude Code (docs/spec/31 CA5): no other provider needed.
		if (choice === "auto" && request.model?.provider === CLAUDE_CODE) {
			const text = await this.claudeCode.complete(systemPrompt, prompt).catch(() => undefined);
			return text ?? this.onDeviceUtility(systemPrompt, prompt, scope);
		}
		const ref = choice === "auto" ? await this.automaticUtility(request.model) : choice;
		if (!ref) return this.onDeviceUtility(systemPrompt, prompt, scope);
		// A picked model whose provider was disconnected: skipped (titles and the like are optional work).
		if (choice !== "auto" && !(await this.connected()).has(ref.provider)) return undefined;
		const rt = await this.ready();
		await this.ensureCredential(ref.provider);
		const model = rt.getModel(ref.provider, ref.id);
		if (!model) throw new EngineError("INVALID", `Unknown utility model ${ref.provider}/${ref.id}`);
		const reply = await rt.completeSimple(model, { systemPrompt, messages: [{ role: "user", content: prompt, timestamp: Date.now() }] });
		const estimated = reply.usage?.cost?.total;
		const hasPricing = Object.values(model.cost).some(value => typeof value === "number" && value > 0);
		this.ledger.recordCost("utility", `${ref.provider}/${ref.id}`, estimated === 0 && !hasPricing ? undefined : estimated, scope);
		if (reply.stopReason === "error" || reply.stopReason === "aborted") throw new EngineError("MODEL_ERROR", reply.errorMessage ?? "The utility model failed.");
		return reply.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("").trim();
	}

	/** Automatic: the conversation's provider (its small model, else the same model), else the default's; undefined with none connected. */
	async automaticUtility(conversation?: ModelRef): Promise<ModelRef | undefined> {
		const rt = await this.ready();
		const ids = await this.connected();
		const base = conversation && ids.has(conversation.provider) ? conversation : ids.size ? this.defaultModel : undefined;
		if (!base) return undefined;
		const small = UTILITY_MODEL[base.provider];
		return small && rt.getModel(base.provider, small) ? { provider: base.provider, id: small } : base;
	}

	private async onDeviceUtility(systemPrompt: string, prompt: string, scope?: string): Promise<string | undefined> {
		try {
			const text = await this.onDevice.complete(systemPrompt, prompt);
			this.ledger.recordCost("utility", "apple/on-device", 0, scope);
			return text;
		} catch (error) {
			if (error instanceof OnDeviceUnavailable) return undefined;
			throw new EngineError("MODEL_ERROR", (error as Error).message);
		}
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
 *   todo: <item> (done) | <item> (in_progress) | <item>…   todo (an item may be "<title> :: <detail>")
 *   plan: <summary> | <step>…          propose_plan
 *   task: <title> | <prompt>           task (a subagent)
 *   call: <tool> | <JSON arguments>    any tool (MCP tools in tests)
 *   think: <text>                      thinking before the first step
 */
function installEcho(faux: FauxHandle): void {
	const step = (context: { messages: readonly { role: string; content: unknown }[] }) => {
		faux.appendResponses([step]);
		const textOf = (m: { content: unknown } | undefined) => (typeof m?.content === "string" ? m.content : Array.isArray(m?.content) ? (m.content as { type: string; text?: string }[]).map((b) => b.text ?? "").join("") : "");
		// The person's last message, not a note Piopio put beside it (an @mention's, recalled memory: docs/spec/38 R3).
		const own = (m: { role: string; content: unknown }) => m.role === "user" && !/^(\[Piopio\] |<memory>)/.test(textOf(m));
		const lastUser = context.messages.findLastIndex(own);
		const last = context.messages[lastUser];
		const raw = textOf(last);
		// What the user typed, without the clock line the context guards add (@piopio/runtime context/clock).
		const text = raw.replace(/^\[Sent [^\]\n]*\](\n\n)?/, "").replace(/^(<attachment [^>\n]*\/>\n)+/, "");
		const script = scriptedTools(text);
		const done = context.messages.slice(lastUser + 1).filter((m) => m.role === "toolResult").length;
		// A call on a line that starts with "& " goes in the same message as the one before (parallel tool calls).
		const groups: (typeof script)[] = [];
		for (const c of script) {
			if (c.together && groups.length) groups.at(-1)!.push(c);
			else groups.push([c]);
		}
		let used = 0;
		const group = groups.find((g) => (used += g.length) > done) ?? [];
		const thinking = done === 0 ? text.split("\n").map((l) => l.trim()).filter((l) => l.startsWith("think: ")).map((l) => l.slice(7)).join("\n\n") : "";
		const calls = group.map((c) => fauxToolCall(c.name, c.args as Parameters<typeof fauxToolCall>[1]));
		if (calls.length) return fauxAssistantMessage(thinking ? [fauxThinking(thinking), ...calls] : calls, { stopReason: "toolUse" });
		return fauxAssistantMessage([fauxText(`Echo: ${text}`)]);
	};
	// Each step queues the next; a few ahead, so conversations asking at the same moment (a side conversation started
	// mid-turn, say) don't find the queue empty.
	faux.setResponses(Array.from({ length: 8 }, () => step));
}

function scriptedTools(text: string): { name: string; args: Record<string, unknown>; together?: boolean }[] {
	const calls: { name: string; args: Record<string, unknown>; together?: boolean }[] = [];
	for (const raw of text.split("\n").map((l) => l.trim())) {
		const together = raw.startsWith("& ") && calls.length > 0;
		const line = together ? raw.slice(2) : raw;
		const before = calls.length;
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
				const [text, detail] = (m ? m[1]! : p).split(" :: ").map((x) => x.trim());
				return { text: text!, ...(detail ? { detail } : {}), status: m ? m[2]! : "pending" };
			});
			calls.push({ name: "todo", args: { items } });
		} else if (line.startsWith("plan: ")) {
			const [summary, ...steps] = parts(line.slice(6));
			calls.push({ name: "propose_plan", args: { summary, steps } });
		} else if (line.startsWith("task: ")) {
			const [description, ...prompt] = parts(line.slice(6));
			// The shorthand waits for its answer (the blocking `task`); `call: task | {…}` scripts the non-blocking one.
			calls.push({ name: "task", args: { description, prompt: prompt.join(" | ").replaceAll(" ; ", "\n"), wait: true } });
		} else if (line.startsWith("ask: ")) {
			const [question, ...options] = parts(line.slice(5));
			calls.push({ name: "ask_user", args: { question, ...(options.length ? { options } : {}) } });
		} else if (line.startsWith("edit: ")) {
			const [path, oldText = "", newText = ""] = parts(line.slice(6));
			calls.push({ name: "edit", args: { path, edits: [{ oldText, newText }] } });
		}
		if (together && calls.length > before) calls[calls.length - 1]!.together = true;
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
