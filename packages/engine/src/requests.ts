import { createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { EngineError } from "./models.js";

/**
 * WAL, so a read never waits on a write, and a busy timeout, so a write that meets another one waits for it instead of
 * failing with SQLITE_BUSY. (search.db already had WAL.)
 */
export const SQLITE_PRAGMAS = "PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;";

/** A receipt is for retrying a lost acknowledgment, minutes later at most: a week is plenty, and then it goes. */
const KEEP_MS = 7 * 24 * 3600_000;

/** Persist successful input receipts so a lost acknowledgment can be retried after reconnect/restart. */
export class InputReceipts {
	private db: DatabaseSync;
	private pending = new Map<string, { hash: string; result: Promise<unknown> }>();
	constructor(file: string) {
		this.db = new DatabaseSync(file);
		this.db.exec(SQLITE_PRAGMAS);
		this.db.exec("CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, hash TEXT NOT NULL, result TEXT NOT NULL)");
		// When each was written, so old ones can go (receipts from before this have none: they're dated now, and go in a week).
		const columns = new Set((this.db.prepare("PRAGMA table_info(receipts)").all() as { name: string }[]).map((c) => c.name));
		if (!columns.has("at")) this.db.exec(`ALTER TABLE receipts ADD COLUMN at INTEGER NOT NULL DEFAULT ${Date.now()}`);
		this.prune();
	}

	/** Drops receipts older than a week; returns how many went. */
	prune(now = Date.now()): number {
		return Number(this.db.prepare("DELETE FROM receipts WHERE at < ?").run(now - KEEP_MS).changes);
	}
	async run(id: string, payload: unknown, execute: () => Promise<unknown>): Promise<unknown> {
		const hash = createHash("sha256").update(JSON.stringify(payload)).digest("hex");
		const receipt = this.db.prepare("SELECT hash, result FROM receipts WHERE id = ?").get(id) as { hash: string; result: string } | undefined;
		const pending = this.pending.get(id);
		if ((receipt && receipt.hash !== hash) || (pending && pending.hash !== hash)) throw new EngineError("CONFLICT", "This request id was already used for a different message.");
		if (receipt) return JSON.parse(receipt.result);
		if (pending) return pending.result;
		const result = Promise.resolve().then(execute).then(value => {
			this.db.prepare("INSERT INTO receipts (id, hash, result, at) VALUES (?, ?, ?, ?)").run(id, hash, JSON.stringify(value), Date.now());
			return value;
		}).finally(() => this.pending.delete(id));
		this.pending.set(id, { hash, result });
		return result;
	}
	close() { this.db.close(); }
}
