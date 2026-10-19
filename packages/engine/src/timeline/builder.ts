/**
 * Runtime-neutral timeline model. Adapters (pi SDK, pi-durable) translate upstream events into
 * calls on this builder. It keeps the current items and collects SessionEvents until flush().
 */
import type { AssistantItem, AssistantPart, AttachmentInfo, BranchInfo, SessionEvent, SessionState, Snapshot, TimelineItem, ToolItem, Usage, ContainerRef, UserItem } from "@piopio/protocol";
import { describeModelError } from "./errors.js";

/** Minimal structural views of pi-ai messages (avoid coupling to upstream unions). */
export type PiContentBlock =
	| { type: "text"; text: string }
	| { type: "thinking"; thinking: string; redacted?: boolean }
	| { type: "toolCall"; id: string; name: string; arguments: unknown }
	| { type: "image"; mimeType?: string };
export type PiUsage = { input: number; output: number; cacheRead: number; cacheWrite: number; cost?: { total?: number } };
export type PiMessage =
	| { role: "user"; content: string | PiContentBlock[]; timestamp?: number }
	| { role: "assistant"; content: PiContentBlock[]; provider?: string; model?: string; usage?: PiUsage; stopReason?: string; errorMessage?: string; timestamp?: number }
	| { role: "toolResult"; toolCallId: string; toolName: string; content: PiContentBlock[]; isError?: boolean; timestamp?: number }
	| { role: string; [key: string]: unknown };

export const emptyUsage = (): Usage => ({ inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, costUsd: 0 });

export function toUsage(u: PiUsage | undefined): Usage | undefined {
	if (!u) return undefined;
	return { inputTokens: u.input ?? 0, outputTokens: u.output ?? 0, cacheReadTokens: u.cacheRead ?? 0, cacheWriteTokens: u.cacheWrite ?? 0, costUsd: u.cost?.total ?? 0 };
}

export function contentText(content: string | PiContentBlock[] | undefined): string {
	if (content === undefined) return "";
	if (typeof content === "string") return content;
	return content
		.map((b) => (b.type === "text" ? b.text : b.type === "image" ? "[image]" : ""))
		.filter((s) => s.length > 0)
		.join("\n");
}

const iso = (ms?: number) => new Date(ms ?? Date.now()).toISOString();

function assistantStatus(stopReason: string | undefined): AssistantItem["status"] {
	if (stopReason === "error") return "error";
	if (stopReason === "aborted") return "aborted";
	return "done";
}

function partsFrom(content: PiContentBlock[]): AssistantPart[] {
	const parts: AssistantPart[] = [];
	for (const b of content) {
		if (b.type === "text") parts.push({ type: "text", text: b.text });
		else if (b.type === "thinking") parts.push({ type: "thinking", text: b.thinking, ...(b.redacted ? { redacted: true } : {}) });
	}
	return parts;
}

export class TimelineBuilder {
	private items: TimelineItem[] = [];
	private index = new Map<string, number>();
	private pending: SessionEvent[] = [];
	private streaming?: { id: string; partByContentIndex: Map<number, number> };
	private state: SessionState = { status: "idle", queue: [], usage: emptyUsage() };

	constructor(readonly ref: ContainerRef) {}

	snapshot(): Snapshot {
		return structuredClone({ ref: this.ref, items: this.items, state: this.state });
	}

	/** Returns and clears the events collected since the last flush. */
	flush(): SessionEvent[] {
		const out = this.pending;
		this.pending = [];
		return out;
	}

	get status() {
		return this.state.status;
	}

	// ── Whole-state ────────────────────────────────────────────────────────

