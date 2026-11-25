/**
 * Custom endpoints (docs/spec/10-model-providers, P1 and §14): servers that speak the OpenAI or Anthropic API — LiteLLM,
 * Ollama, LM Studio, vLLM, llama.cpp, a company gateway — added by address. Each is a provider in pi's own
 * `models.json` (in pi's folder), which pi reads itself, so the same servers are there in pi's CLI. A key, when the
 * server wants one, is a credential in the Keychain like any other provider's, never in the file.
 *
 * The file is yours and pi's as much as Piopio's: it is edited in place (comments and formatting stay), only the
 * endpoint's own entry is touched, and a provider you wrote there by hand is listed like one added in Settings.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, statSync } from "node:fs";
import { dirname } from "node:path";
import { applyEdits, findNodeAtLocation, format, modify, parse, parseTree, type ParseError } from "jsonc-parser";
import { readJsonFile, writeFileAtomic } from "./atomic.js";

/** `vision` and `reasoning`: what the server's own model list says the model takes, when it says. */
export type EndpointModel = { id: string; contextWindow?: number; embedding?: boolean; vision?: boolean; reasoning?: boolean };
/** What pi's catalog knows about a model served under the same id elsewhere (`ModelHub.knownModel`). */
export type KnownModel = { vision: boolean; reasoning: boolean; contextWindow: number; maxTokens: number };
export type EndpointFormat = "openai" | "anthropic";
/** An endpoint as Settings shows it, read from its provider entry in `models.json`. */
export type Endpoint = {
	id: string;
	name: string;
	baseUrl: string;
	/** The file gives the key itself (Piopio writes a placeholder for servers that want none): nothing in the Keychain. */
	keyless: boolean;
	models: EndpointModel[];
	/** Which API it speaks (default OpenAI-compatible). */
	format: EndpointFormat;
	/** Extra headers sent with every request (not secrets: those go in the key). */
	headers?: Record<string, string>;
};

/** A provider entry in pi's `models.json`, as far as Piopio reads it. Fields it doesn't know are kept as they are. */
export type PiProvider = { name?: string; baseUrl?: string; api?: string; apiKey?: string; headers?: Record<string, string>; models?: PiModel[]; [other: string]: unknown };
export type PiModel = { id: string; name?: string; api?: string; reasoning?: boolean; input?: string[]; contextWindow?: number; maxTokens?: number; [other: string]: unknown };

/** What `endpoints.json` held before endpoints moved into pi's `models.json` (2026-11-25). */
type LegacyEndpoint = { id: string; name: string; baseUrl: string; keyless: boolean; models: EndpointModel[]; format?: EndpointFormat; headers?: Record<string, string>; contextWindow?: number };

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

const TABS = { insertSpaces: false, tabSize: 1, eol: "\n" };

/**
 * `text` (JSON with comments) with one provider's entry set or removed. Only that entry is written and laid out: the
 * library's own formatting lays out the neighbours of what it inserts too, and they are someone else's.
 */
function putProvider(text: string, id: string, provider: PiProvider | undefined): string {
	const path = ["providers", id];
	const before = parseTree(text);
	// No `providers` yet: there's nothing of anyone's in it to disturb.
	if (!before || !findNodeAtLocation(before, ["providers"])) return applyEdits(text, modify(text, path, provider, { formattingOptions: TABS }));
	const existed = Boolean(findNodeAtLocation(before, path));
	let next = applyEdits(text, modify(text, path, provider, {}));
	if (provider === undefined) return next;
	if (!existed) {
		// A new entry goes on a line of its own, indented like the entry before it.
		const key = findNodeAtLocation(parseTree(next)!, path)!.parent!;
		const siblings = key.parent!.children!;
		const other = siblings.find((c) => c !== key);
		const lead = other ? next.slice(next.lastIndexOf("\n", other.offset) + 1, other.offset) : "";
		const indent = other && /^[ \t]+$/.test(lead) ? lead : "\t\t";
		if (!/\n[ \t]*$/.test(next.slice(0, key.offset))) next = `${next.slice(0, key.offset)}\n${indent}${next.slice(key.offset)}`;
	}
	const value = findNodeAtLocation(parseTree(next)!, path)!;
	return applyEdits(next, format(next, { offset: value.offset, length: value.length }, TABS));
}

/** pi's `models.json` couldn't be read as it is: nothing is written over it. */
export class ModelsFileError extends Error {}

