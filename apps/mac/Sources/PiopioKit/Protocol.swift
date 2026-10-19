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

public struct SystemItem: Codable, Sendable, Hashable {
    public enum Level: String, Codable, Sendable { case info, warn, error }
    public var id, at: String
    public var level: Level
    public var text: String
}

public struct CompactionItem: Codable, Sendable, Hashable { public var id, at, summary: String }

public enum TimelineItem: Codable, Sendable, Hashable, Identifiable {
    case user(UserItem)
    case assistant(AssistantItem)
    case tool(ToolItem)
    case system(SystemItem)
    case compaction(CompactionItem)

    private enum Key: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .kind)
        switch kind {
        case "user": self = .user(try UserItem(from: decoder))
        case "assistant": self = .assistant(try AssistantItem(from: decoder))
        case "tool": self = .tool(try ToolItem(from: decoder))
        case "system": self = .system(try SystemItem(from: decoder))
        case "compaction": self = .compaction(try CompactionItem(from: decoder))
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
        }
    }

    public var id: String {
        switch self {
        case .user(let v): v.id
        case .assistant(let v): v.id
        case .tool(let v): v.id
        case .system(let v): v.id
        case .compaction(let v): v.id
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
    public init(status: SessionStatus, queue: [QueuedInput], model: ModelRef?, thinking: String?, tools: Tools? = nil, usage: Usage) {
        self.status = status; self.queue = queue; self.model = model; self.thinking = thinking; self.tools = tools; self.usage = usage
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
    case itemDelta(itemId: String, partIndex: Int, partType: AssistantPart.PartType, textDelta: String)
    case itemUpdated(TimelineItem)
    case itemRemoved(itemId: String)
    case itemReplaced(oldId: String, item: TimelineItem)
    case state(SessionState)
    case resnapshot(Snapshot)
    case unknown(String)

    private enum Key: String, CodingKey { case type, item, itemId, partIndex, partType, textDelta, oldId, state, snapshot }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "item.added": self = .itemAdded(try c.decode(TimelineItem.self, forKey: .item))
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
    public init(kind: ContainerKind, cwd: String? = nil, model: ModelRef? = nil, thinking: String? = nil, title: String? = nil) {
        self.kind = kind; self.cwd = cwd; self.model = model; self.thinking = thinking; self.title = title
    }
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
    public init(ref: ContainerRef, model: ModelRef? = nil, thinking: String? = nil, web: Bool? = nil) { self.ref = ref; self.model = model; self.thinking = thinking; self.web = web }
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
