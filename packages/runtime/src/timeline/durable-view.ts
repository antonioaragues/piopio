/**
 * Maps a pi-durable conversation's state onto a timeline builder. pi-durable 1.5 dropped its event stream
 * (`watchEvents()`); a renderer watches the conversation view (`Conversation.watch()`) instead: a window over the
 * transcript plus `pi.live` (the answer being streamed, the tool round) and `pi.inbox`. Each new value is compared with
 * the last one to make the builder calls the events used to drive.
 *
 * One mapper for every host of an agent (the Mac's engine, the cloud's Durable Object): each brings its own builder,
 * which this only knows as `MapperBuilder`, and says what it draws itself (`ownItem`).
 */
import { RECALL_ENTRY } from "../agents/entries.js";
import { contentText, type PiContentBlock, type PiMessage } from "./messages.js";

const USER_ENTRY = "piopio.user";
/** `attachments`: as the host's builder takes them (the engine's attachment infos). */
type UserData = { text: string; attachments?: unknown };

/** What the mapper sets on the session's state. */
export type MapperState = { status?: "running" | "idle"; queue?: { id: string; mode: "steer" | "followUp"; text?: string }[] };

/**
 * The timeline builder as the mapper uses it. `I` is the host's item type; the mapper only reads an item's id and time,
 * and makes one kind itself (a compaction marker).
 */
export interface MapperBuilder<I extends { id: string; at: string } = { id: string; at: string }> {
	reset(messages: readonly PiMessage[], idOf: (index: number, message: PiMessage) => string, emit?: boolean): void;
	/** Sends the current items as a fresh snapshot. */
	resnapshot(): void;
	readonly currentItems: readonly I[];
	/** Adds an item before `beforeId`, or at the end. */
	insert(item: I, beforeId?: string, emit?: boolean): void;
	/** Adds an item where its time puts it (a host's own items). */
	place?(item: I, emit?: boolean): void;
	user(id: string, text: string, timestamp?: number, attachments?: never): void;
	assistantStart(id: string, model?: string): void;
	assistantDelta(index: number, kind: "text" | "thinking", text: string): void;
	assistantEnd(message: Extract<PiMessage, { role: "assistant" }>, finalId?: string): void;
	toolStart(callId: string, name: string, args: unknown, parentCallId?: string): void;
	toolOutput(callId: string, change: { append: string } | { set: string }): void;
	toolEnd(callId: string, output: string | undefined, isError: boolean, durationMs?: number, result?: { details?: unknown }): void;
	system(id: string, level: "info" | "warn" | "error", text: string): void;
	setState(patch: MapperState): void;
}

export type MapperOptions<I> = {
	/** The text of a queued submission, when known. */
	queueText?: (submissionId: string) => string | undefined;
	/** An entry the host draws itself (a note, a message the agent sent on its own): its item, placed by its time. */
	ownItem?: (entry: Entry) => I | undefined;
};

/** `head`: on a compaction, the first entry it kept as it was (what's older was summarized). */
export type Entry = { id: string | number; kind: string; model?: PiMessage[]; data?: unknown; head?: string | number };

/** Entries the model reads that the transcript doesn't show: what memory recalled for a message (docs/spec/38 R3). */
const UNSEEN = new Set([RECALL_ENTRY]);

/** Flattens committed entries into messages, keeping the entry id for each. */
export function messagesFromEntries(entries: readonly Entry[], own: (entry: Entry) => unknown = () => undefined): { messages: PiMessage[]; ids: string[] } {
	const messages: PiMessage[] = [];
	const ids: string[] = [];
	for (const e of entries) {
		if (e.kind === "pi.compaction" || UNSEEN.has(e.kind) || own(e) !== undefined) continue;
		for (const [i, m] of (e.model ?? []).entries()) {
			if (m.role !== "user" && m.role !== "assistant" && m.role !== "toolResult") continue;
			if ((e.kind === USER_ENTRY || (e.kind === "piopio.imported" && typeof (e.data as { text?: unknown })?.text === "string")) && m.role === "user") {
				// Show the words and file names, not the attachment blocks the model reads.
				const data = e.data as UserData;
				messages.push({ role: "user", content: data.text, attachments: data.attachments, timestamp: m.timestamp } as PiMessage);
			} else {
				messages.push(m);
			}
			ids.push(i === 0 ? String(e.id) : `${e.id}:${i}`);
		}
	}
	return { messages, ids };
}

