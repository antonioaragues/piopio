/**
 * Session catalog + open runtimes. Phase 0 keeps the catalog in a JSON index;
 * it moves to catalog.db (SQLite + FTS) with the Phase 1 sidebar.
 */
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, watch, writeFileSync, type FSWatcher } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { ApprovalMode, ApprovalRule, ContainerRef, ModelRef, PromptResponse, SessionSummary, WorkOn } from "@piopio/protocol";
import { EngineError, type ModelHub } from "./models.js";
import type { EnginePaths } from "./paths.js";
import { CheckpointStore } from "./checkpoints.js";
import { addWorktree, checkout, mergeWorktree, removeWorktree, status as gitStatus } from "./git.js";
import { BuildRuntime } from "./runtimes/build.js";
import type { TaskResult } from "@piopio/pi-extensions";
import type { Runtime } from "./runtimes/runtime.js";
import { DatabaseSync } from "node:sqlite";
import { ThreadRuntime, type BranchState } from "./runtimes/thread.js";
import type { WebOptions } from "./tools/web.js";
import { exportTranscript, type ExportFormat } from "./export.js";
import { SearchIndex } from "./search.js";
import type { SessionEvent } from "@piopio/protocol";

type CatalogEntry = SessionSummary & {
	thinking?: string;
	file?: string;
	sessionFile?: string;
	/** The pi session file was seen on disk, so its disappearance means it was deleted. */
	onDisk?: boolean;
	branches?: BranchState;
	web?: boolean;
	/** Build: the session's approval mode (new sessions take their project's). */
	approvalMode?: ApprovalMode;
	/** Build: plan mode (piopio-plan). */
	planMode?: boolean;
};

/** At most this many subagents run at once per session (docs/spec/05-build §4). */
const MAX_SUBAGENTS = 3;

/** Where Build sessions get their default approval mode and "always allow" rules (the projects). */
export type ApprovalPolicy = {
	/** The project that contains `cwd` (worktrees live under the project's id). */
	projectFor(cwd: string): { id: string; path: string } | undefined;
	modeFor(cwd: string): ApprovalMode;
	rulesFor(cwd: string): ApprovalRule[];
	addRule(cwd: string, rule: { kind: ApprovalRule["kind"]; pattern: string }): void;
};

export const newId = (prefix: string) => `${prefix}_${randomUUID().replaceAll("-", "").slice(0, 20)}`;

export type CatalogListener = (change: { upserted: SessionSummary[]; removed: ContainerRef[] }) => void;

export class Sessions {
	private entries = new Map<string, CatalogEntry>();
	private open = new Map<string, Promise<Runtime>>();
	private listeners = new Set<CatalogListener>();
	readonly search: SearchIndex;
	readonly checkpoints: CheckpointStore;
	policy: ApprovalPolicy = { projectFor: () => undefined, modeFor: () => "auto_edit", rulesFor: () => [], addRule: () => {} };
	/** A Build session needs the user (a new prompt) or told them something (notify_user). */
	onAttention?: (change: { ref: ContainerRef; title: string; kind: "waiting" | "notify"; message: string }) => void;

	constructor(
		private readonly paths: EnginePaths,
		private readonly hub: ModelHub,
		private readonly piOverrides: { piSessionDir?: string; piAgentDir?: string; trashDir?: string } = {},
		private readonly webOptions: WebOptions = {},
	) {
		this.search = new SearchIndex(join(paths.home, "search.db"));
		this.checkpoints = new CheckpointStore(join(paths.home, "checkpoints"));
		if (existsSync(paths.catalogIndex)) {
			for (const e of JSON.parse(readFileSync(paths.catalogIndex, "utf8")) as CatalogEntry[]) this.entries.set(e.ref.id, e);
		}
	}

	get openCount(): number {
		return this.open.size;
	}

	list(kind?: string): SessionSummary[] {
		return [...this.entries.values()]
			.filter((e) => !kind || e.ref.kind === kind)
			.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
			.map(summary);
	}

