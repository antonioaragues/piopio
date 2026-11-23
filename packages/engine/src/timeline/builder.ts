/**
 * Runtime-neutral timeline model. Adapters (pi SDK, pi-durable) translate upstream events into
 * calls on this builder. It keeps the current items and collects SessionEvents until flush().
 */
import type { AssistantItem, AssistantPart, AttachmentInfo, BranchInfo, SessionEvent, SessionState, Snapshot, TimelineItem, ToolDetails, ToolItem, Usage, ContainerRef, UserItem } from "@piopio/protocol";
import { describeModelError } from "./errors.js";
import { endDetails, startDetails, type PiToolResult } from "./tool-details.js";
import { DENIED_PREFIX } from "@piopio/pi-extensions";

/** Minimal structural views of pi-ai messages (avoid coupling to upstream unions). */
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

/** Keeps a tool result's images where the app can show them; returns each one's `stored` path (attachment-files.ts). */
export type ToolImageKeeper = (callId: string, images: readonly { data: string; mimeType: string }[]) => (string | undefined)[];

export class TimelineBuilder {
	/** Where tool images go; without it they show only as "[image]" in the output. */
	keepImages?: ToolImageKeeper;
	/** Where a handed-over file is now (a branched chat's copy of its folder); paths it doesn't know stay as they are. */
	relocate?: (path: string) => string;
	private items: TimelineItem[] = [];
	private index = new Map<string, number>();
	private pending: SessionEvent[] = [];
	private streaming?: { id: string; partByContentIndex: Map<number, number>; thinkingFrom: number | undefined; thinkingTo: number | undefined };
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
		const nested = new Map<string, ToolItem[]>();
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
					const details = startDetails(b.name, b.arguments);
					const t: ToolItem = { kind: "tool", id: `tool:${b.id}`, at: iso(a.timestamp), callId: b.id, tool: b.name, args: b.arguments, status: "interrupted", ...(details ? { details } : {}) };
					tools.set(b.id, t);
					this.push(t);
				}
			} else if (m.role === "custom" && (m as { display?: boolean }).display) {
				this.push({ kind: "system", id, at: iso(m.timestamp as number | undefined), level: "info", text: customText(m) });
			} else if (m.role === "toolResult") {
				const r = m as Extract<PiMessage, { role: "toolResult" }>;
				const t = tools.get(r.toolCallId);
				if (t) {
					t.output = contentText(r.content);
					this.addImages(t, r.content);
					t.status = r.isError ? failedStatus(t.output) : "done";
					const details = endDetails(t.tool, t.args, { details: r.details }, t.output, Boolean(r.isError));
					if (details) t.details = this.relocated(details);
					this.addTaskCost(t);
					const inner = nestedItems(t, (r as { nestedCalls?: unknown }).nestedCalls);
					if (inner.length) nested.set(t.id, inner);
				}
			}
		});
		// The calls a tool made while it ran (a codemode script's), as live: their own items, right after it.
		if (nested.size) this.setItems(this.items.flatMap((item) => [item, ...(nested.get(item.id) ?? [])]));
		// The checklist is the latest todo call on this branch.
		const lastTodo = [...tools.values()].reverse().find((t) => t.details?.type === "todos");
		if (lastTodo?.details?.type === "todos") this.state.todos = lastTodo.details.items;
		else delete this.state.todos;
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

	/** Replaces the items (after rearranging them outside the event flow); usage and state stay. Emits nothing. */
	setItems(items: TimelineItem[]): void {
		this.items = items;
		this.index.clear();
		items.forEach((it, i) => this.index.set(it.id, i));
	}

	setState(patch: Partial<SessionState>): void {
		this.state = { ...this.state, ...patch };
		this.pending.push({ type: "state", state: structuredClone(this.state) });
	}

	/**
	 * A cost reported after the answer it belongs to (Claude Code's turn result): onto the latest answer, so it shows
	 * where the request was (the usage ledger reads it there), and onto the total.
	 */
	chargeLastAnswer(usd: number): void {
		const item = this.items.findLast((i): i is AssistantItem => i.kind === "assistant");
		if (item) {
			const u = item.usage ?? emptyUsage();
			item.usage = { ...u, costUsd: u.costUsd + usd };
			this.pending.push({ type: "item.updated", item: structuredClone(item) });
		}
		this.setState({ usage: { ...this.state.usage, costUsd: this.state.usage.costUsd + usd } });
	}

	// ── Incremental ────────────────────────────────────────────────────────

	/** A message of yours shown as you typed it (a `/command` pi expanded before sending). */
	setUserText(id: string, text: string, emit = true): void {
		const at = this.index.get(id);
		const item = at === undefined ? undefined : this.items[at];
		if (!item || item.kind !== "user" || item.text === text) return;
		item.text = text;
		if (emit) this.pending.push({ type: "item.updated", item: structuredClone(item) });
	}

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
		this.streaming = { id, partByContentIndex: new Map(), thinkingFrom: undefined, thinkingTo: undefined };
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
		// Thinking time: from its first delta to the first delta of anything else.
		if (partType === "thinking") s.thinkingFrom ??= Date.now();
		else if (s.thinkingFrom !== undefined) s.thinkingTo ??= Date.now();
		if (delta.length > 0) this.pending.push({ type: "item.delta", itemId: s.id, partIndex, partType, textDelta: delta });
	}

	/** Completes the streaming answer with its authoritative message. `finalId` swaps a provisional id. */
	assistantEnd(message: Extract<PiMessage, { role: "assistant" }>, finalId?: string): void {
		const s = this.streaming;
		this.streaming = undefined;
		const id = s?.id ?? finalId ?? `a:${Date.now()}`;
		const item = this.assistantItem(finalId ?? id, message);
		if (s?.thinkingFrom !== undefined) item.thinkingMs = (s.thinkingTo ?? Date.now()) - s.thinkingFrom;
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
			const details = startDetails(tool, args);
			if (details) existing.details = details;
			this.pending.push({ type: "item.updated", item: structuredClone(existing) });
			return;
		}
		const details = startDetails(tool, args);
		const item: ToolItem = { kind: "tool", id, at: iso(), callId, tool, args, status: "running", ...(details ? { details } : {}), ...(parentCallId ? { parentCallId } : {}) };
		if (details?.type === "todos") this.setState({ todos: details.items });
		this.push(item);
		this.pending.push({ type: "item.added", item: structuredClone(item) });
	}

	/** Marks a tool waiting for approval, or running again once answered. */
	toolStatus(callId: string, status: "pending_approval" | "running"): void {
		const item = this.get(`tool:${callId}`) as ToolItem | undefined;
		if (!item || item.status === status || (status === "running" && item.status !== "pending_approval")) return;
		item.status = status;
		this.pending.push({ type: "item.updated", item: structuredClone(item) });
	}

	/** Auto review let this call run without asking: its reason, shown on the card. */
	toolReview(callId: string, reason: string, emit = true): void {
		const item = this.get(`tool:${callId}`) as ToolItem | undefined;
		if (!item || item.review === reason) return;
		item.review = reason;
		if (emit) this.pending.push({ type: "item.updated", item: structuredClone(item) });
	}

	/** A subagent's child session, known once it starts (shown on the task card, openable). */
	toolSession(callId: string, sessionId: string): void {
		const item = this.get(`tool:${callId}`) as ToolItem | undefined;
		if (!item || (item.details?.type === "task" && item.details.sessionId === sessionId)) return;
		item.details = { type: "task", sessionId };
		this.pending.push({ type: "item.updated", item: structuredClone(item) });
	}

	/** A finished subagent's cost counts toward this session (spec: children count toward the parent's cost). */
	private addTaskCost(item: ToolItem): boolean {
		if (item.details?.type !== "task" || !item.details.costUsd) return false;
		this.state.usage.costUsd += item.details.costUsd;
		return true;
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

	toolEnd(callId: string, output: string | undefined, isError: boolean, durationMs?: number, result?: PiToolResult & { content?: PiContentBlock[] }): void {
		const item = this.get(`tool:${callId}`) as ToolItem | undefined;
		if (!item) return;
		if (output !== undefined) item.output = output;
		this.addImages(item, result?.content);
		item.status = isError ? failedStatus(item.output) : "done";
		const details = endDetails(item.tool, item.args, result, item.output, isError);
		if (details) item.details = this.relocated(details);
		if (this.addTaskCost(item)) this.pending.push({ type: "state", state: structuredClone(this.state) });
		if (durationMs !== undefined) item.durationMs = durationMs;
		this.pending.push({ type: "item.updated", item: structuredClone(item) });
	}

	// ── Internals ──────────────────────────────────────────────────────────

	private relocated(details: ToolDetails): ToolDetails {
		const move = this.relocate;
		return move && details.type === "files" ? { ...details, files: details.files.map((f) => ({ ...f, path: move(f.path) })) } : details;
	}

	/** A tool's images (a screenshot it read), kept so the activity line can show them; named after the file read. */
	private addImages(item: ToolItem, content: PiContentBlock[] | undefined): void {
		if (!this.keepImages || !content) return;
		const blocks = content.flatMap((b) => (b.type === "image" && typeof b.data === "string" && b.data.length > 0 ? [{ data: b.data, mimeType: b.mimeType ?? "image/png" }] : []));
		if (blocks.length === 0) return;
		const stored = this.keepImages(item.callId, blocks);
		const path = (item.args as { path?: unknown } | undefined)?.path;
		const name = typeof path === "string" && path.length > 0 ? (path.split("/").pop() ?? path) : "Image";
		const images = blocks.flatMap((b, i) => (stored[i] ? [{ name, kind: "image" as const, mimeType: b.mimeType, stored: stored[i] }] : []));
		if (images.length > 0) item.images = images;
	}

	private assistantItem(id: string, m: Extract<PiMessage, { role: "assistant" }>): AssistantItem {
		const usage = toUsage(m.usage);
		const item: AssistantItem = {
			kind: "assistant",
			id,
			at: iso(m.timestamp),
			parts: partsFrom(m.content),
			status: assistantStatus(m.stopReason),
			...(m.model ? { model: m.provider ? `${m.provider}/${m.model}` : m.model } : {}),
			...(usage ? { usage } : {}),
			...(m.stopReason === "error" || m.errorMessage ? errorFields(m.errorMessage, m.provider) : {}),
		};
		return item;
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

	/**
	 * Adds a checkpoint before the item `beforeId` (the change it precedes), or at the end.
	 * Emits item.added with `before` so clients put it in the same place.
	 */
	checkpoint(item: Extract<TimelineItem, { kind: "checkpoint" }>, beforeId?: string, emit = true): void {
		this.insert(item, beforeId, emit);
	}

	/** Adds an item before `beforeId`, or at the end (items that don't come from the transcript's messages). */
	insert(item: TimelineItem, beforeId?: string, emit = true): void {
		if (this.index.has(item.id)) return;
		const at = beforeId ? this.index.get(beforeId) : undefined;
		if (at === undefined) {
			this.push(item);
			if (emit) this.pending.push({ type: "item.added", item: structuredClone(item) });
			return;
		}
		this.items.splice(at, 0, item);
		this.index.clear();
		this.items.forEach((it, i) => this.index.set(it.id, i));
		if (emit) this.pending.push({ type: "item.added", item: structuredClone(item), before: beforeId! });
	}

	/** Sends the current items as a fresh snapshot (after rebuilding them outside the event flow). */
	resnapshot(): void {
		this.pending.push({ type: "resnapshot", snapshot: this.snapshot() });
	}

	/** The first item newer than `at` (to place something by time). */
	firstAfter(at: string): string | undefined {
		return this.items.find((i) => i.at > at)?.id;
	}

	/** The checkpoints, oldest first. */
	checkpoints(): Extract<TimelineItem, { kind: "checkpoint" }>[] {
		return this.items.filter((i): i is Extract<TimelineItem, { kind: "checkpoint" }> => i.kind === "checkpoint");
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

function errorFields(raw: string | undefined, provider: string | undefined): Pick<AssistantItem, "error" | "errorKind" | "errorDetail"> {
	const { kind, message } = describeModelError(raw, provider);
	return { error: message, errorKind: kind, ...(raw ? { errorDetail: raw } : {}) };
}

/** What a displayed custom message (e.g. Piopio's restore note) shows: its `details.summary`, else its text. */
export function customText(m: PiMessage): string {
	const summary = (m as { details?: { summary?: unknown } }).details?.summary;
	return typeof summary === "string" ? summary : contentText((m as { content?: string | PiContentBlock[] }).content);
}

/**
 * The calls a tool made while it ran, from pi's record on its result (`nestedCalls`), as the items they were live.
 * The record keeps no output, and drops the arguments of a call over 8 KB (pi's limit); such a call comes back with none.
 */
function nestedItems(parent: ToolItem, record: unknown): ToolItem[] {
	const calls = (record as { calls?: unknown } | undefined)?.calls;
	if (!Array.isArray(calls)) return [];
	return calls.flatMap((c: { id?: unknown; name?: unknown; status?: unknown; arguments?: unknown; error?: unknown; durationMs?: unknown }) => {
		if (typeof c?.id !== "string" || typeof c.name !== "string") return [];
		const args = c.arguments ?? {};
		const details = startDetails(c.name, args);
		const status: ToolItem["status"] = c.status === "ok" ? "done" : c.status === "error" ? "error" : "interrupted";
		return [{
			kind: "tool", id: `tool:${c.id}`, at: parent.at, callId: c.id, tool: c.name, args, status, parentCallId: parent.callId,
			...(typeof c.error === "string" ? { output: c.error } : {}),
			...(typeof c.durationMs === "number" ? { durationMs: c.durationMs } : {}),
			...(details ? { details } : {}),
		} satisfies ToolItem];
	});
}

/** A failed call that the user denied, or that a stop cut short, isn't an error of the tool. */
function failedStatus(output: string | undefined): ToolItem["status"] {
	if (output?.startsWith(DENIED_PREFIX)) return "denied";
	if (output === "Operation aborted") return "interrupted";
	return "error";
}
