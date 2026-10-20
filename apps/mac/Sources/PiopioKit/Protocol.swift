import Foundation

// Engine Protocol types (docs/spec/03-engine-protocol.md).
// Hand-written for the Phase 0 subset; generated from packages/protocol/schema in Phase 1.

public let protocolVersion = "1.0"
public let secretOpenRouter = "provider.openrouter.apiKey"

public enum ContainerKind: String, Codable, Sendable { case build, thread, space, agent }

public struct ContainerRef: Codable, Sendable, Hashable {
    public var kind: ContainerKind
    public var id: String
    public var conversationId: String?
    public init(kind: ContainerKind, id: String, conversationId: String? = nil) {
        self.kind = kind; self.id = id; self.conversationId = conversationId
    }
}

public struct ModelRef: Codable, Sendable, Hashable {
    public var provider: String
    public var id: String
    public init(provider: String, id: String) { self.provider = provider; self.id = id }
}

public struct Usage: Codable, Sendable, Hashable {
    public var inputTokens: Double
    public var outputTokens: Double
    public var cacheReadTokens: Double
    public var cacheWriteTokens: Double
    public var costUsd: Double
    public init(inputTokens: Double, outputTokens: Double, cacheReadTokens: Double, cacheWriteTokens: Double, costUsd: Double) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens; self.costUsd = costUsd
    }
}

public struct AssistantPart: Codable, Sendable, Hashable {
    public enum PartType: String, Codable, Sendable { case text, thinking }
    public var type: PartType
    public var text: String
    public var redacted: Bool?
    public init(type: PartType, text: String, redacted: Bool? = nil) { self.type = type; self.text = text; self.redacted = redacted }
}

/// Where a user message sits among alternative versions at the same point (edits, regenerations).
public struct BranchInfo: Codable, Sendable, Hashable {
    public var index: Int
    public var count: Int
    public var previous: String?
    public var next: String?
    public init(index: Int, count: Int, previous: String? = nil, next: String? = nil) {
        self.index = index; self.count = count; self.previous = previous; self.next = next
    }
}

/// A file sent with a message, as the transcript shows it.
public struct AttachmentInfo: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case image, text }
    public var name: String
    public var kind: Kind
    public var mimeType: String?
    public var size: Double?
    public init(name: String, kind: Kind, mimeType: String? = nil, size: Double? = nil) { self.name = name; self.kind = kind; self.mimeType = mimeType; self.size = size }
}

public struct UserItem: Codable, Sendable, Hashable {
    public var id, at, text: String
    public var attachments: [AttachmentInfo]?
    public var branch: BranchInfo?
    public init(id: String, at: String, text: String, attachments: [AttachmentInfo]? = nil, branch: BranchInfo? = nil) {
        self.id = id; self.at = at; self.text = text; self.attachments = attachments; self.branch = branch
    }
}

/// Why a model request failed.
public enum ErrorKind: String, Codable, Sendable { case auth, credits, model, rateLimit = "rate_limit", provider, network, context, other }

public struct AssistantItem: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case streaming, done, error, aborted }
    public var id, at: String
    public var parts: [AssistantPart]
    public var model: String?
    public var usage: Usage?
    public var status: Status
    public var error: String?
    public var errorKind: ErrorKind?
    public var errorDetail: String?
    public var text: String { parts.filter { $0.type == .text }.map(\.text).joined() }
    public init(id: String, at: String, parts: [AssistantPart], model: String? = nil, usage: Usage? = nil, status: Status, error: String? = nil, errorKind: ErrorKind? = nil, errorDetail: String? = nil) {
        self.id = id; self.at = at; self.parts = parts; self.model = model; self.usage = usage; self.status = status
        self.error = error; self.errorKind = errorKind; self.errorDetail = errorDetail
    }
}

