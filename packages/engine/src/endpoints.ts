/**
 * Custom endpoints (docs/spec/10-model-providers, P1): servers that speak the OpenAI or Anthropic API — LiteLLM,
 * Ollama, LM Studio, vLLM, llama.cpp, a company gateway — added by address. Each becomes a pi provider registered on
 * the shared ModelRuntime, with its models read from `GET <address>/models`. The list (no secrets) lives in
 * `endpoints.json`; a key, when the server wants one, is a credential in the Keychain like any other provider's.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";

export type EndpointModel = { id: string; contextWindow?: number; embedding?: boolean };
export type EndpointFormat = "openai" | "anthropic";
export type Endpoint = {
	id: string;
	name: string;
	baseUrl: string;
	keyless: boolean;
	models: EndpointModel[];
	addedAt: string;
	/** Which API it speaks (default OpenAI-compatible). */
	format?: EndpointFormat;
	/** Extra headers sent with every request (not secrets: those go in the key). */
	headers?: Record<string, string>;
	/** Context window to assume for models that don't report one. */
	contextWindow?: number;
};

export type EndpointError = "refused" | "auth" | "not_found" | "empty" | "tls" | "invalid" | "other";
export type EndpointCheck = { ok: true; baseUrl: string; models: EndpointModel[]; latencyMs: number } | { ok: false; message: string; error: EndpointError };

/** Servers looked for on this Mac, at their default ports (Settings › Models detection). */
export const LOCAL_SERVERS = [
	{ name: "Ollama", preset: "ollama", baseUrl: "http://localhost:11434/v1" },
	{ name: "LM Studio", preset: "lmstudio", baseUrl: "http://localhost:1234/v1" },
	{ name: "LiteLLM", preset: "litellm", baseUrl: "http://localhost:4000/v1" },
	{ name: "vLLM", preset: "vllm", baseUrl: "http://localhost:8000/v1" },
	{ name: "llama.cpp", preset: "llamacpp", baseUrl: "http://localhost:8080/v1" },
];

/** Embedding-only models can't chat; they start hidden. */
export const isEmbedding = (id: string) => /embed|bge-|\be5-|gte-|minilm/i.test(id);

export class Endpoints {
	private items: Endpoint[] = [];

	constructor(private readonly path?: string) {
		if (path && existsSync(path)) {
			try {
				this.items = JSON.parse(readFileSync(path, "utf8")) as Endpoint[];
			} catch {
				this.items = [];
			}
		}
	}

	list(): readonly Endpoint[] {
		return this.items;
	}

	get(id: string): Endpoint | undefined {
		return this.items.find((e) => e.id === id);
	}

	/** A new id from the name ("LiteLLM (home)" → "custom-litellm-home"), unique among endpoints. */
	newId(name: string): string {
		const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "endpoint";
		let id = `custom-${slug}`;
		for (let n = 2; this.get(id); n++) id = `custom-${slug}-${n}`;
		return id;
	}

	save(endpoint: Endpoint): void {
		this.items = [...this.items.filter((e) => e.id !== endpoint.id), endpoint];
		this.write();
	}

	remove(id: string): void {
		this.items = this.items.filter((e) => e.id !== id);
		this.write();
	}

	private write(): void {
		if (this.path) writeFileSync(this.path, `${JSON.stringify(this.items, null, "\t")}\n`, { mode: 0o600 });
	}
}

export function isLocal(baseUrl: string): boolean {
	try {
		const host = new URL(baseUrl).hostname;
		return host === "localhost" || host === "127.0.0.1" || host === "[::1]" || host === "::1";
	} catch {
		return false;
	}
}

/** Who pays for an endpoint's requests: nobody but you. */
export const endpointBilling = (e: Pick<Endpoint, "baseUrl">) => (isLocal(e.baseUrl) ? "On this Mac" : "Your server");

/**
 * Asks the server for its models. Tries the address as given, then with `/v1` added, and answers with the one
 * that worked, how long it took, or what went wrong (refused, wants a key, no model list, none loaded, certificate).
 * Context sizes come from whatever the server reports (vLLM's `max_model_len`, LM Studio's and LiteLLM's
 * `context_length`); otherwise they stay unknown.
 */
