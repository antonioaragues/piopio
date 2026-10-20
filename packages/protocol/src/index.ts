/**
 * Piopio Engine Protocol (see docs/spec/03-engine-protocol.md).
 *
 * Schemas are TypeBox, so they double as JSON Schema for the Swift side.
 * Phase 0 covers the S1 subset: handshake, sessions (thread + build), timeline events and secrets.
 */
import { Type, type Static, type TLiteral, type TSchema, type TUnion } from "typebox";

/** Union of string literals that keeps its literal types. */
function literals<const T extends readonly string[]>(...values: T): TUnion<{ -readonly [K in keyof T]: TLiteral<T[K]> }> {
	return Type.Union(values.map((v) => Type.Literal(v))) as never;
}

export const PROTOCOL_VERSION = "1.0";

// ── Common ──────────────────────────────────────────────────────────────────

export const ContainerKind = literals("build", "thread", "space", "agent");
export type ContainerKind = Static<typeof ContainerKind>;

export const ContainerRef = Type.Object({ kind: ContainerKind, id: Type.String(), conversationId: Type.Optional(Type.String()) });
export type ContainerRef = Static<typeof ContainerRef>;

export const ErrorCode = literals("NOT_FOUND", "BUSY", "AUTH", "ENGINE_UNAVAILABLE", "MODEL_ERROR", "INVALID", "CONFLICT", "QUOTA", "INTERNAL");
export type ErrorCode = Static<typeof ErrorCode>;

export const Usage = Type.Object({
	inputTokens: Type.Number(),
	outputTokens: Type.Number(),
	cacheReadTokens: Type.Number(),
	cacheWriteTokens: Type.Number(),
	costUsd: Type.Number(),
});
export type Usage = Static<typeof Usage>;

export const ModelRef = Type.Object({ provider: Type.String(), id: Type.String() });
export type ModelRef = Static<typeof ModelRef>;

// ── Timeline ────────────────────────────────────────────────────────────────

export const AssistantPart = Type.Union([
	Type.Object({ type: Type.Literal("text"), text: Type.String() }),
	Type.Object({ type: Type.Literal("thinking"), text: Type.String(), redacted: Type.Optional(Type.Boolean()) }),
]);
export type AssistantPart = Static<typeof AssistantPart>;

export const ToolStatus = literals("pending_approval", "running", "done", "error", "interrupted", "denied");
export type ToolStatus = Static<typeof ToolStatus>;

export const ToolDetails = Type.Union([
	Type.Object({ type: Type.Literal("diff"), path: Type.String(), diff: Type.String() }),
	Type.Object({ type: Type.Literal("file"), path: Type.String(), language: Type.Optional(Type.String()) }),
	Type.Object({ type: Type.Literal("terminal"), command: Type.String(), exitCode: Type.Optional(Type.Number()) }),
	Type.Object({ type: Type.Literal("json"), value: Type.Unknown() }),
	/** The agent's checklist (piopio-todos). */
	Type.Object({ type: Type.Literal("todos"), items: Type.Array(Type.Object({ text: Type.String(), status: literals("pending", "in_progress", "done") })) }),
	/** A subagent (piopio-subagents): its child session, once started, and the outcome. */
	Type.Object({ type: Type.Literal("task"), sessionId: Type.Optional(Type.String()), status: Type.Optional(literals("done", "error", "stopped")), costUsd: Type.Optional(Type.Number()) }),
]);
export type ToolDetails = Static<typeof ToolDetails>;

/** Where a user message sits among alternative versions (edits/regenerations) at the same point. */
export const BranchInfo = Type.Object({
	index: Type.Number(), // 0-based position of the shown version
	count: Type.Number(),
	/** Branch ids to pass to `sessions.switchBranch` for the neighbouring versions. */
	previous: Type.Optional(Type.String()),
	next: Type.Optional(Type.String()),
});
export type BranchInfo = Static<typeof BranchInfo>;

/** A file sent with a message, as the transcript shows it. */
export const AttachmentInfo = Type.Object({ name: Type.String(), kind: literals("image", "text"), mimeType: Type.Optional(Type.String()), size: Type.Optional(Type.Number()) });
export type AttachmentInfo = Static<typeof AttachmentInfo>;