	onChange(listener: CatalogListener): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	private changed(entry: CatalogEntry): void {
		for (const l of this.listeners) l({ upserted: [summary(entry)], removed: [] });
	}

	async configure(ref: ContainerRef, change: { model?: ModelRef; thinking?: string; web?: boolean; approvalMode?: ApprovalMode; planMode?: boolean }): Promise<void> {
		const entry = this.entry(ref);
		if (change.approvalMode) entry.approvalMode = change.approvalMode; // read by the runtime's approvals bridge
		if (change.planMode !== undefined) entry.planMode = change.planMode;
		if (this.open.has(ref.id)) await (await this.runtime(ref)).configure(change);
		if (change.web !== undefined) entry.web = change.web;
		if (change.model) entry.model = change.model;
		if (change.thinking === "default") delete entry.thinking;
		else if (change.thinking) entry.thinking = change.thinking;
		this.save();
		this.changed(entry);
	}

	rename(ref: ContainerRef, title: string): void {
		const entry = this.entry(ref);
		entry.title = title.trim().slice(0, 120) || entry.title;
		this.search.setTitle(ref.id, entry.title, entry.updatedAt);
		this.save();
		this.changed(entry);
	}

	/** Full-text search across sessions, with the catalog's titles and refs. */
	find(query: string, limit = 30) {
		return this.search.search(query, limit).flatMap((hit) => {
			const entry = this.entries.get(hit.sessionId);
			return entry ? [{ ref: entry.ref, title: entry.title, ...(hit.itemId ? { itemId: hit.itemId } : {}), kind: hit.kind, snippet: hit.snippet, at: hit.at }] : [];
		});
	}

	/** Indexes threads that were never indexed (or with an older index version), one at a time. */
	async backfillSearch(): Promise<number> {
		let count = 0;
		for (const entry of [...this.entries.values()]) {
			if (entry.ref.kind !== "thread" || this.search.isIndexed(entry.ref.id) || !this.entries.has(entry.ref.id)) continue;
			const wasOpen = this.open.has(entry.ref.id);
			try {
				const runtime = await this.runtime(entry.ref); // indexes on open
				if (!wasOpen && this.open.get(entry.ref.id)) {
					this.open.delete(entry.ref.id);
					await runtime.close();
				}
				count++;
			} catch {
				// unreadable session: skip; it is retried on the next start
			}
		}
		return count;
	}

	/** Keeps the search index in step with what the session shows. */
	private index(entry: CatalogEntry, events: readonly SessionEvent[]): void {
		const id = entry.ref.id;
		for (const event of events) {
			switch (event.type) {
				case "item.added":
				case "item.updated":
					this.search.upsertItem(id, event.item);
					break;
				case "item.replaced":
					this.search.upsertItem(id, event.item, event.oldId);
					break;
				case "item.removed":
					this.search.removeItem(id, event.itemId);
					break;
				case "resnapshot":
					this.search.replaceSession(id, entry.title, entry.updatedAt, event.snapshot.items);
					break;
			}
		}
	}

	/**
	 * Copies a thread into a new one that continues from `itemId` (inclusive) of the active branch.
	 * The SQLite file is copied with VACUUM INTO, so the source can stay open.
	 */
	async fork(ref: ContainerRef, itemId: string): Promise<ContainerRef> {
		const source = this.entry(ref);
		if (ref.kind !== "thread" || !source.file) throw new EngineError("INVALID", "Only threads can be branched into a new session for now.");
		const runtime = await this.runtime(ref);
		if (runtime.snapshot().state.status === "running") throw new EngineError("BUSY", "Wait for the answer to finish before branching into a new thread.");
		const copy: CatalogEntry = {
			...structuredClone(source),
			ref: { kind: "thread", id: newId("thr") },
			title: `${source.title} (branch)`,
			createdAt: new Date().toISOString(),
			updatedAt: new Date().toISOString(),
			branches: { ...(source.branches?.active ? { active: source.branches.active } : {}), activity: {} },
		};
		copy.file = join(this.paths.threadsDir, `${copy.ref.id}.sqlite`);
		const db = new DatabaseSync(source.file, { readOnly: true });
		try {
			db.exec(`VACUUM INTO '${copy.file.replaceAll("'", "''")}'`);
		} finally {
			db.close();
		}
		this.entries.set(copy.ref.id, copy);
		this.save();
		try {
			const forked = (await this.runtime(copy.ref)) as ThreadRuntime;
			await forked.startAt(itemId);
		} catch (error) {
			await this.delete(copy.ref).catch(() => undefined);
			throw error;
		}
		this.changed(copy);
		return copy.ref;
	}

