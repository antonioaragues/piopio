/**
 * Minimal structural views of pi-ai messages, as the timeline code reads them (they avoid coupling to pi's own
 * unions). Shared by the engine's and the cloud's timeline builders and by the pi-durable view mapper.
 */
export type PiContentBlock =
	| { type: "text"; text: string }
	| { type: "thinking"; thinking: string; redacted?: boolean }
	| { type: "toolCall"; id: string; name: string; arguments: unknown }
	| { type: "image"; mimeType?: string; data?: string };
export type PiUsage = { input: number; output: number; cacheRead: number; cacheWrite: number; cost?: { total?: number } };
export type PiMessage =
	| { role: "user"; content: string | PiContentBlock[]; timestamp?: number }
	| { role: "assistant"; content: PiContentBlock[]; provider?: string; model?: string; usage?: PiUsage; stopReason?: string; errorMessage?: string; timestamp?: number }
	| { role: "toolResult"; toolCallId: string; toolName: string; content: PiContentBlock[]; details?: unknown; isError?: boolean; timestamp?: number }
	| { role: string; [key: string]: unknown };

/** A message's content as text: its text blocks, with "[image]" where an image is. */
export function contentText(content: string | PiContentBlock[] | undefined): string {
	if (content === undefined) return "";
	if (typeof content === "string") return content;
	return content
		.map((b) => (b.type === "text" ? b.text : b.type === "image" ? "[image]" : ""))
		.filter((s) => s.length > 0)
		.join("\n");
}