export class Endpoints {
	private cache?: { stamp: string; providers: Record<string, PiProvider> };

	/** `path`: pi's `models.json`. Without one (a hub with no home) there are no endpoints. */
	constructor(private readonly path?: string) {}

	/** The file's text and its providers; a file that doesn't parse throws `ModelsFileError`. */
	private read(): { text: string; providers: Record<string, PiProvider> } {
		if (!this.path || !existsSync(this.path)) return { text: "", providers: {} };
		const text = readFileSync(this.path, "utf8");
		const errors: ParseError[] = [];
		const parsed = parse(text, errors, { allowTrailingComma: true }) as { providers?: Record<string, PiProvider> } | undefined;
		if (errors.length || (text.trim() && (typeof parsed !== "object" || parsed === null))) throw new ModelsFileError(`pi's models.json has an error, so it was left as it is. Fix it and try again: ${this.path}`);
		return { text, providers: parsed?.providers && typeof parsed.providers === "object" ? parsed.providers : {} };
	}

	/** Every provider entry, read again only when the file changed. A file with an error has none. */
	private providers(): Record<string, PiProvider> {
		if (!this.path) return {};
		const stat = statSync(this.path, { throwIfNoEntry: false });
		const stamp = stat ? `${stat.mtimeMs}:${stat.size}` : "none";
		if (this.cache?.stamp !== stamp) {
			let providers: Record<string, PiProvider> = {};
			try {
				providers = this.read().providers;
			} catch {
				// Shown where it matters: pi reports the file's error, and a save refuses.
			}
			this.cache = { stamp, providers };
		}
		return this.cache.providers;
	}

	/**
	 * The providers the file adds: an entry with an address and its own models (pi's rule for a new provider; an
	 * entry that only adjusts a built-in one has no model list of its own with an `api`).
	 */
	list(): readonly Endpoint[] {
		return Object.entries(this.providers()).flatMap(([id, p]) => {
			if (typeof p?.baseUrl !== "string" || !Array.isArray(p.models) || !(p.api || p.models.some((m) => m.api))) return [];
			return [
				{
					id,
					name: p.name ?? id,
					baseUrl: p.baseUrl,
					keyless: p.apiKey !== undefined,
					models: p.models.filter((m) => typeof m?.id === "string").map((m) => ({ id: m.id, ...(m.contextWindow ? { contextWindow: m.contextWindow } : {}), vision: Boolean(m.input?.includes("image")), reasoning: Boolean(m.reasoning) })),
					format: p.api === "anthropic-messages" ? ("anthropic" as const) : ("openai" as const),
					...(p.headers && Object.keys(p.headers).length ? { headers: p.headers } : {}),
				},
			];
		});
	}

	get(id: string): Endpoint | undefined {
		return this.list().find((e) => e.id === id);
	}

	/** The entry as the file has it, with whatever else you or pi put there. */
	raw(id: string): PiProvider | undefined {
		return this.providers()[id];
	}

	/** A new id from the name ("LiteLLM (home)" → "custom-litellm-home"), unique among the file's providers. */
	newId(name: string): string {
		const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "endpoint";
		const taken = this.providers();
		let id = `custom-${slug}`;
		for (let n = 2; taken[id]; n++) id = `custom-${slug}-${n}`;
		return id;
	}

	/** Writes one provider's entry (`undefined` removes it), leaving the rest of the file, comments included, as it is. */
	write(id: string, provider: PiProvider | undefined): void {
		if (!this.path) throw new ModelsFileError("There's nowhere to keep endpoints here.");
		const { text } = this.read();
		const base = text.trim() ? text : "{}\n";
		const next = putProvider(base, id, provider);
		mkdirSync(dirname(this.path), { recursive: true });
		const mode = statSync(this.path, { throwIfNoEntry: false })?.mode;
		writeFileAtomic(this.path, next.endsWith("\n") ? next : `${next}\n`, mode ? { mode: mode & 0o777 } : { mode: 0o600 });
		this.cache = undefined;
	}

