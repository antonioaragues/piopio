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
	/** A proposed plan (piopio-plan): what it says, and how you answered (approved, with your edits, or sent back). */
	Type.Object({
		type: Type.Literal("plan"),
		summary: Type.String(),
		steps: Type.Array(Type.String()),
		files: Type.Optional(Type.Array(Type.String())),
		risks: Type.Optional(Type.Array(Type.String())),
		outcome: Type.Optional(literals("approved", "changes", "unanswered")),
		edited: Type.Optional(Type.Boolean()),
		note: Type.Optional(Type.String()),
	}),
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
	/** A Space topic: typed in the topic itself, not routed from Main (04-chat S4). */
	direct: Type.Optional(Type.Boolean()),
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
	/** An agent's message sent on its own (send_message), and where from: a run id or a person's conversation. */
	outbound: Type.Optional(Type.Object({ from: Type.String() })),
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

/** A Space's Main: where the organizer sent a message (04-chat §3.4). The reply lives in the topic. */
export const RoutingItem = Type.Object({
	kind: Type.Literal("routing"),
	id: Type.String(),
	at: Type.String(),
	decision: literals("route", "create"),
	/** The topic's conversation id. */
	topicId: Type.String(),
	topicTitle: Type.String(),
	reason: Type.String(),
	/** The message as the topic got it. */
	message: Type.String(),
	/** Live: the topic is working on it, writing, answered, asked you something, or failed. */
	status: literals("thinking", "replying", "replied", "needs_you", "failed"),
	/** One line of the reply. */
	preview: Type.Optional(Type.String()),
	/** The reply's item in the topic, for Open. */
	replyItemId: Type.Optional(Type.String()),
	/** You chose the topic (@topic, /new) instead of the organizer. */
	forced: Type.Optional(Type.Boolean()),
	/** Moved here with Wrong topic: the topic it was first sent to. */
	movedFrom: Type.Optional(Type.String()),
});
export type RoutingItem = Static<typeof RoutingItem>;

/** A change to a Space's memory: saved by the organizer (Undo), or proposed by a topic (Save, Dismiss). 04-chat S8. */
export const MemoryItem = Type.Object({
	kind: Type.Literal("memory"),
	id: Type.String(),
	at: Type.String(),
	action: literals("saved", "proposed"),
	added: Type.Array(Type.String()),
	removed: Type.Array(Type.String()),
	reason: Type.Optional(Type.String()),
	status: literals("saved", "undone", "pending", "dismissed", "failed"),
	revisionId: Type.Optional(Type.String()),
	proposalId: Type.Optional(Type.String()),
});
export type MemoryItem = Static<typeof MemoryItem>;

/** A turn's tool calls as one line, "Worked 18s · 2 steps" (06-agents §12 UI2): agents' conversations. */
export const StepsItem = Type.Object({
	kind: Type.Literal("steps"),
	id: Type.String(),
	at: Type.String(),
	tools: Type.Array(ToolItem),
});

/** An agent's tool call waiting for the owner (06-agents §9 AS1), or how it was answered. */
export const ApprovalItem = Type.Object({
	kind: Type.Literal("approval"),
	id: Type.String(),
	at: Type.String(),
	approvalId: Type.String(),
	tool: Type.String(),
	/** "Send to María: “…”". */
	title: Type.String(),
	args: Type.Unknown(),
	status: literals("pending", "approved", "denied", "expired", "cancelled"),
	editedArgs: Type.Optional(Type.Unknown()),
	reason: Type.Optional(Type.String()),
	expiresAt: Type.String(),
	/** What "Always allow" would allow, in words. */
	always: Type.String(),
	/** "connector": a connected app's change in a chat (Allow / Deny, no editing; `sessions.decide`). Else an agent's. */
	source: Type.Optional(Type.Literal("connector")),
});
/** What an agent's tool changed, with Undo while it can be undone (06-agents §4.2 RC1–RC2). */
export const ResultItem = Type.Object({
	kind: Type.Literal("result"),
	id: Type.String(),
	at: Type.String(),
	callId: Type.String(),
	card: Type.Object({ kind: literals("reminder", "message", "memory", "event", "contact", "note", "music", "shortcut"), title: Type.String(), detail: Type.Optional(Type.String()) }),
	undo: Type.Optional(Type.Object({ id: Type.String(), status: literals("available", "undone", "failed", "expired"), until: Type.String() })),
});
/** A message between two of the owner's agents (06-agents §7 AA5): sent (`out`, with the answer once it comes) or received (`in`). */
export const AgentMsgItem = Type.Object({
	kind: Type.Literal("agent_msg"),
	id: Type.String(),
	at: Type.String(),
	fromAgent: Type.Object({ id: Type.String(), name: Type.String() }),
	toAgent: Type.Object({ id: Type.String(), name: Type.String() }),
	text: Type.String(),
	direction: literals("in", "out"),
	mode: literals("ask", "tell", "reply"),
	status: Type.Optional(literals("waiting", "replied", "no_reply", "sent", "failed")),
	reply: Type.Optional(Type.String()),
	/** Opens the trace view (`agents.trace`). */
	traceId: Type.Optional(Type.String()),
});
export const TimelineItem = Type.Union([UserItem, AssistantItem, ToolItem, SystemItem, CompactionItem, CheckpointItem, RoutingItem, MemoryItem, StepsItem, ApprovalItem, ResultItem, AgentMsgItem]);
export type TimelineItem = Static<typeof TimelineItem>;
export type UserItem = Static<typeof UserItem>;
export type AssistantItem = Static<typeof AssistantItem>;
export type ApprovalItem = Static<typeof ApprovalItem>;
export type ResultItem = Static<typeof ResultItem>;
export type AgentMsgItem = Static<typeof AgentMsgItem>;
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
	/** Plans: the user's edited version, approved with decision "allow". */
	summary: Type.Optional(Type.String()),
	steps: Type.Optional(Type.Array(Type.String())),
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

