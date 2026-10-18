/** Maps pi-durable `watchEvents` agent events onto the timeline builder. */
import { contentText, type PiContentBlock, type PiMessage, type TimelineBuilder } from "./builder.js";

type AnyEvent = { type: string; [key: string]: unknown };
type Entry = { id: string | number; kind: string; model?: PiMessage[]; data?: unknown };

/** Flattens committed entries into messages, keeping the entry id for each. */
export function messagesFromEntries(entries: readonly Entry[]): { messages: PiMessage[]; ids: string[] } {
	const messages: PiMessage[] = [];
	const ids: string[] = [];
	for (const e of entries) {
		if (e.kind === "pi.compaction") continue;
		for (const [i, m] of (e.model ?? []).entries()) {
			if (m.role !== "user" && m.role !== "assistant" && m.role !== "toolResult") continue;
			messages.push(m);
			ids.push(i === 0 ? String(e.id) : `${e.id}:${i}`);
		}
	}
	return { messages, ids };
}

export class DurableEventMapper {
	private provisional = 0;
	constructor(private readonly builder: TimelineBuilder) {}

	applySnapshot(event: AnyEvent, emit: boolean): void {
		const { messages, ids } = messagesFromEntries((event.entries as Entry[]) ?? []);
		this.builder.reset(messages, (i) => ids[i]!, emit);
		const inbox = (event.inbox as { id: string; mode: string }[] | undefined) ?? [];
		this.builder.setState({
			status: event.run ? "running" : "idle",
			queue: inbox.map((q) => ({ id: q.id, mode: q.mode === "steer" ? "steer" : "followUp" })),
		});
		const partial = (event.generation as { message?: PiMessage } | undefined)?.message;
		if (partial && partial.role === "assistant") {
			// Resume an in-flight answer: replay its blocks as deltas on a provisional item.
			this.builder.assistantStart(`gen:${++this.provisional}`, (partial as { model?: string }).model);
			(partial.content as PiContentBlock[]).forEach((block, i) => {
				if (block.type === "text") this.builder.assistantDelta(i, "text", block.text);
				else if (block.type === "thinking") this.builder.assistantDelta(i, "thinking", block.thinking);
			});
		}
	}

	apply(event: AnyEvent): void {
		const b = this.builder;
		switch (event.type) {
			case "snapshot":
				this.applySnapshot(event, true);
				break;
			case "run_start":
				b.setState({ status: "running" });
				break;
			case "run_end":
				b.setState({ status: "idle" });
				break;
			case "message_start": {
				const message = event.message as PiMessage;
				if (message.role === "assistant") b.assistantStart(`gen:${++this.provisional}`, (message as { model?: string }).model);
				break;
			}
			case "message_update": {
				for (const change of (event.changes as { type: string; contentIndex: number; delta?: string; block?: PiContentBlock }[]) ?? []) {
					if (change.type === "text_delta") b.assistantDelta(change.contentIndex, "text", change.delta ?? "");
					else if (change.type === "thinking_delta") b.assistantDelta(change.contentIndex, "thinking", change.delta ?? "");
					else if (change.type === "text_start" && change.block?.type === "text") b.assistantDelta(change.contentIndex, "text", change.block.text);
					else if (change.type === "thinking_start" && change.block?.type === "thinking") b.assistantDelta(change.contentIndex, "thinking", change.block.thinking);
				}
				break;
			}
			case "message_end": {
				const entry = event.entry as Entry;
				const message = entry.model?.[0];
				if (!message) break;
				if (message.role === "user") b.user(String(entry.id), contentText(message.content as string | PiContentBlock[]), message.timestamp as number | undefined);
				else if (message.role === "assistant") b.assistantEnd(message as Extract<PiMessage, { role: "assistant" }>, String(entry.id));
				break;
			}
			case "tool_execution_start":
				b.toolStart(event.toolCallId as string, event.toolName as string, event.args, event.parentToolCallId as string | undefined);
				break;
			case "tool_execution_update": {
				const output = event.output as { set: string } | { trimStart?: number; append?: string } | undefined;
				if (output) b.toolOutput(event.toolCallId as string, output);
				break;
			}
			case "tool_execution_end": {
				const result = (event.entry as Entry | undefined)?.model?.[0] as Extract<PiMessage, { role: "toolResult" }> | undefined;
				b.toolEnd(event.toolCallId as string, result ? contentText(result.content) : undefined, result?.isError ?? !result);
				break;
			}
			case "inbox_update": {
				const items = (event.items as { id: string; mode: string }[]) ?? [];
				b.setState({ queue: items.map((q) => ({ id: q.id, mode: q.mode === "steer" ? "steer" : "followUp" })) });
				break;
			}
			case "submission": {
				const record = event.record as { id: string; status: string; reason?: string; detail?: string };
				if (record.status === "unanswered") b.system(`sys:${record.id}`, "error", `Not answered (${record.reason ?? "unknown"})${record.detail ? `: ${record.detail}` : ""}`);
				break;
			}
			case "auto_retry_start":
				b.system(`sys:retry:${String(event.attempt)}:${Date.now()}`, "warn", `Retrying (attempt ${String(event.attempt)}): ${String(event.errorMessage)}`);
				break;
			case "task_failed":
				b.system(`sys:${String(event.taskId)}`, "error", `${String(event.kind)} failed: ${String(event.message)}`);
				break;
			case "compaction_end":
				if (event.error) b.system(`sys:${String(event.taskId)}`, "warn", `Compaction failed: ${String(event.error)}`);
				break;
			case "entry_appended": {
				const entry = event.entry as Entry & { data?: { summary?: string } };
				if (entry.kind === "pi.compaction" && entry.data?.summary) b.compaction(String(entry.id), entry.data.summary);
				break;
			}
		}
	}
}
