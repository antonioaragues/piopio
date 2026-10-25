/**
 * The built-in memory provider (07-shared §5.1): records in SQLite with their sources, full-text search (FTS5,
 * BM25) with a recency boost, pinning, and an event log for the history. No extraction: what is retained is stored
 * as it is (messages, or facts an agent or the user wrote). Runs on Node's SQLite locally and on a Durable Object's
 * SQLite in the cloud, through the small synchronous `Sql` adapter.
 *
 * With an embedder (docs/spec/14-memory, "Standard"), records also get a vector (int8, in `memory_vectors`) and
 * recall is hybrid: the keyword and vector rankings are fused with reciprocal rank fusion, then recency and pins.
 * A record whose embedding failed is stored anyway and embedded later by `reindex`.
 */
import { quantize, VectorIndex, type Embedder } from "./embeddings.js";
import { pack, type MemoryEvent, type MemoryHit, type MemoryKind, type MemoryProvider, type MemoryRecord, type RetainInput } from "./provider.js";

/** Synchronous SQL, as `node:sqlite` and Durable Object storage both offer. */
export interface Sql {
	exec(sql: string): void;
	run(sql: string, ...params: unknown[]): void;
	all<T = Record<string, unknown>>(sql: string, ...params: unknown[]): T[];
}

type Row = {
	id: string;
	bank: string;
	text: string;
	kind: MemoryKind;
	created_by: MemoryRecord["createdBy"];
	at: string;
	source: string | null;
	tags: string | null;
	pinned: number;
	replaces?: string | null;
	replaced_by?: string | null;
	ended_at?: string | null;
	rank?: number;
};

/** How much a record's age matters next to its text match (0: not at all). */
const RECENCY_WEIGHT = 0.5;
/** Reciprocal rank fusion's constant: rank 1 scores 1/61, rank 10 1/70 (the usual 60). */
const RRF_K = 60;
/** Below this cosine similarity a vector hit is noise, not a match (text-embedding-3-small puts unrelated text near 0.1–0.2). */
const MIN_SIMILARITY = 0.3;
/** How many vector hits join the fusion. */
const VECTOR_HITS = 50;
/** Current facts (distilled, M2) count a little more than the raw messages they came from. */
const FACT_WEIGHT = 1.3;

export class BuiltinMemory implements MemoryProvider {
	readonly id = "builtin";
	private seq = 0;
	/** One index per bank and model, rebuilt after the bank changes. */
	private readonly indexes = new Map<string, VectorIndex>();