/** A file to send. Clients prepare it: images as base64 (already downscaled), documents as extracted text. */
export const Attachment = Type.Union([
	Type.Object({ kind: Type.Literal("image"), name: Type.String(), mimeType: Type.String(), data: Type.String() }),
	Type.Object({ kind: Type.Literal("text"), name: Type.String(), mimeType: Type.Optional(Type.String()), text: Type.String() }),
]);
export type Attachment = Static<typeof Attachment>;

export const UserItem = Type.Object({
	kind: Type.Literal("user"),
	id: Type.String(),
	at: Type.String(),
	text: Type.String(),
	attachments: Type.Optional(Type.Array(AttachmentInfo)),
	branch: Type.Optional(BranchInfo),
});

/** Why a model request failed, so clients can offer the right fix. */
export const ErrorKind = literals("auth", "credits", "model", "rate_limit", "provider", "network", "context", "other");
export type ErrorKind = Static<typeof ErrorKind>;
export const AssistantItem = Type.Object({
	kind: Type.Literal("assistant"),
	id: Type.String(),
	at: Type.String(),
	parts: Type.Array(AssistantPart),
	model: Type.Optional(Type.String()),
	usage: Type.Optional(Usage),
	status: literals("streaming", "done", "error", "aborted"),
	error: Type.Optional(Type.String()),
	errorKind: Type.Optional(ErrorKind),
	/** The provider's raw error, for "show details". */
	errorDetail: Type.Optional(Type.String()),
});
export const ToolItem = Type.Object({
	kind: Type.Literal("tool"),
	id: Type.String(),
	at: Type.String(),
	callId: Type.String(),
	tool: Type.String(),
	args: Type.Unknown(),
	status: ToolStatus,
	output: Type.Optional(Type.String()),
	details: Type.Optional(ToolDetails),
	durationMs: Type.Optional(Type.Number()),
	parentCallId: Type.Optional(Type.String()),
});
export const SystemItem = Type.Object({
	kind: Type.Literal("system"),
	id: Type.String(),
	at: Type.String(),
	level: literals("info", "warn", "error"),
	text: Type.String(),
});
export const CompactionItem = Type.Object({
	kind: Type.Literal("compaction"),
	id: Type.String(),
	at: Type.String(),
	summary: Type.String(),
});

/** A snapshot of the working tree before a turn changed files (Build, docs/spec/05-build §7). */
export const CheckpointItem = Type.Object({
	kind: Type.Literal("checkpoint"),
	id: Type.String(),
	at: Type.String(),
	checkpointId: Type.String(),
	/** "Session start", "Before turn 3", "Before restore". */
	label: Type.String(),
	/** Files that changed since the previous checkpoint. */
	files: Type.Optional(Type.Number()),
});

export const TimelineItem = Type.Union([UserItem, AssistantItem, ToolItem, SystemItem, CompactionItem, CheckpointItem]);
export type TimelineItem = Static<typeof TimelineItem>;
export type UserItem = Static<typeof UserItem>;
export type AssistantItem = Static<typeof AssistantItem>;
export type ToolItem = Static<typeof ToolItem>;
export type SystemItem = Static<typeof SystemItem>;
export type CheckpointItem = Static<typeof CheckpointItem>;

/** A file that differs from a checkpoint. */
export const FileChange = Type.Object({
	path: Type.String(),
	status: literals("added", "modified", "deleted"),
	added: Type.Number(),
	removed: Type.Number(),
	binary: Type.Optional(Type.Boolean()),
});
export type FileChange = Static<typeof FileChange>;

/** Compared with the session's first checkpoint, or its latest one (the last turn). */
export const ChangesSince = literals("session", "turn");

// ── Session state & events ─────────────────────────────────────────────────

export const SessionStatus = literals("idle", "running", "waiting_approval", "error");

/** Build approval modes (docs/spec/05-build §6). */
export const ApprovalMode = literals("ask", "auto_edit", "full_auto");
export type ApprovalMode = Static<typeof ApprovalMode>;

/** "Always allow" rules, per project (AP2): a bash command prefix, a tool name, or a path glob. */
export const ApprovalRule = Type.Object({ id: Type.String(), kind: literals("command", "tool", "path"), pattern: Type.String(), createdAt: Type.String() });
export type ApprovalRule = Static<typeof ApprovalRule>;

/**
 * Something the session waits on you for: a tool approval, an agent's question (`ask_user`), or an
 * extension's confirm/select/input. Lives in the session state until answered, so it survives reconnects.
 */