/** The parts of a `ConversationView` the mapper reads (pi-durable's `ConversationView`, `LiveState`, `InboxState`). */
export type DurableView = { readonly entries: readonly Entry[]; readonly docs: Readonly<Record<string, unknown>> };
type Slot = { callId: string; name: string; status: "pending" | "running" | "done"; output?: string; entry?: number; parentCallId?: string; arguments?: unknown; summary?: { isError: boolean; error?: string } };
type Live = {
	run?: { taskId: number };
	generation?: { attempt: number; message?: PiMessage; retry?: { at: number; error: string } };
	tools?: Slot[];
	nestedTools?: Slot[];
	compactionFailure?: { taskId: number; error: string };
	runFailure?: { taskId: number; reason: string; detail?: string };
};
type ToolResult = Extract<PiMessage, { role: "toolResult" }>;
type InboxItem = { id: string | number; mode: string };

/** What one new value changed, for the caller's own bookkeeping. */
export type ViewChange = { appended: Entry[]; runEnded: boolean };

export class DurableViewMapper<I extends { id: string; at: string } = { id: string; at: string }> {
	private provisional = 0;
	/** The newest entry already shown. */
	private last = -Infinity;
	private running = false;
	/** The partial answer on the provisional item: which generation attempt, and how much of each block was shown. */
	private stream?: { key: string; shown: Map<number, number> };
	/** Tool calls: name and arguments from the answer that made them, and which were started, ended, and their output. */
	private readonly calls = new Map<string, { name: string; args: unknown }>();
	private readonly started = new Set<string>();
	private readonly ended = new Set<string>();
	private readonly outputs = new Map<string, string>();
	private nestedOpen = new Map<string, string>();
	/** Notices already shown (run failures, retries, compaction failures), so a value repeating them adds nothing. */
	private readonly noticed = new Set<string>();
	private lastInbox: InboxItem[] = [];
	private inboxKey = "";

	private readonly queueText: (submissionId: string) => string | undefined;
	private readonly ownItem: (entry: Entry) => I | undefined;

	/** A function as `options` is `queueText`: the text of a queued submission, when known. */
	constructor(
		private readonly builder: MapperBuilder<I>,
		options: MapperOptions<I> | ((submissionId: string) => string | undefined) = {},
	) {
		const o = typeof options === "function" ? { queueText: options } : options;
		this.queueText = o.queueText ?? (() => undefined);
		this.ownItem = o.ownItem ?? (() => undefined);
	}

	/** Re-reads queue texts (a submission's text can become known after its inbox update). */
	refreshQueue(): void {
		this.builder.setState({ queue: this.queue(this.lastInbox) });
	}

	private queue(items: InboxItem[]) {
		this.lastInbox = items;
		// Writes (notes and messages the engine adds) wait for the turn to end too, but they aren't yours to edit.
		return items.filter((q) => q.mode !== "write").map((q) => {
			const text = this.queueText(String(q.id));
			return { id: String(q.id), mode: q.mode === "steer" ? ("steer" as const) : ("followUp" as const), ...(text !== undefined ? { text } : {}) };
		});
	}

	/**
	 * The first state: the conversation's history (its entries in order, read before the watch) and the watch's first
	 * value, which may hold newer entries, an answer being streamed and running tools. Notices already in it (the last
	 * run's failure) aren't shown again. Returns the entries the view added after the transcript.
	 *
	 * The history is everything said, not the model's context: a compaction summarizes older entries for the model and
	 * leaves them where they were, so the reader still sees them, with a marker where the summary took over.
	 */
	load(transcript: readonly Entry[], view: DurableView, emit: boolean): Entry[] {
		const { messages, ids } = messagesFromEntries(transcript, this.ownItem);
		this.builder.reset(messages, (i) => ids[i]!, false);
		for (const e of transcript) {
			this.note(e, true);
			const own = this.ownItem(e);
			if (own) this.place(own, false);
			if (e.kind === "pi.compaction") this.compacted(e, false);
		}
		if (emit) this.builder.resnapshot();
		const live = (view.docs["pi.live"] ?? {}) as Live;
		if (live.runFailure) this.noticed.add(`run:${live.runFailure.taskId}`);
		if (live.compactionFailure) this.noticed.add(`compaction:${live.compactionFailure.taskId}`);
		if (live.generation?.retry) this.noticed.add(`retry:${live.run?.taskId}:${live.generation.attempt}`);
		return this.apply(view).appended;
	}

