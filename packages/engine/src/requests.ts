import { createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { EngineError } from "./models.js";

/** Persist successful input receipts so a lost acknowledgment can be retried after reconnect/restart. */
export class InputReceipts {
	private db: DatabaseSync;
	private pending = new Map<string, { hash: string; result: Promise<unknown> }>();
	constructor(file: string) {
		this.db = new DatabaseSync(file);
		this.db.exec("CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, hash TEXT NOT NULL, result TEXT NOT NULL)");
	}
	async run(id: string, payload: unknown, execute: () => Promise<unknown>): Promise<unknown> {
		const hash = createHash("sha256").update(JSON.stringify(payload)).digest("hex");
		const receipt = this.db.prepare("SELECT hash, result FROM receipts WHERE id = ?").get(id) as { hash: string; result: string } | undefined;
		const pending = this.pending.get(id);
		if ((receipt && receipt.hash !== hash) || (pending && pending.hash !== hash)) throw new EngineError("CONFLICT", "This request id was already used for a different message.");
		if (receipt) return JSON.parse(receipt.result);
		if (pending) return pending.result;
		const result = Promise.resolve().then(execute).then(value => {
			this.db.prepare("INSERT INTO receipts VALUES (?, ?, ?)").run(id, hash, JSON.stringify(value));
			return value;
		}).finally(() => this.pending.delete(id));
		this.pending.set(id, { hash, result });
		return result;
	}
	close() { this.db.close(); }
}
