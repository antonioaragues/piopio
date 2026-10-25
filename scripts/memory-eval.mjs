#!/usr/bin/env node
// Memory evaluation M0 (docs/spec/14-memory §5.5): retains the 2,018 messages of
// packages/engine/test/memory-eval/memory-2000.json into one bank, then asks its 40 questions on 30 September,
// once per engine, with the same answering model. For each question: what recall returned (within the agents'
// 1,200-token budget), whether that holds the answer, the model's answer and its grade.
//
//   node scripts/memory-eval.mjs                          # every engine; key from OPENROUTER_API_KEY or the Keychain
//   node scripts/memory-eval.mjs --engines basic,small    # some of them
//   node scripts/memory-eval.mjs --model <id>             # the answering model (default anthropic/claude-haiku-5.5)
//   node scripts/memory-eval.mjs --recall-only            # no answers: retrieval only (embeddings still cost a little)
//
// Engines: basic (keyword + recency), small (+ text-embedding-3-small at 256), large (+ text-embedding-3-large at 256),
// learned (small + facts learned from each day's exchanges by the utility model, M2; about $1 and 20 minutes).
// Costs real money with OpenRouter (about $0.05 without learned). Build first: corepack pnpm -r build
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const option = (name) => (args.includes(`--${name}`) ? args[args.indexOf(`--${name}`) + 1] : undefined);
const recallOnly = args.includes("--recall-only");
const model = option("model") ?? "anthropic/claude-haiku-5.5";
const engines = (option("engines") ?? "basic,small,large").split(",");

const key =
	process.env.OPENROUTER_API_KEY ??
	(() => {
		try {
			return execFileSync("security", ["find-generic-password", "-s", "Piopio", "-a", "provider.openrouter.apiKey", "-w"], { encoding: "utf8" }).trim();
		} catch {
			console.error("No OpenRouter key: set OPENROUTER_API_KEY, or add the key in Piopio first.");
			process.exit(1);
		}
	})();

const { BuiltinMemory, openAiEmbedder, learnFacts } = await import(join(root, "packages/runtime/dist/index.js"));
const utilityModel = option("utility") ?? "anthropic/claude-haiku-5.5";
const set = JSON.parse(readFileSync(join(root, "packages/engine/test/memory-eval/memory-2000.json"), "utf8"));
const BANK = "alex";

/** fetch that adds up OpenRouter's reported cost. */
const spent = { embeddings: 0, answers: 0, learning: 0, embeddingTokens: 0 };
const countingFetch = (bucket) => async (url, init) => {
	const res = await fetch(url, init);
	const body = await res.clone().json().catch(() => ({}));
	spent[bucket] += body.usage?.cost ?? 0;
	if (bucket === "embeddings") spent.embeddingTokens += body.usage?.prompt_tokens ?? 0;
	return res;
};

const EMBEDDERS = {
	small: { model: "openai/text-embedding-3-small", dims: 256 },
	large: { model: "openai/text-embedding-3-large", dims: 256 },
	learned: { model: "openai/text-embedding-3-small", dims: 256 },
};

/** The utility model, as the engine calls it: a system prompt and a prompt. */
async function utility(system, prompt) {
	const res = await countingFetch("learning")("https://openrouter.ai/api/v1/chat/completions", {
		method: "POST",
		headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
		body: JSON.stringify({ model: utilityModel, temperature: 0, max_tokens: 3000, usage: { include: true }, messages: [{ role: "system", content: system }, { role: "user", content: prompt }] }),
	});
	const body = await res.json();
	if (!res.ok) throw new Error(`${res.status} ${JSON.stringify(body).slice(0, 200)}`);
	return body.choices?.[0]?.message?.content ?? "";
}

async function build(engine) {
	const db = new DatabaseSync(":memory:");
	const sql = { exec: (s) => db.exec(s), run: (s, ...p) => void db.prepare(s).run(...p), all: (s, ...p) => db.prepare(s).all(...p) };
	const spec = EMBEDDERS[engine];
	const embedder = spec ? openAiEmbedder({ baseUrl: "https://openrouter.ai/api/v1", model: spec.model, dims: spec.dims, key: async () => key, fetch: countingFetch("embeddings") }) : undefined;
	// Write first, embed after in batches (what the engine's backfill does), so the run doesn't make 2,000 requests.
	let embedding = false;
	let n = 0;
	const memory = new BuiltinMemory(sql, () => `r${++n}`, () => new Date().toISOString(), () => (embedding ? embedder : undefined));
	const t0 = performance.now();
	const learned = { added: 0, replaced: 0, ended: 0, days: 0 };
	const byDay = new Map();
	for (const m of set.messages) byDay.set(m.at.slice(0, 10), [...(byDay.get(m.at.slice(0, 10)) ?? []), m]);
	for (const [date, day] of byDay) {
		for (const m of day) await memory.retain(BANK, { content: `${m.from}: ${m.text}`, kind: "message", createdBy: m.from === set.people.user ? "user" : "agent", at: m.at });
		if (engine !== "learned") continue;
		// One learning step per day of conversation (the engine batches a quiet conversation's exchanges the same way).
		embedding = true;
		const exchange = day.map((m) => `${m.from}: ${m.text}`).join("\n");
		const changes = await learnFacts(memory, BANK, { exchange, at: day[day.length - 1].at, about: set.people.user }, utility).catch((e) => (console.error(date, e.message), []));
		for (const c of changes) learned[c.action]++;
		learned.days++;
		embedding = false;
		if (learned.days % 30 === 0) console.log(`  learned through ${date}: +${learned.added} ~${learned.replaced} -${learned.ended}`);
	}
	embedding = Boolean(embedder);
	if (embedder) await memory.reindex({ batch: 128 });
	return { memory, writeMs: performance.now() - t0, learned };
}

