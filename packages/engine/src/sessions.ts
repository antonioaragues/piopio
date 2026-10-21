/**
 * Session catalog + open runtimes. Phase 0 keeps the catalog in a JSON index;
 * it moves to catalog.db (SQLite + FTS) with the Phase 1 sidebar.
 */
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, watch, writeFileSync, type FSWatcher } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { ApprovalMode, ApprovalRule, ContainerRef, ModelRef, PromptResponse, SessionSummary, SpaceSuggestion, WorkOn } from "@piopio/protocol";
import { EngineError, type ModelHub } from "./models.js";
import type { EnginePaths } from "./paths.js";
import { CheckpointStore } from "./checkpoints.js";
import { addWorktree, checkout, mergeWorktree, removeWorktree, status as gitStatus } from "./git.js";
import { BuildRuntime } from "./runtimes/build.js";
import type { TaskResult } from "@piopio/pi-extensions";
import type { Runtime } from "./runtimes/runtime.js";
import { DatabaseSync } from "node:sqlite";
import { SpaceRuntime, type SpaceStats, type TopicSummary } from "./runtimes/space.js";
import { aboutMeExtension, type AboutMe } from "./about-me.js";
import type { Settings } from "./settings.js";
import type { ChatMcp } from "./tools/mcp-chat.js";
import type { ChatResources } from "./tools/chat-resources.js";
import { AgentRuntime } from "./runtimes/agent.js";
import type { AgentFiles } from "./agent-files.js";
import type { AppServices } from "./app-services.js";
import type { MemoryProviders } from "./memory.js";
import { alwaysLabel, type Envelope, type PeerLog, newDefinition, modelOf, validate, TEMPLATES, type AgentDefinition, type DefinitionError } from "@piopio/runtime";
import type { Extension } from "@earendil-works/pi-durable";
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
	/** Spaces: when you last looked at each topic (unread dots). */
	readAt?: Record<string, string>;
	/** Spaces: the topics as the runtime last reported them. */
	topicState?: TopicSummary[];
	/** Spaces: the organizer's model (default: `model`, the topics'), memory and auto-tidy (§3.6). */
	organizerModel?: ModelRef;
	memoryOff?: boolean;
	autoTidy?: boolean;
	stats?: SpaceStats;
	/** Agents: the definition folder. */
	agentFolder?: string;
	/** Threads: Dismiss on a Space suggestion; and the exchanges a suggestion was already looked for at. */
	suggestionDismissed?: boolean;
	suggestChecked?: number[];
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
	/** Settings, About me and MCP for Threads and Spaces (set by the engine). */
	chat?: { settings: Settings; aboutMe: AboutMe; mcp: ChatMcp; resources: ChatResources };
	/** Agent folders and memory (set by the engine). */
	agentHost?: { files: AgentFiles; memory: MemoryProviders; app?: AppServices };
	/** Each agent's last valid definition, as the runtime uses it. */
	private definitions = new Map<string, { definition: AgentDefinition; instructions: string }>();
	private skillsExtension?: Extension;
	private aboutMeExtensions = new Map<"thread" | "space", Extension>();
	/** A Build session needs the user (a new prompt) or told them something (notify_user). */
	onAttention?: (change: { ref: ContainerRef; title: string; kind: "waiting" | "notify"; message: string }) => void;
	/** How long ask_agent waits (tests shorten it). */
	agentAskTimeoutMs?: number;
	/** The Inbox changed (badges), with the approval an agent just asked for (notifications). */
	onInbox?: (change: { count: number; approval?: { agent: ContainerRef; agentName: string; approvalId: string; title: string } }) => void;

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
		if (entry.ref.kind === "space") rmSync(join(this.paths.spacesDir, entry.ref.id), { recursive: true, force: true });
		if (entry.sessionFile && existsSync(entry.sessionFile)) moveToTrash(entry.sessionFile, this.piOverrides.trashDir ?? join(homedir(), ".Trash"));
		if (entry.ref.kind === "agent") {
			this.agentHost?.memory.builtin.dropBanks(`${entry.ref.id}/`);
			if (entry.agentFolder) this.agentHost?.files.trash(entry.agentFolder, this.piOverrides.trashDir);
			this.definitions.delete(entry.ref.id);
		}
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

	async create(params: { kind: "thread" | "build" | "space"; instructions?: string; cwd?: string; model?: ModelRef; thinking?: string; title?: string; workOn?: WorkOn; approvalMode?: ApprovalMode; profile?: "build" | "chat" }): Promise<ContainerRef> {
		if (params.kind === "build" && !params.cwd) throw new EngineError("INVALID", "Build sessions need a cwd.");
		if (params.kind === "build" && !existsSync(params.cwd!)) throw new EngineError("INVALID", `No such folder: ${params.cwd}`);
		const ref: ContainerRef = { kind: params.kind, id: newId(params.kind === "thread" ? "thr" : params.kind === "space" ? "spc" : "ses") };
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
			title: params.title?.trim() || (params.kind === "thread" ? "New thread" : params.kind === "space" ? "New Notebook" : "New session"),
			createdAt: now,
			updatedAt: now,
			model: params.model ?? this.hub.defaultModel,
			...(cwd ? { cwd } : {}),
			...(worktree ? { projectPath: params.cwd!, worktree } : {}),
			...(params.thinking ? { thinking: params.thinking } : {}),
			...(params.kind === "build" ? { approvalMode: params.approvalMode ?? this.policy.modeFor(params.cwd!), profile: params.profile ?? "build" } : {}),
			...(params.kind === "thread" ? { file: join(this.paths.threadsDir, `${ref.id}.sqlite`) } : {}),
			...(params.kind === "space" ? { file: join(this.paths.spacesDir, `${ref.id}.sqlite`), topics: [], space: { costUsd: 0, files: 0, memoryLines: 0, memory: true, autoTidy: false }, ...(params.instructions?.trim() ? { instructions: params.instructions.trim() } : {}) } : {}),
		};
		this.entries.set(ref.id, entry);
		this.save();
		this.changed(entry);
		return ref;
	}

	async runtime(ref: ContainerRef): Promise<Runtime> {
		if (ref.kind === "space" && ref.conversationId) return (await this.space(ref)).view(ref.conversationId);
		if (ref.kind === "agent" && ref.conversationId?.startsWith("run:")) return (await this.agent(ref)).runView(ref.conversationId.slice(4));
		if (ref.kind === "agent" && ref.conversationId?.startsWith("agent:")) return (await this.agent(ref)).peerView(ref.conversationId.slice(6));
		if (ref.kind === "agent" && ref.conversationId) return (await this.agent(ref)).view(ref.conversationId.replace(/^person:/, ""));
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

	// ── Agents (docs/spec/06-agents) ─────────────────────────────────────────

	async agent(ref: ContainerRef): Promise<AgentRuntime> {
		const runtime = await this.runtime({ kind: "agent", id: ref.id });
		if (!(runtime instanceof AgentRuntime)) throw new EngineError("INVALID", "Not an agent.");
		return runtime;
	}

	private get host() {
		if (!this.agentHost) throw new EngineError("INTERNAL", "Agents aren't set up in this engine.");
		return this.agentHost;
	}

	/** A new local agent from a template (or from scratch): its folder, its git repo, its catalog entry. */
	async createAgent(params: { name: string; template?: string; avatar?: string; model?: ModelRef; owner?: string }): Promise<ContainerRef> {
		const name = params.name.trim();
		if (!name) throw new EngineError("INVALID", "The agent needs a name.");
		if (params.template && !TEMPLATES.some((t) => t.id === params.template)) throw new EngineError("INVALID", `No template “${params.template}”.`);
		const id = `agt_${randomUUID().replaceAll("-", "").slice(0, 16)}`;
		const slug = name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "agent";
		const model = params.model ?? this.hub.defaultModel;
		const folder = this.host.files.folderFor(slug);
		const made = newDefinition({ id, slug: basename(folder), name, owner: params.owner?.trim() || "Owner", model: model.provider === "openrouter" ? model.id : `${model.provider}:${model.id}`, ...(params.template ? { template: params.template } : {}), ...(params.avatar ? { avatar: params.avatar } : {}) });
		await this.host.files.create(folder, made);
		this.definitions.set(id, made);
		const now = new Date().toISOString();
		const entry: CatalogEntry = { ref: { kind: "agent", id }, title: name, createdAt: now, updatedAt: now, file: join(this.paths.home, "agents", `${id}.sqlite`), agentFolder: folder };
		mkdirSync(dirname(entry.file!), { recursive: true });
		this.setAgentInfo(entry, made.definition);
		this.entries.set(id, entry);
		this.save();
		this.changed(entry);
		return entry.ref;
	}

	/** The definition as it is on disk, its errors and history. */
	async getAgent(ref: ContainerRef): Promise<{ definition: unknown; instructions: string; folder: string; errors: DefinitionError[]; history: { commit: string; at: string; message: string }[] }> {
		const entry = this.entry({ kind: "agent", id: ref.id });
		const folder = entry.agentFolder!;
		let definition: unknown;
		let instructions = "";
		let errors: DefinitionError[];
		try {
			const read = this.host.files.read(folder);
			definition = read.definition;
			instructions = read.instructions;
			errors = this.validateAgent(definition, ref.id);
		} catch (error) {
			definition = this.definitions.get(ref.id)?.definition ?? {};
			errors = [{ path: "/", message: `agent.json can't be read: ${(error as Error).message}` }];
		}
		return { definition, instructions, folder, errors, history: await this.host.files.history(folder) };
	}

	/** Validates; with no errors, writes, commits and reconfigures the running agent. */
	async saveAgent(ref: ContainerRef, definition: unknown, instructions: string, message?: string): Promise<{ errors: DefinitionError[]; saved: boolean }> {
		const entry = this.entry({ kind: "agent", id: ref.id });
		const def = definition as AgentDefinition;
		const errors = this.validateAgent(definition, ref.id);
		if (!errors.length && def.id !== ref.id) errors.push({ path: "/id", message: "The id can't change." });
		if (errors.length) return { errors, saved: false };
		const saved = await this.host.files.save(entry.agentFolder!, { definition: def, instructions }, message?.trim() || "Edit the definition");
		this.definitions.set(ref.id, { definition: def, instructions });
		entry.title = def.name;
		this.setAgentInfo(entry, def);
		entry.updatedAt = new Date().toISOString();
		this.save();
		this.changed(entry);
		if (this.open.has(ref.id)) await (await this.agent(ref)).reconfigure();
		return { errors: [], saved };
	}

	async agentConversations(ref: ContainerRef) {
		const def = this.agentDefinition(ref.id).definition;
		const runtime = await this.agent(ref);
		const people = await runtime.people();
		const humans = def.contacts.map((c) => {
			const p = people.find((x) => x.contactId === c.id);
			return { contactId: c.id, name: c.name, role: c.role, conversationId: `person:${c.id}`, started: p?.started ?? false, ...(p?.lastAt ? { lastAt: p.lastAt } : {}), ...(p?.preview ? { preview: p.preview } : {}) };
		});
		const agents = (await runtime.peers()).map((a) => ({ contactId: `agent:${a.id}`, name: a.name, role: "agent" as const, conversationId: `agent:${a.id}`, started: true, ...(a.lastAt ? { lastAt: a.lastAt } : {}), ...(a.preview ? { preview: a.preview } : {}) }));
		return [...humans, ...agents];
	}

	/** Runs, held messages and what fires next (the Runs tab). */
	async agentRuns(ref: ContainerRef) {
		const { runs, outbox, upcoming } = await (await this.agent(ref)).runs();
		const iso = (t: number) => new Date(t).toISOString();
		return {
			runs: runs.map(({ conversationId: _c, deliverTo: _d, ...r }) => r),
			outbox: outbox.map((o) => ({ id: o.id, to: o.to, text: o.text, notBefore: iso(o.notBefore), reason: o.reason })),
			upcoming: upcoming.map((u) => ({ id: u.id, kind: u.kind, label: u.label, ...(u.next ? { next: iso(u.next) } : {}) })),
		};
	}

	/** Opens every agent, so their schedules, reminders and held messages run while the app is closed (06 §6). */
	async startAgents(log: (line: string) => void): Promise<void> {
		for (const entry of [...this.entries.values()].filter((e) => e.ref.kind === "agent")) {
			await this.agent(entry.ref).catch((error: unknown) => log(`Agent ${entry.title}: couldn't start: ${(error as Error).message}`));
			await this.agentStatus(entry);
		}
	}

	/** Agents reaching each other in this engine (06 §7 AA7): who they are, delivery, a trace's cost, shared memory. */
	private peerHost() {
		const agents = () => [...this.entries.values()].filter((e) => e.ref.kind === "agent");
		const defOf = (id: string) => {
			try {
				return this.agentDefinition(id).definition;
			} catch {
				return undefined;
			}
		};
		return {
			directory: async () =>
				agents().flatMap((e) => {
					const def = defOf(e.ref.id);
					return def ? [{ id: def.id, slug: def.slug, name: def.name, ...(def.acceptFrom ? { acceptFrom: def.acceptFrom } : {}) }] : [];
				}),
			deliver: async (to: string, envelope: Envelope) => {
				if (this.entries.get(to)?.ref.kind !== "agent") throw new Error("No such agent.");
				await (await this.agent({ kind: "agent", id: to })).core.peers.receive(envelope);
			},
			traceCost: async (traceId: string) => (await this.traceLogs(traceId)).reduce((n, l) => n + (l.costUsd ?? 0), 0),
			sharedBanks: async (agentId: string) => {
				const me = defOf(agentId);
				return agents().flatMap((e) => {
					const share = defOf(e.ref.id)?.shareMemory;
					const parts = share?.[agentId] ?? (me ? share?.[me.slug] : undefined) ?? [];
					return e.ref.id === agentId ? [] : parts.map((p) => `${e.ref.id}/${p}`);
				});
			},
		};
	}

	/** A trace's messages from every agent's log: the receiver's entry (with its answer and cost) wins. */
	private async traceLogs(traceId: string): Promise<PeerLog[]> {
		const byId = new Map<string, PeerLog>();
		for (const entry of [...this.entries.values()].filter((e) => e.ref.kind === "agent")) {
			const runtime = await this.agent(entry.ref).catch(() => undefined);
			for (const l of (await runtime?.core.peers.logs()) ?? []) {
				if (l.traceId !== traceId) continue;
				const had = byId.get(l.id);
				if (!had || l.side === "in") byId.set(l.id, had && l.side === "in" ? { ...had, ...l, reply: l.reply ?? had.reply } : l);
			}
		}
		return [...byId.values()].sort((a, b) => a.at.localeCompare(b.at));
	}

	/** The trace view (AA5). */
	async agentTrace(traceId: string) {
		const logs = await this.traceLogs(traceId);
		if (!logs.length) throw new EngineError("NOT_FOUND", "No such trace.");
		return {
			traceId,
			costUsd: logs.reduce((n, l) => n + (l.costUsd ?? 0), 0),
			hops: logs
				.filter((l) => l.mode !== "reply")
				.map((l) => ({ id: l.id, ...(l.parent ? { parent: l.parent } : {}), hop: l.hop, mode: l.mode, from: l.from, to: l.to, text: l.text, ...(l.reply ? { reply: l.reply } : {}), at: l.at, status: l.status, ...(l.costUsd !== undefined ? { costUsd: l.costUsd } : {}), ...(l.error ? { error: l.error } : {}) })),
		};
	}

	/** Pause, spend and the Inbox count, from the running agent into the catalog (sidebar, header, badges). */
	private async agentStatus(entry: CatalogEntry): Promise<void> {
		const runtime = await this.open.get(entry.ref.id)?.catch(() => undefined);
		if (!(runtime instanceof AgentRuntime) || !entry.agent) return;
		const status = await runtime.core.safety.status().catch(() => undefined);
		if (!status || !this.entries.has(entry.ref.id)) return;
		const changed = JSON.stringify(status) !== JSON.stringify(entry.agent.status);
		entry.agent.status = status;
		if (changed) {
			this.save();
			this.changed(entry);
		}
		this.onInbox?.({ count: this.inboxCount() });
	}

	/** What waits for you across agents. */
	inboxCount(): number {
		return [...this.entries.values()].reduce((n, e) => n + (e.ref.kind === "agent" ? (e.agent?.status?.inbox ?? 0) : 0), 0);
	}

	/** The Inbox (06 §12): every agent's entries, newest first. */
	async inbox() {
		const items = [];
		for (const entry of [...this.entries.values()].filter((e) => e.ref.kind === "agent")) {
			const runtime = await this.agent(entry.ref).catch(() => undefined);
			if (!runtime) continue;
			const def = runtime.definition();
			for (const e of await runtime.core.safety.entries()) {
				const a = e.approval;
				items.push({
					id: e.id,
					agent: entry.ref,
					agentName: entry.title,
					...(entry.agent?.avatar ? { avatar: entry.agent.avatar } : {}),
					kind: e.kind,
					at: e.at,
					title: e.title,
					body: e.body,
					needsYou: e.needsYou && (a ? true : !e.read),
					read: e.read ?? false,
					...(e.conversation ? { conversationId: e.conversation } : {}),
					...(a
						? {
								approval: {
									kind: "approval" as const,
									id: `approval:${a.id}`,
									at: a.requestedAt,
									approvalId: a.id,
									tool: a.tool,
									title: a.title,
									args: a.args,
									status: a.status,
									...(a.editedArgs ? { editedArgs: a.editedArgs } : {}),
									...(a.reason ? { reason: a.reason } : {}),
									expiresAt: new Date(a.expiresAt).toISOString(),
									always: alwaysLabel(a.key, def),
								},
							}
						: {}),
				});
			}
		}
		items.sort((a, b) => b.at.localeCompare(a.at));
		return { count: this.inboxCount(), items };
	}

	async inboxRead(items: readonly { agentId: string; id: string }[]): Promise<void> {
		const byAgent = new Map<string, string[]>();
		for (const i of items) byAgent.set(i.agentId, [...(byAgent.get(i.agentId) ?? []), i.id]);
		for (const [agentId, ids] of byAgent) await (await this.agent({ kind: "agent", id: agentId })).core.safety.markRead(ids);
	}

	/** A webhook trigger (hooks.ts): the agent must exist and have it. */
	async fireTrigger(agentId: string, triggerId: string, body: string, deliveryId?: string): Promise<{ runId: string }> {
		if (this.entries.get(agentId)?.ref.kind !== "agent") throw new EngineError("NOT_FOUND", "No such agent.");
		const run = await (await this.agent({ kind: "agent", id: agentId })).trigger(triggerId, body, deliveryId);
		return { runId: run.id };
	}

	agentMemory(ref: ContainerRef) {
		const def = this.agentDefinition(ref.id).definition;
		const partitions = [
			{ id: "owner", label: def.contacts.find((c) => c.role === "owner")?.name ?? "Owner", bank: `${def.id}/owner` },
			{ id: "shared", label: "Shared", bank: `${def.id}/shared` },
			...def.contacts.filter((c) => c.role === "contact").map((c) => ({ id: `contacts/${c.id}`, label: c.name, bank: `${def.id}/contacts/${c.id}` })),
		];
		return { provider: def.memory?.provider ?? "builtin", partitions };
	}

	private validateAgent(definition: unknown, id: string): DefinitionError[] {
		const knownAgents = [...this.entries.values()].filter((e) => e.ref.kind === "agent" && e.ref.id !== id).map((e) => e.ref.id);
		return validate(definition, {
			knownAgents,
			knownModels: (m) => {
				const { provider, modelId } = modelOf(m);
				return Boolean(this.hub.models.getModel(provider, modelId));
			},
		});
	}

	/** The last valid definition: from memory, else from disk (falling back to nothing usable). */
	agentDefinition(id: string): { definition: AgentDefinition; instructions: string } {
		let cached = this.definitions.get(id);
		if (!cached) {
			const entry = this.entry({ kind: "agent", id });
			const read = this.host.files.read(entry.agentFolder!);
			if (validate(read.definition).length) {
				entry.agent = entry.agent ? { ...entry.agent, invalid: true } : entry.agent;
				throw new EngineError("INVALID", `${entry.title}'s agent.json doesn't validate; fix it in the Definition tab.`);
			}
			cached = read;
			this.definitions.set(id, cached);
		}
		return cached;
	}

	private setAgentInfo(entry: CatalogEntry, def: AgentDefinition): void {
		const status = entry.agent?.status;
		entry.agent = {
			...(status ? { status } : {}),
			...(def.policies?.requireApproval?.length ? { asksFirst: true } : {}),
			slug: def.slug,
			...(def.avatar ? { avatar: def.avatar } : {}),
			...(def.description ? { description: def.description } : {}),
			folder: entry.agentFolder!,
			location: "local",
			model: def.models.default,
			contacts: def.contacts.map((c) => ({ id: c.id, name: c.name, role: c.role })),
		};
	}

	// ── Spaces (docs/spec/04-chat §3) ─────────────────────────────────────────

	async space(ref: ContainerRef): Promise<SpaceRuntime> {
		const runtime = await this.runtime({ kind: "space", id: ref.id });
		if (!(runtime instanceof SpaceRuntime)) throw new EngineError("INVALID", "Not a Notebook.");
		return runtime;
	}

	/** You looked at a topic (or Main): its unread dot goes. */
	markRead(ref: ContainerRef): void {
		const entry = this.entry({ kind: "space", id: ref.id });
		if (!ref.conversationId) return;
		entry.readAt = { ...entry.readAt, [ref.conversationId]: new Date().toISOString() };
		this.updateTopics(entry, entry.topicState ?? []);
	}

	async configureSpace(ref: ContainerRef, change: { instructions?: string; organizerModel?: ModelRef; topicModel?: ModelRef; memory?: boolean; autoTidy?: boolean }): Promise<void> {
		const entry = this.entry({ kind: "space", id: ref.id });
		for (const m of [change.organizerModel, change.topicModel]) {
			if (m && !this.hub.models.getModel(m.provider, m.id)) throw new EngineError("INVALID", `Unknown model ${m.provider}/${m.id}`);
		}
		if (change.instructions !== undefined) {
			if (change.instructions.trim()) entry.instructions = change.instructions.trim();
			else delete entry.instructions;
		}
		if (change.memory !== undefined) entry.memoryOff = !change.memory;
		if (change.autoTidy !== undefined) entry.autoTidy = change.autoTidy;
		const open = this.open.has(ref.id) ? await this.space(ref) : undefined;
		if (change.organizerModel) {
			entry.organizerModel = change.organizerModel;
			await open?.setOrganizerModel(change.organizerModel);
		}
		if (change.topicModel) {
			entry.model = change.topicModel;
			await open?.setTopicModel(change.topicModel);
		}
		this.setSpaceInfo(entry);
		this.save();
		this.changed(entry);
	}

	private setSpaceInfo(entry: CatalogEntry): void {
		const stats = entry.stats ?? { costUsd: 0, files: 0, memoryLines: 0 };
		entry.space = { ...stats, ...(entry.organizerModel ? { organizerModel: entry.organizerModel } : {}), memory: !entry.memoryOff, autoTidy: entry.autoTidy ?? false };
	}

	private updateTopics(entry: CatalogEntry, topics: TopicSummary[]): void {
		entry.topicState = topics;
		const read = entry.readAt ?? {};
		entry.topics = topics.map((t) => ({
			id: t.id,
			title: t.title,
			...(t.brief ? { brief: t.brief } : {}),
			...(t.summary ? { summary: t.summary } : {}),
			lastActiveAt: t.lastActiveAt,
			...(t.archived ? { archived: true } : {}),
			...(t.lastReplyAt && t.lastReplyAt > (read[t.id] ?? "") ? { unread: true } : {}),
			...(t.running ? { running: true } : {}),
		}));
		this.setSpaceInfo(entry);
		const latest = topics[0]?.lastActiveAt;
		if (latest && latest > entry.updatedAt) entry.updatedAt = latest;
		this.save();
		this.changed(entry);
	}

	private chatExtras(kind: "thread" | "space"): { extensions?: Extension[]; mcp?: ChatMcp; expand?: (text: string) => string | undefined } {
		if (!this.chat) return {};
		let aboutMe = this.aboutMeExtensions.get(kind);
		if (!aboutMe) {
			aboutMe = aboutMeExtension(this.chat.aboutMe, this.chat.settings, kind) as unknown as Extension;
			this.aboutMeExtensions.set(kind, aboutMe);
		}
		const resources = this.chat.resources;
		this.skillsExtension ??= resources.extension() as unknown as Extension;
		return { extensions: [aboutMe, this.skillsExtension], mcp: this.chat.mcp, expand: (text) => resources.expand(text) };
	}

	/** `/commands` of a Thread or Space: prompt templates and skills from pi's folder and packages. */
	async chatCommands() {
		await this.chat?.resources.ready();
		return this.chat?.resources.commands() ?? [];
	}

	// ── Moving threads and topics (04-chat S5, S9, S11) ─────────────────────

	/** Each thread becomes a topic of the Space (or joins `topicId`); then it's deleted unless `keep`. */
	async importThreads(spaceRef: ContainerRef, threads: ContainerRef[], options: { topicId?: string; keep: boolean }): Promise<string[]> {
		const space = await this.space(spaceRef);
		const ids: string[] = [];
		for (const ref of threads) {
			const entry = this.entry({ kind: "thread", id: ref.id });
			const runtime = (await this.runtime(entry.ref)) as ThreadRuntime;
			if (runtime.snapshot().state.status === "running") throw new EngineError("BUSY", `“${entry.title}” is still answering.`);
			const entries = await runtime.exportEntries();
			ids.push(await space.importTopic(options.topicId ? { topicId: options.topicId } : { title: entry.title, brief: `Moved here from the thread “${entry.title}”.` }, entries, { title: entry.title }));
			if (options.keep) {
				delete entry.suggestion;
				entry.suggestionDismissed = true;
				this.save();
				this.changed(entry);
			} else {
				await this.delete(entry.ref);
			}
		}
		return ids;
	}

	/** Promote to Thread: a new thread with a copy of the topic's messages. */
	async promoteTopic(topicRef: ContainerRef): Promise<ContainerRef> {
		if (!topicRef.conversationId) throw new EngineError("INVALID", "Give a topic.");
		const spaceEntry = this.entry({ kind: "space", id: topicRef.id });
		const { title, entries } = await (await this.space(topicRef)).exportTopic(topicRef.conversationId);
		const ref = await this.create({ kind: "thread", title, ...(spaceEntry.model ? { model: spaceEntry.model } : {}) });
		const thread = (await this.runtime(ref)) as ThreadRuntime;
		await thread.importEntries(entries, { title: `${spaceEntry.title} › ${title}` });
		this.entry(ref).suggestionDismissed = true; // it just came from a Space
		this.touch(ref);
		return ref;
	}

	dismissSuggestion(ref: ContainerRef): void {
		const entry = this.entry(ref);
		entry.suggestionDismissed = true;
		delete entry.suggestion;
		this.save();
		this.changed(entry);
	}

	/**
	 * Thread → Space suggestion (S11): after the first exchange, and again after the fifth (the subject may have
	 * drifted), the utility model compares the thread with every Space's topics.
	 */
	private async suggestSpace(entry: CatalogEntry, runtime: Runtime): Promise<void> {
		if (!this.chat?.settings.get().chat.suggestSpaces || entry.suggestionDismissed || entry.suggestion) return;
		const items = runtime.snapshot().items;
		const exchanges = items.filter((i) => i.kind === "assistant" && i.status === "done").length;
		const at = exchanges >= 5 ? 5 : exchanges >= 1 ? 1 : 0;
		if (!at || entry.suggestChecked?.includes(at)) return;
		entry.suggestChecked = [...(entry.suggestChecked ?? []), at];
		this.save();
		const spaces = [...this.entries.values()].filter((e) => e.ref.kind === "space");
		if (!spaces.length) return;
		const text = items
			.flatMap((i) => (i.kind === "user" ? [`User: ${i.text}`] : i.kind === "assistant" ? [`Assistant: ${i.parts.filter((p) => p.type === "text").map((p) => p.text).join("")}`] : []))
			.join("\n\n")
			.slice(0, 6000);
		const suggestion = (await this.askUtility(text, spaces).catch(() => undefined)) ?? keywordMatch(text, spaces);
		if (!suggestion || !this.entries.has(entry.ref.id) || entry.suggestionDismissed) return;
		entry.suggestion = suggestion;
		this.save();
		this.changed(entry);
	}

	private async askUtility(text: string, spaces: CatalogEntry[]): Promise<SpaceSuggestion | undefined> {
		const index = spaces
			.map((s) => `Notebook ${s.ref.id} “${s.title}”${s.instructions ? ` (${s.instructions.slice(0, 200)})` : ""}\n${(s.topics ?? []).filter((t) => !t.archived).map((t) => `  - topic ${t.id} “${t.title}”: ${t.brief ?? ""} ${t.summary ?? ""}`.trimEnd()).join("\n") || "  (no topics)"}`)
			.join("\n");
		const reply = await this.hub.utility(
			'You decide whether a chat thread belongs in one of the user\'s Notebooks (long-running areas of their life or work, split into topics). Answer with JSON only: {"space": "<notebook id or null>", "topic": "<topic id or null>", "confidence": <0..1>, "reason": "<one short line>"}. Pick a topic only when the thread continues its subject. Use null when nothing fits well.',
			`Notebooks:\n${index}\n\nThread:\n${text}`,
		);
		if (reply === undefined) return undefined;
		const json = /\{[\s\S]*\}/.exec(reply)?.[0];
		const parsed = json ? (JSON.parse(json) as { space?: string | null; topic?: string | null; confidence?: number; reason?: string }) : undefined;
		const space = spaces.find((s) => s.ref.id === parsed?.space);
		if (!parsed || !space || (parsed.confidence ?? 0) < SUGGEST_CONFIDENCE) return undefined;
		const topic = (space.topics ?? []).find((t) => t.id === parsed.topic && !t.archived);
		return { spaceId: space.ref.id, spaceTitle: space.title, ...(topic ? { topicId: topic.id, topicTitle: topic.title } : {}), reason: parsed.reason?.trim() || "It looks like the same subject." };
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
		if (entry.ref.kind !== "build") await this.chat?.resources.ready();
		const runtime = await this.createRuntime(entry);
		if (!this.search.isIndexed(entry.ref.id)) this.search.replaceSession(entry.ref.id, entry.title, entry.updatedAt, runtime.snapshot().items);
		runtime.onEvents((events) => {
			this.index(entry, events);
			if (entry.ref.kind === "thread" && events.some((e) => e.type === "state" && e.state.status === "idle")) void this.suggestSpace(entry, runtime);
		});
		return runtime;
	}

	private async createRuntime(entry: CatalogEntry): Promise<Runtime> {
		const model = entry.model ?? this.hub.defaultModel;
		if (entry.ref.kind === "agent") {
			const id = entry.ref.id;
			this.agentDefinition(id);
			return AgentRuntime.open({
				ref: entry.ref,
				file: entry.file!,
				hub: this.hub,
				definition: () => this.agentDefinition(id).definition,
				instructions: () => this.agentDefinition(id).instructions,
				memory: () => this.host.memory.get(this.agentDefinition(id).definition.memory?.provider ?? "builtin"),
				webOptions: this.webOptions,
				onActivity: () => this.touch(entry.ref),
				...(this.agentHost?.app ? { appTool: (call: Parameters<AppServices["tool"]>[0]) => this.agentHost!.app!.tool(call) } : {}),
				peers: this.peerHost(),
				...(this.agentAskTimeoutMs ? { askTimeoutMs: this.agentAskTimeoutMs } : {}),
				onStatus: () => void this.agentStatus(entry),
				onApproval: (approval) => {
					if (approval.status === "pending") this.onInbox?.({ count: this.inboxCount(), approval: { agent: entry.ref, agentName: entry.title, approvalId: approval.id, title: approval.title } });
				},
			});
		}
		if (entry.ref.kind === "space") {
			return SpaceRuntime.open({
				ref: entry.ref,
				file: entry.file!,
				hub: this.hub,
				model,
				...(entry.organizerModel ? { organizerModel: entry.organizerModel } : {}),
				filesDir: join(this.paths.spacesDir, entry.ref.id, "files"),
				info: () => ({ name: entry.title, ...(entry.instructions ? { instructions: entry.instructions } : {}) }),
				settings: () => ({ memory: !entry.memoryOff, autoTidy: entry.autoTidy ?? false }),
				webOptions: this.webOptions,
				...this.chatExtras("space"),
				onTopics: (topics, stats) => {
					if (!this.entries.has(entry.ref.id)) return;
					if (JSON.stringify(topics) === JSON.stringify(entry.topicState) && JSON.stringify(stats) === JSON.stringify(entry.stats)) return;
					entry.stats = stats;
					this.updateTopics(entry, topics);
				},
			});
		}
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
				...this.chatExtras("thread"),
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
			profile: entry.profile ?? "build",
			webOptions: this.webOptions,
			...(entry.projectPath ? { trustPath: entry.projectPath } : {}),
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

function summary({ file: _f, sessionFile: _s, onDisk: _d, thinking: _t, readAt: _r, topicState: _ts, organizerModel: _o, memoryOff: _m, autoTidy: _a, stats: _st, suggestionDismissed: _sd, suggestChecked: _sc, ...rest }: CatalogEntry): SessionSummary {
	return rest;
}

/** The suggestion needs this much confidence from the utility model. */
const SUGGEST_CONFIDENCE = 0.75;

/**
 * Without a utility model (the scripted model): a topic whose title words (4+ letters) all appear in the thread,
 * else nothing. Cheap and conservative.
 */
function keywordMatch(text: string, spaces: CatalogEntry[]): SpaceSuggestion | undefined {
	const lower = text.toLowerCase();
	for (const space of spaces) {
		for (const topic of (space.topics ?? []).filter((t) => !t.archived)) {
			const words = topic.title.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter((w) => w.length >= 4);
			if (words.length && words.every((w) => lower.includes(w))) return { spaceId: space.ref.id, spaceTitle: space.title, topicId: topic.id, topicTitle: topic.title, reason: `It mentions ${topic.title}.` };
		}
	}
	return undefined;
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
