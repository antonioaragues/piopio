/**
 * Space memory (docs/spec/04-chat §3.2, S8): shared knowledge as markdown, `## Section` headings with `- fact`
 * bullets. Every change is a revision that says who made it (the organizer, a topic, you), so the editor can show
 * the history and a change can be undone. Topics propose changes; you save or dismiss them.
 */
import { defineDoc } from "@earendil-works/pi-durable";

export type MemoryAuthor = { kind: "organizer" | "topic" | "user"; topicId?: string; title?: string };
export type Revision = { id: string; at: string; by: MemoryAuthor; summary: string; added: string[]; removed: string[]; before: string; after: string; undone?: boolean };
export type Proposal = { id: string; at: string; topicId: string; title: string; added: string[]; removed: string[]; reason: string; status: "pending" | "saved" | "dismissed"; revisionId?: string };
export type MemoryState = { text: string; revisions: Revision[]; proposals: Record<string, Proposal> };

export const MemoryDoc = defineDoc<MemoryState>({ kind: "piopio.space-memory", version: 1, scope: "session", initial: () => ({ text: "", revisions: [], proposals: {} }) });

export const MAX_REVISIONS = 40;
const MAX_MEMORY_CHARS = 20_000;
/** What the agents read of it each request. */
const PROMPT_CHARS = 4_000;

const bullet = /^\s*[-*]\s+/;
const content = (line: string) => line.replace(bullet, "").trim();

/** Adds and removes facts. Removing matches a fact exactly, else the first that contains the text. */
export function applyPatch(text: string, add: readonly string[], remove: readonly string[], section = "Notes"): { text: string; added: string[]; removed: string[] } {
	const lines = text.split("\n");
	const removed: string[] = [];
	for (const r of remove) {
		const want = r.trim().toLowerCase();
		if (!want) continue;
		const facts = lines.map((l, i) => ({ i, c: bullet.test(l) ? content(l).toLowerCase() : undefined })).filter((f) => f.c !== undefined);
		const hit = facts.find((f) => f.c === want) ?? facts.find((f) => f.c!.includes(want));
		if (!hit) continue;
		removed.push(content(lines[hit.i]!));
		lines.splice(hit.i, 1);
	}
	const added: string[] = [];
	for (const a of add) {
		const fact = a.replace(/\s+/g, " ").replace(bullet, "").trim();
		if (!fact || lines.some((l) => bullet.test(l) && content(l).toLowerCase() === fact.toLowerCase())) continue;
		const heading = lines.findIndex((l) => l.trim().toLowerCase() === `## ${section.trim().toLowerCase()}`);
		if (heading === -1) {
			while (lines.length && !lines.at(-1)!.trim()) lines.pop();
			lines.push(...(lines.length ? [""] : []), `## ${section.trim() || "Notes"}`, `- ${fact}`);
		} else {
			let end = heading + 1;
			while (end < lines.length && !lines[end]!.startsWith("## ")) end++;
			while (end > heading + 1 && !lines[end - 1]!.trim()) end--;
			lines.splice(end, 0, `- ${fact}`);
		}
		added.push(fact);
	}
	const next = lines.join("\n").replace(/\n{3,}/g, "\n\n").trim();
	if (next.length > MAX_MEMORY_CHARS) throw new Error(`Memory is limited to ${MAX_MEMORY_CHARS} characters; remove something first.`);
	return { text: next, added, removed };
}

/** The facts that differ between two versions (your edits in the editor). */
export function diffFacts(before: string, after: string): { added: string[]; removed: string[] } {
	const facts = (t: string) => new Set(t.split("\n").filter((l) => bullet.test(l)).map(content));
	const a = facts(before), b = facts(after);
	return { added: [...b].filter((f) => !a.has(f)), removed: [...a].filter((f) => !b.has(f)) };
}

export function describe(added: readonly string[], removed: readonly string[]): string {
	const q = (s: string) => `“${s.length > 80 ? `${s.slice(0, 79)}…` : s}”`;
	const parts = [...(added.length ? [`added ${added.map(q).join(", ")}`] : []), ...(removed.length ? [`removed ${removed.map(q).join(", ")}`] : [])];
	const text = parts.join("; ");
	return text ? text[0]!.toUpperCase() + text.slice(1) : "No change";
}

/** Memory as the agents see it: the start of it, with a note when it is cut. */
export function memoryPrompt(text: string, empty = "The Space's memory is empty."): string {
	if (!text.trim()) return empty;
	if (text.length <= PROMPT_CHARS) return text;
	return `${text.slice(0, PROMPT_CHARS)}\n\n[… ${text.length - PROMPT_CHARS} more characters of memory; search_space finds older facts.]`;
}

export function lineCount(text: string): number {
	return text.split("\n").filter((l) => bullet.test(l)).length;
}

/** Records a revision, keeping the newest MAX_REVISIONS. */
export function pushRevision(doc: MemoryState, revision: Revision): void {
	doc.revisions.push(revision);
	if (doc.revisions.length > MAX_REVISIONS) doc.revisions.splice(0, doc.revisions.length - MAX_REVISIONS);
}