export async function checkEndpoint(
	address: string,
	key?: string,
	fetchImpl: typeof fetch = fetch,
	timeoutMs = 8_000,
	options: { format?: EndpointFormat; headers?: Record<string, string> } = {},
): Promise<EndpointCheck> {
	let base = address.trim().replace(/\/+$/, "");
	if (!/^https?:\/\//.test(base)) base = `http://${base}`;
	let url: URL;
	try {
		url = new URL(base);
	} catch {
		return { ok: false, error: "invalid", message: "That isn't a valid address. It looks like http://localhost:4000/v1." };
	}
	const headers: Record<string, string> = { ...options.headers };
	if (key && options.format === "anthropic") {
		headers["x-api-key"] = key;
		headers["anthropic-version"] = "2023-06-01";
	} else if (key) headers.authorization = `Bearer ${key}`;
	const candidates = base.endsWith("/v1") ? [base] : [base, `${base}/v1`];
	let last: EndpointCheck = { ok: false, error: "refused", message: `Nothing is answering at ${url.host}. Is the server running?` };
	for (const candidate of candidates) {
		let response: Response;
		const started = Date.now();
		try {
			response = await fetchImpl(`${candidate}/models`, { headers, signal: AbortSignal.timeout(timeoutMs) });
		} catch (error) {
			const text = String((error as { cause?: { code?: string } }).cause?.code ?? (error as Error).message);
			if (/CERT|SSL|TLS|self.signed/i.test(text)) return { ok: false, error: "tls", message: "The server's certificate isn't trusted." };
			return { ok: false, error: "refused", message: `Nothing is answering at ${url.host}. Is the server running?` };
		}
		const latencyMs = Date.now() - started;
		if (response.status === 401 || response.status === 403) return { ok: false, error: "auth", message: key ? "The server didn't accept this key." : "The server wants an API key." };
		if (!response.ok) {
			last = { ok: false, error: "not_found", message: response.status === 404 ? `Reachable, but there's no model list at ${candidate}/models.` : `The server answered ${response.status} at ${candidate}/models.` };
			continue;
		}
		const body = (await response.json().catch(() => undefined)) as { data?: unknown } | undefined;
		if (!body || !Array.isArray(body.data)) {
			last = { ok: false, error: "not_found", message: "That address doesn't look like an OpenAI- or Anthropic-compatible server." };
			continue;
		}
		const models = (body.data as Record<string, unknown>[])
			.filter((m) => typeof m.id === "string")
			.map((m) => {
				const context = [m.context_length, m.context_window, m.max_model_len, m.max_context_length].find((v) => typeof v === "number" && v > 0) as number | undefined;
				return { id: m.id as string, ...(context ? { contextWindow: context } : {}), ...(isEmbedding(m.id as string) ? { embedding: true } : {}) };
			});
		if (models.length === 0) return { ok: false, error: "empty", message: "Connected, but no models are loaded on the server." };
		return { ok: true, baseUrl: candidate, models, latencyMs };
	}
	return last;
}

/** Local servers that answer at their default ports. */
export async function detectLocalServers(fetchImpl: typeof fetch = fetch): Promise<{ name: string; baseUrl: string; models: number; preset: string }[]> {
	const found = await Promise.all(
		LOCAL_SERVERS.map(async (s) => {
			const check = await checkEndpoint(s.baseUrl, undefined, fetchImpl, 300);
			return check.ok ? { name: s.name, baseUrl: check.baseUrl, models: check.models.length, preset: s.preset } : undefined;
		}),
	);
	return found.filter((f) => f !== undefined);
}

/** pi's provider config for an endpoint: OpenAI Chat Completions or Anthropic Messages, free, text in. */
export function endpointConfig(e: Endpoint) {
	return {
		name: e.name,
		// pi's Anthropic API adds /v1/messages itself; OpenAI-compatible bases keep their /v1.
		baseUrl: e.format === "anthropic" ? e.baseUrl.replace(/\/v1$/, "") : e.baseUrl,
		api: e.format === "anthropic" ? "anthropic-messages" : "openai-completions",
		...(e.headers && Object.keys(e.headers).length ? { headers: e.headers } : {}),
		// Keyless servers still need a value for pi to count them as configured; they ignore it.
		...(e.keyless ? { apiKey: "none" } : {}),
		models: e.models
			.filter((m) => !m.embedding)
			.map((m) => {
				const context = m.contextWindow ?? e.contextWindow ?? 128_000;
				return {
					id: m.id,
					name: m.id,
					reasoning: false,
					input: ["text"],
					cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
					contextWindow: context,
					maxTokens: Math.min(16_384, Math.floor(context / 4)),
				};
			}),
	};
}