	async export(ref: ContainerRef, format: ExportFormat) {
		const entry = this.entry(ref);
		return exportTranscript(entry.title, (await this.runtime(ref)).snapshot().items, format);
	}

	/**
	 * Threads lose their history file. A build session's pi file goes to the Trash (it would be found
	 * again on disk otherwise, and the pi CLI would still list it).
	 */
	async delete(ref: ContainerRef): Promise<void> {
		const entry = this.entry(ref);
		const runtime = this.open.get(ref.id);
		this.open.delete(ref.id);
		if (runtime) await (await runtime.catch(() => undefined))?.close();
		if (entry.file) for (const suffix of ["", "-wal", "-shm"]) rmSync(entry.file + suffix, { force: true });
		if (entry.sessionFile && existsSync(entry.sessionFile)) moveToTrash(entry.sessionFile, this.piOverrides.trashDir ?? join(homedir(), ".Trash"));
		this.search.deleteSession(ref.id);
		this.entries.delete(ref.id);
		this.save();
		for (const l of this.listeners) l({ upserted: [], removed: [entry.ref] });
	}

	private entry(ref: ContainerRef): CatalogEntry {
		const entry = this.entries.get(ref.id);
		if (!entry || entry.ref.kind !== ref.kind) throw new EngineError("NOT_FOUND", `No ${ref.kind} ${ref.id}`);
		return entry;
	}

	async create(params: { kind: "thread" | "build"; cwd?: string; model?: ModelRef; thinking?: string; title?: string; workOn?: WorkOn; approvalMode?: ApprovalMode }): Promise<ContainerRef> {
		if (params.kind === "build" && !params.cwd) throw new EngineError("INVALID", "Build sessions need a cwd.");
		if (params.kind === "build" && !existsSync(params.cwd!)) throw new EngineError("INVALID", `No such folder: ${params.cwd}`);
		const ref: ContainerRef = { kind: params.kind, id: newId(params.kind === "thread" ? "thr" : "ses") };
		// Build: a new branch in the project, or a worktree of its own (BP5) under <data>/worktrees/<project>/<session>.
		let cwd = params.cwd;
		let worktree: CatalogEntry["worktree"];
		if (params.kind === "build" && params.workOn && params.workOn.kind !== "current") {
			const base = params.workOn.base ?? (await gitStatus(params.cwd!)).branch ?? "HEAD";
			if (params.workOn.kind === "branch") {
				await checkout(params.cwd!, params.workOn.branch, true, params.workOn.base);
			} else {
				const project = this.policy.projectFor(params.cwd!);
				cwd = join(this.paths.home, "worktrees", project?.id ?? "other", ref.id);
				await addWorktree(params.cwd!, cwd, params.workOn.branch, base);
				worktree = { branch: params.workOn.branch, base };
			}
		}
		const now = new Date().toISOString();
		const entry: CatalogEntry = {
			ref,
			title: params.title ?? (params.kind === "thread" ? "New thread" : "New session"),
			createdAt: now,
			updatedAt: now,
			model: params.model ?? this.hub.defaultModel,
			...(cwd ? { cwd } : {}),
			...(worktree ? { projectPath: params.cwd!, worktree } : {}),
			...(params.thinking ? { thinking: params.thinking } : {}),
			...(params.kind === "build" ? { approvalMode: params.approvalMode ?? this.policy.modeFor(params.cwd!) } : {}),
			...(params.kind === "thread" ? { file: join(this.paths.threadsDir, `${ref.id}.sqlite`) } : {}),
		};
		this.entries.set(ref.id, entry);
		this.save();
		this.changed(entry);
		return ref;
	}

