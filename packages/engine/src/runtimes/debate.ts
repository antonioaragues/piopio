/**
 * Debate runtime (docs/spec/16-debate): two models work on one goal in one pi-durable session, one conversation
 * each. In each conversation that model's own turns are its answers and the other side's work comes in as messages,
 * so each model knows which words are its own. The runtime is the moderator: it runs one turn at a time, hands each
 * side's work to the other, and ends the debate when the reviewer approves, nothing changes or the rounds run out.
 * Afterwards the thread goes on as a chat with the author, who has the whole debate in its context.
 *
 * Everything the panel shows (drafts, objections) is read back from the two tools' calls, so a debate survives a
 * restart without state of its own beyond what the catalog keeps (`DebateRecord`).
 */
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { Type } from "@earendil-works/pi-ai";
import { createRegistry, defineExtension, defineTool, Harness, section, watchEvents, type AgentEventStream, type Conversation, type Extension } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import type { ContainerRef, DebateConfig, DebateItem, DebateObjection, DebateRole, DebateState, DebateStatus, ModelRef, Snapshot, TimelineItem } from "@piopio/protocol";
import { commandInput, isUserEntry, USER_ENTRY } from "../input.js";
import { EngineError, type ModelHub } from "../models.js";
import { contentText, TimelineBuilder, type PiContentBlock, type PiMessage } from "../timeline/builder.js";
import { DurableEventMapper } from "../timeline/pi-durable.js";
import { createWebExtension, type WebOptions } from "../tools/web.js";
import { Emitter, type Runtime, type SubmitOptions } from "./runtime.js";

const ctx = BACKGROUND_CONTEXT;

/** What the catalog keeps about a debate. */
export type DebateRecord = {
	config: DebateConfig;
	/** The reviewer's conversation (the author's is the session's root). */
	reviewer?: string;
	status: DebateStatus;
	/** Grows with Keep going. */
	maxRounds: number;
	/** Each time it ended: after which round, how and why (several with Keep going). */
	endings: { round: number; status: Exclude<DebateStatus, "running">; reason: string; at: number }[];
};

export type DebateOpenOptions = {
	ref: ContainerRef;
	file: string;
	hub: ModelHub;
	record: DebateRecord;
	/** Persists record changes (status, endings, the reviewer's conversation). */
	onRecord: (record: DebateRecord) => void;
	web?: boolean;
	webOptions?: WebOptions;
	/** More extensions (About me). */
	extensions?: Extension[];
};

/** Relayed work and the user's notes: hidden in the transcript, except a note (`note`), shown as the user's message. */
const RELAY = "piopio.debate";
type RelayData = { round: number; nudge?: boolean; note?: string };

const TOOL = { author: "debate_submit", reviewer: "debate_review" } as const;

type SubmitArgs = { draft?: string; unchanged?: boolean; changes?: string[]; pushback?: { objection: string; reason: string }[] };
type ReviewArgs = { objections: { id?: string; text: string; severity: "blocking" | "minor"; status: "open" | "resolved" | "withdrawn"; note?: string }[]; approve: boolean };

type RawEntry = { id: string | number; kind: string; data?: unknown; model?: PiMessage[] };

/** One side's turn: what it was sent (round), what it said, and the tool call it ended with. */
type Turn = { key: string; role: DebateRole; round: number; at: number; nudged: boolean; text: string; submit?: SubmitArgs; review?: ReviewArgs; error?: string };

const ROLES: DebateRole[] = ["author", "reviewer"];
const text = (t: string, isError = false) => ({ output: [{ type: "text" as const, text: t }], ...(isError ? { isError: true } : {}) });
const timeOf = (e: RawEntry) => Number((e.model?.[0] as { timestamp?: number } | undefined)?.timestamp ?? 0);
const other = (role: DebateRole): DebateRole => (role === "author" ? "reviewer" : "author");

/** Checks a new debate's settings (`sessions.create`). */
export function validateDebate(config: DebateConfig, hub: ModelHub): void {
	if (!config.goal.trim()) throw new EngineError("INVALID", "Write the goal first.");
	for (const role of ROLES) {
		const p = config.participants.find((x) => x.role === role);
		if (!p) throw new EngineError("INVALID", `A debate needs an ${role}.`);
		if (!hub.models.getModel(p.model.provider, p.model.id)) throw new EngineError("INVALID", `Unknown model ${p.model.provider}/${p.model.id}`);
	}
	if (!Number.isInteger(config.maxRounds) || config.maxRounds < 1 || config.maxRounds > 12) throw new EngineError("INVALID", "Rounds go from 1 to 12.");
}

export class DebateRuntime implements Runtime {
	private readonly emitter = new Emitter();
	private readonly builder: TimelineBuilder;
	private readonly mapper: DurableEventMapper;
	private readonly conversations = new Map<DebateRole, Conversation>();
	private readonly streams: AgentEventStream[] = [];
	private readonly speakers = new Map<string, DebateRole>();
	/** Who is answering now (live answers get their speaker before their id is known). */
	private speaking: DebateRole = "author";
	private turn?: DebateRole;
	private looping?: Promise<void>;
	private closing = false;
	private chatting = false;
	private notes: { id: string; text: string; shown?: boolean }[] = [];
	private undelivered = new Map<DebateRole, string[]>([["author", []], ["reviewer", []]]);
	private state: Fold = emptyFold();
	private lastRound = 1;

