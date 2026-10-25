/**
 * Learned facts (docs/spec/14-memory §5.1, M2): after a turn, a small model pulls out the lasting facts in what was
 * said, then compares each with the most similar facts already known and decides: add it, replace one (the old fact
 * is kept, marked with what replaced it and when), end one that's no longer true, or nothing. Mem0's decision with
 * Graphiti's time model, on our own provider, so it runs on the Mac and on a Durable Object alike.
 */
import type { MemoryProvider, MemoryRecord, MemorySource } from "./provider.js";

/** The utility model: a system prompt and a prompt in, text out (undefined when no model is available). */
export type Complete = (system: string, prompt: string) => Promise<string | undefined>;

export type LearnedChange =
	| { action: "added"; record: MemoryRecord }
	| { action: "replaced"; record: MemoryRecord; old: MemoryRecord }
	| { action: "ended"; old: MemoryRecord };

export type LearnInput = {
	/** The exchange, as said: "Alex: …\nKit: …". */
	exchange: string;
	/** When it was said (ISO): facts take this date, and relative dates resolve against it. */
	at: string;
	/** Whose memory this is, for the extraction prompt ("Alex"). */
	about: string;
	source?: MemorySource;
};

const EXTRACT = `You maintain a long-term memory of facts about a person and their life, from their conversations with an assistant.
From the exchange, extract the facts worth remembering for months: where they live, work and study, their role, people and pets in their life, health, possessions, preferences and dislikes, plans and appointments with their dates, decisions, and changes to any of these.
Rules:
- Only what the person states or confirms. Not the assistant's suggestions, not requests, not small talk, not what's true only today.
- One self-contained sentence per fact, in the third person, with names ("Alex lives in Madrid"), never "I" or "they" alone.
- Write dates as absolute dates (the exchange's date is given). Keep a change's context in the fact: "Alex now works in pediatrics at Hospital Gregorio Marañón (since June 2026)".
- Nothing worth keeping: no facts.
Answer with JSON only: {"facts": ["…"]}`;

const DECIDE = `You keep a memory of facts about a person up to date. For each new fact, compare it with the existing facts and choose one operation:
- "add": new information.
- "replace": it updates or contradicts an existing fact about the same thing (a new city, a new job, a new date, a changed preference). Give that fact's id. The old fact is kept as history.
- "none": already known (same meaning as an existing fact).
Also, if the exchange says an existing fact stopped being true and no new fact replaces it, add {"op": "end", "id": "…"}.
Answer with JSON only: {"ops": [{"fact": 0, "op": "add"}, {"fact": 1, "op": "replace", "id": "…"}, {"fact": 2, "op": "none"}, {"op": "end", "id": "…"}]}`;

/** Learns from one exchange into `bank`. Returns what changed; nothing when the model finds no facts or isn't there. */
export async function learnFacts(memory: MemoryProvider, bank: string, input: LearnInput, complete: Complete): Promise<LearnedChange[]> {
	if (!memory.capabilities.learns || !memory.end) throw new Error("This memory provider can't keep learned facts.");
	const extracted = parse<{ facts?: unknown }>(await complete(EXTRACT, `Person: ${input.about}\nDate of the exchange: ${input.at.slice(0, 10)}\n\nExchange:\n${input.exchange}`));
	const facts = (Array.isArray(extracted?.facts) ? extracted.facts : []).filter((f): f is string => typeof f === "string" && f.trim().length > 3).map((f) => f.trim()).slice(0, 8);
	if (!facts.length) return [];

	// The facts each new one might update: the closest current facts in this bank.
	const candidates = new Map<string, MemoryRecord>();
	for (const fact of facts) {
		for (const hit of await memory.recall([bank], fact, { kinds: ["fact"], limit: 5, budgetTokens: 4000 })) candidates.set(hit.id, hit);
	}
	let ops: { fact?: number; op?: string; id?: string }[] = facts.map((_, i) => ({ fact: i, op: "add" }));
	if (candidates.size) {
		const existing = [...candidates.values()].map((r) => `${r.id}: ${r.text} (${r.at.slice(0, 10)})`).join("\n");
		const decided = parse<{ ops?: unknown }>(await complete(DECIDE, `Existing facts:\n${existing}\n\nNew facts (from ${input.at.slice(0, 10)}):\n${facts.map((f, i) => `${i}: ${f}`).join("\n")}\n\nExchange:\n${input.exchange}`));
		if (Array.isArray(decided?.ops)) ops = decided.ops as typeof ops;
	}

	const changes: LearnedChange[] = [];
	const touched = new Set<string>();
	const write = (text: string, replaces?: string) =>
		memory.retain(bank, { content: text, kind: "fact", createdBy: "extraction", at: input.at, ...(input.source ? { source: input.source } : {}), ...(replaces ? { replaces } : {}) });
	for (const op of ops) {
		const text = typeof op.fact === "number" ? facts[op.fact] : undefined;
		const old = op.id ? candidates.get(op.id) : undefined;
		if (op.op === "add" && text) {
			const [record] = await write(text);
			if (record) changes.push({ action: "added", record });
		} else if (op.op === "replace" && text && old && !touched.has(old.id)) {
			touched.add(old.id);
			const [record] = await write(text, old.id);
			if (record) changes.push({ action: "replaced", record, old });
		} else if (op.op === "replace" && text && !old) {
			// The model named a fact that isn't there: keep the new fact anyway.
			const [record] = await write(text);
			if (record) changes.push({ action: "added", record });
		} else if (op.op === "end" && old && !touched.has(old.id)) {
			touched.add(old.id);
			await memory.end(bank, old.id, input.at, "extraction");
			changes.push({ action: "ended", old });
		}
	}
	return changes;
}

/** Takes back what one learning step changed (Undo on its card). */
export async function unlearn(memory: MemoryProvider, bank: string, changes: readonly { action: LearnedChange["action"]; id?: string; oldId?: string }[]): Promise<void> {
	for (const c of [...changes].reverse()) {
		if (c.id && (c.action === "added" || c.action === "replaced")) await memory.forget?.(bank, c.id, "user").catch(() => undefined);
		if (c.oldId && (c.action === "replaced" || c.action === "ended")) await memory.restore?.(bank, c.oldId, "user");
	}
}

/** One line for the card: "Alex lives in Madrid (was: Alex lives in Valencia)". */
export function describeChange(c: LearnedChange): string {
	switch (c.action) {
		case "added":
			return c.record.text;
		case "replaced":
			return `${c.record.text} (was: ${c.old.text})`;
		case "ended":
			return `No longer true: ${c.old.text}`;
	}
}

/** The first JSON object in a model's answer (it may wrap it in prose or a code fence). */
function parse<T>(text: string | undefined): T | undefined {
	if (!text) return undefined;
	const start = text.indexOf("{");
	const end = text.lastIndexOf("}");
	if (start < 0 || end <= start) return undefined;
	try {
		return JSON.parse(text.slice(start, end + 1)) as T;
	} catch {
		return undefined;
	}
}