	constructor(
		private readonly sql: Sql,
		private readonly newId: () => string,
		private readonly now: () => string = () => new Date().toISOString(),
		/** The embedding model, when semantic recall is on (undefined: keyword recall only). */
		private readonly embedder: () => Embedder | undefined = () => undefined,
	) {
		sql.exec(`
			CREATE TABLE IF NOT EXISTS memory_records (
				id TEXT PRIMARY KEY, bank TEXT NOT NULL, text TEXT NOT NULL, kind TEXT NOT NULL, created_by TEXT NOT NULL,
				at TEXT NOT NULL, source TEXT, tags TEXT, pinned INTEGER NOT NULL DEFAULT 0
			);
			CREATE INDEX IF NOT EXISTS memory_records_bank_at ON memory_records (bank, at);
			CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5 (text, content='memory_records', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2');
			CREATE TRIGGER IF NOT EXISTS memory_ai AFTER INSERT ON memory_records BEGIN INSERT INTO memory_fts (rowid, text) VALUES (new.rowid, new.text); END;
			CREATE TRIGGER IF NOT EXISTS memory_ad AFTER DELETE ON memory_records BEGIN INSERT INTO memory_fts (memory_fts, rowid, text) VALUES ('delete', old.rowid, old.text); END;
			CREATE TRIGGER IF NOT EXISTS memory_au AFTER UPDATE OF text ON memory_records BEGIN
				INSERT INTO memory_fts (memory_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
				INSERT INTO memory_fts (rowid, text) VALUES (new.rowid, new.text);
			END;
			CREATE TABLE IF NOT EXISTS memory_events (
				id TEXT PRIMARY KEY, at TEXT NOT NULL, bank TEXT NOT NULL, action TEXT NOT NULL, record_id TEXT NOT NULL,
				text TEXT NOT NULL, tags TEXT, by TEXT NOT NULL, batch TEXT
			);
			CREATE INDEX IF NOT EXISTS memory_events_bank_at ON memory_events (bank, at);
			CREATE TABLE IF NOT EXISTS memory_vectors (record_id TEXT PRIMARY KEY, bank TEXT NOT NULL, model TEXT NOT NULL, vector BLOB NOT NULL);
			CREATE INDEX IF NOT EXISTS memory_vectors_bank ON memory_vectors (bank, model);
			CREATE TRIGGER IF NOT EXISTS memory_vectors_ad AFTER DELETE ON memory_records BEGIN DELETE FROM memory_vectors WHERE record_id = old.id; END;
			CREATE TRIGGER IF NOT EXISTS memory_vectors_au AFTER UPDATE OF text ON memory_records BEGIN DELETE FROM memory_vectors WHERE record_id = old.id; END;
		`);
		// Learned facts (M2): what a fact replaced, what replaced it, and when it stopped being true. Added to older files.
		const columns = new Set(sql.all<{ name: string }>("PRAGMA table_info(memory_records)").map((c) => c.name));
		for (const c of ["replaces", "replaced_by", "ended_at"]) if (!columns.has(c)) sql.exec(`ALTER TABLE memory_records ADD COLUMN ${c} TEXT`);
	}

	get capabilities() {
		return { retain: true, list: true, forget: true, update: true, reflect: false, history: true, semantic: Boolean(this.embedder()), learns: true };
	}

	async retain(bank: string, input: RetainInput): Promise<MemoryRecord[]> {
		const text = input.content.trim();
		if (!text) return [];
		const record: MemoryRecord = {
			id: this.newId(),
			bank,
			text,
			kind: input.kind ?? "message",
			createdBy: input.createdBy ?? "agent",
			at: input.at ?? this.now(),
			...(input.source ? { source: input.source } : {}),
			...(input.tags?.length ? { tags: input.tags } : {}),
			...(input.pinned ? { pinned: true } : {}),
			...(input.replaces ? { replaces: input.replaces } : {}),
		};
		this.sql.run(
			"INSERT INTO memory_records (id, bank, text, kind, created_by, at, source, tags, pinned, replaces) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
			record.id, bank, text, record.kind, record.createdBy, record.at, input.source ? JSON.stringify(input.source) : null, input.tags?.length ? JSON.stringify(input.tags) : null, input.pinned ? 1 : 0, input.replaces ?? null,
		);
		this.event(bank, "added", record.id, text, record.createdBy, input.tags);
		if (input.replaces) {
			const old = this.get(bank, input.replaces);
			this.sql.run("UPDATE memory_records SET replaced_by = ?, ended_at = ? WHERE id = ?", record.id, record.at, old.id);
			this.event(bank, "replaced", old.id, old.text, record.createdBy);
		}
		this.invalidate(bank);
		await this.embedRecords([{ id: record.id, bank, text }]).catch(() => undefined);
		return [record];
	}