	/** Rebuilds items from a transcript. `idOf(i, msg)` supplies stable ids. Emits `resnapshot`. */
	reset(messages: readonly PiMessage[], idOf: (index: number, message: PiMessage) => string, emit = true): void {
		this.items = [];
		this.index.clear();
		this.streaming = undefined;
		this.state.usage = emptyUsage();
		const tools = new Map<string, ToolItem>();
		messages.forEach((m, i) => {
			const id = idOf(i, m);
			if (m.role === "user") {
				const attachments = (m as { attachments?: AttachmentInfo[] }).attachments;
				this.push({ kind: "user", id, at: iso(m.timestamp as number | undefined), text: contentText(m.content as string | PiContentBlock[]), ...(attachments?.length ? { attachments } : {}) });
			} else if (m.role === "assistant") {
				const a = m as Extract<PiMessage, { role: "assistant" }>;
				this.push(this.assistantItem(id, a));
				this.addUsage(a.usage);
				for (const b of a.content) {
					if (b.type !== "toolCall") continue;
					const t: ToolItem = { kind: "tool", id: `tool:${b.id}`, at: iso(a.timestamp), callId: b.id, tool: b.name, args: b.arguments, status: "interrupted" };
					tools.set(b.id, t);
					this.push(t);
				}
			} else if (m.role === "toolResult") {
				const r = m as Extract<PiMessage, { role: "toolResult" }>;
				const t = tools.get(r.toolCallId);
				if (t) {
					t.status = r.isError ? "error" : "done";
					t.output = contentText(r.content);
				}
			}
		});
		if (emit) this.pending.push({ type: "resnapshot", snapshot: this.snapshot() });
	}

	/** Sets the branch switcher info of user items (missing ids lose theirs). Emits updates for changed items. */
	annotateBranches(branches: ReadonlyMap<string, BranchInfo>, emit = true): void {
		for (const item of this.items) {
			if (item.kind !== "user") continue;
			const next = branches.get(item.id);
			if (JSON.stringify(next) === JSON.stringify((item as UserItem).branch)) continue;
			if (next) (item as UserItem).branch = next;
			else delete (item as UserItem).branch;
			if (emit) this.pending.push({ type: "item.updated", item: structuredClone(item) });
		}
	}

	/** Items in order (read-only use). */
	get currentItems(): readonly TimelineItem[] {
		return this.items;
	}

	setState(patch: Partial<SessionState>): void {
		this.state = { ...this.state, ...patch };
		this.pending.push({ type: "state", state: structuredClone(this.state) });
	}

	// ── Incremental ────────────────────────────────────────────────────────

	user(id: string, text: string, at?: number, attachments?: AttachmentInfo[]): void {
		if (this.index.has(id)) return;
		const item: TimelineItem = { kind: "user", id, at: iso(at), text, ...(attachments?.length ? { attachments } : {}) };
		this.push(item);
		this.pending.push({ type: "item.added", item: structuredClone(item) });
	}

	system(id: string, level: "info" | "warn" | "error", text: string): void {
		const item: TimelineItem = { kind: "system", id, at: iso(), level, text };
		this.push(item);
		this.pending.push({ type: "item.added", item });
	}

	compaction(id: string, summary: string): void {
		const item: TimelineItem = { kind: "compaction", id, at: iso(), summary };
		this.push(item);
		this.pending.push({ type: "item.added", item });
	}

	assistantStart(id: string, model?: string): void {
		const item: AssistantItem = { kind: "assistant", id, at: iso(), parts: [], status: "streaming", ...(model ? { model } : {}) };
		this.push(item);
		this.streaming = { id, partByContentIndex: new Map() };
		this.pending.push({ type: "item.added", item: structuredClone(item) });
	}

	/** Starts (if needed) the part for `contentIndex` and appends `delta`. */
	assistantDelta(contentIndex: number, partType: "text" | "thinking", delta: string): void {
		const s = this.streaming;
		if (!s) return;
		const item = this.get(s.id) as AssistantItem | undefined;
		if (!item) return;
		let partIndex = s.partByContentIndex.get(contentIndex);
		if (partIndex === undefined) {
			partIndex = item.parts.length;
			item.parts.push({ type: partType, text: "" });
			s.partByContentIndex.set(contentIndex, partIndex);
		}
		const part = item.parts[partIndex];
		if (!part) return;
		part.text += delta;
		if (delta.length > 0) this.pending.push({ type: "item.delta", itemId: s.id, partIndex, partType, textDelta: delta });
	}

