/**
 * Compact progress (docs/spec/06-agents §12 UI2): a turn's tool calls, shown as one `steps` item ("Worked 18s ·
 * 2 steps") that expands to the calls. A run of tool items, with nothing but tool-call-only answers between them,
 * becomes one steps item named after its first call.
 */
import type { SessionEvent, TimelineItem, ToolItem } from "@piopio/protocol";

type AssistantItem = Extract<TimelineItem, { kind: "assistant" }>;

type Steps = Extract<TimelineItem, { kind: "steps" }>;

export function groupSteps(items: readonly TimelineItem[], standalone: (tool: ToolItem) => boolean = () => false): TimelineItem[] {
	const out: TimelineItem[] = [];
	let current: Steps | undefined;
	// A finished answer that only thought (or only called tools): it joins the steps line that follows, if any.
	let pending: AssistantItem | undefined;
	const flush = () => {
		if (pending) out.push(pending);
		pending = undefined;
	};
	for (const item of items) {
		if (item.kind === "tool" && !standalone(item as ToolItem)) {
			if (!current) {
				current = { kind: "steps", id: `steps:${item.id}`, at: item.at, tools: [] };
				if (pending) absorb(current, pending);
				pending = undefined;
				out.push(current);
			}
			current.tools.push(item as ToolItem);
			continue;
		}
		// Checkpoints are saved silently (docs/design chat v3): they don't break a turn's line.
		if (item.kind === "checkpoint") {
			out.push(item);
			continue;
		}
		const silent = item.kind === "assistant" && !item.parts.some((p) => p.type === "text" && p.text.trim()) && item.status !== "error";
		if (silent && item.status !== "streaming") {
			// "Thought for 3s, edited RESUMEN.md": thinking between or before tool calls joins the line.
			if (current) absorb(current, item);
			else {
				flush();
				pending = item;
			}
			continue;
		}
		flush();
		// An answer still streaming with no text yet doesn't break the run either.
		if (!silent) current = undefined;
		out.push(item);
	}
	flush();
	return out;
}

/** Folds an answer's thinking (and its time) into a steps line. */
function absorb(steps: Steps, answer: AssistantItem): void {
	const thinking = answer.parts.filter((p) => p.type === "thinking").map((p) => p.text).join("").trim();
	if (thinking) steps.thinking = steps.thinking ? `${steps.thinking}\n\n${thinking}` : thinking;
	if (answer.thinkingMs) steps.thinkingMs = (steps.thinkingMs ?? 0) + answer.thinkingMs;
}

/**
 * Turns a batch of the builder's events into events over the grouped items: the items the batch touched are
 * compared with what was sent before and re-sent as added, updated or removed.
 *
 * Without an `items` source, the view keeps its own list of the conversation's items, from the snapshot and the
 * events (what any subscriber sees), and never changes an item it holds: an event's item replaces it, and a delta
 * makes a new one. So an item that is the same object as the one sent is unchanged, and only the items that are new
 * objects are compared, instead of copying and serializing the whole conversation on every update (a long Build turn
 * paid 10 to 20% of a core for it: docs/research/memory-and-cpu.md).
 */
export class StepsView {
	/** What was sent last, by id; `json` only where the item could change in place (an `items` source). */
	private shown = new Map<string, { item: TimelineItem; json?: string }>();
	private order: string[] = [];
	/** The conversation's items, when the view follows the events itself. */
	private mirror: TimelineItem[] = [];

	/**
	 * `group`: how items are folded (agents add result cards after each steps line). `items`: where the current items
	 * come from instead, read when a batch touched one; they may change in place, so they're compared by their JSON.
	 */
	constructor(
		private readonly group: (items: readonly TimelineItem[]) => TimelineItem[] = groupSteps,
		private readonly items?: () => readonly TimelineItem[],
	) {}

	/** The grouped items to send in a snapshot; remembers them as sent. */
	snapshot(items: readonly TimelineItem[]): TimelineItem[] {
		this.mirror = [...items];
		const grouped = this.group(items);
		this.remember(grouped);
		return grouped;
	}