public struct ToolItem: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case pendingApproval = "pending_approval", running, done, error, interrupted, denied }
    public var id, at, callId, tool: String
    public var args: JSONValue?
    public var status: Status
    public var output: String?
    public var details: JSONValue?
    public var durationMs: Double?
    public var parentCallId: String?
    public init(id: String, at: String, callId: String, tool: String, args: JSONValue? = nil, status: Status, output: String? = nil, details: JSONValue? = nil, durationMs: Double? = nil, parentCallId: String? = nil) {
        self.id = id; self.at = at; self.callId = callId; self.tool = tool; self.args = args; self.status = status
        self.output = output; self.details = details; self.durationMs = durationMs; self.parentCallId = parentCallId
    }
}

/// What a tool card shows beyond the output (engine: timeline/tool-details.ts).
public enum ToolDetails: Sendable, Hashable {
    case diff(path: String, diff: String)
    case file(path: String, language: String?)
    case terminal(command: String, exitCode: Int?)
    case todos([Todo])
    /// A subagent: its child session once started, and how it ended.
    case task(sessionId: String?, status: String?, costUsd: Double?)
}

/// An item of the agent's checklist (piopio-todos).
public struct Todo: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case pending, inProgress = "in_progress", done }
    public var text: String
    public var status: Status
}

extension ToolItem {
    public var typedDetails: ToolDetails? {
        guard let d = details, let type = d["type"]?.stringValue else { return nil }
        switch type {
        case "diff": return d["path"]?.stringValue.map { .diff(path: $0, diff: d["diff"]?.stringValue ?? "") }
        case "file": return d["path"]?.stringValue.map { .file(path: $0, language: d["language"]?.stringValue) }
        case "todos":
            guard case .array(let items)? = d["items"] else { return nil }
            return .todos(items.compactMap { item in
                guard let text = item["text"]?.stringValue, let status = item["status"]?.stringValue.flatMap(Todo.Status.init(rawValue:)) else { return nil }
                return Todo(text: text, status: status)
            })
        case "task":
            var cost: Double?
            if case .number(let c)? = d["costUsd"] { cost = c }
            return .task(sessionId: d["sessionId"]?.stringValue, status: d["status"]?.stringValue, costUsd: cost)
        case "terminal":
            guard let command = d["command"]?.stringValue else { return nil }
            if case .number(let code)? = d["exitCode"] { return .terminal(command: command, exitCode: Int(code)) }
            return .terminal(command: command, exitCode: nil)
        default: return nil
        }
    }
}

public struct SystemItem: Codable, Sendable, Hashable {
    public enum Level: String, Codable, Sendable { case info, warn, error }
    public var id, at: String
    public var level: Level
    public var text: String
}

public struct CompactionItem: Codable, Sendable, Hashable { public var id, at, summary: String }

/// A snapshot of the working tree before a turn changed files (Build).
public struct CheckpointItem: Codable, Sendable, Hashable {
    public var id, at, checkpointId, label: String
    /// Files that changed since the previous checkpoint.
    public var files: Int?
    public init(id: String, at: String, checkpointId: String, label: String, files: Int? = nil) {
        self.id = id; self.at = at; self.checkpointId = checkpointId; self.label = label; self.files = files
    }
}

/// A file that differs from a checkpoint.
public struct FileChange: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case added, modified, deleted }
    public var path: String
    public var status: Status
    public var added: Int
    public var removed: Int
    public var binary: Bool?
    public var id: String { path }
}

public enum ChangesSince: String, Codable, Sendable { case session, turn }
public struct ChangesParams: Encodable, Sendable { public var ref: ContainerRef; public var since: ChangesSince; public init(ref: ContainerRef, since: ChangesSince) { self.ref = ref; self.since = since } }
public struct ChangesResult: Decodable, Sendable { public var base: String?; public var files: [FileChange] }
public struct DiffParams: Encodable, Sendable {
    public var ref: ContainerRef; public var path: String; public var since: ChangesSince
    public init(ref: ContainerRef, path: String, since: ChangesSince) { self.ref = ref; self.path = path; self.since = since }
}
public struct DiffResult: Decodable, Sendable { public var patch: String }
public struct RestoreParams: Encodable, Sendable {
    public var ref: ContainerRef; public var checkpointId: String; public var paths: [String]?; public var dryRun: Bool?
    public init(ref: ContainerRef, checkpointId: String, paths: [String]? = nil, dryRun: Bool? = nil) { self.ref = ref; self.checkpointId = checkpointId; self.paths = paths; self.dryRun = dryRun }
}
public struct RestoreResult: Decodable, Sendable { public var files: [FileChange] }