	/**
	 * Endpoints from the `endpoints.json` Piopio kept before: each goes into `models.json` unless that id is already
	 * there, and the old file is set aside (`.migrated`). Returns how many moved.
	 */
	migrate(legacyPath: string, known: (id: string) => KnownModel | undefined): number {
		if (!this.path || !existsSync(legacyPath)) return 0;
		const old = readJsonFile<LegacyEndpoint[]>(legacyPath, () => []);
		let moved = 0;
		for (const e of Array.isArray(old) ? old : []) {
			if (!e?.id || this.providers()[e.id]) continue;
			this.write(e.id, piProvider(undefined, { name: e.name, baseUrl: e.baseUrl, format: e.format ?? "openai", keyless: e.keyless, ...(e.headers ? { headers: e.headers } : {}) }, e.models, { ...(e.contextWindow ? { contextWindow: e.contextWindow } : {}), known }));
			moved++;
		}
		renameSync(legacyPath, `${legacyPath}.migrated`);
		return moved;
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
				// Gateways with OpenRouter's model list say what each model takes; most servers don't.
				const architecture = m.architecture as { input_modalities?: unknown } | undefined;
				const modalities = [m.input_modalities, architecture?.input_modalities].find((v) => Array.isArray(v)) as unknown[] | undefined;
				const parameters = Array.isArray(m.supported_parameters) ? (m.supported_parameters as unknown[]) : undefined;
				return {
					id: m.id as string,
					...(context ? { contextWindow: context } : {}),
					...(isEmbedding(m.id as string) ? { embedding: true } : {}),
					...(modalities ? { vision: modalities.includes("image") } : {}),
					...(parameters ? { reasoning: parameters.includes("reasoning") || parameters.includes("reasoning_effort") } : {}),
				};
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

/** A model's entry for `models.json`: what the server said, then what pi's catalog knows of that id, then text only. */
function piModel(m: EndpointModel, options: { contextWindow?: number; known: (id: string) => KnownModel | undefined }): PiModel {
	const same = options.known(m.id);
	const context = m.contextWindow ?? options.contextWindow ?? same?.contextWindow ?? 128_000;
	return {
		id: m.id,
		name: m.id,
		reasoning: m.reasoning ?? same?.reasoning ?? false,
		input: (m.vision ?? same?.vision ?? false) ? ["text", "image"] : ["text"],
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: context,
		// The model's own limit when pi knows it, within what this server's context leaves.
		maxTokens: Math.min(same?.maxTokens ?? 16_384, Math.floor(context / 4)),
	};
}

/**
 * An endpoint's provider entry for pi's `models.json`. `previous` is the entry there now: whatever else it holds
 * stays (`compat`, `modelOverrides`, fields pi adds later), and a model already listed keeps its entry as it is, so
 * what you corrected by hand isn't undone by the next check; only a context size the server now reports, or one you
 * set, replaces the old. `served` is what the server lists now (`undefined`: it didn't answer, keep the models).
 * Embedding models aren't written: they can't chat.
 */
export function piProvider(
	previous: PiProvider | undefined,
	endpoint: { name: string; baseUrl: string; format?: EndpointFormat; keyless: boolean; headers?: Record<string, string> },
	served: EndpointModel[] | undefined,
	options: { contextWindow?: number; known: (id: string) => KnownModel | undefined },
): PiProvider {
	const api = endpoint.format ? (endpoint.format === "anthropic" ? "anthropic-messages" : "openai-completions") : (previous?.api ?? "openai-completions");
	const before = new Map((previous?.models ?? []).map((m) => [m.id, m]));
	const models = served
		? served
				.filter((m) => !m.embedding)
				.map((m) => {
					const kept = before.get(m.id);
					if (!kept) return piModel(m, options);
					const context = m.contextWindow ?? options.contextWindow;
					return context && context !== kept.contextWindow ? { ...kept, contextWindow: context, maxTokens: Math.min(kept.maxTokens ?? 16_384, Math.floor(context / 4)) } : kept;
				})
		: (previous?.models ?? []);
	const { apiKey: _key, headers: _headers, ...rest } = previous ?? {};
	return {
		...rest,
		name: endpoint.name,
		// pi's Anthropic API adds /v1/messages itself; OpenAI-compatible bases keep their /v1.
		baseUrl: api === "anthropic-messages" ? endpoint.baseUrl.replace(/\/v1$/, "") : endpoint.baseUrl,
		api,
		// A server that wants no key still needs a value for pi to count it as configured; it ignores it.
		...(endpoint.keyless ? { apiKey: previous?.apiKey ?? "none" } : {}),
		...(endpoint.headers && Object.keys(endpoint.headers).length ? { headers: endpoint.headers } : {}),
		models,
	};
}
