/**
 * The engine's memory providers (07-shared §5.1, §6.2): the built-in one (SQLite in `<home>/memory.db`) and the MCP
 * memory providers configured in Settings › Chat › Memory, each a memory system reached through its MCP server.
 */
import { randomUUID } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { McpMemoryProvider as McpMemoryConfig } from "@piopio/protocol";
import { BuiltinMemory, openAiEmbedder, pack, type Embedder, type MemoryHit, type MemoryKind, type MemoryProvider, type MemoryRecord, type RetainInput, type Sql } from "@piopio/runtime";
import type { McpConfig } from "./mcp.js";
import { EngineError } from "./models.js";
import type { Settings } from "./settings.js";
import { transport, withTimeout } from "./tools/mcp-chat.js";

/** Hindsight's MCP endpoint (one for every bank, `bank_id` as an argument). Checked against hindsight-api 1.0.0. */
export const HINDSIGHT_PRESET: Omit<McpMemoryConfig, "id" | "name"> = {
	url: "http://127.0.0.1:8888/mcp",
	tools: {
		recall: { tool: "recall", args: { query: "{query}", bank_id: "{bank}", max_tokens: "{budget}", budget: "mid" } },
		retain: { tool: "retain", args: { content: "{content}", bank_id: "{bank}", timestamp: "{at}", context: "{source}" } },
		list: { tool: "list_memories", args: { bank_id: "{bank}", limit: "{limit}" } },
		forget: { tool: "invalidate_memory", args: { memory_id: "{id}", bank_id: "{bank}", reason: "Forgotten in Piopio" } },
		reflect: { tool: "reflect", args: { query: "{query}", bank_id: "{bank}" } },
	},
};

/** The default embedding model (docs/spec/14-memory §5.1): the same model through OpenRouter or the OpenAI API, so vectors match either way. */
export const EMBEDDING_MODEL = { id: "openai/text-embedding-3-small@256", openrouter: "openai/text-embedding-3-small", openai: "text-embedding-3-small", dims: 256 };
/** After a failure (no key, offline), recall stays keyword-only this long before trying again. */
const EMBEDDINGS_RETRY_MS = 60_000;

export class MemoryProviders {
	readonly builtin: BuiltinMemory;
	private readonly mcp = new Map<string, McpMemory>();
	private embedder?: Embedder;
	private pausedUntil = 0;
	private lastError?: { reason: "no_key" | "failing"; message: string };
	private via?: string;
	private backfill?: Promise<void>;

	constructor(
		file: string,
		private readonly mcpConfig: McpConfig,
		private readonly settings: Settings,
		/** A provider's API key (OpenRouter, OpenAI API), read per request so a new key applies at once. */
		private readonly keyFor: (provider: string) => Promise<string | undefined> = async () => undefined,
	) {
		const db = new DatabaseSync(file);
		const sql: Sql = { exec: (s) => db.exec(s), run: (s, ...p) => void db.prepare(s).run(...(p as never[])), all: (s, ...p) => db.prepare(s).all(...(p as never[])) as never };
		this.builtin = new BuiltinMemory(sql, () => randomUUID(), undefined, () => this.currentEmbedder());
		this.embedder = this.makeEmbedder();
		settings.onChange((next, previous) => {
			if (JSON.stringify(next.memory) !== JSON.stringify(previous.memory)) {
				this.embedder = this.makeEmbedder();
				this.pausedUntil = 0;
				void this.reset();
				this.fill();
			}
		});
	}

	/** Semantic search, unless memory stays on this Mac or the last request failed a moment ago. */
	private currentEmbedder(): Embedder | undefined {
		return Date.now() < this.pausedUntil ? undefined : this.embedder;
	}