export const PendingPrompt = Type.Object({
	id: Type.String(),
	kind: literals("approval", "question", "confirm", "select", "input", "plan"),
	title: Type.String(),
	message: Type.Optional(Type.String()),
	/** Monospace detail: the command, or the path. */
	detail: Type.Optional(Type.String()),
	/** Approvals: the tool and its call (the tool card shows "waiting for approval"). */
	tool: Type.Optional(Type.String()),
	callId: Type.Optional(Type.String()),
	/** Why it asks even though the mode would allow it (deny-list, outside the project). */
	reason: Type.Optional(Type.String()),
	/** Approvals: the rule "Always allow" would add; absent when it can't be made a rule (deny-list). */
	rule: Type.Optional(Type.Object({ kind: literals("command", "tool", "path"), pattern: Type.String() })),
	/** Questions and selects: the choices offered. */
	options: Type.Optional(Type.Array(Type.String())),
	placeholder: Type.Optional(Type.String()),
	/** Plans (propose_plan): the steps. Approve = decision "allow"; keep planning = "deny" with a note. */
	steps: Type.Optional(Type.Array(Type.String())),
	at: Type.String(),
});
export type PendingPrompt = Static<typeof PendingPrompt>;

export const PromptResponse = Type.Object({
	/** Approvals. "always" also adds the prompt's rule. */
	decision: Type.Optional(literals("allow", "always", "deny")),
	/** Deny: a note for the agent. Questions/inputs: the answer. */
	text: Type.Optional(Type.String()),
	/** Selects and questions with options: the chosen option. */
	choice: Type.Optional(Type.String()),
	/** Confirms. */
	confirmed: Type.Optional(Type.Boolean()),
});
export type PromptResponse = Static<typeof PromptResponse>;
export type SessionStatus = Static<typeof SessionStatus>;

export const QueuedInput = Type.Object({ id: Type.String(), mode: Type.Union([Type.Literal("steer"), Type.Literal("followUp")]), text: Type.Optional(Type.String()) });
export type QueuedInput = Static<typeof QueuedInput>;

export const SessionState = Type.Object({
	status: SessionStatus,
	queue: Type.Array(QueuedInput),
	model: Type.Optional(ModelRef),
	thinking: Type.Optional(Type.String()),
	/** Optional tool sets enabled for this session. */
	tools: Type.Optional(Type.Object({ web: Type.Boolean() })),
	usage: Usage,
	/** Build: approval mode and what the session is waiting on you for. */
	approvalMode: Type.Optional(ApprovalMode),
	prompts: Type.Optional(Type.Array(PendingPrompt)),
	/** Build: the agent's current checklist, and whether plan mode is on. */
	todos: Type.Optional(Type.Array(Type.Object({ text: Type.String(), status: literals("pending", "in_progress", "done") }))),
	planMode: Type.Optional(Type.Boolean()),
	/** How full the model's context is (Build). `tokens` is null right after a compaction. */
	context: Type.Optional(Type.Object({ tokens: Type.Union([Type.Number(), Type.Null()]), window: Type.Number() })),
});
export type SessionState = Static<typeof SessionState>;

export const Snapshot = Type.Object({ ref: ContainerRef, items: Type.Array(TimelineItem), state: SessionState });
export type Snapshot = Static<typeof Snapshot>;

export const SessionEvent = Type.Union([
	/** Appended, or inserted before the item `before` when set (checkpoints go before the change they precede). */
	Type.Object({ type: Type.Literal("item.added"), item: TimelineItem, before: Type.Optional(Type.String()) }),
	Type.Object({ type: Type.Literal("item.delta"), itemId: Type.String(), partIndex: Type.Number(), partType: Type.Union([Type.Literal("text"), Type.Literal("thinking")]), textDelta: Type.String() }),
	Type.Object({ type: Type.Literal("item.updated"), item: TimelineItem }),
	Type.Object({ type: Type.Literal("item.removed"), itemId: Type.String() }),
	/** A provisional item (e.g. a streaming answer) got its durable id. Same position. */
	Type.Object({ type: Type.Literal("item.replaced"), oldId: Type.String(), item: TimelineItem }),
	Type.Object({ type: Type.Literal("state"), state: SessionState }),
	Type.Object({ type: Type.Literal("resnapshot"), snapshot: Snapshot }),
]);
export type SessionEvent = Static<typeof SessionEvent>;