	private constructor(
		readonly ref: ContainerRef,
		private readonly hub: ModelHub,
		private readonly harness: Harness,
		private record: DebateRecord,
		private readonly onRecord: (record: DebateRecord) => void,
		private readonly ext: { author: Extension; reviewer: Extension; chat: Extension; base: Extension[] },
		private web: boolean,
		private readonly webExtension: Extension,
	) {
		this.builder = new TimelineBuilder(ref);
		this.mapper = new DurableEventMapper(this.builder);
		for (const tool of Object.values(TOOL)) this.builder.hiddenTools.add(tool);
		this.builder.decorate = (item) => {
			const role = this.speakers.get(item.id) ?? this.speaking;
			item.speaker = { role, label: this.label(role) };
		};
	}

	static async open(options: DebateOpenOptions): Promise<DebateRuntime> {
		const storage = await openNodeSqliteStorage(options.file);
		const registry = createRegistry();
		let runtime!: DebateRuntime;
		const webExtension = createWebExtension(options.hub, { ...options.webOptions, scope: options.ref.id }) as unknown as Extension;
		const ext = { ...debateExtensions(() => runtime), base: [...(options.extensions ?? [])] };
		for (const e of [webExtension, ext.author, ext.reviewer, ext.chat, ...ext.base]) registry.install(e as never);
		const harness = await Harness.open(storage, { models: options.hub.models, registry }, ctx);
		runtime = new DebateRuntime(options.ref, options.hub, harness, options.record, options.onRecord, ext, options.web ?? true, webExtension);
		const author = await harness.root(ctx, { agent: runtime.agent("author") } as Parameters<Harness["root"]>[1]);
		runtime.conversations.set("author", author);
		let reviewer = options.record.reviewer ? await harness.conversation(Number(options.record.reviewer) as never, ctx) : undefined;
		if (!reviewer) {
			reviewer = await harness.createConversation({ ownership: { kind: "ownerless" }, agent: runtime.agent("reviewer") } as never, ctx);
			runtime.setRecord({ ...runtime.record, reviewer: String(reviewer.id) });
		}
		runtime.conversations.set("reviewer", reviewer);
		for (const role of ROLES) await runtime.applySettings(role);
		await runtime.rebuild(false);
		for (const role of ROLES) await runtime.watch(role);
		for (const p of options.record.config.participants) await options.hub.ensureCredential(p.model.provider).catch(() => undefined);
		harness.resume();
		runtime.kick();
		return runtime;
	}

	// MARK: Participants

	private participant(role: DebateRole) {
		return this.record.config.participants.find((p) => p.role === role)!;
	}

	/** The model's name; both sides' role when the two names are the same. */
	label(role: DebateRole): string {
		const name = (r: DebateRole) => {
			const m = this.participant(r).model;
			return this.hub.models.getModel(m.provider, m.id)?.name ?? m.id;
		};
		const mine = name(role);
		return mine === name(other(role)) ? `${mine} (${role})` : mine;
	}

	private agent(role: DebateRole) {
		const p = this.participant(role);
		return { model: { provider: p.model.provider, modelId: p.model.id }, ...(p.thinking ? { thinkingLevel: p.thinking } : {}), extensions: this.extensionsFor(role) };
	}

	private extensionsFor(role: DebateRole): Extension[] {
		const own = role === "reviewer" ? this.ext.reviewer : this.record.status === "running" ? this.ext.author : this.ext.chat;
		return [...(this.web ? [this.webExtension] : []), ...this.ext.base, own];
	}

	private async applySettings(role: DebateRole): Promise<void> {
		const p = this.participant(role);
		await this.conv(role).configure(
			{ model: { provider: p.model.provider, modelId: p.model.id }, thinkingLevel: p.thinking ?? null, extensions: this.extensionsFor(role) } as unknown as Parameters<Conversation["configure"]>[0],
			ctx,
		);
	}

	private conv(role: DebateRole): Conversation {
		return this.conversations.get(role)!;
	}

	private setRecord(record: DebateRecord): void {
		this.record = record;
		this.onRecord(record);
	}

	// MARK: Prompts (the tools' sections)

	/** Each side's instructions, read every request. */
	prompt(role: DebateRole | "chat"): string {
		const { goal, criteria } = this.record.config;
		const brief = `The user's goal:\n${goal.trim()}\n\nWhat a good result must have:\n${criteria?.trim() || "(not given: judge by what the goal needs)"}`;
		if (role === "chat") {
			const draft = this.state.drafts.at(-1);
			const ending = this.record.endings.at(-1);
			return `You were the author in a review with another AI model, ${this.label("reviewer")}, about the goal below. The review has ended${ending ? ` (${ending.reason})` : ""}${draft ? `; the final draft is version ${draft.version}` : ""}. Now the user talks to you directly: answer as a normal assistant, using everything from the review. The review tools are gone.\n\n${brief}`;
		}
		if (role === "author") {
			return `You are the author in a review with another AI model, ${this.label("reviewer")}, who reviews your work. Together you produce one deliverable for the user.

${brief}

How it works: each round you write or revise the draft and end your turn by calling debate_submit. The reviewer then checks it against the goal and raises objections, each with an id like O1. In later rounds you get the open objections: fix what's right, and push back (with a reason) on what isn't. Don't give in just to agree: the user wants the best deliverable, not a quick consensus.
The draft is the deliverable itself: complete, ready to hand to the user, with no notes about the review in it. Anything for the reviewer goes in your message or in pushback, briefly.
There are at most ${this.record.maxRounds} rounds.`;
		}
		return `You are the reviewer in a review with another AI model, ${this.label("author")}, who writes the deliverable. Together you produce one deliverable for the user.

${brief}

How it works: each round you get the latest draft with the author's changes and pushback. Check it against the goal and what it must have, and end your turn by calling debate_review with:
- every objection that is still open or new, with its id (keep the ids of earlier ones; new ones take the next number: O1, O2…), its severity (blocking: the result fails the goal without this; minor: worth doing, not required) and its status (open, resolved or withdrawn), with a short note when you resolve or withdraw one or answer pushback;
- approve: true only when nothing blocking is open.
You are judged on the quality of the final deliverable, not on being agreeable. Approving with a blocking problem left is a failure; so is inventing problems or raising ones already fixed. When the author's pushback is right, withdraw the objection and say why. Be specific: what is wrong, and what would fix it.
There are at most ${this.record.maxRounds} rounds.`;
	}

