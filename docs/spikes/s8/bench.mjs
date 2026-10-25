// Spike S8 (docs/spec/14-memory.md §4): semantic search in the built-in memory provider without a SQLite extension.
// Vectors are int8 BLOBs in an ordinary table; a bank's vectors are loaded once into one typed array and scanned in
// JavaScript, so the same code runs on node:sqlite and on a Durable Object's storage.
//
//   node docs/spikes/s8/bench.mjs [records…]     (default: 10000 50000)
//
// Synthetic vectors (unit-length random, quantized to int8): this measures storage and scan cost, not retrieval
// quality. Each query is a stored vector with noise added, so the right answer is known.
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const DIMS = 256;
const QUERIES = 50;
const sizes = process.argv.slice(2).map(Number).filter(Boolean);

function randomUnit(dims) {
	const v = new Float32Array(dims);
	let norm = 0;
	for (let i = 0; i < dims; i++) {
		// Box–Muller: Gaussian components give directions uniform on the sphere.
		const g = Math.sqrt(-2 * Math.log(Math.random() || 1e-12)) * Math.cos(2 * Math.PI * Math.random());
		v[i] = g;
		norm += g * g;
	}
	norm = Math.sqrt(norm);
	for (let i = 0; i < dims; i++) v[i] /= norm;
	return v;
}

/** Unit vector → int8 (scale 127 / max |component|), as stored. */
function quantize(v) {
	let max = 0;
	for (const x of v) max = Math.max(max, Math.abs(x));
	const q = new Int8Array(v.length);
	for (let i = 0; i < v.length; i++) q[i] = Math.round((v[i] / max) * 127);
	return q;
}

function run(n) {
	const dir = mkdtempSync(join(tmpdir(), "piopio-s8-"));
	const file = join(dir, "memory.sqlite");
	const db = new DatabaseSync(file);
	db.exec("CREATE TABLE memory_vectors (record_id TEXT PRIMARY KEY, bank TEXT NOT NULL, model TEXT NOT NULL, vector BLOB NOT NULL)");
	const insert = db.prepare("INSERT INTO memory_vectors (record_id, bank, model, vector) VALUES (?, 'bank', 'bench-256', ?)");
	const originals = [];
	let t = performance.now();
	db.exec("BEGIN");
	for (let i = 0; i < n; i++) {
		const v = randomUnit(DIMS);
		if (i < QUERIES) originals.push(v);
		insert.run(`r${i}`, quantize(v));
	}
	db.exec("COMMIT");
	const writeMs = performance.now() - t;

	// Load the bank once into one typed array (what the provider keeps in memory per bank).
	t = performance.now();
	const rows = db.prepare("SELECT record_id, vector FROM memory_vectors WHERE bank = 'bank' ORDER BY rowid").all();
	const ids = rows.map((r) => r.record_id);
	const matrix = new Int8Array(rows.length * DIMS);
	rows.forEach((r, i) => matrix.set(new Int8Array(r.vector.buffer, r.vector.byteOffset, DIMS), i * DIMS));
	const loadMs = performance.now() - t;

	// Queries: a stored vector plus noise; the nearest should be that record.
	let hits = 0;
	const times = [];
	for (let q = 0; q < QUERIES; q++) {
		const noisy = originals[q].map((x) => x + (Math.random() - 0.5) * 0.02);
		const query = quantize(noisy);
		t = performance.now();
		let best = -Infinity;
		let bestAt = -1;
		for (let row = 0, off = 0; row < ids.length; row++, off += DIMS) {
			let dot = 0;
			for (let d = 0; d < DIMS; d++) dot += query[d] * matrix[off + d];
			if (dot > best) {
				best = dot;
				bestAt = row;
			}
		}
		times.push(performance.now() - t);
		if (ids[bestAt] === `r${q}`) hits++;
	}
	db.close();
	const bytes = statSync(file).size;
	rmSync(dir, { recursive: true, force: true });
	times.sort((a, b) => a - b);
	const median = times[Math.floor(times.length / 2)];
	return { n, mb: bytes / 1e6, writeMs, loadMs, median, p90: times[Math.floor(times.length * 0.9)], hits };
}

console.log(`node ${process.version} · ${process.arch} · ${DIMS} dims int8 · ${QUERIES} queries per size`);
for (const n of sizes.length ? sizes : [10_000, 50_000]) {
	const r = run(n);
	console.log(`${String(n).padStart(7)} records · ${r.mb.toFixed(1)} MB on disk · write ${r.writeMs.toFixed(0)} ms · load ${r.loadMs.toFixed(0)} ms · query median ${r.median.toFixed(1)} ms, p90 ${r.p90.toFixed(1)} ms · nearest first ${r.hits}/${QUERIES}`);
}
