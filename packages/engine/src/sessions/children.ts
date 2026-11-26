/**
 * A conversation's children (docs/spec/26 §7.1): its subagents (`task`, docs/spec/17 §3) and its side conversations
 * (docs/spec/24). Each is a conversation of its own in the catalog, with a link to its parent (`parent` for a subagent,
 * `side` for a side conversation); they share how they run, how their state shows, and how they report back: a note
 * that wakes the parent, at most WAKE_LIMIT times in a row without you, and once for a burst.
 *
 * Everything this needs from the conversations comes through `ChildrenHost`, which Sessions implements.
 */
import { randomUUID } from "node:crypto";
import type { ApprovalMode, ContainerRef, WorkOn } from "@piopio/protocol";
import { EngineError } from "../models.js";
import { git as runGit, status as gitStatus } from "../git.js";
import { BuildRuntime } from "../runtimes/build.js";
import { innerOf } from "../runtimes/segments.js";
import type { TaskResult } from "@piopio/pi-extensions";
import type { Runtime } from "../runtimes/runtime.js";
import type { Settings } from "../settings.js";
import { AGENT_NAMES, runExternalAgent, type ExternalAgent } from "../external-agents.js";
import type { SideBridge, SideLine } from "../tools/side.js";
import type { WatchdogRule } from "../watchdog.js";
import { progressLine } from "../progress-line.js";
import type { CatalogEntry } from "./catalog-entry.js";
import type { Sessions } from "../sessions.js";

/** At most this many subagents run at once per session (docs/spec/05-build §4). */
const MAX_SUBAGENTS = 3;
/** Side conversations (docs/spec/24 §4–§5): at most this many of one parent run at once, and their notes wake it at most this many turns in a row without you. */
const SIDE_MAX = 4;
const WAKE_LIMIT = 5;

export interface ChildrenHost {
	entry(ref: ContainerRef): CatalogEntry;
	get(id: string): CatalogEntry | undefined;
	all(): Iterable<CatalogEntry>;
	create(params: Parameters<Sessions["create"]>[0]): Promise<ContainerRef>;
	runtime(ref: ContainerRef): Promise<Runtime>;
	/** Entries changed: write the catalog; `changed` tells clients about one. */
	save(): void;
	changed(entry: CatalogEntry): void;
	touch(ref: ContainerRef, firstInput?: string): void;
	/** The approval mode a child gets at `place` (never wider than `mode`), and a folder's default. */
	modeAt(place: string, mode: ApprovalMode): ApprovalMode;
	defaultMode(cwd: string): ApprovalMode;
	chatSettings(): ReturnType<Settings["get"]>["chat"] | undefined;
	/** A Watchdog note for a board helper, to the task that made it. */
	noteHelper(project: string, taskId: string, text: string): Promise<void>;
	findExternal(agent: ExternalAgent): string | undefined;
	projectNamed(name: string): { id: string; path: string } | undefined;
	projectNames(): string[];
}

export class Children {
	constructor(private readonly host: ChildrenHost) {}

	// ── Subagents (piopio-subagents, docs/spec/17 §3) ──────────────────────────

	/** Claude Code / Codex tasks running per parent (they wait for a slot; Piopio's own subagents are counted by state). */
	private subagents = new Map<string, { running: number; waiting: (() => void)[] }>();
	/** A blocking `task`'s progress lines, `task_wait`'s waiters, and results nobody has collected yet, by child id. */
	private readonly taskProgress = new Map<string, (line: string) => void>();
	private readonly taskWaiters = new Map<string, ((result: TaskResult) => void)[]>();
	private readonly taskResults = new Map<string, TaskResult>();
	/** The [Task] note each uncollected result went out as, so task_wait can take it back (see withdrawNote). */
	private readonly taskNotes = new Map<string, string>();