public enum TimelineItem: Codable, Sendable, Hashable, Identifiable {
    case user(UserItem)
    case assistant(AssistantItem)
    case tool(ToolItem)
    case system(SystemItem)
    case compaction(CompactionItem)
    case checkpoint(CheckpointItem)

    private enum Key: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .kind)
        switch kind {
        case "user": self = .user(try UserItem(from: decoder))
        case "assistant": self = .assistant(try AssistantItem(from: decoder))
        case "tool": self = .tool(try ToolItem(from: decoder))
        case "system": self = .system(try SystemItem(from: decoder))
        case "compaction": self = .compaction(try CompactionItem(from: decoder))
        case "checkpoint": self = .checkpoint(try CheckpointItem(from: decoder))
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown item kind \(kind)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .user(let v): try c.encode("user", forKey: .kind); try v.encode(to: encoder)
        case .assistant(let v): try c.encode("assistant", forKey: .kind); try v.encode(to: encoder)
        case .tool(let v): try c.encode("tool", forKey: .kind); try v.encode(to: encoder)
        case .system(let v): try c.encode("system", forKey: .kind); try v.encode(to: encoder)
        case .compaction(let v): try c.encode("compaction", forKey: .kind); try v.encode(to: encoder)
        case .checkpoint(let v): try c.encode("checkpoint", forKey: .kind); try v.encode(to: encoder)
        }
    }

    public var id: String {
        switch self {
        case .user(let v): v.id
        case .assistant(let v): v.id
        case .tool(let v): v.id
        case .system(let v): v.id
        case .compaction(let v): v.id
        case .checkpoint(let v): v.id
        }
    }
}

public enum SessionStatus: String, Codable, Sendable { case idle, running, waitingApproval = "waiting_approval", error }

public struct QueuedInput: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable { case steer, followUp }
    public var id: String
    public var mode: Mode
    public var text: String?
}

public struct SessionState: Codable, Sendable, Hashable {
    public var status: SessionStatus
    public var queue: [QueuedInput]
    public var model: ModelRef?
    public var thinking: String?
    public struct Tools: Codable, Sendable, Hashable { public var web: Bool }
    public var tools: Tools?
    public var usage: Usage
    /// How full the model's context is (Build). `tokens` is nil right after a compaction.
    public struct Context: Codable, Sendable, Hashable { public var tokens: Double?; public var window: Double }
    public var context: Context?
    /// Build: approval mode and what the session waits on you for.
    public var approvalMode: ApprovalMode?
    public var prompts: [PendingPrompt]?
    /// Build: the agent's checklist, and plan mode.
    public var todos: [Todo]?
    public var planMode: Bool?
    public init(status: SessionStatus, queue: [QueuedInput], model: ModelRef?, thinking: String?, tools: Tools? = nil, usage: Usage, context: Context? = nil) {
        self.status = status; self.queue = queue; self.model = model; self.thinking = thinking; self.tools = tools; self.usage = usage; self.context = context
    }
}

public struct Snapshot: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var items: [TimelineItem]
    public var state: SessionState
    public init(ref: ContainerRef, items: [TimelineItem], state: SessionState) { self.ref = ref; self.items = items; self.state = state }
}

public enum SessionEvent: Decodable, Sendable, Hashable {
    case itemAdded(TimelineItem)
    /// Added before another item (checkpoints go before the change they precede).
    case itemInserted(TimelineItem, before: String)
    case itemDelta(itemId: String, partIndex: Int, partType: AssistantPart.PartType, textDelta: String)
    case itemUpdated(TimelineItem)
    case itemRemoved(itemId: String)
    case itemReplaced(oldId: String, item: TimelineItem)
    case state(SessionState)
    case resnapshot(Snapshot)
    case unknown(String)

