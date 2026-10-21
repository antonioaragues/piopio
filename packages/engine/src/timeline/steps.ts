/**
 * Compact progress (docs/spec/06-agents §12 UI2): a turn's tool calls, shown as one `steps` item ("Worked 18s ·
 * 2 steps") that expands to the calls. A run of tool items, with nothing but tool-call-only answers between them,
 * becomes one steps item named after its first call.
 */
import type { SessionEvent, TimelineItem, ToolItem } from "@piopio/protocol";

type Steps = Extract<TimelineItem, { kind: "steps" }>;

export function groupSteps(items: readonly TimelineItem[]): TimelineItem[] {
	const out: TimelineItem[] = [];
	let current: Steps | undefined;
	for (const item of items) {
		if (item.kind === "tool") {
			if (!current) {
				current = { kind: "steps", id: `steps:${item.id}`, at: item.at, tools: [] };
				out.push(current);
			}
			current.tools.push(item as ToolItem);
			continue;
		}
		// An answer that only called tools shows nothing; it doesn't break the run.
		const silent = item.kind === "assistant" && !item.parts.some((p) => p.type === "text" && p.text.trim()) && item.status !== "error";
		if (!silent) current = undefined;
		out.push(item);
	}
	return out;
}

/**
 * Turns a batch of the builder's events into events over the grouped items: the items the batch touched are
 * compared with what was sent before and re-sent as added, updated or removed.
 */
export class StepsView {
	private shown = new Map<string, string>();
	private order: string[] = [];

	/** The grouped items to send in a snapshot; remembers them as sent. */
	snapshot(items: readonly TimelineItem[]): TimelineItem[] {
		const grouped = groupSteps(items);
		this.shown = new Map(grouped.map((i) => [i.id, JSON.stringify(i)]));
		this.order = grouped.map((i) => i.id);
		return grouped;
	}

	events(events: readonly SessionEvent[], items: () => readonly TimelineItem[]): SessionEvent[] {
		const out: SessionEvent[] = [];
		let touched = false;
		for (const e of events) {
			if (e.type === "resnapshot") {
				out.push({ ...e, snapshot: { ...e.snapshot, items: this.snapshot(e.snapshot.items) } });
				touched = false;
				continue;
			}
			if (e.type === "item.added" || e.type === "item.updated" || e.type === "item.replaced" || e.type === "item.removed") {
				touched = true;
				continue;
			}
			out.push(e);
		}
		if (!touched) return out;
		const next = groupSteps(items());
		const ids = new Set(next.map((i) => i.id));
		for (const id of this.order) if (!ids.has(id)) out.push({ type: "item.removed", itemId: id });
		next.forEach((item, i) => {
			const json = JSON.stringify(item);
			const before = this.shown.get(item.id);
			if (before === undefined) {
				const following = next.slice(i + 1).find((n) => this.shown.has(n.id));
				out.push({ type: "item.added", item, ...(following ? { before: following.id } : {}) });
			} else if (before !== json) {
				out.push({ type: "item.updated", item });
			}
		});
		this.shown = new Map(next.map((i) => [i.id, JSON.stringify(i)]));
		this.order = next.map((i) => i.id);
		return out;
	}
}
