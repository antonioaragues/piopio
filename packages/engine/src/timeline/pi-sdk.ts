/** Maps pi-coding-agent `AgentSessionEvent`s onto the timeline builder. */
import { sdkUser, type ContentBlock } from "../input.js";
import { contentText, customText, type PiContentBlock, type PiMessage, type TimelineBuilder } from "@piopio/runtime";

/** A session's messages for `TimelineBuilder.reset`: each user message as its words, with its files as chips. */
export function sdkMessages(messages: readonly PiMessage[]): PiMessage[] {
	return messages.map((m) => {
		if (m.role !== "user" || typeof m.content === "string") return m;
		const { text, attachments } = sdkUser(m.content as unknown as ContentBlock[]);
		return { ...m, content: text, ...(attachments.length ? { attachments } : {}) } as PiMessage;
	});
}

type AnyEvent = { type: string; [key: string]: unknown };

/**
 * pi SDK messages carry no ids, so items are numbered by transcript position (`m<index>`),
 * which matches what `reset(session.messages)` produces on the next snapshot.
 */
export class SdkEventMapper {
	private nextIndex: number;
	constructor(
		private readonly builder: TimelineBuilder,
		startIndex: number,
	) {
		this.nextIndex = startIndex;
	}

	static idOf = (index: number) => `m${index}`;

	apply(event: AnyEvent): void {
		const b = this.builder;
		switch (event.type) {
			case "agent_start":
				if (b.status !== "running") b.setState({ status: "running" });
				break;
			case "agent_settled":
				b.setState({ status: "idle" });
				break;
			case "message_start": {
				const message = event.message as PiMessage;
				const id = SdkEventMapper.idOf(this.nextIndex++);
				if (message.role === "user") {
					const { text, attachments } = sdkUser(message.content as unknown as ContentBlock[]);
					b.user(id, text, message.timestamp as number | undefined, attachments);
				}
				else if (message.role === "assistant") b.assistantStart(id, (message as { model?: string }).model);
				else if (message.role === "custom" && (message as { display?: boolean }).display) b.system(id, "info", customText(message));
				break;
			}
			case "entry_appended": {
				// A message an extension added at a boundary (the project's check, 05-build "Diagnostics") comes as an entry,
				// not a message_start; it is a message of the transcript all the same.
				const entry = event.entry as { type?: string; display?: boolean; content?: unknown; details?: unknown; timestamp?: string } | undefined;
				if (entry?.type !== "custom_message") break;
				const id = SdkEventMapper.idOf(this.nextIndex++);
				if (entry.display) b.system(id, "info", customText({ role: "custom", content: entry.content, details: entry.details } as unknown as PiMessage));
				break;
			}
			case "message_update": {
				const e = event.assistantMessageEvent as { type: string; contentIndex?: number; delta?: string };
				if (e.type === "text_delta") b.assistantDelta(e.contentIndex ?? 0, "text", e.delta ?? "");
				else if (e.type === "thinking_delta") b.assistantDelta(e.contentIndex ?? 0, "thinking", e.delta ?? "");
				break;
			}
			case "message_end": {
				const message = event.message as PiMessage;
				if (message.role === "assistant") b.assistantEnd(message as Extract<PiMessage, { role: "assistant" }>);
				break;
			}
			case "tool_execution_start":
				b.toolStart(event.toolCallId as string, event.toolName as string, event.args, event.parentToolCallId as string | undefined);
				break;
			case "tool_execution_update": {
				const partial = event.partialResult as { content?: PiContentBlock[]; details?: { sessionId?: unknown } } | undefined;
				if (partial?.content) b.toolOutput(event.toolCallId as string, { set: contentText(partial.content) });
				if (event.toolName === "task" && typeof partial?.details?.sessionId === "string" && partial.details.sessionId) b.toolSession(event.toolCallId as string, partial.details.sessionId);
				break;
			}
			case "tool_execution_end": {
				const result = event.result as { content?: PiContentBlock[]; details?: unknown; structuredContent?: unknown } | undefined;
				b.toolEnd(event.toolCallId as string, result?.content ? contentText(result.content) : undefined, Boolean(event.isError), event.durationMs as number | undefined, result);
				break;
			}
			case "queue_update": {
				const steering = (event.steering as string[] | undefined) ?? [];
				const followUp = (event.followUp as string[] | undefined) ?? [];
				b.setState({
					queue: [
						...steering.map((text, i) => ({ id: `steer:${i}`, mode: "steer" as const, text })),
						...followUp.map((text, i) => ({ id: `follow:${i}`, mode: "followUp" as const, text })),
					],
				});
				break;
			}
			case "compaction_end": {
				const result = event.result as { summary?: string } | undefined;
				if (result?.summary) b.compaction(`compaction:${Date.now()}`, result.summary);
				else if (event.errorMessage) b.system(`sys:${Date.now()}`, "warn", `Compaction failed: ${String(event.errorMessage)}`);
				break;
			}
			case "auto_retry_start":
				b.system(`sys:${Date.now()}`, "warn", `Retrying (attempt ${String(event.attempt)}): ${String(event.errorMessage)}`);
				break;
			case "auto_retry_end":
				if (event.success === false) b.system(`sys:${Date.now()}`, "error", String(event.finalError ?? "Request failed"));
				break;
		}
	}
}