    private enum Key: String, CodingKey { case type, item, itemId, partIndex, partType, textDelta, oldId, state, snapshot, before }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "item.added":
            let item = try c.decode(TimelineItem.self, forKey: .item)
            if let before = try c.decodeIfPresent(String.self, forKey: .before) { self = .itemInserted(item, before: before) } else { self = .itemAdded(item) }
        case "item.delta":
            self = .itemDelta(itemId: try c.decode(String.self, forKey: .itemId), partIndex: try c.decode(Int.self, forKey: .partIndex),
                              partType: try c.decode(AssistantPart.PartType.self, forKey: .partType), textDelta: try c.decode(String.self, forKey: .textDelta))
        case "item.updated": self = .itemUpdated(try c.decode(TimelineItem.self, forKey: .item))
        case "item.removed": self = .itemRemoved(itemId: try c.decode(String.self, forKey: .itemId))
        case "item.replaced": self = .itemReplaced(oldId: try c.decode(String.self, forKey: .oldId), item: try c.decode(TimelineItem.self, forKey: .item))
        case "state": self = .state(try c.decode(SessionState.self, forKey: .state))
        case "resnapshot": self = .resnapshot(try c.decode(Snapshot.self, forKey: .snapshot))
        default: self = .unknown(type) // newer engine; ignore
        }
    }
}

public struct SessionEventsNotification: Decodable, Sendable {
    public var subscriptionId: String
    public var seq: Int
    public var events: [SessionEvent]
}

public struct SessionSummary: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    public var cwd: String?
    public var model: ModelRef?
    /// Build: the project folder (differs from `cwd` for worktree sessions), and the worktree if any.
    public var projectPath: String?
    public var worktree: WorktreeInfo?
    /// A subagent's session: the parent session and its `task` call.
    public struct Parent: Codable, Sendable, Hashable { public var id: String; public var callId: String }
    public var parent: Parent?
}

// MARK: Method params / results

public struct HelloParams: Encodable, Sendable { public var token: String; public var client: String; public var protocolVersion: String }
public struct HelloResult: Decodable, Sendable {
    public struct Capabilities: Decodable, Sendable { public var runtimes: [ContainerKind]; public var models: [String] }
    public var engineId: String
    public var kind: String
    public var version: String
    public var protocolVersion: String
    public var capabilities: Capabilities
}

public struct CreateSessionParams: Encodable, Sendable {
    public var kind: ContainerKind
    public var cwd: String?
    public var model: ModelRef?
    public var thinking: String?
    public var title: String?
    public var workOn: WorkOn?
    public var approvalMode: ApprovalMode?
    public init(kind: ContainerKind, cwd: String? = nil, model: ModelRef? = nil, thinking: String? = nil, title: String? = nil, workOn: WorkOn? = nil, approvalMode: ApprovalMode? = nil) {
        self.kind = kind; self.cwd = cwd; self.model = model; self.thinking = thinking; self.title = title; self.workOn = workOn; self.approvalMode = approvalMode
    }
}

// MARK: Composer and tree (Build)

public struct SessionCommand: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case template, skill, `extension` }
    public var name: String
    public var description: String
    public var kind: Kind
    public var hint: String?
    public var id: String { name }
}
public struct CommandsResult: Decodable, Sendable { public var commands: [SessionCommand] }

public struct TreeNode: Codable, Sendable, Hashable, Identifiable {
    public var entryId: String
    public var text: String
    public var at: String
    public var depth: Int
    public var current: Bool
    public var branches: Int
    public var id: String { entryId }
}
public struct TreeResult: Decodable, Sendable { public var nodes: [TreeNode] }
public struct NavigateParams: Encodable, Sendable { public var ref: ContainerRef; public var entryId: String; public init(ref: ContainerRef, entryId: String) { self.ref = ref; self.entryId = entryId } }
public struct NavigateResult: Decodable, Sendable { public var editorText: String? }