	/** Checks a debate_submit call against the debate so far (an error lets the model fix it in the same turn). */
	checkSubmit(args: SubmitArgs): string | undefined {
		if (this.record.status !== "running") return "The review has ended.";
		const hasDraft = Boolean(args.draft?.trim()) && !args.unchanged;
		if (!hasDraft && this.state.drafts.length === 0) return "There's no draft yet: write the full draft in `draft`.";
		const open = new Set(this.state.objections.filter((o) => o.status === "open").map((o) => o.id));
		const unknown = (args.pushback ?? []).filter((p) => !open.has(p.objection)).map((p) => p.objection);
		if (unknown.length) return `${unknown.join(", ")} ${unknown.length === 1 ? "isn't an open objection" : "aren't open objections"}. Open: ${[...open].join(", ") || "none"}.`;
		return undefined;
	}

	/** Checks a debate_review call: approving needs nothing blocking left open. */
	checkReview(args: ReviewArgs): string | undefined {
		if (this.record.status !== "running") return "The review has ended.";
		if (!args.approve) return undefined;
		const after = applyReview(this.state.objections.map((o) => ({ ...o, history: [...o.history] })), args, this.lastRound);
		const blocking = after.filter((o) => o.status === "open" && o.severity === "blocking");
		if (blocking.length) return `${blocking.map((o) => o.id).join(", ")} ${blocking.length === 1 ? "is" : "are"} blocking and still open: resolve or withdraw ${blocking.length === 1 ? "it" : "them"}, or set approve to false.`;
		return undefined;
	}

	// MARK: The moderator

	/** Starts the turn loop unless it's running or the debate has ended. */
	private kick(): void {
		if (this.looping || this.record.status !== "running" || this.closing) return;
		this.looping = this.loop()
			.catch(async (error) => {
				if (this.closing) return;
				await this.end("stopped", `stopped by an error: ${(error as Error).message}`);
			})
			.finally(() => {
				this.looping = undefined;
				this.turn = undefined;
				this.publish();
			});
		this.publish();
	}

	private async loop(): Promise<void> {
		// A turn still running from before a restart finishes first.
		for (const role of ROLES) await this.conv(role).waitForIdle(ctx);
		while (this.record.status === "running" && !this.closing) {
			const turns = await this.turns();
			this.state = fold(turns);
			const last = turns.at(-1);
			if (!last) {
				await this.runTurn("author", 1, `The user's goal:\n${this.record.config.goal.trim()}\n\nWrite the first draft and submit it with debate_submit.`, this.record.config.goal.trim());
				continue;
			}
			const result = last.role === "author" ? last.submit : last.review;
			if (!result && last.error) return this.end("stopped", `${this.label(last.role)} couldn't answer: ${last.error}`);
			if (!result && !last.nudged) {
				await this.nudge(last);
				continue;
			}
			if (last.role === "author" && !this.state.drafts.length) return this.end("stopped", `${this.label("author")} didn't submit a draft`);
			if (last.role === "author") {
				await this.runTurn("reviewer", last.round, this.forReviewer(last, turns));
				continue;
			}
			// A reviewer's turn ends the round, unless the debate already ended there (Keep going).
			if (!this.record.endings.some((e) => e.round === last.round)) {
				if (last.review?.approve) return this.end("agreed", `${this.label("reviewer")} approved draft v${this.state.drafts.at(-1)?.version ?? 1}`);
				if (stalled(this.state, last.round)) return this.end("no_agreement", "nothing changed in the last two rounds");
				if (last.round >= this.record.maxRounds) {
					const open = this.state.objections.filter((o) => o.status === "open").length;
					return this.end("no_agreement", `reached the round limit (${this.record.maxRounds}) with ${open === 1 ? "1 objection" : `${open} objections`} open`);
				}
			}
			await this.runTurn("author", last.round + 1, this.forAuthor(last));
		}
	}

	/** Sends `content` to one side and waits for its answer, then refreshes the transcript and the panel. */
	private async runTurn(role: DebateRole, round: number, content: string, shownNote?: string): Promise<void> {
		const waiting = this.undelivered.get(role)!;
		const delivered = this.notes.filter((n) => waiting.includes(n.id));
		const userNotes = delivered.length ? `\n\nThe user says:\n${delivered.map((n) => n.text).join("\n")}` : "";
		// A note shows in the transcript once, with the first turn that carries it; the queue holds it until then.
		const first = delivered.filter((n) => !n.shown);
		for (const n of first) n.shown = true;
		const shown = [shownNote, ...first.map((n) => n.text)].filter((t): t is string => Boolean(t));
		this.undelivered.set(role, []);
		this.notes = this.notes.filter((n) => this.undelivered.get(other(role))!.includes(n.id));
		const data: RelayData = { round, ...(shown.length ? { note: shown.join("\n\n") } : {}) };
		await this.send(role, content + userNotes, data);
	}