/** A Space topic, for the sidebar (04-chat S6). */
export const TopicInfo = Type.Object({
	/** The topic's conversation id (`ContainerRef.conversationId`). */
	id: Type.String(),
	title: Type.String(),
	brief: Type.Optional(Type.String()),
	/** Where it stands, in a line (refreshed after each reply). */
	summary: Type.Optional(Type.String()),
	lastActiveAt: Type.String(),
	archived: Type.Optional(Type.Boolean()),
	/** A reply arrived since you last looked. */
	unread: Type.Optional(Type.Boolean()),
	running: Type.Optional(Type.Boolean()),
});
export type TopicInfo = Static<typeof TopicInfo>;

export const SpaceInfo = Type.Object({
	costUsd: Type.Number(),
	files: Type.Number(),
	memoryLines: Type.Number(),
	organizerModel: Type.Optional(ModelRef),
	memory: Type.Boolean(),
	autoTidy: Type.Boolean(),
});
export type SpaceInfo = Static<typeof SpaceInfo>;

/** One operation of an MCP memory provider: the tool, and its arguments with {placeholders} (07-shared §6.2 MM1). */
export const McpMemoryMapping = Type.Object({ tool: Type.String(), args: Type.Record(Type.String(), Type.Unknown()) });
/** A memory system reached through its MCP server: a server from mcp.json, or a URL. */
export const McpMemoryProvider = Type.Object({
	id: Type.String(),
	name: Type.String(),
	server: Type.Optional(Type.String()),
	url: Type.Optional(Type.String()),
	tools: Type.Object({
		recall: McpMemoryMapping,
		retain: Type.Optional(McpMemoryMapping),
		list: Type.Optional(McpMemoryMapping),
		forget: Type.Optional(McpMemoryMapping),
		reflect: Type.Optional(McpMemoryMapping),
	}),
});
export type McpMemoryProvider = Static<typeof McpMemoryProvider>;

/** Engine-wide settings (07-shared §5, §7). */
export const EngineSettings = Type.Object({
	chat: Type.Object({
		/** Before per-server choices: every global server that's on is used in chats too. */
		mcp: Type.Boolean(),
		/** The global MCP servers chats and notebooks use (Settings › MCP servers, per server). Absent: `mcp` decides. */
		mcpServers: Type.Optional(Type.Array(Type.String())),
		/** Suggest moving a thread into a Space (04-chat S11). */
		suggestSpaces: Type.Boolean(),
		/** After an answer, suggest a few next messages (docs/design v2 "You could also"). */
		followUps: Type.Optional(Type.Boolean()),
	}),
	aboutMe: Type.Object({
		/** Shown to the agents. */
		enabled: Type.Boolean(),
		/** The agents may add facts (`remember_about_me`). */
		capture: Type.Boolean(),
		inThreads: Type.Boolean(),
		inSpaces: Type.Boolean(),
		/** Where About me lives: "builtin", or an MCP memory provider's id. */
		provider: Type.String(),
	}),
	memory: Type.Object({
		/** MCP memory providers (07-shared §6.2). */
		providers: Type.Array(McpMemoryProvider),
	}),
});
export type EngineSettings = Static<typeof EngineSettings>;

/** A pi package (07-shared §6.1): what it brings, and what of it is on. */
export const PiPackage = Type.Object({
	source: Type.String(),
	installedPath: Type.Optional(Type.String()),
	installed: Type.Boolean(),
	/** Some of it is on. */
	enabled: Type.Boolean(),
	/** Kinds of resources turned off. */
	off: Type.Array(literals("extensions", "skills", "prompts", "themes")),
	resources: Type.Object({
		extensions: Type.Array(Type.Object({ path: Type.String(), enabled: Type.Boolean() })),
		skills: Type.Array(Type.Object({ path: Type.String(), enabled: Type.Boolean() })),
		prompts: Type.Array(Type.Object({ path: Type.String(), enabled: Type.Boolean() })),
		themes: Type.Array(Type.Object({ path: Type.String(), enabled: Type.Boolean() })),
	}),
});
export type PiPackage = Static<typeof PiPackage>;

/** An agent in the catalog (06-agents §12): enough for the sidebar and the header. */
export const AgentInfo = Type.Object({
	slug: Type.String(),
	avatar: Type.Optional(Type.String()),
	description: Type.Optional(Type.String()),
	folder: Type.String(),
	location: literals("local", "cloud"),
	model: Type.String(),
	contacts: Type.Array(Type.Object({ id: Type.String(), name: Type.String(), role: literals("owner", "contact") })),
	/** The definition on disk doesn't validate (the agent keeps running its last good version). */
	invalid: Type.Optional(Type.Boolean()),
	/** Some tool calls wait for the owner (`policies.requireApproval`): the header's "Asks first". */
	asksFirst: Type.Optional(Type.Boolean()),
	/** While the engine runs it: paused (AS4), this month's spend against the budget (AS3), Inbox items waiting. */
	status: Type.Optional(Type.Object({ paused: Type.Boolean(), spendUsd: Type.Number(), budgetUsd: Type.Optional(Type.Number()), inbox: Type.Number(), nextRun: Type.Optional(Type.String()) })),
});
export type AgentInfo = Static<typeof AgentInfo>;

export const DefinitionError = Type.Object({ path: Type.String(), message: Type.String() });