	/**
	 * Starts a `task` as a child Build session (same folder, model and approval mode), one level deep, and returns at
	 * once. Past MAX_SUBAGENTS working for one parent it waits as queued. Its result goes back to the parent as a
	 * `[Task]` note (the side conversations' bridge, 26 §7.1), unless `task_wait` collects it.
	 */
	async startTask(parentRef: ContainerRef, task: { callId: string; description: string; prompt: string }): Promise<{ sessionId: string; queued: boolean }> {
		const parent = this.host.entry(parentRef);
		// A child never gets more than its parent: the same profile (a Chat-lens parent has no bash) and the same tools
		// turned off (see `toolsOff` in build(), which also follows later changes to the parent).
		const ref = await this.host.create({ kind: "build", cwd: parent.cwd!, ...(parent.model ? { model: parent.model } : {}), approvalMode: this.host.modeAt(parent.projectPath ?? parent.cwd!, parent.approvalMode ?? this.host.defaultMode(parent.projectPath ?? parent.cwd!)), title: task.description });
		const child = this.host.entry(ref);
		// Counted here, after the await and right before the child takes its place: tasks the model starts in one
		// message run in parallel, and counting before `create` let all of them past the limit.
		const working = this.childrenOf(parent.ref.id).filter((c) => c !== child && c.parent && c.parent.state === "working").length;
		child.parent = { id: parent.ref.id, callId: task.callId, state: working >= MAX_SUBAGENTS ? "queued" : "working", ...(working >= MAX_SUBAGENTS ? {} : { startedAt: new Date().toISOString() }) };
		if (parent.toolsOff?.length) child.toolsOff = [...parent.toolsOff];
		if (parent.projectPath) child.projectPath = parent.projectPath;
		if (child.parent.state === "queued") child.sideBrief = task.prompt;
		this.host.save();
		this.host.changed(child);
		if (child.parent.state === "working") await this.childSubmit(child, task.prompt);
		return { sessionId: ref.id, queued: child.parent.state === "queued" };
	}

	/** One of `parent`'s subagents, or an error for the model. */
	private ownTask(parent: CatalogEntry, id: string): CatalogEntry {
		const child = this.host.get(id);
		if (!child || child.parent?.id !== parent.ref.id) throw new EngineError("NOT_FOUND", `${id} isn't one of this conversation's subagents.`);
		return child;
	}

	/** `task_wait`: their results, as each finishes. A waited-for result doesn't also come back as a note. */
	async waitTasks(parentRef: ContainerRef, ids: readonly string[], signal?: AbortSignal): Promise<TaskResult[]> {
		const parent = this.host.entry(parentRef);
		const children = ids.map((id) => this.ownTask(parent, id));
		return Promise.all(
			children.map(async (child) => {
				const kept = this.taskResults.get(child.ref.id);
				if (kept) {
					this.taskResults.delete(child.ref.id);
					await this.withdrawNote(parent, child.ref.id);
					return kept;
				}
				if (child.parent!.state !== "working" && child.parent!.state !== "queued") return this.taskResultOf(child, await this.host.runtime(child.ref));
				return new Promise<TaskResult>((resolve, reject) => {
					this.taskWaiters.set(child.ref.id, [...(this.taskWaiters.get(child.ref.id) ?? []), resolve]);
					signal?.addEventListener("abort", () => reject(new Error("Stopped waiting.")), { once: true });
				});
			}),
		);
	}

	/**
	 * task_wait collected a result whose [Task] note already went out (the subagent finished while the parent's turn
	 * ran, before it called task_wait): the note leaves the parent's pending notes, or its queue, so it doesn't wake
	 * the parent for a turn about what it already read. A note the model already has stays.
	 */
	private async withdrawNote(parent: CatalogEntry, childId: string): Promise<void> {
		const note = this.taskNotes.get(childId);
		this.taskNotes.delete(childId);
		if (!note) return;
		if (parent.sidePending?.includes(note)) {
			parent.sidePending = parent.sidePending.filter((n) => n !== note);
			this.host.save();
			return;
		}
		const inner = innerOf(await this.host.runtime(parent.ref));
		if (inner instanceof BuildRuntime && (await inner.withdrawQueued(note)) === "message") {
			// That wake won't happen: it doesn't count toward WAKE_LIMIT.
			parent.sideWoke = Math.max(0, (parent.sideWoke ?? 0) - 1);
			this.host.save();
		}
	}

	/** `task_stop`: a queued one won't start; a working one's turn stops. */
	async stopTask(parentRef: ContainerRef, id: string): Promise<string> {
		const child = this.ownTask(this.host.entry(parentRef), id);
		if (child.parent!.state === "queued") {
			delete child.sideBrief;
			this.setChildState(child, "stopped");
			return `${id} won't start.`;
		}
		await (await this.host.runtime(child.ref)).abort();
		return `Stopped ${id}.`;
	}

