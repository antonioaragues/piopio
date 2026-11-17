/**
 * Session catalog + open runtimes. Phase 0 keeps the catalog in a JSON index;
 * it moves to catalog.db (SQLite + FTS) with the Phase 1 sidebar.
 */
import { browserCaller, type BrowserCall, type BrowserSites } from "./tools/browser-tools.js";
import type { ConnectorHub } from "./connectors/hub.js";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, watch, writeFileSync, type FSWatcher } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { ApprovalMode, ApprovalRule, ContainerRef, ModelRef, ProjectInfo, PromptResponse, SessionSummary, TimelineItem, WorkOn } from "@piopio/protocol";
import { EngineError, type ModelHub } from "./models.js";
import type { EnginePaths } from "./paths.js";
import { CheckpointStore } from "./checkpoints.js";
import { attachmentsDir, copyAttachments, deleteAttachments, toolImageKeeper } from "./attachment-files.js";
import { draftAgent, type AgentDraft } from "./agent-draft.js";
import { addWorktree, checkout, git as runGit, mergeWorktree, removeWorktree, status as gitStatus } from "./git.js";
import { BuildRuntime } from "./runtimes/build.js";
import { parseVerdict, REVIEW_SYSTEM, reviewPrompt, type TaskResult } from "@piopio/pi-extensions";
import type { Runtime } from "./runtimes/runtime.js";
import { DatabaseSync } from "node:sqlite";
import { aboutMeExtension, aboutMeSdkExtension, type AboutMe } from "./about-me.js";
import type { Settings } from "./settings.js";
import type { ChatResources } from "./tools/chat-resources.js";
import { AgentRuntime, type AgentOpenOptions } from "./runtimes/agent.js";
import { writingExtension } from "./tools/writing.js";
import { durableVisualsExtension, visualChecker, type VisualCheck } from "./tools/visuals.js";
import type { AgentFiles } from "./agent-files.js";
import type { AppServices } from "./app-services.js";
import type { MemoryProviders } from "./memory.js";
import { alwaysLabel, type Envelope, type PeerLog, newDefinition, modelOf, nextFire, validate, TEMPLATES, type AgentDefinition, type DefinitionError, type Watch } from "@piopio/runtime";
import type { Extension } from "@earendil-works/pi-durable";
import type { WebOptions } from "./tools/web.js";
import { exportTranscript, type ExportFormat } from "./export.js";
import { SearchIndex } from "./search.js";
import type { HistoryBridge } from "./tools/history.js";
import { AGENT_NAMES, findAgent, installedAgents, runExternalAgent, type ExternalAgent } from "./external-agents.js";
import type { TelegramChannels } from "./channels/manager.js";
import type { AgentWatchers } from "./watchers.js";
import { runCommand, type WorkHost, type WorkRunner } from "./work/runner.js";
import type { BoardBridge } from "./work/extension.js";
import type { SideBridge, SideLine } from "./tools/side.js";
import type { ConsultBridge } from "./consult.js";
import { routineLabel } from "./work/routines.js";
import { TimelineBuilder, type PiMessage } from "./timeline/builder.js";
import { sdkMessages, SdkEventMapper } from "./timeline/pi-sdk.js";
import { migrateChat } from "./migrate-chats.js";
import type { SessionEvent } from "@piopio/protocol";

type CatalogEntry = SessionSummary & {
	thinking?: string;
	file?: string;
	sessionFile?: string;
	/** Chats moved from pi-durable (2026-11-15): the old SQLite file, kept until the chat is deleted. */
	migratedFrom?: string;
	/** Original CLI file for recovered history; avoid importing a duplicate after restore. */
	restoredFromSessionFile?: string;
	/** The pi session file was seen on disk, so its disappearance means it was deleted. */
	onDisk?: boolean;
	/** Chats before 2026-11-15: the branch a pi-durable chat showed (read once, by the migration). */
	branches?: { active?: string };
	web?: boolean;
	/** Build: the session's approval mode (new sessions take their project's). */
	approvalMode?: ApprovalMode;
	/** Build: plan mode (piopio-plan). */
	planMode?: boolean;
	/** Agents: the definition folder. */
	agentFolder?: string;
	/** A side conversation (docs/spec/24): its brief while queued, and who drove its last turn (a turn you drove doesn't wake its parent). */
	sideBrief?: string;
	sideBy?: "parent" | "you";
	/** A conversation with side conversations: turns their notes woke in a row since your last message, and notes waiting for a sibling. */
	sideWoke?: number;
	sidePending?: string[];
	/** Offer cards this conversation left (by tool call id), answered or not; and its proposals' briefs. */
	sideOffers?: Record<string, { title: string; brief?: string; project?: string; answered?: "new" | "here" }>;
	sideBriefs?: Record<string, string>;
};

/** At most this many subagents run at once per session (docs/spec/05-build §4). */
const MAX_SUBAGENTS = 3;
/** Side conversations (docs/spec/24 §4–§5): at most this many of one parent run at once, and their notes wake it at most this many turns in a row without you. */
const SIDE_MAX = 4;
const WAKE_LIMIT = 5;

