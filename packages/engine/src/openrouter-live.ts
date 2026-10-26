/**
 * OpenRouter models newer than pi's catalog (docs/spec/10-model-providers). pi ships OpenRouter's models as a list
 * fixed at its release, and its refresh only narrows that list to what a key may use, so a model OpenRouter adds
 * later never shows. This reads OpenRouter's live list (public, cached for six hours in `<home>/openrouter-models.json`)
 * and adds the chat models with tool calling that the catalog lacks, shaped like pi's own entries: prices, context and
 * modalities from OpenRouter; the request details (reasoning levels, compatibility flags) from the catalog model of the
 * same maker whose id is closest.
 */
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import type { Api, Model, Provider } from "@earendil-works/pi-ai";

const LIST_URL = "https://openrouter.ai/api/v1/models";
const BASE_URL = "https://openrouter.ai/api/v1";
/** How long a fetched list is used before asking again. */
const MAX_AGE_MS = 6 * 3600_000;

/** One model in OpenRouter's `GET /models`, as far as we read it. */
export type LiveEntry = {
	id: string;
	name?: string;
	context_length?: number;
	architecture?: { input_modalities?: string[]; output_modalities?: string[] };
	pricing?: { prompt?: string; completion?: string; input_cache_read?: string; input_cache_write?: string };
	top_provider?: { context_length?: number | null; max_completion_tokens?: number | null };
	supported_parameters?: string[];
};

type Cache = { fetchedAt: number; entries: LiveEntry[] };

export class OpenRouterLive {
	private cache?: Cache;
	private extra: Model<Api>[] = [];
	private fetching?: Promise<boolean>;

	constructor(
		private readonly file?: string,
		private readonly fetchList: () => Promise<LiveEntry[]> = defaultFetch,
		private readonly now: () => number = Date.now,
	) {
		if (file && existsSync(file)) {
			try {
				this.cache = JSON.parse(readFileSync(file, "utf8")) as Cache;
			} catch {
				// a broken cache is fetched again
			}
		}
	}

	/** The models added on top of the catalog (what the last list had that pi's catalog doesn't). */
	get models(): readonly Model<Api>[] {
		return this.extra;
	}

	/** pi's OpenRouter provider with the added models listed too; requests go through it unchanged. */
	wrap(base: Provider): Provider {
		const { getAllModels, ...rest } = base;
		return {
			...rest,
			getModels: () => [...base.getModels(), ...this.extra],
			...(getAllModels ? { getAllModels: () => [...getAllModels.call(base), ...this.extra] } : {}),
		} as Provider;
	}

	/**
	 * Recomputes the added models from the cached list, fetching a new list when it's older than six hours (or with
	 * `force`). Returns whether the added models changed. Never throws: without the network the cache stays.
	 */
	async update(catalog: readonly Model<Api>[], options: { force?: boolean } = {}): Promise<boolean> {
		const stale = !this.cache || this.now() - this.cache.fetchedAt > MAX_AGE_MS;
		if (stale || options.force) {
			this.fetching ??= this.fetchList()
				.then((entries) => {
					this.cache = { fetchedAt: this.now(), entries };
					this.save();
					return true;
				})
				.catch(() => false)
				.finally(() => (this.fetching = undefined));
			await this.fetching;
		}
		return this.recompute(catalog);
	}

	/** Without fetching: the added models from the cached list (at startup, before any network). */
	recompute(catalog: readonly Model<Api>[]): boolean {
		const before = this.extra.map((m) => m.id).join("\n");
		this.extra = this.cache ? addedModels(this.cache.entries, catalog) : [];
		return this.extra.map((m) => m.id).join("\n") !== before;
	}

	private save(): void {
		if (!this.file || !this.cache) return;
		const tmp = `${this.file}.tmp`;
		writeFileSync(tmp, JSON.stringify(this.cache));
		renameSync(tmp, this.file);
	}
}

async function defaultFetch(): Promise<LiveEntry[]> {
	const res = await fetch(LIST_URL, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(15_000) });
	if (!res.ok) throw new Error(`OpenRouter model list: ${res.status}`);
	const body = (await res.json()) as { data?: LiveEntry[] };
	if (!Array.isArray(body.data)) throw new Error("OpenRouter model list: no data");
	return body.data;
}

/** The live list's chat models with tool calling that the catalog doesn't have, as pi models. */
export function addedModels(entries: readonly LiveEntry[], catalog: readonly Model<Api>[]): Model<Api>[] {
	const known = new Set(catalog.map((m) => m.id));
	const out: Model<Api>[] = [];
	for (const entry of entries) {
		if (known.has(entry.id)) continue;
		const model = liveModel(entry, catalog);
		if (model) out.push(model);
	}
	return out;
}

/** One live entry as a pi chat model, or undefined when Piopio can't use it (no tool calling, no text out). */
export function liveModel(entry: LiveEntry, catalog: readonly Model<Api>[]): Model<Api> | undefined {
	const params = entry.supported_parameters ?? [];
	const outputs = entry.architecture?.output_modalities ?? ["text"];
	if (!params.includes("tools") || !outputs.includes("text") || outputs.some((o) => o !== "text")) return undefined;
	const sibling = closest(entry.id, catalog);
	const reasoning = params.includes("reasoning") || params.includes("include_reasoning");
	const images = (entry.architecture?.input_modalities ?? []).includes("image");
	const perMillion = (price?: string) => {
		const n = Number(price ?? 0);
		return Number.isFinite(n) && n > 0 ? Math.round(n * 1e6 * 1e6) / 1e6 : 0;
	};
	const contextWindow = entry.top_provider?.context_length || entry.context_length || sibling?.contextWindow || 128_000;
	const sib = sibling as (Model<Api> & { thinkingLevelMap?: unknown; inputLimits?: unknown; compat?: unknown }) | undefined;
	return {
		type: "chat",
		id: entry.id,
		name: entry.name ?? entry.id,
		api: "openai-completions",
		baseUrl: BASE_URL,
		provider: "openrouter",
		reasoning,
		...(reasoning && sib?.reasoning && sib.thinkingLevelMap ? { thinkingLevelMap: sib.thinkingLevelMap } : {}),
		input: images ? ["text", "image"] : ["text"],
		cost: { input: perMillion(entry.pricing?.prompt), output: perMillion(entry.pricing?.completion), cacheRead: perMillion(entry.pricing?.input_cache_read), cacheWrite: perMillion(entry.pricing?.input_cache_write) },
		contextWindow,
		maxTokens: entry.top_provider?.max_completion_tokens || sibling?.maxTokens || Math.min(32_768, contextWindow),
		compat: sib?.compat ?? { supportsDeveloperRole: false, thinkingFormat: "openrouter" },
		...(images && sib?.inputLimits ? { inputLimits: sib.inputLimits } : {}),
	} as unknown as Model<Api>;
}

/** The catalog model of the same maker ("deepseek/…") whose id shares the longest start with this one. */
function closest(id: string, catalog: readonly Model<Api>[]): Model<Api> | undefined {
	const maker = id.replace(/^~/, "").split("/")[0];
	let best: Model<Api> | undefined;
	let bestLength = -1;
	for (const m of catalog) {
		if (m.api !== "openai-completions" || m.id.replace(/^~/, "").split("/")[0] !== maker) continue;
		let n = 0;
		while (n < id.length && n < m.id.length && id[n] === m.id[n]) n++;
		if (n > bestLength) {
			best = m;
			bestLength = n;
		}
	}
	return best;
}