export const SessionEventsNotification = Type.Object({ subscriptionId: Type.String(), seq: Type.Number(), events: Type.Array(SessionEvent) });
export type SessionEventsNotification = Static<typeof SessionEventsNotification>;

/** A Build session in its own worktree (docs/spec/05-build BP5). */
export const WorktreeInfo = Type.Object({
	branch: Type.String(),
	base: Type.String(),
	/** Set once finished: merged into base, or discarded. The session then continues in the project folder. */
	finished: Type.Optional(literals("merged", "discarded")),
});
export type WorktreeInfo = Static<typeof WorktreeInfo>;

export const SessionSummary = Type.Object({
	ref: ContainerRef,
	title: Type.String(),
	createdAt: Type.String(),
	updatedAt: Type.String(),
	cwd: Type.Optional(Type.String()),
	model: Type.Optional(ModelRef),
	/** Build: the project folder (differs from `cwd` for worktree sessions). */
	projectPath: Type.Optional(Type.String()),
	worktree: Type.Optional(WorktreeInfo),
	/** Project sessions: the profile they were created with (04-chat P2). */
	profile: Type.Optional(literals("build", "chat")),
	/** A subagent's session: the parent session and the `task` call that started it. */
	parent: Type.Optional(Type.Object({ id: Type.String(), callId: Type.String() })),
});
export type SessionSummary = Static<typeof SessionSummary>;

export const ModelInfo = Type.Object({
	provider: Type.String(),
	id: Type.String(),
	name: Type.String(),
	contextWindow: Type.Number(),
	maxOutputTokens: Type.Number(),
	/** USD per million tokens. */
	pricing: Type.Object({ input: Type.Number(), output: Type.Number(), cacheRead: Type.Number(), cacheWrite: Type.Number() }),
	supports: Type.Object({ vision: Type.Boolean(), reasoning: Type.Boolean() }),
});
export type ModelInfo = Static<typeof ModelInfo>;

/** A folder added in Build (docs/spec/05-build BP1). */
export const ProjectInfo = Type.Object({
	id: Type.String(),
	path: Type.String(),
	name: Type.String(),
	addedAt: Type.String(),
	/** Current git branch; absent outside a git repo. */
	branch: Type.Optional(Type.String()),
	/** AGENTS.md or CLAUDE.md, when present. */
	contextFile: Type.Optional(Type.String()),
	/** The folder has a pi project config (`.pi/`). */
	piConfig: Type.Boolean(),
	/** Approval mode new sessions start with (default: auto_edit). */
	approvalMode: ApprovalMode,
	rules: Type.Array(ApprovalRule),
	/**
	 * pi project trust (shared with the pi CLI, ~/.pi/agent/trust.json): whether the project's own .pi
	 * extensions, MCP servers, settings, prompts and skills load. `needsTrust`: the project has such resources.
	 */
	trust: literals("trusted", "untrusted", "undecided"),
	needsTrust: Type.Boolean(),
	/** Where the project shows (04-chat P1): Build, Chat, or both. Detected when added; "Show in…" changes it. */
	lenses: Type.Array(literals("build", "chat")),
	/** The folder no longer exists. */
	missing: Type.Optional(Type.Boolean()),
});
export type ProjectInfo = Static<typeof ProjectInfo>;

export const ProjectsChanged = Type.Object({ projects: Type.Array(ProjectInfo) });
export type ProjectsChanged = Static<typeof ProjectsChanged>;

/** An MCP server as configured in a pi mcp.json (docs: pi-coding-agent docs/mcp.md). */
export const McpServerInfo = Type.Object({
	name: Type.String(),
	scope: literals("global", "project"),
	transport: literals("stdio", "http"),
	command: Type.Optional(Type.String()),
	args: Type.Optional(Type.Array(Type.String())),
	url: Type.Optional(Type.String()),
	enabled: Type.Boolean(),
	description: Type.Optional(Type.String()),
	/** A project entry that only overrides a global server's `enabled`/exposure. */
	override: Type.Optional(Type.Boolean()),
});
export type McpServerInfo = Static<typeof McpServerInfo>;

// ── Git (Build, docs/spec/05-build §8 G1–G3) ──────────────────────────────

