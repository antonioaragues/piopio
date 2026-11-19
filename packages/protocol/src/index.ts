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

export const ContainerKind = literals("build", "thread", "agent");
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

/** An automation as its card shows it (docs/spec/27 §4): when, who runs it, what it does, where the result goes. */
export const AutomationSummary = Type.Object({
	id: Type.String(),
	name: Type.String(),
	when: Type.String({ description: "“Every Monday at 09:00”, “When an email from the bank arrives”" }),
	runsAs: Type.String({ description: "“Rita”, “Piopio in shop”" }),
	does: Type.String(),
	tellsYou: Type.String({ description: "“Rita’s chat”, “Telegram”, “A conversation in shop”, “Only if it needs you”" }),
	runsOn: Type.String({ description: "“This Mac, only while it's awake”" }),
	url: Type.Optional(Type.String({ description: "webhook: where to POST" })),
	next: Type.Optional(Type.Number({ description: "time: the next run, epoch ms" })),
});
export type AutomationSummary = Static<typeof AutomationSummary>;

export const ToolDetails = Type.Union([
	Type.Object({ type: Type.Literal("diff"), path: Type.String(), diff: Type.String() }),
	Type.Object({ type: Type.Literal("file"), path: Type.String(), language: Type.Optional(Type.String()) }),
	Type.Object({ type: Type.Literal("terminal"), command: Type.String(), exitCode: Type.Optional(Type.Number()) }),
	Type.Object({ type: Type.Literal("json"), value: Type.Unknown() }),
	/** The agent's checklist (piopio-todos). */
	Type.Object({ type: Type.Literal("todos"), items: Type.Array(Type.Object({ text: Type.String(), detail: Type.Optional(Type.String()), status: literals("pending", "in_progress", "done") })) }),
	/** A subagent (piopio-subagents): its child session, once started, and the outcome. */
	Type.Object({ type: Type.Literal("task"), sessionId: Type.Optional(Type.String()), status: Type.Optional(literals("started", "queued", "done", "error", "stopped")), costUsd: Type.Optional(Type.Number()) }),
	/** Files the agent handed over (piopio-present): where they are, what they are, and which ones don't exist. */
	Type.Object({
		type: Type.Literal("files"),
		files: Type.Array(Type.Object({ path: Type.String(), name: Type.String(), description: Type.Optional(Type.String()), size: Type.Optional(Type.Number()), missing: Type.Optional(Type.Boolean()) })),
	}),
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
	/** One of your agents asked from a conversation (docs/spec/21 D6): who, whether an @mention brought it in, and how it went. */
	Type.Object({
		type: Type.Literal("agent"),
		agent: Type.Object({ id: Type.String(), name: Type.String() }),
		joined: Type.Optional(Type.Boolean({ description: "Brought in with @Name for this message" })),
		status: Type.Optional(literals("replied", "no_reply", "failed")),
	}),
	/** Piopio made or changed an automation (docs/spec/27 §4): its card, with Open in Automations and Undo. */
	Type.Object({ type: Type.Literal("automation"), automation: AutomationSummary, changed: Type.Optional(Type.Boolean()) }),
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
export const AttachmentInfo = Type.Object({
	name: Type.String(),
	kind: literals("image", "text"),
	mimeType: Type.Optional(Type.String()),
	size: Type.Optional(Type.Number()),
	/** Where Piopio keeps a copy, relative to `<home>/attachments/<container id>/` (to show it again). */
	stored: Type.Optional(Type.String()),
});
export type AttachmentInfo = Static<typeof AttachmentInfo>;

/**
 * A file to send. Clients prepare it: images as base64 (already downscaled), documents as extracted text. `path` is the
 * original on this Mac, which the engine copies so the file can be shown again; it never reaches the model.
 */
export const Attachment = Type.Union([
	Type.Object({ kind: Type.Literal("image"), name: Type.String(), mimeType: Type.String(), data: Type.String(), path: Type.Optional(Type.String()) }),
	Type.Object({ kind: Type.Literal("text"), name: Type.String(), mimeType: Type.Optional(Type.String()), text: Type.String(), path: Type.Optional(Type.String()) }),
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
	/** An agent's message sent on its own (send_message), and where from: a run id or a person's conversation. */
	outbound: Type.Optional(Type.Object({ from: Type.String(), suggestions: Type.Optional(Type.Array(Type.String(), { description: "Quick replies offered with it (a new agent's greeting)" })) })),
	/** How long it thought before answering or acting (measured live; absent for reloaded history). */
	thinkingMs: Type.Optional(Type.Number()),
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
	/** Auto review let this command run without asking you (Build, Auto-edit): its reason. */
	review: Type.Optional(Type.String()),
	/** Images the tool returned (a screenshot it read), kept like sent files so the transcript can show them. */
	images: Type.Optional(Type.Array(AttachmentInfo)),
});
export const SystemItem = Type.Object({
	kind: Type.Literal("system"),
	id: Type.String(),
	at: Type.String(),
	level: literals("info", "warn", "error"),
	text: Type.String(),
	/** A run of the agent, shown in its owner's conversation as a divider (docs/spec/21 D3); opens as `run:<id>`. */
	run: Type.Optional(Type.Object({ id: Type.String(), status: literals("running", "done", "failed", "skipped"), sent: Type.Number(), summary: Type.Optional(Type.String()), costUsd: Type.Optional(Type.Number()), automation: Type.Optional(Type.Object({ id: Type.String(), name: Type.String() }, { description: "The automation that started it (docs/spec/27 §4): “From <name>”" })) })),
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

/** A turn's tool calls as one line, "Worked 18s · 2 steps" (06-agents §12 UI2): agents' conversations. */
export const StepsItem = Type.Object({
	kind: Type.Literal("steps"),
	id: Type.String(),
	at: Type.String(),
	tools: Type.Array(ToolItem),
	/** What the model thought in the answers that only called these tools, folded into the same line. */
	thinking: Type.Optional(Type.String()),
	thinkingMs: Type.Optional(Type.Number()),
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
	card: Type.Object({
		kind: literals("reminder", "message", "memory", "event", "contact", "note", "music", "shortcut", "setup", "automation"),
		title: Type.String(),
		detail: Type.Optional(Type.String()),
		/** An automation made or changed (docs/spec/27 §4): what its card shows. */
		automation: Type.Optional(AutomationSummary),
	}),
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
export const TimelineItem = Type.Union([UserItem, AssistantItem, ToolItem, SystemItem, CompactionItem, CheckpointItem, StepsItem, ApprovalItem, ResultItem, AgentMsgItem]);
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
/** How much a Build session may do on its own (05-build §6). `read_only`: reads and the web; no edits or commands (18 §4). */
export const ApprovalMode = literals("read_only", "ask", "auto_edit", "full_auto");
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

/** What fills the context: pi's total spread over categories by their estimated shares, so they add up to `tokens`. */
const ContextBreakdown = Type.Object({
	source: literals("request", "session"),
	groups: Type.Array(Type.Object({
		kind: literals("instructions", "tools", "conversation", "toolUse", "attachments", "summaries"),
		tokens: Type.Number(),
		parts: Type.Array(Type.Object({ label: Type.String(), tokens: Type.Number() })),
	})),
});

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
	todos: Type.Optional(Type.Array(Type.Object({ text: Type.String(), detail: Type.Optional(Type.String()), status: literals("pending", "in_progress", "done") }))),
	planMode: Type.Optional(Type.Boolean()),
	/** How full the model's context is (Build). `tokens` is null right after a compaction. */
	context: Type.Optional(Type.Object({
		tokens: Type.Union([Type.Number(), Type.Null()]),
		window: Type.Number(),
		breakdown: Type.Optional(ContextBreakdown),
	})),
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

/**
 * Where background model work runs (07-shared §1.3): "auto" (the default) uses the provider each conversation already
 * uses; or Apple's on-device model, a model you picked, or nowhere.
 */
export const UtilityChoice = Type.Union([Type.Literal("auto"), Type.Literal("on_device"), Type.Literal("off"), ModelRef]);
export type UtilityChoice = Static<typeof UtilityChoice>;

/** Engine-wide settings (07-shared §5, §7). */
export const EngineSettings = Type.Object({
	/** Background model work (07-shared §1.3). Unset: automatic. */
	models: Type.Optional(
		Type.Object({
			/** Titles, summaries, suggested replies, commit messages, learned facts. */
			utility: Type.Optional(UtilityChoice),
		}),
	),
	chat: Type.Object({
		/** Before per-server choices: every global server that's on is used in chats too. */
		mcp: Type.Boolean(),
		/** The global MCP servers chats use (Settings › MCP servers, per server). Absent: `mcp` decides. */
		mcpServers: Type.Optional(Type.Array(Type.String())),
		/** After an answer, suggest a few next messages (docs/design v2 "You could also"). */
		followUps: Type.Optional(Type.Boolean()),
		/** Side conversations (docs/spec/24 §6): when you bring up something unrelated, ask (default), start one, or do nothing. */
		sideOnUnrelated: Type.Optional(literals("ask", "start", "off")),
		/** Piopio proposes follow-ups it notices as cards you start (default on). */
		sidePropose: Type.Optional(Type.Boolean()),
		/** A side conversation's report wakes the conversation it came from (default on). */
		sideWake: Type.Optional(Type.Boolean()),
	}),
	/** Build sessions (docs/research/deepseek-harness.md). Absent fields: their defaults. */
	build: Type.Optional(
		Type.Object({
			/** Shell commands run in macOS's sandbox and write only inside the project (default on; Full access runs them as before). */
			sandbox: Type.Optional(Type.Boolean()),
			/** Auto-edit: before asking you about a command, the session's model judges it and runs the clearly safe ones (default off). */
			autoReview: Type.Optional(Type.Boolean()),
		}),
	),
	aboutMe: Type.Object({
		/** Shown to the agents. */
		enabled: Type.Boolean(),
		/** The agents may add facts (`remember_about_me`). */
		capture: Type.Boolean(),
		inThreads: Type.Boolean(),
		/** Agents read it too (Settings › Chat, "Share with … + Agents"). */
		inAgents: Type.Optional(Type.Boolean()),
		/** Where About me lives: "builtin", or an MCP memory provider's id. */
		provider: Type.String(),
	}),
	memory: Type.Object({
		/** MCP memory providers (07-shared §6.2). */
		providers: Type.Array(McpMemoryProvider),
		/**
		 * Search memory by meaning (docs/spec/14-memory M1): memories are embedded through OpenRouter (or the OpenAI API
		 * key). Off by default: search matches words and nothing leaves the Mac. Unset with `embeddings`: on.
		 */
		semantic: Type.Optional(Type.Boolean()),
		/** Older name for `semantic: false` (read, no longer written). */
		localOnly: Type.Optional(Type.Boolean()),
		/** Another embedding endpoint than the default (OpenRouter, then the OpenAI API key): an OpenAI-compatible server. */
		embeddings: Type.Optional(Type.Object({ baseUrl: Type.String(), model: Type.String(), dims: Type.Number(), provider: Type.Optional(Type.String()) })),
	}),
});
export type EngineSettings = Static<typeof EngineSettings>;

/** A pi package (07-shared §6.1): what it brings, and what of it is on. */
export const PiPackage = Type.Object({
	source: Type.String(),
	kind: literals("npm", "git", "local"),
	/** From its package.json, once installed. */
	name: Type.Optional(Type.String()),
	version: Type.Optional(Type.String()),
	description: Type.Optional(Type.String()),
	/** A newer version on npm (unpinned npm packages). */
	latest: Type.Optional(Type.String()),
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

/** What a package would add, before installing it (Settings › Extensions, Install sheet). */
export const PackagePreview = Type.Object({
	ok: Type.Boolean(),
	kind: literals("npm", "git", "local"),
	name: Type.Optional(Type.String()),
	version: Type.Optional(Type.String()),
	description: Type.Optional(Type.String()),
	author: Type.Optional(Type.String()),
	extensions: Type.Array(Type.String()),
	skills: Type.Array(Type.String()),
	prompts: Type.Array(Type.String()),
	themes: Type.Array(Type.String()),
	/** Whether the lists above are known (a git repository off GitHub isn't read before installing). */
	contentsKnown: Type.Boolean(),
	error: Type.Optional(Type.String()),
});
export type PackagePreview = Static<typeof PackagePreview>;

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
	/** Just made, still learning its job by talking (docs/spec/21 D4): shown as a draft. */
	draft: Type.Optional(Type.Boolean()),
	/** While the engine runs it: paused (AS4), this month's spend against the budget (AS3), Inbox items waiting. */
	status: Type.Optional(Type.Object({ paused: Type.Boolean(), spendUsd: Type.Number(), budgetUsd: Type.Optional(Type.Number()), inbox: Type.Number(), nextRun: Type.Optional(Type.String()) })),
});
export type AgentInfo = Static<typeof AgentInfo>;

export const DefinitionError = Type.Object({ path: Type.String(), message: Type.String() });

/** A memory record on its way between the Mac and the cloud: its partition (the bank is `<agent>/<partition>`). */
export const CloudMemory = Type.Object({
	partition: Type.String(),
	text: Type.String(),
	kind: Type.String(),
	createdBy: literals("agent", "user", "extraction"),
	at: Type.String(),
	tags: Type.Optional(Type.Array(Type.String())),
	pinned: Type.Optional(Type.Boolean()),
});
export type CloudMemory = Static<typeof CloudMemory>;

/** Your cloud as the Mac sees it (docs/spec/30 K1). */
export const CloudStatus = Type.Object({
	connected: Type.Boolean(),
	url: Type.Optional(Type.String()),
	/** It answered `/v1/health` just now (false: offline, or the token stopped working; see `error`). */
	reachable: Type.Optional(Type.Boolean()),
	version: Type.Optional(Type.String()),
	error: Type.Optional(Type.String()),
	connectedAt: Type.Optional(Type.String()),
	/** The agents the Worker's registry lists. */
	agents: Type.Array(Type.Object({ id: Type.String(), name: Type.String(), avatar: Type.Optional(Type.String()), deployedAt: Type.String() })),
});
export type CloudStatus = Static<typeof CloudStatus>;

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
	/**
	 * A subagent's session: the parent session and the `task` call that started it; its state (queued while 3 others
	 * of its parent run, docs/spec/17 §3) and, while it works, a line on what it's doing.
	 */
	parent: Type.Optional(Type.Object({ id: Type.String(), callId: Type.String(), state: Type.Optional(literals("queued", "working", "done", "failed", "stopped")), line: Type.Optional(Type.String()) })),
	/** A helper's session (docs/spec/26 CL4): made by Piopio for a task on a project's board; not listed with yours. */
	helper: Type.Optional(Type.Object({ project: Type.String(), kind: literals("build", "review"), taskId: Type.String() })),
	/**
	 * A side conversation (docs/spec/24): the conversation it was started from, how (asked in words, or by hand with
	 * /side), its state (queued while 4 others of its parent run), and while it works, a line on what it's doing.
	 */
	side: Type.Optional(Type.Object({ parent: Type.Object({ id: Type.String(), title: Type.String() }), how: literals("asked", "manual", "offered", "proposed"), state: literals("queued", "working", "needs_you", "done", "failed", "stopped"), line: Type.Optional(Type.String()), from: Type.Optional(Type.String({ description: "The tool call that started it (side_start, an offer's or a proposal's), for its line in the parent's transcript" })) })),
	/** Side conversations Piopio proposed from here (docs/spec/24 §3): each a card you may start, until it expires. */
	sideProposals: Type.Optional(Type.Array(Type.Object({ id: Type.String(), title: Type.String(), why: Type.String(), project: Type.Optional(Type.String()), expiresAt: Type.String() }))),
	/** Its pull request (docs/spec/05-build G6–G7): the conversation that created it owns it. */
	pr: Type.Optional(Type.Object({ repo: Type.String(), number: Type.Number(), url: Type.String(), title: Type.String(), head: Type.String(), base: Type.String(), state: literals("open", "closed", "merged"), checks: Type.Optional(literals("pending", "passing", "failing", "none")) })),
	/** A chat continued in a project folder (18 §5): the new conversation, and in it, where it came from. */
	continuedIn: Type.Optional(Type.Object({ id: Type.String(), title: Type.String() })),
	continuedFrom: Type.Optional(Type.Object({ id: Type.String(), title: Type.String() })),
	/** Agents. Refs to a person's conversation carry `conversationId: "person:<contactId>"`. */
	agent: Type.Optional(AgentInfo),
	/** Threads and sessions: next messages the utility model suggests after the latest answer (until you write). */
	followUps: Type.Optional(Type.Array(Type.String())),
	/**
	 * Tools turned off in this conversation only (docs/design/session-panel, step 3): "connector:<id>" for a connected
	 * app, "mcp:<server>" for an MCP server. Settings decides what's on; this can only take things away.
	 */
	toolsOff: Type.Optional(Type.Array(Type.String())),
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
	/** Its tools are offered in chats and Build (agents always get them). */
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

/**
 * A project (docs/spec/18 §3, CF4): a folder on the Mac. One the user opened (05-build BP1), or one New project made in
 * ~/Piopio with an AGENTS.md and a NOTES.md.
 */
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
	/** What a conversation hears about its pull request (docs/spec/17 §5): off, tell (a notification, default) or act (a follow-up it works on). */
	prEvents: Type.Optional(literals("off", "tell", "act")),
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
	/**
	 * Other folders on the Mac linked to the project (docs/spec/18 §18): every conversation here is told about them and
	 * @ finds their files. `edit`: they follow the project's permissions like its own folder; otherwise read only.
	 */
	folders: Type.Optional(Type.Array(Type.Object({ path: Type.String(), edit: Type.Boolean(), missing: Type.Optional(Type.Boolean()) }))),
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
	/** Global servers: chats use it too. */
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
	/** Lines added and removed against HEAD (untracked: the file's lines); absent for binary files. */
	added: Type.Optional(Type.Number()),
	removed: Type.Optional(Type.Number()),
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

/**
 * A project's work (docs/spec/26): its way of working, its board and its branch. Every conversation in a project is
 * with Piopio, which puts parallel work on the board for helpers it makes (a kind, a brief, a model).
 */
export const WorkTask = Type.Object({
	id: Type.String(),
	title: Type.String(),
	brief: Type.String(),
	done: Type.Optional(Type.String()),
	helper: Type.String({ description: "What the helper is called on the board: “Builder”, “Researcher”" }),
	state: literals("todo", "doing", "review", "integrating", "done", "blocked"),
	by: literals("piopio", "you"),
	conversationId: Type.Optional(Type.String({ description: "The conversation that made it; its updates go there" })),
	sessionId: Type.Optional(Type.String()),
	reviewSessionId: Type.Optional(Type.String()),
	branch: Type.Optional(Type.String()),
	cwd: Type.Optional(Type.String()),
	report: Type.Optional(Type.String()),
	review: Type.Optional(Type.String()),
	attempts: Type.Number(),
	blocked: Type.Optional(Type.String()),
	landed: Type.Optional(Type.String({ description: "When its work was merged into the project's branch" })),
	createdAt: Type.String(),
	updatedAt: Type.String(),
});
export type WorkTask = Static<typeof WorkTask>;
/** A pull request as Piopio sees it (docs/spec/05-build G7): state, checks and the comments on it. */
export const PrStatus = Type.Object({
	repo: Type.String(),
	number: Type.Number(),
	url: Type.String(),
	title: Type.String(),
	state: literals("open", "closed", "merged"),
	draft: Type.Boolean(),
	head: Type.String(),
	base: Type.String(),
	headSha: Type.String(),
	summary: literals("pending", "passing", "failing", "none"),
	checks: Type.Array(Type.Object({ name: Type.String(), status: literals("queued", "in_progress", "completed"), conclusion: Type.Optional(Type.String()), url: Type.Optional(Type.String()), jobId: Type.Optional(Type.Number()) })),
	comments: Type.Array(Type.Object({ id: Type.String(), author: Type.String(), bot: Type.Boolean(), body: Type.String(), at: Type.String(), url: Type.Optional(Type.String()), path: Type.Optional(Type.String()), line: Type.Optional(Type.Number()), kind: literals("review", "comment", "verdict") })),
});
export type PrStatus = Static<typeof PrStatus>;
/** What the project's work branch would bring to its branch (the merge card). */
export const WorkLanding = Type.Object({
	base: Type.String(),
	branch: Type.String(),
	ahead: Type.Number(),
	behind: Type.Number(),
	files: Type.Array(Type.Object({ path: Type.String(), added: Type.Number(), removed: Type.Number() })),
	tasks: Type.Array(Type.Object({ id: Type.String(), title: Type.String() })),
	open: Type.Number(),
	checkedOut: Type.Optional(Type.String()),
	remote: Type.Optional(Type.String()),
	compareUrl: Type.Optional(Type.String()),
});
export type WorkLanding = Static<typeof WorkLanding>;
/**
 * An automation (docs/spec/27): work that starts when nobody started it. A trigger (a time, an email, a file in a
 * folder, a URL), who runs it (Piopio or an agent), the prompt, a project (Piopio only), where the result goes, and
 * what it may do while you're away.
 */
export const Automation = Type.Object({
	id: Type.String(),
	name: Type.String(),
	on: literals("time", "folder", "email", "webhook"),
	cron: Type.Optional(Type.String()),
	at: Type.Optional(Type.Number({ description: "time, once: epoch ms" })),
	tz: Type.Optional(Type.String()),
	folder: Type.Optional(Type.String()),
	from: Type.Optional(Type.String()),
	subject: Type.Optional(Type.String()),
	runsAs: Type.String({ description: "“piopio”, or an agent's id" }),
	project: Type.Optional(Type.String({ description: "A project's id; only when Piopio runs it" })),
	prompt: Type.String(),
	result: literals("chat", "telegram", "conversation", "quiet"),
	deliverTo: Type.Optional(Type.String({ description: "An agent's contact the result is for (default its owner)" })),
	approval: literals("wait", "skip"),
	budgetPerRunUsd: Type.Optional(Type.Number()),
	enabled: Type.Boolean(),
	by: Type.String({ description: "“you”, “piopio”, or the agent that made it" }),
	createdAt: Type.String(),
	next: Type.Optional(Type.Number({ description: "time: the next run, epoch ms" })),
	lastRun: Type.Optional(Type.String()),
	runCount: Type.Number(),
	fresh: Type.Optional(Type.Boolean({ description: "Not opened since it was made (the list's “New” badge)" })),
	aliases: Type.Optional(Type.Array(Type.String())),
	/** Words for the app. */
	label: Type.String({ description: "“Every Monday at 09:00”, “When a file appears in ~/Inbox”" }),
	runnerName: Type.String({ description: "“Piopio”, “Piopio in shop”, “Rita”" }),
	resultLabel: Type.String({ description: "“Rita’s chat”, “Telegram”, “A conversation in shop”, “Only if it needs you”" }),
	url: Type.Optional(Type.String({ description: "webhook: where to POST" })),
	lastStatus: Type.Optional(literals("running", "done", "quiet", "waiting", "skipped", "failed")),
	lastSummary: Type.Optional(Type.String()),
});
export type Automation = Static<typeof Automation>;
export const AutomationRun = Type.Object({
	id: Type.String(),
	automation: Type.String(),
	firedAt: Type.String(),
	cause: literals("time", "event", "now"),
	status: literals("running", "done", "quiet", "waiting", "skipped", "failed"),
	summary: Type.Optional(Type.String()),
	costUsd: Type.Optional(Type.Number()),
	/** A Piopio run's conversation (a session id), or an agent's run (`run:<id>`, opened in that agent). */
	conversation: Type.Optional(Type.String()),
	agent: Type.Optional(Type.String()),
	agentRun: Type.Optional(Type.String()),
});
export type AutomationRun = Static<typeof AutomationRun>;
/** What `automations.add` and `automations.update` take: the trigger in words (`when`), the rest as the record. */
export const AutomationChange = Type.Object({
	name: Type.Optional(Type.String()),
	on: Type.Optional(literals("time", "folder", "email", "webhook")),
	when: Type.Optional(Type.String({ description: "time: a 5-field cron, or a local date-time once" })),
	folder: Type.Optional(Type.String()),
	from: Type.Optional(Type.String()),
	subject: Type.Optional(Type.String()),
	runsAs: Type.Optional(Type.String()),
	project: Type.Optional(Type.Union([Type.String(), Type.Null()])),
	prompt: Type.Optional(Type.String()),
	result: Type.Optional(literals("chat", "telegram", "conversation", "quiet")),
	approval: Type.Optional(literals("wait", "skip")),
	budgetPerRunUsd: Type.Optional(Type.Union([Type.Number(), Type.Null()])),
	enabled: Type.Optional(Type.Boolean()),
});
export type AutomationChange = Static<typeof AutomationChange>;
/** How work is done in a project (docs/spec/26 §4). */
export const WayOfWorking = Type.Object({
	parallel: Type.Boolean({ description: "Piopio may split work onto the board" }),
	review: Type.Boolean({ description: "Every task is reviewed by a helper with fresh eyes" }),
	reviewLimit: Type.Number({ description: "Times a task may be sent back before you're asked" }),
	testCommand: Type.Optional(Type.String({ description: "The checks, run after each merge" })),
	maxParallel: Type.Number({ description: "Tasks at once" }),
	buildModel: Type.Optional(Type.String({ description: "The helpers' model for doing tasks; unset: the project's" })),
	reviewModel: Type.Optional(Type.String({ description: "The reviewers' model; unset: the build model" })),
	helperMode: ApprovalMode,
	budgetPerJob: Type.Optional(Type.Number({ description: "USD one conversation's tasks may spend" })),
	playbook: Type.String({ description: "The playbook Piopio plans with: development, research, writing, or a project's own" }),
});
export type WayOfWorking = Static<typeof WayOfWorking>;
export const WorkInfo = Type.Object({
	project: Type.String(),
	cwd: Type.String(),
	way: WayOfWorking,
	git: Type.Optional(Type.Object({ base: Type.String(), branch: Type.String(), integration: Type.String() })),
	tasks: Type.Array(WorkTask),
	createdAt: Type.String(),
});
export type WorkInfo = Static<typeof WorkInfo>;

export const GitBranch = Type.Object({ name: Type.String(), upstream: Type.Optional(Type.String()), lastCommitAt: Type.Optional(Type.String()), current: Type.Boolean() });
export type GitBranch = Static<typeof GitBranch>;
export const GitCommitFile = Type.Object({ path: Type.String(), added: Type.Number(), removed: Type.Number() });
export type GitCommitFile = Static<typeof GitCommitFile>;
/** A commit on the current branch (a session's results: what was committed since it started), with the files it touched. */
export const GitCommit = Type.Object({ hash: Type.String(), subject: Type.String(), at: Type.String(), files: Type.Optional(Type.Array(GitCommitFile)) });
export type GitCommit = Static<typeof GitCommit>;

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
			/** Reverse requests this client answers besides `secrets.get` (§3.12): `app.tool`, `secrets.set` (also `secrets.delete`); `browser` when its `app.tool` runs the browser tools (22-browser). */
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
	/**
	 * Continue a chat in a project folder (18 §5): a new conversation there that starts with the chat's active branch
	 * (text, one line per tool call, images). The chat stays, linked to it. Nothing is sent to the model yet.
	 */
	"sessions.continueIn": {
		params: Type.Object({ ref: ContainerRef, cwd: Type.String(), approvalMode: Type.Optional(ApprovalMode) }),
		result: Type.Object({ ref: ContainerRef }),
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
			planMode: Type.Optional(Type.Boolean()),
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
		params: Type.Object({ ref: ContainerRef, itemId: Type.String(), text: Type.String(), clientRequestId: Type.Optional(Type.String()) }),
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
	"sessions.export": {
		params: Type.Object({ ref: ContainerRef, format: literals("markdown", "html", "jsonl") }),
		/** `visuals`: the ones the export shows, by tool call, so the app can draw them without the conversation open. */
		result: Type.Object({ filename: Type.String(), mimeType: Type.String(), content: Type.String(), visuals: Type.Optional(Type.Array(Type.Object({ callId: Type.String(), title: Type.String(), html: Type.String() }))) }),
	},
	"sessions.configure": {
		/** `toolsOff` replaces the conversation's list (see SessionSummary.toolsOff). */
		params: Type.Object({ ref: ContainerRef, model: Type.Optional(ModelRef), thinking: Type.Optional(Type.String()), web: Type.Optional(Type.Boolean()), approvalMode: Type.Optional(ApprovalMode), planMode: Type.Optional(Type.Boolean()), toolsOff: Type.Optional(Type.Array(Type.String())) }),
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
		params: Type.Object({ query: Type.String(), limit: Type.Optional(Type.Number()), kind: Type.Optional(ContainerKind) }),
		result: Type.Object({
			results: Type.Array(Type.Object({ ref: ContainerRef, title: Type.String(), itemId: Type.Optional(Type.String()), kind: literals("title", "user", "assistant"), snippet: Type.String(), at: Type.String() })),
		}),
	},
	/** Gracefully stops the local process for offline backup/restore. */
	"engine.shutdown": { params: Type.Object({}), result: Type.Object({}) },
	"usage.extras": {
		params: Type.Object({ ref: Type.Optional(ContainerRef) }),
		result: Type.Object({ scope: Type.String(), knownUsd: Type.Number(), unknownCalls: Type.Number(), calls: Type.Number(), breakdown: Type.Array(Type.Object({ kind: Type.String(), calls: Type.Number(), knownUsd: Type.Number(), unknownCalls: Type.Number() })) }),
	},
	/** OpenRouter-key billing; includes other apps sharing that key. Cached a minute. */
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
	/** Whether Apple's on-device model can run on this Mac now (07-shared §1.3), and why not. */
	"models.onDevice": { params: Type.Object({}), result: Type.Object({ available: Type.Boolean(), reason: Type.Optional(Type.String()) }) },
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
	/** Answers a connector approval in a chat or Build session. `always`: don't ask again for that write. */
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
	/**
	 * New project (18 CF4): a folder in ~/Piopio named after it, with AGENTS.md (`instructions`, what every conversation
	 * there is told) and NOTES.md (what they keep for each other). Starts in Auto-edit.
	 */
	"projects.create": {
		params: Type.Object({ name: Type.String({ minLength: 1 }), instructions: Type.Optional(Type.String()) }),
		result: Type.Object({ project: ProjectInfo }),
	},
	/**
	 * Turn into an agent (18 phase 3): a draft for the Agent start page from a conversation's active branch: a name,
	 * instructions and, when the conversation said when, a schedule (a cron). Nothing is created.
	 */
	"sessions.agentDraft": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({ name: Type.String(), instructions: Type.String(), schedule: Type.Union([Type.String(), Type.Null()]) }),
	},
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
			/** Links a folder (absolute), or changes whether it can be edited when it's already linked (18 §18). */
			linkFolder: Type.Optional(Type.Object({ path: Type.String(), edit: Type.Boolean() })),
			/** Unlinks a folder (its path as `folders` lists it). Nothing on disk changes. */
			unlinkFolder: Type.Optional(Type.String()),
			prEvents: Type.Optional(literals("off", "tell", "act")),
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
	/** The current branch's commits, newest first: since `since` (ISO), at most `limit` (default 20, up to 100). */
	"git.log": { params: Type.Object({ cwd: Type.String(), since: Type.Optional(Type.String()), limit: Type.Optional(Type.Number()) }), result: Type.Object({ commits: Type.Array(GitCommit) }) },
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
		/** `source`: skills, the folder they were found in ("~/.agents/skills"), so the app can say where they come from. */
		result: Type.Object({ commands: Type.Array(Type.Object({ name: Type.String(), description: Type.String(), kind: literals("template", "skill", "extension"), hint: Type.Optional(Type.String()), source: Type.Optional(Type.String()) })) }),
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
	/** The browser's sites (docs/spec/22 §4.4): those you always allow the model to act on, and those you blocked. */
	"browser.sites": {
		params: Type.Object({}),
		result: Type.Object({ sites: Type.Array(Type.Object({ site: Type.String(), level: literals("allowed", "blocked") })) }),
	},
	/** Sets a site's level; "ask" removes it from both lists (the default: acting asks per conversation). */
	"browser.setSite": {
		params: Type.Object({ site: Type.String(), level: literals("allowed", "blocked", "ask") }),
		result: Type.Object({}),
	},
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
			/** Global servers: use in chats too. */
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
	/** A global server in chats, or not. */
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
	/**
	 * Build: back to just before one of your messages (docs/design chat v3, 14b). `files` also puts the project's
	 * files back as they were then; the message's text comes back for the composer. `dryRun` only says what changes.
	 */
	"sessions.rewind": {
		params: Type.Object({ ref: ContainerRef, itemId: Type.String(), files: Type.Boolean(), dryRun: Type.Optional(Type.Boolean()) }),
		result: Type.Object({ files: Type.Array(FileChange), turns: Type.Number(), editorText: Type.Optional(Type.String()) }),
	},
	/** Answers a pending prompt (approval, question, confirm, select, input). */
	"sessions.respond": {
		params: Type.Object({ ref: ContainerRef, promptId: Type.String(), response: PromptResponse }),
		result: Type.Object({}),
	},
	"settings.get": { params: Type.Object({}), result: EngineSettings },
	"settings.set": {
		params: Type.Object({ models: Type.Optional(Type.Object({ utility: Type.Optional(UtilityChoice) })), chat: Type.Optional(Type.Partial(EngineSettings.properties.chat)), aboutMe: Type.Optional(Type.Partial(EngineSettings.properties.aboutMe)), memory: Type.Optional(Type.Partial(EngineSettings.properties.memory)) }),
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
	/** Settings › Memory: every bank of the built-in provider, what it holds, and whose it is. */
	"memory.banks": {
		params: Type.Object({}),
		result: Type.Object({
			banks: Type.Array(
				Type.Object({
					bank: Type.String(),
					/** "About me", or the agent's partition: "Owner", "Shared", "María". */
					label: Type.String(),
					/** "about-me", "agent", "project" (a project without a folder), or "other" (its owner was deleted). */
					area: Type.String(),
					agent: Type.Optional(Type.Object({ id: Type.String(), name: Type.String(), avatar: Type.Optional(Type.String()), learns: Type.Boolean() })),
					records: Type.Number(),
					facts: Type.Number(),
					messages: Type.Number(),
					ended: Type.Number(),
					updatedAt: Type.Optional(Type.String()),
				}),
			),
			/** Agents that use memory, with or without records yet (for the learning switches). */
			agents: Type.Array(Type.Object({ id: Type.String(), name: Type.String(), avatar: Type.Optional(Type.String()), learns: Type.Boolean(), provider: Type.String() })),
			bytes: Type.Number(),
		}),
	},
	/** A bank's changes, newest first. */
	"memory.history": {
		params: Type.Object({ provider: Type.String(), bank: Type.String(), limit: Type.Optional(Type.Number()) }),
		result: Type.Object({ events: Type.Array(Type.Object({ id: Type.String(), at: Type.String(), action: Type.String(), recordId: Type.String(), text: Type.String(), by: Type.String() })) }),
	},
	/** Writes everything the built-in provider holds to `folder` as memory.json and memory.md. */
	"memory.export": { params: Type.Object({ folder: Type.String() }), result: Type.Object({ files: Type.Array(Type.String()), records: Type.Number() }) },
	/** Deletes one bank, or every bank with "*". */
	"memory.wipe": { params: Type.Object({ bank: Type.String() }), result: Type.Object({ records: Type.Number() }) },
	/** Embeds again what has no vector from the current model (in the background); how many records wait. */
	"memory.reindex": { params: Type.Object({}), result: Type.Object({ pending: Type.Number() }) },
	/** An agent learns facts by itself, or only stores what was said (its definition's memory.learn). */
	"memory.setLearning": { params: Type.Object({ ref: ContainerRef, learn: Type.Boolean() }), result: Type.Object({}) },
	/** The built-in provider's semantic search: on or why not, the embedding model and how much is indexed. */
	"memory.status": {
		params: Type.Object({}),
		result: Type.Object({
			semantic: Type.Boolean(),
			/** Why semantic search is off: "off" (words only, the default), "no_key", or "failing" (with `error`). */
			reason: Type.Optional(Type.String()),
			error: Type.Optional(Type.String()),
			model: Type.Optional(Type.String()),
			/** Who computes the embeddings: "OpenRouter", "OpenAI API", or a server's address. */
			via: Type.Optional(Type.String()),
			records: Type.Number(),
			indexed: Type.Number(),
		}),
	},
	/** Try a provider: what it recalls for a query in a bank. */
	"memory.recall": {
		params: Type.Object({ provider: Type.String(), bank: Type.String(), query: Type.String() }),
		result: Type.Object({ hits: Type.Array(Type.Object({ id: Type.String(), text: Type.String(), score: Type.Number(), at: Type.Optional(Type.String()) })) }),
	},
	/** pi packages (Settings › Extensions). */
	"packages.list": { params: Type.Object({}), result: Type.Object({ packages: Type.Array(PiPackage) }) },
	"packages.install": { params: Type.Object({ source: Type.String() }), result: Type.Object({}) },
	"packages.remove": { params: Type.Object({ source: Type.String() }), result: Type.Object({}) },
	"packages.update": { params: Type.Object({ source: Type.Optional(Type.String()) }), result: Type.Object({}) },
	"packages.preview": { params: Type.Object({ source: Type.String() }), result: PackagePreview },
	/** One resource (by its path, as `packages.list` gives it) on or off. */
	"packages.setResource": {
		params: Type.Object({ source: Type.String(), kind: literals("extensions", "skills", "prompts", "themes"), path: Type.String(), enabled: Type.Boolean() }),
		result: Type.Object({}),
	},
	"packages.setEnabled": {
		params: Type.Object({ source: Type.String(), enabled: Type.Boolean(), kinds: Type.Optional(Type.Array(literals("extensions", "skills", "prompts", "themes"))) }),
		result: Type.Object({}),
	},
	/** Agents (06-agents §2, §11). */
	"agents.templates": {
		params: Type.Object({}),
		/** `instructions` may contain "{owner}"; `schedule` is the first schedule's cron, when the template has one. */
		result: Type.Object({ templates: Type.Array(Type.Object({ id: Type.String(), name: Type.String(), avatar: Type.String(), description: Type.String(), instructions: Type.String(), schedule: Type.Optional(Type.String()) })) }),
	},
	"agents.create": {
		/** `instructions` replaces the template's; `schedule` (a cron, or null for none) replaces its first schedule. */
		params: Type.Object({ name: Type.String(), template: Type.Optional(Type.String()), avatar: Type.Optional(Type.String()), model: Type.Optional(ModelRef), owner: Type.Optional(Type.String()), instructions: Type.Optional(Type.String()), schedule: Type.Optional(Type.Union([Type.String(), Type.Null()])) }),
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
	/**
	 * Home's agenda (docs/spec/21 D2): today's timeline (runs, what's next, event routines and work in progress) across
	 * agents and projects, and what happened since `since` (your last visit), one line per agent or project.
	 */
	"home.agenda": {
		params: Type.Object({ since: Type.Optional(Type.String()) }),
		result: Type.Object({
			today: Type.Array(Type.Object({ at: Type.Optional(Type.String()), label: Type.String(), source: Type.Object({ kind: literals("agent", "project", "piopio"), id: Type.String(), name: Type.String() }), automation: Type.Optional(Type.String({ description: "The automation it belongs to (docs/spec/27)" })), state: literals("done", "failed", "skipped", "running", "upcoming", "event"), tomorrow: Type.Optional(Type.Boolean({ description: "Upcoming after midnight, within the next 24 hours" })) })),
			away: Type.Array(Type.Object({ at: Type.String(), source: Type.Object({ kind: literals("agent", "project", "piopio"), id: Type.String(), name: Type.String() }), automation: Type.Optional(Type.String({ description: "The automation it belongs to (docs/spec/27)" })), text: Type.String(), costUsd: Type.Optional(Type.Number()), quiet: Type.Boolean(), failed: Type.Optional(Type.Boolean()) })),
			held: Type.Number({ description: "Messages held by quiet hours or limits, across agents" }),
		}),
	},
	/** Every project's work (docs/spec/26): its way of working, board and branch. */
	/**
	 * Your answer to a side card (docs/spec/24 §1): an offer's New conversation ("new") or Do it here ("here"), a
	 * proposal's Start or Dismiss. `askAlways` after three New in a row: offer "Don't ask again" (SCQ3).
	 */
	"sessions.side.answer": { params: Type.Object({ ref: ContainerRef, id: Type.String({ description: "The offer's or proposal's tool call id" }), choice: literals("new", "here", "start", "dismiss") }), result: Type.Object({ ref: Type.Optional(ContainerRef), askAlways: Type.Optional(Type.Boolean()) }) },
	/** GitHub (docs/spec/05-build G4): signed in or not, how (`gh` or a token you added), and as whom. */
	"github.status": { params: Type.Object({}), result: Type.Object({ connected: Type.Boolean(), via: Type.Optional(literals("gh", "token")), login: Type.Optional(Type.String()), error: Type.Optional(Type.String()) }) },
	/** A personal access token, checked, then kept in the app's Keychain. */
	"github.setToken": { params: Type.Object({ token: Type.String({ minLength: 1 }) }), result: Type.Object({ login: Type.String() }) },
	"github.signOut": { params: Type.Object({}), result: Type.Object({}) },
	/** Your repositories, most recently updated first (G5). */
	"github.repos": { params: Type.Object({}), result: Type.Object({ repos: Type.Array(Type.Object({ fullName: Type.String(), description: Type.Optional(Type.String()), private: Type.Boolean(), cloneUrl: Type.String(), updatedAt: Type.String(), defaultBranch: Type.String() })) }) },
	/** Clones owner/name (or a URL) into ~/Piopio/<name> or `path`, and adds it as a project (G5). */
	"github.clone": { params: Type.Object({ repo: Type.String(), path: Type.Optional(Type.String()) }), result: Type.Object({ project: ProjectInfo }) },
	/** A title and body for this conversation's pull request, from what it did and its diff (G6), and the branches. */
	"sessions.pr.draft": { params: Type.Object({ ref: ContainerRef }), result: Type.Object({ title: Type.String(), body: Type.String(), head: Type.String(), base: Type.String() }) },
	/** Pushes the conversation's branch and opens its pull request, linked to it (G6). */
	"sessions.pr.create": { params: Type.Object({ ref: ContainerRef, title: Type.String(), body: Type.String(), base: Type.Optional(Type.String()), draft: Type.Optional(Type.Boolean()) }), result: Type.Object({ pr: PrStatus }) },
	/** Its pull request now: state, checks and comments (G7). */
	"sessions.pr.get": { params: Type.Object({ ref: ContainerRef }), result: Type.Object({ pr: PrStatus }) },
	/** Hands the review comments, or the failing checks' logs, to the conversation as a follow-up (G7, G8). */
	"sessions.pr.address": { params: Type.Object({ ref: ContainerRef, what: literals("comments", "ci") }), result: Type.Object({}) },
	/** A side conversation by hand (docs/spec/24 §6, `/side <what>`): your words are its brief. */
	"sessions.side.start": { params: Type.Object({ ref: ContainerRef, brief: Type.String({ minLength: 1 }), title: Type.Optional(Type.String()) }), result: Type.Object({ ref: ContainerRef }) },
	"work.list": { params: Type.Object({}), result: Type.Object({ work: Type.Array(WorkInfo) }) },
	/** A project's work; none until parallel work was first switched on there. */
	"work.get": { params: Type.Object({ project: Type.String() }), result: Type.Object({ work: Type.Optional(WorkInfo) }) },
	/**
	 * How work is done here (docs/spec/26 §4). Switching parallel work on the first time runs the fit check and prefills
	 * the checks. null clears an optional field.
	 */
	"work.configure": {
		params: Type.Object({
			project: Type.String(),
			parallel: Type.Optional(Type.Boolean()),
			review: Type.Optional(Type.Boolean()),
			reviewLimit: Type.Optional(Type.Number({ minimum: 1, maximum: 10 })),
			testCommand: Type.Optional(Type.String({ description: "Empty removes it" })),
			maxParallel: Type.Optional(Type.Number({ minimum: 1, maximum: 8 })),
			buildModel: Type.Optional(Type.Union([Type.String(), Type.Null()])),
			reviewModel: Type.Optional(Type.Union([Type.String(), Type.Null()])),
			helperMode: Type.Optional(ApprovalMode),
			budgetPerJob: Type.Optional(Type.Union([Type.Number({ minimum: 0 }), Type.Null()])),
			playbook: Type.Optional(Type.String()),
			initGit: Type.Optional(Type.Boolean({ description: "A folder without git: make it a repo first, so tasks get branches" })),
		}),
		result: Type.Object({ work: WorkInfo }),
	},
	/** "Work in parallel" on Piopio's offer (docs/spec/26 CL9): parallel work goes on, and that conversation plans it. */
	"work.accept": { params: Type.Object({ project: Type.String(), sessionId: Type.String() }), result: Type.Object({ work: WorkInfo }) },
	/** The playbooks a project can plan with: built in, and the project's own (docs/spec/26 CL6). */
	"work.playbooks": { params: Type.Object({ project: Type.String() }), result: Type.Object({ playbooks: Type.Array(Type.Object({ id: Type.String(), name: Type.String(), description: Type.String(), source: literals("builtin", "project") })) }) },
	/** What parallel work needs in a project (docs/spec/21 D6): git, checks it can run, AGENTS.md. */
	"work.fitCheck": {
		params: Type.Object({ cwd: Type.String() }),
		result: Type.Object({ git: Type.Boolean(), checks: Type.Optional(Type.String({ description: "The test command found in the folder" })), agentsMd: Type.Boolean(), language: Type.Optional(Type.String()) }),
	},
	/** What a conversation's tasks have cost (a job), against the budget per job. */
	"work.job": { params: Type.Object({ project: Type.String(), conversationId: Type.String() }), result: Type.Object({ cost: Type.Number(), tasks: Type.Number(), budget: Type.Optional(Type.Number()) }) },
	/** You add a card to the board. */
	"work.addTask": { params: Type.Object({ project: Type.String(), title: Type.String(), brief: Type.String(), done: Type.Optional(Type.String()) }), result: Type.Object({ task: WorkTask }) },
	/** You move or edit a card. */
	"work.updateTask": { params: Type.Object({ project: Type.String(), taskId: Type.String(), state: Type.Optional(literals("todo", "blocked", "done")), title: Type.Optional(Type.String()), brief: Type.Optional(Type.String()) }), result: Type.Object({}) },
	/** What the project's work branch would bring to its branch. */
	"work.landing": { params: Type.Object({ project: Type.String() }), result: WorkLanding },
	/** You land the work: merge the work branch into the project's, or push it for a pull request. */
	"work.land": { params: Type.Object({ project: Type.String(), action: literals("merge", "push") }), result: Type.Object({ commit: Type.Optional(Type.String()), compareUrl: Type.Optional(Type.String()), output: Type.Optional(Type.String()) }) },
	/** The project's work branch as a pull request into its base (G6 from the Board). */
	"work.createPR": { params: Type.Object({ project: Type.String(), title: Type.String(), body: Type.String(), draft: Type.Optional(Type.Boolean()) }), result: Type.Object({ pr: PrStatus }) },
	/** What changed when teams became projects' ways of working (docs/spec/26 §8): shown once, until dismissed. */
	"work.migrationReport": { params: Type.Object({}), result: Type.Object({ report: Type.Optional(Type.String({ description: "Markdown" })) }) },
	"work.dismissMigrationReport": { params: Type.Object({}), result: Type.Object({}) },
	/** Automations (docs/spec/27): every one, or those a runner or a project has. */
	"automations.list": {
		params: Type.Object({ runsAs: Type.Optional(Type.String()), project: Type.Optional(Type.String()) }),
		result: Type.Object({ automations: Type.Array(Automation) }),
	},
	/** One, its latest runs, and the card's words. Opening it clears its “New” badge. */
	"automations.get": {
		params: Type.Object({ id: Type.String() }),
		result: Type.Object({ automation: Automation, runs: Type.Array(AutomationRun), summary: AutomationSummary }),
	},
	"automations.add": { params: Type.Intersect([AutomationChange, Type.Object({ prompt: Type.String() })]), result: Type.Object({ automation: Automation }) },
	"automations.update": { params: Type.Intersect([Type.Object({ id: Type.String() }), AutomationChange]), result: Type.Object({ automation: Automation }) },
	"automations.remove": { params: Type.Object({ id: Type.String() }), result: Type.Object({}) },
	/** Redo after Undo (a creation card): one removed since the engine started comes back as it was. */
	"automations.restore": { params: Type.Object({ id: Type.String() }), result: Type.Object({ automation: Automation }) },
	/** Run now: a run even while it's paused. */
	"automations.run": { params: Type.Object({ id: Type.String() }), result: Type.Object({ run: AutomationRun }) },
	"automations.runs": { params: Type.Object({ id: Type.Optional(Type.String()), limit: Type.Optional(Type.Number()) }), result: Type.Object({ runs: Type.Array(AutomationRun) }) },
	/** What changed when schedules, watches and routines became automations (docs/spec/27 §6): shown until dismissed. */
	"automations.migrationReport": { params: Type.Object({}), result: Type.Object({ report: Type.Optional(Type.String({ description: "Markdown" })) }) },
	"automations.dismissMigrationReport": { params: Type.Object({}), result: Type.Object({}) },
	/** Runs: schedules, heartbeat, reminders, triggers and manual runs, newest first (06 §6, Runs tab). Open one with `conversationId: "run:<id>"`. */
	"agents.runs": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({
			runs: Type.Array(
				Type.Object({
					id: Type.String(),
					kind: literals("schedule", "heartbeat", "reminder", "trigger", "manual", "automation"),
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
			upcoming: Type.Array(Type.Object({ id: Type.String(), kind: literals("schedule", "heartbeat", "reminder", "watch"), label: Type.String(), next: Type.Optional(Type.String()), cron: Type.Optional(Type.String({ description: "A repeating one's cron" })) })),
		}),
	},
	/** Run now: a schedule from the definition (its prompt), or any prompt. */
	"agents.runNow": {
		params: Type.Object({ ref: ContainerRef, scheduleId: Type.Optional(Type.String()), prompt: Type.Optional(Type.String()), trial: Type.Optional(Type.Boolean({ description: "A trial run right after it's set up (docs/spec/21 D4)" })) }),
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
	/** The Watchdog's notes about your conversations (docs/spec/17 §4): stuck, repeating itself. In Needs you until dismissed or the conversation moves on. */
	"watchdog.list": {
		params: Type.Object({}),
		result: Type.Object({ notes: Type.Array(Type.Object({ id: Type.String(), ref: ContainerRef, title: Type.String(), rule: literals("silent", "looping", "waiting"), text: Type.String(), at: Type.String() })) }),
	},
	"watchdog.dismiss": { params: Type.Object({ id: Type.String() }), result: Type.Object({}) },
	"inbox.read": {
		params: Type.Object({ items: Type.Array(Type.Object({ agentId: Type.String(), id: Type.String() })) }),
		result: Type.Object({}),
	},
	/**
	 * Where an agent runs (docs/spec/30 §3.2, K1): up to your cloud, or back to this Mac. Its definition, instructions,
	 * memory, time automations and reminders move; `lines` says what moved and what couldn't (events need the Mac).
	 */
	"agents.move": {
		params: Type.Object({ ref: ContainerRef, to: literals("cloud", "local") }),
		result: Type.Object({ lines: Type.Array(Type.String()) }),
	},
	/** The cloud engine (docs/spec/30 K1): the Mac's engine sends an agent up as data, with no Worker redeploy. */
	"agents.deploy": {
		params: Type.Object({ ref: ContainerRef, definition: Type.Unknown(), instructions: Type.String(), memory: Type.Optional(Type.Array(CloudMemory)), reminders: Type.Optional(Type.Array(Type.Unknown())), telegram: Type.Optional(Type.Object({ token: Type.String() })) }),
		result: Type.Object({ deployedAt: Type.String(), lines: Type.Array(Type.String()) }),
	},
	/** The cloud engine: everything an agent has, to bring it back to the Mac (read only; `agents.retire` ends it there). */
	"agents.export": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({ definition: Type.Unknown(), instructions: Type.String(), memory: Type.Array(CloudMemory), reminders: Type.Array(Type.Unknown()), telegram: Type.Optional(Type.Object({ token: Type.String() })) }),
	},
	/** The cloud engine: paused, this month's spend and budget, Inbox items waiting, and what fires next (the catalog's `agent.status`). */
	"agents.status": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({ paused: Type.Boolean(), spendUsd: Type.Number(), budgetUsd: Type.Optional(Type.Number()), inbox: Type.Number(), nextRun: Type.Optional(Type.String()) }),
	},
	/** The cloud engine: the agent stops there and its data is deleted (after `agents.export` was saved on the Mac). */
	"agents.retire": { params: Type.Object({ ref: ContainerRef }), result: Type.Object({}) },
	/** Your cloud (Settings › This Mac & cloud, docs/spec/30 K1): connected or not, and what's up there. */
	"cloud.status": { params: Type.Object({}), result: CloudStatus },
	/** Connects to a Worker already deployed: its address and owner token (checked before anything is saved). */
	"cloud.connect": { params: Type.Object({ url: Type.String(), token: Type.String() }), result: CloudStatus },
	/** Forgets the cloud on this Mac. Refused while agents run there (move them back first). */
	"cloud.disconnect": { params: Type.Object({}), result: Type.Object({}) },
	/** The agent's memory: its provider and partitions, each a bank (06 §8). */
	"agents.memory": {
		params: Type.Object({ ref: ContainerRef }),
		result: Type.Object({ provider: Type.String(), partitions: Type.Array(Type.Object({ id: Type.String(), label: Type.String(), bank: Type.String() })) }),
	},
	/** A memory provider's records (the memory views). */
	"memory.list": {
		params: Type.Object({
			provider: Type.String(),
			bank: Type.String(),
			cursor: Type.Optional(Type.String()),
			kinds: Type.Optional(Type.Array(Type.String())),
			/** Replaced and ended facts too (the history of learned facts, M2). */
			includeEnded: Type.Optional(Type.Boolean()),
			/** Search instead of listing: the best matches, current records only. */
			query: Type.Optional(Type.String()),
		}),
		result: Type.Object({
			records: Type.Array(
				Type.Object({
					id: Type.String(),
					text: Type.String(),
					kind: Type.String(),
					createdBy: Type.String(),
					at: Type.String(),
					pinned: Type.Optional(Type.Boolean()),
					source: Type.Optional(Type.Object({ ref: Type.Optional(Type.String()), itemId: Type.Optional(Type.String()), title: Type.Optional(Type.String()) })),
					replaces: Type.Optional(Type.String()),
					replacedBy: Type.Optional(Type.String()),
					endedAt: Type.Optional(Type.String()),
				}),
			),
			cursor: Type.Optional(Type.String()),
			limited: Type.Boolean(),
		}),
	},
	/** A fact written by you; with `replaces`, it updates that fact and keeps it as history. */
	"memory.add": { params: Type.Object({ provider: Type.String(), bank: Type.String(), text: Type.String(), replaces: Type.Optional(Type.String()) }), result: Type.Object({}) },
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
	 * A tool only the Mac app can run with the user's permissions: Apple apps for agents (06-agents §4.1), the browser
	 * for conversations and Build (22-browser §8). The app checks `groups` (and `shortcuts`) again. `agent` asks for an
	 * agent; `ref` for a conversation or Build session (the browser keeps tabs per `ref`). `undo` is the call that
	 * reverses a change (§4.2); `images` are screenshots the model sees.
	 */
	"app.tool": {
		params: Type.Object({
			name: Type.String(),
			args: Type.Unknown(),
			agent: Type.Optional(Type.Object({ id: Type.String(), name: Type.String() })),
			ref: Type.Optional(ContainerRef),
			/** Browser: the sites (registrable domains) the model may act on now (22 §4.1). */
			sites: Type.Optional(Type.Array(Type.String())),
			groups: Type.Array(Type.String()),
			shortcuts: Type.Array(Type.String()),
		}),
		result: Type.Object({
			ok: Type.Boolean(),
			/** What the model reads. */
			output: Type.String(),
			images: Type.Optional(Type.Array(Type.Object({ mimeType: Type.String(), data: Type.String() }))),
			/** Browser: nothing was done; acting needs the user's permission for this site first. */
			needsSite: Type.Optional(Type.String()),
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
	/** The Watchdog's notes changed (docs/spec/17 §4): list them again. */
	"watchdog.changed": Type.Object({}),
	/** The Inbox changed; `count` is what waits for you (badges). `approval` is set when an agent asks (notifications). */
	/** A step of a provider sign-in started with `providers.login`. */
	"providers.auth": Type.Object({ loginId: Type.String(), provider: Type.String(), event: ProviderAuthEvent }),
	/** A step of signing in to an app started with `connectors.connect`. */
	"connectors.auth": Type.Object({ loginId: Type.String(), connector: Type.String(), event: ProviderAuthEvent }),
	/** Connected apps changed (accounts, settings, needs sign-in): list them again. */
	"connectors.changed": Type.Object({}),
	/** Providers or their models changed (connected, disconnected, needs attention): list them again. */
	"providers.changed": Type.Object({}),
	/** A project's work or its board changed (docs/spec/26). */
	"work.changed": Type.Object({ project: Type.String() }),
	/** An automation or one of its runs changed (docs/spec/27): list them again. */
	"automations.changed": Type.Object({}),
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