	async runtime(ref: ContainerRef): Promise<Runtime> {
		const entry = this.entry(ref);
		let pending = this.open.get(ref.id);
		if (!pending) {
			pending = this.openRuntime(entry);
			this.open.set(ref.id, pending);
			pending.catch(() => this.open.delete(ref.id));
		}
		return pending;
	}

	/**
	 * Ends a worktree session: merges its branch into the base (in the project's checkout) or discards both.
	 * The worktree is removed; the session goes on in the project folder.
	 */
	async finish(ref: ContainerRef, action: "merge" | "discard"): Promise<void> {
		const entry = this.entry(ref);
		if (!entry.worktree || !entry.projectPath) throw new EngineError("INVALID", "This session doesn't have a worktree.");
		if (entry.worktree.finished) throw new EngineError("INVALID", `This worktree was already ${entry.worktree.finished}.`);
		const runtime = this.open.get(ref.id);
		if (runtime) {
			const r = await runtime.catch(() => undefined);
			if (r?.snapshot().state.status === "running") throw new EngineError("BUSY", "Stop the agent first.");
		}
		if (action === "merge") await mergeWorktree(entry.projectPath, entry.cwd!, entry.worktree.branch, entry.worktree.base);
		else await removeWorktree(entry.projectPath, entry.cwd!, entry.worktree.branch, true);
		this.open.delete(ref.id);
		if (runtime) await (await runtime.catch(() => undefined))?.close();
		entry.worktree = { ...entry.worktree, finished: action === "merge" ? "merged" : "discarded" };
		entry.cwd = entry.projectPath;
		entry.updatedAt = new Date().toISOString();
		this.save();
		this.changed(entry);
	}

	// ── Subagents (piopio-subagents) ─────────────────────────────────────────

	private subagents = new Map<string, { running: number; waiting: (() => void)[] }>();

	/**
	 * Runs a `task` as a child Build session (same folder, model and approval mode), one level deep,
	 * at most MAX_SUBAGENTS at a time per parent. Its final answer goes back to the parent.
	 */
	private async runTask(
		parent: CatalogEntry,
		task: { callId: string; description: string; prompt: string },
		signal: AbortSignal | undefined,
		onStart: (sessionId: string) => void,
		onProgress: (line: string) => void,
	): Promise<TaskResult> {
		const slot = this.subagents.get(parent.ref.id) ?? { running: 0, waiting: [] };
		this.subagents.set(parent.ref.id, slot);
		if (slot.running >= MAX_SUBAGENTS) {
			onProgress("Waiting for another subagent to finish…");
			await new Promise<void>((resolve) => slot.waiting.push(resolve));
		}
		slot.running++;
		try {
			const ref = await this.create({ kind: "build", cwd: parent.cwd!, ...(parent.model ? { model: parent.model } : {}), approvalMode: parent.approvalMode ?? this.policy.modeFor(parent.projectPath ?? parent.cwd!), title: task.description });
			const child = this.entry(ref);
			child.parent = { id: parent.ref.id, callId: task.callId };
			if (parent.projectPath) child.projectPath = parent.projectPath;
			this.save();
			this.changed(child);
			onStart(ref.id);
			const runtime = await this.build(ref);
			let started = false;
			let off = () => {};
			const settled = new Promise<void>((resolve) => {
				off = runtime.onEvents((events) => {
					for (const e of events) {
						if ((e.type === "item.added" || e.type === "item.updated") && e.item.kind === "tool" && e.item.status === "running") onProgress(progressLine(e.item.tool, e.item.args));
						if (e.type === "state" && e.state.status === "waiting_approval") onProgress("Waiting for your approval in the subagent…");
						if (e.type === "state" && e.state.status === "running") started = true;
						if (e.type === "state" && e.state.status === "idle" && started) resolve();
					}
				});
			});
			const stop = () => void runtime.abort();
			signal?.addEventListener("abort", stop, { once: true });
			try {
				await runtime.submit(task.prompt, { whenBusy: "reject" });
				this.touch(ref);
				await settled;
			} finally {
				off();
				signal?.removeEventListener("abort", stop);
			}
			const snap = runtime.snapshot();
			const last = [...snap.items].reverse().find((i) => i.kind === "assistant");
			const text = last?.kind === "assistant" ? last.parts.filter((p) => p.type === "text").map((p) => p.text).join("") : "";
			const status = signal?.aborted || last?.status === "aborted" ? "stopped" : last?.status === "error" ? "error" : "done";
			return { text: status === "error" ? (last?.kind === "assistant" ? (last.error ?? text) : text) : text, sessionId: ref.id, costUsd: snap.state.usage.costUsd, status };
		} finally {
			slot.running--;
			slot.waiting.shift()?.();
		}
	}