	private async nudge(turn: Turn): Promise<void> {
		await this.send(turn.role, `End your turn by calling ${TOOL[turn.role]}.`, { round: turn.round, nudge: true });
	}

	private async send(role: DebateRole, content: string, data: RelayData): Promise<void> {
		this.turn = role;
		this.speaking = role;
		this.lastRound = data.round;
		await this.hub.ensureCredential(this.participant(role).model.provider);
		// A new round shows its divider right away, not when its first turn ends.
		if (role === "author" && !data.nudge) this.builder.insert({ kind: "debate", id: `debate:round:${data.round}`, at: new Date().toISOString(), event: "round", round: data.round, title: `Round ${data.round}` });
		this.publish();
		const conversation = this.conv(role);
		await conversation.submit({ type: "input", content, entry: { kind: RELAY, data }, whenBusy: "followUp" } as unknown as Parameters<Conversation["submit"]>[0], ctx);
		await conversation.waitForIdle(ctx);
		if (this.closing) return;
		// The turn is over: its summary shows in the rebuilt transcript.
		this.turn = undefined;
		await this.rebuild(true);
	}

	/** What the reviewer gets after the author's turn. */
	private forReviewer(turn: Turn, turns: Turn[]): string {
		const draft = this.state.drafts.at(-1);
		const s = turn.submit;
		const kept = !s || s.unchanged || !s.draft?.trim();
		const lines = [`Round ${turn.round}. ${this.label("author")} ${kept ? `kept draft v${draft?.version ?? 1}` : `submitted draft v${draft?.version ?? 1}`}.`];
		if (s?.changes?.length) lines.push(`\nChanges:\n${s.changes.map((c) => `- ${c}`).join("\n")}`);
		if (s?.pushback?.length) lines.push(`\nPushback:\n${s.pushback.map((p) => `- ${p.objection}: ${p.reason}`).join("\n")}`);
		if (turn.text.trim()) lines.push(`\n${this.label("author")} says:\n${clip(turn.text)}`);
		const reviewed = turns.some((t) => t.role === "reviewer");
		if (reviewed) lines.push(`\nYour objections so far:\n${objectionList(this.state.objections)}`);
		lines.push(`\nThe draft:\n<draft version="${draft?.version ?? 1}">\n${draft?.text ?? ""}\n</draft>\n\nReview it and call debate_review.`);
		return lines.join("\n");
	}

	/** What the author gets after the reviewer's turn. */
	private forAuthor(turn: Turn): string {
		const version = this.state.drafts.at(-1)?.version ?? 1;
		const lines = [`Round ${turn.round + 1}. ${this.label("reviewer")}'s review of draft v${version}${turn.review ? "" : " (no review came back)"}:`];
		const open = this.state.objections.filter((o) => o.status === "open");
		lines.push(open.length ? `\nOpen objections:\n${objectionList(open)}` : "\nNo open objections.");
		const closed = (turn.review?.objections ?? []).filter((o) => o.status !== "open");
		if (closed.length) lines.push(`\nClosed this round:\n${closed.map((o) => `- ${o.id ?? "?"} ${o.status}${o.note ? `: ${o.note}` : ""}`).join("\n")}`);
		if (turn.text.trim()) lines.push(`\n${this.label("reviewer")} says:\n${clip(turn.text)}`);
		lines.push("\nRevise the draft (or keep it, pushing back with reasons) and call debate_submit.");
		return lines.join("\n");
	}

	private async end(status: Exclude<DebateStatus, "running">, reason: string): Promise<void> {
		this.setRecord({ ...this.record, status, endings: [...this.record.endings, { round: this.lastRound, status, reason, at: Date.now() }] });
		this.turn = undefined;
		await this.applySettings("author");
		await this.rebuild(true);
	}

	/** Keep going: more rounds, from where it ended. */
	async continueDebate(rounds?: number): Promise<void> {
		if (this.record.status === "running") throw new EngineError("BUSY", "The debate is still going.");
		if (this.builder.status === "running") throw new EngineError("BUSY", "Wait for the answer to finish.");
		const more = rounds ?? this.record.config.maxRounds;
		if (!Number.isInteger(more) || more < 1 || more > 12) throw new EngineError("INVALID", "Add 1 to 12 rounds.");
		this.setRecord({ ...this.record, status: "running", maxRounds: Math.max(this.record.maxRounds, this.lastRound) + more });
		await this.applySettings("author");
		this.kick();
	}

	/** Ends the debate now, keeping the latest draft. */
	async stopDebate(): Promise<void> {
		if (this.record.status !== "running") return;
		const running = this.turn;
		this.setRecord({ ...this.record, status: "stopped" });
		if (running) await this.conv(running).abort(ctx);
		await this.looping;
		this.setRecord({ ...this.record, endings: [...this.record.endings, { round: this.lastRound, status: "stopped", reason: "stopped by you", at: Date.now() }] });
		await this.applySettings("author");
		await this.rebuild(true);
	}