export const GitFile = Type.Object({
	path: Type.String(),
	status: literals("added", "modified", "deleted", "renamed", "conflicted", "untracked"),
	staged: Type.Boolean(),
	from: Type.Optional(Type.String()),
});
export type GitFile = Static<typeof GitFile>;

export const GitStatus = Type.Object({
	repo: Type.Boolean(),
	branch: Type.Optional(Type.String()),
	detached: Type.Optional(Type.Boolean()),
	upstream: Type.Optional(Type.String()),
	ahead: Type.Number(),
	behind: Type.Number(),
	files: Type.Array(GitFile),
});
export type GitStatus = Static<typeof GitStatus>;

export const GitBranch = Type.Object({ name: Type.String(), upstream: Type.Optional(Type.String()), lastCommitAt: Type.Optional(Type.String()), current: Type.Boolean() });
export type GitBranch = Static<typeof GitBranch>;

/** Where a new Build session works: the project as it is, a new branch in it, or a new worktree. */
export const WorkOn = Type.Union([
	Type.Object({ kind: Type.Literal("current") }),
	Type.Object({ kind: Type.Literal("branch"), branch: Type.String(), base: Type.Optional(Type.String()) }),
	Type.Object({ kind: Type.Literal("worktree"), branch: Type.String(), base: Type.Optional(Type.String()) }),
]);
export type WorkOn = Static<typeof WorkOn>;

export const CatalogChanged = Type.Object({ upserted: Type.Array(SessionSummary), removed: Type.Array(ContainerRef) });
export type CatalogChanged = Static<typeof CatalogChanged>;

// ── Methods (client → engine) ───────────────────────────────────────────────

export const EngineCapabilities = Type.Object({ runtimes: Type.Array(ContainerKind), models: Type.Array(Type.String()) });