	/** Folders git may run in: a project, or a Build session's worktree. */
	knowsFolder(cwd: string): boolean {
		return Boolean(this.policy.projectFor(cwd)) || [...this.entries.values()].some((e) => e.ref.kind === "build" && e.cwd === cwd);
	}

	/** A Build session's runtime (checkpoints, approvals). */
	async build(ref: ContainerRef): Promise<BuildRuntime> {
		const runtime = await this.runtime(ref);
		if (!(runtime instanceof BuildRuntime)) throw new EngineError("INVALID", "Only Build sessions have checkpoints and approvals.");
		return runtime;
	}

	/** Answers a pending prompt of a Build session. */
	async respond(ref: ContainerRef, promptId: string, response: PromptResponse): Promise<void> {
		const runtime = await this.runtime(ref);
		if (!(runtime instanceof BuildRuntime)) throw new EngineError("INVALID", "Only Build sessions ask for approval.");
		runtime.respond(promptId, response);
	}

	/** Called after a submit: bumps recency and auto-titles from the first input. */
	touch(ref: ContainerRef, firstInput?: string): void {
		const entry = this.entries.get(ref.id);
		if (!entry) return;
		entry.updatedAt = new Date().toISOString();
		if (firstInput && (entry.title === "New thread" || entry.title === "New session")) {
			entry.title = titleFrom(firstInput) || entry.title;
			this.search.setTitle(ref.id, entry.title, entry.updatedAt);
		}
		this.save();
		this.changed(entry);
	}

	// ── pi session discovery (docs/spec/05-build BP3) ──────────────────────

	private watcher?: FSWatcher;

	/** pi's session folder for `cwd`: `<agentDir>/sessions/--path-with-dashes--`, or the test override. */
	private piSessionDir(cwd: string): string {
		if (this.piOverrides.piSessionDir) return this.piOverrides.piSessionDir;
		return join(this.piSessionsRoot(), `--${resolve(cwd).replace(/^\//, "").replace(/[/:]/g, "-")}--`);
	}

	private piSessionsRoot(): string {
		return this.piOverrides.piSessionDir ?? join(this.piOverrides.piAgentDir ?? join(homedir(), ".pi", "agent"), "sessions");
	}