	events(events: readonly SessionEvent[]): SessionEvent[] {
		const items = this.items;
		const out: SessionEvent[] = [];
		let touched = false;
		for (const e of events) {
			if (e.type === "resnapshot") {
				out.push({ ...e, snapshot: { ...e.snapshot, items: this.snapshot(e.snapshot.items) } });
				touched = false;
				continue;
			}
			if (e.type === "item.added" || e.type === "item.updated" || e.type === "item.replaced" || e.type === "item.removed") {
				if (!items) this.apply(e);
				touched = true;
				continue;
			}
			if (e.type === "item.delta" && !items) {
				// An answer not sent yet goes out whole at the end of this batch, with this text in it.
				const sent = this.shown.has(e.itemId);
				this.applyDelta(e);
				if (!sent) continue;
			}
			out.push(e);
		}
		if (!touched) return out;
		const next = this.group(items ? items() : this.mirror);
		const ids = new Set(next.map((i) => i.id));
		for (const id of this.order) if (!ids.has(id)) out.push({ type: "item.removed", itemId: id });
		next.forEach((item, i) => {
			const before = this.shown.get(item.id);
			if (before === undefined) {
				const following = next.slice(i + 1).find((n) => this.shown.has(n.id));
				out.push({ type: "item.added", item, ...(following ? { before: following.id } : {}) });
			} else if (items ? before.json !== JSON.stringify(item) : !same(before.item, item)) {
				out.push({ type: "item.updated", item });
			}
		});
		this.remember(next);
		return out;
	}

	private remember(grouped: readonly TimelineItem[]): void {
		this.shown = new Map(grouped.map((i) => [i.id, this.items ? { item: i, json: JSON.stringify(i) } : { item: i }]));
		this.order = grouped.map((i) => i.id);
	}

	/** Where an item is in the view's list: looked for from the end, where a turn's changes are. */
	private at(id: string): number {
		for (let i = this.mirror.length - 1; i >= 0; i--) if (this.mirror[i]!.id === id) return i;
		return -1;
	}

	private apply(e: Extract<SessionEvent, { type: "item.added" | "item.updated" | "item.replaced" | "item.removed" }>): void {
		if (e.type === "item.removed") {
			const i = this.at(e.itemId);
			if (i >= 0) this.mirror.splice(i, 1);
			return;
		}
		const i = this.at(e.type === "item.replaced" ? e.oldId : e.item.id);
		if (e.type !== "item.added" && i >= 0) {
			this.mirror[i] = e.item;
			return;
		}
		if (i >= 0) this.mirror.splice(i, 1);
		const before = e.type === "item.added" && e.before ? this.at(e.before) : -1;
		if (before >= 0) this.mirror.splice(before, 0, e.item);
		else this.mirror.push(e.item);
	}

	/** Streamed text, as the client adds it: a new item (the one sent stays as it was), which counts as sent. */
	private applyDelta(e: Extract<SessionEvent, { type: "item.delta" }>): void {
		const i = this.at(e.itemId);
		const old = this.mirror[i];
		if (!old || old.kind !== "assistant") return;
		const parts = [...old.parts];
		const part = parts[e.partIndex];
		if (part) parts[e.partIndex] = { ...part, text: part.text + e.textDelta };
		else parts[e.partIndex] = { type: e.partType, text: e.textDelta };
		const item = { ...old, parts };
		this.mirror[i] = item;
		const sent = this.shown.get(item.id);
		if (sent?.item === old) this.shown.set(item.id, { item });
	}
}

/**
 * Whether a grouped item is what was sent: the same object, or a steps line made again of the same objects (each
 * regrouping makes new steps lines). Anything else that is a new object counts as changed.
 */
function same(a: TimelineItem, b: TimelineItem): boolean {
	if (a === b) return true;
	if (a.kind !== "steps" || b.kind !== "steps") return false;
	const ka = Object.keys(a);
	if (ka.length !== Object.keys(b).length) return false;
	return ka.every((k) => {
		const x = (a as Record<string, unknown>)[k];
		const y = (b as Record<string, unknown>)[k];
		return x === y || (Array.isArray(x) && Array.isArray(y) && x.length === y.length && x.every((v, i) => v === y[i]));
	});
}