	private taskResultOf(child: CatalogEntry, runtime: Runtime): TaskResult {
		const snap = runtime.snapshot();
		const last = [...snap.items].reverse().find((i) => i.kind === "assistant");
		const text = last?.kind === "assistant" ? last.parts.filter((p) => p.type === "text").map((p) => p.text).join("") : "";
		const status = last?.kind === "assistant" && last.status === "aborted" ? "stopped" : last?.kind === "assistant" && last.status === "error" ? "error" : "done";
		return { text: status === "error" && last?.kind === "assistant" ? (last.error ?? text) : text, sessionId: child.ref.id, costUsd: snap.state.usage.costUsd, status };
	}

	/** A subagent's turn ended: its result to whoever waits for it, else a [Task] note; the next queued one starts. */
	private async taskSettled(child: CatalogEntry, runtime: Runtime): Promise<void> {
		const result = this.taskResultOf(child, runtime);
		if (child.parent && result.costUsd) child.parent.costUsd = result.costUsd;
		this.setChildState(child, result.status === "error" ? "failed" : result.status);
		const waiters = this.taskWaiters.get(child.ref.id);
		if (waiters?.length) {
			this.taskWaiters.delete(child.ref.id);
			for (const w of waiters) w(result);
		} else {
			this.taskResults.set(child.ref.id, result);
			const word = result.status === "done" ? "finished" : result.status === "error" ? "failed" : "was stopped";
			const text = result.text.length > 8000 ? `${result.text.slice(0, 8000).trimEnd()}… (read the rest with read_conversation ${child.ref.id})` : result.text;
			const note = `[Task] “${child.title}” (${child.ref.id}) ${word}.${result.costUsd ? ` It cost $${result.costUsd.toFixed(2)}.` : ""}${text.trim() ? `\n\n${text.trim().split("\n").map((l) => `> ${l}`).join("\n")}` : ""}`;
			this.taskNotes.set(child.ref.id, note);
			await this.reportToParent(child, note, `Result from ${child.title} · ${result.status === "error" ? "failed" : result.status}`);
		}
		const parentId = child.parent!.id;
		const next = this.childrenOf(parentId).find((c) => c.parent?.state === "queued");
		if (next && this.childrenOf(parentId).filter((c) => c.parent?.state === "working").length < MAX_SUBAGENTS) {
			const prompt = next.sideBrief ?? next.title;
			delete next.sideBrief;
			this.setChildState(next, "working");
			await this.childSubmit(next, prompt);
		}
	}

	/**
	 * A `task` that waits (`wait: true`, Claude Code, Codex): runs it to completion. Piopio's own go through
	 * startTask and wait for it, with their progress on the card.
	 */
	async runTask(
		parent: CatalogEntry,
		task: { callId: string; description: string; prompt: string; agent?: string },
		signal: AbortSignal | undefined,
		onStart: (sessionId: string) => void,
		onProgress: (line: string) => void,
	): Promise<TaskResult> {
		// Claude Code / Codex (external-agents.ts): the user's own CLI, in this folder, with the session's mode.
		if (task.agent === "claude" || task.agent === "codex") {
			const slot = this.subagents.get(parent.ref.id) ?? { running: 0, waiting: [] };
			this.subagents.set(parent.ref.id, slot);
			if (slot.running >= MAX_SUBAGENTS) {
				onProgress("Waiting for another subagent to finish…");
				await new Promise<void>((resolve) => slot.waiting.push(resolve));
			}
			slot.running++;
			try {
				const path = this.host.findExternal(task.agent);
				if (!path) return { text: `${AGENT_NAMES[task.agent]} isn't installed on this Mac.`, sessionId: "", costUsd: 0, status: "error" };
				return await runExternalAgent(task.agent, { path, cwd: parent.cwd!, prompt: task.prompt, mode: this.host.modeAt(parent.projectPath ?? parent.cwd!, parent.approvalMode ?? this.host.defaultMode(parent.projectPath ?? parent.cwd!)), ...(signal ? { signal } : {}), onProgress });
			} finally {
				slot.running--;
				slot.waiting.shift()?.();
			}
		}
		const { sessionId, queued } = await this.startTask(parent.ref, task);
		onStart(sessionId);
		if (queued) onProgress("Waiting for another subagent to finish…");
		this.taskProgress.set(sessionId, onProgress);
		const stop = () => void this.stopTask(parent.ref, sessionId).catch(() => undefined);
		signal?.addEventListener("abort", stop, { once: true });
		try {
			const [result] = await this.waitTasks(parent.ref, [sessionId]);
			return result!;
		} finally {
			this.taskProgress.delete(sessionId);
			signal?.removeEventListener("abort", stop);
		}
	}