	async recall(banks: readonly string[], query: string, options: { budgetTokens?: number; kinds?: MemoryKind[]; limit?: number } = {}): Promise<MemoryHit[]> {
		if (!banks.length || !query.trim()) return [];
		const keyword = this.keywordRows(banks, query, options.kinds);
		const semantic = await this.semanticRanking(banks, query).catch(() => []);
		if (!keyword.length && !semantic.length) return [];
		// Reciprocal rank fusion of the two rankings; a record found by both adds up.
		const fused = new Map<string, number>();
		keyword.forEach((r, i) => fused.set(r.id, (fused.get(r.id) ?? 0) + 1 / (RRF_K + i + 1)));
		semantic.forEach((h, i) => fused.set(h.id, (fused.get(h.id) ?? 0) + 1 / (RRF_K + i + 1)));
		const rows = new Map(keyword.map((r) => [r.id, r]));
		const missing = semantic.map((h) => h.id).filter((id) => !rows.has(id));
		for (const r of this.rowsById(missing, options.kinds)) rows.set(r.id, r);
		const found = [...rows.values()];
		const best = Math.max(...found.map((r) => fused.get(r.id) ?? 0));
		const times = found.map((r) => Date.parse(r.at));
		const newest = Math.max(...times), oldest = Math.min(...times);
		const hits = found.map((r, i) => {
			const match = ((fused.get(r.id) ?? 0) / best) * (r.kind === "fact" ? FACT_WEIGHT : 1);
			const recency = newest === oldest ? 1 : (times[i]! - oldest) / (newest - oldest);
			return { ...toRecord(r), score: match * (1 + RECENCY_WEIGHT * recency) + (r.pinned ? 0.5 : 0) };
		});
		hits.sort((a, b) => b.score - a.score);
		return pack(hits.slice(0, options.limit ?? 40), options.budgetTokens ?? 1500);
	}

	/** FTS5 matches, best first. Prefix terms, so "live" finds "lives" (FTS5 has no stemming). */
	private keywordRows(banks: readonly string[], query: string, kinds?: MemoryKind[]): Row[] {
		const terms = (query.normalize("NFKD").match(/[\p{L}\p{N}]{2,}/gu) ?? []).map((t) => `"${t.replaceAll('"', "")}"${t.length >= 3 ? "*" : ""}`);
		if (!terms.length) return [];
		const kindFilter = kinds?.length ? ` AND r.kind IN (${kinds.map(() => "?").join(", ")})` : "";
		return this.sql.all<Row>(
			`SELECT r.*, bm25(memory_fts) AS rank FROM memory_fts JOIN memory_records r ON r.rowid = memory_fts.rowid
			 WHERE memory_fts MATCH ? AND r.bank IN (${banks.map(() => "?").join(", ")}) AND r.ended_at IS NULL${kindFilter} ORDER BY rank LIMIT 200`,
			terms.join(" OR "), ...banks, ...(kinds ?? []),
		);
	}

	/** The records closest in meaning to `query`, best first, above the noise floor. Empty without an embedder. */
	private async semanticRanking(banks: readonly string[], query: string): Promise<{ id: string; similarity: number }[]> {
		const embedder = this.embedder();
		if (!embedder) return [];
		const [vector] = await embedder.embed([query]);
		if (!vector) return [];
		const q = quantize(vector);
		const hits = banks.flatMap((bank) => this.index(bank, embedder).search(q, VECTOR_HITS));
		return hits.filter((h) => h.similarity >= MIN_SIMILARITY).sort((a, b) => b.similarity - a.similarity).slice(0, VECTOR_HITS);
	}

	private index(bank: string, embedder: Embedder): VectorIndex {
		const key = `${embedder.model}\u0000${bank}`;
		let index = this.indexes.get(key);
		if (!index) {
			const rows = this.sql.all<{ record_id: string; vector: Uint8Array }>("SELECT record_id, vector FROM memory_vectors WHERE bank = ? AND model = ?", bank, embedder.model);
			index = new VectorIndex(embedder.dims, rows.map((r) => ({ id: r.record_id, vector: r.vector })));
			this.indexes.set(key, index);
		}
		return index;
	}

	private rowsById(ids: readonly string[], kinds?: MemoryKind[]): Row[] {
		if (!ids.length) return [];
		const kindFilter = kinds?.length ? ` AND kind IN (${kinds.map(() => "?").join(", ")})` : "";
		return this.sql.all<Row>(`SELECT * FROM memory_records WHERE id IN (${ids.map(() => "?").join(", ")}) AND ended_at IS NULL${kindFilter}`, ...ids, ...(kinds ?? []));
	}