/** Where a thread seems to belong (04-chat S11). */
export const SpaceSuggestion = Type.Object({
	spaceId: Type.String(),
	spaceTitle: Type.String(),
	topicId: Type.Optional(Type.String()),
	topicTitle: Type.Optional(Type.String()),
	reason: Type.String(),
});
export type SpaceSuggestion = Static<typeof SpaceSuggestion>;

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
	/** Spaces: the topics, newest activity first (Main is the Space itself). */
	topics: Type.Optional(Type.Array(TopicInfo)),
	/** Spaces: what every agent in the Space is told. */
	instructions: Type.Optional(Type.String()),
	/** Spaces: the header's numbers and the settings (04-chat S7, §3.6). */
	space: Type.Optional(SpaceInfo),
	/** Threads: a Space it seems to belong in (S11), until moved or dismissed. */
	suggestion: Type.Optional(SpaceSuggestion),
	/** Agents. Refs to a person's conversation carry `conversationId: "person:<contactId>"`. */
	agent: Type.Optional(AgentInfo),
	/** Threads and sessions: next messages the utility model suggests after the latest answer (until you write). */
	followUps: Type.Optional(Type.Array(Type.String())),
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
	/** The provider's display name ("OpenAI", "OpenAI API", "OpenRouter"). */
	providerName: Type.Optional(Type.String()),
	/** Who bills for it: "ChatGPT subscription", "OpenRouter credits", "OpenAI API billing" (docs/spec/10 FR2). */
	billing: Type.Optional(Type.String()),
});
export type ModelInfo = Static<typeof ModelInfo>;

/** A model provider and how it's connected (docs/spec/10-model-providers FR1). */
export const ProviderInfo = Type.Object({
	id: Type.String(),
	name: Type.String(),
	/** Ways to connect it: an API key, or signing in (OAuth); `subscription` when sign-in uses a paid plan. */
	methods: Type.Array(Type.Object({ type: literals("api_key", "oauth"), label: Type.String(), subscription: Type.Optional(Type.Boolean()) })),
	status: literals("not_connected", "connecting", "connected", "needs_attention"),
	connectedWith: Type.Optional(literals("api_key", "oauth")),
	billing: Type.Optional(Type.String()),
	/** Why it needs attention ("Sign-in expired"). */
	message: Type.Optional(Type.String()),
	/** Shown first in Settings (OpenRouter, ChatGPT, OpenAI API). */
	featured: Type.Boolean(),
	models: Type.Number(),
	/** A custom endpoint added by address (LiteLLM, Ollama, LM Studio…). */
	endpoint: Type.Optional(
		Type.Object({
			baseUrl: Type.String(),
			local: Type.Boolean(),
			keyless: Type.Boolean(),
			format: Type.Optional(literals("openai", "anthropic")),
			headers: Type.Optional(Type.Record(Type.String(), Type.String())),
			contextWindow: Type.Optional(Type.Number()),
		}),
	),
	/** Catalog (Add provider sheet): cloud API, subscription or cloud platform. */
	kind: Type.Optional(literals("cloud", "subscription", "platform", "custom")),
	/** The "Popular" card's one line. */
	popular: Type.Optional(Type.String()),
	/** Where to create a key. */
	keyPage: Type.Optional(Type.String()),
	/** Model families it serves ("claude", "gpt"…), for search. */
	families: Type.Optional(Type.Array(Type.String())),
	/** The stored key, masked ("sk-or-v1-755…a30"). */
	keyHint: Type.Optional(Type.String()),
	/** Models you hid from the picker. */
	hiddenModels: Type.Optional(Type.Number()),
	/** A few model names, for the connect sheet's preview. */
	sampleModels: Type.Optional(Type.Array(Type.String())),
});
export type ProviderInfo = Static<typeof ProviderInfo>;

/** One step of a provider sign-in (pi's AuthInteraction, docs/spec/10 §10). `prompt` waits for `providers.answer`. */
export const ProviderAuthEvent = Type.Union([
	Type.Object({ type: Type.Literal("auth_url"), url: Type.String(), instructions: Type.Optional(Type.String()) }),
	Type.Object({ type: Type.Literal("device_code"), userCode: Type.String(), verificationUri: Type.String(), expiresInSeconds: Type.Optional(Type.Number()) }),
	Type.Object({ type: Type.Literal("progress"), message: Type.String() }),
	Type.Object({ type: Type.Literal("info"), message: Type.String(), links: Type.Optional(Type.Array(Type.Object({ url: Type.String(), label: Type.Optional(Type.String()) }))) }),
	Type.Object({
		type: Type.Literal("prompt"),
		promptId: Type.String(),
		kind: literals("text", "secret", "select", "manual_code"),
		message: Type.String(),
		placeholder: Type.Optional(Type.String()),
		options: Type.Optional(Type.Array(Type.Object({ id: Type.String(), label: Type.String(), description: Type.Optional(Type.String()) }))),
	}),
	Type.Object({ type: Type.Literal("prompt_closed"), promptId: Type.String() }),
	Type.Object({ type: Type.Literal("done") }),
	Type.Object({ type: Type.Literal("failed"), message: Type.String() }),
]);
export type ProviderAuthEvent = Static<typeof ProviderAuthEvent>;

export const ConnectorPermission = literals("runs", "ask", "off");

