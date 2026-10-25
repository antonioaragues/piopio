import { DatabaseSync } from "node:sqlite";
import { describe, expect, test } from "vitest";
import { BuiltinMemory, openAiEmbedder, quantize, VectorIndex, type Embedder, type Sql } from "../src/index.js";

/**
 * A toy embedding model: each word maps to a concept, and a text's vector counts its concepts. Enough to tell
 * "moving to Madrid" apart from "the Turia park" by meaning when they share no words with the question.
 */
const CONCEPTS: Record<string, number> = {
	live: 0, lives: 0, living: 0, moving: 0, moved: 0, home: 0, address: 0, city: 0, where: 0,
	madrid: 1, valencia: 1, bilbao: 1,
	dog: 2, cat: 2, pet: 2, puppy: 2,
	bike: 3, cycling: 3, ride: 3, rides: 3,
	park: 4, garden: 4,
};

function toyEmbedder(calls: { n: number } = { n: 0 }, fail = false): Embedder {
	return {
		model: "toy@8",
		dims: 8,
		async embed(texts) {
			if (fail) throw new Error("offline");
			calls.n++;
			return texts.map((t) => {
				const v = new Float32Array(8);
				for (const w of t.toLowerCase().match(/\p{L}+/gu) ?? []) {
					const c = CONCEPTS[w];
					if (c !== undefined) v[c]! += 1;
				}
				v[7] = 0.05; // nothing is exactly zero
				return v;
			});
		},
	};
}

function memory(embedder: () => Embedder | undefined) {
	const db = new DatabaseSync(":memory:");
	const sql: Sql = { exec: (s) => db.exec(s), run: (s, ...p) => void db.prepare(s).run(...(p as never[])), all: (s, ...p) => db.prepare(s).all(...(p as never[])) as never };
	let n = 0;
	let clock = Date.parse("2026-03-01T00:00:00Z");
	return { m: new BuiltinMemory(sql, () => `m${++n}`, () => new Date((clock += 60_000)).toISOString(), embedder), db };
}

describe("semantic recall (docs/spec/14-memory, M1)", () => {
	test("finds by meaning what shares no words with the question, and fuses with keyword matches", async () => {
		const { m } = memory(() => toyEmbedder());
		await m.retain("alex", { content: "Alex works at a bakery downtown.", at: "2026-03-02T10:00:00Z" });
		await m.retain("alex", { content: "We're moving to Madrid in April.", at: "2026-03-31T10:00:00Z" });
		await m.retain("alex", { content: "Got a puppy called Toffee.", at: "2026-04-02T10:00:00Z" });
		expect(m.capabilities.semantic).toBe(true);
		// No word of "Which city?" is in the Madrid message: only the vector finds it.
		const city = await m.recall(["alex"], "Which city?");
		expect(city[0]!.text).toContain("Madrid");
		expect(city.map((h) => h.text)).not.toContain("Alex works at a bakery downtown.");
		// "dog" → the puppy, by concept.
		expect((await m.recall(["alex"], "Does Alex have a dog?"))[0]!.text).toContain("puppy");
		// Keyword matches still count: "bakery" has no concept but is a word in the record.
		expect((await m.recall(["alex"], "bakery"))[0]!.text).toContain("bakery");
	});

	test("without an embedder it's keyword recall as before; a failed embedding is stored and filled in by reindex", async () => {
		let online = false;
		const calls = { n: 0 };
		const { m } = memory(() => (online ? toyEmbedder(calls) : toyEmbedder(calls, true)));
		await m.retain("me", { content: "I ride my bike to work." });
		await m.retain("me", { content: "We have a small garden." });
		expect(await m.recall(["me"], "cycling")).toEqual([]); // the embedder is down: no vectors, no keyword match
		expect(m.missingVectors()).toBe(2);
		online = true;
		expect(await m.reindex({ batch: 1 })).toBe(2);
		expect(m.missingVectors()).toBe(0);
		expect(m.vectorStatus()).toEqual({ records: 2, indexed: 2, model: "toy@8" });
		expect((await m.recall(["me"], "cycling"))[0]!.text).toContain("bike");
		// Edits re-embed; forgetting removes the vector.
		const [garden] = (await m.list("me")).records.filter((r) => r.text.includes("garden"));
		await m.update("me", garden!.id, { text: "We have a cat." });
		expect((await m.recall(["me"], "pet"))[0]!.text).toBe("We have a cat.");
		await m.forget("me", garden!.id);
		expect(m.vectorStatus().indexed).toBe(1);
		const none = memory(() => undefined).m;
		await none.retain("me", { content: "I ride my bike." });
		expect(none.capabilities.semantic).toBe(false);
		expect((await none.recall(["me"], "bike"))[0]!.text).toContain("bike");
	});

	test("int8 vectors keep the nearest first, and a model change leaves old vectors out until reindexed", async () => {
		const rows = Array.from({ length: 200 }, (_, i) => {
			const v = Float32Array.from({ length: 32 }, (_, d) => Math.sin(i * 7.1 + d * 1.3));
			const q = quantize(v);
			return { id: `r${i}`, v, vector: new Uint8Array(q.buffer) };
		});
		const index = new VectorIndex(32, rows);
		for (const i of [0, 17, 199]) {
			const noisy = rows[i]!.v.map((x) => x + 0.01);
			expect(index.search(quantize(noisy), 3)[0]!.id).toBe(`r${i}`);
		}
		// A vector of another size (another model) is skipped.
		expect(new VectorIndex(16, rows).size).toBe(0);
	});

	test("the OpenAI-compatible embedder sends the model, dimensions and key, and keeps the order", async () => {
		let sent: { url: string; body: { model: string; dimensions: number; input: string[] }; auth?: string } | undefined;
		const fakeFetch = (async (url: string, init: { body: string; headers: Record<string, string> }) => {
			sent = { url, body: JSON.parse(init.body), auth: init.headers.authorization };
			return new Response(JSON.stringify({ data: [{ index: 1, embedding: [0, 1] }, { index: 0, embedding: [1, 0] }] }));
		}) as unknown as typeof fetch;
		const e = openAiEmbedder({ baseUrl: "https://openrouter.ai/api/v1/", model: "openai/text-embedding-3-small", dims: 2, key: async () => "sk-test", fetch: fakeFetch });
		const [a, b] = await e.embed(["first", "second"]);
		expect(sent).toEqual({ url: "https://openrouter.ai/api/v1/embeddings", body: { model: "openai/text-embedding-3-small", dimensions: 2, input: ["first", "second"] }, auth: "Bearer sk-test" });
		expect([...a!]).toEqual([1, 0]);
		expect([...b!]).toEqual([0, 1]);
		expect(e.model).toBe("openai/text-embedding-3-small@2");
	});
});
