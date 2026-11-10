/**
 * Session catalog + open runtimes. Phase 0 keeps the catalog in a JSON index;
 * it moves to catalog.db (SQLite + FTS) with the Phase 1 sidebar.
 */
import type { ConnectorHub } from "./connectors/hub.js";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, watch, writeFileSync, type FSWatcher } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { ApprovalMode, ApprovalRule, ContainerRef, DebateConfig, ModelRef, ProjectInfo, PromptResponse, SessionSummary, TimelineItem, WorkOn } from "@piopio/protocol";
import { EngineError, type ModelHub } from "./models.js";
import type { EnginePaths } from "./paths.js";
import { CheckpointStore } from "./checkpoints.js";
import { attachmentsDir, copyAttachments, deleteAttachments } from "./attachment-files.js";
import { draftAgent, type AgentDraft } from "./agent-draft.js";
import { addWorktree, checkout, git as runGit, mergeWorktree, removeWorktree, status as gitStatus } from "./git.js";
import { BuildRuntime } from "./runtimes/build.js";
import { parseVerdict, REVIEW_SYSTEM, reviewPrompt, type TaskResult } from "@piopio/pi-extensions";
import type { Runtime } from "./runtimes/runtime.js";
import { DatabaseSync } from "node:sqlite";
import { aboutMeExtension, type AboutMe } from "./about-me.js";
import type { Settings } from "./settings.js";
import type { ChatMcp } from "./tools/mcp-chat.js";
import type { ChatResources } from "./tools/chat-resources.js";
import { AgentRuntime, type AgentOpenOptions } from "./runtimes/agent.js";
import { writingExtension } from "./tools/writing.js";
import type { AgentFiles } from "./agent-files.js";
import type { AppServices } from "./app-services.js";
import type { MemoryProviders } from "./memory.js";
import { alwaysLabel, type Envelope, type PeerLog, newDefinition, modelOf, validate, TEMPLATES, type AgentDefinition, type DefinitionError, type Watch } from "@piopio/runtime";
import type { Extension } from "@earendil-works/pi-durable";
import { ThreadRuntime, type BranchState } from "./runtimes/thread.js";
import { DebateRuntime, validateDebate, type DebateRecord } from "./runtimes/debate.js";
import type { WebOptions } from "./tools/web.js";
import { exportTranscript, type ExportFormat } from "./export.js";
import { SearchIndex } from "./search.js";
import { historyExtension, type HistoryBridge } from "./tools/history.js";
import { AGENT_NAMES, findAgent, installedAgents, runExternalAgent, type ExternalAgent } from "./external-agents.js";
import type { TelegramChannels } from "./channels/manager.js";
import type { AgentWatchers } from "./watchers.js";
import { runCommand, type TeamHost, type TeamRunner } from "./teams/runner.js";
import type { TeamBridge } from "./teams/extension.js";
import { TimelineBuilder, type PiMessage } from "./timeline/builder.js";
import { SdkEventMapper } from "./timeline/pi-sdk.js";
import type { SessionEvent } from "@piopio/protocol";