/** A connected app (docs/spec/12-connectors): what it is, its accounts and settings. */
export const ConnectorInfo = Type.Object({
	id: Type.String(),
	name: Type.String(),
	category: Type.String(),
	description: Type.String(),
	/** An OAuth client is set up (Piopio's own, or yours). */
	ready: Type.Boolean(),
	/** You set your own OAuth client (Settings shows its fields filled). */
	ownClient: Type.Boolean(),
	needsSecret: Type.Boolean(),
	setupHelp: Type.String(),
	connecting: Type.Boolean(),
	/** Its tools are offered in chats, notebooks and Build (agents always get them). */
	chats: Type.Boolean(),
	accounts: Type.Array(Type.Object({ id: Type.String(), label: Type.String(), addedAt: Type.String(), problem: Type.Optional(Type.String()) })),
	/** What it can do, grouped as Settings shows it: each capability's tools and whether it runs, asks first or is off. */
	capabilities: Type.Array(
		Type.Object({
			id: Type.String(),
			label: Type.String(),
			tools: Type.Array(Type.String()),
			access: literals("read", "write", "send", "destructive"),
			permission: ConnectorPermission,
			/** The permissions it can take: sending and deleting can't run on their own. */
			choices: Type.Array(ConnectorPermission),
			note: Type.Optional(Type.String()),
		}),
	),
});
export type ConnectorInfo = Static<typeof ConnectorInfo>;

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
	/** Names of its environment variables (values stay in the file). */
	env: Type.Optional(Type.Array(Type.String())),
	/** Tools turned off (pi's `toolExposure`: "hidden"). */
	hiddenTools: Type.Optional(Type.Array(Type.String())),
	/** Global servers: chats and notebooks use it too. */
	chat: Type.Optional(Type.Boolean()),
});
export type McpServerInfo = Static<typeof McpServerInfo>;

