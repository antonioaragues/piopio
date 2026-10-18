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
]);
export type ToolDetails = Static<typeof ToolDetails>;

export const UserItem = Type.Object({
	kind: Type.Literal("user"),
	id: Type.String(),
	at: Type.String(),
	text: Type.String(),
});
export const AssistantItem = Type.Object({
	kind: Type.Literal("assistant"),
	id: Type.String(),
	at: Type.String(),
	parts: Type.Array(AssistantPart),
	model: Type.Optional(Type.String()),
	usage: Type.Optional(Usage),
	status: literals("streaming", "done", "error", "aborted"),
	error: Type.Optional(Type.String()),
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

export const TimelineItem = Type.Union([UserItem, AssistantItem, ToolItem, SystemItem, CompactionItem]);
export type TimelineItem = Static<typeof TimelineItem>;
export type UserItem = Static<typeof UserItem>;
export type AssistantItem = Static<typeof AssistantItem>;
export type ToolItem = Static<typeof ToolItem>;
export type SystemItem = Static<typeof SystemItem>;

// ── Session state & events ─────────────────────────────────────────────────

export const SessionStatus = literals("idle", "running", "waiting_approval", "error");
export type SessionStatus = Static<typeof SessionStatus>;

export const QueuedInput = Type.Object({ id: Type.String(), mode: Type.Union([Type.Literal("steer"), Type.Literal("followUp")]), text: Type.Optional(Type.String()) });
export type QueuedInput = Static<typeof QueuedInput>;

export const SessionState = Type.Object({
	status: SessionStatus,
	queue: Type.Array(QueuedInput),
	model: Type.Optional(ModelRef),
	thinking: Type.Optional(Type.String()),
	usage: Usage,
});
export type SessionState = Static<typeof SessionState>;

export const Snapshot = Type.Object({ ref: ContainerRef, items: Type.Array(TimelineItem), state: SessionState });
export type Snapshot = Static<typeof Snapshot>;

export const SessionEvent = Type.Union([
	Type.Object({ type: Type.Literal("item.added"), item: TimelineItem }),
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

export const SessionSummary = Type.Object({
	ref: ContainerRef,
	title: Type.String(),
	createdAt: Type.String(),
	updatedAt: Type.String(),
	cwd: Type.Optional(Type.String()),
	model: Type.Optional(ModelRef),
});
export type SessionSummary = Static<typeof SessionSummary>;

// ── Methods (client → engine) ───────────────────────────────────────────────

export const EngineCapabilities = Type.Object({ runtimes: Type.Array(ContainerKind), models: Type.Array(Type.String()) });

export const methods = {
	"engine.hello": {
		params: Type.Object({ token: Type.String(), client: Type.String(), protocolVersion: Type.String() }),
		result: Type.Object({ engineId: Type.String(), kind: Type.Union([Type.Literal("local"), Type.Literal("cloud")]), version: Type.String(), protocolVersion: Type.String(), capabilities: EngineCapabilities }),
	},
	"engine.status": {
		params: Type.Object({}),
		result: Type.Object({ uptimeMs: Type.Number(), openSessions: Type.Number(), subscriptions: Type.Number() }),
	},
	"sessions.list": {
		params: Type.Object({ kind: Type.Optional(ContainerKind) }),
		result: Type.Object({ sessions: Type.Array(SessionSummary) }),
	},
	"sessions.create": {
		params: Type.Object({
			kind: Type.Union([Type.Literal("thread"), Type.Literal("build")]),
			cwd: Type.Optional(Type.String()),
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
			input: Type.Object({ text: Type.String() }),
			whenBusy: Type.Optional(Type.Union([Type.Literal("followUp"), Type.Literal("steer"), Type.Literal("reject")])),
			clientRequestId: Type.Optional(Type.String()),
		}),
		result: Type.Object({ accepted: Type.Boolean(), disposition: Type.Union([Type.Literal("started"), Type.Literal("queued")]) }),
	},
	"sessions.abort": {
		params: Type.Object({ ref: ContainerRef }),
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