	/** Embeds and stores vectors for these records (one request). */
	private async embedRecords(records: readonly { id: string; bank: string; text: string }[]): Promise<number> {
		const embedder = this.embedder();
		if (!embedder || !records.length) return 0;
		const vectors = await embedder.embed(records.map((r) => r.text));
		records.forEach((r, i) => {
			const q = quantize(vectors[i]!);
			this.sql.run("INSERT OR REPLACE INTO memory_vectors (record_id, bank, model, vector) VALUES (?, ?, ?, ?)", r.id, r.bank, embedder.model, new Uint8Array(q.buffer, q.byteOffset, q.byteLength));
		});
		for (const bank of new Set(records.map((r) => r.bank))) this.invalidate(bank);
		return records.length;
	}

	/** Records with no vector from the current model: new ones whose embedding failed, or all after a model change. */
	missingVectors(bank?: string): number {
		const embedder = this.embedder();
		if (!embedder) return 0;
		const where = bank ? " AND r.bank = ?" : "";
		const row = this.sql.all<{ n: number }>(
			`SELECT COUNT(*) AS n FROM memory_records r LEFT JOIN memory_vectors v ON v.record_id = r.id AND v.model = ? WHERE v.record_id IS NULL${where}`,
			embedder.model, ...(bank ? [bank] : []),
		)[0];
		return Number(row?.n ?? 0);
	}

	/** Embeds the records that have no vector from the current model, `batch` at a time. Returns how many it embedded. */
	async reindex(options: { bank?: string; batch?: number; max?: number } = {}): Promise<number> {
		const embedder = this.embedder();
		if (!embedder) return 0;
		const batch = options.batch ?? 64;
		let done = 0;
		for (;;) {
			const where = options.bank ? " AND r.bank = ?" : "";
			const rows = this.sql.all<{ id: string; bank: string; text: string }>(
				`SELECT r.id, r.bank, r.text FROM memory_records r LEFT JOIN memory_vectors v ON v.record_id = r.id AND v.model = ? WHERE v.record_id IS NULL${where} ORDER BY r.rowid LIMIT ?`,
				embedder.model, ...(options.bank ? [options.bank] : []), batch,
			);
			if (!rows.length) return done;
			done += await this.embedRecords(rows);
			if (options.max && done >= options.max) return done;
		}
	}

	/** Vector counts for the status line: records, and how many have a vector from the current model. */
	vectorStatus(): { records: number; indexed: number; model?: string } {
		const records = Number(this.sql.all<{ n: number }>("SELECT COUNT(*) AS n FROM memory_records")[0]?.n ?? 0);
		const model = this.embedder()?.model;
		if (!model) return { records, indexed: 0 };
		const indexed = Number(this.sql.all<{ n: number }>("SELECT COUNT(*) AS n FROM memory_vectors WHERE model = ?", model)[0]?.n ?? 0);
		return { records, indexed, model };
	}

	private invalidate(bank: string): void {
		for (const key of this.indexes.keys()) if (key.endsWith(`\u0000${bank}`) || key === bank) this.indexes.delete(key);
	}

	async list(bank: string, options: { cursor?: string; limit?: number; kinds?: MemoryKind[]; tag?: string; includeEnded?: boolean } = {}): Promise<{ records: MemoryRecord[]; cursor?: string }> {
		const limit = options.limit ?? 100;
		const offset = Number(options.cursor ?? 0);
		const kinds = options.kinds?.length ? ` AND kind IN (${options.kinds.map(() => "?").join(", ")})` : "";
		const tag = options.tag ? " AND EXISTS (SELECT 1 FROM json_each(tags) WHERE value = ?)" : "";
		const ended = options.includeEnded ? "" : " AND ended_at IS NULL";
		const rows = this.sql.all<Row>(
			`SELECT * FROM memory_records WHERE bank = ?${kinds}${tag}${ended} ORDER BY at DESC, rowid DESC LIMIT ? OFFSET ?`,
			bank, ...(options.kinds ?? []), ...(options.tag ? [options.tag] : []), limit + 1, offset,
		);
		return { records: rows.slice(0, limit).map(toRecord), ...(rows.length > limit ? { cursor: String(offset + limit) } : {}) };
	}

