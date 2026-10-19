/**
 * Full-text search over what sessions show: titles, your messages and finished answers of the active
 * branch. SQLite FTS5 (Node's built-in SQLite) in `search.db`, kept current from session events.
 */
import { DatabaseSync, type StatementSync } from "node:sqlite";
import type { TimelineItem } from "@piopio/protocol";

/** Bump to rebuild every session's rows (e.g. when indexed text changes shape). */
export const INDEX_VERSION = 1;

/** Highlight markers in snippets (clients turn them into bold). */
export const MARK_START = "\u0002";
export const MARK_END = "\u0003";

export type SearchHit = { sessionId: string; itemId: string | null; kind: "title" | "user" | "assistant"; at: string; snippet: string };

export class SearchIndex {
	private readonly db: DatabaseSync;
	private readonly insertRow: StatementSync;
	private readonly deleteItemRow: StatementSync;

	constructor(file: string) {
		this.db = new DatabaseSync(file);
		this.db.exec(`
			PRAGMA journal_mode = WAL;
			CREATE VIRTUAL TABLE IF NOT EXISTS rows USING fts5(text, session_id UNINDEXED, item_id UNINDEXED, kind UNINDEXED, at UNINDEXED, tokenize = 'unicode61 remove_diacritics 2');
			CREATE TABLE IF NOT EXISTS indexed (session_id TEXT PRIMARY KEY, version INTEGER NOT NULL);
		`);
		this.insertRow = this.db.prepare("INSERT INTO rows (text, session_id, item_id, kind, at) VALUES (?, ?, ?, ?, ?)");
		this.deleteItemRow = this.db.prepare("DELETE FROM rows WHERE session_id = ? AND item_id = ?");
	}

	isIndexed(sessionId: string): boolean {
		const row = this.db.prepare("SELECT version FROM indexed WHERE session_id = ?").get(sessionId) as { version: number } | undefined;
		return row?.version === INDEX_VERSION;
	}

	/** Replaces everything indexed for a session (open, branch switch, backfill). */
	replaceSession(sessionId: string, title: string, at: string, items: readonly TimelineItem[]): void {
		this.transaction(() => {
			this.db.prepare("DELETE FROM rows WHERE session_id = ?").run(sessionId);
			this.insertRow.run(title, sessionId, null, "title", at);
			for (const item of items) this.insert(sessionId, item);
			this.db.prepare("INSERT INTO indexed (session_id, version) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET version = excluded.version").run(sessionId, INDEX_VERSION);
		});
	}

	upsertItem(sessionId: string, item: TimelineItem, replacing?: string): void {
		this.transaction(() => {
			this.deleteItemRow.run(sessionId, replacing ?? item.id);
			if (replacing) this.deleteItemRow.run(sessionId, item.id);
			this.insert(sessionId, item);
		});
	}

	removeItem(sessionId: string, itemId: string): void {
		this.deleteItemRow.run(sessionId, itemId);
	}

	setTitle(sessionId: string, title: string, at: string): void {
		this.transaction(() => {
			this.db.prepare("DELETE FROM rows WHERE session_id = ? AND kind = 'title'").run(sessionId);
			this.insertRow.run(title, sessionId, null, "title", at);
		});
	}

	deleteSession(sessionId: string): void {
		this.db.prepare("DELETE FROM rows WHERE session_id = ?").run(sessionId);
		this.db.prepare("DELETE FROM indexed WHERE session_id = ?").run(sessionId);
	}

	/** Every word must match (prefix match on each), best first. */
	search(query: string, limit = 30): SearchHit[] {
		const match = toMatch(query);
		if (!match) return [];
		const rows = this.db
			.prepare(`SELECT session_id, item_id, kind, at, snippet(rows, 0, '${MARK_START}', '${MARK_END}', '…', 16) AS snippet FROM rows WHERE rows MATCH ? ORDER BY bm25(rows) LIMIT ?`)
			.all(match, limit) as { session_id: string; item_id: string | null; kind: SearchHit["kind"]; at: string; snippet: string }[];
		return rows.map((r) => ({ sessionId: r.session_id, itemId: r.item_id, kind: r.kind, at: r.at, snippet: r.snippet.replace(/\s+/g, " ").trim() }));
	}

	close(): void {
		this.db.close();
	}

	private insert(sessionId: string, item: TimelineItem): void {
		const text = indexText(item);
		if (text) this.insertRow.run(text, sessionId, item.id, item.kind, item.at);
	}

	private transaction(body: () => void): void {
		this.db.exec("BEGIN");
		try {
			body();
			this.db.exec("COMMIT");
		} catch (error) {
			this.db.exec("ROLLBACK");
			throw error;
		}
	}
}

/** What a timeline item contributes to search (nothing while it streams). */
export function indexText(item: TimelineItem): string | undefined {
	if (item.kind === "user") return [item.text, ...(item.attachments ?? []).map((a) => a.name)].join("\n");
	if (item.kind === "assistant" && item.status !== "streaming") {
		const text = item.parts.filter((p) => p.type === "text").map((p) => p.text).join("");
		return text.trim() ? text : undefined;
	}
	return undefined;
}

export function toMatch(query: string): string | undefined {
	const words = query.split(/\s+/).map((w) => w.replace(/["*^():]/g, "")).filter((w) => w.length > 0);
	return words.length > 0 ? words.map((w) => `"${w}"*`).join(" ") : undefined;
}
