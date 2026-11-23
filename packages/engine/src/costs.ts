import { DatabaseSync } from "node:sqlite";
import { SQLITE_PRAGMAS } from "./requests.js";

/** Costs for paid requests outside the conversation harness. No prompts or credentials are stored. */
export class ExtraCosts {
	private db: DatabaseSync;
	constructor(file = ":memory:") {
		this.db = new DatabaseSync(file);
		this.db.exec(SQLITE_PRAGMAS);
		this.db.exec("CREATE TABLE IF NOT EXISTS extra_costs (at TEXT NOT NULL, scope TEXT NOT NULL, kind TEXT NOT NULL, model TEXT NOT NULL, usd REAL)");
		// Every budget check and Usage reads by scope (and month): without it, each read went through every row ever written.
		this.db.exec("CREATE INDEX IF NOT EXISTS extra_costs_scope_at ON extra_costs (scope, at)");
	}
	/** Each request as it's recorded, for the usage ledger (docs/spec/34 §8.1). */
	onRecord?: (row: { at: string; scope: string; kind: string; model: string; usd: number | null }) => void;
	record(kind: "web_search" | "utility" | "embeddings", model: string, usd: number | undefined, scope = "app"): void {
		const row = { at: new Date().toISOString(), scope, kind, model, usd: typeof usd === "number" && Number.isFinite(usd) && usd >= 0 ? usd : null };
		this.db.prepare("INSERT INTO extra_costs VALUES (?, ?, ?, ?, ?)").run(row.at, row.scope, row.kind, row.model, row.usd);
		this.onRecord?.(row);
	}
	/** Every row, oldest first (the ledger reads them once). */
	all(): { rowid: number; at: string; scope: string; kind: string; model: string; usd: number | null }[] {
		return this.db.prepare("SELECT rowid, at, scope, kind, model, usd FROM extra_costs ORDER BY rowid").all() as { rowid: number; at: string; scope: string; kind: string; model: string; usd: number | null }[];
	}
	summary(scope?: string) {
		const where = scope ? "WHERE scope = ?" : "";
		const rows = this.db.prepare(`SELECT kind, COUNT(*) calls, SUM(usd) usd, SUM(CASE WHEN usd IS NULL THEN 1 ELSE 0 END) unknown FROM extra_costs ${where} GROUP BY kind`).all(...(scope ? [scope] : [])) as { kind: string; calls: number; usd: number | null; unknown: number }[];
		return { scope: scope ?? "app", knownUsd: rows.reduce((sum, row) => sum + (row.usd ?? 0), 0), unknownCalls: rows.reduce((sum, row) => sum + row.unknown, 0), calls: rows.reduce((sum, row) => sum + row.calls, 0), breakdown: rows.map(row => ({ kind: row.kind, calls: row.calls, knownUsd: row.usd ?? 0, unknownCalls: row.unknown })) };
	}
	/** Known USD for `scope` in `month` ("YYYY-MM", UTC); unknown prices count as 0. */
	monthUsd(scope: string, month: string): number {
		// A range on `at` (ISO times sort as text), so the index answers it; substr() read every row of the scope.
		const [y, m] = month.split("-").map(Number) as [number, number];
		const next = m === 12 ? `${y + 1}-01` : `${y}-${String(m + 1).padStart(2, "0")}`;
		const row = this.db.prepare("SELECT SUM(usd) usd FROM extra_costs WHERE scope = ? AND at >= ? AND at < ?").get(scope, month, next) as { usd: number | null } | undefined;
		return row?.usd ?? 0;
	}
	close() { this.db.close(); }
}