	// MARK: Reading the debate back

	private async entries(role: DebateRole): Promise<RawEntry[]> {
		const view = await this.conv(role).viewState(ctx);
		const entries = [...(view.value.entries as readonly RawEntry[])];
		view.dispose();
		return entries;
	}

	private async turns(): Promise<Turn[]> {
		const all = [...turnsOf("author", await this.entries("author")), ...turnsOf("reviewer", await this.entries("reviewer"))];
		return all.sort((a, b) => a.round - b.round || (a.role === b.role ? a.at - b.at : a.role === "author" ? -1 : 1));
	}

	/**
	 * Rebuilds the transcript from both conversations: the user's goal and notes, each side's answers with its
	 * speaker, a divider per round, what each turn did, and each ending's result.
	 */
	private async rebuild(emit: boolean): Promise<void> {
		const entries = { author: await this.entries("author"), reviewer: await this.entries("reviewer") };
		const turns = [...turnsOf("author", entries.author), ...turnsOf("reviewer", entries.reviewer)].sort((a, b) => a.round - b.round || (a.role === b.role ? a.at - b.at : a.role === "author" ? -1 : 1));
		this.state = fold(turns);
		if (turns.length) this.lastRound = turns.at(-1)!.round;

		type Shown = { message: PiMessage; id: string; at: number; role: DebateRole; segment: string };
		const shown: Shown[] = [];
		for (const role of ROLES) {
			let segment = "chat";
			let at = 0;
			for (const e of entries[role]) {
				at = timeOf(e) || at;
				if (e.kind === "pi.compaction") continue;
				if (e.kind === RELAY) {
					const data = e.data as RelayData;
					if (!data.nudge) segment = `${role}:${data.round}`;
					if (data.note) shown.push({ message: { role: "user", content: data.note, timestamp: at }, id: String(e.id), at, role, segment });
					continue;
				}
				if (isUserEntry(e.kind)) segment = `chat:${String(e.id)}`;
				for (const [i, m] of (e.model ?? []).entries()) {
					if (m.role !== "user" && m.role !== "assistant" && m.role !== "toolResult") continue;
					const message = e.kind === USER_ENTRY && m.role === "user" ? { role: "user", content: (e.data as { text: string }).text, timestamp: m.timestamp } : m;
					shown.push({ message: message as PiMessage, id: i === 0 ? String(e.id) : `${e.id}:${i}`, at: Number(m.timestamp ?? at), role, segment });
				}
			}
		}
		shown.sort((a, b) => a.at - b.at);
		this.speakers.clear();
		const segmentOf = new Map<string, string>();
		for (const s of shown) {
			if (s.message.role === "assistant") this.speakers.set(s.id, s.role);
			segmentOf.set(s.id, s.segment);
			if (s.message.role === "assistant") {
				for (const b of (s.message.content as PiContentBlock[]) ?? []) if (b.type === "toolCall") segmentOf.set(`tool:${b.id}`, s.segment);
			}
		}
		this.builder.reset(shown.map((s) => s.message), (i) => shown[i]!.id, false);

		// Group items by segment, in the order segments first appear.
		const order: string[] = [];
		const groups = new Map<string, TimelineItem[]>();
		for (const s of shown) if (!groups.has(s.segment)) (groups.set(s.segment, []), order.push(s.segment));
		for (const t of turns) if (!groups.has(t.key)) (groups.set(t.key, []), order.push(t.key));
		for (const item of this.builder.currentItems) {
			if (item.kind === "assistant" && item.status === "done" && !item.parts.some((p) => p.text.trim())) continue;
			groups.get(segmentOf.get(item.id) ?? "chat")?.push(item) ?? (groups.set("chat", [item]), order.push("chat"));
		}
		const byKey = new Map(turns.map((t) => [t.key, t]));
		const endingsAfter = new Map<string, DebateRecord["endings"]>();
		for (const ending of this.record.endings) {
			const turn = [...turns].reverse().find((t) => t.round <= ending.round && t.at <= ending.at) ?? turns.at(-1);
			if (turn) endingsAfter.set(turn.key, [...(endingsAfter.get(turn.key) ?? []), ending]);
		}
		const items: TimelineItem[] = [];
		const dividers = new Set<number>();
		for (const key of order) {
			const turn = byKey.get(key);
			if (turn && turn.role === "author" && !dividers.has(turn.round)) {
				dividers.add(turn.round);
				items.push(this.divider(turn));
			}
			items.push(...(groups.get(key) ?? []));
			if (!turn) continue;
			const finished = turn !== turns.at(-1) || !(this.record.status === "running" && this.turn === turn.role);
			if (finished) items.push(this.summary(turn));
			for (const [i, ending] of (endingsAfter.get(key) ?? []).entries()) items.push(this.result(ending, `${key}:${i}`));
		}
		this.builder.setItems(items);
		this.builder.setState({ ...this.stateFields(), status: this.status() });
		this.builder.flush();
		if (emit) this.emitter.emit([{ type: "resnapshot", snapshot: this.builder.snapshot() }]);
	}

	private divider(turn: Turn): DebateItem {
		return { kind: "debate", id: `debate:round:${turn.round}`, at: new Date(turn.at || Date.now()).toISOString(), event: "round", round: turn.round, title: `Round ${turn.round}` };
	}

