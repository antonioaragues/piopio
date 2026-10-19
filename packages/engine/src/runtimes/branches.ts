/**
 * Branch switchers for pi-durable threads.
 *
 * Editing or regenerating a message forks the active conversation just before that user message
 * (pi-durable records the fork as `parent: { conversationId, at }`), or creates a fresh conversation
 * when it is the first message. Versions that diverge after the same entry are alternatives of each
 * other; the conversation that owns that entry is the original version.
 */
import type { BranchInfo } from "@piopio/protocol";

export type ConversationNode = { id: string; parent?: { conversationId: string; at: string } };
export type ViewEntry = { id: string; kind: string; conversationId: string };

const START = "start";

/** Branch info for every user message in `view` (the active conversation's transcript) that has alternatives. */
export function computeBranches(active: string, view: readonly ViewEntry[], conversations: readonly ConversationNode[], activity: Readonly<Record<string, number>>): Map<string, BranchInfo> {
	const byId = new Map(conversations.map((c) => [c.id, c]));
	const children = new Map<string, ConversationNode[]>();
	const groups = new Map<string, Set<string>>();
	for (const c of conversations) {
		const key = c.parent ? c.parent.at : START;
		if (!groups.has(key)) groups.set(key, new Set());
		groups.get(key)!.add(c.id);
		if (c.parent) {
			if (!children.has(c.parent.conversationId)) children.set(c.parent.conversationId, []);
			children.get(c.parent.conversationId)!.push(c);
		}
	}

	const lineage: string[] = [];
	for (let id: string | undefined = active; id !== undefined; id = byId.get(id)?.parent?.conversationId) lineage.push(id);

	const out = new Map<string, BranchInfo>();
	view.forEach((entry, i) => {
		if (entry.kind !== "pi.user" && entry.kind !== "piopio.user") return;
		const forkPoint = i > 0 ? view[i - 1]!.id : START;
		const forks = groups.get(forkPoint);
		if (!forks) return;
		const members = new Set(forks);
		// The original version: the conversation that owns the fork-point entry (for "start", the parentless ones are all in the group).
		if (forkPoint !== START) members.add(view[i - 1]!.conversationId);
		if (members.size < 2) return;
		const ordered = [...members].sort(byNumericId);
		const current = lineage.find((id) => members.has(id));
		if (current === undefined) return;
		const index = ordered.indexOf(current);
		const target = (member: string | undefined) => (member === undefined ? undefined : latestVersion(member, forkPoint, children, activity));
		const previous = target(ordered[index - 1]);
		const next = target(ordered[index + 1]);
		out.set(entry.id, { index, count: ordered.length, ...(previous ? { previous } : {}), ...(next ? { next } : {}) });
	});
	return out;
}

/**
 * Switching to a version should land where the user last was inside it: the most recently active
 * conversation among the version and its descendants that still contain it (forked after the fork point).
 */
function latestVersion(member: string, forkPoint: string, children: Map<string, ConversationNode[]>, activity: Readonly<Record<string, number>>): string {
	const after = forkPoint === START ? -Infinity : Number(forkPoint);
	let best = member;
	let bestAt = activity[member] ?? -1;
	const stack = [member];
	while (stack.length > 0) {
		for (const child of children.get(stack.pop()!) ?? []) {
			if (Number(child.parent!.at) <= after) continue; // diverges at or before the fork point: a different version
			const at = activity[child.id] ?? -1;
			if (at > bestAt) {
				best = child.id;
				bestAt = at;
			}
			stack.push(child.id);
		}
	}
	return best;
}

function byNumericId(a: string, b: string): number {
	return Number(a) - Number(b);
}