	async forget(bank: string, id: string, by: MemoryRecord["createdBy"] = "user"): Promise<void> {
		const row = this.get(bank, id);
		this.sql.run("DELETE FROM memory_records WHERE id = ? AND bank = ?", id, bank);
		this.invalidate(bank);
		this.event(bank, "removed", id, row.text, by, row.tags ? (JSON.parse(row.tags) as string[]) : undefined);
	}

	async end(bank: string, id: string, at: string, by: MemoryRecord["createdBy"] = "extraction"): Promise<void> {
		const row = this.get(bank, id);
		this.sql.run("UPDATE memory_records SET ended_at = ? WHERE id = ?", at, id);
		this.invalidate(bank);
		this.event(bank, "ended", id, row.text, by);
	}

	async restore(bank: string, id: string, by: MemoryRecord["createdBy"] = "user"): Promise<void> {
		const row = this.get(bank, id);
		this.sql.run("UPDATE memory_records SET ended_at = NULL, replaced_by = NULL WHERE id = ?", id);
		this.invalidate(bank);
		this.event(bank, "restored", id, row.text, by);
	}

	/** One record, current or not. */
	async record(bank: string, id: string): Promise<MemoryRecord | undefined> {
		const row = this.sql.all<Row>("SELECT * FROM memory_records WHERE id = ? AND bank = ?", id, bank)[0];
		return row ? toRecord(row) : undefined;
	}

	async update(bank: string, id: string, change: { text?: string; pinned?: boolean; tags?: string[] }, by: MemoryRecord["createdBy"] = "user"): Promise<MemoryRecord> {
		const row = this.get(bank, id);
		if (change.text !== undefined && change.text.trim() && change.text.trim() !== row.text) {
			this.sql.run("UPDATE memory_records SET text = ? WHERE id = ?", change.text.trim(), id);
			this.invalidate(bank);
			this.event(bank, "updated", id, change.text.trim(), by);
			await this.embedRecords([{ id, bank, text: change.text.trim() }]).catch(() => undefined);
		}
		if (change.pinned !== undefined) this.sql.run("UPDATE memory_records SET pinned = ? WHERE id = ?", change.pinned ? 1 : 0, id);
		if (change.tags !== undefined) this.sql.run("UPDATE memory_records SET tags = ? WHERE id = ?", change.tags.length ? JSON.stringify(change.tags) : null, id);
		return toRecord(this.get(bank, id));
	}

	async history(bank: string, options: { limit?: number } = {}): Promise<MemoryEvent[]> {
		return this.sql
			.all<{ id: string; at: string; bank: string; action: MemoryEvent["action"]; record_id: string; text: string; tags: string | null; by: MemoryRecord["createdBy"]; batch: string | null }>(
				"SELECT * FROM memory_events WHERE bank = ? ORDER BY at DESC, rowid DESC LIMIT ?",
				bank, options.limit ?? 200,
			)
			.map((e) => ({ id: e.id, at: e.at, bank: e.bank, action: e.action, recordId: e.record_id, text: e.text, ...(e.tags ? { tags: JSON.parse(e.tags) as string[] } : {}), by: e.by, ...(e.batch ? { batch: e.batch } : {}) }));
	}

	async standing(bank: string): Promise<MemoryRecord[]> {
		return this.sql.all<Row>("SELECT * FROM memory_records WHERE bank = ? AND pinned = 1 AND ended_at IS NULL ORDER BY at", bank).map(toRecord);
	}