	// ── Side conversations (docs/spec/24) ─────────────────────────────────

	/** A conversation's side conversations, oldest first. */
	sidesOf(parentId: string): CatalogEntry[] {
		return [...this.host.all()].filter((e) => e.side?.parent.id === parentId).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
	}

	private sideLine(e: CatalogEntry): SideLine {
		return { id: e.ref.id, title: e.title, state: e.side!.state.replace("_", " "), ...(e.worktree?.branch ? { branch: e.worktree.branch } : {}), ...(e.side!.line ? { line: e.side!.line } : {}) };
	}

	/**
	 * A side conversation of `parentRef`: an ordinary conversation of the same kind in the same project, with the
	 * parent's model and permissions (never wider), in a worktree of its own when it will change files in a git project
	 * (SC5, SC6). The brief is its first message; past SIDE_MAX running, it waits as queued.
	 */
	async startSide(parentRef: ContainerRef, input: { title?: string; brief: string; workOn?: "worktree" | "here"; project?: string }, how: NonNullable<CatalogEntry["side"]>["how"], from?: string): Promise<CatalogEntry> {
		const parent = this.host.entry(parentRef);
		if ((parent.ref.kind !== "build" && parent.ref.kind !== "thread") || parent.parent || parent.helper) throw new EngineError("INVALID", "Only your own conversations start side conversations.");
		const brief = input.brief.trim();
		if (!brief) throw new EngineError("INVALID", "Say what the side conversation should do.");
		const first = brief.split("\n")[0]!.replace(/\s+/g, " ");
		const title = (input.title?.trim() || (first.length > 60 ? `${first.slice(0, 59).trimEnd()}…` : first)).slice(0, 80);
		// In another of your projects when it's plainly about it (SCQ5, 26 CL11): that project's folder and permissions.
		const elsewhere = input.project?.trim() ? this.host.projectNamed(input.project.trim()) : undefined;
		if (input.project?.trim() && !elsewhere) throw new EngineError("NOT_FOUND", `No project called “${input.project.trim()}”.`);
		const folder = elsewhere ? elsewhere.path : parent.ref.kind === "build" ? (parent.projectPath ?? parent.cwd!) : undefined;
		const mode = elsewhere ? this.host.modeAt(elsewhere.path, this.host.defaultMode(elsewhere.path)) : folder ? this.host.modeAt(folder, parent.approvalMode ?? this.host.defaultMode(folder)) : parent.approvalMode;
		let workOn: WorkOn | undefined;
		if (folder && input.workOn !== "here" && mode !== "read_only" && (await gitStatus(folder)).repo) {
			const slug = title.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "side";
			workOn = { kind: "worktree", branch: `side/${slug}-${randomUUID().slice(0, 4)}` };
		}
		const running = this.sidesOf(parent.ref.id).filter((s) => s.side!.state === "working").length;
		const ref = await this.host.create({ kind: elsewhere ? "build" : parent.ref.kind, ...(folder ? { cwd: folder } : {}), ...(parent.model ? { model: parent.model } : {}), ...(parent.thinking ? { thinking: parent.thinking } : {}), ...(mode ? { approvalMode: mode } : {}), ...(parent.profile && !elsewhere ? { profile: parent.profile } : {}), title, ...(workOn ? { workOn } : {}) });
		const child = this.host.entry(ref);
		child.side = { parent: { id: parent.ref.id, title: parent.title }, how, state: running >= SIDE_MAX ? "queued" : "working", ...(from ? { from } : {}) };
		child.sideBy = "parent";
		if (parent.toolsOff?.length && !elsewhere) child.toolsOff = [...parent.toolsOff];
		const opening = `${brief}\n\n(This is a side conversation started from “${parent.title}” (${parent.ref.id}). It works on its own; read that conversation with read_conversation only if you need its background.)`;
		if (child.side.state === "queued") child.sideBrief = opening;
		this.host.save();
		this.host.changed(child);
		if (child.side.state === "working") await this.childSubmit(child, opening);
		return child;
	}

	// ── Children: side conversations and subagents share one bridge (docs/spec/26 §7.1) ──

	/** A side conversation's or a subagent's parent. */
	private parentIdOf(e: CatalogEntry): string | undefined {
		return e.side?.parent.id ?? e.parent?.id;
	}

	/** A conversation's side conversations and subagents. */
	private childrenOf(parentId: string): CatalogEntry[] {
		return [...this.host.all()].filter((e) => this.parentIdOf(e) === parentId);
	}