	/** The configured endpoint, else OpenRouter, else the OpenAI API key; a request without any key pauses semantic search. */
	private makeEmbedder(): Embedder | undefined {
		const memory = this.settings.get().memory;
		if (memory.localOnly) return undefined;
		const custom = memory.embeddings;
		const inner = custom
			? openAiEmbedder({ baseUrl: custom.baseUrl, model: custom.model, dims: custom.dims, id: `${custom.model}@${custom.dims}`, key: async () => (custom.provider ? this.keyFor(custom.provider) : undefined) })
			: undefined;
		const tracked: Embedder = {
			model: inner?.model ?? EMBEDDING_MODEL.id,
			dims: inner?.dims ?? EMBEDDING_MODEL.dims,
			embed: async (texts) => {
				try {
					const out = inner ? await inner.embed(texts) : await this.embedDefault(texts);
					this.lastError = undefined;
					return out;
				} catch (error) {
					this.pausedUntil = Date.now() + EMBEDDINGS_RETRY_MS;
					const message = error instanceof Error ? error.message : String(error);
					this.lastError = { reason: message === "no_key" ? "no_key" : "failing", message };
					throw error;
				}
			},
		};
		if (custom) this.via = custom.baseUrl;
		return tracked;
	}

	private async embedDefault(texts: readonly string[]): Promise<Float32Array[]> {
		const openrouter = await this.keyFor("openrouter");
		if (openrouter) {
			this.via = "OpenRouter";
			return openAiEmbedder({ baseUrl: "https://openrouter.ai/api/v1", model: EMBEDDING_MODEL.openrouter, dims: EMBEDDING_MODEL.dims, id: EMBEDDING_MODEL.id, key: async () => openrouter }).embed(texts);
		}
		const openai = await this.keyFor("openai-api");
		if (openai) {
			this.via = "OpenAI API";
			return openAiEmbedder({ baseUrl: "https://api.openai.com/v1", model: EMBEDDING_MODEL.openai, dims: EMBEDDING_MODEL.dims, id: EMBEDDING_MODEL.id, key: async () => openai }).embed(texts);
		}
		throw new Error("no_key");
	}

	/** Embeds, in the background, records that have no vector yet (written while offline, or before semantic search). */
	fill(): void {
		if (this.backfill || !this.currentEmbedder() || this.builtin.missingVectors() === 0) return;
		this.backfill = (async () => {
			try {
				while (this.currentEmbedder() && (await this.builtin.reindex({ batch: 64, max: 64 })) > 0) await new Promise((r) => setTimeout(r, 200));
			} catch {
				// paused by the failure; the next fill() tries again
			} finally {
				this.backfill = undefined;
			}
		})();
	}

	/** Embeds everything that has no vector from the current model, in the background. Returns how many wait. */
	reindex(): number {
		this.pausedUntil = 0;
		const pending = this.builtin.missingVectors();
		this.fill();
		return pending;
	}

	/** For Settings: whether recall is semantic, with what, and how much is indexed. Checks the key when it hasn't been used yet. */
	async status(): Promise<{ semantic: boolean; reason?: string; error?: string; model?: string; via?: string; records: number; indexed: number }> {
		const memory = this.settings.get().memory;
		if (!this.via && !memory.localOnly && !memory.embeddings) {
			this.via = (await this.keyFor("openrouter")) ? "OpenRouter" : (await this.keyFor("openai-api")) ? "OpenAI API" : undefined;
			if (!this.via) this.lastError = { reason: "no_key", message: "no_key" };
		}
		const counts = this.builtin.vectorStatus();
		this.fill();
		if (memory.localOnly) return { semantic: false, reason: "local_only", records: counts.records, indexed: 0 };
		if (this.lastError) return { semantic: false, reason: this.lastError.reason, ...(this.lastError.reason === "failing" ? { error: this.lastError.message } : {}), model: this.embedder?.model, records: counts.records, indexed: counts.indexed };
		return { semantic: true, ...(this.embedder ? { model: this.embedder.model } : {}), ...(this.via ? { via: this.via } : {}), records: counts.records, indexed: counts.indexed };
	}

	/** "builtin", or an MCP memory provider's id. */
	get(id: string): MemoryProvider {
		if (id === "builtin") return this.builtin;
		const config = this.settings.get().memory.providers.find((p) => p.id === id);
		if (!config) throw new EngineError("NOT_FOUND", `No memory provider ${id}`);
		let provider = this.mcp.get(id);
		if (!provider) {
			provider = new McpMemory(config, (c) => this.connect(c));
			this.mcp.set(id, provider);
		}
		return provider;
	}

	/** The tools of a server or URL, for the mapping editor. */
	async tools(target: { server?: string; url?: string }): Promise<{ name: string; description?: string }[]> {
		const client = await this.connect(target);
		try {
			return (await withTimeout(client.listTools(), 15_000)).tools.map((t) => ({ name: t.name, ...(t.description ? { description: t.description.split("\n")[0]!.slice(0, 200) } : {}) }));
		} finally {
			await client.close().catch(() => undefined);
		}
	}

