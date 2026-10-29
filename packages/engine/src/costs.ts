import { DatabaseSync } from "node:sqlite";

/** Costs for paid requests outside the conversation harness. No prompts or credentials are stored. */
export class ExtraCosts {
	private db: DatabaseSync;
	constructor(file = ":memory:") {
		this.db = new DatabaseSync(file);
		this.db.exec("CREATE TABLE IF NOT EXISTS extra_costs (at TEXT NOT NULL, scope TEXT NOT NULL, kind TEXT NOT NULL, model TEXT NOT NULL, usd REAL)");
	}
	record(kind: "web_search" | "utility", model: string, usd: number | undefined, scope = "app"): void {
		this.db.prepare("INSERT INTO extra_costs VALUES (?, ?, ?, ?, ?)").run(new Date().toISOString(), scope, kind, model, typeof usd === "number" && Number.isFinite(usd) && usd >= 0 ? usd : null);
	}
	summary(scope?: string) {
		const where = scope ? "WHERE scope = ?" : "";
		const rows = this.db.prepare(`SELECT kind, COUNT(*) calls, SUM(usd) usd, SUM(CASE WHEN usd IS NULL THEN 1 ELSE 0 END) unknown FROM extra_costs ${where} GROUP BY kind`).all(...(scope ? [scope] : [])) as { kind: string; calls: number; usd: number | null; unknown: number }[];
		return { scope: scope ?? "app", knownUsd: rows.reduce((sum, row) => sum + (row.usd ?? 0), 0), unknownCalls: rows.reduce((sum, row) => sum + row.unknown, 0), calls: rows.reduce((sum, row) => sum + row.calls, 0), breakdown: rows.map(row => ({ kind: row.kind, calls: row.calls, knownUsd: row.usd ?? 0, unknownCalls: row.unknown })) };
	}
	close() { this.db.close(); }
}
