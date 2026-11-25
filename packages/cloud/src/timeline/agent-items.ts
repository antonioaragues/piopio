/**
 * An agent's own entries as the cloud draws them (the engine's view does this in its own way): a note, and a message
 * the agent sent on its own. The pi-durable mapper (@piopio/runtime) places them by their time.
 */
import type { TimelineItem } from "@piopio/protocol";
import { NOTICE_ENTRY, OUT_ENTRY, type Entry } from "@piopio/runtime";

export function agentItem(entry: Entry): TimelineItem | undefined {
	const at = (t?: number) => new Date(t ?? Date.now()).toISOString();
	if (entry.kind === NOTICE_ENTRY) {
		const d = entry.data as { text: string; at?: string };
		return { kind: "system", id: `notice:${entry.id}`, at: d.at ?? at(), level: "info", text: d.text };
	}
	if (entry.kind === OUT_ENTRY) {
		const d = entry.data as { text: string; from: string; suggestions?: string[] };
		return { kind: "assistant", id: String(entry.id), at: at(entry.model?.[0]?.timestamp as number | undefined), parts: [{ type: "text", text: d.text }], status: "done", outbound: { from: d.from, ...(d.suggestions?.length ? { suggestions: d.suggestions } : {}) } };
	}
	return undefined;
}