	private async connect(target: { server?: string; url?: string }): Promise<Client> {
		const client = new Client({ name: "piopio-memory", version: "1.0.0" });
		if (target.url) {
			await withTimeout(client.connect(new StreamableHTTPClientTransport(new URL(target.url))), 15_000);
		} else {
			const server = this.mcpConfig.enabledGlobal().find((s) => s.name === target.server)?.server;
			if (!server) throw new EngineError("NOT_FOUND", `No MCP server “${target.server}” (it must be in Settings › MCP servers, and on).`);
			await withTimeout(client.connect(transport(server)), 15_000);
		}
		return client;
	}

	/** Drops the connections (settings changed): new calls get providers with the new settings right away. */
	async reset(): Promise<void> {
		const old = [...this.mcp.values()];
		this.mcp.clear();
		for (const p of old) await p.close();
	}
}

/**
 * A memory system behind its MCP server (07-shared §6.2): each operation is a tool call whose arguments are filled
 * from the mapping's placeholders ({bank}, {query}, {content}, {source}, {at}, {id}, {limit}, {budget}). Results are
 * read as JSON when they are (an array, or an object with results/items/memories), else as one fact per line.
 */
export class McpMemory implements MemoryProvider {
	readonly id: string;
	readonly capabilities;
	private client?: Promise<Client>;

	constructor(
		private readonly config: McpMemoryConfig,
		private readonly connect: (target: { server?: string; url?: string }) => Promise<Client>,
	) {
		this.id = config.id;
		const t = config.tools;
		this.capabilities = { retain: Boolean(t.retain), list: Boolean(t.list), forget: Boolean(t.forget), update: false, reflect: Boolean(t.reflect), history: false };
	}

	private async call(op: keyof McpMemoryConfig["tools"], values: Record<string, unknown>): Promise<string> {
		const mapping = this.config.tools[op];
		if (!mapping) throw new EngineError("INVALID", `${this.config.name} has no ${op} tool.`);
		this.client ??= this.connect({ ...(this.config.url ? { url: this.config.url } : {}), ...(this.config.server ? { server: this.config.server } : {}) });
		let client: Client;
		try {
			client = await this.client;
		} catch (error) {
			this.client = undefined;
			throw error;
		}
		const result = (await withTimeout(client.callTool({ name: mapping.tool, arguments: fill(mapping.args, values) as Record<string, unknown> }), 60_000)) as { content?: { type: string; text?: string }[]; isError?: boolean };
		const text = (result.content ?? []).filter((c) => c.type === "text").map((c) => c.text ?? "").join("\n");
		if (result.isError) throw new EngineError("INTERNAL", `${this.config.name}: ${text || "the tool failed"}`);
		return text;
	}

	async retain(bank: string, input: RetainInput): Promise<MemoryRecord[]> {
		await this.call("retain", { bank, content: input.content, source: input.source?.title ?? input.source?.ref ?? "", at: input.at ?? new Date().toISOString(), tags: input.tags ?? [] });
		return []; // the memory system decides what to store
	}

	async recall(banks: readonly string[], query: string, options: { budgetTokens?: number; kinds?: MemoryKind[]; limit?: number } = {}): Promise<MemoryHit[]> {
		const hits: MemoryHit[] = [];
		for (const bank of banks) {
			const records = parseRecords(await this.call("recall", { bank, query, budget: options.budgetTokens ?? 1500, limit: options.limit ?? 20 }), bank);
			records.forEach((r, i) => hits.push({ ...r, score: 1 - i / Math.max(1, records.length) }));
		}
		hits.sort((a, b) => b.score - a.score);
		return pack(hits.slice(0, options.limit ?? 40), options.budgetTokens ?? 1500);
	}

	async reflect(bank: string, question: string) {
		const text = await this.call("reflect", { bank, query: question });
		let answer = text;
		try {
			const parsed = JSON.parse(text) as { text?: string; answer?: string };
			answer = parsed.text ?? parsed.answer ?? text;
		} catch {
			// plain text
		}
		return { answer, used: [] };
	}