	private summary(turn: Turn): DebateItem {
		const s = this.state.summaries.get(turn.key) ?? { title: turn.role === "author" ? "No draft this turn" : "No review this turn", lines: [] };
		return { kind: "debate", id: `debate:turn:${turn.key}`, at: new Date(turn.at || Date.now()).toISOString(), event: "turn", round: turn.round, speaker: { role: turn.role, label: this.label(turn.role) }, title: s.title, ...(s.lines.length ? { lines: s.lines } : {}) };
	}

	private result(ending: DebateRecord["endings"][number], key: string): DebateItem {
		const rounds = ending.round === 1 ? "1 round" : `${ending.round} rounds`;
		const title = ending.status === "agreed" ? `Agreed after ${rounds}` : ending.status === "no_agreement" ? `No agreement after ${rounds}` : `Stopped in round ${ending.round}`;
		const draft = this.state.drafts.filter((d) => d.round <= ending.round).at(-1);
		const open = this.state.objections.filter((o) => o.status === "open" && o.round <= ending.round);
		return {
			kind: "debate",
			id: `debate:result:${key}`,
			at: new Date(ending.at).toISOString(),
			event: "result",
			round: ending.round,
			title,
			status: ending.status,
			lines: [ending.reason.charAt(0).toUpperCase() + ending.reason.slice(1)],
			...(draft ? { draft: draft.text } : {}),
			...(open.length ? { open: open.map((o) => ({ text: `${o.id}: ${o.text}`, severity: o.severity, ...(o.pushback ? { pushback: o.pushback } : {}) })) } : {}),
			costUsd: this.builder.snapshot().state.usage.costUsd,
		};
	}

	// MARK: Live events

	private async watch(role: DebateRole): Promise<void> {
		const stream = await watchEvents(this.harness, this.conv(role).id, ctx);
		this.streams.push(stream);
		stream.start(async (events) => {
			for (const event of events) {
				const e = event as { type: string; entry?: RawEntry };
				if (e.type === "snapshot" || e.type === "inbox_update" || e.type === "submission") continue;
				if (e.type === "run_start" || e.type === "run_end") {
					if (!this.looping) {
						this.chatting = e.type === "run_start";
						this.builder.setState({ status: this.status() });
					}
					continue;
				}
				if (e.type === "message_end") {
					const message = e.entry?.model?.[0];
					if (e.entry?.kind === RELAY) continue;
					// Answers that only called a debate tool show as the turn's summary instead.
					if (message?.role === "assistant" && !(message.content as PiContentBlock[]).some((b) => (b.type === "text" && b.text.trim()) || b.type === "thinking") && message.stopReason !== "error") continue;
				}
				if (e.type === "message_start") this.speaking = role;
				this.mapper.apply(event as never);
			}
			this.emitter.emit(this.builder.flush());
		});
	}

	// MARK: State

	private status(): "running" | "idle" {
		return this.looping || this.chatting ? "running" : "idle";
	}

	private stateFields() {
		const author = this.participant("author");
		return { model: author.model, thinking: author.thinking ?? "default", tools: { web: this.web }, queue: this.notes.filter((n) => !n.shown).map((n) => ({ id: n.id, mode: "steer" as const, text: n.text })), debate: this.debateState() };
	}

	private debateState(): DebateState {
		const { config } = this.record;
		return {
			status: this.record.status,
			round: this.lastRound,
			maxRounds: this.record.maxRounds,
			...(this.record.status === "running" && this.turn ? { turn: this.turn } : {}),
			goal: config.goal,
			...(config.criteria?.trim() ? { criteria: config.criteria } : {}),
			participants: ROLES.map((role) => ({ role, label: this.label(role), model: this.participant(role).model })),
			drafts: this.state.drafts,
			objections: this.state.objections,
			...(this.record.endings.length && this.record.status !== "running" ? { reason: this.record.endings.at(-1)!.reason } : {}),
		};
	}

	private publish(): void {
		this.builder.setState({ ...this.stateFields(), status: this.status() });
		this.emitter.emit(this.builder.flush());
	}

	// MARK: Runtime

	snapshot(): Snapshot {
		return this.builder.snapshot();
	}

	onEvents(listener: Parameters<Runtime["onEvents"]>[0]): () => void {
		return this.emitter.on(listener);
	}