public struct FileMatch: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case file, folder }
    public var path: String
    public var kind: Kind
    public var id: String { path }
}
public struct FilesParams: Encodable, Sendable {
    public var cwd: String; public var query: String; public var limit: Int?
    public init(cwd: String, query: String, limit: Int? = nil) { self.cwd = cwd; self.query = query; self.limit = limit }
}
public struct FilesResult: Decodable, Sendable { public var files: [FileMatch] }

// MARK: Files and MCP (Build)

public struct ReadFileParams: Encodable, Sendable { public var cwd: String; public var path: String; public init(cwd: String, path: String) { self.cwd = cwd; self.path = path } }
public struct ReadFileResult: Decodable, Sendable {
    public var content: String; public var size: Int; public var truncated: Bool; public var binary: Bool
    public init(content: String, size: Int, truncated: Bool, binary: Bool) { self.content = content; self.size = size; self.truncated = truncated; self.binary = binary }
}
public struct WriteFileParams: Encodable, Sendable {
    public var cwd: String; public var path: String; public var content: String
    public init(cwd: String, path: String, content: String) { self.cwd = cwd; self.path = path; self.content = content }
}

public struct McpServerInfo: Codable, Sendable, Hashable, Identifiable {
    public enum Scope: String, Codable, Sendable { case global, project }
    public var name: String
    public var scope: Scope
    public var transport: String
    public var command: String?
    public var args: [String]?
    public var url: String?
    public var enabled: Bool
    public var description: String?
    public var override: Bool?
    public var id: String { "\(scope.rawValue):\(name)" }
}
public struct McpListParams: Encodable, Sendable { public var cwd: String?; public init(cwd: String? = nil) { self.cwd = cwd } }
public struct McpListResult: Decodable, Sendable { public var servers: [McpServerInfo]; public var errors: [String] }
public struct McpAddParams: Encodable, Sendable {
    public var scope: McpServerInfo.Scope; public var cwd: String?; public var name: String
    public var command: String?; public var args: [String]?; public var url: String?; public var description: String?
    public init(scope: McpServerInfo.Scope, cwd: String?, name: String, command: String?, args: [String]?, url: String?, description: String?) {
        self.scope = scope; self.cwd = cwd; self.name = name; self.command = command; self.args = args; self.url = url; self.description = description
    }
}
public struct McpNameParams: Encodable, Sendable {
    public var scope: McpServerInfo.Scope; public var cwd: String?; public var name: String; public var enabled: Bool?
    public init(scope: McpServerInfo.Scope, cwd: String?, name: String, enabled: Bool? = nil) { self.scope = scope; self.cwd = cwd; self.name = name; self.enabled = enabled }
}

// MARK: Git (Build)

/// Where a new Build session works.
public enum WorkOn: Encodable, Sendable, Hashable {
    case current
    case branch(String, base: String?)
    case worktree(String, base: String?)

    private enum Key: String, CodingKey { case kind, branch, base }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .current: try c.encode("current", forKey: .kind)
        case .branch(let b, let base): try c.encode("branch", forKey: .kind); try c.encode(b, forKey: .branch); try c.encodeIfPresent(base, forKey: .base)
        case .worktree(let b, let base): try c.encode("worktree", forKey: .kind); try c.encode(b, forKey: .branch); try c.encodeIfPresent(base, forKey: .base)
        }
    }
}

public struct WorktreeInfo: Codable, Sendable, Hashable {
    public enum Finished: String, Codable, Sendable { case merged, discarded }
    public var branch: String
    public var base: String
    public var finished: Finished?
}

public struct GitFile: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case added, modified, deleted, renamed, conflicted, untracked }
    public var path: String
    public var status: Status
    public var staged: Bool
    public var from: String?
    public var id: String { path }
}

public struct GitStatus: Codable, Sendable, Hashable {
    public var repo: Bool
    public var branch: String?
    public var detached: Bool?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var files: [GitFile]
}

public struct GitBranch: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var upstream: String?
    public var lastCommitAt: String?
    public var current: Bool
    public var id: String { name }
}