	/** Completes the streaming answer with its authoritative message. `finalId` swaps a provisional id. */
	assistantEnd(message: Extract<PiMessage, { role: "assistant" }>, finalId?: string): void {
		const s = this.streaming;
		this.streaming = undefined;
		const id = s?.id ?? finalId ?? `a:${Date.now()}`;
		const item = this.assistantItem(finalId ?? id, message);
		this.addUsage(message.usage);
		const at = this.index.get(id);
		if (at === undefined) {
			this.push(item);
			this.pending.push({ type: "item.added", item: structuredClone(item) });
		} else if (finalId && finalId !== id) {
			item.at = this.items[at]!.at;
			this.items[at] = item;
			this.index.delete(id);
			this.index.set(finalId, at);
			this.pending.push({ type: "item.replaced", oldId: id, item: structuredClone(item) });
		} else {
			item.at = this.items[at]!.at;
			this.items[at] = item;
			this.pending.push({ type: "item.updated", item: structuredClone(item) });
		}
		this.pending.push({ type: "state", state: structuredClone(this.state) });
	}

	toolStart(callId: string, tool: string, args: unknown, parentCallId?: string): void {
		const id = `tool:${callId}`;
		const existing = this.get(id) as ToolItem | undefined;
		if (existing) {
			existing.status = "running";
			existing.args = args;
			this.pending.push({ type: "item.updated", item: structuredClone(existing) });
			return;
		}
		const item: ToolItem = { kind: "tool", id, at: iso(), callId, tool, args, status: "running", ...(parentCallId ? { parentCallId } : {}) };
		this.push(item);
		this.pending.push({ type: "item.added", item: structuredClone(item) });
	}

	toolOutput(callId: string, update: { set: string } | { trimStart?: number; append?: string }): void {
		const item = this.get(`tool:${callId}`) as ToolItem | undefined;
		if (!item) return;
		let out = item.output ?? "";
		if ("set" in update) out = update.set;
		else {
			if (update.trimStart) out = out.slice(update.trimStart);
			if (update.append) out += update.append;
		}
		item.output = out;
		this.pending.push({ type: "item.updated", item: structuredClone(item) });
	}

	toolEnd(callId: string, output: string | undefined, isError: boolean, durationMs?: number): void {
		const item = this.get(`tool:${callId}`) as ToolItem | undefined;
		if (!item) return;
		item.status = isError ? "error" : "done";
		if (output !== undefined) item.output = output;
		if (durationMs !== undefined) item.durationMs = durationMs;
		this.pending.push({ type: "item.updated", item: structuredClone(item) });
	}

	// ── Internals ──────────────────────────────────────────────────────────

	private assistantItem(id: string, m: Extract<PiMessage, { role: "assistant" }>): AssistantItem {
		const usage = toUsage(m.usage);
		return {
			kind: "assistant",
			id,
			at: iso(m.timestamp),
			parts: partsFrom(m.content),
			status: assistantStatus(m.stopReason),
			...(m.model ? { model: m.provider ? `${m.provider}/${m.model}` : m.model } : {}),
			...(usage ? { usage } : {}),
			...(m.stopReason === "error" || m.errorMessage ? errorFields(m.errorMessage) : {}),
		};
	}

	private addUsage(u: PiUsage | undefined): void {
		const add = toUsage(u);
		if (!add) return;
		const cur = this.state.usage;
		this.state.usage = {
			inputTokens: cur.inputTokens + add.inputTokens,
			outputTokens: cur.outputTokens + add.outputTokens,
			cacheReadTokens: cur.cacheReadTokens + add.cacheReadTokens,
			cacheWriteTokens: cur.cacheWriteTokens + add.cacheWriteTokens,
			costUsd: cur.costUsd + add.costUsd,
		};
	}

	private push(item: TimelineItem): void {
		this.index.set(item.id, this.items.length);
		this.items.push(item);
	}

	private get(id: string): TimelineItem | undefined {
		const i = this.index.get(id);
		return i === undefined ? undefined : this.items[i];
	}
}

function errorFields(raw: string | undefined): Pick<AssistantItem, "error" | "errorKind" | "errorDetail"> {
	const { kind, message } = describeModelError(raw);
	return { error: message, errorKind: kind, ...(raw ? { errorDetail: raw } : {}) };
}