	/** A later value of the watch. */
	apply(view: DurableView): ViewChange {
		const b = this.builder;
		const live = (view.docs["pi.live"] ?? {}) as Live;
		// New entries first: they end the answer and the tool calls the previous value showed in progress.
		const appended: Entry[] = [];
		for (const entry of view.entries) {
			if (Number(entry.id) <= this.last) continue;
			appended.push(entry);
			this.entry(entry);
		}
		// Then what is in progress: the answer being streamed, the tool round.
		const partial = live.generation?.message;
		if (partial?.role === "assistant") {
			const key = `${live.run?.taskId}:${live.generation!.attempt}`;
			if (this.stream?.key !== key) {
				b.assistantStart(`gen:${++this.provisional}`, (partial as { model?: string }).model);
				this.stream = { key, shown: new Map() };
			}
			(partial.content as PiContentBlock[]).forEach((block, i) => {
				const text = block.type === "text" ? block.text : block.type === "thinking" ? block.thinking : undefined;
				if (text === undefined) return;
				const shown = this.stream!.shown.get(i) ?? 0;
				if (text.length > shown) b.assistantDelta(i, block.type as "text" | "thinking", text.slice(shown));
				this.stream!.shown.set(i, text.length);
			});
		}
		for (const slot of live.tools ?? []) this.slot(slot);
		const nested = new Set<string>();
		for (const slot of live.nestedTools ?? []) {
			nested.add(slot.callId);
			this.slot(slot);
		}
		// A nested call's slot leaves when its caller settles.
		for (const [callId] of this.nestedOpen) {
			if (nested.has(callId)) continue;
			this.nestedOpen.delete(callId);
			if (!this.ended.has(callId)) this.end(callId, undefined, false);
		}
		const inbox = ((view.docs["pi.inbox"] as { items?: InboxItem[] } | undefined)?.items ?? []).map((q) => ({ id: q.id, mode: q.mode }));
		const inboxKey = JSON.stringify(inbox);
		if (inboxKey !== this.inboxKey) {
			this.inboxKey = inboxKey;
			b.setState({ queue: this.queue(inbox) });
		}
		const retry = live.generation?.retry;
		if (retry && this.notice(`retry:${live.run?.taskId}:${live.generation!.attempt}`)) {
			b.system(`sys:retry:${String(live.generation!.attempt)}:${Date.now()}`, "warn", `Retrying (attempt ${String(live.generation!.attempt)}): ${retry.error}`);
		}
		const failure = live.runFailure;
		// Model errors already arrive as an assistant entry with the error; other reasons get a notice.
		if (failure && this.notice(`run:${failure.taskId}`) && !["model_error", "aborted", "nothing_to_answer"].includes(failure.reason)) {
			b.system(`sys:run:${failure.taskId}`, "error", `Not answered (${failure.reason})${failure.detail ? `: ${failure.detail}` : ""}`);
		}
		const compaction = live.compactionFailure;
		if (compaction && this.notice(`compaction:${compaction.taskId}`)) b.system(`sys:${compaction.taskId}`, "warn", `Compaction failed: ${compaction.error}`);
		const running = live.run !== undefined;
		const runEnded = this.running && !running;
		if (running !== this.running) {
			this.running = running;
			b.setState({ status: running ? "running" : "idle" });
		}
		return { appended, runEnded };
	}

	private notice(key: string): boolean {
		if (this.noticed.has(key)) return false;
		this.noticed.add(key);
		return true;
	}

	/** Bookkeeping for an entry: where it is, the calls it made, and (for one already shown) the results it holds. */
	private note(entry: Entry, shown: boolean): void {
		this.last = Math.max(this.last, Number(entry.id));
		for (const m of entry.model ?? []) {
			if (m.role === "assistant") {
				for (const block of m.content as { type: string; id?: string; name?: string; arguments?: unknown }[]) {
					if (block.type === "toolCall" && block.id) this.calls.set(block.id, { name: block.name ?? "tool", args: block.arguments });
				}
			} else if (m.role === "toolResult" && shown) {
				const { toolCallId } = m as ToolResult;
				this.started.add(toolCallId);
				this.ended.add(toolCallId);
			}
		}
	}

