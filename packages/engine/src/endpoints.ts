/**
 * Custom endpoints (docs/spec/10-model-providers, P1): servers that speak the OpenAI API — LiteLLM, Ollama,
 * LM Studio, vLLM — added by address. Each becomes a pi provider registered on the shared ModelRuntime, with
 * its models read from `GET <address>/models`. The list (no secrets) lives in `endpoints.json`; a key, when
 * the server wants one, is a credential in the Keychain like any other provider's.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";

export type EndpointModel = { id: string; contextWindow?: number };
export type Endpoint = { id: string; name: string; baseUrl: string; keyless: boolean; models: EndpointModel[]; addedAt: string };

export type EndpointCheck = { ok: true; baseUrl: string; models: EndpointModel[] } | { ok: false; message: string };

/** Servers looked for on this Mac, at their default ports. */
export const LOCAL_SERVERS = [
	{ name: "Ollama", baseUrl: "http://localhost:11434/v1" },
	{ name: "LM Studio", baseUrl: "http://localhost:1234/v1" },
];

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
 * that worked. Context sizes come from whatever the server reports (vLLM's `max_model_len`, LM Studio's and
 * LiteLLM's `context_length`); otherwise they stay unknown.
 */
export async function checkEndpoint(address: string, key?: string, fetchImpl: typeof fetch = fetch, timeoutMs = 8_000): Promise<EndpointCheck> {
	let base = address.trim().replace(/\/+$/, "");
	if (!/^https?:\/\//.test(base)) base = `http://${base}`;
	let url: URL;
	try {
		url = new URL(base);
	} catch {
		return { ok: false, message: "That isn't a valid address. It looks like http://localhost:4000/v1." };
	}
	const candidates = base.endsWith("/v1") ? [base] : [base, `${base}/v1`];
	let last: EndpointCheck = { ok: false, message: `Can't reach ${url.host}. Is the server running?` };
	for (const candidate of candidates) {
		let response: Response;
		try {
			response = await fetchImpl(`${candidate}/models`, { headers: key ? { authorization: `Bearer ${key}` } : {}, signal: AbortSignal.timeout(timeoutMs) });
		} catch {
			return { ok: false, message: `Can't reach ${url.host}. Is the server running?` };
		}
		if (response.status === 401 || response.status === 403) return { ok: false, message: key ? "The server didn't accept this key." : "The server wants a key." };
		if (!response.ok) {
			last = { ok: false, message: `The server answered ${response.status} at ${candidate}/models.` };
			continue;
		}
		const body = (await response.json().catch(() => undefined)) as { data?: unknown } | undefined;
		if (!body || !Array.isArray(body.data)) {
			last = { ok: false, message: "That address doesn't look like an OpenAI-compatible server." };
			continue;
		}
		const models = (body.data as Record<string, unknown>[])
			.filter((m) => typeof m.id === "string")
			.map((m) => {
				const context = [m.context_length, m.context_window, m.max_model_len, m.max_context_length].find((v) => typeof v === "number" && v > 0) as number | undefined;
				return { id: m.id as string, ...(context ? { contextWindow: context } : {}) };
			});
		if (models.length === 0) return { ok: false, message: "The server answered but lists no models. Load or add one there first." };
		return { ok: true, baseUrl: candidate, models };
	}
	return last;
}

/** Local servers that answer at their default ports. */
export async function detectLocalServers(fetchImpl: typeof fetch = fetch): Promise<{ name: string; baseUrl: string; models: number }[]> {
	const found = await Promise.all(
		LOCAL_SERVERS.map(async (s) => {
			const check = await checkEndpoint(s.baseUrl, undefined, fetchImpl, 800);
			return check.ok ? { name: s.name, baseUrl: check.baseUrl, models: check.models.length } : undefined;
		}),
	);
	return found.filter((f) => f !== undefined);
}

/** pi's provider config for an endpoint: OpenAI Chat Completions, free, text in. */
export function endpointConfig(e: Endpoint) {
	return {
		name: e.name,
		baseUrl: e.baseUrl,
		api: "openai-completions",
		// Keyless servers still need a value for pi to count them as configured; they ignore it.
		...(e.keyless ? { apiKey: "none" } : {}),
		models: e.models.map((m) => ({
			id: m.id,
			name: m.id,
			reasoning: false,
			input: ["text"],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			contextWindow: m.contextWindow ?? 128_000,
			maxTokens: Math.min(16_384, Math.floor((m.contextWindow ?? 128_000) / 4)),
		})),
	};
}
