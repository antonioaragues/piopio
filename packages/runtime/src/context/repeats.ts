/**
 * A nudge out of tool-call loops (docs/research/deepseek-harness.md §1.2). When the model calls the same tool with the
 * same arguments for the 3rd, 5th and 8th time since the user's last message, that call's result ends with a note
 * asking it to look at what it got and change approach or stop. It never blocks a call. Worked out from the messages,
 * like the clock, so it survives a restart and a reload reads the same.
 */

type Block = { type?: string; id?: string; name?: string; arguments?: unknown; text?: string };
/** A message as pi and pi-durable keep it. */
export type RepeatMessage = { role: string; content?: unknown; toolCallId?: string };

export const REPEAT_REMINDERS = [3, 5, 8] as const;

/** JSON with sorted keys, so `{a,b}` and `{b,a}` are the same call. */
export function stableJson(value: unknown): string {
	if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
	if (value && typeof value === "object") {
		return `{${Object.keys(value)
			.sort()
			.map((k) => `${JSON.stringify(k)}:${stableJson((value as Record<string, unknown>)[k])}`)
			.join(",")}}`;
	}
	return JSON.stringify(value) ?? "null";
}

export function repeatNote(tool: string, count: number): string {
	return `[Piopio: this is call number ${count} to ${tool} with exactly these arguments since the user's last message. Look at the earlier results before going on: if they didn't help, try a different approach, or stop and tell the user what's in the way.]`;
}

/** The messages with a note on the results of repeated calls. Returns the same array when there are none. */
export function remindRepeats<M extends RepeatMessage>(messages: readonly M[]): M[] {
	// Since the last real user message (tool results are their own role).
	let start = 0;
	for (let i = messages.length - 1; i >= 0; i--) {
		if (messages[i]!.role === "user") {
			start = i + 1;
			break;
		}
	}
	const counts = new Map<string, number>();
	const notes = new Map<string, string>();
	for (let i = start; i < messages.length; i++) {
		const m = messages[i]!;
		if (m.role !== "assistant" || !Array.isArray(m.content)) continue;
		for (const b of m.content as Block[]) {
			if (b?.type !== "toolCall" || !b.id || !b.name) continue;
			const key = `${b.name}\u0000${stableJson(b.arguments ?? {})}`;
			const n = (counts.get(key) ?? 0) + 1;
			counts.set(key, n);
			if ((REPEAT_REMINDERS as readonly number[]).includes(n)) notes.set(b.id, repeatNote(b.name, n));
		}
	}
	if (notes.size === 0) return messages as M[];
	let out: M[] | undefined;
	for (let i = start; i < messages.length; i++) {
		const m = messages[i]!;
		const note = m.role === "toolResult" && m.toolCallId ? notes.get(m.toolCallId) : undefined;
		if (!note) continue;
		out ??= messages.slice();
		const content = Array.isArray(m.content) ? [...m.content, { type: "text", text: `\n\n${note}` }] : typeof m.content === "string" ? `${m.content}\n\n${note}` : [{ type: "text", text: note }];
		out[i] = { ...m, content };
	}
	return out ?? (messages as M[]);
}