	/** While the debate runs, your message goes to both sides before their next turns; afterwards, to the author. */
	async submit(text: string, options: SubmitOptions) {
		if (this.record.status === "running") {
			const id = `note:${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
			this.notes.push({ id, text });
			for (const role of ROLES) this.undelivered.get(role)!.push(id);
			this.publish();
			return { disposition: "queued" as const };
		}
		const busy = this.builder.status === "running";
		const input = commandInput(text, options.attachments);
		const author = this.participant("author");
		await this.hub.ensureCredential(author.model.provider);
		this.speaking = "author";
		await this.conv("author").submit(
			{ type: "input", content: input.content, ...(input.entry ? { entry: input.entry } : {}), whenBusy: options.whenBusy, ...(options.requestId ? { requestId: options.requestId } : {}) } as Parameters<Conversation["submit"]>[0],
			ctx,
		);
		return { disposition: busy ? ("queued" as const) : ("started" as const) };
	}

	/** Stop: ends the debate while it runs; stops the author's answer afterwards. */
	async abort(): Promise<void> {
		if (this.record.status === "running") return this.stopDebate();
		await this.conv("author").abort(ctx);
	}

	/** Changes the author's model or thinking (the chat after the debate), or web tools for both. */
	async configure(change: { model?: ModelRef; thinking?: string; web?: boolean }): Promise<void> {
		if (change.model && !this.hub.models.getModel(change.model.provider, change.model.id)) throw new EngineError("INVALID", `Unknown model ${change.model.provider}/${change.model.id}`);
		if (change.model || change.thinking) {
			const participants = this.record.config.participants.map((p) =>
				p.role !== "author" ? p : { ...p, ...(change.model ? { model: change.model } : {}), ...(change.thinking ? (change.thinking === "default" ? { thinking: undefined } : { thinking: change.thinking }) : {}) },
			);
			this.setRecord({ ...this.record, config: { ...this.record.config, participants } });
		}
		if (change.web !== undefined) this.web = change.web;
		for (const role of ROLES) await this.applySettings(role);
		this.publish();
	}

	async close(): Promise<void> {
		this.closing = true;
		for (const s of this.streams) await s.stop();
		await this.harness.close(ctx);
		await this.looping?.catch(() => undefined);
	}
}

// MARK: Tools

function debateExtensions(host: () => DebateRuntime) {
	const submitTool = defineTool({
		name: TOOL.author,
		description: "Submit your draft for this round and end your turn. The reviewer reads it next.",
		parameters: Type.Object({
			draft: Type.Optional(Type.String({ description: "The full deliverable, complete and ready for the user (not a diff). Leave out only with unchanged." })),
			unchanged: Type.Optional(Type.Boolean({ description: "true to keep the previous draft as it is" })),
			changes: Type.Optional(Type.Array(Type.String(), { description: "One line per change, naming the objection it answers (\"O2: added a rollback section\")" })),
			pushback: Type.Optional(Type.Array(Type.Object({ objection: Type.String({ description: "The objection's id, e.g. O3" }), reason: Type.String({ description: "Why you won't act on it" }) }), { description: "Open objections you won't act on, each with a reason" })),
		}),
		execute: async (args) => {
			const problem = host().checkSubmit(args);
			if (problem) return text(problem, true);
			return { ...text("Received. The reviewer reads it next."), control: { terminate: true } };
		},
	});
	const reviewTool = defineTool({
		name: TOOL.reviewer,
		description: "Submit your review of the latest draft and end your turn.",
		parameters: Type.Object({
			objections: Type.Array(
				Type.Object({
					id: Type.Optional(Type.String({ description: "O1, O2…: keep earlier ids; leave out for a new one" })),
					text: Type.String({ description: "What is wrong and what would fix it" }),
					severity: Type.Union([Type.Literal("blocking"), Type.Literal("minor")]),
					status: Type.Union([Type.Literal("open"), Type.Literal("resolved"), Type.Literal("withdrawn")]),
					note: Type.Optional(Type.String({ description: "Why it's resolved or withdrawn, or your answer to pushback" })),
				}),
				{ description: "Every objection still open or new, plus ones you resolve or withdraw now" },
			),
			approve: Type.Boolean({ description: "true only when nothing blocking is open" }),
		}),
		execute: async (args) => {
			const problem = host().checkReview(args);
			if (problem) return text(problem, true);
			return { ...text(args.approve ? "Approved." : "Sent to the author."), control: { terminate: true } };
		},
	});
	return {
		author: defineExtension({ name: "piopio-debate-author", tools: [submitTool], sections: [section("debate-author", () => host().prompt("author"))] }) as unknown as Extension,
		reviewer: defineExtension({ name: "piopio-debate-reviewer", tools: [reviewTool], sections: [section("debate-reviewer", () => host().prompt("reviewer"))] }) as unknown as Extension,
		chat: defineExtension({ name: "piopio-debate-chat", sections: [section("debate-chat", () => host().prompt("chat"))] }) as unknown as Extension,
	};
}

// MARK: Folding turns into drafts and objections

type Fold = {
	drafts: DebateState["drafts"];
	objections: DebateObjection[];
	/** Each turn's summary line and details, for the transcript. */
	summaries: Map<string, { title: string; lines: string[] }>;
	/** Rounds whose author turn made a new draft. */
	changed: Set<number>;
	/** The open objections' ids after each round's review. */
	openAfter: Map<number, string>;
};

const emptyFold = (): Fold => ({ drafts: [], objections: [], summaries: new Map(), changed: new Set(), openAfter: new Map() });

/** One side's turns, read from its conversation: each relay starts one (nudges don't), and its tool call ends it. */
function turnsOf(role: DebateRole, entries: readonly RawEntry[]): Turn[] {
	const failed = new Map<string, boolean>();
	for (const e of entries) for (const m of e.model ?? []) if (m.role === "toolResult") failed.set(String((m as { toolCallId: string }).toolCallId), Boolean((m as { isError?: boolean }).isError));
	const turns: Turn[] = [];
	let current: Turn | undefined;
	for (const e of entries) {
		if (e.kind === RELAY) {
			const data = e.data as RelayData;
			const key = `${role}:${data.round}`;
			const same = turns.find((t) => t.key === key);
			if (data.nudge || same) {
				current = same ?? current;
				if (current) current.nudged = true;
				continue;
			}
			current = { key, role, round: data.round, at: timeOf(e), nudged: false, text: "" };
			turns.push(current);
			continue;
		}
		if (isUserEntry(e.kind)) current = undefined;
		if (!current) continue;
		for (const m of e.model ?? []) {
			if (m.role !== "assistant") continue;
			const a = m as Extract<PiMessage, { role: "assistant" }>;
			const said = contentText(a.content.filter((b) => b.type === "text"));
			if (said.trim()) current.text += (current.text ? "\n\n" : "") + said.trim();
			for (const b of a.content) {
				if (b.type !== "toolCall" || b.name !== TOOL[role] || failed.get(b.id) !== false) continue;
				if (role === "author") current.submit = b.arguments as SubmitArgs;
				else current.review = b.arguments as ReviewArgs;
			}
			if (a.stopReason === "error") current.error = a.errorMessage ?? "the model failed";
			else delete current.error;
		}
	}
	return turns;
}

function fold(turns: readonly Turn[]): Fold {
	const f = emptyFold();
	for (const turn of turns) {
		if (turn.role === "author") {
			const s = turn.submit;
			if (!s) continue;
			const lines: string[] = [];
			let title: string;
			if (s.draft?.trim() && !s.unchanged) {
				const version = f.drafts.length + 1;
				f.drafts.push({ version, round: turn.round, text: s.draft, changes: s.changes ?? [] });
				f.changed.add(turn.round);
				title = version === 1 ? "Draft v1" : `Draft v${version}`;
			} else {
				title = `Kept draft v${f.drafts.length}`;
			}
			const counts = [s.changes?.length ? (s.changes.length === 1 ? "1 change" : `${s.changes.length} changes`) : "", s.pushback?.length ? (s.pushback.length === 1 ? "1 pushback" : `${s.pushback.length} pushbacks`) : ""].filter(Boolean);
			if (counts.length) title += ` · ${counts.join(" · ")}`;
			for (const c of s.changes ?? []) lines.push(`+ ${c}`);
			for (const p of s.pushback ?? []) {
				lines.push(`↩ ${p.objection}: ${p.reason}`);
				const o = f.objections.find((x) => x.id === p.objection);
				if (o) {
					o.pushback = p.reason;
					o.history.push({ round: turn.round, by: "author", action: "pushed_back", note: p.reason });
				}
			}
			f.summaries.set(turn.key, { title, lines });
		} else {
			const r = turn.review;
			if (!r) continue;
			const before = new Map(f.objections.map((o) => [o.id, o.status]));
			f.objections = applyReview(f.objections, r, turn.round);
			const open = f.objections.filter((o) => o.status === "open");
			const blocking = open.filter((o) => o.severity === "blocking").length;
			f.openAfter.set(turn.round, open.map((o) => o.id).sort().join(","));
			const title = r.approve ? (open.length ? `Approved · ${open.length} minor left` : "Approved") : open.length ? `${open.length === 1 ? "1 objection" : `${open.length} objections`} open${blocking ? ` · ${blocking} blocking` : ""}` : "No objections";
			const lines = f.objections
				.filter((o) => o.history.at(-1)?.round === turn.round && o.history.at(-1)?.by === "reviewer" && (o.status === "open" ? true : before.get(o.id) !== o.status))
				.map((o) => (o.status === "open" ? `${o.id} · ${o.severity} · ${o.text}` : `${o.id} ${o.status}${o.history.at(-1)?.note ? `: ${o.history.at(-1)!.note}` : ""}`));
			f.summaries.set(turn.key, { title, lines });
		}
	}
	return f;
}

/** Applies a review to the objections: updates the named ones, numbers the new ones. */
function applyReview(objections: DebateObjection[], review: ReviewArgs, round: number): DebateObjection[] {
	const next = objections.map((o) => ({ ...o, history: [...o.history] }));
	let n = next.reduce((max, o) => Math.max(max, Number(/^O(\d+)$/.exec(o.id)?.[1] ?? 0)), 0);
	for (const r of review.objections ?? []) {
		const existing = r.id ? next.find((o) => o.id === r.id) : undefined;
		if (existing) {
			const action = r.status === "open" ? (existing.status === "open" ? (r.note ? "raised" : undefined) : "reopened") : r.status;
			if (existing.status !== r.status || r.note || existing.text !== r.text) existing.history.push({ round, by: "reviewer", action: action ?? "raised", ...(r.note ? { note: r.note } : {}) });
			existing.text = r.text || existing.text;
			existing.severity = r.severity;
			existing.status = r.status;
			if (r.status !== "open") delete existing.pushback;
			continue;
		}
		const id = r.id && /^O\d+$/.test(r.id) && !next.some((o) => o.id === r.id) ? r.id : `O${++n}`;
		n = Math.max(n, Number(id.slice(1)));
		next.push({ id, text: r.text, severity: r.severity, status: r.status, round, history: [{ round, by: "reviewer", action: r.status === "open" ? "raised" : r.status, ...(r.note ? { note: r.note } : {}) }] });
	}
	return next;
}

/** Two rounds in a row with no new draft and the same open objections. */
function stalled(f: Fold, round: number): boolean {
	if (round < 3) return false;
	return !f.changed.has(round) && !f.changed.has(round - 1) && f.openAfter.get(round) === f.openAfter.get(round - 1);
}

function objectionList(objections: readonly DebateObjection[]): string {
	return objections.map((o) => `- ${o.id} (${o.severity}, ${o.status}): ${o.text}${o.pushback && o.status === "open" ? ` [author's pushback: ${o.pushback}]` : ""}`).join("\n") || "(none)";
}

function clip(t: string, max = 3000): string {
	return t.length > max ? `${t.slice(0, max)}…` : t;
}