/** A server started to see it works: its tools and how long it took, or what went wrong (with its stderr). */
export const McpProbe = Type.Object({
	ok: Type.Boolean(),
	ms: Type.Optional(Type.Number()),
	tools: Type.Array(Type.Object({ name: Type.String(), description: Type.Optional(Type.String()) })),
	error: Type.Optional(Type.String()),
	log: Type.Optional(Type.String()),
});
export type McpProbe = Static<typeof McpProbe>;

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
		params: Type.Object({
			token: Type.String(),
			client: Type.String(),
			protocolVersion: Type.String(),
			/** Reverse requests this client answers besides `secrets.get` (§3.12): `app.tool`, `secrets.set` (also `secrets.delete`). */
			services: Type.Optional(Type.Array(Type.String())),
		}),
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
			kind: Type.Union([Type.Literal("thread"), Type.Literal("build"), Type.Literal("space")]),
			cwd: Type.Optional(Type.String()),
			/** Spaces: what every agent in the Space is told. */
			instructions: Type.Optional(Type.String()),
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
		/** `fold`: a turn's tool calls come as one `steps` item (the app's folded activity line, docs/design v2). */
		params: Type.Object({ ref: ContainerRef, fold: Type.Optional(Type.Boolean()) }),
		result: Snapshot,
	},
	"sessions.subscribe": {
		params: Type.Object({ ref: ContainerRef, fold: Type.Optional(Type.Boolean()) }),
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
	/** What the model provider has billed, from its own account (OpenRouter's key endpoint; cached a minute). */
	"usage.summary": {
		params: Type.Object({ refresh: Type.Optional(Type.Boolean()) }),
		result: Type.Object({
			connected: Type.Boolean(),
			/** "sk-or-v1-755…a30". */
			keyHint: Type.Optional(Type.String()),
			todayUsd: Type.Optional(Type.Number()),
			monthUsd: Type.Optional(Type.Number()),
			totalUsd: Type.Optional(Type.Number()),
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
	/** Every model provider pi knows, and how each is connected (docs/spec/10 FR1). */
	"providers.list": {
		params: Type.Object({}),
		result: Type.Object({ providers: Type.Array(ProviderInfo) }),
	},
	/** Starts connecting a provider; its steps arrive as `providers.auth` notifications with this `loginId`. */
	"providers.login": {
		params: Type.Object({ provider: Type.String(), method: literals("api_key", "oauth") }),
		result: Type.Object({ loginId: Type.String() }),
	},
	/** Answers a sign-in prompt (`value`), or cancels it (no value). */
	"providers.answer": {
		params: Type.Object({ loginId: Type.String(), promptId: Type.String(), value: Type.Optional(Type.String()) }),
		result: Type.Object({}),
	},
	"providers.cancelLogin": {
		params: Type.Object({ loginId: Type.String() }),
		result: Type.Object({}),
	},
	/** Asks an OpenAI-compatible server for its models, without saving anything. */
	"endpoints.check": {
		params: Type.Object({ baseUrl: Type.String(), key: Type.Optional(Type.String()), id: Type.Optional(Type.String()), format: Type.Optional(literals("openai", "anthropic")), headers: Type.Optional(Type.Record(Type.String(), Type.String())) }),
		result: Type.Object({
			ok: Type.Boolean(),
			/** The address that answered (with /v1 added when needed). */
			baseUrl: Type.Optional(Type.String()),
			models: Type.Array(Type.Object({ id: Type.String(), contextWindow: Type.Optional(Type.Number()), embedding: Type.Optional(Type.Boolean()) })),
			message: Type.Optional(Type.String()),
			/** What went wrong, for the right help (design m5). */
			error: Type.Optional(literals("refused", "auth", "not_found", "empty", "tls", "invalid", "other")),
			latencyMs: Type.Optional(Type.Number()),
		}),
	},
	/** Adds or updates (`id`) a custom endpoint after checking it (`force`: save even if it doesn't answer). No `key` on update keeps the stored one. */
	"endpoints.save": {
		params: Type.Object({
			id: Type.Optional(Type.String()),
			name: Type.String(),
			baseUrl: Type.String(),
			key: Type.Optional(Type.String()),
			format: Type.Optional(literals("openai", "anthropic")),
			headers: Type.Optional(Type.Record(Type.String(), Type.String())),
			contextWindow: Type.Optional(Type.Number()),
			/** Model ids to keep out of the picker (embeddings are hidden by default). */
			hidden: Type.Optional(Type.Array(Type.String())),
			force: Type.Optional(Type.Boolean()),
		}),
		result: Type.Object({ id: Type.String() }),
	},
	"endpoints.remove": {
		params: Type.Object({ id: Type.String() }),
		result: Type.Object({}),
	},
	/** Ollama and LM Studio answering on this Mac, and not added yet. */
	"endpoints.detect": {
		params: Type.Object({}),
		result: Type.Object({ found: Type.Array(Type.Object({ name: Type.String(), baseUrl: Type.String(), models: Type.Number(), preset: Type.String() })) }),
	},
	/** Connected apps (docs/spec/12-connectors). */
	"connectors.list": {
		params: Type.Object({}),
		result: Type.Object({ connectors: Type.Array(ConnectorInfo) }),
	},
	/** Starts signing in to an app; steps arrive as `connectors.auth`. */
	"connectors.connect": {
		params: Type.Object({ connector: Type.String() }),
		result: Type.Object({ loginId: Type.String() }),
	},
	"connectors.cancel": {
		params: Type.Object({ loginId: Type.String() }),
		result: Type.Object({}),
	},
	"connectors.disconnect": {
		params: Type.Object({ accountId: Type.String() }),
		result: Type.Object({}),
	},
	/** Use in chats, what each tool may do (by tool name), and a developer's own OAuth client (the secret goes to the Keychain). */
	"connectors.configure": {
		params: Type.Object({
			connector: Type.String(),
			chats: Type.Optional(Type.Boolean()),
			dontAsk: Type.Optional(Type.Array(Type.String())),
			permissions: Type.Optional(Type.Record(Type.String(), ConnectorPermission)),
			clientId: Type.Optional(Type.String()),
			clientSecret: Type.Optional(Type.String()),
		}),
		result: Type.Object({}),
	},
	/** An account's calendars, each on or off for Piopio (off: never read). */
	"connectors.calendars": {
		params: Type.Object({ accountId: Type.String() }),
		result: Type.Object({ calendars: Type.Array(Type.Object({ id: Type.String(), name: Type.String(), primary: Type.Boolean(), color: Type.Optional(Type.String()), enabled: Type.Boolean() })) }),
	},
	"connectors.setCalendar": {
		params: Type.Object({ accountId: Type.String(), calendarId: Type.String(), enabled: Type.Boolean() }),
		result: Type.Object({}),
	},
	/** Answers a connector approval in a chat, notebook topic or Build session. `always`: don't ask again for that write. */
	"sessions.decide": {
		params: Type.Object({ ref: ContainerRef, approvalId: Type.String(), approve: Type.Boolean(), always: Type.Optional(Type.Boolean()), reason: Type.Optional(Type.String()) }),
		result: Type.Object({ status: literals("pending", "approved", "denied", "expired", "cancelled") }),
	},
	/** Checks a key against the provider's model list without saving it. `ok: null`: can't be checked up front. */
	"providers.verifyKey": {
		params: Type.Object({ provider: Type.String(), key: Type.String() }),
		result: Type.Object({ ok: Type.Union([Type.Boolean(), Type.Null()]), message: Type.Optional(Type.String()), models: Type.Optional(Type.Number()) }),
	},
	/** Connects a provider with an API key directly (the Add provider sheet), replacing any key it had. */
	"providers.saveKey": {
		params: Type.Object({ provider: Type.String(), key: Type.String() }),
		result: Type.Object({}),
	},
	/** Every model a connected provider offers, and whether it shows in the picker. */
	"providers.models": {
		params: Type.Object({ provider: Type.String() }),
		result: Type.Object({ models: Type.Array(Type.Object({ id: Type.String(), name: Type.String(), contextWindow: Type.Number(), hidden: Type.Boolean(), embedding: Type.Optional(Type.Boolean()) })) }),
	},
	/** Hides or shows models of a provider in the picker. */
	"providers.setHidden": {
		params: Type.Object({ provider: Type.String(), hidden: Type.Array(Type.String()) }),
		result: Type.Object({}),
	},
	/** Disconnects one provider; the others stay as they are. */
	"providers.logout": {
		params: Type.Object({ provider: Type.String() }),
		result: Type.Object({}),
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
			/** Off for Build (pi's `enabled: false`). */
			enabled: Type.Optional(Type.Boolean()),
			/** Global servers: use in chats and notebooks too. */
			chat: Type.Optional(Type.Boolean()),
		}),
		result: Type.Object({}),
	},
	/** Starts a server that isn't saved yet and lists its tools (the Add server sheet). */
	"mcp.probe": {
		params: Type.Object({ command: Type.Optional(Type.String()), args: Type.Optional(Type.Array(Type.String())), url: Type.Optional(Type.String()), env: Type.Optional(Type.Record(Type.String(), Type.String())) }),
		result: McpProbe,
	},
	/** A configured server's status: its last probe, or a new one (`refresh`: Restart). */
	"mcp.status": {
		params: Type.Object({ scope: literals("global", "project"), cwd: Type.Optional(Type.String()), name: Type.String(), refresh: Type.Optional(Type.Boolean()) }),
		result: McpProbe,
	},
	/** A global server in chats and notebooks, or not. */
	"mcp.setChat": { params: Type.Object({ name: Type.String(), chat: Type.Boolean() }), result: Type.Object({}) },
	/** One of a server's tools on or off. */
	"mcp.setTool": {
		params: Type.Object({ scope: literals("global", "project"), cwd: Type.Optional(Type.String()), name: Type.String(), tool: Type.String(), enabled: Type.Boolean() }),
		result: Type.Object({}),
	},
	/** Servers configured in other apps (Claude Desktop, Cursor, VS Code, Windsurf) that aren't here yet. */
	"mcp.detect": {
		params: Type.Object({}),
		result: Type.Object({
			found: Type.Array(
				Type.Object({
					app: Type.String(),
					path: Type.String(),
					servers: Type.Array(Type.Object({ name: Type.String(), command: Type.Optional(Type.String()), args: Type.Optional(Type.Array(Type.String())), url: Type.Optional(Type.String()), env: Type.Optional(Type.Record(Type.String(), Type.String())) })),
				}),
			),
		}),
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
	/** Wrong topic: sends a routed message to another topic, or a new one, and teaches the organizer (04-chat S2). */
	"spaces.reroute": {
		params: Type.Object({ ref: ContainerRef, itemId: Type.String(), toTopicId: Type.Optional(Type.String()), newTopic: Type.Optional(Type.String()) }),
		result: Type.Object({}),
	},
	/** You looked at a topic: clears its unread dot. */
	"spaces.markRead": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({}),
	},
	/** A Space's settings (§3.6). The topic model applies to new topics and every existing one. */
	"spaces.configure": {
		params: Type.Object({
			ref: ContainerRef,
			instructions: Type.Optional(Type.String()),
			organizerModel: Type.Optional(ModelRef),
			topicModel: Type.Optional(ModelRef),
			memory: Type.Optional(Type.Boolean()),
			autoTidy: Type.Optional(Type.Boolean()),
		}),
		result: Type.Object({}),
	},
	/** The memory and its history, newest first (S8). */
	"spaces.memory.get": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({
			text: Type.String(),
			revisions: Type.Array(
				Type.Object({
					id: Type.String(),
					at: Type.String(),
					by: Type.Object({ kind: literals("organizer", "topic", "user"), topicId: Type.Optional(Type.String()), title: Type.Optional(Type.String()) }),
					summary: Type.String(),
					added: Type.Array(Type.String()),
					removed: Type.Array(Type.String()),
					undone: Type.Optional(Type.Boolean()),
				}),
			),
			/** Changes topics proposed that wait for you (docs/design v2 "Suggested by topics"). */
			proposals: Type.Optional(
				Type.Array(Type.Object({ id: Type.String(), at: Type.String(), topicId: Type.String(), title: Type.String(), added: Type.Array(Type.String()), removed: Type.Array(Type.String()), reason: Type.String() })),
			),
		}),
	},
	/** Your edit in the memory editor. */
	"spaces.memory.set": { params: Type.Object({ ref: ContainerRef, text: Type.String() }), result: Type.Object({}) },
	/** Undo on a memory card: takes that change back. */
	"spaces.memory.undo": { params: Type.Object({ ref: ContainerRef, revisionId: Type.String() }), result: Type.Object({}) },
	/** The memory as it was after a change in the history. */
	"spaces.memory.restore": { params: Type.Object({ ref: ContainerRef, revisionId: Type.String() }), result: Type.Object({}) },
	/** Save or Dismiss a topic's proposal. */
	"spaces.memory.decide": { params: Type.Object({ ref: ContainerRef, proposalId: Type.String(), accept: Type.Boolean() }), result: Type.Object({}) },
	/** Topic housekeeping (S9). `ref` is the topic's. */
	"spaces.topics.rename": { params: Type.Object({ ref: ContainerRef, title: Type.String() }), result: Type.Object({}) },
	"spaces.topics.archive": { params: Type.Object({ ref: ContainerRef, archived: Type.Boolean() }), result: Type.Object({}) },
	/** Summarizes the topic into `into` (its brief) and archives it. */
	"spaces.topics.merge": { params: Type.Object({ ref: ContainerRef, into: Type.String() }), result: Type.Object({ summary: Type.String() }) },
	/** Space files: documents every topic can read. */
	"spaces.files.list": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({ files: Type.Array(Type.Object({ name: Type.String(), size: Type.Number(), addedAt: Type.String() })) }),
	},
	/** Copies a file in (`path`), or writes a note (`text`). `extracted`: a document's text, read by the client. */
	"spaces.files.add": {
		params: Type.Object({ ref: ContainerRef, name: Type.String(), path: Type.Optional(Type.String()), text: Type.Optional(Type.String()), extracted: Type.Optional(Type.String()) }),
		result: Type.Object({}),
	},
	"spaces.files.remove": { params: Type.Object({ ref: ContainerRef, name: Type.String() }), result: Type.Object({}) },
	"settings.get": { params: Type.Object({}), result: EngineSettings },
	"settings.set": {
		params: Type.Object({ chat: Type.Optional(Type.Partial(EngineSettings.properties.chat)), aboutMe: Type.Optional(Type.Partial(EngineSettings.properties.aboutMe)), memory: Type.Optional(Type.Partial(EngineSettings.properties.memory)) }),
		result: EngineSettings,
	},
	/** The "About me" memory and its history, newest first. */
	"aboutMe.get": {
		params: Type.Object({}),
		result: Type.Object({
			text: Type.String(),
			revisions: Type.Array(Type.Object({ id: Type.String(), at: Type.String(), by: Type.Object({ kind: literals("organizer", "topic", "user") }), summary: Type.String(), added: Type.Array(Type.String()), removed: Type.Array(Type.String()) })),
			/** The provider it lives in, and whether that provider can list what it stored (07 §6.2 MM3). */
			provider: Type.String(),
			limited: Type.Boolean(),
		}),
	},
	"aboutMe.set": { params: Type.Object({ text: Type.String() }), result: Type.Object({}) },
	/** Takes one change back (a revision of the history). */
	"aboutMe.undo": { params: Type.Object({ revisionId: Type.String() }), result: Type.Object({}) },
	/** The tools of an MCP server or URL, for the memory provider's mapping editor. */
	"memory.tools": {
		params: Type.Object({ server: Type.Optional(Type.String()), url: Type.Optional(Type.String()) }),
		result: Type.Object({ tools: Type.Array(Type.Object({ name: Type.String(), description: Type.Optional(Type.String()) })) }),
	},
	/** Try a provider: what it recalls for a query in a bank. */
	"memory.recall": {
		params: Type.Object({ provider: Type.String(), bank: Type.String(), query: Type.String() }),
		result: Type.Object({ hits: Type.Array(Type.Object({ id: Type.String(), text: Type.String(), score: Type.Number(), at: Type.Optional(Type.String()) })) }),
	},
	/** Dismiss on a thread's Space suggestion: it won't be suggested again. */
	"threads.dismissSuggestion": { params: Type.Object({ ref: ContainerRef }), result: Type.Object({}) },
	/**
	 * Moves threads into a Space (S5, S11): each becomes a new topic named after it, or, with `topicId`, joins
	 * that topic. The threads are deleted unless `keepThreads`.
	 */
	"spaces.importThreads": {
		params: Type.Object({ ref: ContainerRef, threads: Type.Array(ContainerRef), topicId: Type.Optional(Type.String()), keepThreads: Type.Optional(Type.Boolean()) }),
		result: Type.Object({ topicIds: Type.Array(Type.String()) }),
	},
	/** Promote to Thread (S9): copies a topic out into a new thread. The topic stays. */
	"spaces.topics.promote": { params: Type.Object({ ref: ContainerRef }), result: Type.Object({ ref: ContainerRef }) },
	/** pi packages (Settings › Extensions). */
	"packages.list": { params: Type.Object({}), result: Type.Object({ packages: Type.Array(PiPackage) }) },
	"packages.install": { params: Type.Object({ source: Type.String() }), result: Type.Object({}) },
	"packages.remove": { params: Type.Object({ source: Type.String() }), result: Type.Object({}) },
	"packages.update": { params: Type.Object({ source: Type.Optional(Type.String()) }), result: Type.Object({}) },
	"packages.setEnabled": {
		params: Type.Object({ source: Type.String(), enabled: Type.Boolean(), kinds: Type.Optional(Type.Array(literals("extensions", "skills", "prompts", "themes"))) }),
		result: Type.Object({}),
	},
	/** Agents (06-agents §2, §11). */
	"agents.templates": {
		params: Type.Object({}),
		result: Type.Object({ templates: Type.Array(Type.Object({ id: Type.String(), name: Type.String(), avatar: Type.String(), description: Type.String() })) }),
	},
	"agents.create": {
		params: Type.Object({ name: Type.String(), template: Type.Optional(Type.String()), avatar: Type.Optional(Type.String()), model: Type.Optional(ModelRef), owner: Type.Optional(Type.String()) }),
		result: Type.Object({ ref: ContainerRef }),
	},
	/** The definition as saved, its validation and its history (git log). */
	"agents.get": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({
			definition: Type.Unknown(),
			instructions: Type.String(),
			folder: Type.String(),
			errors: Type.Array(DefinitionError),
			history: Type.Array(Type.Object({ commit: Type.String(), at: Type.String(), message: Type.String() })),
		}),
	},
	/** Validates, then writes and commits. With errors, nothing is saved. */
	"agents.save": {
		params: Type.Object({ ref: ContainerRef, definition: Type.Unknown(), instructions: Type.String(), message: Type.Optional(Type.String()) }),
		result: Type.Object({ errors: Type.Array(DefinitionError), saved: Type.Boolean() }),
	},
	/** Everyone the agent talks with: the owner and contacts, with the last message. */
	"agents.conversations": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({
			/** People, then other agents it has talked with (`agent:<id>`, read-only). */
			people: Type.Array(Type.Object({ contactId: Type.String(), name: Type.String(), role: literals("owner", "contact", "agent"), conversationId: Type.String(), started: Type.Boolean(), lastAt: Type.Optional(Type.String()), preview: Type.Optional(Type.String()) })),
		}),
	},
	/** A trace (AA5): every message between agents it holds, as a tree (`parent`), with what answering cost. */
	"agents.trace": {
		params: Type.Object({ traceId: Type.String() }),
		result: Type.Object({
			traceId: Type.String(),
			costUsd: Type.Number(),
			hops: Type.Array(
				Type.Object({
					id: Type.String(),
					parent: Type.Optional(Type.String()),
					hop: Type.Number(),
					mode: literals("ask", "tell", "reply"),
					from: Type.Object({ id: Type.String(), name: Type.String() }),
					to: Type.Object({ id: Type.String(), name: Type.String() }),
					text: Type.String(),
					reply: Type.Optional(Type.String()),
					at: Type.String(),
					status: literals("waiting", "replied", "no_reply", "sent", "failed"),
					costUsd: Type.Optional(Type.Number()),
					error: Type.Optional(Type.String()),
				}),
			),
		}),
	},
	/** Runs: schedules, heartbeat, reminders, triggers and manual runs, newest first (06 §6, Runs tab). Open one with `conversationId: "run:<id>"`. */
	"agents.runs": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({
			runs: Type.Array(
				Type.Object({
					id: Type.String(),
					kind: literals("schedule", "heartbeat", "reminder", "trigger", "manual"),
					source: Type.String(),
					prompt: Type.String(),
					firedAt: Type.String(),
					status: literals("running", "done", "failed", "skipped"),
					summary: Type.Optional(Type.String()),
					sent: Type.Number(),
					costUsd: Type.Optional(Type.Number()),
				}),
			),
			/** Messages held by quiet hours or the daily limit. */
			outbox: Type.Array(Type.Object({ id: Type.String(), to: Type.String(), text: Type.String(), notBefore: Type.String(), reason: literals("quiet", "limit", "paused") })),
			/** The schedules and reminders, with their next time. */
			upcoming: Type.Array(Type.Object({ id: Type.String(), kind: literals("schedule", "heartbeat", "reminder"), label: Type.String(), next: Type.Optional(Type.String()) })),
		}),
	},
	/** Run now: a schedule from the definition (its prompt), or any prompt. */
	"agents.runNow": {
		params: Type.Object({ ref: ContainerRef, scheduleId: Type.Optional(Type.String()), prompt: Type.Optional(Type.String()) }),
		result: Type.Object({ runId: Type.String() }),
	},
	/** The agent's webhook triggers, with the local URLs to call (HMAC-signed path). */
	"agents.triggers": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({ triggers: Type.Array(Type.Object({ id: Type.String(), url: Type.String() })) }),
	},
	/** Answers an approval: approve (as asked, or with `args`), or deny; `always` stops asking for this kind of call. */
	"agents.decide": {
		params: Type.Object({ ref: ContainerRef, approvalId: Type.String(), approve: Type.Boolean(), args: Type.Optional(Type.Unknown()), always: Type.Optional(Type.Boolean()), reason: Type.Optional(Type.String()) }),
		result: Type.Object({ status: literals("pending", "approved", "denied", "expired", "cancelled") }),
	},
	/** Reverses a change a result card shows (within 24 hours). */
	"agents.undo": {
		params: Type.Object({ ref: ContainerRef, undoId: Type.String() }),
		result: Type.Object({}),
	},
	/** The kill switch (AS4): paused, the agent runs nothing and sends nothing until it's resumed. */
	"agents.pause": {
		params: Type.Object({ ref: ContainerRef, paused: Type.Boolean() }),
		result: Type.Object({}),
	},
	/** The Inbox across agents, newest first (06 §12, docs/design 4d). `count` is what waits for you. */
	"inbox.list": {
		params: Type.Object({}),
		result: Type.Object({
			count: Type.Number(),
			items: Type.Array(
				Type.Object({
					id: Type.String(),
					agent: ContainerRef,
					agentName: Type.String(),
					avatar: Type.Optional(Type.String()),
					kind: literals("approval", "message", "run_failed", "budget", "paused"),
					at: Type.String(),
					title: Type.String(),
					body: Type.String(),
					needsYou: Type.Boolean(),
					read: Type.Boolean(),
					/** The conversation it's about, to open (`person:<id>` or `run:<id>`). */
					conversationId: Type.Optional(Type.String()),
					approval: Type.Optional(ApprovalItem),
				}),
			),
		}),
	},
	"inbox.read": {
		params: Type.Object({ items: Type.Array(Type.Object({ agentId: Type.String(), id: Type.String() })) }),
		result: Type.Object({}),
	},
	/** The agent's memory: its provider and partitions, each a bank (06 §8). */
	"agents.memory": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({ provider: Type.String(), partitions: Type.Array(Type.Object({ id: Type.String(), label: Type.String(), bank: Type.String() })) }),
	},
	/** A memory provider's records (the memory views). */
	"memory.list": {
		params: Type.Object({ provider: Type.String(), bank: Type.String(), cursor: Type.Optional(Type.String()), kinds: Type.Optional(Type.Array(Type.String())) }),
		result: Type.Object({
			records: Type.Array(Type.Object({ id: Type.String(), text: Type.String(), kind: Type.String(), createdBy: Type.String(), at: Type.String(), pinned: Type.Optional(Type.Boolean()), source: Type.Optional(Type.Object({ ref: Type.Optional(Type.String()), itemId: Type.Optional(Type.String()), title: Type.Optional(Type.String()) })) })),
			cursor: Type.Optional(Type.String()),
			limited: Type.Boolean(),
		}),
	},
	"memory.add": { params: Type.Object({ provider: Type.String(), bank: Type.String(), text: Type.String() }), result: Type.Object({}) },
	"memory.forget": { params: Type.Object({ provider: Type.String(), bank: Type.String(), id: Type.String() }), result: Type.Object({}) },
	"memory.update": { params: Type.Object({ provider: Type.String(), bank: Type.String(), id: Type.String(), text: Type.Optional(Type.String()), pinned: Type.Optional(Type.Boolean()) }), result: Type.Object({}) },
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
	/** Stores a secret in the client's Keychain (provider sign-ins, refreshed tokens). Only for clients offering `secrets.set`. */
	"secrets.set": {
		params: Type.Object({ name: Type.String(), value: Type.String() }),
		result: Type.Object({}),
	},
	"secrets.delete": {
		params: Type.Object({ name: Type.String() }),
		result: Type.Object({}),
	},
	/**
	 * An Apple app tool, run by the Mac app with the user's permissions (06-agents §4.1). The app checks `groups`
	 * (and `shortcuts`) again. `undo` is the call that reverses a change (§4.2).
	 */
	"app.tool": {
		params: Type.Object({
			name: Type.String(),
			args: Type.Unknown(),
			agent: Type.Object({ id: Type.String(), name: Type.String() }),
			groups: Type.Array(Type.String()),
			shortcuts: Type.Array(Type.String()),
		}),
		result: Type.Object({
			ok: Type.Boolean(),
			/** What the model reads. */
			output: Type.String(),
			card: Type.Optional(Type.Object({ kind: literals("reminder", "event", "contact", "note", "music", "shortcut"), title: Type.String(), detail: Type.Optional(Type.String()) })),
			undo: Type.Optional(Type.Object({ name: Type.String(), args: Type.Unknown(), title: Type.String() })),
		}),
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
	/** The Inbox changed; `count` is what waits for you (badges). `approval` is set when an agent asks (notifications). */
	/** A step of a provider sign-in started with `providers.login`. */
	"providers.auth": Type.Object({ loginId: Type.String(), provider: Type.String(), event: ProviderAuthEvent }),
	/** A step of signing in to an app started with `connectors.connect`. */
	"connectors.auth": Type.Object({ loginId: Type.String(), connector: Type.String(), event: ProviderAuthEvent }),
	/** Connected apps changed (accounts, settings, needs sign-in): list them again. */
	"connectors.changed": Type.Object({}),
	/** Providers or their models changed (connected, disconnected, needs attention): list them again. */
	"providers.changed": Type.Object({}),
	"inbox.changed": Type.Object({ count: Type.Number(), approval: Type.Optional(Type.Object({ agent: ContainerRef, agentName: Type.String(), approvalId: Type.String(), title: Type.String() })) }),
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
