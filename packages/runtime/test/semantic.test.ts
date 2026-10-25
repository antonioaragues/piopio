import { DatabaseSync } from "node:sqlite";
import { describe, expect, test } from "vitest";
import { BuiltinMemory, describeChange, learnFacts, openAiEmbedder, quantize, unlearn, VectorIndex, type Embedder, type Sql } from "../src/index.js";

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

describe("learned facts (docs/spec/14-memory, M2)", () => {
	test("add, replace with history, end, nothing; Undo restores; ended facts aren't recalled", async () => {
		const { m } = memory(() => toyEmbedder());
		const script: string[] = [];
		const complete = async (system: string, prompt: string) => {
			script.push(system.startsWith("You maintain") ? "extract" : "decide");
			if (system.startsWith("You maintain")) {
				if (prompt.includes("Valencia")) return '```json\n{"facts": ["Alex lives in Valencia", "Alex is vegetarian"]}\n```';
				if (prompt.includes("Madrid")) return '{"facts": ["Alex lives in Madrid", "Alex is vegetarian"]}';
				if (prompt.includes("stopped")) return '{"facts": ["Alex stopped being vegetarian"]}';
				return '{"facts": []}';
			}
			const id = (text: string) => new RegExp(`^(\\S+): ${text}`, "m").exec(prompt)?.[1];
			if (prompt.includes("moved to Madrid")) return JSON.stringify({ ops: [{ fact: 0, op: "replace", id: id("Alex lives in Valencia") }, { fact: 1, op: "none" }] });
			return JSON.stringify({ ops: [{ op: "end", id: id("Alex is vegetarian") }, { fact: 0, op: "none" }] });
		};
		const added = await learnFacts(m, "alex", { exchange: "Alex: I live in Valencia and I'm vegetarian.", at: "2026-04-02T10:00:00Z", about: "Alex" }, complete);
		expect(added.map((c) => c.action)).toEqual(["added", "added"]);
		expect(script).toEqual(["extract"]); // nothing known yet: no decision step

		const replaced = await learnFacts(m, "alex", { exchange: "Alex: We moved to Madrid.", at: "2026-06-16T10:00:00Z", about: "Alex" }, complete);
		expect(replaced.map((c) => [c.action, describeChange(c)])).toEqual([["replaced", "Alex lives in Madrid (was: Alex lives in Valencia)"]]);
		expect((await m.list("alex")).records.map((r) => r.text).sort()).toEqual(["Alex is vegetarian", "Alex lives in Madrid"]);
		const history = (await m.list("alex", { includeEnded: true })).records.find((r) => r.text === "Alex lives in Valencia")!;
		expect(history).toMatchObject({ endedAt: "2026-06-16T10:00:00Z", replacedBy: replaced[0]!.action === "replaced" ? replaced[0]!.record.id : "" });
		expect((await m.recall(["alex"], "Which city?")).map((h) => h.text)).toEqual(["Alex lives in Madrid"]);

		const ended = await learnFacts(m, "alex", { exchange: "Alex: I stopped being vegetarian, I eat fish now.", at: "2026-07-20T10:00:00Z", about: "Alex" }, complete);
		expect(ended.map((c) => c.action)).toEqual(["ended"]);
		expect((await m.list("alex")).records.map((r) => r.text)).toEqual(["Alex lives in Madrid"]);

		// Undo the replacement: Valencia is current again, Madrid is gone.
		await unlearn(m, "alex", [{ action: "replaced", id: replaced[0]!.action === "replaced" ? replaced[0]!.record.id : "", oldId: history.id }]);
		expect((await m.list("alex")).records.map((r) => r.text)).toEqual(["Alex lives in Valencia"]);
		expect((await m.history("alex")).map((e) => e.action).slice(0, 3)).toEqual(["restored", "removed", "ended"]);
		// A model that answers nonsense learns nothing.
		expect(await learnFacts(m, "alex", { exchange: "Alex: hi", at: "2026-08-01T10:00:00Z", about: "Alex" }, async () => "sorry")).toEqual([]);
	});
});