	/**
	 * Brings the catalog in line with pi's session files for `cwd`: sessions started with the pi CLI
	 * appear, and sessions whose files were deleted go away.
	 */
	async syncFolder(cwd: string): Promise<void> {
		let infos: Awaited<ReturnType<typeof SessionManager.list>>;
		try {
			infos = await SessionManager.list(cwd, this.piSessionDir(cwd));
		} catch {
			return;
		}
		const byFile = new Map([...this.entries.values()].filter((e) => e.sessionFile).map((e) => [e.sessionFile!, e]));
		const upserted: CatalogEntry[] = [];
		for (const info of infos) {
			const modified = info.modified.toISOString();
			const entry = byFile.get(info.path);
			if (entry) {
				let changed = !entry.onDisk;
				entry.onDisk = true;
				if (!this.open.has(entry.ref.id) && modified > entry.updatedAt) {
					entry.updatedAt = modified;
					if (info.name) entry.title = info.name;
					changed = true;
				}
				if (changed) upserted.push(entry);
				continue;
			}
			const created: CatalogEntry = {
				ref: { kind: "build", id: newId("ses") },
				title: info.name ?? (titleFrom(info.firstMessage) || "Untitled session"),
				createdAt: info.created.toISOString(),
				updatedAt: modified,
				cwd,
				model: this.hub.defaultModel,
				sessionFile: info.path,
				onDisk: true,
			};
			this.entries.set(created.ref.id, created);
			upserted.push(created);
		}
		const removed = [...this.entries.values()].filter(
			(e) => e.ref.kind === "build" && e.cwd === cwd && e.onDisk && e.sessionFile && !existsSync(e.sessionFile) && !this.open.has(e.ref.id),
		);
		for (const e of removed) {
			this.entries.delete(e.ref.id);
			this.search.deleteSession(e.ref.id);
		}
		if (!upserted.length && !removed.length) return;
		this.save();
		const change = { upserted: upserted.map(summary), removed: removed.map((e) => e.ref) };
		for (const l of this.listeners) l(change);
	}

	/** Re-syncs folders when pi writes session files from outside this engine (the CLI). */
	watchPiSessions(folders: () => string[]): void {
		const root = this.piSessionsRoot();
		mkdirSync(root, { recursive: true });
		const dirty = new Set<string>();
		let timer: NodeJS.Timeout | undefined;
		this.watcher = watch(root, { recursive: true }, (_event, name) => {
			if (!name?.endsWith(".jsonl")) return;
			const file = join(root, name);
			// Our own sessions write as they stream; their catalog entries are already current.
			if ([...this.entries.values()].some((e) => e.sessionFile === file && this.open.has(e.ref.id))) return;
			const dir = join(root, dirname(name));
			for (const cwd of folders()) if (this.piSessionDir(cwd) === dir || this.piOverrides.piSessionDir) dirty.add(cwd);
			clearTimeout(timer);
			timer = setTimeout(() => {
				const cwds = [...dirty];
				dirty.clear();
				for (const cwd of cwds) void this.syncFolder(cwd);
			}, 300);
		});
	}

	/** Drops the build sessions of a folder from the catalog (the files stay with pi). */
	async forgetFolder(cwd: string): Promise<void> {
		const gone = [...this.entries.values()].filter((e) => e.ref.kind === "build" && e.cwd === cwd);
		for (const e of gone) {
			const runtime = this.open.get(e.ref.id);
			this.open.delete(e.ref.id);
			if (runtime) await (await runtime.catch(() => undefined))?.close();
			this.entries.delete(e.ref.id);
			this.search.deleteSession(e.ref.id);
		}
		if (!gone.length) return;
		this.save();
		for (const l of this.listeners) l({ upserted: [], removed: gone.map((e) => e.ref) });
	}

	async closeAll(): Promise<void> {
		this.watcher?.close();
		const runtimes = await Promise.allSettled(this.open.values());
		this.open.clear();
		await Promise.allSettled(runtimes.map((r) => (r.status === "fulfilled" ? r.value.close() : undefined)));
		this.search.close();
	}

	private async openRuntime(entry: CatalogEntry): Promise<Runtime> {
		const runtime = await this.createRuntime(entry);
		if (!this.search.isIndexed(entry.ref.id)) this.search.replaceSession(entry.ref.id, entry.title, entry.updatedAt, runtime.snapshot().items);
		runtime.onEvents((events) => this.index(entry, events));
		return runtime;
	}