	private entry(entry: Entry): void {
		const b = this.builder;
		this.note(entry, false);
		const own = this.ownItem(entry);
		if (own) return this.place(own, true);
		if (entry.kind === "pi.compaction") return this.compacted(entry, true);
		const message = entry.model?.[0];
		if (!message || UNSEEN.has(entry.kind)) return;
		if (message.role === "user" && entry.kind === USER_ENTRY) {
			const data = entry.data as UserData;
			b.user(String(entry.id), data.text, message.timestamp as number | undefined, data.attachments as never);
		} else if (message.role === "user") b.user(String(entry.id), contentText(message.content as string | PiContentBlock[]), message.timestamp as number | undefined);
		else if (message.role === "assistant") {
			this.stream = undefined;
			b.assistantEnd(message as Extract<PiMessage, { role: "assistant" }>, String(entry.id));
		}
		for (const message of entry.model ?? []) {
			if (message.role !== "toolResult") continue;
			const m = message as ToolResult;
			// A call that ran between two values, or that was blocked before it ran, still gets its item.
			if (!this.started.has(m.toolCallId)) {
				this.started.add(m.toolCallId);
				const call = this.calls.get(m.toolCallId);
				b.toolStart(m.toolCallId, call?.name ?? m.toolName ?? "tool", call?.args ?? {});
			}
			// Its details too: a file card's files (06 §14), a plan's outcome.
			const details = (m as { details?: unknown }).details;
			this.end(m.toolCallId, contentText(m.content), m.isError ?? false, details === undefined ? undefined : { details });
		}
	}

	/**
	 * A compaction's marker, with its summary (the entry's own message, what the model reads in place of the older
	 * entries), put before the first entry it kept: what's above was summarized for the model, what's below it still
	 * reads as it was said.
	 */
	private compacted(entry: Entry, emit: boolean): void {
		const summary = contentText((entry.model?.[0]?.content ?? "") as string | PiContentBlock[]).trim();
		if (!summary) return;
		const head = Number(entry.head);
		const kept = Number.isFinite(head) ? this.builder.currentItems.find((i) => Number(i.id) >= head) : undefined;
		this.builder.insert({ kind: "compaction", id: String(entry.id), at: kept?.at ?? new Date().toISOString(), summary } as unknown as I, kept?.id, emit);
	}

	/** A host's own item, where its time puts it (or at the end, for a builder that doesn't place by time). */
	private place(item: I, emit: boolean): void {
		if (this.builder.place) this.builder.place(item, emit);
		else this.builder.insert(item, undefined, emit);
	}

	private slot(slot: Slot): void {
		const b = this.builder;
		const id = slot.callId;
		if (this.ended.has(id)) return;
		if (slot.parentCallId !== undefined) this.nestedOpen.set(id, slot.parentCallId);
		// A slot runs once `beforeTool` let it (an approval, a pause); a blocked call goes from pending to done.
		if (!this.started.has(id) && slot.status !== "pending") {
			this.started.add(id);
			const call = this.calls.get(id);
			b.toolStart(id, slot.name, slot.parentCallId !== undefined ? (slot.arguments ?? {}) : (call?.args ?? {}), slot.parentCallId);
		}
		if (this.started.has(id) && slot.output !== undefined && slot.output !== (this.outputs.get(id) ?? "")) {
			const before = this.outputs.get(id) ?? "";
			b.toolOutput(id, slot.output.startsWith(before) ? { append: slot.output.slice(before.length) } : { set: slot.output });
			this.outputs.set(id, slot.output);
		}
		if (slot.status !== "done") return;
		if (slot.parentCallId !== undefined) this.end(id, slot.summary?.error, slot.summary?.isError ?? false);
		// A model-issued call ends with its result entry; one without (the tool task faulted) ends here.
		else if (slot.entry === undefined && this.started.has(id)) this.end(id, undefined, true);
	}

	private end(callId: string, output: string | undefined, isError: boolean, result?: { details?: unknown }): void {
		this.ended.add(callId);
		this.outputs.delete(callId);
		this.builder.toolEnd(callId, output, isError, undefined, result);
	}
}
