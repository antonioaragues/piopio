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
}

public struct AssistantPart: Codable, Sendable, Hashable {
    public enum PartType: String, Codable, Sendable { case text, thinking }
    public var type: PartType
    public var text: String
    public var redacted: Bool?
}

public struct UserItem: Codable, Sendable, Hashable { public var id, at, text: String }

public struct AssistantItem: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case streaming, done, error, aborted }
    public var id, at: String
    public var parts: [AssistantPart]
    public var model: String?
    public var usage: Usage?
    public var status: Status
    public var error: String?
    public var text: String { parts.filter { $0.type == .text }.map(\.text).joined() }
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
    public var usage: Usage
}

public struct Snapshot: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var items: [TimelineItem]
    public var state: SessionState
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

public struct SubmitParams: Encodable, Sendable {
    public enum WhenBusy: String, Encodable, Sendable { case followUp, steer, reject }
    public struct Input: Encodable, Sendable { public var text: String }
    public var ref: ContainerRef
    public var input: Input
    public var whenBusy: WhenBusy?
    public var clientRequestId: String?
    public init(ref: ContainerRef, text: String, whenBusy: WhenBusy? = nil, clientRequestId: String? = nil) {
        self.ref = ref; self.input = Input(text: text); self.whenBusy = whenBusy; self.clientRequestId = clientRequestId
    }
}
public struct SubmitResult: Decodable, Sendable { public var accepted: Bool; public var disposition: String }
public struct Empty: Codable, Sendable { public init() {} }
