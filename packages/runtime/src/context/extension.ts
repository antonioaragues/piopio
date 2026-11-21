/**
 * The context guards for pi-durable conversations (chats and agents): the clock, the repeated-call nudge and the
 * head-and-tail trim of oversized results. Build sessions get the same through a pi extension (engine/src/tools/guards.ts).
 */
import { defineExtension, GenerationTask, hook, ToolTask, type Extension, type ToolExecutionResult } from "@earendil-works/pi-durable";
import { localZone, stampMessages } from "./clock.js";
import { remindRepeats } from "./repeats.js";
import { keepEnds } from "./spill.js";

export const CONTEXT_EXTENSION = "piopio-context";

export type ContextGuardOptions = {
	/** The user's time zone, read at each request (an agent's own, else the Mac's). */
	tz?: () => string;
};

/** The model's messages as the guards change them, or the same array. */
export function guardMessages<M extends { role: string; timestamp?: number; content?: unknown; toolCallId?: string }>(messages: readonly M[], tz: string): M[] {
	return remindRepeats(stampMessages(messages, tz));
}

/**
 * The model's reasoning from turns before the newest message, left out (kept within the turn, where tool calls need it).
 * Sent back, an old turn's reasoning was believed over what changed since: Pinpin's "there's no automation tool in this
 * list", written while that switch was off, came back each turn and outweighed the tool it now had. DeepSeek asks for
 * this, and Anthropic drops earlier turns' thinking anyway. An answer that is only reasoning keeps it.
 */
export function dropEarlierReasoning<M extends { role: string; content?: unknown }>(messages: readonly M[]): M[] {
	const lastUser = messages.map((m) => m.role).lastIndexOf("user");
	let changed = false;
	const out = messages.map((m, i) => {
		if (i > lastUser || m.role !== "assistant" || !Array.isArray(m.content)) return m;
		const kept = (m.content as { type: string }[]).filter((c) => c.type !== "thinking");
		if (kept.length === m.content.length || kept.length === 0) return m;
		changed = true;
		return { ...m, content: kept };
	});
	return changed ? out : (messages as M[]);
}

/** A result's text over the budget, with its two ends kept. */
export function trimResult(result: ToolExecutionResult): ToolExecutionResult | undefined {
	const output = result.output;
	if (!output?.length) return undefined;
	const texts = output.filter((c) => c.type === "text");
	if (texts.length === 0) return undefined;
	const joined = texts.map((c) => (c as { text: string }).text).join("");
	const kept = keepEnds(joined);
	if (!kept.cut) return undefined;
	const others = output.filter((c) => c.type !== "text");
	return { ...result, output: [{ type: "text", text: kept.text }, ...others] };
}

export function contextGuardsExtension(options: ContextGuardOptions = {}): Extension {
	const tz = options.tz ?? localZone;
	return defineExtension({
		name: CONTEXT_EXTENSION,
		hooks: [
			hook(GenerationTask, {
				beforeRequest: (request) => {
					const messages = guardMessages(request.messages as never[], tz());
					return messages === (request.messages as unknown) ? undefined : { messages };
				},
			}),
			hook(ToolTask, { afterTool: (_call, result) => trimResult(result) }),
		],
	}) as unknown as Extension;
}
