/**
 * The built-in memory provider (07-shared §5.1): records in SQLite with their sources, full-text search (FTS5,
 * BM25) with a recency boost, pinning, and an event log for the history. No extraction: what is retained is stored
 * as it is (messages, or facts an agent or the user wrote). Runs on Node's SQLite locally and on a Durable Object's
 * SQLite in the cloud, through the small synchronous `Sql` adapter.
 */
import { pack, type MemoryEvent, type MemoryHit, type MemoryKind, type MemoryProvider, type MemoryRecord, type RetainInput } from "./provider.js";

/** Synchronous SQL, as `node:sqlite` and Durable Object storage both offer. */
export interface Sql {
	exec(sql: string): void;
	run(sql: string, ...params: unknown[]): void;
	all<T = Record<string, unknown>>(sql: string, ...params: unknown[]): T[];
}

type Row = { id: string; bank: string; text: string; kind: MemoryKind; created_by: MemoryRecord["createdBy"]; at: string; source: string | null; tags: string | null; pinned: number; rank?: number };

/** How much a record's age matters next to its text match (0: not at all). */
const RECENCY_WEIGHT = 0.5;

export class BuiltinMemory implements MemoryProvider {
	readonly id = "builtin";
	readonly capabilities = { retain: true, list: true, forget: true, update: true, reflect: false, history: true };
	private seq = 0;

	constructor(
		private readonly sql: Sql,
		private readonly newId: () => string,
		private readonly now: () => string = () => new Date().toISOString(),
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
		`);
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
		};
		this.sql.run(
			"INSERT INTO memory_records (id, bank, text, kind, created_by, at, source, tags, pinned) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
			record.id, bank, text, record.kind, record.createdBy, record.at, input.source ? JSON.stringify(input.source) : null, input.tags?.length ? JSON.stringify(input.tags) : null, input.pinned ? 1 : 0,
		);
		this.event(bank, "added", record.id, text, record.createdBy, input.tags);
		return [record];
	}

	async recall(banks: readonly string[], query: string, options: { budgetTokens?: number; kinds?: MemoryKind[]; limit?: number } = {}): Promise<MemoryHit[]> {
		// Prefix terms, so "live" finds "lives" (FTS5 has no stemming).
		const terms = (query.normalize("NFKD").match(/[\p{L}\p{N}]{2,}/gu) ?? []).map((t) => `"${t.replaceAll('"', "")}"${t.length >= 3 ? "*" : ""}`);
		if (!terms.length || !banks.length) return [];
		const kinds = options.kinds?.length ? ` AND r.kind IN (${options.kinds.map(() => "?").join(", ")})` : "";
		const rows = this.sql.all<Row>(
			`SELECT r.*, bm25(memory_fts) AS rank FROM memory_fts JOIN memory_records r ON r.rowid = memory_fts.rowid
			 WHERE memory_fts MATCH ? AND r.bank IN (${banks.map(() => "?").join(", ")})${kinds} ORDER BY rank LIMIT 200`,
			terms.join(" OR "), ...banks, ...(options.kinds ?? []),
		);
		if (!rows.length) return [];
		// bm25() is lower for better matches: turn it into a 0–1 match score, then add recency.
		const ranks = rows.map((r) => -(r.rank ?? 0));
		const best = Math.max(...ranks), worst = Math.min(...ranks);
		const times = rows.map((r) => Date.parse(r.at));
		const newest = Math.max(...times), oldest = Math.min(...times);
		const hits = rows.map((r, i) => {
			const match = best === worst ? 1 : (ranks[i]! - worst) / (best - worst);
			const recency = newest === oldest ? 1 : (times[i]! - oldest) / (newest - oldest);
			return { ...toRecord(r), score: match * (1 + RECENCY_WEIGHT * recency) + (r.pinned ? 0.5 : 0) };
		});
		hits.sort((a, b) => b.score - a.score);
		return pack(hits.slice(0, options.limit ?? 40), options.budgetTokens ?? 1500);
	}

	async list(bank: string, options: { cursor?: string; limit?: number; kinds?: MemoryKind[]; tag?: string } = {}): Promise<{ records: MemoryRecord[]; cursor?: string }> {
		const limit = options.limit ?? 100;
		const offset = Number(options.cursor ?? 0);
		const kinds = options.kinds?.length ? ` AND kind IN (${options.kinds.map(() => "?").join(", ")})` : "";
		const tag = options.tag ? " AND EXISTS (SELECT 1 FROM json_each(tags) WHERE value = ?)" : "";
		const rows = this.sql.all<Row>(
			`SELECT * FROM memory_records WHERE bank = ?${kinds}${tag} ORDER BY at DESC, rowid DESC LIMIT ? OFFSET ?`,
			bank, ...(options.kinds ?? []), ...(options.tag ? [options.tag] : []), limit + 1, offset,
		);
		return { records: rows.slice(0, limit).map(toRecord), ...(rows.length > limit ? { cursor: String(offset + limit) } : {}) };
	}

	async forget(bank: string, id: string, by: MemoryRecord["createdBy"] = "user"): Promise<void> {
		const row = this.get(bank, id);
		this.sql.run("DELETE FROM memory_records WHERE id = ? AND bank = ?", id, bank);
		this.event(bank, "removed", id, row.text, by, row.tags ? (JSON.parse(row.tags) as string[]) : undefined);
	}

	async update(bank: string, id: string, change: { text?: string; pinned?: boolean; tags?: string[] }, by: MemoryRecord["createdBy"] = "user"): Promise<MemoryRecord> {
		const row = this.get(bank, id);
		if (change.text !== undefined && change.text.trim() && change.text.trim() !== row.text) {
			this.sql.run("UPDATE memory_records SET text = ? WHERE id = ?", change.text.trim(), id);
			this.event(bank, "updated", id, change.text.trim(), by);
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
		return this.sql.all<Row>("SELECT * FROM memory_records WHERE bank = ? AND pinned = 1 ORDER BY at", bank).map(toRecord);
	}

	/** Deletes every bank whose name starts with `prefix` (an agent being deleted), with their history. */
	dropBanks(prefix: string): void {
		const like = `${prefix.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
		this.sql.run("DELETE FROM memory_records WHERE bank LIKE ? ESCAPE '\\'", like);
		this.sql.run("DELETE FROM memory_events WHERE bank LIKE ? ESCAPE '\\'", like);
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
	};
}