	private async childSubmit(child: CatalogEntry, text: string): Promise<void> {
		const runtime = await this.host.runtime(child.ref);
		this.watchChild(child, runtime);
		await runtime.submit(text, { whenBusy: "followUp" });
		this.host.touch(child.ref, text);
	}

	private readonly childWatched = new WeakSet<Runtime>();

	/** Follows a child's turns: its live line, its state, and its report to the parent when a turn ends or it needs you. */
	watchChild(child: CatalogEntry, runtime: Runtime): void {
		if (this.childWatched.has(runtime)) return;
		this.childWatched.add(runtime);
		let started = runtime.snapshot().state.status === "running";
		let lineAt = 0;
		let lineTimer: ReturnType<typeof setTimeout> | undefined;
		// At most one line a second; the latest one always lands (a quick read then a long command shows the command).
		const showLine = (link: { line?: string }, line: string) => {
			clearTimeout(lineTimer);
			const wait = 1000 - (Date.now() - lineAt);
			const apply = () => {
				lineAt = Date.now();
				if ((child.side ?? child.parent)?.state !== "working") return;
				link.line = line;
				if (child.parent) delete child.parent.alert;
				this.host.changed(child);
			};
			if (wait <= 0) apply();
			else lineTimer = setTimeout(apply, wait);
		};
		runtime.onEvents((events) => {
			for (const e of events) {
				const link = child.side ?? child.parent;
				if (!link) return;
				if ((e.type === "item.added" || e.type === "item.updated") && e.item.kind === "tool" && e.item.status === "running") {
					const line = progressLine(e.item.tool, e.item.args);
					this.taskProgress.get(child.ref.id)?.(line);
					showLine(link, line);
				}
				if (e.type === "state" && e.state.status === "waiting_approval") this.taskProgress.get(child.ref.id)?.("Waiting for your approval in the subagent…");
				if (e.type !== "state") continue;
				if (e.state.status === "running" && !started) {
					started = true;
					this.setChildState(child, "working");
				} else if (e.state.status === "waiting_approval" && child.side && child.side.state !== "needs_you") {
					this.setChildState(child, "needs_you");
					void this.reportToParent(child, `[Side] “${child.title}” (${child.ref.id}) needs the user: it's waiting for an approval there.`, `Message from ${child.title} · needs you`).catch(() => undefined);
				} else if (e.state.status === "idle" && started) {
					started = false;
					void (child.side ? this.sideSettled(child, runtime) : this.taskSettled(child, runtime)).catch(() => undefined);
				}
			}
		});
	}

	private setChildState(child: CatalogEntry, state: NonNullable<CatalogEntry["side"]>["state"]): void {
		if (child.side) {
			child.side.state = state;
			if (state !== "working") delete child.side.line;
		} else if (child.parent && state !== "needs_you") {
			child.parent.state = state;
			// When its turn started and ended, for its row (docs/spec/37 SB2).
			if (state === "working") {
				child.parent.startedAt = new Date().toISOString();
				delete child.parent.endedAt;
			} else if (state !== "queued") child.parent.endedAt = new Date().toISOString();
			if (state !== "working") delete child.parent.line;
			delete child.parent.alert;
		} else return;
		this.host.save();
		this.host.changed(child);
	}

	/** A side conversation's turn ended: its state, a note to its parent, and the next queued sibling starts. */
	private async sideSettled(child: CatalogEntry, runtime: Runtime): Promise<void> {
		const snap = runtime.snapshot();
		const last = [...snap.items].reverse().find((i) => i.kind === "assistant");
		const answer = last?.kind === "assistant" ? last.parts.filter((p) => p.type === "text").map((p) => p.text).join("").trim() : "";
		const state = last?.kind === "assistant" && last.status === "error" ? "failed" : last?.kind === "assistant" && last.status === "aborted" ? "stopped" : "done";
		this.setChildState(child, state);
		const word = state === "done" ? "finished" : state === "failed" ? "failed" : "was stopped";
		const cut = answer.length > 400 ? `${answer.slice(0, 400).trimEnd()}…` : answer;
		const branch = child.worktree && !child.worktree.finished ? ` Its work is on ${child.worktree.branch}, not in this checkout until the user merges it.` : "";
		const cost = snap.state.usage?.costUsd ? ` It cost $${snap.state.usage.costUsd.toFixed(2)}.` : "";
		await this.reportToParent(child, `[Side] “${child.title}” (${child.ref.id}) ${word}.${branch}${cost}${cut ? `\n\n${cut.split("\n").map((l) => `> ${l}`).join("\n")}` : ""}`, `Message from ${child.title} · ${state}`);
		const parentId = child.side!.parent.id;
		const next = this.sidesOf(parentId).find((s) => s.side!.state === "queued");
		if (next && this.sidesOf(parentId).filter((s) => s.side!.state === "working").length < SIDE_MAX) {
			const brief = next.sideBrief ?? next.title;
			delete next.sideBrief;
			this.setChildState(next, "working");
			await this.childSubmit(next, brief);
		}
	}