export const methods = {
	"engine.hello": {
		params: Type.Object({ token: Type.String(), client: Type.String(), protocolVersion: Type.String() }),
		result: Type.Object({ engineId: Type.String(), kind: Type.Union([Type.Literal("local"), Type.Literal("cloud")]), version: Type.String(), protocolVersion: Type.String(), capabilities: EngineCapabilities }),
	},
	"engine.status": {
		params: Type.Object({}),
		result: Type.Object({ uptimeMs: Type.Number(), openSessions: Type.Number(), subscriptions: Type.Number(), runtime: Type.String(), memoryMB: Type.Number(), dataPath: Type.String() }),
	},
	"sessions.list": {
		params: Type.Object({ kind: Type.Optional(ContainerKind) }),
		result: Type.Object({ sessions: Type.Array(SessionSummary) }),
	},
	"sessions.create": {
		params: Type.Object({
			kind: Type.Union([Type.Literal("thread"), Type.Literal("build")]),
			cwd: Type.Optional(Type.String()),
			/** Build: branch or worktree to work on (default: the project as it is). */
			workOn: Type.Optional(WorkOn),
			/** Project sessions: "build" (coding tools) or "chat" (knowledge assistant: no bash, web tools). */
			profile: Type.Optional(literals("build", "chat")),
			approvalMode: Type.Optional(ApprovalMode),
			model: Type.Optional(ModelRef),
			thinking: Type.Optional(Type.String()),
			title: Type.Optional(Type.String()),
		}),
		result: Type.Object({ ref: ContainerRef }),
	},
	"sessions.open": {
		params: Type.Object({ ref: ContainerRef }),
		result: Snapshot,
	},
	"sessions.subscribe": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({ subscriptionId: Type.String(), snapshot: Snapshot }),
	},
	"sessions.unsubscribe": {
		params: Type.Object({ subscriptionId: Type.String() }),
		result: Type.Object({}),
	},
	"sessions.submit": {
		params: Type.Object({
			ref: ContainerRef,
			input: Type.Object({ text: Type.String(), attachments: Type.Optional(Type.Array(Attachment)) }),
			whenBusy: Type.Optional(Type.Union([Type.Literal("followUp"), Type.Literal("steer"), Type.Literal("reject")])),
			clientRequestId: Type.Optional(Type.String()),
		}),
		result: Type.Object({ accepted: Type.Boolean(), disposition: Type.Union([Type.Literal("started"), Type.Literal("queued")]) }),
	},
	"sessions.abort": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({}),
	},
	/** Re-asks from a user message with new text, as a new branch (threads). */
	"sessions.edit": {
		params: Type.Object({ ref: ContainerRef, itemId: Type.String(), text: Type.String() }),
		result: Type.Object({}),
	},
	/** Asks again for a new answer: `itemId` is the answer, or the user message whose answer failed. */
	"sessions.regenerate": {
		params: Type.Object({ ref: ContainerRef, itemId: Type.String() }),
		result: Type.Object({}),
	},
	"sessions.switchBranch": {
		params: Type.Object({ ref: ContainerRef, branch: Type.String() }),
		result: Type.Object({}),
	},
	/** Copies the conversation up to and including `itemId` into a new session of the same kind. */
	"sessions.fork": {
		params: Type.Object({ ref: ContainerRef, itemId: Type.String() }),
		result: Type.Object({ ref: ContainerRef }),
	},
	/** Withdraws one queued input. */
	"sessions.queue.remove": {
		params: Type.Object({ ref: ContainerRef, queueId: Type.String() }),
		result: Type.Object({}),
	},
	"sessions.queue.clear": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({}),
	},
	"sessions.export": {
		params: Type.Object({ ref: ContainerRef, format: literals("markdown", "html", "jsonl") }),
		result: Type.Object({ filename: Type.String(), mimeType: Type.String(), content: Type.String() }),
	},
	"sessions.configure": {
		params: Type.Object({ ref: ContainerRef, model: Type.Optional(ModelRef), thinking: Type.Optional(Type.String()), web: Type.Optional(Type.Boolean()), approvalMode: Type.Optional(ApprovalMode), planMode: Type.Optional(Type.Boolean()) }),
		result: Type.Object({}),
	},
	"sessions.rename": {
		params: Type.Object({ ref: ContainerRef, title: Type.String() }),
		result: Type.Object({}),
	},
	/** Threads: deletes the history. Build sessions: moves the pi session file to the Trash. */
	"sessions.delete": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({}),
	},
	/** Full-text search over session titles and messages (active branches). Snippets mark matches with \u0002…\u0003. */
	"catalog.search": {
		params: Type.Object({ query: Type.String(), limit: Type.Optional(Type.Number()) }),
		result: Type.Object({
			results: Type.Array(Type.Object({ ref: ContainerRef, title: Type.String(), itemId: Type.Optional(Type.String()), kind: literals("title", "user", "assistant"), snippet: Type.String(), at: Type.String() })),
		}),
	},
	/** Checks a provider key without saving it (welcome, settings). */
	"models.verifyKey": {
		params: Type.Object({ provider: Type.String(), key: Type.String() }),
		result: Type.Object({ ok: Type.Boolean(), message: Type.Optional(Type.String()), label: Type.Optional(Type.String()), usageUsd: Type.Optional(Type.Number()), limitUsd: Type.Optional(Type.Union([Type.Number(), Type.Null()])) }),
	},
	"models.list": {
		params: Type.Object({ refresh: Type.Optional(Type.Boolean()) }),
		result: Type.Object({ models: Type.Array(ModelInfo), defaultModel: ModelRef }),
	},
	"projects.list": {
		params: Type.Object({}),
		result: Type.Object({ projects: Type.Array(ProjectInfo) }),
	},
	/** Adds a folder (idempotent by real path) and imports its pi sessions. `lens`: also show it there. */
	"projects.add": {
		params: Type.Object({ path: Type.String(), lens: Type.Optional(literals("build", "chat")) }),
		result: Type.Object({ project: ProjectInfo }),
	},
	/** Default approval mode for the project's new sessions, and rule removal. */
	"projects.configure": {
		params: Type.Object({
			id: Type.String(),
			approvalMode: Type.Optional(ApprovalMode),
			removeRule: Type.Optional(Type.String()),
			trust: Type.Optional(Type.Union([Type.Boolean(), Type.Null()])),
			lenses: Type.Optional(Type.Array(literals("build", "chat"))),
		}),
		result: Type.Object({ project: ProjectInfo }),
	},
	/** Build: files that differ from the session's first checkpoint (or the latest), with line counts. */
	"sessions.changes": {
		params: Type.Object({ ref: ContainerRef, since: ChangesSince }),
		result: Type.Object({ base: Type.Optional(Type.String()), files: Type.Array(FileChange) }),
	},
	/** Build: unified diff of one file since a checkpoint. */
	"sessions.diff": {
		params: Type.Object({ ref: ContainerRef, path: Type.String(), since: ChangesSince }),
		result: Type.Object({ patch: Type.String() }),
	},
	/**
	 * Build: puts files back as they were at a checkpoint (all, or `paths`). `dryRun` lists what would change.
	 * A real restore first checkpoints the current state, then tells the agent what changed.
	 */
	"sessions.restore": {
		params: Type.Object({ ref: ContainerRef, checkpointId: Type.String(), paths: Type.Optional(Type.Array(Type.String())), dryRun: Type.Optional(Type.Boolean()) }),
		result: Type.Object({ files: Type.Array(FileChange) }),
	},
	/** Build, worktree sessions: merge the branch into its base (then remove the worktree), or discard both. */
	"sessions.finish": {
		params: Type.Object({ ref: ContainerRef, action: literals("merge", "discard") }),
		result: Type.Object({}),
	},
	/** Git in a project folder or a session's worktree (`cwd`). */
	"git.status": { params: Type.Object({ cwd: Type.String() }), result: GitStatus },
	"git.branches": { params: Type.Object({ cwd: Type.String() }), result: Type.Object({ branches: Type.Array(GitBranch) }) },
	"git.checkout": { params: Type.Object({ cwd: Type.String(), branch: Type.String(), create: Type.Optional(Type.Boolean()), base: Type.Optional(Type.String()) }), result: Type.Object({}) },
	/** Commits `paths` (default: every change), new and deleted files included. */
	"git.commit": {
		params: Type.Object({ cwd: Type.String(), message: Type.String(), paths: Type.Optional(Type.Array(Type.String())), amend: Type.Optional(Type.Boolean()) }),
		result: Type.Object({ commit: Type.String() }),
	},
	/** A commit message for `paths`, written by the utility model from the diff. */
	"git.message": { params: Type.Object({ cwd: Type.String(), paths: Type.Optional(Type.Array(Type.String())) }), result: Type.Object({ message: Type.String() }) },
	"git.sync": { params: Type.Object({ cwd: Type.String(), action: literals("push", "pull", "fetch") }), result: Type.Object({ output: Type.String() }) },
	/** A branch name for a new session, from its prompt. */
	"git.suggestBranch": { params: Type.Object({ prompt: Type.String() }), result: Type.Object({ branch: Type.String() }) },
	/** Build: what `/` offers besides Piopio's own commands: pi prompt templates, skills and extension commands. */
	"sessions.commands": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({ commands: Type.Array(Type.Object({ name: Type.String(), description: Type.String(), kind: literals("template", "skill", "extension"), hint: Type.Optional(Type.String()) })) }),
	},
	/** Build: pi's session tree, as your messages (BR6). `depth` grows at each branch point; `current` = on the active path. */
	"sessions.tree": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({ nodes: Type.Array(Type.Object({ entryId: Type.String(), text: Type.String(), at: Type.String(), depth: Type.Number(), current: Type.Boolean(), branches: Type.Number() })) }),
	},
	/** Build: moves to another point of the tree. Going to one of your messages returns its text for the composer. */
	"sessions.navigate": {
		params: Type.Object({ ref: ContainerRef, entryId: Type.String() }),
		result: Type.Object({ editorText: Type.Optional(Type.String()) }),
	},
	/** Build: summarizes older messages to free context. */
	"sessions.compact": { params: Type.Object({ ref: ContainerRef }), result: Type.Object({}) },
	/** Files and folders for @-mentions: fuzzy match on the path, .gitignore respected. */
	"projects.files": {
		params: Type.Object({ cwd: Type.String(), query: Type.String(), limit: Type.Optional(Type.Number()) }),
		result: Type.Object({ files: Type.Array(Type.Object({ path: Type.String(), kind: literals("file", "folder") })) }),
	},
	/** File browser (04-chat P3): the entries of a folder of the project (.gitignore respected in git repositories). */
	"projects.listDir": {
		params: Type.Object({ cwd: Type.String(), dir: Type.String() }),
		result: Type.Object({ entries: Type.Array(Type.Object({ name: Type.String(), path: Type.String(), kind: literals("file", "folder") })) }),
	},
	/** File viewer (BR4): a file of a project or worktree. Text only; large files are cut. */
	"projects.readFile": {
		params: Type.Object({ cwd: Type.String(), path: Type.String() }),
		result: Type.Object({ content: Type.String(), size: Type.Number(), truncated: Type.Boolean(), binary: Type.Boolean() }),
	},
	/** File viewer quick edit (BR4). */
	"projects.writeFile": { params: Type.Object({ cwd: Type.String(), path: Type.String(), content: Type.String() }), result: Type.Object({}) },
	/** MCP servers from pi's mcp.json files: global (~/.pi/agent/mcp.json), and the project's (.pi/mcp.json) when `cwd` is given. */
	"mcp.list": {
		params: Type.Object({ cwd: Type.Optional(Type.String()) }),
		result: Type.Object({ servers: Type.Array(McpServerInfo), errors: Type.Array(Type.String()) }),
	},
	"mcp.add": {
		params: Type.Object({
			scope: literals("global", "project"),
			cwd: Type.Optional(Type.String()),
			name: Type.String(),
			command: Type.Optional(Type.String()),
			args: Type.Optional(Type.Array(Type.String())),
			url: Type.Optional(Type.String()),
			env: Type.Optional(Type.Record(Type.String(), Type.String())),
			description: Type.Optional(Type.String()),
		}),
		result: Type.Object({}),
	},
	"mcp.remove": { params: Type.Object({ scope: literals("global", "project"), cwd: Type.Optional(Type.String()), name: Type.String() }), result: Type.Object({}) },
	"mcp.setEnabled": {
		params: Type.Object({ scope: literals("global", "project"), cwd: Type.Optional(Type.String()), name: Type.String(), enabled: Type.Boolean() }),
		result: Type.Object({}),
	},
	/** Answers a pending prompt (approval, question, confirm, select, input). */
	"sessions.respond": {
		params: Type.Object({ ref: ContainerRef, promptId: Type.String(), response: PromptResponse }),
		result: Type.Object({}),
	},
	/** Forgets a project. Its session files stay where pi keeps them. */
	"projects.remove": {
		params: Type.Object({ id: Type.String() }),
		result: Type.Object({}),
	},
	/** The client changed a secret (e.g. a new API key): drop cached copies. */
	"secrets.changed": {
		params: Type.Object({ name: Type.String() }),
		result: Type.Object({}),
	},
} satisfies Record<string, { params: TSchema; result: TSchema }>;

