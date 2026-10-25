/**
 * Embeddings for the built-in provider's semantic recall (docs/spec/14-memory §4, §5.1): vectors are normalized,
 * stored as int8 (256 dimensions by default) and scanned in JavaScript, so the same code runs on `node:sqlite` and on
 * a Durable Object's SQLite (spike S8). Only `fetch`: no SDK, no native code.
 */

export interface Embedder {
	/** Stored with each vector: a bank is searched only with vectors from the same model. */
	readonly model: string;
	readonly dims: number;
	embed(texts: readonly string[]): Promise<Float32Array[]>;
}

/** An OpenAI-compatible `/embeddings` endpoint: OpenRouter, OpenAI, or a local server. */
export function openAiEmbedder(options: {
	baseUrl: string;
	model: string;
	dims: number;
	/** Called per request, so a changed key applies at once. Undefined: no key (keyless local servers). */
	key: () => Promise<string | undefined>;
	/** Stored with the vectors; defaults to `model@dims`. */
	id?: string;
	fetch?: typeof fetch;
}): Embedder {
	const doFetch = options.fetch ?? fetch;
	return {
		model: options.id ?? `${options.model}@${options.dims}`,
		dims: options.dims,
		async embed(texts) {
			if (!texts.length) return [];
			const key = await options.key();
			const res = await doFetch(`${options.baseUrl.replace(/\/$/, "")}/embeddings`, {
				method: "POST",
				headers: { "content-type": "application/json", ...(key ? { authorization: `Bearer ${key}` } : {}) },
				body: JSON.stringify({ model: options.model, input: texts.map((t) => t.slice(0, 8000)), dimensions: options.dims }),
			});
			if (!res.ok) throw new Error(`Embeddings failed (${res.status}): ${(await res.text()).slice(0, 200)}`);
			const body = (await res.json()) as { data?: { index?: number; embedding: number[] }[] };
			const data = [...(body.data ?? [])].sort((a, b) => (a.index ?? 0) - (b.index ?? 0));
			if (data.length !== texts.length) throw new Error(`Embeddings: asked for ${texts.length}, got ${data.length}`);
			return data.map((d) => Float32Array.from(d.embedding));
		},
	};
}

/** A vector as stored: scaled so its largest component is ±127. Cosine similarity doesn't depend on the scale. */
export function quantize(v: Float32Array): Int8Array {
	let max = 0;
	for (const x of v) max = Math.max(max, Math.abs(x));
	const q = new Int8Array(v.length);
	if (max === 0) return q;
	for (let i = 0; i < v.length; i++) q[i] = Math.round((v[i]! / max) * 127);
	return q;
}

/** Vectors of one bank and model, in one typed array (what recall scans). */
export class VectorIndex {
	readonly ids: string[] = [];
	private matrix: Int8Array;
	private norms: Float32Array;

	constructor(
		readonly dims: number,
		rows: readonly { id: string; vector: Uint8Array }[],
	) {
		this.matrix = new Int8Array(rows.length * dims);
		this.norms = new Float32Array(rows.length);
		let n = 0;
		for (const r of rows) {
			if (r.vector.byteLength !== dims) continue; // another size (the model changed): reindexed later
			const v = new Int8Array(r.vector.buffer, r.vector.byteOffset, dims);
			this.matrix.set(v, n * dims);
			let sum = 0;
			for (let d = 0; d < dims; d++) sum += v[d]! * v[d]!;
			this.norms[n] = Math.sqrt(sum);
			this.ids.push(r.id);
			n++;
		}
	}

	get size(): number {
		return this.ids.length;
	}

	/** The `limit` most similar records by cosine similarity, best first. */
	search(query: Int8Array, limit: number): { id: string; similarity: number }[] {
		let qn = 0;
		for (const x of query) qn += x * x;
		qn = Math.sqrt(qn);
		if (!qn) return [];
		const best: { id: string; similarity: number }[] = [];
		const { dims, matrix, norms } = this;
		for (let row = 0, off = 0; row < this.ids.length; row++, off += dims) {
			let dot = 0;
			for (let d = 0; d < dims; d++) dot += query[d]! * matrix[off + d]!;
			const similarity = norms[row] ? dot / (qn * norms[row]!) : 0;
			if (best.length < limit || similarity > best[best.length - 1]!.similarity) {
				best.push({ id: this.ids[row]!, similarity });
				best.sort((a, b) => b.similarity - a.similarity);
				if (best.length > limit) best.pop();
			}
		}
		return best;
	}
}