	/**
	 * A child's report to its parent (docs/spec/24 SC7, 17 §3). It wakes the parent (a follow-up message) unless you
	 * drove that turn yourself, the parent has been woken WAKE_LIMIT times in a row without you, waking is off for side
	 * conversations, or another child of the parent is still working (then it waits for it, so a burst costs one turn).
	 * A report that doesn't wake is shown and read on the parent's next turn.
	 */
	private async reportToParent(child: CatalogEntry, text: string, summary: string): Promise<void> {
		const parent = this.host.get(this.parentIdOf(child) ?? "");
		if (!parent) return;
		const quiet = child.sideBy === "you" || (parent.sideWoke ?? 0) >= WAKE_LIMIT || (!!child.side && this.host.chatSettings()?.sideWake === false);
		if (quiet) {
			const runtime = await this.host.runtime(parent.ref);
			const inner = innerOf(runtime);
			if (inner instanceof BuildRuntime) await inner.sideNote(text, summary);
			return;
		}
		parent.sidePending = [...(parent.sidePending ?? []), text];
		this.host.save();
		if (this.childrenOf(parent.ref.id).some((c) => c !== child && (c.side?.state === "working" || c.parent?.state === "working"))) return;
		const notes = parent.sidePending;
		parent.sidePending = [];
		parent.sideWoke = (parent.sideWoke ?? 0) + 1;
		this.host.save();
		const runtime = await this.host.runtime(parent.ref);
		await runtime.submit(notes.join("\n\n"), { whenBusy: "followUp" });
		this.host.touch(parent.ref);
	}

	/**
	 * Where a Watchdog note goes (docs/spec/17 §4): a side conversation's or a subagent's to its parent (as its
	 * report), a board helper's to the conversation that made the task, yours to Needs you.
	 */
	watchdogNote(ref: ContainerRef, rule: WatchdogRule, text: string): "elsewhere" | "you" {
		const e = this.host.get(ref.id);
		if (!e) return "you";
		if (e.side || e.parent) {
			const kind = e.side ? "Side" : "Task";
			// On the subagent's row too, until it does something again (docs/spec/37).
			if (e.parent) {
				e.parent.alert = text.replace(/\.\s*$/, "");
				this.host.changed(e);
			}
			void this.reportToParent(e, `[${kind}] “${e.title}” (${e.ref.id}) ${text}`, `${e.side ? "Message" : "Result"} from ${e.title} · ${rule === "silent" ? "looks stuck" : "repeating itself"}`).catch(() => undefined);
			return "elsewhere";
		}
		if (e.helper && this.host.noteHelper) {
			void this.host.noteHelper(e.helper.project, e.helper.taskId, text).catch(() => undefined);
			return "elsewhere";
		}
		return "you";
	}

	/**
	 * A message to a subagent still queued adds to its brief and doesn't start it: it starts in its turn, with the
	 * brief and what you added (docs/spec/37). False when it isn't queued.
	 */
	addToQueuedBrief(ref: ContainerRef, text: string): boolean {
		const entry = this.host.get(ref.id);
		if (entry?.parent?.state !== "queued" || !text.trim()) return false;
		entry.sideBrief = `${entry.sideBrief ?? entry.title}\n\n${text.trim()}`;
		this.host.save();
		this.host.changed(entry);
		return true;
	}

	/** You wrote in a conversation yourself: its side conversations may wake it again, and a side conversation you drive doesn't wake its parent. */
	youWrote(ref: ContainerRef): void {
		const entry = this.host.get(ref.id);
		if (!entry) return;
		entry.sideWoke = 0;
		if (entry.side) entry.sideBy = "you";
		this.host.save();
	}

	/** One of `parent`'s side conversations, or an error for the model. */
	private ownSide(parent: CatalogEntry, id: string): CatalogEntry {
		const child = this.host.get(id);
		if (!child || child.side?.parent.id !== parent.ref.id) throw new EngineError("NOT_FOUND", `${id} isn't one of this conversation's side conversations.`);
		return child;
	}