export type MethodName = keyof typeof methods;
export type Params<M extends MethodName> = Static<(typeof methods)[M]["params"]>;
export type Result<M extends MethodName> = Static<(typeof methods)[M]["result"]>;

// ── Reverse requests (engine → client) ──────────────────────────────────────

export const reverseMethods = {
	"secrets.get": {
		params: Type.Object({ name: Type.String(), purpose: Type.String() }),
		result: Type.Object({ value: Type.Union([Type.String(), Type.Null()]) }),
	},
} satisfies Record<string, { params: TSchema; result: TSchema }>;

export type ReverseMethodName = keyof typeof reverseMethods;
export type ReverseParams<M extends ReverseMethodName> = Static<(typeof reverseMethods)[M]["params"]>;
export type ReverseResult<M extends ReverseMethodName> = Static<(typeof reverseMethods)[M]["result"]>;

// ── Notifications (engine → client) ─────────────────────────────────────────

export const notifications = {
	"session.events": SessionEventsNotification,
	"catalog.changed": CatalogChanged,
	"projects.changed": ProjectsChanged,
	/** A session needs you (it's waiting on a prompt) or told you something (notify_user). Sent to every client. */
	"session.attention": Type.Object({ ref: ContainerRef, title: Type.String(), kind: literals("waiting", "notify"), message: Type.String() }),
} satisfies Record<string, TSchema>;

// ── JSON-RPC envelope ───────────────────────────────────────────────────────

export type JsonRpcId = string | number;
export type JsonRpcRequest = { jsonrpc: "2.0"; id: JsonRpcId; method: string; params?: unknown };
export type JsonRpcNotification = { jsonrpc: "2.0"; method: string; params?: unknown };
export type JsonRpcResponse =
	| { jsonrpc: "2.0"; id: JsonRpcId; result: unknown }
	| { jsonrpc: "2.0"; id: JsonRpcId; error: { code: number; message: string; data?: { code: ErrorCode } } };
export type JsonRpcMessage = JsonRpcRequest | JsonRpcNotification | JsonRpcResponse;

/** Secret names the engine may request. */
export const SECRET_OPENROUTER = "provider.openrouter.apiKey";