async function answer(question, lines) {
	const res = await countingFetch("answers")("https://openrouter.ai/api/v1/chat/completions", {
		method: "POST",
		headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
		body: JSON.stringify({
			model,
			temperature: 0,
			max_tokens: 2000, // the model reasons first; its answer comes after
			usage: { include: true },
			messages: [
				{
					role: "system",
					content: `You are ${set.people.agent}, ${set.people.user}'s assistant. Today is ${set.today}. Answer from your memory below only, in one short sentence. Messages are dated; when facts changed, the newest is true now. If your memory doesn't say, answer "I don't know".\n\nFrom your memory:\n${lines.join("\n") || "(nothing relevant)"}`,
				},
				{ role: "user", content: question },
			],
		}),
	});
	const body = await res.json();
	if (!res.ok) throw new Error(`${res.status} ${JSON.stringify(body).slice(0, 200)}`);
	return body.choices?.[0]?.message?.content?.trim() ?? "";
}

const grade = (text, q) => q.expect.every((p) => new RegExp(p, "i").test(text)) && !(q.forbid ?? []).some((p) => new RegExp(p, "is").test(text));

async function pool(items, size, fn) {
	const out = new Array(items.length);
	let next = 0;
	await Promise.all(Array.from({ length: size }, async () => {
		while (next < items.length) {
			const i = next++;
			out[i] = await fn(items[i], i);
		}
	}));
	return out;
}

const report = { set: set.name, messages: set.messages.length, model: recallOnly ? null : model, at: new Date().toISOString(), engines: {} };
for (const engine of engines) {
	const { memory, writeMs, learned } = await build(engine);
	const rows = await pool(set.questions, 5, async (q) => {
		const t = performance.now();
		const hits = await memory.recall([BANK], q.q, { budgetTokens: 1200 });
		const recallMs = performance.now() - t;
		const lines = hits.map((h) => `- [${h.at.slice(0, 10)}] ${h.text}`);
		const context = lines.join("\n");
		const found = q.type === "unknown" ? null : q.expect.every((p) => new RegExp(p, "i").test(context));
		const said = recallOnly ? null : await answer(q.q, lines);
		return { type: q.type, q: q.q, found, answer: said, right: said === null ? null : grade(said, q), recallMs: Math.round(recallMs), hits: hits.length };
	});
	const byType = {};
	for (const r of rows) {
		const t = (byType[r.type] ??= { n: 0, found: 0, right: 0 });
		t.n++;
		if (r.found) t.found++;
		if (r.right) t.right++;
	}
	const known = rows.filter((r) => r.type !== "unknown");
	report.engines[engine] = {
		found: known.filter((r) => r.found).length,
		of: known.length,
		right: recallOnly ? null : rows.filter((r) => r.right).length,
		questions: rows.length,
		byType,
		recallMsMedian: rows.map((r) => r.recallMs).sort((a, b) => a - b)[Math.floor(rows.length / 2)],
		writeSeconds: Math.round(writeMs / 100) / 10,
		...(engine === "learned" ? { learned, facts: (await memory.list(BANK, { kinds: ["fact"], includeEnded: true, limit: 1000 })).records.map((r) => ({ text: r.text, at: r.at, ...(r.endedAt ? { endedAt: r.endedAt } : {}) })) } : {}),
		rows,
	};
	const e = report.engines[engine];
	console.log(`${engine.padEnd(6)} recall holds the answer ${e.found}/${e.of}` + (recallOnly ? "" : ` · answered right ${e.right}/${e.questions}`) + ` · ${Object.entries(byType).map(([t, v]) => `${t} ${recallOnly ? v.found : v.right}/${v.n}`).join(", ")} · recall ${e.recallMsMedian} ms`);
}
report.cost = { embeddings: Math.round(spent.embeddings * 1e5) / 1e5, embeddingTokens: spent.embeddingTokens, answers: Math.round(spent.answers * 1e4) / 1e4, learning: Math.round(spent.learning * 1e4) / 1e4 };
console.log(`cost: embeddings $${report.cost.embeddings} (${spent.embeddingTokens} tokens), answers $${report.cost.answers}, learning $${report.cost.learning}`);
const dir = join(root, "packages/engine/test/memory-eval/results");
mkdirSync(dir, { recursive: true });
const file = join(dir, `${report.at.slice(0, 10)}-${engines.join("-")}${recallOnly ? "-recall" : ""}.json`);
writeFileSync(file, `${JSON.stringify(report, null, "\t")}\n`);
console.log(`report: ${file}`);