	/** New conversation answers in a row (SCQ3): after three, the app offers Always start. */
	private sideStreak = 0;

	private sideSettings(): { onUnrelated: "ask" | "start" | "off"; propose: boolean } {
		const chat = this.host.chatSettings();
		return { onUnrelated: chat?.sideOnUnrelated ?? "ask", propose: chat?.sidePropose !== false };
	}

	/** Whether the turn now running began with your own words (not a note, the board or a routine). */
	private async yourTurn(entry: CatalogEntry): Promise<boolean> {
		const user = [...(await this.host.runtime(entry.ref)).snapshot().items].reverse().find((i) => i.kind === "user");
		return !!user && user.kind === "user" && !/^\[(Side|Task|Board|Routine|Automation|PR)\]/.test(user.text);
	}

	/**
	 * Your answer to a side card (docs/spec/24 §1): an offer's New conversation or Do it here, a proposal's Start or
	 * Dismiss. Each card is answered once.
	 */
	async answerSide(ref: ContainerRef, id: string, choice: "new" | "here" | "start" | "dismiss"): Promise<{ ref?: ContainerRef; askAlways?: boolean }> {
		const entry = this.host.entry(ref);
		if (choice === "new" || choice === "here") {
			const offer = entry.sideOffers?.[id];
			if (!offer) throw new EngineError("NOT_FOUND", "That offer isn't here.");
			if (offer.answered) throw new EngineError("INVALID", offer.answered === "new" ? "It already has its own conversation." : "You chose to do it here.");
			offer.answered = choice;
			this.host.save();
			if (choice === "here") {
				this.sideStreak = 0;
				this.youWrote(ref);
				await (await this.host.runtime(ref)).submit("Do it here.", { whenBusy: "followUp" });
				this.host.touch(ref);
				return {};
			}
			// Its brief: the part of your words the offer named, else your whole message (§3: a fresh conversation would do it from your words alone).
			const user = [...(await this.host.runtime(ref)).snapshot().items].reverse().find((i) => i.kind === "user");
			const brief = offer.brief?.trim() || (user?.kind === "user" ? user.text : offer.title);
			const child = await this.startSide(ref, { title: offer.title, brief, ...(offer.project ? { project: offer.project } : {}) }, "offered", id);
			this.sideStreak++;
			return { ref: child.ref, ...(this.sideStreak >= 3 && this.sideSettings().onUnrelated === "ask" ? { askAlways: true } : {}) };
		}
		const proposal = entry.sideProposals?.find((p) => p.id === id);
		if (!proposal) throw new EngineError("NOT_FOUND", "That proposal is gone (started, dismissed or expired).");
		const brief = entry.sideBriefs?.[id] ?? proposal.title;
		this.dropProposal(entry, id);
		if (choice === "dismiss") return {};
		const child = await this.startSide(ref, { title: proposal.title, brief, ...(proposal.project ? { project: proposal.project } : {}) }, "proposed", id);
		return { ref: child.ref };
	}

	private dropProposal(entry: CatalogEntry, id: string): void {
		entry.sideProposals = entry.sideProposals?.filter((p) => p.id !== id);
		if (!entry.sideProposals?.length) delete entry.sideProposals;
		if (entry.sideBriefs) delete entry.sideBriefs[id];
		this.host.save();
		this.host.changed(entry);
	}