	async list(bank: string, options: { limit?: number } = {}): Promise<{ records: MemoryRecord[] }> {
		return { records: parseRecords(await this.call("list", { bank, limit: options.limit ?? 100 }), bank) };
	}

	async forget(bank: string, id: string): Promise<void> {
		await this.call("forget", { bank, id });
	}

	async close(): Promise<void> {
		const client = await this.client?.catch(() => undefined);
		this.client = undefined;
		await client?.close().catch(() => undefined);
	}
}

/** Replaces {placeholders}: a whole-string placeholder keeps the value's type (numbers, arrays). */
export function fill(value: unknown, values: Record<string, unknown>): unknown {
	if (typeof value === "string") {
		const whole = /^\{(\w+)\}$/.exec(value);
		if (whole) return values[whole[1]!] ?? "";
		return value.replace(/\{(\w+)\}/g, (_, k: string) => String(values[k] ?? ""));
	}
	if (Array.isArray(value)) return value.map((v) => fill(v, values));
	if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, fill(v, values)]));
	return value;
}

/** Records from a tool's answer: JSON (an array, or results/items/memories/data/hits), else one per line. */
export function parseRecords(text: string, bank: string): MemoryRecord[] {
	let items: unknown[] | undefined;
	try {
		const parsed = JSON.parse(text) as unknown;
		if (Array.isArray(parsed)) items = parsed;
		else if (parsed && typeof parsed === "object") {
			const o = parsed as Record<string, unknown>;
			items = (["results", "items", "memories", "data", "hits", "facts"].map((k) => o[k]).find(Array.isArray) as unknown[] | undefined) ?? [];
		}
	} catch {
		items = undefined;
	}
	const kindOf = (t: unknown): MemoryKind => (t === "observation" ? "observation" : t === "opinion" ? "opinion" : t === "experience" ? "experience" : "fact");
	if (items) {
		return items.flatMap((item, i) => {
			if (typeof item === "string") return [{ id: String(i), bank, text: item, kind: "fact" as const, createdBy: "extraction" as const, at: "" }];
			const o = (item ?? {}) as Record<string, unknown>;
			const textOf = [o.text, o.content, o.memory, o.fact].find((v) => typeof v === "string") as string | undefined;
			if (!textOf) return [];
			const at = [o.mentioned_at, o.created_at, o.date, o.timestamp, o.at].find((v) => typeof v === "string") as string | undefined;
			return [{ id: String(o.id ?? o.memory_id ?? o.uuid ?? i), bank, text: textOf, kind: kindOf(o.type ?? o.fact_type), createdBy: "extraction" as const, at: at ?? "" }];
		});
	}
	return text
		.split("\n")
		.map((l) => l.replace(/^\s*(?:[-*•]|\d+[.)])\s+/, "").trim())
		.filter(Boolean)
		.map((line, i) => ({ id: String(i), bank, text: line, kind: "fact" as const, createdBy: "extraction" as const, at: "" }));
}

/**
 * Settings › Memory › Export (docs/spec/14-memory §5.3): everything the built-in provider holds, replaced facts too,
 * as memory.json (every field) and memory.md (one section per bank, readable).
 */
export function exportMemory(memory: BuiltinMemory, folder: string, label: (bank: string) => string): { files: string[]; records: number } {
	mkdirSync(folder, { recursive: true });
	const records = memory.dump();
	const json = join(folder, "memory.json");
	writeFileSync(json, `${JSON.stringify({ exportedAt: new Date().toISOString(), records }, null, "\t")}\n`);
	const lines = [`# Piopio memory`, "", `Exported ${new Date().toISOString().slice(0, 10)} · ${records.length} records`, ""];
	let bank = "";
	for (const r of records) {
		if (r.bank !== bank) {
			bank = r.bank;
			lines.push("", `## ${label(bank)}`, "");
		}
		const when = r.at.slice(0, 10);
		const ended = r.endedAt ? ` (until ${r.endedAt.slice(0, 10)}${r.replacedBy ? ", replaced" : ""})` : "";
		lines.push(`- ${when} · ${r.kind}${r.pinned ? " · pinned" : ""}: ${r.text.replace(/\n+/g, " ")}${ended}`);
	}
	const md = join(folder, "memory.md");
	writeFileSync(md, `${lines.join("\n")}\n`);
	return { files: [json, md], records: records.length };
}
