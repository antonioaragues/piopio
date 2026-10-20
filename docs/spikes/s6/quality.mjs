// Spike S6, quality: the 200 messages of conversation.json go into
//   (a) a Hindsight bank (retain with LLM extraction through OpenRouter), and
//   (b) the built-in baseline: keyword (BM25) + recency over the raw messages, as 06-agents ME2 v1 describes;
// then the 30 questions are answered from each one's memory by the same model, and a judge model scores them.
// Hindsight's own `reflect` answers are scored too. Costs are the OpenRouter key's usage before and after.
//   OPENROUTER_API_KEY=… node quality.mjs <hindsight url> [model]
import { readFileSync, writeFileSync } from "node:fs";

const api = process.argv[2] ?? "http://127.0.0.1:8888";
const model = process.argv[3] ?? "anthropic/claude-haiku-5.5";
const key = process.env.OPENROUTER_API_KEY;
const set = JSON.parse(readFileSync(new URL("./conversation.json", import.meta.url), "utf8"));
const bank = `${api}/v1/default/banks/alex`;
const json = async (url, body, method = "POST", headers = {}) => {
	const r = await fetch(url, { method, headers: { "content-type": "application/json", ...headers }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
	if (!r.ok) throw new Error(`${url}: ${r.status} ${await r.text()}`);
	return r.json();
};
const usage = async () => (await json("https://openrouter.ai/api/v1/key", undefined, "GET", { authorization: `Bearer ${key}` })).data.usage;
const chat = async (system, user) => {
	const r = await json("https://openrouter.ai/api/v1/chat/completions", { model, messages: [{ role: "system", content: system }, { role: "user", content: user }], max_tokens: 300, temperature: 0 }, "POST", { authorization: `Bearer ${key}` });
	return r.choices[0].message.content.trim();
};
const line = (m) => `[${m.at.slice(0, 16).replace("T", " ")}] ${m.speaker}: ${m.text}\nAgent: ${m.reply}`;

// ── Hindsight: retain, day by day ──
const report = { model, retain: {}, questions: [] };
const u0 = await usage();
await json(bank, { mission: "A personal assistant agent for Alex. Remember facts about Alex and the people Alex knows, and how they change." }, "PUT");
const byDay = new Map();
for (const m of set.messages) byDay.set(m.at.slice(0, 10), [...(byDay.get(m.at.slice(0, 10)) ?? []), m]);
let t = Date.now();
const retainTimes = [];
let tokens = 0;
for (const [, ms] of byDay) {
	const s = Date.now();
	const r = await json(`${bank}/memories`, { items: ms.map((m) => ({ content: `${m.speaker}: ${m.text}\nAgent: ${m.reply}`, timestamp: m.at, context: `Message from ${m.speaker} to Alex's personal agent` })) });
	tokens += r.usage?.total_tokens ?? 0;
	retainTimes.push(Date.now() - s);
}
report.retain.calls = retainTimes.length;
report.retain.seconds = +((Date.now() - t) / 1000).toFixed(1);
report.retain.msPerCallMedian = retainTimes.sort((a, b) => a - b)[Math.floor(retainTimes.length / 2)];
report.retain.tokens = tokens;
// Background consolidation (observations): wait until no operation is pending.
t = Date.now();
for (let i = 0; i < 600; i++) {
	const ops = await json(`${bank}/operations`, undefined, "GET");
	const items = ops.operations ?? ops.items ?? [];
	if (!items.some((o) => ["pending", "running", "processing"].includes(o.status))) break;
	await new Promise((r) => setTimeout(r, 1000));
}
report.retain.consolidationSeconds = +((Date.now() - t) / 1000).toFixed(1);
const stats = await json(`${bank}/stats`, undefined, "GET");
report.retain.stats = stats;
const u1 = await usage();
report.retain.costUsd = +(u1 - u0).toFixed(4);

// ── Baseline: BM25 + recency over the raw messages ──
const tokenize = (s) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").split(/[^a-z0-9€]+/).filter((w) => w.length > 2);
const docs = set.messages.map((m, i) => ({ m, i, words: tokenize(`${m.speaker} ${m.text} ${m.reply}`) }));
const df = new Map();
for (const d of docs) for (const w of new Set(d.words)) df.set(w, (df.get(w) ?? 0) + 1);
const avg = docs.reduce((s, d) => s + d.words.length, 0) / docs.length;
const baseline = (q) => {
	const qs = tokenize(q);
	return docs
		.map((d) => {
			let score = 0;
			for (const w of qs) {
				const f = d.words.filter((x) => x === w).length;
				if (!f) continue;
				const idf = Math.log(1 + (docs.length - df.get(w) + 0.5) / (df.get(w) + 0.5));
				score += (idf * f * 2.2) / (f + 1.2 * (0.25 + (0.75 * d.words.length) / avg));
			}
			return { d, score: score * (1 + (0.5 * d.i) / docs.length) };
		})
		.filter((x) => x.score > 0)
		.sort((a, b) => b.score - a.score)
		.slice(0, 10)
		.sort((a, b) => a.d.i - b.d.i)
		.map((x) => line(x.d.m))
		.join("\n\n");
};

const answer = (memory, q) =>
	chat(`You are Alex's personal assistant. Today is ${set.today}. Answer the question from the memory below only, in one short sentence. Later information replaces earlier information. If the memory doesn't say, answer "I don't know".`, `Memory:\n${memory || "(empty)"}\n\nQuestion: ${q}`);
const judge = async (q, expected, got) =>
	/^yes/i.test(await chat("You grade answers. Reply with only yes or no.", `Question: ${q}\nCorrect answer: ${expected}\nGiven answer: ${got}\nDoes the given answer state the correct answer (same fact, current value)? Extra correct detail is fine.`));

for (const { q, a, kind } of set.questions) {
	const row = { q, expected: a, kind };
	row.baseline = await answer(baseline(q), q);
	let s = Date.now();
	const recall = await json(`${bank}/memories/recall`, { query: q, max_tokens: 2000, query_timestamp: `${set.today}T09:00:00Z` });
	row.recallMs = Date.now() - s;
	const facts = recall.results.map((r) => `[${(r.occurred_start ?? r.mentioned_at ?? "").slice(0, 10)}] ${r.text}`).join("\n");
	row.hindsight = await answer(facts, q);
	s = Date.now();
	const reflected = await json(`${bank}/reflect`, { query: q, budget: "low", query_timestamp: `${set.today}T09:00:00Z` }).catch((e) => ({ text: `ERROR ${e.message}` }));
	row.reflectMs = Date.now() - s;
	row.reflect = (reflected.text ?? reflected.answer ?? JSON.stringify(reflected)).trim();
	row.right = { baseline: await judge(q, a, row.baseline), hindsight: await judge(q, a, row.hindsight), reflect: await judge(q, a, row.reflect) };
	report.questions.push(row);
	console.log(`${row.right.baseline ? "✓" : "✗"} ${row.right.hindsight ? "✓" : "✗"} ${row.right.reflect ? "✓" : "✗"}  [${kind}] ${q}`);
}
const u2 = await usage();
report.qaCostUsd = +(u2 - u1).toFixed(4);
const score = (k) => report.questions.filter((r) => r.right[k]).length;
const byKind = (k) => Object.fromEntries(["fact", "changed", "who"].map((kind) => [kind, `${report.questions.filter((r) => r.kind === kind && r.right[k]).length}/${report.questions.filter((r) => r.kind === kind).length}`]));
const med = (k) => report.questions.map((r) => r[k]).sort((a, b) => a - b)[15];
report.summary = { baseline: score("baseline"), hindsight: score("hindsight"), reflect: score("reflect"), of: report.questions.length, byKind: { baseline: byKind("baseline"), hindsight: byKind("hindsight"), reflect: byKind("reflect") }, recallMsMedian: med("recallMs"), reflectMsMedian: med("reflectMs") };
console.log(JSON.stringify({ retain: { ...report.retain, stats: undefined }, summary: report.summary, qaCostUsd: report.qaCostUsd }, null, 2));
writeFileSync(process.env.S6_OUT ?? "quality-report.json", JSON.stringify(report, null, "\t"));