	/** Every bank with what it holds (Settings › Memory). */
	banks(): { bank: string; records: number; facts: number; messages: number; ended: number; updatedAt: string }[] {
		return this.sql
			.all<{ bank: string; records: number; facts: number; messages: number; ended: number; updated: string }>(
				`SELECT bank, COUNT(*) AS records, SUM(kind = 'fact' AND ended_at IS NULL) AS facts, SUM(kind = 'message') AS messages,
				 SUM(ended_at IS NOT NULL) AS ended, MAX(at) AS updated FROM memory_records GROUP BY bank ORDER BY bank`,
			)
			.map((r) => ({ bank: r.bank, records: Number(r.records), facts: Number(r.facts ?? 0), messages: Number(r.messages ?? 0), ended: Number(r.ended ?? 0), updatedAt: r.updated }));
	}

	/** Every record of a bank (or of all of them), current or not, oldest first: the export. */
	dump(bank?: string): MemoryRecord[] {
		return this.sql.all<Row>(`SELECT * FROM memory_records${bank ? " WHERE bank = ?" : ""} ORDER BY bank, at, rowid`, ...(bank ? [bank] : [])).map(toRecord);
	}

	/** Deletes one bank (or every bank) with its history and vectors. */
	wipe(bank?: string): number {
		const where = bank ? " WHERE bank = ?" : "";
		const params = bank ? [bank] : [];
		const n = Number(this.sql.all<{ n: number }>(`SELECT COUNT(*) AS n FROM memory_records${where}`, ...params)[0]?.n ?? 0);
		this.sql.run(`DELETE FROM memory_records${where}`, ...params);
		this.sql.run(`DELETE FROM memory_events${where}`, ...params);
		this.sql.run(`DELETE FROM memory_vectors${where}`, ...params);
		this.indexes.clear();
		return n;
	}

	/** Deletes every bank whose name starts with `prefix` (an agent being deleted), with their history. */
	dropBanks(prefix: string): void {
		const like = `${prefix.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
		this.sql.run("DELETE FROM memory_records WHERE bank LIKE ? ESCAPE '\\'", like);
		this.sql.run("DELETE FROM memory_events WHERE bank LIKE ? ESCAPE '\\'", like);
		this.sql.run("DELETE FROM memory_vectors WHERE bank LIKE ? ESCAPE '\\'", like);
		this.indexes.clear();
	}

	/** Groups the events written until `end()` (one change in the editor, one tool call) into one batch. Nested batches join the outer one. */
	batch(): { end(): void } {
		if (this.currentBatch) return { end: () => {} };
		this.currentBatch = this.newId();
		return { end: () => (this.currentBatch = undefined) };
	}
	private currentBatch?: string;

	private get(bank: string, id: string): Row {
		const row = this.sql.all<Row>("SELECT * FROM memory_records WHERE id = ? AND bank = ?", id, bank)[0];
		if (!row) throw new Error(`No memory ${id} in ${bank}`);
		return row;
	}

	private event(bank: string, action: MemoryEvent["action"], recordId: string, text: string, by: MemoryRecord["createdBy"], tags?: string[]): void {
		// Events in the same millisecond keep their order through the rowid; `seq` keeps ids unique.
		this.sql.run(
			"INSERT INTO memory_events (id, at, bank, action, record_id, text, tags, by, batch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
			`${this.newId()}-${++this.seq}`, this.now(), bank, action, recordId, text, tags?.length ? JSON.stringify(tags) : null, by, this.currentBatch ?? null,
		);
	}
}

function toRecord(r: Row): MemoryRecord {
	return {
		id: r.id,
		bank: r.bank,
		text: r.text,
		kind: r.kind,
		createdBy: r.created_by,
		at: r.at,
		...(r.source ? { source: JSON.parse(r.source) as MemoryRecord["source"] } : {}),
		...(r.tags ? { tags: JSON.parse(r.tags) as string[] } : {}),
		...(r.pinned ? { pinned: true } : {}),
		...(r.replaces ? { replaces: r.replaces } : {}),
		...(r.replaced_by ? { replacedBy: r.replaced_by } : {}),
		...(r.ended_at ? { endedAt: r.ended_at } : {}),
	};
}