	/** The side tools for one of your conversations (tools/side.ts). */
	sideBridge(entry: CatalogEntry): SideBridge {
		return {
			settings: () => this.sideSettings(),
			projects: () => (entry.ref.kind === "thread" ? (this.host.projectNames() ?? []) : []),
			list: () => [
				...this.sidesOf(entry.ref.id).map((s) => this.sideLine(s)),
				...(entry.sideProposals ?? []).filter((p) => Date.parse(p.expiresAt) > Date.now()).map((p) => ({ id: p.id, title: p.title, state: "proposed" })),
			],
			offer: async (callId, input) => {
				if (this.sideSettings().onUnrelated === "off") throw new EngineError("INVALID", "The user turned these offers off: do the work here.");
				if (!(await this.yourTurn(entry))) throw new EngineError("INVALID", "Offer a side conversation only for the user's own message.");
				if (input.project?.trim() && !this.host.projectNamed(input.project.trim())) throw new EngineError("NOT_FOUND", `No project called “${input.project.trim()}”.`);
				entry.sideOffers = { ...entry.sideOffers, [callId]: { title: input.title.trim(), ...(input.brief?.trim() ? { brief: input.brief.trim() } : {}), ...(input.project?.trim() ? { project: input.project.trim() } : {}) } };
				this.host.save();
				return "Offered: the card shows the user both choices. End your turn now, with nothing more or one short line; don't restate the choices or ask anything else.";
			},
			propose: async (callId, input) => {
				if (!this.sideSettings().propose) throw new EngineError("INVALID", "The user turned proposals off.");
				const open = (entry.sideProposals ?? []).filter((p) => Date.parse(p.expiresAt) > Date.now());
				if (open.some((p) => p.title.toLowerCase() === input.title.trim().toLowerCase())) throw new EngineError("INVALID", "That's already proposed.");
				if (open.length >= 6) throw new EngineError("INVALID", "Six proposals are waiting already: dismiss one first.");
				if (input.project?.trim() && !this.host.projectNamed(input.project.trim())) throw new EngineError("NOT_FOUND", `No project called “${input.project.trim()}”.`);
				entry.sideProposals = [...open, { id: callId, title: input.title.trim(), why: input.why.trim(), ...(input.project?.trim() ? { project: input.project.trim() } : {}), expiresAt: new Date(Date.now() + 7 * 86_400_000).toISOString() }];
				entry.sideBriefs = { ...entry.sideBriefs, [callId]: input.brief.trim() };
				this.host.save();
				this.host.changed(entry);
				return `Proposed as ${callId}. The user may start it until it expires in a week.`;
			},
			dismiss: async (id) => {
				if (!entry.sideProposals?.some((p) => p.id === id)) throw new EngineError("NOT_FOUND", `No proposal ${id}.`);
				this.dropProposal(entry, id);
				return `Withdrew ${id}.`;
			},
			start: async (input, callId) => {
				// Only on the user's own words: a turn a note, the board or a routine started can't start one (§4).
				if (!(await this.yourTurn(entry))) throw new EngineError("INVALID", "Start a side conversation only when the user asks for separate work in their own message.");
				return this.sideLine(await this.startSide(entry.ref, input, "asked", callId));
			},
			send: async (id, message) => {
				const child = this.ownSide(entry, id);
				child.sideBy = "parent";
				if (child.side!.state === "queued") {
					child.sideBrief = `${child.sideBrief ?? ""}\n\n${message}`;
					this.host.save();
					return `Added to ${id}'s brief; it starts when there's room.`;
				}
				await this.childSubmit(child, message);
				return `Sent to ${id}.`;
			},
			read: async (id, from = 0) => {
				const child = this.ownSide(entry, id);
				const snap = (await this.host.runtime(child.ref)).snapshot();
				const last = [...snap.items].reverse().find((i) => i.kind === "assistant");
				const answer = last?.kind === "assistant" ? last.parts.filter((p) => p.type === "text").map((p) => p.text).join("").trim() : "";
				const part = answer.slice(from, from + 6000);
				const changed = child.worktree ? (await runGit(child.cwd!, ["diff", "--stat", `${child.worktree.base ?? "HEAD"}...HEAD`]).catch(() => "")).trim() : "";
				const uncommitted = child.worktree ? (await runGit(child.cwd!, ["status", "--short"]).catch(() => "")).trim() : "";
				return [
					`${child.title} (${id}) · ${child.side!.state.replace("_", " ")}${child.worktree ? ` · branch ${child.worktree.branch}${child.worktree.finished ? ` (${child.worktree.finished})` : ""}` : ""} · $${(snap.state.usage?.costUsd ?? 0).toFixed(2)}`,
					changed ? `Committed on its branch:\n${changed}` : "",
					uncommitted ? `Changed and not committed:\n${uncommitted}` : "",
					`Its last answer${from ? ` from character ${from}` : ""}:\n${part || "(none yet)"}`,
					from + 6000 < answer.length ? `(More: side_read with from ${from + 6000}.)` : "",
				]
					.filter(Boolean)
					.join("\n\n");
			},
			stop: async (id) => {
				const child = this.ownSide(entry, id);
				if (child.side!.state === "queued") {
					delete child.sideBrief;
					this.setChildState(child, "stopped");
					return `${id} won't start.`;
				}
				await (await this.host.runtime(child.ref)).abort();
				return `Stopped ${id}'s turn.`;
			},
		};
	}
}