public struct CwdParams: Encodable, Sendable { public var cwd: String; public init(cwd: String) { self.cwd = cwd } }
public struct GitBranchesResult: Decodable, Sendable { public var branches: [GitBranch] }
public struct GitCheckoutParams: Encodable, Sendable {
    public var cwd: String; public var branch: String; public var create: Bool?; public var base: String?
    public init(cwd: String, branch: String, create: Bool? = nil, base: String? = nil) { self.cwd = cwd; self.branch = branch; self.create = create; self.base = base }
}
public struct GitCommitParams: Encodable, Sendable {
    public var cwd: String; public var message: String; public var paths: [String]?; public var amend: Bool?
    public init(cwd: String, message: String, paths: [String]? = nil, amend: Bool? = nil) { self.cwd = cwd; self.message = message; self.paths = paths; self.amend = amend }
}
public struct GitCommitResult: Decodable, Sendable { public var commit: String }
public struct GitMessageParams: Encodable, Sendable { public var cwd: String; public var paths: [String]?; public init(cwd: String, paths: [String]? = nil) { self.cwd = cwd; self.paths = paths } }
public struct GitMessageResult: Decodable, Sendable { public var message: String }
public struct GitSyncParams: Encodable, Sendable {
    public enum Action: String, Encodable, Sendable { case push, pull, fetch }
    public var cwd: String; public var action: Action
    public init(cwd: String, action: Action) { self.cwd = cwd; self.action = action }
}
public struct GitSyncResult: Decodable, Sendable { public var output: String }
public struct SuggestBranchParams: Encodable, Sendable { public var prompt: String; public init(prompt: String) { self.prompt = prompt } }
public struct SuggestBranchResult: Decodable, Sendable { public var branch: String }
public struct FinishParams: Encodable, Sendable {
    public enum Action: String, Encodable, Sendable { case merge, discard }
    public var ref: ContainerRef; public var action: Action
    public init(ref: ContainerRef, action: Action) { self.ref = ref; self.action = action }
}
public struct CreateSessionResult: Decodable, Sendable { public var ref: ContainerRef }
public struct RefParams: Encodable, Sendable { public var ref: ContainerRef; public init(ref: ContainerRef) { self.ref = ref } }
public struct SubscribeResult: Decodable, Sendable { public var subscriptionId: String; public var snapshot: Snapshot }
public struct ListSessionsParams: Encodable, Sendable { public var kind: ContainerKind?; public init(kind: ContainerKind? = nil) { self.kind = kind } }
public struct ListSessionsResult: Decodable, Sendable { public var sessions: [SessionSummary] }

/// A file to send: images as base64 (prepared by the client), documents as extracted text.
public enum Attachment: Encodable, Sendable, Hashable {
    case image(name: String, mimeType: String, data: String)
    case text(name: String, mimeType: String?, text: String)

    private enum Key: String, CodingKey { case kind, name, mimeType, data, text }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .image(let name, let mime, let data):
            try c.encode("image", forKey: .kind); try c.encode(name, forKey: .name); try c.encode(mime, forKey: .mimeType); try c.encode(data, forKey: .data)
        case .text(let name, let mime, let text):
            try c.encode("text", forKey: .kind); try c.encode(name, forKey: .name); try c.encodeIfPresent(mime, forKey: .mimeType); try c.encode(text, forKey: .text)
        }
    }
}

public struct SubmitParams: Encodable, Sendable {
    public enum WhenBusy: String, Encodable, Sendable { case followUp, steer, reject }
    public struct Input: Encodable, Sendable { public var text: String; public var attachments: [Attachment]? }
    public var ref: ContainerRef
    public var input: Input
    public var whenBusy: WhenBusy?
    public var clientRequestId: String?
    public init(ref: ContainerRef, text: String, attachments: [Attachment] = [], whenBusy: WhenBusy? = nil, clientRequestId: String? = nil) {
        self.ref = ref; self.input = Input(text: text, attachments: attachments.isEmpty ? nil : attachments); self.whenBusy = whenBusy; self.clientRequestId = clientRequestId
    }
}
public struct SubmitResult: Decodable, Sendable { public var accepted: Bool; public var disposition: String }
public struct Empty: Codable, Sendable { public init() {} }

