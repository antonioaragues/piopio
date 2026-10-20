/**
 * Moving conversations between pi-durable sessions (04-chat S5, S9, S11): a thread into a Space topic, a topic
 * out into a thread. The model messages of the conversation's active branch are copied as `piopio.imported`
 * entries, so the new conversation's model sees the same history and the transcript shows it.
 */
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Conversation, ConversationId, Tx } from "@earendil-works/pi-durable";
import { USER_ENTRY } from "../input.js";
import { contentText, type PiContentBlock } from "../timeline/builder.js";

const ctx = BACKGROUND_CONTEXT;

export const IMPORTED_ENTRY = "piopio.imported";

/** One entry's model messages, with the text to show for a user message. */
export type Portable = { model: { role: string; content?: unknown }[]; text?: string };

type RawEntry = { kind: string; data?: unknown; model?: readonly { role: string; content?: unknown }[] };

/** The active branch's messages (user, assistant, tool results), oldest first. */
export async function exportConversation(conversation: Conversation): Promise<Portable[]> {
	const view = await conversation.viewState(ctx);
	const entries = view.value.entries as readonly RawEntry[];
	view.dispose();
	const out: Portable[] = [];
	for (const e of entries) {
		const model = (e.model ?? []).filter((m) => m.role === "user" || m.role === "assistant" || m.role === "toolResult");
		if (!model.length || e.kind === "pi.compaction") continue;
		const data = e.data as { text?: unknown } | undefined;
		const text = model[0]!.role !== "user" ? undefined : typeof data?.text === "string" && (e.kind === USER_ENTRY || e.kind === IMPORTED_ENTRY || e.kind.startsWith("piopio.")) ? data.text : contentText(model[0]!.content as string | PiContentBlock[]);
		out.push({ model: structuredClone(model) as Portable["model"], ...(text !== undefined ? { text } : {}) });
	}
	return out;
}

/** Appends the messages to a conversation, in one commit with the caller's other changes. */
export async function importInto(tx: Tx, conversationId: ConversationId, entries: readonly Portable[], from: { title: string }): Promise<void> {
	for (const e of entries) {
		await tx.appendEntry(conversationId, { kind: IMPORTED_ENTRY, data: { from: from.title, ...(e.text !== undefined ? { text: e.text } : {}) }, model: e.model as never });
	}
}
