import { DatabaseSync } from "node:sqlite";
import { describe, expect, test } from "vitest";
import { BuiltinMemory, type Sql } from "../src/index.js";

function memory() {
	const db = new DatabaseSync(":memory:");
	const sql: Sql = { exec: (s) => db.exec(s), run: (s, ...p) => void db.prepare(s).run(...(p as never[])), all: (s, ...p) => db.prepare(s).all(...(p as never[])) as never };
	let n = 0;
	let clock = Date.parse("2026-03-01T00:00:00Z");
	return new BuiltinMemory(sql, () => `m${++n}`, () => new Date((clock += 60_000)).toISOString());
}

describe("built-in memory", () => {
	test("recall ranks by match and recency, within banks, and packs a budget", async () => {
		const m = memory();
		await m.retain("alex", { content: "I live in Valencia, near the Turia park.", at: "2026-03-02T10:00:00Z" });
		await m.retain("alex", { content: "We're moving to Madrid in April, to Chamberí.", at: "2026-03-31T10:00:00Z" });
		await m.retain("alex", { content: "New address: Fernández de los Ríos 12, Madrid. We live here now.", at: "2026-04-17T10:00:00Z" });
		await m.retain("marta", { content: "Marta lives in Alicante.", at: "2026-03-05T10:00:00Z" });
		const hits = await m.recall(["alex"], "Where does Alex live now?");
		expect(hits[0]!.text).toContain("Fernández de los Ríos");
		expect(hits.every((h) => h.bank === "alex")).toBe(true);
		expect((await m.recall(["alex", "marta"], "Alicante")).map((h) => h.bank)).toEqual(["marta"]);
		expect(await m.recall(["alex"], "Atlas")).toEqual([]);
		expect((await m.recall(["alex"], "live Madrid Valencia", { budgetTokens: 10 })).length).toBe(1);
		// Accents don't matter.
		expect((await m.recall(["alex"], "chamberi"))[0]!.text).toContain("Chamberí");
	});

	test("list, pin, update, forget, and the history with batches", async () => {
		const m = memory();
		const batch = m.batch();
		const [a] = await m.retain("me", { content: "Prefers matte finishes", kind: "fact", createdBy: "user", tags: ["Preferences"] });
		const [b] = await m.retain("me", { content: "Lives in Valencia", kind: "fact", createdBy: "user", tags: ["Home"], source: { ref: "thr_1", itemId: "7" } });
		batch.end();
		expect((await m.list("me")).records.map((r) => r.text)).toEqual(["Lives in Valencia", "Prefers matte finishes"]);
		expect((await m.list("me", { tag: "Home" })).records.map((r) => r.source)).toEqual([{ ref: "thr_1", itemId: "7" }]);
		await m.update("me", b!.id, { text: "Lives in Madrid", pinned: true });
		expect((await m.standing("me")).map((r) => r.text)).toEqual(["Lives in Madrid"]);
		expect((await m.recall(["me"], "madrid"))[0]!.text).toBe("Lives in Madrid");
		expect(await m.recall(["me"], "valencia")).toEqual([]);
		await m.forget("me", a!.id);
		const history = await m.history("me");
		expect(history.map((e) => [e.action, e.text])).toEqual([
			["removed", "Prefers matte finishes"],
			["updated", "Lives in Madrid"],
			["added", "Lives in Valencia"],
			["added", "Prefers matte finishes"],
		]);
		expect(history[2]!.batch).toBeDefined();
		expect(history[2]!.batch).toBe(history[3]!.batch);
		await m.retain("me", { content: "Has a dog called Kiwi", kind: "fact" });
		const first = await m.list("me", { limit: 1 });
		expect(first.cursor).toBe("1");
		expect((await m.list("me", { limit: 1, cursor: first.cursor })).records.map((r) => r.text)).toEqual(["Lives in Madrid"]);
	});
});