// MARK: Phase 1 additions

public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    public struct Pricing: Codable, Sendable, Hashable { public var input, output, cacheRead, cacheWrite: Double }
    public struct Supports: Codable, Sendable, Hashable { public var vision, reasoning: Bool }
    public var provider: String
    public var id: String
    public var name: String
    public var contextWindow: Double
    public var maxOutputTokens: Double
    public var pricing: Pricing
    public var supports: Supports
    public var ref: ModelRef { ModelRef(provider: provider, id: id) }
}

public struct ModelsListParams: Encodable, Sendable { public var refresh: Bool?; public init(refresh: Bool? = nil) { self.refresh = refresh } }
public struct ModelsListResult: Decodable, Sendable { public var models: [ModelInfo]; public var defaultModel: ModelRef }

public struct ConfigureParams: Encodable, Sendable {
    public var ref: ContainerRef
    public var model: ModelRef?
    public var thinking: String?
    public var web: Bool?
    public var approvalMode: ApprovalMode?
    public var planMode: Bool?
    public init(ref: ContainerRef, model: ModelRef? = nil, thinking: String? = nil, web: Bool? = nil, approvalMode: ApprovalMode? = nil, planMode: Bool? = nil) {
        self.ref = ref; self.model = model; self.thinking = thinking; self.web = web; self.approvalMode = approvalMode; self.planMode = planMode
    }
}

// MARK: Approvals (Build)

public enum ApprovalMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case ask, autoEdit = "auto_edit", fullAuto = "full_auto"
    public var id: String { rawValue }
}

public struct ApprovalRule: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case command, tool, path }
    public var id: String
    public var kind: Kind
    public var pattern: String
    public var createdAt: String
}

/// Something a session waits on you for: an approval, a question, or an extension's confirm/select/input.
public struct PendingPrompt: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case approval, question, confirm, select, input, plan }
    public struct SuggestedRule: Codable, Sendable, Hashable { public var kind: ApprovalRule.Kind; public var pattern: String }
    public var id: String
    public var kind: Kind
    public var title: String
    public var message: String?
    public var detail: String?
    public var tool: String?
    public var callId: String?
    public var reason: String?
    public var rule: SuggestedRule?
    public var options: [String]?
    public var placeholder: String?
    /// Plans: the steps (approve = decision allow; keep planning = deny with a note).
    public var steps: [String]?
    public var at: String
}

public struct PromptResponse: Encodable, Sendable {
    public enum Decision: String, Encodable, Sendable { case allow, always, deny }
    public var decision: Decision?
    public var text: String?
    public var choice: String?
    public var confirmed: Bool?
    public init(decision: Decision? = nil, text: String? = nil, choice: String? = nil, confirmed: Bool? = nil) {
        self.decision = decision; self.text = text; self.choice = choice; self.confirmed = confirmed
    }
}

public struct RespondParams: Encodable, Sendable {
    public var ref: ContainerRef
    public var promptId: String
    public var response: PromptResponse
    public init(ref: ContainerRef, promptId: String, response: PromptResponse) { self.ref = ref; self.promptId = promptId; self.response = response }
}

public struct ProjectsConfigureParams: Encodable, Sendable {
    public var id: String
    public var approvalMode: ApprovalMode?
    public var removeRule: String?
    public var trust: Bool?
    public init(id: String, approvalMode: ApprovalMode? = nil, removeRule: String? = nil, trust: Bool? = nil) { self.id = id; self.approvalMode = approvalMode; self.removeRule = removeRule; self.trust = trust }
}

/// A session needs you, or told you something (notify_user).
public struct SessionAttention: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable { case waiting, notify }
    public var ref: ContainerRef
    public var title: String
    public var kind: Kind
    public var message: String
}

