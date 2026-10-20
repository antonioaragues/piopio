// Spike S6, scale: stores synthetic facts in a Hindsight bank (an instance started with the LLM provider "none",
// so items are stored as they are, with local embeddings) and times ingestion and recall at 1k and 20k items.
//   node scale.mjs <api url> <api pid>
import { execFileSync } from "node:child_process";

const api = process.argv[2] ?? "http://127.0.0.1:8889";
const pid = process.argv[3];
const bank = `${api}/v1/default/banks/scale`;
const post = async (url, body, method = "POST") => {
	const r = await fetch(url, { method, headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
	if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
	return r.json();
};
const rss = () => (pid ? Math.round(Number(execFileSync("ps", ["-o", "rss=", "-p", pid]).toString().trim()) / 1024) : undefined);

const people = ["Alex", "Marta", "Luis", "Sam", "Ana", "Jordi", "Carmen", "Pablo", "Lucía", "Diego"];
const things = ["dentist", "flight", "gym", "book club", "car service", "vet", "dinner", "meeting", "concert", "haircut", "insurance renewal", "rent payment"];
const places = ["Madrid", "Valencia", "Lisbon", "Alicante", "Barcelona", "Sevilla", "Porto", "Bilbao"];
let n = 0;
const fact = () => {
	n++;
	const p = people[n % people.length], t = things[(n * 7) % things.length], c = places[(n * 3) % places.length];
	const day = 1 + (n % 28), month = 1 + (n % 12);
	return { content: `${p} has the ${t} in ${c} on ${month}/${day}, note ${n}.`, timestamp: new Date(Date.UTC(2026, month - 1, day)).toISOString() };
};
const queries = ["When is Marta's dentist?", "Who has a flight to Lisbon?", "What is on 3/14?", "Luis gym Barcelona", "Which concerts are in Porto?", "rent payment Sevilla", "Carmen haircut", "vet appointments in Valencia", "When does Pablo renew the insurance?", "dinner in Bilbao"];

async function fill(to) {
	const start = Date.now();
	const from = n;
	while (n < to) await post(`${bank}/memories`, { items: Array.from({ length: Math.min(100, to - n) }, fact) });
	const s = (Date.now() - start) / 1000;
	return { items: to - from, seconds: +s.toFixed(1), perSecond: Math.round((to - from) / s) };
}
async function recall() {
	const times = [];
	for (const q of [...queries, ...queries]) {
		const t = Date.now();
		await post(`${bank}/memories/recall`, { query: q, max_tokens: 2000 });
		times.push(Date.now() - t);
	}
	times.sort((a, b) => a - b);
	return { p50ms: times[Math.floor(times.length / 2)], p90ms: times[Math.floor(times.length * 0.9)], maxMs: times.at(-1) };
}

await post(bank, {}, "PUT");
const report = { idleRssMb: rss() };
report.fill1k = await fill(1000);
report.recall1k = await recall();
report.rss1k = rss();
report.fill20k = await fill(20000);
report.recall20k = await recall();
report.rss20k = rss();
console.log(JSON.stringify(report, null, 2));