type CatalogEntry = SessionSummary & {
	thinking?: string;
	file?: string;
	sessionFile?: string;
	/** Original CLI file for recovered history; avoid importing a duplicate after restore. */
	restoredFromSessionFile?: string;
	/** The pi session file was seen on disk, so its disappearance means it was deleted. */
	onDisk?: boolean;
	branches?: BranchState;
	web?: boolean;
	/** Build: the session's approval mode (new sessions take their project's). */
	approvalMode?: ApprovalMode;
	/** Build: plan mode (piopio-plan). */
	planMode?: boolean;
	/** Agents: the definition folder. */
	agentFolder?: string;
	/** Debate threads (docs/spec/16-debate). */
	debate?: DebateRecord;
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
	private searchReady = new Set<string>();
	private searchLoads = new Map<string, Promise<void>>();
	private indexedViews = new WeakSet<Runtime>();
	readonly checkpoints: CheckpointStore;
	policy: ApprovalPolicy = { projectFor: () => undefined, modeFor: () => "auto_edit", rulesFor: () => [], addRule: () => {} };
	/** Settings, About me and MCP for conversations (set by the engine). */
	chat?: { settings: Settings; aboutMe: AboutMe; mcp: ChatMcp; resources: ChatResources };
	/** Agent folders and memory (set by the engine). */
	agentHost?: { files: AgentFiles; memory: MemoryProviders; app?: AppServices };
	/** Each agent's last valid definition, as the runtime uses it. */
	private definitions = new Map<string, { definition: AgentDefinition; instructions: string }>();
	private skillsExtension?: Extension;
	private aboutMeExtensions = new Map<"thread" | "agent", Extension>();
	/** A Build session needs the user (a new prompt) or told them something (notify_user). */
	onAttention?: (change: { ref: ContainerRef; title: string; kind: "waiting" | "notify"; message: string }) => void;
	/** Tests: where the Claude Code / Codex CLIs are (default: PATH and the usual folders). */
	findExternal: (agent: ExternalAgent) => string | undefined = (agent) => findAgent(agent);
	private externalAgents(): ExternalAgent[] {
		return installedAgents((agent) => this.findExternal(agent));
	}
	/** Tests: a scripted auto reviewer (system prompt, prompt → its reply). */
	reviewer?: (system: string, prompt: string) => Promise<string | undefined>;
	/** How long ask_agent waits (tests shorten it). */
	agentAskTimeoutMs?: number;
	/** Tests: a scripted utility model for learned facts, a short quiet time, and a hook when learning ends. */
	agentLearn?: Pick<AgentOpenOptions, "learn" | "learnQuietMs" | "onLearned">;
	/** The Inbox changed (badges), with the approval an agent just asked for (notifications). */
	onInbox?: (change: { count: number; approval?: { agent: ContainerRef; agentName: string; approvalId: string; title: string } }) => void;
	/** Agents on Telegram from this Mac (channels/manager.ts), set by the engine. */
	telegram?: TelegramChannels;
	/** Teams (docs/spec/19): their boards, set by the engine. */
	teams?: TeamRunner;
	/** A team changed (the app refreshes its board). */
	onTeams?: (id: string) => void;
	/** Event routines on this Mac (watchers.ts), and a webhook's local URL; set by the engine. */
	watchers?: AgentWatchers;
	hookUrl?: (agentId: string, triggerId: string) => string;

	constructor(
		private readonly paths: EnginePaths,
		private readonly hub: ModelHub,
		private readonly piOverrides: { piSessionDir?: string; piAgentDir?: string; trashDir?: string } = {},
		private readonly webOptions: WebOptions = {},
	) {
		this.search = new SearchIndex(join(paths.home, "search.db"));
		this.checkpoints = new CheckpointStore(join(paths.home, "checkpoints"));
		if (existsSync(paths.catalogIndex)) {
			for (const e of JSON.parse(readFileSync(paths.catalogIndex, "utf8")) as CatalogEntry[]) {
				// Chat-lens sessions are Read only now (docs/spec/18 §4): the profile follows the approval mode.
				if (e.ref.kind === "build" && e.profile === "chat") e.approvalMode = "read_only";
				// Notebooks are gone (docs/spec/18 CF8): their files stay in spaces/, they no longer show.
				if ((e.ref.kind as string) === "space") continue;
				// Projects without a folder are folders now (CF4); their conversations stay, as conversations.
				delete (e as { projectId?: string }).projectId;
				this.entries.set(e.ref.id, e);
			}
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
		this.searchReady.delete(entry.ref.id);
		for (const l of this.listeners) l({ upserted: [summary(entry)], removed: [] });
	}

	async configure(ref: ContainerRef, change: { model?: ModelRef; thinking?: string; web?: boolean; approvalMode?: ApprovalMode; planMode?: boolean; toolsOff?: string[] }): Promise<void> {
		const entry = this.entry(ref);
		if (change.approvalMode) {
			entry.approvalMode = change.approvalMode; // read by the runtime's approvals bridge
			entry.profile = change.approvalMode === "read_only" ? "chat" : "build"; // the runtime switches its tools
		}
		if (change.planMode !== undefined) entry.planMode = change.planMode;
		if (change.toolsOff) {
			// Read live by the runtimes; chat MCP tools are reinstalled, connector tools follow on the next turn.
			const list = [...new Set(change.toolsOff.filter((t) => /^(connector|mcp):.+/.test(t)))].sort();
			if (list.length) entry.toolsOff = list;
			else delete entry.toolsOff;
			this.chat?.mcp.refresh();
		}
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
	async find(query: string, limit = 30, kind?: string) {
		await this.backfillSearch();
		return this.search.search(query, 5000).flatMap((hit) => {
			const destination = this.search.destination(hit.sessionId);
			const entry = destination ?? this.entries.get(hit.sessionId);
			return entry && this.entries.has(entry.ref.id) && (!kind || entry.ref.kind === kind)
				? [{ ref: entry.ref, title: entry.title, ...(hit.itemId ? { itemId: hit.itemId } : {}), kind: hit.kind, snippet: hit.snippet, at: hit.at }] : [];
		}).slice(0, Math.min(100, Math.max(1, limit)));
	}

	/**
	 * What a conversation may look into with search_conversations / read_conversation (tools/history.ts): a Build
	 * session, the other sessions of its project; a chat without a project, the other chats without one. Not agents
	 * or debates.
	 */
	historyBridge(entry: CatalogEntry): HistoryBridge | undefined {
		const scopeOf = (e: CatalogEntry) => (e.ref.kind === "build" ? `build:${e.projectPath ?? e.cwd}` : e.ref.kind === "thread" && !e.projectPath && !e.debate ? "chats" : undefined);
		const scope = scopeOf(entry);
		if (!scope) return undefined;
		const mine = (id: string) => {
			const e = this.entries.get(id);
			return e && id !== entry.ref.id && scopeOf(e) === scope ? e : undefined;
		};
		return {
			scope: entry.ref.kind === "build" ? "this project" : "the user's other chats",
			search: async (query, limit) => {
				const seen = new Set<string>();
				const out: { id: string; title: string; at: string; snippet?: string }[] = [];
				for (const hit of await this.find(query, 100)) {
					const e = !hit.ref.conversationId ? mine(hit.ref.id) : undefined;
					if (!e || seen.has(e.ref.id)) continue;
					seen.add(e.ref.id);
					out.push({ id: e.ref.id, title: e.title, at: e.updatedAt, ...(hit.kind !== "title" ? { snippet: hit.snippet } : {}) });
					if (out.length >= limit) break;
				}
				return out;
			},
			read: async (id) => {
				const e = mine(id);
				return e ? { title: e.title, at: e.updatedAt, items: await this.itemsOf(e) } : undefined;
			},
		};
	}

	/** A conversation's items without keeping it open: Build history straight from its file (no extensions, no key). */
	private async itemsOf(entry: CatalogEntry): Promise<readonly TimelineItem[]> {
		const open = this.open.get(entry.ref.id);
		if (open) return (await open).snapshot().items;
		if (entry.ref.kind === "build") {
			if (!entry.sessionFile || !existsSync(entry.sessionFile)) return [];
			const builder = new TimelineBuilder(entry.ref);
			builder.reset(SessionManager.open(entry.sessionFile).buildSessionContext().messages as unknown as PiMessage[], (index) => SdkEventMapper.idOf(index), false);
			return builder.snapshot().items;
		}
		const runtime = await this.runtime(entry.ref);
		const items = runtime.snapshot().items;
		this.open.delete(entry.ref.id);
		await runtime.close();
		return items;
	}

	/** Index all active branches, including agent conversations. */
	async backfillSearch(): Promise<number> {
		let count = 0;
		for (const entry of [...this.entries.values()]) {
			if (this.searchReady.has(entry.ref.id)) continue;
			let pending = this.searchLoads.get(entry.ref.id);
			if (!pending) {
				pending = this.indexContainer(entry);
				this.searchLoads.set(entry.ref.id, pending);
				pending.finally(() => this.searchLoads.delete(entry.ref.id)).catch(() => {});
			}
			try { await pending; count++; } catch { /* Retry unreadable/missing files on the next search. */ }
		}
		return count;
	}

	private async indexContainer(entry: CatalogEntry): Promise<void> {
		// Searching unopened Build history must not load project extensions or require a provider key.
		if (entry.ref.kind === "build" && !this.open.has(entry.ref.id)) {
			if (!entry.sessionFile || !existsSync(entry.sessionFile)) return;
			const builder = new TimelineBuilder(entry.ref);
			const messages = SessionManager.open(entry.sessionFile).buildSessionContext().messages as unknown as PiMessage[];
			builder.reset(messages, index => SdkEventMapper.idOf(index), false);
			this.search.setDestination(entry.ref.id, entry.ref, entry.title, entry.updatedAt);
			this.search.replaceSession(entry.ref.id, entry.title, entry.updatedAt, builder.snapshot().items);
			this.searchReady.add(entry.ref.id);
			return;
		}
		const wasOpen = this.open.has(entry.ref.id);
		const runtime = await this.runtime(entry.ref);
		const refs: { ref: ContainerRef; title: string }[] = [{ ref: entry.ref, title: entry.title }];
		if (entry.ref.kind === "agent") {
			for (const person of await this.agentConversations(entry.ref)) if (person.started && person.role !== "owner") refs.push({ ref: { ...entry.ref, conversationId: person.conversationId }, title: `${entry.title} › ${person.name}` });
			for (const run of (await this.agentRuns(entry.ref)).runs) refs.push({ ref: { ...entry.ref, conversationId: `run:${run.id}` }, title: `${entry.title} › Run ${run.id}` });
		}
		for (const { ref, title } of refs) {
			const view = ref.conversationId ? await this.runtime(ref) : runtime;
			const key = ref.conversationId ? `${ref.id}/${ref.conversationId}` : ref.id;
			this.search.setDestination(key, ref, title, entry.updatedAt);
			this.search.replaceSession(key, title, entry.updatedAt, view.snapshot().items);
			if (!this.indexedViews.has(view)) {
				this.indexedViews.add(view);
				view.onEvents(events => this.index({ ...entry, ref: { ...ref, id: key }, title }, events));
			}
		}
		if (!wasOpen && entry.ref.kind !== "agent") {
			this.open.delete(entry.ref.id);
			await runtime.close();
		}
		this.searchReady.add(entry.ref.id);
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
		if (ref.kind === "build") {
			// pi writes the new session file next to this one; the folder sync picks it up like a CLI session.
			const runtime = await this.build(ref);
			const file = runtime.forkFile(itemId);
			await this.syncFolder(source.cwd!);
			const copy = [...this.entries.values()].find((e) => e.sessionFile === file);
			if (!copy) throw new EngineError("INTERNAL", "The new session didn't show up.");
			copy.title = `${source.title} (fork)`;
			copyAttachments(this.paths.home, ref.id, copy.ref.id);
			if (source.model) copy.model = source.model;
			this.save();
			this.changed(copy);
			return copy.ref;
		}
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
		copyAttachments(this.paths.home, ref.id, copy.ref.id);
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
		if (entry.ref.kind === "agent") {
			this.agentHost?.memory.builtin.dropBanks(`${entry.ref.id}/`);
			if (entry.agentFolder) this.agentHost?.files.trash(entry.agentFolder, this.piOverrides.trashDir);
			this.definitions.delete(entry.ref.id);
		}
		deleteAttachments(this.paths.home, ref.id);
		this.search.deleteContainer(ref.id);
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

	async create(params: { kind: "thread" | "build"; instructions?: string; cwd?: string; model?: ModelRef; thinking?: string; title?: string; workOn?: WorkOn; approvalMode?: ApprovalMode; planMode?: boolean; profile?: "build" | "chat"; debate?: DebateConfig }): Promise<ContainerRef> {
		if (params.kind === "build" && !params.cwd) throw new EngineError("INVALID", "Build sessions need a cwd.");
		if (params.planMode && params.kind !== "build") throw new EngineError("INVALID", "Only folder conversations support Plan mode.");
		if (params.debate && params.kind !== "thread") throw new EngineError("INVALID", "Only threads can be debates.");
		if (params.debate) validateDebate(params.debate, this.hub);
		const author = params.debate?.participants.find((p) => p.role === "author");
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
			title: params.title?.trim() || (params.debate ? titleFrom(params.debate.goal) : "") || (params.kind === "thread" ? "New thread" : "New session"),
			createdAt: now,
			updatedAt: now,
			model: author?.model ?? params.model ?? this.hub.defaultModel,
			...(cwd ? { cwd } : {}),
			...(worktree ? { projectPath: params.cwd!, worktree } : {}),
			...(params.thinking ? { thinking: params.thinking } : {}),
			...(params.planMode ? { planMode: true } : {}),
			...(params.kind === "build" ? buildMode(params.profile === "chat" ? "read_only" : (params.approvalMode ?? this.policy.modeFor(params.cwd!))) : {}),
			...(params.kind === "thread" ? { file: join(this.paths.threadsDir, `${ref.id}.sqlite`) } : {}),
			...(params.debate ? { debate: { config: params.debate, status: "running" as const, maxRounds: params.debate.maxRounds, endings: [] } } : {}),
		};
		this.entries.set(ref.id, entry);
		this.save();
		this.changed(entry);
		return ref;
	}

	async runtime(ref: ContainerRef): Promise<Runtime> {
		let view: Runtime | undefined;
		if (ref.kind === "agent" && ref.conversationId?.startsWith("run:")) view = await (await this.agent(ref)).runView(ref.conversationId.slice(4));
		else if (ref.kind === "agent" && ref.conversationId?.startsWith("agent:")) view = await (await this.agent(ref)).peerView(ref.conversationId.slice(6));
		else if (ref.kind === "agent" && ref.conversationId) view = await (await this.agent(ref)).view(ref.conversationId.replace(/^person:/, ""));
		if (view) {
			const entry = this.entry(ref);
			const key = `${ref.id}/${ref.conversationId}`;
			const title = this.search.destination(key)?.title ?? `${entry.title} › ${ref.conversationId}`;
			this.search.setDestination(key, ref, title, entry.updatedAt);
			if (!this.indexedViews.has(view)) {
				this.indexedViews.add(view);
				this.search.replaceSession(key, title, entry.updatedAt, view.snapshot().items);
				view.onEvents(events => {
					this.searchReady.delete(entry.ref.id);
					this.index({ ...entry, title: this.search.destination(key)?.title ?? title, ref: { ...ref, id: key } }, events);
				});
			}
			return view;
		}

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

	// ── Turn into an agent (docs/spec/18 phase 3) ────────────────────────────

	/** A draft agent from a conversation: its active branch, written up by the background model when there is one. */
	async agentDraft(ref: ContainerRef): Promise<AgentDraft> {
		const entry = this.entry(ref);
		if (entry.ref.kind !== "thread" && entry.ref.kind !== "build") throw new EngineError("INVALID", "Only conversations can become agents.");
		const runtime = await this.runtime(ref);
		const snapshot = runtime.snapshot();
		const lines: { role: "user" | "assistant"; text: string }[] = [];
		for (const i of snapshot.items) {
			if (i.kind === "user" && i.text.trim()) lines.push({ role: "user", text: i.text });
			if (i.kind === "assistant") {
				const text = i.parts.filter((p) => p.type === "text").map((p) => p.text).join("").trim();
				if (text) lines.push({ role: "assistant", text });
			}
		}
		const model = snapshot.state.model ?? entry.model;
		return draftAgent(entry.title, lines, (system, prompt) => this.hub.utility(system, prompt, ref.id, model ? { model } : {}));
	}

	// ── Continue in a project folder (docs/spec/18 §5) ───────────────────────

	/**
	 * A chat continues in a folder: a Build session there whose first entry is the chat's active branch, as context the
	 * model reads (user and assistant text, one line per tool call, the images attached). Thinking and other branches
	 * stay behind. The chat stays where it was, with a link to the new conversation.
	 */
	async continueIn(from: ContainerRef, cwd: string, approvalMode?: ApprovalMode): Promise<ContainerRef> {
		const source = this.entry(from);
		if (source.ref.kind !== "thread") throw new EngineError("INVALID", "Only a conversation without a project can continue in one.");
		if (!existsSync(cwd)) throw new EngineError("NOT_FOUND", `No folder ${cwd}`);
		const chat = await this.runtime(from);
		const items = chat.snapshot().items;
		const model = chat.snapshot().state.model ?? source.model;
		const lines: string[] = [];
		const images: { type: "image"; data: string; mimeType: string }[] = [];
		let messages = 0;
		for (const item of items) {
			if (item.kind === "user") {
				messages++;
				const names = (item.attachments ?? []).map((a) => a.name);
				lines.push(`User: ${item.text}${names.length ? `\n[Attached: ${names.join(", ")}]` : ""}`);
				for (const a of item.attachments ?? []) {
					if (a.kind !== "image" || !a.stored) continue;
					const file = join(attachmentsDir(this.paths.home, from.id), a.stored);
					if (existsSync(file)) images.push({ type: "image", data: readFileSync(file).toString("base64"), mimeType: a.mimeType ?? "image/png" });
				}
			} else if (item.kind === "assistant") {
				const text = item.parts.filter((p) => p.type === "text").map((p) => p.text).join("").trim();
				if (text) {
					messages++;
					lines.push(`Assistant: ${text}`);
				}
			} else if (item.kind === "tool") {
				lines.push(`(tool ${item.tool}: ${item.status})`);
			}
		}
		const ref = await this.create({ kind: "build", cwd, ...(approvalMode ? { approvalMode } : {}), ...(model ? { model } : {}), title: source.title });
		const child = this.entry(ref);
		child.continuedFrom = { id: source.ref.id, title: source.title };
		source.continuedIn = { id: ref.id, title: source.title };
		const runtime = await this.build(ref);
		const intro = `This conversation continues an earlier one, “${source.title}”, now in the folder ${cwd}. Here it is, so you know what was said:`;
		await runtime.seed(`${intro}\n\n${lines.join("\n\n")}`, images, `Continued from “${source.title}” · ${messages} message${messages === 1 ? "" : "s"}`);
		this.save();
		this.changed(source);
		this.changed(child);
		return ref;
	}

	// ── Subagents (piopio-subagents) ─────────────────────────────────────────

	private subagents = new Map<string, { running: number; waiting: (() => void)[] }>();

	/**
	 * Runs a `task` as a child Build session (same folder, model and approval mode), one level deep,
	 * at most MAX_SUBAGENTS at a time per parent. Its final answer goes back to the parent.
	 */
	private async runTask(
		parent: CatalogEntry,
		task: { callId: string; description: string; prompt: string; agent?: string },
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
			// Claude Code / Codex (external-agents.ts): the user's own CLI, in this folder, with the session's mode.
			if (task.agent === "claude" || task.agent === "codex") {
				const path = this.findExternal(task.agent);
				if (!path) return { text: `${AGENT_NAMES[task.agent]} isn't installed on this Mac.`, sessionId: "", costUsd: 0, status: "error" };
				return await runExternalAgent(task.agent, { path, cwd: parent.cwd!, prompt: task.prompt, mode: parent.approvalMode ?? this.policy.modeFor(parent.projectPath ?? parent.cwd!), ...(signal ? { signal } : {}), onProgress });
			}
			// A child never gets more than its parent: the same profile (a Chat-lens parent has no bash) and the
			// same tools turned off (see `toolsOff` in build(), which also follows later changes to the parent).
			const ref = await this.create({ kind: "build", cwd: parent.cwd!, ...(parent.model ? { model: parent.model } : {}), approvalMode: parent.approvalMode ?? this.policy.modeFor(parent.projectPath ?? parent.cwd!), title: task.description });
			const child = this.entry(ref);
			child.parent = { id: parent.ref.id, callId: task.callId };
			if (parent.toolsOff?.length) child.toolsOff = [...parent.toolsOff];
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
	async createAgent(params: { name: string; template?: string; avatar?: string; model?: ModelRef; owner?: string; instructions?: string; schedule?: string | null }): Promise<ContainerRef> {
		const name = params.name.trim();
		if (!name) throw new EngineError("INVALID", "The agent needs a name.");
		if (params.template && !TEMPLATES.some((t) => t.id === params.template)) throw new EngineError("INVALID", `No template “${params.template}”.`);
		const id = `agt_${randomUUID().replaceAll("-", "").slice(0, 16)}`;
		const slug = name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "agent";
		const model = params.model ?? this.hub.defaultModel;
		const folder = this.host.files.folderFor(slug);
		// Nothing said yet (no template, no instructions): it interviews the owner and sets itself up (docs/spec/19 S2).
		const interview = !params.template && !params.instructions?.trim();
		const made = newDefinition({ id, slug: basename(folder), name, owner: params.owner?.trim() || "Owner", model: model.provider === "openrouter" ? model.id : `${model.provider}:${model.id}`, ...(params.template ? { template: params.template } : {}), ...(params.avatar ? { avatar: params.avatar } : {}), ...(params.instructions !== undefined ? { instructions: params.instructions } : {}), ...(params.schedule !== undefined ? { schedule: params.schedule } : {}), ...(interview ? { interview: true } : {}) });
		await this.host.files.create(folder, made);
		this.definitions.set(id, made);
		const now = new Date().toISOString();
		const entry: CatalogEntry = { ref: { kind: "agent", id }, title: name, createdAt: now, updatedAt: now, file: join(this.paths.home, "agents", `${id}.sqlite`), agentFolder: folder };
		mkdirSync(dirname(entry.file!), { recursive: true });
		this.setAgentInfo(entry, made.definition);
		this.entries.set(id, entry);
		this.save();
		this.changed(entry);
		if (interview) {
			const owner = made.definition.contacts[0]!.name;
			const hi = owner && owner !== "Owner" ? `Hi ${owner}!` : "Hi!";
			await (await this.agent(entry.ref)).greet(
				`${hi} I'm your new agent. What would you like me to help with? For example:\n\n1. A morning briefing: your calendar, the emails that need you, the weather\n2. Watching something and telling you when it changes\n3. Reminders, and keeping track of what you ask me\n4. Something else: tell me in your words`,
			);
		}
		return entry.ref;
	}

	/** `set_up` from the agent itself (docs/spec/19 S2): saved like an edit, and the interview ends once it has instructions. */
	private async updateAgentSelf(id: string, change: { name?: string; description?: string; avatar?: string; instructions?: string }) {
		const { definition, instructions } = this.agentDefinition(id);
		const body = instructions.replace(/^#[^\n]*\n+/, "").trim();
		const previous = { name: definition.name, ...(definition.description ? { description: definition.description } : {}), ...(definition.avatar ? { avatar: definition.avatar } : {}), instructions: body };
		const next = structuredClone(definition);
		if (change.name) next.name = change.name;
		if (change.description) next.description = change.description;
		if (change.avatar) next.avatar = change.avatar;
		if (change.instructions) delete next.interview;
		const text = `# ${next.name}\n\n${change.instructions ?? body}\n`;
		const result = await this.saveAgent({ kind: "agent", id }, next, text, change.instructions ? "Set itself up" : "Change its name or line");
		if (!result.saved && result.errors.length) throw new Error(result.errors.map((e) => e.message).join(" "));
		return previous;
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
		await this.telegram?.sync();
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
		await this.telegram?.sync().catch((error: unknown) => log(`Telegram: ${(error as Error).message}`));
		await this.watchers?.sync().catch((error: unknown) => log(`Routines: ${(error as Error).message}`));
	}

	/** Every open agent's event routines (watchers.ts). */
	async agentWatches(): Promise<{ agentId: string; watches: Watch[] }[]> {
		const out = [];
		for (const entry of [...this.entries.values()].filter((e) => e.ref.kind === "agent" && this.open.has(e.ref.id))) {
			out.push({ agentId: entry.ref.id, watches: await (await this.agent(entry.ref)).watches() });
		}
		return out;
	}

	/** Local agents and their definitions (channels). */
	agentList(): { id: string; name: string; definition: AgentDefinition }[] {
		return [...this.entries.values()]
			.filter((e) => e.ref.kind === "agent")
			.flatMap((e) => {
				try {
					return [{ id: e.ref.id, name: e.title, definition: this.agentDefinition(e.ref.id).definition }];
				} catch {
					return [];
				}
			});
	}

	/** Changes an agent's definition in code (channels pairing), saved like an edit. */
	async changeAgent(id: string, change: (def: AgentDefinition) => void, message: string): Promise<void> {
		const { definition, instructions } = this.agentDefinition(id);
		const next = structuredClone(definition);
		change(next);
		const result = await this.saveAgent({ kind: "agent", id }, next, instructions, message);
		if (!result.saved && result.errors.length) throw new EngineError("INVALID", result.errors.map((e) => e.message).join(" "));
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
		const safety = await runtime.core.safety.status().catch(() => undefined);
		if (!safety || !this.entries.has(entry.ref.id)) return;
		// What fires next (the sidebar's "Next run tomorrow 7:00").
		const next = (await runtime.runs().catch(() => undefined))?.upcoming.map((u) => u.next).filter((n): n is number => typeof n === "number").sort((a, b) => a - b)[0];
		const status = { ...safety, ...(next && !safety.paused ? { nextRun: new Date(next).toISOString() } : {}) };
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

	/** Settings › Memory: the agents that use memory, their partitions' names, and whether they learn by themselves. */
	memoryOwners(): { agents: { id: string; name: string; avatar?: string; learns: boolean; provider: string; partitions: { bank: string; label: string }[] }[] } {
		const agents = [...this.entries.values()]
			.filter((e) => e.ref.kind === "agent")
			.flatMap((e) => {
				const def = this.agentDefinition(e.ref.id).definition;
				if (!def.tools.builtin.includes("memory")) return [];
				const { provider, partitions } = this.agentMemory(e.ref);
				return [{ id: def.id, name: def.name, ...(def.avatar ? { avatar: def.avatar } : {}), learns: def.memory?.learn !== false, provider, partitions: partitions.map((p) => ({ bank: p.bank, label: p.label })) }];
			});
		return { agents };
	}

	/** Turns an agent's learned facts on or off (its definition's memory.learn), as a saved change in its history. */
	async setLearning(ref: ContainerRef, learn: boolean): Promise<void> {
		const { definition, instructions } = this.agentDefinition(ref.id);
		const next = { ...definition, memory: { provider: definition.memory?.provider ?? "builtin", ...definition.memory, learn } };
		const saved = await this.saveAgent(ref, next, instructions, learn ? "Learn facts from conversations" : "Stop learning facts from conversations");
		if (!saved.saved) throw new EngineError("INVALID", saved.errors[0]?.message ?? "Couldn't save the agent.");
	}

	private validateAgent(definition: unknown, id: string): DefinitionError[] {
		const knownAgents = [...this.entries.values()].filter((e) => e.ref.kind === "agent" && e.ref.id !== id).map((e) => e.ref.id);
		return validate(definition, {
			unsupported: true,
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

	private aboutMeFor(kind: "thread" | "agent"): Extension | undefined {
		if (!this.chat) return undefined;
		let aboutMe = this.aboutMeExtensions.get(kind);
		if (!aboutMe) {
			aboutMe = aboutMeExtension(this.chat.aboutMe, this.chat.settings, kind) as unknown as Extension;
			this.aboutMeExtensions.set(kind, aboutMe);
		}
		return aboutMe;
	}

	/** About me in an agent, when Settings › Chat shares it with agents. */
	/** No em dashes, tables as Markdown tables (tools/writing.ts), in conversations and agents. */
	private writing?: Extension;

	private agentExtras(): Extension[] {
		const s = this.chat?.settings.get().aboutMe;
		const aboutMe = s?.enabled && s.inAgents ? this.aboutMeFor("agent") : undefined;
		this.writing ??= writingExtension() as unknown as Extension;
		return aboutMe ? [aboutMe, this.writing] : [this.writing];
	}

	private chatExtras(kind: "thread"): { extensions?: Extension[]; mcp?: ChatMcp; expand?: (text: string) => string | undefined } {
		if (!this.chat) return {};
		const aboutMe = this.aboutMeFor(kind)!;
		const resources = this.chat.resources;
		this.skillsExtension ??= resources.extension() as unknown as Extension;
		this.writing ??= writingExtension() as unknown as Extension;
		return { extensions: [aboutMe, this.skillsExtension, this.writing], mcp: this.chat.mcp, expand: (text) => resources.expand(text) };
	}

	/** `/commands` of a conversation: prompt templates and skills from pi's folder and packages. */
	async chatCommands() {
		await this.chat?.resources.ready();
		return this.chat?.resources.commands() ?? [];
	}

	/**
	 * After an answer: up to three short next messages (docs/design v2 "You could also"), from the utility model, only
	 * when the answer invites a reply (it asks something, offers options or a next step). A finished task, a fact or a
	 * confirmation gets none: suggestions under every answer were noise.
	 */
	private async suggestFollowUps(entry: CatalogEntry, runtime: Runtime): Promise<void> {
		if (this.chat?.settings.get().chat.followUps === false) return;
		const items = runtime.snapshot().items;
		const answer = [...items].reverse().find((i) => i.kind === "assistant" && i.status === "done" && i.parts.some((p) => p.type === "text" && p.text.trim()));
		const asked = [...items].reverse().find((i) => i.kind === "user");
		if (!answer || answer.kind !== "assistant" || !asked || asked.kind !== "user") return;
		const text = answer.parts.filter((p) => p.type === "text").map((p) => p.text).join("").slice(0, 4000);
		const reply = await this.hub
			.utility(
				FOLLOW_UPS_PROMPT,
				`User: ${asked.text.slice(0, 1500)}\n\nAssistant: ${text}`,
				entry.ref.id,
				{ model: runtime.snapshot().state.model ?? entry.model },
			)
			.catch(() => undefined);
		const list = reply ? (/\[[\s\S]*\]/.exec(reply)?.[0] ?? "") : "";
		const followUps = parseFollowUps(list);
		if (!followUps) return;
		// Still the latest answer, and nobody wrote meanwhile.
		const latest = [...runtime.snapshot().items].reverse().find((i) => i.kind === "assistant");
		if (!followUps.length || latest?.id !== answer.id || !this.entries.has(entry.ref.id)) return;
		entry.followUps = followUps;
		this.save();
		this.changed(entry);
	}

	/** Folders git may run in: a project, or a Build session's worktree. */
	knowsFolder(cwd: string): boolean {
		return Boolean(this.policy.projectFor(cwd)) || [...this.entries.values()].some((e) => e.ref.kind === "build" && e.cwd === cwd);
	}

	// ── Teams (docs/spec/19) ─────────────────────────────────────────────

	/** The board's tools for a team's session: the lead's, or a reviewer's verdict. */
	private teamBridge(entry: CatalogEntry): TeamBridge {
		const teams = this.teams!;
		const team = () => teams.get(entry.team!.id);
		return {
			kind: entry.team!.kind,
			brief: () => teams.leadBrief(team()),
			createTask: async (task) => {
				const t = await teams.createTask(team().id, task);
				return `Added ${t.id} “${t.title}” for ${t.role}: ${t.state === "doing" ? "started" : "waits for a free slot"}.`;
			},
			board: () => teams.board(team().id),
			message: (taskId, text) => teams.message(team().id, taskId, text),
			verdict: (pass, notes) => teams.verdict(entry.ref.id, pass, notes),
		};
	}

	/** What the team runner needs from the catalog: sessions, their turns, git and the checks. */
	teamHost(options: { stateFile: string; worktreesDir: string; log: (line: string) => void }): TeamHost {
		const answerOf = (runtime: Runtime) => {
			const last = [...runtime.snapshot().items].reverse().find((i) => i.kind === "assistant");
			return last?.kind === "assistant" ? last.parts.filter((p) => p.type === "text").map((p) => p.text).join("") : "";
		};
		return {
			createSession: async ({ cwd, title, model, approvalMode, team }) => {
				const ref = await this.create({ kind: "build", cwd, title, approvalMode, ...(model ? { model: model.includes(":") ? { provider: model.split(":")[0]!, id: model.split(":").slice(1).join(":") } : { provider: "openrouter", id: model } } : {}) });
				const entry = this.entry(ref);
				entry.team = { id: team.id, role: team.role, kind: team.kind, ...(team.taskId ? { taskId: team.taskId } : {}) };
				this.save();
				this.changed(entry);
				return ref.id;
			},
			submit: async (id, text) => {
				const runtime = await this.runtime({ kind: "build", id });
				await runtime.submit(text, { whenBusy: "followUp" });
				this.touch({ kind: "build", id });
			},
			onSettled: async (id, settled) => {
				const runtime = await this.runtime({ kind: "build", id });
				let running = runtime.snapshot().state.status === "running";
				return runtime.onEvents((events) => {
					for (const e of events) {
						if (e.type !== "state") continue;
						if (e.state.status === "running") running = true;
						else if (e.state.status === "idle" && running) {
							running = false;
							settled(answerOf(runtime));
						}
					}
				});
			},
			peek: async (id) => {
				const runtime = await this.runtime({ kind: "build", id });
				return { idle: runtime.snapshot().state.status === "idle", answer: answerOf(runtime) };
			},
			git: (cwd, args) => runGit(cwd, args),
			isRepo: async (cwd) => (await gitStatus(cwd)).repo,
			branchOf: async (cwd) => (await gitStatus(cwd)).branch,
			addWorktree: (repo, path, branch, base) => addWorktree(repo, path, branch, base),
			removeWorktree: (repo, path, branch, force) => removeWorktree(repo, path, branch, force),
			run: (cwd, command) => runCommand(cwd, command),
			worktreesDir: options.worktreesDir,
			stateFile: options.stateFile,
			changed: (id) => this.onTeams?.(id),
			log: options.log,
		};
	}

	/** A Build session's runtime (checkpoints, approvals). */
	async build(ref: ContainerRef): Promise<BuildRuntime> {
		const runtime = await this.runtime(ref);
		if (!(runtime instanceof BuildRuntime)) throw new EngineError("INVALID", "Only Build sessions have checkpoints and approvals.");
		return runtime;
	}

	/** Answers a pending prompt of a Build session. */
	/** Connected apps (docs/spec/12-connectors), set by the engine. */
	connectors?: ConnectorHub;

	/** The user's answer to a connector approval in a chat. */
	async decide(ref: ContainerRef, approvalId: string, decision: { approve: boolean; always?: boolean; reason?: string }) {
		const runtime = await this.runtime(ref);
		if (!(runtime instanceof ThreadRuntime)) throw new EngineError("INVALID", "Only chats ask this way.");
		return runtime.decide(approvalId, decision);
	}

	async respond(ref: ContainerRef, promptId: string, response: PromptResponse): Promise<void> {
		const runtime = await this.runtime(ref);
		if (!(runtime instanceof BuildRuntime)) throw new EngineError("INVALID", "Only Build sessions ask for approval.");
		runtime.respond(promptId, response);
	}

	/** Debate threads: Keep going, or end the debate now. */
	async debate(ref: ContainerRef): Promise<DebateRuntime> {
		const runtime = await this.runtime(ref);
		if (!(runtime instanceof DebateRuntime)) throw new EngineError("INVALID", "This thread isn't a debate.");
		return runtime;
	}

	/** Called after a submit: bumps recency and auto-titles from the first input. */
	touch(ref: ContainerRef, firstInput?: string): void {
		const entry = this.entries.get(ref.id);
		if (!entry) return;
		delete entry.followUps;
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
		const byFile = new Map([...this.entries.values()].filter((e) => e.sessionFile).flatMap(e => [
			[e.sessionFile!, e] as const,
			...(e.restoredFromSessionFile ? [[e.restoredFromSessionFile, e] as const] : []),
		]));
		const upserted: CatalogEntry[] = [];
		for (const info of infos) {
			const modified = info.modified.toISOString();
			const entry = byFile.get(info.path);
			if (entry?.restoredFromSessionFile === info.path && entry.sessionFile !== info.path) continue;
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
		for (const entry of upserted) this.searchReady.delete(entry.ref.id);
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
			this.searchReady.delete(entry.ref.id);
			this.index(entry, events);
			// A rejected sign-in or key marks its provider "Needs attention" in Settings › Models (docs/spec/10 FR1).
			for (const e of events) {
				if ((e.type === "item.added" || e.type === "item.updated") && e.item.kind === "assistant" && e.item.errorKind === "auth" && e.item.model) {
					this.hub.needsAttention(e.item.model.split("/")[0]!, e.item.error ?? "Sign-in or key rejected.");
				}
			}
			const idle = events.some((e) => e.type === "state" && e.state.status === "idle");
			if ((entry.ref.kind === "thread" || entry.ref.kind === "build") && idle && !entry.debate) void this.suggestFollowUps(entry, runtime);
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
				...(this.connectors ? { connectors: this.connectors } : {}),
				extraExtensions: () => this.agentExtras(),
				...(this.agentAskTimeoutMs ? { askTimeoutMs: this.agentAskTimeoutMs } : {}),
				...(this.agentLearn ? this.agentLearn : {}),
				onStatus: () => void this.agentStatus(entry),
				onApproval: (approval) => {
					if (approval.status === "pending") this.onInbox?.({ count: this.inboxCount(), approval: { agent: entry.ref, agentName: entry.title, approvalId: approval.id, title: approval.title } });
					if (approval.status === "pending") this.telegram?.approval(id, approval.title);
				},
				onAnswer: (contactId, said, answer) => this.telegram?.answered(id, contactId, said, answer),
				onOutbound: (to, text) => this.telegram?.outbound(id, to, text),
				...(this.telegram ? { connectTelegram: (token: string) => this.telegram!.connect(id, token) } : {}),
				...(this.hookUrl ? { watchUrl: (watchId: string) => this.hookUrl!(id, watchId) } : {}),
				onWatches: () => void this.watchers?.sync().catch(() => undefined),
				updateSelf: (change) => this.updateAgentSelf(id, change),
			});
		}
		if (entry.ref.kind === "thread" && entry.debate) {
			return DebateRuntime.open({
				ref: entry.ref,
				file: entry.file!,
				hub: this.hub,
				record: entry.debate,
				onRecord: (record) => {
					const changed = record.status !== entry.debate?.status;
					entry.debate = record;
					if (record.config.participants.find((p) => p.role === "author")?.model) entry.model = record.config.participants.find((p) => p.role === "author")!.model;
					this.save();
					if (changed) this.changed(entry);
				},
				web: entry.web ?? true,
				webOptions: this.webOptions,
				...(this.chatExtras("thread").extensions ? { extensions: this.chatExtras("thread").extensions } : {}),
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
				extensions: [...(this.chatExtras("thread").extensions ?? []), ...(this.historyBridge(entry) ? [historyExtension(this.historyBridge(entry)!) as unknown as Extension] : [])],
				...(this.historyBridge(entry) ? { history: this.historyBridge(entry)! } : {}),
				...(this.connectors ? { connectors: this.connectors } : {}),
				toolsOff: () => entry.toolsOff ?? [],
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
			webOptions: this.webOptions,
			sandbox: () => this.chat?.settings.get().build?.sandbox !== false,
			// Auto review on the session's own model (Settings › Approvals; off by default).
			review: async (command, request) => {
				if (this.chat?.settings.get().build?.autoReview !== true) return undefined;
				const ask = this.reviewer ?? ((system: string, prompt: string) => this.hub.utility(system, prompt, entry.ref.id, { choice: entry.model ?? model }));
				return parseVerdict(await ask(REVIEW_SYSTEM, reviewPrompt(command, entry.cwd!, request)));
			},
			...(this.historyBridge(entry) ? { history: this.historyBridge(entry)! } : {}),
			...(entry.projectPath ? { trustPath: entry.projectPath } : {}),
			plan: {
				active: () => entry.planMode ?? false,
				setActive: (on) => {
					entry.planMode = on;
					this.save();
				},
			},
			...(entry.parent || entry.team ? {} : { runTask: (task, signal, onStart, onProgress) => this.runTask(entry, task, signal, onStart, onProgress), externalAgents: this.externalAgents() }),
			...(entry.team && this.teams ? { team: this.teamBridge(entry) } : {}),
			onAttention: (kind, message) => this.onAttention?.({ ref: entry.ref, title: entry.title, kind, message }),
			...(this.connectors ? { connectors: this.connectors } : {}),
			toolsOff: () => [...new Set([...(entry.toolsOff ?? []), ...((entry.parent && this.entries.get(entry.parent.id)?.toolsOff) || [])])],
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

function summary({ file: _f, sessionFile: _s, restoredFromSessionFile: _recovered, onDisk: _d, thinking: _t, debate, ...rest }: CatalogEntry): SessionSummary {
	return { ...rest, ...(debate ? { debate: { status: debate.status } } : {}) };
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
		// "/goal Add tests…": the command's words, not its name.
		.replace(/^\s*\/[\w:-]+\s+(?=\S)/, "")
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

/** A Build session's approval mode, and the profile that goes with it: Read only is the chat profile (18 §4). */
function buildMode(approvalMode: ApprovalMode): { approvalMode: ApprovalMode; profile: "build" | "chat" } {
	return { approvalMode, profile: approvalMode === "read_only" ? "chat" : "build" };
}

/** What the utility model is asked after an answer (suggestFollowUps). Empty when nothing calls for a reply. */
export const FOLLOW_UPS_PROMPT =
	"Decide whether the assistant's last answer calls for a quick reply from the user: it asks the user something, offers options, or proposes a next step the user would confirm. If it does, give up to three short replies the user might send, in the user's language, each under 7 words, concrete to this exchange. If the answer is complete and expects nothing (a finished task, a plain fact, a confirmation, a report), give none. Answer with a JSON array of strings only, [] for none.";

/** The replies in the utility model's answer (at most three), [] when it gave none, undefined when it isn't a list. */
export function parseFollowUps(list: string): string[] | undefined {
	try {
		const parsed = JSON.parse(list) as unknown;
		if (!Array.isArray(parsed)) return undefined;
		return parsed.filter((x): x is string => typeof x === "string").map((x) => x.trim()).filter(Boolean).slice(0, 3);
	} catch {
		return undefined;
	}
}