	private async createRuntime(entry: CatalogEntry): Promise<Runtime> {
		const model = entry.model ?? this.hub.defaultModel;
		if (entry.ref.kind === "thread") {
			return ThreadRuntime.open({
				ref: entry.ref,
				file: entry.file!,
				hub: this.hub,
				model,
				...(entry.thinking ? { thinking: entry.thinking } : {}),
				...(entry.branches ? { branches: entry.branches } : {}),
				onBranchState: (state) => {
					entry.branches = state;
					this.save();
				},
				web: entry.web ?? true,
				webOptions: this.webOptions,
			});
		}
		const runtime = await BuildRuntime.open({
			ref: entry.ref,
			hub: this.hub,
			cwd: entry.cwd!,
			model,
			...(entry.thinking ? { thinking: entry.thinking } : {}),
			...(entry.sessionFile ? { sessionFile: entry.sessionFile } : {}),
			...this.piOverrides,
			approvals: {
				mode: () => entry.approvalMode ?? this.policy.modeFor(entry.projectPath ?? entry.cwd!),
				rules: () => this.policy.rulesFor(entry.projectPath ?? entry.cwd!),
				addRule: (rule) => this.policy.addRule(entry.projectPath ?? entry.cwd!, rule),
			},
			checkpoints: this.checkpoints,
			plan: {
				active: () => entry.planMode ?? false,
				setActive: (on) => {
					entry.planMode = on;
					this.save();
				},
			},
			...(entry.parent ? {} : { runTask: (task, signal, onStart, onProgress) => this.runTask(entry, task, signal, onStart, onProgress) }),
			onAttention: (kind, message) => this.onAttention?.({ ref: entry.ref, title: entry.title, kind, message }),
		});
		if (runtime.sessionFile && runtime.sessionFile !== entry.sessionFile) {
			entry.sessionFile = runtime.sessionFile;
			this.save();
		}
		return runtime;
	}

	private save(): void {
		const tmp = `${this.paths.catalogIndex}.tmp`;
		writeFileSync(tmp, JSON.stringify([...this.entries.values()], null, "\t"));
		renameSync(tmp, this.paths.catalogIndex);
	}
}

function summary({ file: _f, sessionFile: _s, onDisk: _d, thinking: _t, ...rest }: CatalogEntry): SessionSummary {
	return rest;
}

/** What a subagent is doing, for its task card. */
function progressLine(tool: string, args: unknown): string {
	const a = (args ?? {}) as Record<string, unknown>;
	const detail = [a.path, a.command, a.pattern, a.query, a.url].find((v) => typeof v === "string") as string | undefined;
	return detail ? `${tool} ${detail.split("\n")[0]!.slice(0, 120)}` : tool;
}

/** Moves a file into the Trash folder under a free name (same volume: a rename). */
function moveToTrash(file: string, trash: string): void {
	mkdirSync(trash, { recursive: true });
	const name = basename(file);
	let target = join(trash, name);
	for (let i = 2; existsSync(target); i++) target = join(trash, name.replace(/(\.[^.]*)?$/, ` ${i}$1`));
	renameSync(file, target);
}

/** A short plain-text title from a first message: markdown markup removed, first line, ≤ 60 chars. */
export function titleFrom(text: string): string {
	const plain = text
		.replace(/```[\s\S]*?(```|$)/g, " ")
		.replace(/^\s*\|.*$/gm, " ")
		.replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
		.replace(/[*_`~#>|]/g, "")
		.replace(/\s+/g, " ")
		.trim();
	if (plain.length <= 60) return plain;
	const cut = plain.slice(0, 60);
	const space = cut.lastIndexOf(" ");
	return `${(space > 30 ? cut.slice(0, space) : cut).trim()}…`;
}