public struct ExportParams: Encodable, Sendable {
    public enum Format: String, Encodable, Sendable { case markdown, html, jsonl }
    public var ref: ContainerRef; public var format: Format
    public init(ref: ContainerRef, format: Format) { self.ref = ref; self.format = format }
}
public struct ExportResult: Decodable, Sendable { public var filename: String; public var mimeType: String; public var content: String }
public struct RenameParams: Encodable, Sendable {
    public var ref: ContainerRef
    public var title: String
    public init(ref: ContainerRef, title: String) { self.ref = ref; self.title = title }
}
public struct SecretChangedParams: Encodable, Sendable { public var name: String; public init(name: String) { self.name = name } }
public struct UnsubscribeParams: Encodable, Sendable { public var subscriptionId: String; public init(subscriptionId: String) { self.subscriptionId = subscriptionId } }

/// A folder added in Build.
public struct ProjectInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public var addedAt: String
    public var branch: String?
    public var contextFile: String?
    public var piConfig: Bool
    public var approvalMode: ApprovalMode
    public var rules: [ApprovalRule]
    /// pi project trust (shared with the pi CLI): whether the project's .pi resources load; `needsTrust`: it has some.
    public enum Trust: String, Codable, Sendable { case trusted, untrusted, undecided }
    public var trust: Trust
    public var needsTrust: Bool
    public var missing: Bool?
}

public struct ProjectsChanged: Decodable, Sendable { public var projects: [ProjectInfo] }
public struct ProjectsListResult: Decodable, Sendable { public var projects: [ProjectInfo] }
public struct ProjectsAddParams: Encodable, Sendable { public var path: String; public init(path: String) { self.path = path } }
public struct ProjectsAddResult: Decodable, Sendable { public var project: ProjectInfo }
public struct ProjectsRemoveParams: Encodable, Sendable { public var id: String; public init(id: String) { self.id = id } }

public struct CatalogChanged: Decodable, Sendable {
    public var upserted: [SessionSummary]
    public var removed: [ContainerRef]
}

// MARK: Milestone 1.2: branches and queue

public struct EditParams: Encodable, Sendable {
    public var ref: ContainerRef; public var itemId: String; public var text: String
    public init(ref: ContainerRef, itemId: String, text: String) { self.ref = ref; self.itemId = itemId; self.text = text }
}
public struct ItemParams: Encodable, Sendable {
    public var ref: ContainerRef; public var itemId: String
    public init(ref: ContainerRef, itemId: String) { self.ref = ref; self.itemId = itemId }
}
public struct SwitchBranchParams: Encodable, Sendable {
    public var ref: ContainerRef; public var branch: String
    public init(ref: ContainerRef, branch: String) { self.ref = ref; self.branch = branch }
}
public struct QueueRemoveParams: Encodable, Sendable {
    public var ref: ContainerRef; public var queueId: String
    public init(ref: ContainerRef, queueId: String) { self.ref = ref; self.queueId = queueId }
}

// MARK: Milestone 1.4: search

public struct SearchParams: Encodable, Sendable {
    public var query: String; public var limit: Int?
    public init(query: String, limit: Int? = nil) { self.query = query; self.limit = limit }
}

public struct SearchResult: Decodable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case title, user, assistant }
    public var ref: ContainerRef
    public var title: String
    public var itemId: String?
    public var kind: Kind
    /// Matches are wrapped in U+0002 … U+0003.
    public var snippet: String
    public var at: String
    public var id: String { "\(ref.id)/\(itemId ?? "title")" }
}
public struct SearchResults: Decodable, Sendable { public var results: [SearchResult] }

// MARK: Keys and engine info

public struct VerifyKeyParams: Encodable, Sendable {
    public var provider: String; public var key: String
    public init(provider: String, key: String) { self.provider = provider; self.key = key }
}
public struct VerifyKeyResult: Decodable, Sendable, Equatable {
    public var ok: Bool; public var message: String?; public var label: String?; public var usageUsd: Double?; public var limitUsd: Double?
}
public struct EngineStatusResult: Decodable, Sendable {
    public var uptimeMs: Double; public var openSessions: Int; public var subscriptions: Int; public var runtime: String; public var memoryMB: Double; public var dataPath: String
}