/** Where Build sessions get their default approval mode and "always allow" rules (the projects). */
export type ApprovalPolicy = {
	/** The project that contains `cwd` (worktrees live under the project's id). */
	projectFor(cwd: string): { id: string; path: string } | undefined;
	modeFor(cwd: string): ApprovalMode;
	rulesFor(cwd: string): ApprovalRule[];
	addRule(cwd: string, rule: { kind: ApprovalRule["kind"]; pattern: string }): void;
	/** Folders linked to the project (docs/spec/18 §18). */
	foldersFor?(cwd: string): { path: string; edit: boolean }[];
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
	chat?: { settings: Settings; aboutMe: AboutMe; mcpOff: () => string[]; resources: ChatResources };
	/** Agent folders and memory (set by the engine). */
	agentHost?: { files: AgentFiles; memory: MemoryProviders; app?: AppServices };
	/** Each agent's last valid definition, as the runtime uses it. */
	private definitions = new Map<string, { definition: AgentDefinition; instructions: string }>();
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
	/** Projects' work (docs/spec/26): their boards, set by the engine. */
	work?: WorkRunner;
	/** A project's work changed (the app refreshes its board). */
	onWork?: (project: string) => void;
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
				// Debates are gone (2026-11-15): a debate thread opens as a chat with its author.
				delete (e as { debate?: unknown }).debate;
				// A side conversation or subagent the engine stopped in the middle of (a quit, a crash) won't go on by itself.
				if (e.side && (e.side.state === "working" || e.side.state === "queued")) e.side.state = "stopped";
				if (e.parent?.state === "working" || e.parent?.state === "queued") e.parent.state = "stopped";
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
	 * session, the other sessions of its project; a chat without a project, the other chats without one. Not agents.
	 */
	historyBridge(entry: CatalogEntry): HistoryBridge | undefined {
		const scopeOf = (e: CatalogEntry) => (e.ref.kind === "build" ? `build:${e.projectPath ?? e.cwd}` : e.ref.kind === "thread" && !e.projectPath ? "chats" : undefined);
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
		if (entry.ref.kind === "build" || entry.ref.kind === "thread") {
			if (!entry.sessionFile || !existsSync(entry.sessionFile)) return [];
			const builder = new TimelineBuilder(entry.ref);
			builder.reset(sdkMessages(SessionManager.open(entry.sessionFile).buildSessionContext().messages as unknown as PiMessage[]), (index) => SdkEventMapper.idOf(index), false);
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
		if ((entry.ref.kind === "build" || entry.ref.kind === "thread") && !this.open.has(entry.ref.id)) {
			if (!entry.sessionFile || !existsSync(entry.sessionFile)) return;
			const builder = new TimelineBuilder(entry.ref);
			const messages = SessionManager.open(entry.sessionFile).buildSessionContext().messages as unknown as PiMessage[];
			builder.reset(sdkMessages(messages), index => SdkEventMapper.idOf(index), false);
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
		if (ref.kind !== "thread") throw new EngineError("INVALID", "Only conversations can be branched into a new one.");
		const runtime = await this.build(ref);
		if (runtime.snapshot().state.status === "running") throw new EngineError("BUSY", "Wait for the answer to finish before branching into a new thread.");
		// pi writes the branched session file next to this one, in chatsDir.
		const file = runtime.forkFile(itemId);
		const now = new Date().toISOString();
		const copy: CatalogEntry = { ...structuredClone(source), ref: { kind: "thread", id: newId("thr") }, title: `${source.title} (branch)`, createdAt: now, updatedAt: now, sessionFile: file };
		delete copy.file;
		delete copy.continuedIn;
		copy.cwd = this.scratch(copy.ref.id);
		copyAttachments(this.paths.home, ref.id, copy.ref.id);
		this.entries.set(copy.ref.id, copy);
		this.save();
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
		for (const old of [entry.file, entry.migratedFrom]) if (old) for (const suffix of ["", "-wal", "-shm"]) rmSync(old + suffix, { force: true });
		if (entry.ref.kind === "thread") {
			// A chat's files are Piopio's own (chatsDir, scratchDir): they go, as a chat's history always did.
			if (entry.sessionFile) rmSync(entry.sessionFile, { force: true });
			if (entry.cwd && resolve(entry.cwd).startsWith(`${resolve(this.paths.scratchDir)}/`)) rmSync(entry.cwd, { recursive: true, force: true });
		} else if (entry.sessionFile && existsSync(entry.sessionFile)) moveToTrash(entry.sessionFile, this.piOverrides.trashDir ?? join(homedir(), ".Trash"));
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

	async create(params: { kind: "thread" | "build"; instructions?: string; cwd?: string; model?: ModelRef; thinking?: string; title?: string; workOn?: WorkOn; approvalMode?: ApprovalMode; planMode?: boolean; profile?: "build" | "chat" }): Promise<ContainerRef> {
		if (params.kind === "build" && !params.cwd) throw new EngineError("INVALID", "Build sessions need a cwd.");
		if (params.planMode && params.kind !== "build") throw new EngineError("INVALID", "Only folder conversations support Plan mode.");
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
			title: params.title?.trim() || (params.kind === "thread" ? "New thread" : "New session"),
			createdAt: now,
			updatedAt: now,
			model: params.model ?? this.hub.defaultModel,
			...(cwd ? { cwd } : {}),
			...(worktree ? { projectPath: params.cwd!, worktree } : {}),
			...(params.thinking ? { thinking: params.thinking } : {}),
			...(params.planMode ? { planMode: true } : {}),
			...(params.kind === "build" ? buildMode(params.profile === "chat" ? "read_only" : (params.approvalMode ?? this.policy.modeFor(params.cwd!))) : {}),
			...(params.kind === "thread" ? { cwd: this.scratch(ref.id) } : {}),
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
			// A side conversation reports to its parent whenever it's open (docs/spec/24 §5).
			if (entry.side || entry.parent) void pending.then((runtime) => this.watchChild(entry, runtime)).catch(() => undefined);
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

	// ── Subagents (piopio-subagents, docs/spec/17 §3) ──────────────────────────

	/** Claude Code / Codex tasks running per parent (they wait for a slot; Piopio's own subagents are counted by state). */
	private subagents = new Map<string, { running: number; waiting: (() => void)[] }>();
	/** A blocking `task`'s progress lines, `task_wait`'s waiters, and results nobody has collected yet, by child id. */
	private readonly taskProgress = new Map<string, (line: string) => void>();
	private readonly taskWaiters = new Map<string, ((result: TaskResult) => void)[]>();
	private readonly taskResults = new Map<string, TaskResult>();

	/**
	 * Starts a `task` as a child Build session (same folder, model and approval mode), one level deep, and returns at
	 * once. Past MAX_SUBAGENTS working for one parent it waits as queued. Its result goes back to the parent as a
	 * `[Task]` note (the side conversations' bridge, 26 §7.1), unless `task_wait` collects it.
	 */
	async startTask(parentRef: ContainerRef, task: { callId: string; description: string; prompt: string }): Promise<{ sessionId: string; queued: boolean }> {
		const parent = this.entry(parentRef);
		const working = this.childrenOf(parent.ref.id).filter((c) => c.parent && c.parent.state === "working").length;
		// A child never gets more than its parent: the same profile (a Chat-lens parent has no bash) and the same tools
		// turned off (see `toolsOff` in build(), which also follows later changes to the parent).
		const ref = await this.create({ kind: "build", cwd: parent.cwd!, ...(parent.model ? { model: parent.model } : {}), approvalMode: parent.approvalMode ?? this.policy.modeFor(parent.projectPath ?? parent.cwd!), title: task.description });
		const child = this.entry(ref);
		child.parent = { id: parent.ref.id, callId: task.callId, state: working >= MAX_SUBAGENTS ? "queued" : "working" };
		if (parent.toolsOff?.length) child.toolsOff = [...parent.toolsOff];
		if (parent.projectPath) child.projectPath = parent.projectPath;
		if (child.parent.state === "queued") child.sideBrief = task.prompt;
		this.save();
		this.changed(child);
		if (child.parent.state === "working") await this.childSubmit(child, task.prompt);
		return { sessionId: ref.id, queued: child.parent.state === "queued" };
	}

	/** One of `parent`'s subagents, or an error for the model. */
	private ownTask(parent: CatalogEntry, id: string): CatalogEntry {
		const child = this.entries.get(id);
		if (!child || child.parent?.id !== parent.ref.id) throw new EngineError("NOT_FOUND", `${id} isn't one of this conversation's subagents.`);
		return child;
	}

	/** `task_wait`: their results, as each finishes. A waited-for result doesn't also come back as a note. */
	async waitTasks(parentRef: ContainerRef, ids: readonly string[], signal?: AbortSignal): Promise<TaskResult[]> {
		const parent = this.entry(parentRef);
		const children = ids.map((id) => this.ownTask(parent, id));
		return Promise.all(
			children.map(async (child) => {
				const kept = this.taskResults.get(child.ref.id);
				if (kept) {
					this.taskResults.delete(child.ref.id);
					return kept;
				}
				if (child.parent!.state !== "working" && child.parent!.state !== "queued") return this.taskResultOf(child, await this.runtime(child.ref));
				return new Promise<TaskResult>((resolve, reject) => {
					this.taskWaiters.set(child.ref.id, [...(this.taskWaiters.get(child.ref.id) ?? []), resolve]);
					signal?.addEventListener("abort", () => reject(new Error("Stopped waiting.")), { once: true });
				});
			}),
		);
	}

	/** `task_stop`: a queued one won't start; a working one's turn stops. */
	async stopTask(parentRef: ContainerRef, id: string): Promise<string> {
		const child = this.ownTask(this.entry(parentRef), id);
		if (child.parent!.state === "queued") {
			delete child.sideBrief;
			this.setChildState(child, "stopped");
			return `${id} won't start.`;
		}
		await (await this.runtime(child.ref)).abort();
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
		this.setChildState(child, result.status === "error" ? "failed" : result.status);
		const waiters = this.taskWaiters.get(child.ref.id);
		if (waiters?.length) {
			this.taskWaiters.delete(child.ref.id);
			for (const w of waiters) w(result);
		} else {
			this.taskResults.set(child.ref.id, result);
			const word = result.status === "done" ? "finished" : result.status === "error" ? "failed" : "was stopped";
			const text = result.text.length > 8000 ? `${result.text.slice(0, 8000).trimEnd()}… (read the rest with read_conversation ${child.ref.id})` : result.text;
			await this.reportToParent(child, `[Task] “${child.title}” (${child.ref.id}) ${word}.${result.costUsd ? ` It cost $${result.costUsd.toFixed(2)}.` : ""}${text.trim() ? `\n\n${text.trim().split("\n").map((l) => `> ${l}`).join("\n")}` : ""}`, `Result from ${child.title} · ${result.status === "error" ? "failed" : result.status}`);
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
	private async runTask(
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
				const path = this.findExternal(task.agent);
				if (!path) return { text: `${AGENT_NAMES[task.agent]} isn't installed on this Mac.`, sessionId: "", costUsd: 0, status: "error" };
				return await runExternalAgent(task.agent, { path, cwd: parent.cwd!, prompt: task.prompt, mode: parent.approvalMode ?? this.policy.modeFor(parent.projectPath ?? parent.cwd!), ...(signal ? { signal } : {}), onProgress });
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
			// "What should I do for you?" with three ideas to tap (docs/spec/21 D4, design 5a); or their own words.
			await (await this.agent(entry.ref)).greet(`${hi} What should I do for you? Pick an idea, or tell me in your own words.`, [
				"Every morning, tell me what's ahead",
				"Watch my email and warn me about bills",
				"Keep a shared list for the family",
			]);
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
		// A schedule the runtime hasn't armed yet has no next time: it comes from its cron (Home, the agent page).
		const schedules = (() => {
			try {
				return this.agentDefinition(ref.id).definition.schedules ?? [];
			} catch {
				return [];
			}
		})();
		for (const u of upcoming) {
			if (u.next || u.kind !== "schedule") continue;
			const s = schedules.find((x) => x.id === u.id);
			try {
				if (s) u.next = nextFire(s.cron, s.tz ?? Intl.DateTimeFormat().resolvedOptions().timeZone, Date.now());
			} catch {
				// a cron that never fires
			}
		}
		return {
			runs: runs.map(({ conversationId: _c, deliverTo: _d, ...r }) => r),
			outbox: outbox.map((o) => ({ id: o.id, to: o.to, text: o.text, notBefore: iso(o.notBefore), reason: o.reason })),
			upcoming: upcoming.map((u) => ({ id: u.id, kind: u.kind, label: u.label, ...(u.next ? { next: iso(u.next) } : {}), ...(u.cron ? { cron: u.cron } : {}) })),
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

	/** Your agents, for drafts that suggest them (docs/spec/21 D7). */
	consultAgents() {
		return this.consultBridge().agents();
	}

	/** A conversation with Piopio in this project (not a helper's or a subagent's), or an error saying why not. */
	plannerIn(ref: ContainerRef, projectPath: string): void {
		const entry = this.entry(ref);
		if (entry.ref.kind !== "build" || entry.parent || entry.helper) throw new EngineError("INVALID", "Only a conversation with Piopio in a project can plan parallel work.");
		if ((entry.projectPath ?? entry.cwd) !== projectPath) throw new EngineError("INVALID", "That conversation is in another project.");
	}

	/** "Work in parallel" on Piopio's offer: that conversation plans what was asked, now with the board. */
	async planInParallel(ref: ContainerRef): Promise<void> {
		const runtime = await this.runtime(ref);
		await runtime.submit("[Board] The user chose to work in parallel. Plan what they asked above: put the independent parts on the board as tasks, then tell them in a sentence or two.", { whenBusy: "followUp" });
		this.touch(ref);
	}

	/**
	 * Sessions from before docs/spec/26: a lead's conversation is a plain one with Piopio; a member's is a helper's,
	 * under its team's project (`projectOf`, from the migration).
	 */
	migrateTeams(projectOf: (teamId: string) => string | undefined): void {
		let changed = false;
		for (const entry of this.entries.values()) {
			const old = (entry as CatalogEntry & { team?: { id: string; kind: string; taskId?: string } }).team;
			if (!old) continue;
			delete (entry as { team?: unknown }).team;
			const project = projectOf(old.id);
			if (old.kind !== "lead" && project && old.taskId) entry.helper = { project, kind: old.kind === "review" ? "review" : "build", taskId: old.taskId };
			changed = true;
		}
		if (changed) this.save();
	}

	/** Answers your conversations wait for (docs/spec/21 D6), by request id. */
	private readonly consulting = new Map<string, (reply: string) => void>();

	/** Your agents, asked from a conversation: each answers in its conversation with Piopio. */
	private consultBridge(): ConsultBridge {
		return {
			agents: () =>
				[...this.entries.values()].flatMap((e) => {
					if (e.ref.kind !== "agent") return [];
					try {
						const def = this.agentDefinition(e.ref.id).definition;
						return def.interview ? [] : [{ id: e.ref.id, name: def.name, ...(def.description ? { description: def.description } : {}) }];
					} catch {
						return [];
					}
				}),
			ask: async (agentId, message, from) => {
				const def = this.agentDefinition(agentId).definition;
				const requestId = `amsg_${randomUUID().slice(0, 12)}`;
				const envelope: Envelope = {
					id: requestId,
					mode: "ask",
					from: { id: "piopio", name: "Piopio" },
					to: { id: agentId, name: def.name },
					text: `For the user, from their conversation “${from}”:\n\n${message}`,
					traceId: `tr_${randomUUID().slice(0, 12)}`,
					hop: 1,
					requestId,
					at: new Date().toISOString(),
				};
				let timer: ReturnType<typeof setTimeout> | undefined;
				const answer = new Promise<string | undefined>((resolve) => {
					this.consulting.set(requestId, resolve);
					timer = setTimeout(() => resolve(undefined), this.agentAskTimeoutMs ?? 10 * 60_000);
				});
				try {
					await (await this.agent({ kind: "agent", id: agentId })).core.peers.receive(envelope);
					return await answer;
				} finally {
					clearTimeout(timer);
					this.consulting.delete(requestId);
				}
			},
		};
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
				// An answer to one of your conversations (consultBridge).
				if (to === "piopio" && envelope.mode === "reply") {
					this.consulting.get(envelope.requestId ?? "")?.(envelope.text);
					return;
				}
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
			...(def.interview ? { draft: true } : {}),
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
	private visuals?: Extension;

	private agentExtras(): Extension[] {
		const s = this.chat?.settings.get().aboutMe;
		const aboutMe = s?.enabled && s.inAgents ? this.aboutMeFor("agent") : undefined;
		this.writing ??= writingExtension() as unknown as Extension;
		this.visuals ??= durableVisualsExtension() as unknown as Extension;
		return aboutMe ? [aboutMe, this.writing, this.visuals] : [this.writing, this.visuals];
	}

	/** Sites the browser may act on (docs/spec/22 §4.4); set by the engine. */
	browserSites?: BrowserSites;

	/** The browser for a conversation or Build session, through the Mac app (docs/spec/22). */
	private browserFor(ref: ContainerRef): { browser?: BrowserCall } {
		const app = this.agentHost?.app;
		return app ? { browser: browserCaller(app, ref, { allowPrivate: this.webOptions.allowPrivate ?? false, ...(this.browserSites ? { sites: this.browserSites } : {}) }) } : {};
	}

	/** The check of visuals for a conversation or Build session, by the Mac app (docs/spec/25 §3.2). */
	private visualsFor(ref: ContainerRef): { visuals?: VisualCheck } {
		const app = this.agentHost?.app;
		return app ? { visuals: visualChecker(app, ref) } : {};
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

	// ── Side conversations (docs/spec/24) ─────────────────────────────────

	/** A conversation's side conversations, oldest first. */
	sidesOf(parentId: string): CatalogEntry[] {
		return [...this.entries.values()].filter((e) => e.side?.parent.id === parentId).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
	}

	private sideLine(e: CatalogEntry): SideLine {
		return { id: e.ref.id, title: e.title, state: e.side!.state.replace("_", " "), ...(e.worktree?.branch ? { branch: e.worktree.branch } : {}), ...(e.side!.line ? { line: e.side!.line } : {}) };
	}

	/**
	 * A side conversation of `parentRef`: an ordinary conversation of the same kind in the same project, with the
	 * parent's model and permissions (never wider), in a worktree of its own when it will change files in a git project
	 * (SC5, SC6). The brief is its first message; past SIDE_MAX running, it waits as queued.
	 */
	async startSide(parentRef: ContainerRef, input: { title?: string; brief: string; workOn?: "worktree" | "here"; project?: string }, how: NonNullable<CatalogEntry["side"]>["how"]): Promise<CatalogEntry> {
		const parent = this.entry(parentRef);
		if ((parent.ref.kind !== "build" && parent.ref.kind !== "thread") || parent.parent || parent.helper) throw new EngineError("INVALID", "Only your own conversations start side conversations.");
		const brief = input.brief.trim();
		if (!brief) throw new EngineError("INVALID", "Say what the side conversation should do.");
		const first = brief.split("\n")[0]!.replace(/\s+/g, " ");
		const title = (input.title?.trim() || (first.length > 60 ? `${first.slice(0, 59).trimEnd()}…` : first)).slice(0, 80);
		// In another of your projects when it's plainly about it (SCQ5, 26 CL11): that project's folder and permissions.
		const elsewhere = input.project?.trim() ? this.projectNamed?.(input.project.trim()) : undefined;
		if (input.project?.trim() && !elsewhere) throw new EngineError("NOT_FOUND", `No project called “${input.project.trim()}”.`);
		const folder = elsewhere ? elsewhere.path : parent.ref.kind === "build" ? (parent.projectPath ?? parent.cwd!) : undefined;
		const mode = elsewhere ? this.policy.modeFor(elsewhere.path) : (parent.approvalMode ?? (folder ? this.policy.modeFor(folder) : undefined));
		let workOn: WorkOn | undefined;
		if (folder && input.workOn !== "here" && mode !== "read_only" && (await gitStatus(folder)).repo) {
			const slug = title.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "side";
			workOn = { kind: "worktree", branch: `side/${slug}-${randomUUID().slice(0, 4)}` };
		}
		const running = this.sidesOf(parent.ref.id).filter((s) => s.side!.state === "working").length;
		const ref = await this.create({ kind: elsewhere ? "build" : parent.ref.kind, ...(folder ? { cwd: folder } : {}), ...(parent.model ? { model: parent.model } : {}), ...(parent.thinking ? { thinking: parent.thinking } : {}), ...(mode ? { approvalMode: mode } : {}), ...(parent.profile && !elsewhere ? { profile: parent.profile } : {}), title, ...(workOn ? { workOn } : {}) });
		const child = this.entry(ref);
		child.side = { parent: { id: parent.ref.id, title: parent.title }, how, state: running >= SIDE_MAX ? "queued" : "working" };
		child.sideBy = "parent";
		if (parent.toolsOff?.length && !elsewhere) child.toolsOff = [...parent.toolsOff];
		const opening = `${brief}\n\n(This is a side conversation started from “${parent.title}” (${parent.ref.id}). It works on its own; read that conversation with read_conversation only if you need its background.)`;
		if (child.side.state === "queued") child.sideBrief = opening;
		this.save();
		this.changed(child);
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
		return [...this.entries.values()].filter((e) => this.parentIdOf(e) === parentId);
	}

	private async childSubmit(child: CatalogEntry, text: string): Promise<void> {
		const runtime = await this.runtime(child.ref);
		this.watchChild(child, runtime);
		await runtime.submit(text, { whenBusy: "followUp" });
		this.touch(child.ref, text);
	}

	private readonly childWatched = new WeakSet<Runtime>();

	/** Follows a child's turns: its live line, its state, and its report to the parent when a turn ends or it needs you. */
	private watchChild(child: CatalogEntry, runtime: Runtime): void {
		if (this.childWatched.has(runtime)) return;
		this.childWatched.add(runtime);
		let started = runtime.snapshot().state.status === "running";
		let lineAt = 0;
		runtime.onEvents((events) => {
			for (const e of events) {
				const link = child.side ?? child.parent;
				if (!link) return;
				if ((e.type === "item.added" || e.type === "item.updated") && e.item.kind === "tool" && e.item.status === "running") {
					const line = progressLine(e.item.tool, e.item.args);
					this.taskProgress.get(child.ref.id)?.(line);
					if (Date.now() - lineAt > 1000) {
						lineAt = Date.now();
						link.line = line;
						this.changed(child);
					}
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
			if (state !== "working") delete child.parent.line;
		} else return;
		this.save();
		this.changed(child);
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
		const parent = this.entries.get(this.parentIdOf(child) ?? "");
		if (!parent) return;
		const quiet = child.sideBy === "you" || (parent.sideWoke ?? 0) >= WAKE_LIMIT || (!!child.side && this.chat?.settings.get().chat.sideWake === false);
		if (quiet) {
			const runtime = await this.runtime(parent.ref);
			if (runtime instanceof BuildRuntime) await runtime.sideNote(text, summary);
			return;
		}
		parent.sidePending = [...(parent.sidePending ?? []), text];
		this.save();
		if (this.childrenOf(parent.ref.id).some((c) => c !== child && (c.side?.state === "working" || c.parent?.state === "working"))) return;
		const notes = parent.sidePending;
		parent.sidePending = [];
		parent.sideWoke = (parent.sideWoke ?? 0) + 1;
		this.save();
		const runtime = await this.runtime(parent.ref);
		await runtime.submit(notes.join("\n\n"), { whenBusy: "followUp" });
		this.touch(parent.ref);
	}

	/** You wrote in a conversation yourself: its side conversations may wake it again, and a side conversation you drive doesn't wake its parent. */
	youWrote(ref: ContainerRef): void {
		const entry = this.entries.get(ref.id);
		if (!entry) return;
		entry.sideWoke = 0;
		if (entry.side) entry.sideBy = "you";
		this.save();
	}

	/** One of `parent`'s side conversations, or an error for the model. */
	private ownSide(parent: CatalogEntry, id: string): CatalogEntry {
		const child = this.entries.get(id);
		if (!child || child.side?.parent.id !== parent.ref.id) throw new EngineError("NOT_FOUND", `${id} isn't one of this conversation's side conversations.`);
		return child;
	}

	/** A project by name (or id), for a side conversation in another project; set by the engine. */
	projectNamed?: (name: string) => { id: string; path: string } | undefined;
	/** Your projects' names; set by the engine. */
	projectNames?: () => string[];
	/** New conversation answers in a row (SCQ3): after three, the app offers Always start. */
	private sideStreak = 0;

	private sideSettings(): { onUnrelated: "ask" | "start" | "off"; propose: boolean } {
		const chat = this.chat?.settings.get().chat;
		return { onUnrelated: chat?.sideOnUnrelated ?? "ask", propose: chat?.sidePropose !== false };
	}

	/** Whether the turn now running began with your own words (not a note, the board or a routine). */
	private async yourTurn(entry: CatalogEntry): Promise<boolean> {
		const user = [...(await this.runtime(entry.ref)).snapshot().items].reverse().find((i) => i.kind === "user");
		return !!user && user.kind === "user" && !/^\[(Side|Task|Board|Routine)\]/.test(user.text);
	}

	/**
	 * Your answer to a side card (docs/spec/24 §1): an offer's New conversation or Do it here, a proposal's Start or
	 * Dismiss. Each card is answered once.
	 */
	async answerSide(ref: ContainerRef, id: string, choice: "new" | "here" | "start" | "dismiss"): Promise<{ ref?: ContainerRef; askAlways?: boolean }> {
		const entry = this.entry(ref);
		if (choice === "new" || choice === "here") {
			const offer = entry.sideOffers?.[id];
			if (!offer) throw new EngineError("NOT_FOUND", "That offer isn't here.");
			if (offer.answered) throw new EngineError("INVALID", offer.answered === "new" ? "It already has its own conversation." : "You chose to do it here.");
			offer.answered = choice;
			this.save();
			if (choice === "here") {
				this.sideStreak = 0;
				this.youWrote(ref);
				await (await this.runtime(ref)).submit("Do it here.", { whenBusy: "followUp" });
				this.touch(ref);
				return {};
			}
			// Its brief: the part of your words the offer named, else your whole message (§3: a fresh conversation would do it from your words alone).
			const user = [...(await this.runtime(ref)).snapshot().items].reverse().find((i) => i.kind === "user");
			const brief = offer.brief?.trim() || (user?.kind === "user" ? user.text : offer.title);
			const child = await this.startSide(ref, { title: offer.title, brief, ...(offer.project ? { project: offer.project } : {}) }, "offered");
			this.sideStreak++;
			return { ref: child.ref, ...(this.sideStreak >= 3 && this.sideSettings().onUnrelated === "ask" ? { askAlways: true } : {}) };
		}
		const proposal = entry.sideProposals?.find((p) => p.id === id);
		if (!proposal) throw new EngineError("NOT_FOUND", "That proposal is gone (started, dismissed or expired).");
		const brief = entry.sideBriefs?.[id] ?? proposal.title;
		this.dropProposal(entry, id);
		if (choice === "dismiss") return {};
		const child = await this.startSide(ref, { title: proposal.title, brief, ...(proposal.project ? { project: proposal.project } : {}) }, "proposed");
		return { ref: child.ref };
	}

	private dropProposal(entry: CatalogEntry, id: string): void {
		entry.sideProposals = entry.sideProposals?.filter((p) => p.id !== id);
		if (!entry.sideProposals?.length) delete entry.sideProposals;
		if (entry.sideBriefs) delete entry.sideBriefs[id];
		this.save();
		this.changed(entry);
	}

	/** The side tools for one of your conversations (tools/side.ts). */
	private sideBridge(entry: CatalogEntry): SideBridge {
		return {
			settings: () => this.sideSettings(),
			projects: () => (entry.ref.kind === "thread" ? (this.projectNames?.() ?? []) : []),
			list: () => [
				...this.sidesOf(entry.ref.id).map((s) => this.sideLine(s)),
				...(entry.sideProposals ?? []).filter((p) => Date.parse(p.expiresAt) > Date.now()).map((p) => ({ id: p.id, title: p.title, state: "proposed" })),
			],
			offer: async (callId, input) => {
				if (this.sideSettings().onUnrelated === "off") throw new EngineError("INVALID", "The user turned these offers off: do the work here.");
				if (!(await this.yourTurn(entry))) throw new EngineError("INVALID", "Offer a side conversation only for the user's own message.");
				if (input.project?.trim() && !this.projectNamed?.(input.project.trim())) throw new EngineError("NOT_FOUND", `No project called “${input.project.trim()}”.`);
				entry.sideOffers = { ...entry.sideOffers, [callId]: { title: input.title.trim(), ...(input.brief?.trim() ? { brief: input.brief.trim() } : {}), ...(input.project?.trim() ? { project: input.project.trim() } : {}) } };
				this.save();
				return "Offered. Stop here and wait for their choice.";
			},
			propose: async (callId, input) => {
				if (!this.sideSettings().propose) throw new EngineError("INVALID", "The user turned proposals off.");
				const open = (entry.sideProposals ?? []).filter((p) => Date.parse(p.expiresAt) > Date.now());
				if (open.some((p) => p.title.toLowerCase() === input.title.trim().toLowerCase())) throw new EngineError("INVALID", "That's already proposed.");
				if (open.length >= 6) throw new EngineError("INVALID", "Six proposals are waiting already: dismiss one first.");
				if (input.project?.trim() && !this.projectNamed?.(input.project.trim())) throw new EngineError("NOT_FOUND", `No project called “${input.project.trim()}”.`);
				entry.sideProposals = [...open, { id: callId, title: input.title.trim(), why: input.why.trim(), ...(input.project?.trim() ? { project: input.project.trim() } : {}), expiresAt: new Date(Date.now() + 7 * 86_400_000).toISOString() }];
				entry.sideBriefs = { ...entry.sideBriefs, [callId]: input.brief.trim() };
				this.save();
				this.changed(entry);
				return `Proposed as ${callId}. The user may start it until it expires in a week.`;
			},
			dismiss: async (id) => {
				if (!entry.sideProposals?.some((p) => p.id === id)) throw new EngineError("NOT_FOUND", `No proposal ${id}.`);
				this.dropProposal(entry, id);
				return `Withdrew ${id}.`;
			},
			start: async (input) => {
				// Only on the user's own words: a turn a note, the board or a routine started can't start one (§4).
				if (!(await this.yourTurn(entry))) throw new EngineError("INVALID", "Start a side conversation only when the user asks for separate work in their own message.");
				return this.sideLine(await this.startSide(entry.ref, input, "asked"));
			},
			send: async (id, message) => {
				const child = this.ownSide(entry, id);
				child.sideBy = "parent";
				if (child.side!.state === "queued") {
					child.sideBrief = `${child.sideBrief ?? ""}\n\n${message}`;
					this.save();
					return `Added to ${id}'s brief; it starts when there's room.`;
				}
				await this.childSubmit(child, message);
				return `Sent to ${id}.`;
			},
			read: async (id, from = 0) => {
				const child = this.ownSide(entry, id);
				const snap = (await this.runtime(child.ref)).snapshot();
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
				await (await this.runtime(child.ref)).abort();
				return `Stopped ${id}'s turn.`;
			},
		};
	}

	// ── Projects' work (docs/spec/26) ─────────────────────────────────────

	/**
	 * The board's tools: Piopio's in a conversation in a project with parallel work on, or a reviewer helper's verdict.
	 * Piopio's brief is read each turn, so it's empty once parallel work goes off.
	 */
	private boardBridge(entry: CatalogEntry, kind: BoardBridge["kind"]): BoardBridge {
		const work = this.work!;
		const project = () => {
			const p = this.policy.projectFor(entry.projectPath ?? entry.cwd!);
			if (!p) throw new EngineError("NOT_FOUND", "This conversation isn't in a project.");
			return p.id;
		};
		return {
			kind,
			brief: () => (work.find(project())?.way.parallel ? work.brief(project()) : ""),
			createTask: async (task) => {
				const t = await work.createTask(project(), task, "piopio", entry.ref.id);
				return `Added ${t.id} “${t.title}” for a ${t.helper}: ${t.state === "doing" ? "started" : "waits for a free slot"}.`;
			},
			board: () => work.board(project(), entry.ref.id),
			message: (taskId, text) => work.message(project(), taskId, text),
			verdict: (pass, notes) => work.verdict(entry.ref.id, pass, notes),
			// The project's routines (docs/spec/21 AD5).
			addRoutine: async (input) => {
				const r = await work.addRoutine(project(), input, "piopio");
				const url = r.on === "webhook" ? work.hookUrl?.(project(), r.id) : undefined;
				return `Set ${r.id}: ${routineLabel(r)}${r.next ? `, first ${new Date(r.next).toISOString().slice(0, 16).replace("T", " ")} UTC` : ""}.${url ? ` Its URL (POST, from this Mac): ${url}` : ""} The user sees it in the project.`;
			},
			routines: () => work.routineList(project()),
			cancelRoutine: async (id) => {
				const r = await work.removeRoutine(project(), id);
				return `Removed ${r.id}: ${routineLabel(r)}.`;
			},
		};
	}

	/** What the work runner needs from the catalog: sessions, their turns, git and the checks. */
	workHost(options: { stateFile: string; routinesFile: string; worktreesDir: string; log: (line: string) => void; project: WorkHost["project"] }): WorkHost {
		const answerOf = (runtime: Runtime) => {
			const last = [...runtime.snapshot().items].reverse().find((i) => i.kind === "assistant");
			return last?.kind === "assistant" ? last.parts.filter((p) => p.type === "text").map((p) => p.text).join("") : "";
		};
		return {
			createSession: async ({ cwd, title, model, approvalMode, helper }) => {
				const ref = await this.create({ kind: "build", cwd, title, ...(approvalMode ? { approvalMode } : {}), ...(model ? { model: model.includes(":") ? { provider: model.split(":")[0]!, id: model.split(":").slice(1).join(":") } : { provider: "openrouter", id: model } } : {}) });
				const entry = this.entry(ref);
				if (helper) entry.helper = helper;
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
			project: options.project,
			cost: async (id) => (await this.runtime({ kind: "build", id })).snapshot().state.usage?.costUsd ?? 0,
			worktreesDir: options.worktreesDir,
			stateFile: options.stateFile,
			routinesFile: options.routinesFile,
			changed: (project) => this.onWork?.(project),
			log: options.log,
		};
	}

	/** pi's resources changed (packages): open conversations read them again. */
	async reloadResources(): Promise<void> {
		for (const pending of this.open.values()) {
			const runtime = await pending.catch(() => undefined);
			if (runtime instanceof BuildRuntime) await runtime.reloadResources().catch(() => undefined);
		}
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
		if (!(runtime instanceof BuildRuntime) || ref.kind !== "thread") throw new EngineError("INVALID", "Only chats ask this way.");
		return runtime.decide(approvalId, decision);
	}

	async respond(ref: ContainerRef, promptId: string, response: PromptResponse): Promise<void> {
		const runtime = await this.runtime(ref);
		if (!(runtime instanceof BuildRuntime)) throw new EngineError("INVALID", "Only Build sessions ask for approval.");
		runtime.respond(promptId, response);
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
			if ((entry.ref.kind === "thread" || entry.ref.kind === "build") && idle) void this.suggestFollowUps(entry, runtime);
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
				onAnswer: (contactId, said, answer, visuals) => void this.telegram?.answered(id, contactId, said, answer, visuals),
				onOutbound: (to, text) => this.telegram?.outbound(id, to, text),
				...(this.telegram ? { connectTelegram: (token: string) => this.telegram!.connect(id, token) } : {}),
				...(this.hookUrl ? { watchUrl: (watchId: string) => this.hookUrl!(id, watchId) } : {}),
				onWatches: () => void this.watchers?.sync().catch(() => undefined),
				updateSelf: (change) => this.updateAgentSelf(id, change),
			});
		}
		if (entry.ref.kind === "thread") return this.openChat(entry, model);
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
				// Linked folders that can be edited (18 §18) are written to as the project's own folder is: without asking in
				// Auto-edit and Full auto; Ask still asks, and Read only can't.
				rules: () => {
					const place = entry.projectPath ?? entry.cwd!;
					const mode = entry.approvalMode ?? this.policy.modeFor(place);
					const linked = mode === "auto_edit" || mode === "full_auto" ? (this.policy.foldersFor?.(place) ?? []).filter((f) => f.edit) : [];
					return [...this.policy.rulesFor(place), ...linked.map((f) => ({ id: `linked:${f.path}`, kind: "path" as const, pattern: `${f.path}/**`, createdAt: "" }))];
				},
				addRule: (rule) => this.policy.addRule(entry.projectPath ?? entry.cwd!, rule),
			},
			folders: () => this.policy.foldersFor?.(entry.projectPath ?? entry.cwd!) ?? [],
			checkpoints: this.checkpoints,
			webOptions: this.webOptions,
			keepImages: toolImageKeeper(attachmentsDir(this.paths.home, entry.ref.id)),
			...this.browserFor(entry.ref),
			...this.visualsFor(entry.ref),
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
			...(entry.parent || entry.helper
				? {}
				: {
						runTask: (task, signal, onStart, onProgress) => this.runTask(entry, task, signal, onStart, onProgress),
						tasks: { start: (task) => this.startTask(entry.ref, task), wait: (ids, signal) => this.waitTasks(entry.ref, ids, signal), stop: (id) => this.stopTask(entry.ref, id) },
						externalAgents: this.externalAgents(),
					}),
			// The board (docs/spec/26): Piopio's tools where parallel work is on, a reviewer's verdict.
			...(entry.helper?.kind === "review" && this.work ? { board: this.boardBridge(entry, "review") } : {}),
			// Piopio's board tools are declared each turn only while parallel work is on in the project (work/extension.ts).
			...(!entry.parent && !entry.helper && this.work && this.policy.projectFor(entry.projectPath ?? entry.cwd!) ? { board: this.boardBridge(entry, "piopio") } : {}),
			// Side conversations (docs/spec/24): your own conversations, not a helper's or a subagent's.
			...(!entry.parent && !entry.helper ? { side: this.sideBridge(entry) } : {}),
			// Your agents, from your conversations (not a helper's task or a subagent): ask_agent and @Name.
			...(!entry.parent && !entry.helper ? { consult: { bridge: this.consultBridge(), from: () => entry.title } } : {}),
			// Piopio's offers: in a project conversation with Piopio, not a helper's.
			...(!entry.parent && !entry.helper && this.policy.projectFor(entry.projectPath ?? entry.cwd!) ? { offers: { canOfferParallel: () => !!this.work && !this.work.parallelAt(entry.projectPath ?? entry.cwd!) } } : {}),
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

	// ── Chats: conversations without a project (one engine for conversations, 2026-11-15) ─────────

	/**
	 * Chats from before 2026-11-15 (pi-durable SQLite files) move to pi sessions, once, before the engine serves anything
	 * (migrate-chats.ts). The old file stays where it was until the chat is deleted. A chat that can't be read is left as
	 * it was and tried again next start.
	 */
	async migrateChats(log: (line: string) => void = () => {}): Promise<number> {
		let moved = 0;
		for (const entry of [...this.entries.values()]) {
			if (entry.ref.kind !== "thread" || !entry.file || entry.sessionFile) continue;
			const cwd = this.scratch(entry.ref.id);
			try {
				const file = await migrateChat(entry.file, entry.branches?.active, this.hub, cwd, this.paths.chatsDir);
				entry.cwd = cwd;
				entry.migratedFrom = entry.file;
				if (file) entry.sessionFile = file;
				delete entry.file;
				delete entry.branches;
				moved++;
			} catch (error) {
				log(`Couldn't move the chat “${entry.title}” (${entry.ref.id}) to the new engine: ${(error as Error).message}`);
			}
		}
		if (moved) this.save();
		return moved;
	}

	/** A chat's own folder, where its pi session runs. */
	private scratch(id: string): string {
		const dir = join(this.paths.scratchDir, id);
		mkdirSync(dir, { recursive: true, mode: 0o700 });
		return dir;
	}

	/** A chat on the pi SDK, with a chat's tools (BuildRuntime's ChatProfile); its session file is in `chatsDir`. */
	private async openChat(entry: CatalogEntry, model: ModelRef): Promise<Runtime> {
		const cwd = entry.cwd && existsSync(entry.cwd) ? entry.cwd : this.scratch(entry.ref.id);
		if (entry.cwd !== cwd) entry.cwd = cwd;
		this.aboutMeSdk ??= this.chat ? aboutMeSdkExtension(this.chat.aboutMe, this.chat.settings) : undefined;
		const runtime = await BuildRuntime.open({
			ref: entry.ref,
			hub: this.hub,
			cwd,
			model,
			...(entry.thinking ? { thinking: entry.thinking } : {}),
			...(entry.sessionFile ? { sessionFile: entry.sessionFile } : {}),
			piSessionDir: this.paths.chatsDir,
			...(this.piOverrides.piAgentDir ? { piAgentDir: this.piOverrides.piAgentDir } : {}),
			// Nothing in a chat goes through approval modes: it has no file or command tools.
			approvals: { mode: () => "full_auto", rules: () => [], addRule: () => {} },
			checkpoints: this.checkpoints,
			plan: { active: () => false, setActive: () => {} },
			webOptions: this.webOptions,
			keepImages: toolImageKeeper(attachmentsDir(this.paths.home, entry.ref.id)),
			...this.browserFor(entry.ref),
			...this.visualsFor(entry.ref),
			...(this.historyBridge(entry) ? { history: this.historyBridge(entry)! } : {}),
			// Side conversations (docs/spec/24), here or in one of your projects (SCQ5).
			side: this.sideBridge(entry),
			...(this.connectors ? { connectors: this.connectors } : {}),
			// Global MCP servers that aren't on for chats (Settings › MCP servers) are refused, as are those turned off here.
			toolsOff: () => [...(entry.toolsOff ?? []), ...(this.chat?.mcpOff() ?? []).map((name) => `mcp:${name}`)],
			chat: {
				web: () => entry.web ?? true,
				setWeb: (on) => {
					entry.web = on;
					this.save();
				},
				...(this.aboutMeSdk ? { extensions: [this.aboutMeSdk] } : {}),
			},
		});
		if (runtime.sessionFile && runtime.sessionFile !== entry.sessionFile) {
			entry.sessionFile = runtime.sessionFile;
			this.save();
		}
		return runtime;
	}

	private aboutMeSdk?: ReturnType<typeof aboutMeSdkExtension>;

	private save(): void {
		const tmp = `${this.paths.catalogIndex}.tmp`;
		writeFileSync(tmp, JSON.stringify([...this.entries.values()], null, "\t"));
		renameSync(tmp, this.paths.catalogIndex);
	}
}

function summary({ file: _f, sessionFile: _s, restoredFromSessionFile: _recovered, onDisk: _d, thinking: _t, migratedFrom: _m, sideBrief: _b, sideBy: _y, sideWoke: _w, sidePending: _p, sideOffers: _o, sideBriefs: _sb, ...rest }: CatalogEntry): SessionSummary {
	// Proposals go after a week (docs/spec/24 §3).
	if (rest.sideProposals) {
		const live = rest.sideProposals.filter((p) => Date.parse(p.expiresAt) > Date.now());
		if (live.length) rest.sideProposals = live;
		else delete rest.sideProposals;
	}
	// A chat's folder is the engine's: the app knows a chat by having no project.
	if (rest.ref.kind === "thread") delete rest.cwd;
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

