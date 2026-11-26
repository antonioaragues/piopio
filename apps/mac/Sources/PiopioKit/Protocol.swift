import Foundation

// Engine Protocol types (docs/spec/03-engine-protocol.md).
// Hand-written for the Phase 0 subset; generated from packages/protocol/schema in Phase 1.

public let protocolVersion = "1.0"
public let secretOpenRouter = "provider.openrouter.apiKey"

public enum ContainerKind: String, Codable, Sendable { case build, thread, agent }

public struct ContainerRef: Codable, Sendable, Hashable {
    public var kind: ContainerKind
    public var id: String
    public var conversationId: String?
    public init(kind: ContainerKind, id: String, conversationId: String? = nil) {
        self.kind = kind; self.id = id; self.conversationId = conversationId
    }
    /// Unique per conversation: a Space topic is "<space>/<topic>", everything else its id.
    public var key: String { conversationId.map { "\(id)/\($0)" } ?? id }
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
    /// Where the engine keeps a copy, relative to `<home>/attachments/<container id>/`; nil for files sent before it kept them.
    public var stored: String?
    public init(name: String, kind: Kind, mimeType: String? = nil, size: Double? = nil, stored: String? = nil) { self.name = name; self.kind = kind; self.mimeType = mimeType; self.size = size; self.stored = stored }
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
    /// An agent's message sent on its own (send_message), from a run (`run_…`) or a person's conversation.
    public struct Outbound: Codable, Sendable, Hashable {
        public var from: String
        /// Quick replies offered with it (a new agent's greeting, docs/spec/21 D4).
        public var suggestions: [String]?
        public init(from: String, suggestions: [String]? = nil) { self.from = from; self.suggestions = suggestions }
    }
    public var outbound: Outbound?
    /// How long it thought (measured live).
    public var thinkingMs: Double?
    public var text: String { parts.filter { $0.type == .text }.map(\.text).joined() }
    public init(id: String, at: String, parts: [AssistantPart], model: String? = nil, usage: Usage? = nil, status: Status, error: String? = nil, errorKind: ErrorKind? = nil, errorDetail: String? = nil, outbound: Outbound? = nil) {
        self.id = id; self.at = at; self.parts = parts; self.model = model; self.usage = usage; self.status = status
        self.error = error; self.errorKind = errorKind; self.errorDetail = errorDetail; self.outbound = outbound
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
    /// Auto review let this command run without asking (Build, Auto-edit): its reason.
    public var review: String?
    /// Images the tool returned (a screenshot it read), kept with the conversation's files.
    public var images: [AttachmentInfo]?
    public init(id: String, at: String, callId: String, tool: String, args: JSONValue? = nil, status: Status, output: String? = nil, details: JSONValue? = nil, durationMs: Double? = nil, parentCallId: String? = nil, review: String? = nil, images: [AttachmentInfo]? = nil) {
        self.id = id; self.at = at; self.callId = callId; self.tool = tool; self.args = args; self.status = status
        self.output = output; self.details = details; self.durationMs = durationMs; self.parentCallId = parentCallId; self.review = review
        self.images = images
    }
}

/// What a tool card shows beyond the output (engine: timeline/tool-details.ts).
extension SessionSummary {
    /// Whole hours a temporary chat has left, at least 1 while it's still here ("23h").
    public func hoursLeft(now: Date = Date()) -> Int? {
        guard let temporary, let end = ISO8601DateFormatter.withFractions.date(from: temporary.expiresAt) ?? ISO8601DateFormatter().date(from: temporary.expiresAt) else { return nil }
        return max(1, Int((end.timeIntervalSince(now) / 3600).rounded(.up)))
    }
}

extension ISO8601DateFormatter {
    /// The engine's timestamps ("2026-11-24T18:03:11.402Z").
    nonisolated(unsafe) static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

public enum ToolDetails: Sendable, Hashable {
    case diff(path: String, diff: String)
    case file(path: String, language: String?)
    case terminal(command: String, exitCode: Int?)
    case todos([Todo])
    /// A subagent: its child session once started, and how it ended.
    case task(sessionId: String?, status: String?, costUsd: Double?)
    /// A proposed plan and how you answered it.
    case plan(PlanDetails)
    /// Files the agent handed over (piopio-present).
    case files([PresentedFile])
    /// Earlier conversations a turn searched or read (docs/spec/14 M4), and how many it held back from a cloud model.
    case conversations([PastConversation], withheld: Int)
    /// What /learn proposes to keep (docs/spec/14 M5), and the project file its rules would go into.
    case learn(file: String?, items: [LearnItem])
}

/// One thing /learn proposes (docs/spec/14 M5): a rule for the project's instructions file, or a fact about you.
public struct LearnItem: Codable, Sendable, Hashable, Identifiable {
    public enum Destination: String, Codable, Sendable, CaseIterable { case project, aboutMe = "about_me", skill }
    public var to: Destination
    /// A rule or fact as written; for a skill, when it's used (the description the model routes on).
    public var text: String
    public var why: String?
    public var section: String?
    /// Skills (docs/spec/40 SH0): its name, its instructions, one of yours to add to, and whether it's this project's only.
    public var name: String?
    public var body: String?
    public var addTo: String?
    public var projectOnly: Bool?
    public var id: String { "\(to.rawValue):\(name ?? ""):\(text)" }
    public init(to: Destination, text: String, why: String? = nil, section: String? = nil, name: String? = nil, body: String? = nil, addTo: String? = nil, projectOnly: Bool? = nil) {
        self.to = to; self.text = text; self.why = why; self.section = section; self.name = name; self.body = body; self.addTo = addTo; self.projectOnly = projectOnly
    }
}

/// One of your hooks (PAR6): what Piopio writes as a pi extension file from a sentence.
public struct HookSpec: Codable, Sendable, Hashable {
    public enum When: String, Codable, Sendable, CaseIterable { case before, after, end }
    public enum Tool: String, Codable, Sendable, CaseIterable { case edit, write, bash, any }
    public var when: When
    public var tools: [Tool]?
    public var files: String?
    public var command: String?
    public var run: String?
    public var stop: String?
    public init(when: When, tools: [Tool]? = nil, files: String? = nil, command: String? = nil, run: String? = nil, stop: String? = nil) {
        self.when = when; self.tools = tools; self.files = files; self.command = command; self.run = run; self.stop = stop
    }
}
public struct HookInfo: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var on: Bool
    public var `where`: String
    /// Absent: changed by hand, so it's code.
    public var spec: HookSpec?
    public var sentence: String
    public var id: String { path }
}
public struct HooksListParams: Encodable, Sendable { public var project: String?; public init(project: String? = nil) { self.project = project } }
public struct HooksResult: Decodable, Sendable {
    public struct Claude: Decodable, Sendable, Hashable { public var spec: HookSpec; public var sentence: String }
    public var hooks: [HookInfo]; public var claude: [Claude]
}
public struct HookSaveParams: Encodable, Sendable {
    public var path: String?; public var project: String?; public var spec: HookSpec
    public init(path: String? = nil, project: String? = nil, spec: HookSpec) { self.path = path; self.project = project; self.spec = spec }
}
public struct HookPathResult: Decodable, Sendable { public var path: String }
public struct HookToggleParams: Encodable, Sendable { public var path: String; public var on: Bool; public init(path: String, on: Bool) { self.path = path; self.on = on } }
public struct HookTryParams: Encodable, Sendable { public var spec: HookSpec; public var project: String?; public init(spec: HookSpec, project: String? = nil) { self.spec = spec; self.project = project } }
public struct HookTryResult: Decodable, Sendable { public var code: Int; public var output: String; public var ms: Double; public var file: String? }
public struct HookImportParams: Encodable, Sendable { public var project: String; public init(project: String) { self.project = project } }
public struct HookImportResult: Decodable, Sendable { public var paths: [String] }

/// A skill pi loads (backlog D9): yours, a project's, or a package's (read-only).
public struct SkillInfo: Codable, Sendable, Hashable, Identifiable {
    public enum Where: String, Codable, Sendable { case yours, project, package }
    public var name: String
    public var description: String
    public var path: String
    public var `where`: Where
    public var manual: Bool
    public var editable: Bool
    public var source: String?
    public var id: String { path }
}
public struct SkillsListParams: Encodable, Sendable { public var project: String?; public init(project: String? = nil) { self.project = project } }
public struct SkillsResult: Decodable, Sendable { public var skills: [SkillInfo] }
public struct SkillPathParams: Encodable, Sendable { public var path: String; public init(path: String) { self.path = path } }
public struct SkillResult: Decodable, Sendable { public var info: SkillInfo; public var body: String }
public struct SkillSaveParams: Encodable, Sendable {
    public var path: String?; public var project: String?; public var name: String; public var description: String; public var body: String; public var manual: Bool?
    public init(path: String? = nil, project: String? = nil, name: String, description: String, body: String, manual: Bool? = nil) {
        self.path = path; self.project = project; self.name = name; self.description = description; self.body = body; self.manual = manual
    }
}
public struct SkillSaveResult: Decodable, Sendable { public var path: String }

/// A custom subagent (roadmap PAR12): one of pi's agent files, which a conversation's `task` can hand work to by name.
public struct CustomSubagentInfo: Codable, Sendable, Hashable, Identifiable {
    public enum Where: String, Codable, Sendable { case yours, project }
    public var name: String
    public var description: String
    /// The only tools it gets; nil, all of the conversation's.
    public var tools: [String]?
    /// Its model as the file says it; nil, the conversation's.
    public var model: String?
    public var path: String
    public var `where`: Where
    public var id: String { path }
}
public struct SubagentsListParams: Encodable, Sendable { public var project: String?; public init(project: String? = nil) { self.project = project } }
public struct SubagentsResult: Decodable, Sendable { public var subagents: [CustomSubagentInfo] }
public struct SubagentPathParams: Encodable, Sendable { public var path: String; public init(path: String) { self.path = path } }
public struct SubagentResult: Decodable, Sendable { public var info: CustomSubagentInfo; public var instructions: String }
public struct SubagentSaveParams: Encodable, Sendable {
    public var path: String?; public var project: String?; public var name: String; public var description: String; public var tools: [String]?; public var model: String?; public var instructions: String
    public init(path: String? = nil, project: String? = nil, name: String, description: String, tools: [String]? = nil, model: String? = nil, instructions: String) {
        self.path = path; self.project = project; self.name = name; self.description = description; self.tools = tools; self.model = model; self.instructions = instructions
    }
}
public struct SubagentSaveResult: Decodable, Sendable { public var path: String }

/// Where a /learn card stands (the session's `learned`).
public struct LearnState: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case pending, later, saved, dismissed }
    public var status: Status
    public var file: String?
    public var aboutMe: Int?
    /// The skills a save made or added to.
    public var skills: [String]?
    public init(status: Status, file: String? = nil, aboutMe: Int? = nil, skills: [String]? = nil) { self.status = status; self.file = file; self.aboutMe = aboutMe; self.skills = skills }
}

public struct LearnSaveParams: Encodable, Sendable {
    public var ref: ContainerRef; public var callId: String; public var items: [LearnItem]?
    public init(ref: ContainerRef, callId: String, items: [LearnItem]? = nil) { self.ref = ref; self.callId = callId; self.items = items }
}
public struct LearnSaveResult: Decodable, Sendable { public var file: String?; public var project: Int; public var aboutMe: Int; public var skills: [String]? }
public struct LearnAnswerParams: Encodable, Sendable {
    public var ref: ContainerRef; public var callId: String; public var choice: String
    public init(ref: ContainerRef, callId: String, choice: String) { self.ref = ref; self.callId = callId; self.choice = choice }
}

/// An earlier conversation a search found or a turn read: opens from the card.
public struct PastConversation: Sendable, Hashable {
    public var id: String
    public var title: String
    /// "thread" or "build".
    public var kind: String
}

/// A file the agent handed over: where it is, what it is, and whether it was there.
public struct PresentedFile: Sendable, Hashable {
    public var path: String
    public var name: String
    public var description: String?
    public var size: Int?
    public var missing: Bool
}

/// A plan (piopio-plan): what it says, and the answer — approved (perhaps with your edits), sent back, or none yet.
public struct PlanDetails: Sendable, Hashable {
    public var summary: String
    public var steps: [String]
    public var files: [String]
    public var risks: [String]
    /// "approved", "changes", "unanswered"; nil while it waits for you.
    public var outcome: String?
    public var edited: Bool
    public var note: String?
}

/// An item of the agent's checklist (piopio-todos).
public struct Todo: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case pending, inProgress = "in_progress", done }
    /// The step's title, in a few words.
    public var text: String
    /// One sentence on what the step covers; older lists and short steps have none.
    public var detail: String?
    public var status: Status

    public init(text: String, detail: String? = nil, status: Status) {
        self.text = text; self.detail = detail; self.status = status
    }
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
                let detail = item["detail"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                return Todo(text: text, detail: detail, status: status)
            })
        case "task":
            var cost: Double?
            if case .number(let c)? = d["costUsd"] { cost = c }
            return .task(sessionId: d["sessionId"]?.stringValue, status: d["status"]?.stringValue, costUsd: cost)
        case "plan":
            let strings = { (key: String) -> [String] in
                guard case .array(let items)? = d[key] else { return [] }
                return items.compactMap(\.stringValue)
            }
            var edited = false
            if case .bool(let e)? = d["edited"] { edited = e }
            return .plan(PlanDetails(summary: d["summary"]?.stringValue ?? "", steps: strings("steps"), files: strings("files"), risks: strings("risks"), outcome: d["outcome"]?.stringValue, edited: edited, note: d["note"]?.stringValue))
        case "files":
            guard case .array(let files)? = d["files"] else { return nil }
            return .files(files.compactMap { f in
                guard let path = f["path"]?.stringValue else { return nil }
                var size: Int?
                if case .number(let n)? = f["size"] { size = Int(n) }
                var missing = false
                if case .bool(let m)? = f["missing"] { missing = m }
                return PresentedFile(path: path, name: f["name"]?.stringValue ?? (path as NSString).lastPathComponent, description: f["description"]?.stringValue, size: size, missing: missing)
            })
        case "learn":
            guard case .array(let items)? = d["items"] else { return nil }
            return .learn(file: d["file"]?.stringValue, items: items.compactMap { i in
                guard let text = i["text"]?.stringValue, let to = i["to"]?.stringValue.flatMap(LearnItem.Destination.init(rawValue:)) else { return nil }
                var projectOnly: Bool?
                if case .bool(let b)? = i["projectOnly"] { projectOnly = b }
                return LearnItem(to: to, text: text, why: i["why"]?.stringValue, section: i["section"]?.stringValue, name: i["name"]?.stringValue, body: i["body"]?.stringValue, addTo: i["addTo"]?.stringValue, projectOnly: projectOnly)
            })
        case "conversations":
            guard case .array(let items)? = d["conversations"] else { return nil }
            var withheld = 0
            if case .number(let n)? = d["withheld"] { withheld = Int(n) }
            return .conversations(items.compactMap { c in
                guard let id = c["id"]?.stringValue else { return nil }
                return PastConversation(id: id, title: c["title"]?.stringValue ?? "Untitled", kind: c["kind"]?.stringValue ?? "thread")
            }, withheld: withheld)
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
    /// A run of an agent, shown in its owner's conversation as a line (docs/spec/21 D3); it opens as `run:<id>`.
    /// `automation`: the automation that started it (docs/spec/27 §4), "From <name>".
    public struct Run: Codable, Sendable, Hashable {
        public struct Origin: Codable, Sendable, Hashable { public var id, name: String }
        public var id, status: String; public var sent: Int; public var summary: String?; public var costUsd: Double?; public var automation: Origin?
    }
    public var id, at: String
    public var level: Level
    public var text: String
    public var run: Run?
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

/// A turn's tool calls as one line (agents' conversations, 06-agents UI2).
public struct StepsItem: Codable, Sendable, Hashable {
    public var id, at: String
    public var tools: [ToolItem]
    /// What the model thought in the answers that only called these tools (folded into the line).
    public var thinking: String?
    public var thinkingMs: Double?
}

/// An agent's tool call waiting for the owner, or how it was answered (06-agents §9 AS1).
public struct ApprovalItem: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case pending, approved, denied, expired, cancelled }
    public var id, at, approvalId, tool, title: String
    public var args: JSONValue
    public var status: Status
    public var editedArgs: JSONValue?
    public var reason: String?
    public var expiresAt: String
    /// "Always allow messages to María".
    public var always: String
    /// "connector": a connected app's change in a chat (Allow / Deny, no editing). Else an agent's.
    public var source: String?
}

/// What an agent's tool changed, with Undo while it lasts (06-agents §4.2).
public struct ResultItem: Codable, Sendable, Hashable {
    /// `automation`: an automation made or changed (docs/spec/27 §4), with what its card shows.
    public struct Card: Codable, Sendable, Hashable { public var kind, title: String; public var detail: String?; public var automation: AutomationSummary? }
    public struct Undo: Codable, Sendable, Hashable {
        public enum Status: String, Codable, Sendable { case available, undone, failed, expired }
        public var id: String; public var status: Status; public var until: String
    }
    public var id, at, callId: String
    public var card: Card
    public var undo: Undo?
}

/// A message between two of the owner's agents (06-agents §7 AA5).
public struct AgentMsgItem: Codable, Sendable, Hashable {
    public struct Agent: Codable, Sendable, Hashable { public var id, name: String }
    public enum Direction: String, Codable, Sendable { case `in`, out }
    public enum Mode: String, Codable, Sendable { case ask, tell, reply }
    public enum Status: String, Codable, Sendable { case waiting, replied, noReply = "no_reply", sent, failed }
    public var id, at: String
    public var fromAgent, toAgent: Agent
    public var text: String
    public var direction: Direction
    public var mode: Mode
    public var status: Status?
    public var reply: String?
    public var traceId: String?
}

public enum TimelineItem: Codable, Sendable, Hashable, Identifiable {
    case user(UserItem)
    case assistant(AssistantItem)
    case tool(ToolItem)
    case system(SystemItem)
    case compaction(CompactionItem)
    case checkpoint(CheckpointItem)
    case steps(StepsItem)
    case approval(ApprovalItem)
    case result(ResultItem)
    case agentMsg(AgentMsgItem)

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
        case "steps": self = .steps(try StepsItem(from: decoder))
        case "approval": self = .approval(try ApprovalItem(from: decoder))
        case "result": self = .result(try ResultItem(from: decoder))
        case "agent_msg": self = .agentMsg(try AgentMsgItem(from: decoder))
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
        case .steps(let v): try c.encode("steps", forKey: .kind); try v.encode(to: encoder)
        case .approval(let v): try c.encode("approval", forKey: .kind); try v.encode(to: encoder)
        case .result(let v): try c.encode("result", forKey: .kind); try v.encode(to: encoder)
        case .agentMsg(let v): try c.encode("agent_msg", forKey: .kind); try v.encode(to: encoder)
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
        case .steps(let v): v.id
        case .approval(let v): v.id
        case .result(let v): v.id
        case .agentMsg(let v): v.id
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
    public struct Context: Codable, Sendable, Hashable {
        public struct Breakdown: Codable, Sendable, Hashable {
            public enum Source: String, Codable, Sendable { case request, session }
            public struct Group: Codable, Sendable, Hashable {
                public enum Kind: String, Codable, Sendable { case instructions, tools, conversation, toolUse, attachments, summaries }
                public struct Part: Codable, Sendable, Hashable {
                    public var label: String
                    public var tokens: Double
                }
                public var kind: Kind
                public var tokens: Double
                public var parts: [Part]
            }
            public var source: Source
            public var groups: [Group]
        }
        public var tokens: Double?
        public var window: Double
        public var breakdown: Breakdown?
    }
    public var context: Context?
    /// Build: approval mode and what the session waits on you for.
    public var approvalMode: ApprovalMode?
    public var prompts: [PendingPrompt]?
    /// Build: the agent's checklist, and plan mode.
    public var todos: [Todo]?
    public var planMode: Bool?
    /// The conversation just changed who runs it and hasn't sent anything since: who ran it before (the composer's
    /// Undo, docs/spec/31 CA7).
    public struct Handoff: Codable, Sendable, Hashable { public var from: ModelRef }
    public var handoff: Handoff?
    /// Build: commands the agent left running (docs/spec/05-build §9 TM4).
    public var processes: [BackgroundProcess]?
    public init(status: SessionStatus, queue: [QueuedInput], model: ModelRef?, thinking: String?, tools: Tools? = nil, usage: Usage, context: Context? = nil) {
        self.status = status; self.queue = queue; self.model = model; self.thinking = thinking; self.tools = tools; self.usage = usage; self.context = context
    }
}

/// A command the agent started with bash `background: true` (docs/spec/05-build §9 TM4).
public struct BackgroundProcess: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case running, exited, stopped }
    public var id: String
    public var command: String
    public var description: String?
    public var cwd: String
    public var status: Status
    public var exitCode: Int?
    public var startedAt: String
    public var endedAt: String?
    /// Local addresses it printed (a dev server's).
    public var urls: [String]
}
public struct ProcessOutputParams: Encodable, Sendable {
    public var ref: ContainerRef; public var id: String; public var since: Double?
    public init(ref: ContainerRef, id: String, since: Double?) { self.ref = ref; self.id = id; self.since = since }
}
public struct ProcessOutputResult: Decodable, Sendable { public var text: String; public var next: Double; public var process: BackgroundProcess }
public struct ProcessStopParams: Encodable, Sendable {
    public var ref: ContainerRef; public var id: String
    public init(ref: ContainerRef, id: String) { self.ref = ref; self.id = id }
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
    /// A temporary chat (docs/spec/14 M4): deleted at `expiresAt`, 24 hours after its last message, unless kept.
    public struct Temporary: Codable, Sendable, Hashable { public var expiresAt: String }
    public var temporary: Temporary?
    /// Its /learn cards by tool call (docs/spec/14 M5).
    public var learned: [String: LearnState]?
    /// A conversation about an app (docs/spec/35 §15): the app's file.
    public var app: String?
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    public var cwd: String?
    public var model: ModelRef?
    /// Build: the project folder (differs from `cwd` for worktree sessions), and the worktree if any.
    public var projectPath: String?
    /// Build: the latest review by an agent of this session (05-build "Review by an agent").
    public var review: ReviewInfo?
    public var worktree: WorktreeInfo?
    /// A subagent's session: the parent session and its `task` call.
    /// A subagent's parent, and its state (queued, working, done, failed, stopped) with a line while it works (17 §3).
    public struct Parent: Codable, Sendable, Hashable { public var id: String; public var callId: String; public var state: String?; public var line: String?; public var startedAt: String?; public var endedAt: String?; public var costUsd: Double?; public var brief: String?; public var alert: String?; public var agent: String? }
    public var parent: Parent?
    /// A helper's session (docs/spec/26 CL4): made by Piopio for a task on a project's board.
    public struct Helper: Codable, Sendable, Hashable { public var project: String; public var kind: String; public var taskId: String }
    public var helper: Helper?
    /// Listed with the project's conversations: yours, all with Piopio; helpers' sessions are reached from their tasks.
    public var listed: Bool { parent == nil && helper == nil }
    /// A side conversation (docs/spec/24): where it was started from, how ("asked" or "manual"), its state
    /// (queued, working, needs_you, done, failed, stopped) and, while it works, a line on what it's doing.
    public struct Side: Codable, Sendable, Hashable { public var parent: Link; public var how: String; public var state: String; public var line: String?; public var from: String? }
    public var side: Side?
    /// Side conversations Piopio proposed from here (docs/spec/24 §3): cards you may start until they expire.
    public struct SideProposal: Codable, Sendable, Hashable, Identifiable { public var id, title, why, expiresAt: String; public var project: String? }
    public var sideProposals: [SideProposal]?
    /// Its pull request (docs/spec/05-build G6–G7): checks is "pending", "passing", "failing" or "none".
    public struct PR: Codable, Sendable, Hashable { public var repo, url, title, head, base, state: String; public var number: Int; public var checks: String? }
    public var pr: PR?
    /// A chat continued in a project folder, and the conversation it continued from (18 §5).
    public struct Link: Codable, Sendable, Hashable { public var id: String; public var title: String }
    public var continuedIn: Link?
    public var continuedFrom: Link?
    /// Project sessions: "build" (coding) or "chat" (knowledge assistant).
    public enum Profile: String, Codable, Sendable { case build, chat }
    public var profile: Profile?
    /// Next messages suggested after the latest answer (docs/design v2 "You could also").
    public var followUps: [String]?
    /// Connectors and MCP servers turned off in this conversation only ("connector:<id>", "mcp:<server>").
    public var toolsOff: [String]?
    /// Agents.
    public var agent: AgentInfo?
}

public struct AgentInfo: Codable, Sendable, Hashable {
    public struct Contact: Codable, Sendable, Hashable, Identifiable { public var id: String; public var name: String; public var role: String }
    public var slug: String
    public var avatar: String?
    public var description: String?
    public var folder: String
    public var location: String
    public var model: String
    public var contacts: [Contact]
    public var invalid: Bool?
    /// Some tool calls wait for the owner: the header's "Asks first".
    public var asksFirst: Bool?
    /// Just made, still learning its job by talking (docs/spec/21 D4).
    public var draft: Bool?
    public struct Status: Codable, Sendable, Hashable { public var paused: Bool; public var spendUsd: Double; public var budgetUsd: Double?; public var inbox: Int; public var nextRun: String? }
    public var status: Status?
}

/// `avatar` is "symbol:<SF Symbol>"; `instructions` may contain "{owner}"; `schedule` is the first schedule's cron.
public struct AgentTemplate: Decodable, Sendable, Hashable, Identifiable {
    public var id, name, avatar, description: String
    public var instructions: String?
    public var schedule: String?
}
public struct AgentTemplatesResult: Decodable, Sendable { public var templates: [AgentTemplate] }
public struct CreateAgentParams: Encodable, Sendable {
    /// The schedule at creation: the template's, none, or this cron.
    public enum Schedule: Sendable, Equatable { case template, none, cron(String) }
    public var name: String; public var template: String?; public var avatar: String?; public var model: ModelRef?; public var owner: String?
    /// Replaces the template's instructions when set.
    public var instructions: String?
    public var schedule: Schedule
    public init(name: String, template: String?, avatar: String?, model: ModelRef?, owner: String?, instructions: String? = nil, schedule: Schedule = .template) {
        self.name = name; self.template = template; self.avatar = avatar; self.model = model; self.owner = owner; self.instructions = instructions; self.schedule = schedule
    }
    enum CodingKeys: String, CodingKey { case name, template, avatar, model, owner, instructions, schedule }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(template, forKey: .template)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(owner, forKey: .owner)
        try c.encodeIfPresent(instructions, forKey: .instructions)
        switch schedule {
        case .template: break
        case .none: try c.encodeNil(forKey: .schedule)
        case .cron(let cron): try c.encode(cron, forKey: .schedule)
        }
    }
}
public struct DefinitionError: Codable, Sendable, Hashable {
    public var path: String
    public var message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}
public struct AgentGetResult: Decodable, Sendable {
    public struct Commit: Decodable, Sendable, Hashable { public var commit, at, message: String }
    public var definition: JSONValue
    public var instructions: String
    public var folder: String
    public var errors: [DefinitionError]
    public var history: [Commit]
}
public struct AgentSaveParams: Encodable, Sendable {
    public var ref: ContainerRef; public var definition: JSONValue; public var instructions: String; public var message: String?
    public init(ref: ContainerRef, definition: JSONValue, instructions: String, message: String?) { self.ref = ref; self.definition = definition; self.instructions = instructions; self.message = message }
}
public struct AgentSaveResult: Decodable, Sendable { public var errors: [DefinitionError]; public var saved: Bool }
public struct AgentPerson: Decodable, Sendable, Hashable, Identifiable {
    public var contactId, name, role, conversationId: String
    public var started: Bool
    public var lastAt: String?
    public var preview: String?
    public var id: String { contactId }
}
public struct AgentPeopleResult: Decodable, Sendable { public var people: [AgentPerson] }
/// The Runs tab (06-agents §6): runs newest first, messages held by quiet hours or the daily limit, what fires next.
// MARK: A project's work (docs/spec/26)

/// How work is done in a project (docs/spec/26 §4).
public struct WayOfWorking: Codable, Sendable, Hashable {
    /// Piopio may split work onto the board.
    public var parallel: Bool
    /// Every task is reviewed, and sent back at most `reviewLimit` times before you're asked.
    public var review: Bool
    public var reviewLimit: Int
    /// The checks, run after each merge.
    public var testCommand: String?
    /// Tasks at once.
    public var maxParallel: Int
    /// "provider:id"; nil: the project's model (the reviewers': the build model).
    public var buildModel: String?
    public var reviewModel: String?
    /// What helpers may do without asking: read_only, ask, auto_edit or full_auto.
    public var helperMode: String
    public var budgetPerJob: Double?
    /// The playbook Piopio plans with.
    public var playbook: String
}

public struct WorkTask: Codable, Sendable, Hashable, Identifiable {
    public var id, title, brief, helper, state, by: String
    /// The conversation that made it; its updates go there.
    public var conversationId: String?
    public var done: String?
    public var sessionId: String?
    public var reviewSessionId: String?
    public var branch: String?
    public var report: String?
    public var review: String?
    public var attempts: Int
    public var blocked: String?
    /// When its work was merged into the project's branch.
    public var landed: String?
    public var createdAt, updatedAt: String
}

/// A project's work: its way of working, board and branch. None until parallel work was first switched on.
public struct ProjectWork: Codable, Sendable, Hashable, Identifiable {
    public struct Git: Codable, Sendable, Hashable { public var base, branch, integration: String }
    public var project, cwd, createdAt: String
    public var way: WayOfWorking
    public var git: Git?
    public var tasks: [WorkTask]
    public var id: String { project }
}
// MARK: GitHub (docs/spec/05-build G4–G8)

public struct GitHubStatus: Decodable, Sendable, Hashable { public var connected: Bool; public var via: String?; public var login: String?; public var error: String? }
public struct GitHubTokenParams: Encodable, Sendable { public var token: String; public init(token: String) { self.token = token } }
public struct GitHubLogin: Decodable, Sendable { public var login: String }
public struct GitHubRepo: Decodable, Sendable, Hashable, Identifiable { public var fullName, cloneUrl, updatedAt, defaultBranch: String; public var description: String?; public var `private`: Bool; public var id: String { fullName } }
public struct GitHubReposResult: Decodable, Sendable { public var repos: [GitHubRepo] }
public struct GitHubCloneParams: Encodable, Sendable { public var repo: String; public init(repo: String) { self.repo = repo } }
public struct GitHubCloneResult: Decodable, Sendable { public var project: ProjectInfo }
/// A pull request now: its state, checks and comments.
public struct PrStatus: Decodable, Sendable, Hashable {
    public struct Check: Decodable, Sendable, Hashable { public var name, status: String; public var conclusion: String?; public var url: String? }
    public struct Comment: Decodable, Sendable, Hashable, Identifiable { public var id, author, body, at, kind: String; public var bot: Bool; public var url: String?; public var path: String?; public var line: Int? }
    public var repo, url, title, state, head, base, summary: String
    public var number: Int
    public var draft: Bool
    public var checks: [Check]
    public var comments: [Comment]
}
public struct PrResult: Decodable, Sendable { public var pr: PrStatus }
public struct PrDraft: Decodable, Sendable { public var title, body, head, base: String }
public struct CreatePrParams: Encodable, Sendable {
    public var ref: ContainerRef; public var title, body: String; public var base: String?; public var draft: Bool?
    public init(ref: ContainerRef, title: String, body: String, base: String?, draft: Bool) { self.ref = ref; self.title = title; self.body = body; self.base = base; self.draft = draft ? true : nil }
}
public struct AddressPrParams: Encodable, Sendable { public var ref: ContainerRef; public var what: String; public init(ref: ContainerRef, what: String) { self.ref = ref; self.what = what } }
public struct WorkPrParams: Encodable, Sendable {
    public var project, title, body: String; public var draft: Bool?
    public init(project: String, title: String, body: String, draft: Bool) { self.project = project; self.title = title; self.body = body; self.draft = draft ? true : nil }
}

/// A Watchdog note about one of your conversations (docs/spec/17 §4): "silent" or "looping".
public struct WatchdogNote: Decodable, Sendable, Hashable, Identifiable { public var id, title, rule, text, at: String; public var ref: ContainerRef }
public struct WatchdogListResult: Decodable, Sendable { public var notes: [WatchdogNote] }
public struct IdParams: Encodable, Sendable { public var id: String; public init(id: String) { self.id = id } }
/// Your answer to a side card: an offer's "new" or "here", a proposal's "start" or "dismiss".
public struct AnswerSideParams: Encodable, Sendable {
    public var ref: ContainerRef
    public var id, choice: String
    public init(ref: ContainerRef, id: String, choice: String) { self.ref = ref; self.id = id; self.choice = choice }
}
public struct AnswerSideResult: Decodable, Sendable { public var ref: ContainerRef?; public var askAlways: Bool? }
/// A side conversation by hand (`/side <what>`, docs/spec/24 §6).
public struct StartSideParams: Encodable, Sendable {
    public var ref: ContainerRef
    public var brief: String
    public init(ref: ContainerRef, brief: String) { self.ref = ref; self.brief = brief }
}
public struct WorkListResult: Decodable, Sendable { public var work: [ProjectWork] }
public struct WorkResult: Decodable, Sendable { public var work: ProjectWork }

/// A change to how work is done in a project. "" clears a model or the checks; a budget of 0 clears it.
public struct ConfigureWorkParams: Encodable, Sendable {
    public var project: String
    public var parallel, review: Bool?
    public var reviewLimit, maxParallel: Int?
    public var testCommand, buildModel, reviewModel, helperMode, playbook: String?
    public var budgetPerJob: Double?
    /// A folder without git: make it a repo first, so tasks get branches (the fit check's fix).
    public var initGit: Bool?
    public init(project: String, parallel: Bool? = nil, review: Bool? = nil, reviewLimit: Int? = nil, maxParallel: Int? = nil, testCommand: String? = nil, buildModel: String? = nil, reviewModel: String? = nil, helperMode: String? = nil, playbook: String? = nil, budgetPerJob: Double? = nil, initGit: Bool? = nil) {
        self.project = project; self.parallel = parallel; self.review = review; self.reviewLimit = reviewLimit; self.maxParallel = maxParallel; self.testCommand = testCommand; self.buildModel = buildModel; self.reviewModel = reviewModel; self.helperMode = helperMode; self.playbook = playbook; self.budgetPerJob = budgetPerJob; self.initGit = initGit
    }
}
/// "Work in parallel" on Piopio's offer: parallel work goes on, and that conversation plans it.
public struct AcceptWorkParams: Encodable, Sendable {
    public var project, sessionId: String
    public init(project: String, sessionId: String) { self.project = project; self.sessionId = sessionId }
}
public struct Playbook: Decodable, Sendable, Hashable, Identifiable { public var id, name, description, source: String }
public struct PlaybooksResult: Decodable, Sendable { public var playbooks: [Playbook] }
public struct MigrationReport: Decodable, Sendable { public var report: String? }

/// What the work branch would bring to the project's branch (the merge card).
public struct WorkLanding: Decodable, Sendable, Hashable {
    public struct File: Decodable, Sendable, Hashable { public var path: String; public var added, removed: Int }
    public struct Task: Decodable, Sendable, Hashable { public var id, title: String }
    public var base, branch: String
    public var ahead, behind, open: Int
    public var files: [File]
    public var tasks: [Task]
    public var checkedOut: String?
    public var remote: String?
    public var compareUrl: String?
}
public struct WorkLandParams: Encodable, Sendable {
    public var project, action: String
    public init(project: String, action: String) { self.project = project; self.action = action }
}
public struct WorkLandResult: Decodable, Sendable { public var commit: String?; public var compareUrl: String?; public var output: String? }

/// What a conversation's tasks cost (docs/spec/21 D1): the merge card's "$0.36".
public struct WorkJobParams: Encodable, Sendable {
    public var project, conversationId: String
    public init(project: String, conversationId: String) { self.project = project; self.conversationId = conversationId }
}
public struct WorkJob: Decodable, Sendable, Hashable { public var cost: Double; public var tasks: Int; public var budget: Double? }

/// What parallel work needs in a project (docs/spec/21 D6): git, the checks found there, AGENTS.md.
public struct FitCheckParams: Encodable, Sendable { public var cwd: String; public init(cwd: String) { self.cwd = cwd } }
public struct FitCheck: Decodable, Sendable, Hashable { public var git: Bool; public var checks: String?; public var agentsMd: Bool; public var language: String? }

/// Home's agenda (docs/spec/21 D2): today's timeline and what happened since your last visit.
public struct HomeAgenda: Decodable, Sendable, Hashable {
    public struct Source: Decodable, Sendable, Hashable { public var kind, id, name: String }
    /// `automation`: the automation the line belongs to (docs/spec/27 AU10); clicking it opens it.
    public struct Today: Decodable, Sendable, Hashable { public var at: String?; public var label: String; public var source: Source; public var automation: String?; public var state: String; public var tomorrow: Bool? }
    public struct Away: Decodable, Sendable, Hashable { public var at: String; public var source: Source; public var automation: String?; public var text: String; public var costUsd: Double?; public var quiet: Bool; public var failed: Bool? }
    public var today: [Today]
    public var away: [Away]
    public var held: Int
}
public struct HomeAgendaParams: Encodable, Sendable { public var since: String?; public init(since: String?) { self.since = since } }

/// An automation (docs/spec/27): work that starts when nobody started it. A trigger (`on`: a time, a folder, an email,
/// a webhook), who runs it (`runsAs`: "piopio" or an agent's id), the prompt, a project (Piopio only), where the result
/// goes, and what it may do while you're away. `label`, `runnerName` and `resultLabel` are the engine's words for it.
public struct Automation: Codable, Sendable, Hashable, Identifiable {
    public var id, name, on, runsAs, prompt, result, approval, by, createdAt: String
    public var cron: String?
    public var at: Double?
    public var tz: String?
    public var folder: String?
    public var from: String?
    public var subject: String?
    public var project: String?
    public var deliverTo: String?
    public var budgetPerRunUsd: Double?
    public var enabled: Bool
    public var next: Double?
    public var lastRun: String?
    public var runCount: Int
    public var fresh: Bool?
    public var label, runnerName, resultLabel: String
    public var url: String?
    public var lastStatus: String?
    public var lastSummary: String?
    public var isPiopio: Bool { runsAs == "piopio" }

    /// One the app holds before the engine has it (the New automation draft): the engine's words come from the app.
    public init(id: String, name: String, on: String, runsAs: String, prompt: String, result: String, approval: String, by: String = "you", createdAt: String = "",
                cron: String? = nil, at: Double? = nil, folder: String? = nil, from: String? = nil, subject: String? = nil, project: String? = nil,
                budgetPerRunUsd: Double? = nil, enabled: Bool = false, next: Double? = nil, label: String, runnerName: String, resultLabel: String) {
        self.id = id; self.name = name; self.on = on; self.runsAs = runsAs; self.prompt = prompt; self.result = result; self.approval = approval
        self.by = by; self.createdAt = createdAt; self.cron = cron; self.at = at; self.folder = folder; self.from = from; self.subject = subject
        self.project = project; self.budgetPerRunUsd = budgetPerRunUsd; self.enabled = enabled; self.next = next; self.runCount = 0
        self.label = label; self.runnerName = runnerName; self.resultLabel = resultLabel
    }
}
public struct AutomationRun: Codable, Sendable, Hashable, Identifiable {
    public var id, automation, firedAt, cause, status: String
    public var summary: String?
    public var costUsd: Double?
    /// A Piopio run's conversation (a session id), or an agent's run (`run:<id>`, opened in that agent).
    public var conversation: String?
    public var agent: String?
    public var agentRun: String?
}
/// What a card shows (docs/spec/27 §4): when, who runs it, what it does, where the result goes, where it runs.
public struct AutomationSummary: Codable, Sendable, Hashable {
    public var id, name, when, runsAs, does, tellsYou, runsOn: String
    public var url: String?
    public var next: Double?
    public init(id: String, name: String, when: String, runsAs: String, does: String, tellsYou: String, runsOn: String, url: String? = nil, next: Double? = nil) {
        self.id = id; self.name = name; self.when = when; self.runsAs = runsAs; self.does = does; self.tellsYou = tellsYou; self.runsOn = runsOn; self.url = url; self.next = next
    }
}
/// A new automation or a change: the trigger in words (`when`), the rest as the record. `project` and
/// `budgetPerRunUsd` set to `.clear` remove them.
public struct AutomationChange: Encodable, Sendable {
    public enum Value<T: Encodable & Sendable>: Encodable, Sendable {
        case set(T), clear
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .set(let v): try c.encode(v); case .clear: try c.encodeNil() }
        }
    }
    public var id: String?
    public var name, on, when, folder, from, subject, runsAs, prompt, result, approval: String?
    public var project: Value<String>?
    public var budgetPerRunUsd: Value<Double>?
    public var enabled: Bool?
    public init(id: String? = nil, name: String? = nil, on: String? = nil, when: String? = nil, folder: String? = nil, from: String? = nil, subject: String? = nil, runsAs: String? = nil, project: Value<String>? = nil, prompt: String? = nil, result: String? = nil, approval: String? = nil, budgetPerRunUsd: Value<Double>? = nil, enabled: Bool? = nil) {
        self.id = id; self.name = name; self.on = on; self.when = when; self.folder = folder; self.from = from; self.subject = subject; self.runsAs = runsAs
        self.project = project; self.prompt = prompt; self.result = result; self.approval = approval; self.budgetPerRunUsd = budgetPerRunUsd; self.enabled = enabled
    }
}
// MARK: Library (docs/spec/35 §4)

/// One thing Piopio or an agent made: a file where it lives, or a visual still in its conversation. The engine calls it
/// `LibraryItem`; SwiftUI already has a type by that name.
public struct LibraryEntry: Codable, Sendable, Hashable, Identifiable {
    public struct Origin: Codable, Sendable, Hashable {
        public var ref: ContainerRef
        public var title: String
        /// The project's folder.
        public var project: String?
    }
    public struct Visual: Codable, Sendable, Hashable {
        public var callId: String
        /// A hash of its HTML: a new one means a new picture.
        public var version: String?
    }
    public var id: String
    /// app · document · page · visual · image · data · slides · file
    public var kind: String
    public var name: String
    public var path: String?
    public var note: String?
    public var at: String
    /// "Piopio", an agent's name, or "You".
    public var by: String
    /// presented · written · visual · added
    public var how: String
    public var origin: Origin?
    public var visual: Visual?
    public var missing: Bool?
    public var size: Int?
    public var changedAt: String?
    public var pinned: Bool?
    public init(id: String, kind: String, name: String, path: String? = nil, note: String? = nil, at: String, by: String, how: String, origin: Origin? = nil, visual: Visual? = nil, missing: Bool? = nil, size: Int? = nil, changedAt: String? = nil, pinned: Bool? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.path = path; self.note = note; self.at = at; self.by = by; self.how = how
        self.origin = origin; self.visual = visual; self.missing = missing; self.size = size; self.changedAt = changedAt; self.pinned = pinned
    }
}
public struct LibraryVisual: Decodable, Sendable { public var title: String; public var html: String }
public struct LibraryList: Decodable, Sendable {
    public var items: [LibraryEntry]
    public var pins: [String]
    /// What you removed, to put back.
    public var removed: [LibraryEntry]?
}
public struct LibrarySavedParams: Encodable, Sendable { public var callId, path: String; public init(callId: String, path: String) { self.callId = callId; self.path = path } }
public struct LibraryEntryResult: Decodable, Sendable { public var item: LibraryEntry }
public struct LibraryPinParams: Encodable, Sendable { public var id: String; public var pinned: Bool; public init(id: String, pinned: Bool) { self.id = id; self.pinned = pinned } }
public struct LibraryIdsParams: Encodable, Sendable { public var ids: [String]; public init(ids: [String]) { self.ids = ids } }
public struct LibraryIdParams: Encodable, Sendable { public var id: String; public init(id: String) { self.id = id } }
public struct LibraryPathParams: Encodable, Sendable { public var path: String; public init(path: String) { self.path = path } }
public struct LibraryRelocateParams: Encodable, Sendable { public var id, path: String; public init(id: String, path: String) { self.id = id; self.path = path } }

// MARK: Apps (docs/spec/35 §14)

/// One source of an app: a file, its last read, and why it failed.
public struct AppSourceStatus: Codable, Sendable, Hashable {
    public struct Account: Codable, Sendable, Hashable {
        public var id: String
        public var label: String
        /// ok · failed (its last good events are shown) · gone (disconnected: nothing of it is shown)
        public var state: String
        public var error: String?
        public var readAt: String?
        public var failedAt: String?
    }
    public var name: String
    /// file · calendar (docs/spec/35 §16) · piopio (Piopio's own numbers, L4)
    public var kind: String?
    /// As the manifest says it: relative to the app's file, or absolute; a calendar source in words.
    public var file: String
    /// A file source's path ("" for a calendar).
    public var path: String
    public var columns: [String]?
    /// A calendar source: each account and how its last read went.
    public var accounts: [Account]?
    /// ok · failed (the page has the last good data) · waiting (not allowed yet)
    public var state: String
    public var error: String?
    public var readAt: String?
    public var failedAt: String?
}

/// An app as it is now: its page, each source's state, and what `piopio.onData` gets.
public struct AppView: Codable, Sendable, Hashable {
    public var path: String
    public var title: String
    public var html: String
    public var sources: [AppSourceStatus]
    public var data: [String: JSONValue]
    public var stale: [String]
    /// False when the manifest lists sources not allowed yet: the page draws what was read before.
    public var allowed: Bool
    public var updatedAt: String?
    /// The latest change the app's conversation made that Undo would take back.
    public var undo: AppUndo?
    /// The conversation about it (a chat's id), once there is one.
    public var conversation: String?
}
public struct AppUndo: Codable, Sendable, Hashable { public var label: String; public var at: String }
public struct AppConversationResult: Decodable, Sendable { public var ref: ContainerRef }
public struct AppUndoParams: Encodable, Sendable { public var path: String; public var force: Bool; public init(path: String, force: Bool) { self.path = path; self.force = force } }
public struct AppResult: Decodable, Sendable { public var app: AppView }

public struct AutomationsParams: Encodable, Sendable {
    public var runsAs, project: String?
    public init(runsAs: String? = nil, project: String? = nil) { self.runsAs = runsAs; self.project = project }
}
public struct AutomationIdParams: Encodable, Sendable { public var id: String; public init(id: String) { self.id = id } }
public struct AutomationsResult: Decodable, Sendable { public var automations: [Automation] }
public struct AutomationResult: Decodable, Sendable { public var automation: Automation }
public struct AutomationDetail: Decodable, Sendable { public var automation: Automation; public var runs: [AutomationRun]; public var summary: AutomationSummary }
public struct AutomationRunResult: Decodable, Sendable { public var run: AutomationRun }
public struct ProjectParams: Encodable, Sendable { public var project: String; public init(project: String) { self.project = project } }

public struct AddWorkTaskParams: Encodable, Sendable {
    public var project, title, brief: String
    public init(project: String, title: String, brief: String) { self.project = project; self.title = title; self.brief = brief }
}
public struct UpdateWorkTaskParams: Encodable, Sendable {
    public var project, taskId: String
    public var state: String?
    public init(project: String, taskId: String, state: String? = nil) { self.project = project; self.taskId = taskId; self.state = state }
}

public struct AgentRunsResult: Decodable, Sendable {
    public struct Run: Decodable, Sendable, Hashable, Identifiable {
        public var id, kind, source, prompt, firedAt, status: String
        public var summary: String?
        public var sent: Int
        public var costUsd: Double?
    }
    public struct Held: Decodable, Sendable, Hashable, Identifiable { public var id, to, text, notBefore, reason: String }
    public struct Upcoming: Decodable, Sendable, Hashable, Identifiable { public var id, kind, label: String; public var next: String?; public var cron: String? }
    public var runs: [Run]
    public var outbox: [Held]
    public var upcoming: [Upcoming]
}
public struct AgentRunNowParams: Encodable, Sendable {
    public var ref: ContainerRef; public var scheduleId: String?; public var prompt: String?
    /// A trial run right after it's set up (docs/spec/21 D4).
    public var trial: Bool?
    public init(ref: ContainerRef, scheduleId: String? = nil, prompt: String? = nil, trial: Bool = false) { self.ref = ref; self.scheduleId = scheduleId; self.prompt = prompt; self.trial = trial ? true : nil }
}
public struct AgentRunNowResult: Decodable, Sendable { public var runId: String }
public struct AgentDecideParams: Encodable, Sendable {
    public var ref: ContainerRef; public var approvalId: String; public var approve: Bool; public var args: JSONValue?; public var always: Bool?; public var reason: String?
    public init(ref: ContainerRef, approvalId: String, approve: Bool, args: JSONValue? = nil, always: Bool? = nil, reason: String? = nil) { self.ref = ref; self.approvalId = approvalId; self.approve = approve; self.args = args; self.always = always; self.reason = reason }
}
public struct AgentUndoParams: Encodable, Sendable { public var ref: ContainerRef; public var undoId: String; public init(ref: ContainerRef, undoId: String) { self.ref = ref; self.undoId = undoId } }
public struct AgentPauseParams: Encodable, Sendable { public var ref: ContainerRef; public var paused: Bool; public init(ref: ContainerRef, paused: Bool) { self.ref = ref; self.paused = paused } }
/// The Inbox across agents (06-agents §12, docs/design 4d).
public struct InboxItem: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var agent: ContainerRef
    public var agentName: String
    public var avatar: String?
    public var kind: String
    public var at, title, body: String
    public var needsYou: Bool
    public var read: Bool
    public var conversationId: String?
    public var approval: ApprovalItem?
}
public struct InboxListResult: Decodable, Sendable { public var count: Int; public var items: [InboxItem] }
/// `fold`: a turn's tool calls come as one steps item (the folded activity line).
public struct SubscribeParams: Encodable, Sendable { public var ref: ContainerRef; public var fold: Bool?; public init(ref: ContainerRef, fold: Bool? = nil) { self.ref = ref; self.fold = fold } }
/// What the model provider has billed (OpenRouter's key endpoint): the sidebar's "$0.05 today", Settings › Models.
public struct UsageSummary: Decodable, Sendable, Equatable {
    public var connected: Bool
    public var keyHint: String?
    public var todayUsd: Double?
    public var monthUsd: Double?
    public var totalUsd: Double?
}
public struct UsageParams: Encodable, Sendable { public var refresh: Bool?; public init(refresh: Bool? = nil) { self.refresh = refresh } }
/// A trace between agents (06-agents §7 AA5): its messages as a tree, with what answering cost.
public struct AgentTrace: Decodable, Sendable {
    public struct Hop: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var parent: String?
        public var hop: Int
        public var mode: String
        public var from, to: AgentMsgItem.Agent
        public var text: String
        public var reply: String?
        public var at, status: String
        public var costUsd: Double?
        public var error: String?
    }
    public var traceId: String
    public var costUsd: Double
    public var hops: [Hop]
}
public struct TraceParams: Encodable, Sendable { public var traceId: String; public init(traceId: String) { self.traceId = traceId } }
public struct InboxReadParams: Encodable, Sendable {
    public struct Item: Encodable, Sendable { public var agentId, id: String; public init(agentId: String, id: String) { self.agentId = agentId; self.id = id } }
    public var items: [Item]
    public init(items: [Item]) { self.items = items }
}
public struct InboxChanged: Decodable, Sendable {
    public struct Approval: Decodable, Sendable { public var agent: ContainerRef; public var agentName, approvalId, title: String }
    public var count: Int
    public var approval: Approval?
}
public struct AgentMemoryResult: Decodable, Sendable {
    public struct Partition: Decodable, Sendable, Hashable, Identifiable { public var id, label, bank: String }
    public var provider: String
    public var partitions: [Partition]
}
/// A file an agent keeps (docs/spec/06-agents §14).
public struct AgentFile: Decodable, Sendable, Hashable, Identifiable {
    public var name: String
    public var note: String?
    /// image, pdf, text or other.
    public var kind: String
    public var size: Double
    public var addedAt: String
    public var path: String
    /// Whether the agent can read it (a PDF dropped in Finder has no text yet).
    public var readable: Bool
    public var id: String { name }
}
public struct AgentFilesResult: Decodable, Sendable { public var files: [AgentFile]; public var folder: String }
public struct AgentFilesAdded: Decodable, Sendable { public var files: [AgentFile] }
public struct AgentFilesAddParams: Encodable, Sendable {
    public var ref: ContainerRef
    public var attachments: [Attachment]
    public init(ref: ContainerRef, attachments: [Attachment]) { self.ref = ref; self.attachments = attachments }
}
public struct AgentFileParams: Encodable, Sendable {
    public var ref: ContainerRef
    public var name: String
    public var note: String?
    public var rename: String?
    public init(ref: ContainerRef, name: String, note: String? = nil, rename: String? = nil) { self.ref = ref; self.name = name; self.note = note; self.rename = rename }
}
public struct MemoryListParams: Encodable, Sendable {
    public var provider, bank: String
    public var cursor: String?
    public var kinds: [String]?
    /// Replaced and ended facts too (learned facts' history).
    public var includeEnded: Bool?
    /// Search instead of listing.
    public var query: String?
    public init(provider: String, bank: String, cursor: String? = nil, kinds: [String]? = nil, includeEnded: Bool? = nil, query: String? = nil) {
        self.provider = provider; self.bank = bank; self.cursor = cursor; self.kinds = kinds; self.includeEnded = includeEnded; self.query = query
    }
}
public struct MemoryRecordInfo: Decodable, Sendable, Hashable, Identifiable {
    public struct Source: Decodable, Sendable, Hashable { public var ref, itemId, title: String? }
    public var id, text, kind, createdBy, at: String
    public var pinned: Bool?
    public var source: Source?
    /// Learned facts (docs/spec/14-memory M2): what it replaced, what replaced it, when it stopped being true.
    public var replaces, replacedBy, endedAt: String?
}
public struct MemoryListResult: Decodable, Sendable { public var records: [MemoryRecordInfo]; public var cursor: String?; public var limited: Bool }
public struct MemoryAddParams: Encodable, Sendable {
    public var provider, bank, text: String
    public var replaces: String?
    public init(provider: String, bank: String, text: String, replaces: String? = nil) { self.provider = provider; self.bank = bank; self.text = text; self.replaces = replaces }
}
public struct MemoryIdParams: Encodable, Sendable {
    public var provider, bank, id: String
    public var pinned: Bool?
    public var text: String?
    public init(provider: String, bank: String, id: String, pinned: Bool? = nil, text: String? = nil) { self.provider = provider; self.bank = bank; self.id = id; self.pinned = pinned; self.text = text }
}

/// Settings › Memory (docs/spec/14-memory M3): every bank of the built-in provider and whose it is.
public struct MemoryBanksResult: Decodable, Sendable, Equatable {
    public struct Agent: Decodable, Sendable, Hashable, Identifiable { public var id, name: String; public var avatar: String?; public var learns: Bool; public var provider: String? }
    public struct Bank: Decodable, Sendable, Hashable, Identifiable {
        public var bank, label, area: String
        public var agent: Agent?
        public var records, facts, messages, ended: Int
        public var updatedAt: String?
        public var id: String { bank }
    }
    public var banks: [Bank]
    public var agents: [Agent]
    public var bytes: Int
}
public struct MemoryHistoryParams: Encodable, Sendable { public var provider, bank: String; public init(provider: String = "builtin", bank: String) { self.provider = provider; self.bank = bank } }
public struct MemoryHistoryResult: Decodable, Sendable {
    public struct Event: Decodable, Sendable, Hashable, Identifiable { public var id, at, action, recordId, text, by: String }
    public var events: [Event]
}
public struct MemoryExportParams: Encodable, Sendable { public var folder: String; public init(folder: String) { self.folder = folder } }
public struct MemoryExportResult: Decodable, Sendable { public var files: [String]; public var records: Int }
public struct MemoryWipeParams: Encodable, Sendable { public var bank: String; public init(bank: String) { self.bank = bank } }
public struct MemoryCountResult: Decodable, Sendable { public var records: Int?; public var pending: Int? }
public struct MemoryLearningParams: Encodable, Sendable { public var ref: ContainerRef; public var learn: Bool; public init(ref: ContainerRef, learn: Bool) { self.ref = ref; self.learn = learn } }

/// The built-in memory's semantic search (docs/spec/14-memory M1): on, or why not, and how much is indexed.
public struct MemoryStatus: Decodable, Sendable, Equatable {
    public var semantic: Bool
    /// "local_only", "no_key" or "failing".
    public var reason: String?
    public var error: String?
    public var model: String?
    public var via: String?
    public var records: Int
    public var indexed: Int
}

/// Engine-wide settings (Settings › Chat, Settings › MCP servers).
/// Where background model work runs (07-shared §1.3): automatic (each conversation's provider), Apple's on-device
/// model, a picked model, or nowhere. On the wire: "auto", "on_device", "off", or a model ref.
public enum UtilityChoice: Codable, Sendable, Hashable {
    case auto, onDevice, off, model(ModelRef)

    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = text == "off" ? .off : text == "on_device" ? .onDevice : .auto
        } else {
            self = .model(try ModelRef(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .auto: var c = encoder.singleValueContainer(); try c.encode("auto")
        case .onDevice: var c = encoder.singleValueContainer(); try c.encode("on_device")
        case .off: var c = encoder.singleValueContainer(); try c.encode("off")
        case .model(let ref): try ref.encode(to: encoder)
        }
    }
}

public struct OnDeviceStatus: Decodable, Sendable, Hashable { public var available: Bool; public var reason: String? }

public struct EngineSettings: Codable, Sendable, Hashable {
    /// Unset: automatic.
    public struct Models: Codable, Sendable, Hashable {
        public var utility: UtilityChoice?
        public init(utility: UtilityChoice? = nil) { self.utility = utility }
    }
    public var models: Models?
    public struct Chat: Codable, Sendable, Hashable {
        public var mcp: Bool; public var mcpServers: [String]?; public var followUps: Bool?
        /// Side conversations (docs/spec/24 §6): "ask" (default), "start" or "off"; proposals; notes that wake.
        public var sideOnUnrelated: String?; public var sidePropose: Bool?; public var sideWake: Bool?
    }
    public struct AboutMe: Codable, Sendable, Hashable { public var enabled, capture, inThreads: Bool; public var inAgents: Bool?; public var provider: String }
    public struct Memory: Codable, Sendable, Hashable {
        public var providers: [McpMemoryProvider]
        /// Search by meaning through OpenRouter (off: by words, on this Mac).
        public var semantic: Bool?
        public var localOnly: Bool?
        /// Conversations may search and read your earlier ones (docs/spec/14 M4); on unless false.
        public var pastChats: Bool?
        public var searchesByMeaning: Bool { localOnly != true && (semantic ?? false) }
    }
    /// Build sessions: the sandbox for commands (default on) and auto review (default off).
    public struct Build: Codable, Sendable, Hashable {
        public var sandbox: Bool?
        public var autoReview: Bool?
        public init(sandbox: Bool? = nil, autoReview: Bool? = nil) { self.sandbox = sandbox; self.autoReview = autoReview }
    }
    public var build: Build?
    public var chat: Chat
    public var aboutMe: AboutMe
    public var memory: Memory
}

/// A memory system reached through its MCP server (07-shared §6.2).
public struct McpMemoryProvider: Codable, Sendable, Hashable, Identifiable {
    public struct Mapping: Codable, Sendable, Hashable {
        public var tool: String
        public var args: [String: JSONValue]
        public init(tool: String, args: [String: JSONValue]) { self.tool = tool; self.args = args }
    }
    public struct Tools: Codable, Sendable, Hashable {
        public var recall: Mapping
        public var retain, list, forget, reflect: Mapping?
        public init(recall: Mapping, retain: Mapping? = nil, list: Mapping? = nil, forget: Mapping? = nil, reflect: Mapping? = nil) { self.recall = recall; self.retain = retain; self.list = list; self.forget = forget; self.reflect = reflect }
    }
    public var id: String
    public var name: String
    public var server: String?
    public var url: String?
    public var tools: Tools
    public init(id: String, name: String, server: String? = nil, url: String? = nil, tools: Tools) { self.id = id; self.name = name; self.server = server; self.url = url; self.tools = tools }
}

/// A pi package (Settings › Extensions).
public struct PiPackage: Codable, Sendable, Hashable, Identifiable {
    public struct Resource: Codable, Sendable, Hashable { public var path: String; public var enabled: Bool }
    public struct Resources: Codable, Sendable, Hashable { public var extensions, skills, prompts, themes: [Resource] }
    public var source: String
    public var kind: String?
    public var name, version, description, latest: String?
    public var installedPath: String?
    public var installed: Bool
    public var enabled: Bool
    public var off: [String]
    public var resources: Resources
    public var id: String { source }
}
/// What a package would add, before installing it.
public struct PackagePreview: Decodable, Sendable, Hashable {
    public var ok: Bool; public var kind: String
    public var name, version, description, author, error: String?
    public var extensions, skills, prompts, themes: [String]
    public var contentsKnown: Bool
}
public struct PackageResourceParams: Encodable, Sendable {
    public var source, kind, path: String; public var enabled: Bool
    public init(source: String, kind: String, path: String, enabled: Bool) { self.source = source; self.kind = kind; self.path = path; self.enabled = enabled }
}
public struct PackagesResult: Decodable, Sendable { public var packages: [PiPackage] }
public struct PackageParams: Encodable, Sendable { public var source: String?; public init(source: String?) { self.source = source } }
public struct PackageEnableParams: Encodable, Sendable {
    public var source: String; public var enabled: Bool; public var kinds: [String]?
    public init(source: String, enabled: Bool, kinds: [String]? = nil) { self.source = source; self.enabled = enabled; self.kinds = kinds }
}
public struct MemoryToolsParams: Encodable, Sendable { public var server: String?; public var url: String?; public init(server: String?, url: String?) { self.server = server; self.url = url } }
public struct MemoryToolsResult: Decodable, Sendable { public struct Tool: Decodable, Sendable, Hashable { public var name: String; public var description: String? }; public var tools: [Tool] }
public struct MemoryRecallParams: Encodable, Sendable { public var provider: String; public var bank: String; public var query: String; public init(provider: String, bank: String, query: String) { self.provider = provider; self.bank = bank; self.query = query } }
public struct MemoryRecallResult: Decodable, Sendable { public struct Hit: Decodable, Sendable, Hashable { public var id: String; public var text: String; public var score: Double }; public var hits: [Hit] }

public struct SettingsPatch: Encodable, Sendable {
    public struct Chat: Encodable, Sendable {
        public var mcp: Bool?; public var followUps: Bool?
        public var sideOnUnrelated: String?; public var sidePropose: Bool?; public var sideWake: Bool?
        public init(mcp: Bool? = nil, followUps: Bool? = nil, sideOnUnrelated: String? = nil, sidePropose: Bool? = nil, sideWake: Bool? = nil) {
            self.mcp = mcp; self.followUps = followUps; self.sideOnUnrelated = sideOnUnrelated; self.sidePropose = sidePropose; self.sideWake = sideWake
        }
    }
    public struct AboutMe: Encodable, Sendable {
        public var enabled, capture, inThreads, inAgents: Bool?
        public var provider: String?
        public init(enabled: Bool? = nil, capture: Bool? = nil, inThreads: Bool? = nil, inAgents: Bool? = nil, provider: String? = nil) { self.enabled = enabled; self.capture = capture; self.inThreads = inThreads; self.inAgents = inAgents; self.provider = provider }
    }
    public struct Memory: Encodable, Sendable {
        public var providers: [McpMemoryProvider]?
        public var semantic: Bool?
        public var localOnly: Bool?
        public var pastChats: Bool?
        public init(providers: [McpMemoryProvider]? = nil, semantic: Bool? = nil, localOnly: Bool? = nil, pastChats: Bool? = nil) { self.providers = providers; self.semantic = semantic; self.localOnly = localOnly; self.pastChats = pastChats }
    }
    public var models: EngineSettings.Models?
    public var build: EngineSettings.Build?
    public var chat: Chat?
    public var aboutMe: AboutMe?
    public var memory: Memory?
    public init(models: EngineSettings.Models? = nil, build: EngineSettings.Build? = nil, chat: Chat? = nil, aboutMe: AboutMe? = nil, memory: Memory? = nil) { self.models = models; self.build = build; self.chat = chat; self.aboutMe = aboutMe; self.memory = memory }
}

public struct TextParams: Encodable, Sendable { public var text: String; public init(text: String) { self.text = text } }
public struct RevisionIdParams: Encodable, Sendable { public var revisionId: String; public init(revisionId: String) { self.revisionId = revisionId } }
/// Turn into an agent (docs/spec/18 phase 3): a draft for the Agent start page.
public struct AgentDraftResult: Decodable, Sendable { public var name: String; public var instructions: String; public var schedule: String? }

public struct ContinueInParams: Encodable, Sendable {
    public var ref: ContainerRef; public var cwd: String
    /// Read only when Build is off (docs/spec/18 §7); nil: the project's own mode.
    public var approvalMode: ApprovalMode?
    public init(ref: ContainerRef, cwd: String, approvalMode: ApprovalMode? = nil) { self.ref = ref; self.cwd = cwd; self.approvalMode = approvalMode }
}
extension SessionSummary: Identifiable {
    public var id: String { ref.key }
}

public struct MemoryRevision: Codable, Sendable, Hashable, Identifiable {
    public struct Author: Codable, Sendable, Hashable { public var kind: String; public var topicId: String?; public var title: String? }
    public var id, at: String
    public var by: Author
    public var summary: String
    public var added, removed: [String]
    public var undone: Bool?
}
public struct MemoryResult: Decodable, Sendable {
    public var text: String
    public var revisions: [MemoryRevision]
    /// About me: the provider it lives in, and whether that provider can list what it stored.
    public var provider: String?
    public var limited: Bool?
}

// MARK: Method params / results

public struct HelloParams: Encodable, Sendable {
    public var token: String; public var client: String; public var protocolVersion: String
    /// Reverse requests this client answers besides secrets.get (03-engine-protocol §3.12): "app.tool".
    public var services: [String]?
}
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
    /// Build: start in Plan mode.
    public var planMode: Bool?
    public var approvalMode: ApprovalMode?
    public var profile: SessionSummary.Profile?
    /// A temporary chat (docs/spec/14 M4): threads with no project only.
    public var temporary: Bool?
    public init(kind: ContainerKind, cwd: String? = nil, model: ModelRef? = nil, thinking: String? = nil, title: String? = nil, workOn: WorkOn? = nil, planMode: Bool? = nil, approvalMode: ApprovalMode? = nil, profile: SessionSummary.Profile? = nil, temporary: Bool? = nil) {
        self.kind = kind; self.cwd = cwd; self.model = model; self.thinking = thinking; self.title = title; self.workOn = workOn; self.planMode = planMode; self.approvalMode = approvalMode; self.profile = profile; self.temporary = temporary
    }
}

// MARK: Composer and tree (Build)

public struct SessionCommand: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case template, skill, `extension` }
    public var name: String
    public var description: String
    public var kind: Kind
    public var hint: String?
    /// Skills: the folder they were found in ("~/.agents/skills").
    public var source: String?
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

public struct ListDirParams: Encodable, Sendable { public var cwd: String; public var dir: String; public init(cwd: String, dir: String) { self.cwd = cwd; self.dir = dir } }
public struct DirEntry: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var kind: FileMatch.Kind
    public var id: String { path }
}
public struct ListDirResult: Decodable, Sendable { public var entries: [DirEntry] }

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
    public var env: [String]?
    public var hiddenTools: [String]?
    public var chat: Bool?
    public var id: String { "\(scope.rawValue):\(name)" }
}
/// A server started to see it works (Settings › MCP servers).
public struct McpProbe: Decodable, Sendable, Hashable {
    public struct Tool: Decodable, Sendable, Hashable { public var name: String; public var description: String? }
    public var ok: Bool; public var ms: Double?; public var tools: [Tool]; public var error: String?; public var log: String?
}
public struct McpProbeParams: Encodable, Sendable {
    public var command: String?; public var args: [String]?; public var url: String?; public var env: [String: String]?
    public init(command: String?, args: [String]?, url: String?, env: [String: String]?) { self.command = command; self.args = args; self.url = url; self.env = env }
}
public struct McpStatusParams: Encodable, Sendable {
    public var scope: McpServerInfo.Scope; public var cwd: String?; public var name: String; public var refresh: Bool?
    public init(scope: McpServerInfo.Scope, cwd: String?, name: String, refresh: Bool? = nil) { self.scope = scope; self.cwd = cwd; self.name = name; self.refresh = refresh }
}
public struct McpSetChatParams: Encodable, Sendable { public var name: String; public var chat: Bool; public init(name: String, chat: Bool) { self.name = name; self.chat = chat } }
public struct McpSetToolParams: Encodable, Sendable {
    public var scope: McpServerInfo.Scope; public var cwd: String?; public var name: String; public var tool: String; public var enabled: Bool
    public init(scope: McpServerInfo.Scope, cwd: String?, name: String, tool: String, enabled: Bool) { self.scope = scope; self.cwd = cwd; self.name = name; self.tool = tool; self.enabled = enabled }
}
public struct McpDetectResult: Decodable, Sendable {
    public struct Server: Decodable, Sendable, Hashable, Identifiable { public var name: String; public var command: String?; public var args: [String]?; public var url: String?; public var env: [String: String]?; public var id: String { name } }
    public struct Found: Decodable, Sendable, Hashable, Identifiable { public var app, path: String; public var servers: [Server]; public var id: String { app } }
    public var found: [Found]
}
public struct McpListParams: Encodable, Sendable { public var cwd: String?; public init(cwd: String? = nil) { self.cwd = cwd } }
/// A commit on the current branch (`git.log`): a session's results.
public struct GitCommitFile: Decodable, Sendable, Hashable, Identifiable { public var path: String; public var added, removed: Int; public var id: String { path } }
public struct GitCommit: Decodable, Sendable, Hashable, Identifiable { public var hash, subject, at: String; public var files: [GitCommitFile]?; public var id: String { hash } }
public struct GitLogParams: Encodable, Sendable {
    public var cwd: String; public var since: String?; public var limit: Int?
    public init(cwd: String, since: String? = nil, limit: Int? = nil) { self.cwd = cwd; self.since = since; self.limit = limit }
}
public struct GitLogResult: Decodable, Sendable { public var commits: [GitCommit] }
public struct McpListResult: Decodable, Sendable { public var servers: [McpServerInfo]; public var errors: [String] }
public struct McpAddParams: Encodable, Sendable {
    public var scope: McpServerInfo.Scope; public var cwd: String?; public var name: String
    public var command: String?; public var args: [String]?; public var url: String?; public var description: String?
    public var env: [String: String]?; public var enabled: Bool?; public var chat: Bool?
    public init(scope: McpServerInfo.Scope, cwd: String?, name: String, command: String?, args: [String]?, url: String?, description: String?, env: [String: String]? = nil, enabled: Bool? = nil, chat: Bool? = nil) {
        self.scope = scope; self.cwd = cwd; self.name = name; self.command = command; self.args = args; self.url = url; self.description = description
        self.env = env; self.enabled = enabled; self.chat = chat
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
    /// Lines added and removed against HEAD (untracked: the file's lines); nil for binary files.
    public var added: Int?
    public var removed: Int?
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

/// A finding of a review by an agent (docs/spec/05-build "Review by an agent").
public struct ReviewFinding: Codable, Sendable, Hashable, Identifiable {
    public enum Severity: String, Codable, Sendable { case bug, risk, nit }
    public enum State: String, Codable, Sendable { case open, fixing, fixed, dismissed }
    public var id: String
    public var severity: Severity
    public var file: String
    public var line: Int?
    public var title: String
    public var detail: String
    public var suggestion: String?
    public var state: State
}
public struct ReviewInfo: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case running, done, failed }
    public var reviewer: ContainerRef
    public var target: String
    public var status: Status
    public var summary: String?
    public var findings: [ReviewFinding]
    public var at: String
}
public struct ReviewParams: Encodable, Sendable {
    public var ref: ContainerRef; public var pr: Int?
    public init(ref: ContainerRef, pr: Int?) { self.ref = ref; self.pr = pr }
}
public struct ReviewFindingParams: Encodable, Sendable {
    public var ref: ContainerRef; public var id: String; public var state: ReviewFinding.State
    public init(ref: ContainerRef, id: String, state: ReviewFinding.State) { self.ref = ref; self.id = id; self.state = state }
}
public struct RefParams: Encodable, Sendable { public var ref: ContainerRef; public init(ref: ContainerRef) { self.ref = ref } }
public struct SubscribeResult: Decodable, Sendable { public var subscriptionId: String; public var snapshot: Snapshot }
public struct ListSessionsParams: Encodable, Sendable { public var kind: ContainerKind?; public init(kind: ContainerKind? = nil) { self.kind = kind } }
public struct ListSessionsResult: Decodable, Sendable { public var sessions: [SessionSummary] }

/// A file to send: images as base64 (prepared by the client), documents as extracted text.
public enum Attachment: Codable, Sendable, Hashable {
    /// `path`: the original on this Mac, which the engine keeps a copy of so it can be shown again.
    case image(name: String, mimeType: String, data: String, path: String? = nil)
    case text(name: String, mimeType: String?, text: String, path: String? = nil)

    public var name: String { switch self { case .image(let n, _, _, _), .text(let n, _, _, _): n } }

    private enum Key: String, CodingKey { case kind, name, mimeType, data, text, path }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let name = try c.decode(String.self, forKey: .name)
        switch try c.decode(String.self, forKey: .kind) {
        case "image": self = .image(name: name, mimeType: try c.decode(String.self, forKey: .mimeType), data: try c.decode(String.self, forKey: .data), path: try c.decodeIfPresent(String.self, forKey: .path))
        case "text": self = .text(name: name, mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType), text: try c.decode(String.self, forKey: .text), path: try c.decodeIfPresent(String.self, forKey: .path))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown attachment kind")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .image(let name, let mime, let data, let path):
            try c.encode("image", forKey: .kind); try c.encode(name, forKey: .name); try c.encode(mime, forKey: .mimeType); try c.encode(data, forKey: .data); try c.encodeIfPresent(path, forKey: .path)
        case .text(let name, let mime, let text, let path):
            try c.encode("text", forKey: .kind); try c.encode(name, forKey: .name); try c.encodeIfPresent(mime, forKey: .mimeType); try c.encode(text, forKey: .text); try c.encodeIfPresent(path, forKey: .path)
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
    /// "OpenAI", "OpenAI API", "OpenRouter" (docs/spec/10 FR2).
    public var providerName: String?
    /// Who bills for it: "ChatGPT subscription", "OpenRouter credits", "OpenAI API billing".
    public var billing: String?
    /// A model inside a coding agent (Claude Code), which runs the whole conversation (docs/spec/31).
    public var agent: Bool?
    public var ref: ModelRef { ModelRef(provider: provider, id: id) }
    public var isAgent: Bool { agent == true }
}

// MARK: Model providers (docs/spec/10-model-providers)

public struct ProviderInfo: Decodable, Sendable, Hashable, Identifiable {
    public struct Method: Decodable, Sendable, Hashable {
        public enum Kind: String, Decodable, Sendable { case apiKey = "api_key", oauth }
        public var type: Kind
        public var label: String
        public var subscription: Bool?
    }
    public enum Status: String, Decodable, Sendable { case notConnected = "not_connected", connecting, connected, needsAttention = "needs_attention" }
    public var id: String
    public var name: String
    public var methods: [Method]
    public var status: Status
    public var connectedWith: Method.Kind?
    public var billing: String?
    public var message: String?
    public var featured: Bool
    public var models: Int
    /// A custom endpoint added by address (LiteLLM, Ollama, LM Studio…).
    public struct Endpoint: Decodable, Sendable, Hashable {
        public var baseUrl: String
        public var local, keyless: Bool
        /// "openai" or "anthropic".
        public var format: String?
        public var headers: [String: String]?
        public var contextWindow: Double?
    }
    /// cloud, subscription, platform, custom (Add provider catalog).
    public var kind: String?
    /// The catalog's "Popular" card line.
    public var popular: String?
    public var keyPage: String?
    public var families: [String]?
    /// The stored key, masked.
    public var keyHint: String?
    public var hiddenModels: Int?
    public var sampleModels: [String]?
    public var endpoint: Endpoint?
    /// A coding agent on this Mac (docs/spec/31): where it is, its version, sign-in, and the commands to install it and sign in.
    public struct Agent: Decodable, Sendable, Hashable {
        public var path, version: String?
        public var signedIn: Bool
        public var install, signIn: String
    }
    public var agent: Agent?
    public var isAgent: Bool { kind == "agent" }
    public var isConnected: Bool { status == .connected || status == .needsAttention }
}
public struct EndpointCheckParams: Encodable, Sendable {
    public var baseUrl: String; public var key, id, format: String?; public var headers: [String: String]?
    public init(baseUrl: String, key: String?, id: String?, format: String? = nil, headers: [String: String]? = nil) { self.baseUrl = baseUrl; self.key = key; self.id = id; self.format = format; self.headers = headers }
}
public struct EndpointCheckResult: Decodable, Sendable, Equatable {
    public struct Model: Decodable, Sendable, Hashable { public var id: String; public var contextWindow: Double?; public var embedding: Bool? }
    public var ok: Bool; public var baseUrl: String?; public var models: [Model]; public var message: String?
    /// refused, auth, not_found, empty, tls, invalid, other
    public var error: String?
    public var latencyMs: Double?
}
public struct EndpointSaveParams: Encodable, Sendable {
    public var id: String?; public var name, baseUrl: String; public var key: String?
    public var format: String?; public var headers: [String: String]?; public var contextWindow: Double?; public var hidden: [String]?; public var force: Bool?
    public init(id: String?, name: String, baseUrl: String, key: String?, format: String? = nil, headers: [String: String]? = nil, contextWindow: Double? = nil, hidden: [String]? = nil, force: Bool? = nil) {
        self.id = id; self.name = name; self.baseUrl = baseUrl; self.key = key; self.format = format; self.headers = headers; self.contextWindow = contextWindow; self.hidden = hidden; self.force = force
    }
}
public struct ProviderKeyParams: Encodable, Sendable { public var provider, key: String; public init(provider: String, key: String) { self.provider = provider; self.key = key } }
public struct ProviderVerifyResult: Decodable, Sendable, Equatable { public var ok: Bool?; public var message: String?; public var models: Int? }
public struct ProviderModelsResult: Decodable, Sendable {
    public struct Model: Decodable, Sendable, Hashable, Identifiable { public var id, name: String; public var contextWindow: Double; public var hidden: Bool; public var embedding: Bool? }
    public var models: [Model]
}
public struct ProviderHiddenParams: Encodable, Sendable { public var provider: String; public var hidden: [String]; public init(provider: String, hidden: [String]) { self.provider = provider; self.hidden = hidden } }
public struct EndpointSaveResult: Decodable, Sendable { public var id: String }
public struct EndpointIdParams: Encodable, Sendable { public var id: String; public init(id: String) { self.id = id } }
public struct EndpointsDetectResult: Decodable, Sendable {
    public struct Found: Decodable, Sendable, Hashable { public var name, baseUrl: String; public var models: Int; public var preset: String? }
    public var found: [Found]
}
public struct ProvidersListResult: Decodable, Sendable { public var providers: [ProviderInfo] }
public struct ProviderLoginParams: Encodable, Sendable {
    public var provider: String; public var method: ProviderInfo.Method.Kind.RawValue
    public init(provider: String, method: ProviderInfo.Method.Kind) { self.provider = provider; self.method = method.rawValue }
}
public struct ProviderLoginResult: Decodable, Sendable { public var loginId: String }
public struct ProviderAnswerParams: Encodable, Sendable {
    public var loginId, promptId: String; public var value: String?
    public init(loginId: String, promptId: String, value: String?) { self.loginId = loginId; self.promptId = promptId; self.value = value }
}
public struct LoginIdParams: Encodable, Sendable { public var loginId: String; public init(loginId: String) { self.loginId = loginId } }
public struct ProviderParams: Encodable, Sendable { public var provider: String; public init(provider: String) { self.provider = provider } }

/// One step of a sign-in (engine `providers.auth`): the union flattened, by `type`.
public struct ProviderAuthEvent: Decodable, Sendable, Hashable {
    public struct Option: Decodable, Sendable, Hashable { public var id, label: String; public var description: String? }
    public struct Link: Decodable, Sendable, Hashable { public var url: String; public var label: String? }
    /// auth_url, device_code, progress, info, prompt, prompt_closed, done, failed
    public var type: String
    public var url, instructions, userCode, verificationUri, message, promptId, kind, placeholder: String?
    public var expiresInSeconds: Double?
    public var options: [Option]?
    public var links: [Link]?
    public init(type: String, message: String? = nil) { self.type = type; self.message = message }
}
public struct ProviderAuthNotification: Decodable, Sendable { public var loginId, provider: String; public var event: ProviderAuthEvent }
public enum ProviderNotification: Sendable { case auth(ProviderAuthNotification), changed, connectorAuth(ConnectorAuthNotification), connectorsChanged, workChanged, watchdogChanged, automationsChanged, libraryChanged, appData(AppView), budgetChanged(BudgetChanged) }

// MARK: Connected apps (docs/spec/12-connectors)

public struct ConnectorInfo: Decodable, Sendable, Hashable, Identifiable {
    public struct Account: Decodable, Sendable, Hashable, Identifiable { public var id, label, addedAt: String; public var problem: String? }
    /// What it can do, grouped as Settings shows it (c2/c4): runs, asks first, or off.
    public struct Capability: Decodable, Sendable, Hashable, Identifiable {
        public enum Access: String, Decodable, Sendable { case read, write, send, destructive }
        public var id, label: String
        public var tools: [String]
        public var access: Access
        public var permission: ConnectorPermission
        public var choices: [ConnectorPermission]
        public var note: String?
    }
    public var id, name, category, description, setupHelp: String
    public var ready, ownClient, needsSecret, connecting, chats: Bool
    public var accounts: [Account]
    public var capabilities: [Capability]
}
public enum ConnectorPermission: String, Codable, Sendable, Hashable, CaseIterable { case runs, ask, off }
public struct ConnectorCalendarsResult: Decodable, Sendable {
    public struct Calendar: Decodable, Sendable, Hashable, Identifiable { public var id, name: String; public var primary: Bool; public var color: String?; public var enabled: Bool }
    public var calendars: [Calendar]
}
public struct ConnectorSetCalendarParams: Encodable, Sendable {
    public var accountId, calendarId: String; public var enabled: Bool
    public init(accountId: String, calendarId: String, enabled: Bool) { self.accountId = accountId; self.calendarId = calendarId; self.enabled = enabled }
}
public struct ConnectorsListResult: Decodable, Sendable { public var connectors: [ConnectorInfo] }
public struct ConnectorParams: Encodable, Sendable { public var connector: String; public init(connector: String) { self.connector = connector } }
public struct ConnectorAccountParams: Encodable, Sendable { public var accountId: String; public init(accountId: String) { self.accountId = accountId } }
public struct ConnectorConfigureParams: Encodable, Sendable {
    public var connector: String; public var chats: Bool?; public var permissions: [String: ConnectorPermission]?; public var clientId: String?; public var clientSecret: String?
    public init(connector: String, chats: Bool? = nil, permissions: [String: ConnectorPermission]? = nil, clientId: String? = nil, clientSecret: String? = nil) {
        self.connector = connector; self.chats = chats; self.permissions = permissions; self.clientId = clientId; self.clientSecret = clientSecret
    }
}
public struct ConnectorAuthNotification: Decodable, Sendable { public var loginId, connector: String; public var event: ProviderAuthEvent }
/// Build: back to before one of your messages (chat v3, 14b).
public struct RewindParams: Encodable, Sendable {
    public var ref: ContainerRef; public var itemId: String; public var files: Bool; public var dryRun: Bool?
    public init(ref: ContainerRef, itemId: String, files: Bool, dryRun: Bool? = nil) { self.ref = ref; self.itemId = itemId; self.files = files; self.dryRun = dryRun }
}
public struct RewindResult: Decodable, Sendable { public var files: [FileChange]; public var turns: Int; public var editorText: String? }
public struct SessionDecideParams: Encodable, Sendable {
    public var ref: ContainerRef; public var approvalId: String; public var approve: Bool; public var always: Bool?
    public init(ref: ContainerRef, approvalId: String, approve: Bool, always: Bool? = nil) { self.ref = ref; self.approvalId = approvalId; self.approve = approve; self.always = always }
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
    /// Replaces the conversation's list of tools turned off here ("connector:<id>", "mcp:<server>").
    public var toolsOff: [String]?
    public init(ref: ContainerRef, model: ModelRef? = nil, thinking: String? = nil, web: Bool? = nil, approvalMode: ApprovalMode? = nil, planMode: Bool? = nil, toolsOff: [String]? = nil) {
        self.ref = ref; self.model = model; self.thinking = thinking; self.web = web; self.approvalMode = approvalMode; self.planMode = planMode; self.toolsOff = toolsOff
    }
}

// MARK: Approvals (Build)

/// How much a Build session may do on its own (05-build §6); Read only reads files and the web (18 §4).
public enum ApprovalMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case readOnly = "read_only", ask, autoEdit = "auto_edit", fullAuto = "full_auto"
    public var id: String { rawValue }
}

public struct ApprovalRule: Codable, Sendable, Hashable, Identifiable {
    /// `host`: a site a filtered project's commands may reach (docs/spec/39).
    public enum Kind: String, Codable, Sendable { case command, tool, path, host }
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
    /// Plans: your edited version, approved with `allow`.
    public var summary: String?
    public var steps: [String]?
    public init(decision: Decision? = nil, text: String? = nil, choice: String? = nil, confirmed: Bool? = nil, summary: String? = nil, steps: [String]? = nil) {
        self.decision = decision; self.text = text; self.choice = choice; self.confirmed = confirmed; self.summary = summary; self.steps = steps
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
    public struct LinkFolder: Encodable, Sendable { public var path: String; public var edit: Bool; public init(path: String, edit: Bool) { self.path = path; self.edit = edit } }
    /// Links a folder, or changes whether it can be edited (docs/spec/18 §18).
    public var linkFolder: LinkFolder?
    public var unlinkFolder: String?
    public var prEvents: String?
    /// Its commands' network (docs/spec/39).
    public var network: ProjectInfo.Network?
    public init(id: String, approvalMode: ApprovalMode? = nil, removeRule: String? = nil, trust: Bool? = nil, linkFolder: LinkFolder? = nil, unlinkFolder: String? = nil, prEvents: String? = nil, network: ProjectInfo.Network? = nil) {
        self.id = id; self.approvalMode = approvalMode; self.removeRule = removeRule; self.trust = trust
        self.linkFolder = linkFolder; self.unlinkFolder = unlinkFolder; self.prEvents = prEvents; self.network = network
    }
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
public struct ExportResult: Decodable, Sendable {
    public var filename: String; public var mimeType: String; public var content: String
    /// The visuals the export shows, by tool call, so they can be drawn without the conversation open.
    public var visuals: [Visual]?
    public struct Visual: Decodable, Sendable { public var callId: String; public var title: String; public var html: String }
}
public struct RenameParams: Encodable, Sendable {
    public var ref: ContainerRef
    public var title: String
    public init(ref: ContainerRef, title: String) { self.ref = ref; self.title = title }
}
public struct SecretChangedParams: Encodable, Sendable { public var name: String; public init(name: String) { self.name = name } }
public struct UnsubscribeParams: Encodable, Sendable { public var subscriptionId: String; public init(subscriptionId: String) { self.subscriptionId = subscriptionId } }

/// A project: a folder on this Mac, opened or made by New project in ~/Piopio (docs/spec/18 CF4).
public struct ProjectInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public var addedAt: String
    public var branch: String?
    public var contextFile: String?
    public var piConfig: Bool
    public var approvalMode: ApprovalMode
    /// What a conversation hears about its pull request (docs/spec/17 §5): "off", "tell" (default) or "act".
    public var prEvents: String?
    public var rules: [ApprovalRule]
    /// pi project trust (shared with the pi CLI): whether the project's .pi resources load; `needsTrust`: it has some.
    public enum Trust: String, Codable, Sendable { case trusted, untrusted, undecided }
    public var trust: Trust
    public var needsTrust: Bool
    /// Its commands' network (docs/spec/39): open, filtered until the project is trusted, or off (only this Mac) until
    /// it's turned on.
    public enum Network: String, Codable, Sendable { case open, filtered, off }
    public var network: Network?
    /// Where the project shows: Build, Chat, or both (04-chat P1).
    public enum Lens: String, Codable, Sendable { case build, chat }
    public var lenses: [Lens]
    public var missing: Bool?
    /// Other folders on the Mac linked to the project (docs/spec/18 §18): read only, or edited under its permissions.
    public struct LinkedFolder: Codable, Sendable, Hashable { public var path: String; public var edit: Bool; public var missing: Bool? }
    public var folders: [LinkedFolder]?
    /// The check run after the agent's edits (docs/spec/05-build "Diagnostics"): detected ("auto", with the command it
    /// found, if any), set by the user, or off.
    public struct Check: Codable, Sendable, Hashable {
        public enum Source: String, Codable, Sendable { case auto, set, off }
        public var command: String?
        public var source: Source
        public init(command: String?, source: Source) { self.command = command; self.source = source }
    }
    public var check: Check?
}

/// Sets a project's check after edits: a command, "" for off, nil for the detected one (05-build "Diagnostics").
public struct ProjectsCheckParams: Encodable, Sendable {
    public var id: String
    public var check: String?
    public init(id: String, check: String?) { self.id = id; self.check = check }
    enum CodingKeys: String, CodingKey { case id, check }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if let check { try c.encode(check, forKey: .check) } else { try c.encodeNil(forKey: .check) }
    }
}

/// New project: a folder in ~/Piopio with AGENTS.md (`instructions`) and NOTES.md.
public struct ProjectsCreateParams: Encodable, Sendable {
    public var name: String; public var instructions: String?
    public init(name: String, instructions: String? = nil) { self.name = name; self.instructions = instructions }
}
public struct ProjectsChanged: Decodable, Sendable { public var projects: [ProjectInfo] }
public struct ProjectsListResult: Decodable, Sendable { public var projects: [ProjectInfo] }
public struct ProjectsAddParams: Encodable, Sendable {
    public var path: String
    public var lens: ProjectInfo.Lens?
    public init(path: String, lens: ProjectInfo.Lens? = nil) { self.path = path; self.lens = lens }
}
public struct ProjectsAddResult: Decodable, Sendable { public var project: ProjectInfo }
public struct ProjectsRemoveParams: Encodable, Sendable { public var id: String; public init(id: String) { self.id = id } }

public struct CatalogChanged: Decodable, Sendable {
    public var upserted: [SessionSummary]
    public var removed: [ContainerRef]
}

// MARK: Milestone 1.2: branches and queue

public struct EditParams: Encodable, Sendable {
    public var ref: ContainerRef; public var itemId: String; public var text: String; public var clientRequestId: String?
    public init(ref: ContainerRef, itemId: String, text: String, clientRequestId: String? = nil) { self.ref = ref; self.itemId = itemId; self.text = text; self.clientRequestId = clientRequestId }
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
    public var query: String; public var limit: Int?; public var kind: ContainerKind?
    public init(query: String, limit: Int? = nil, kind: ContainerKind? = nil) { self.query = query; self.limit = limit; self.kind = kind }
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
    public var id: String { "\(ref.kind.rawValue)/\(ref.key)/\(itemId ?? "title")" }
}
public struct SearchResults: Decodable, Sendable { public var results: [SearchResult] }

// MARK: Keys and engine info

public struct EngineStatusResult: Decodable, Sendable {
    public var uptimeMs: Double; public var openSessions: Int; public var subscriptions: Int; public var runtime: String; public var memoryMB: Double; public var dataPath: String
}


public struct ExtraCostParams: Encodable, Sendable {
    public var ref: ContainerRef?
    public init(ref: ContainerRef? = nil) { self.ref = ref }
}
public struct ExtraCostSummary: Decodable, Sendable {
    public struct Breakdown: Decodable, Sendable, Identifiable {
        public var kind: String; public var calls, unknownCalls: Int; public var knownUsd: Double
        public var id: String { kind }
    }
    public var scope: String; public var knownUsd: Double; public var unknownCalls, calls: Int; public var breakdown: [Breakdown]
}

// MARK: Overview (docs/spec/34)

/// Days are local to the engine's Mac; "month" is this calendar month, "12m" the last twelve by month.
public enum SpendRange: String, Codable, Sendable, CaseIterable { case today, sevenDays = "7d", month, lastMonth = "last_month", twelveMonths = "12m" }
public enum SpendGroupBy: String, Codable, Sendable, CaseIterable { case what, model, provider, project, `where` }

public struct SpendFilter: Encodable, Sendable, Hashable {
    public var agent: String?; public var automation: String?; public var place: String?
    public init(agent: String? = nil, automation: String? = nil, place: String? = nil) { self.agent = agent; self.automation = automation; self.place = place }
}
public struct SpendParams: Encodable, Sendable {
    public var range: SpendRange; public var groupBy: SpendGroupBy?; public var filter: SpendFilter?
    public init(range: SpendRange, groupBy: SpendGroupBy? = nil, filter: SpendFilter? = nil) { self.range = range; self.groupBy = groupBy; self.filter = filter }
}
/// A grouped row: known USD (unknown prices excluded and counted), or tokens when billed to a plan.
public struct SpendGroup: Decodable, Sendable, Hashable, Identifiable {
    public var id: String; public var label: String
    public var usd: Double; public var calls, unknownCalls: Int
    public var plan: Bool; public var tokens: Double; public var share: Double
    public var ref: ContainerRef?
}
public struct SpendDay: Decodable, Sendable, Hashable, Identifiable {
    public struct Top: Decodable, Sendable, Hashable { public var label: String; public var usd: Double }
    /// "2026-11-23", or "2026-11" on 12 months.
    public var day: String
    public var macUsd, cloudUsd: Double; public var calls: Int
    /// That day's requests with no price (not in its amounts).
    public var unknownCalls: Int
    public var top: [Top]
    public var id: String { day }
}
public struct SpendResult: Decodable, Sendable {
    public struct Tokens: Decodable, Sendable { public var input, output, cacheRead, cacheWrite: Double }
    public var range: SpendRange
    public var from, to: String
    public var knownUsd: Double
    public var calls, unknownCalls, planCalls: Int
    /// Tokens of the requests billed to a subscription plan.
    public var planTokens: Double
    public var tokens: Tokens
    /// "About" this much by the month's end; only for "month" from day 5.
    public var forecastUsd: Double?
    public var days: [SpendDay]
    public var groupBy: SpendGroupBy
    public var groups: [SpendGroup]
    public var since: String?
    public var backfilling: Bool?
    /// Cheaper next time (34 §5.5): at most three, each with the number it's based on.
    public var suggestions: [SpendSuggestion]?
    /// The cloud's usage is counted up to this time (it was unreachable since).
    public var cloudAsOf: String?
}
/// Cheaper next time (34 §5.5, OV7): a saving with the number it's based on, and one thing to do about it.
public struct SpendSuggestion: Decodable, Sendable, Hashable, Identifiable {
    public struct Action: Decodable, Sendable, Hashable {
        public enum Kind: String, Decodable, Sendable { case automation, agent, onDevice = "on_device" }
        public var kind: Kind; public var id: String?; public var label: String
    }
    public var id: String; public var text: String; public var savingUsd: Double; public var action: Action?
}
public struct SpendItemsParams: Encodable, Sendable {
    public var range: SpendRange; public var groupBy: SpendGroupBy; public var group: String
    public init(range: SpendRange, groupBy: SpendGroupBy, group: String) { self.range = range; self.groupBy = groupBy; self.group = group }
}
public struct SpendItem: Decodable, Sendable, Hashable, Identifiable {
    public var ref: ContainerRef; public var title: String
    public var usd: Double; public var calls, unknownCalls: Int
    public var plan: Bool; public var tokens: Double; public var lastAt: String
    public var id: String { ref.key }
}
public struct SpendItems: Decodable, Sendable { public var items: [SpendItem] }
/// An agent's month or an automation's run (34 §5.4).
public struct Budget: Decodable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case agent, automation }
    public enum Period: String, Decodable, Sendable { case month, run }
    public var id: String; public var kind: Kind; public var name: String
    public var spentUsd, limitUsd: Double
    public var period: Period
    public var resets: String?
    public var ref: ContainerRef?
    public var automation: String?
}
/// Piopio this month (34 §5.4, OV3): one budget over everything the ledger counts on this Mac, off until set.
public struct PiopioBudget: Decodable, Sendable, Equatable {
    public enum State: String, Decodable, Sendable { case off, ok, near, over, allowed }
    public struct Held: Decodable, Sendable, Equatable, Identifiable {
        public var run, automation, name, at: String
        public var id: String { run }
    }
    /// "2026-11".
    public var month: String
    public var limitUsd: Double?
    public var spentUsd: Double
    public var resets: String
    public var state: State
    public var held: [Held]
}
public struct Budgets: Decodable, Sendable { public var budgets: [Budget]; public var piopio: PiopioBudget? }
public struct BudgetSetParams: Encodable, Sendable {
    public var monthUsd: Double?
    public init(monthUsd: Double?) { self.monthUsd = monthUsd }
    // `null` turns it off, so the key is always sent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(monthUsd, forKey: .monthUsd)
    }
    private enum CodingKeys: String, CodingKey { case monthUsd }
}
public struct BudgetReleaseParams: Encodable, Sendable {
    public var run: String?; public var month: Bool?
    public init(run: String? = nil, month: Bool? = nil) { self.run = run; self.month = month }
}
public struct BudgetChanged: Decodable, Sendable { public var notify: String? }
public struct SpendExportParams: Encodable, Sendable { public var range: SpendRange; public init(range: SpendRange) { self.range = range } }
public struct SpendExport: Decodable, Sendable { public var csv: String; public var rows: Int }

/// Overview › Activity (docs/spec/34 §7): one number, the range before, and what it counts.
public struct ActivityRow: Decodable, Sendable, Hashable, Identifiable {
    public enum Unit: String, Decodable, Sendable { case count, ms, files }
    public var id: String; public var label: String; public var value: Double
    public var previous: Double?; public var unit: Unit?; public var detail: String?
}
public struct ActivityGroup: Decodable, Sendable, Hashable, Identifiable { public var id: String; public var title: String; public var rows: [ActivityRow] }
public struct ActivityDay: Decodable, Sendable, Hashable { public var day: String; public var count: Double; public init(day: String, count: Double) { self.day = day; self.count = count } }
public struct ActivityParams: Encodable, Sendable { public var range: SpendRange; public init(range: SpendRange) { self.range = range } }
public struct ActivityResult: Decodable, Sendable {
    public var range: SpendRange; public var from: String; public var to: String
    public var groups: [ActivityGroup]
    /// A year of days (OV5), from the day Piopio started or a year ago.
    public var year: [ActivityDay]
    public var backfilling: Bool?
}
/// Overview › Disk (34 §7.1).
public struct StorageResult: Decodable, Sendable {
    public struct Action: Decodable, Sendable, Hashable { public var id: String; public var label: String; public var freesBytes: Double; public var count: Int }
    public struct Item: Decodable, Sendable, Hashable, Identifiable { public var id: String; public var label: String; public var bytes: Double; public var detail: String?; public var action: Action? }
    public var totalBytes: Double; public var items: [Item]; public var path: String
}
public struct StorageCleanParams: Encodable, Sendable { public var action: String; public init(action: String) { self.action = action } }
public struct StorageCleanResult: Decodable, Sendable { public var freedBytes: Double; public var removed: Int }
/// Overview › Setup (34 §6): a node of the map.
public struct SetupNode: Decodable, Sendable, Hashable, Identifiable {
    public enum Column: String, Decodable, Sendable { case you, piopio, uses }
    public enum Kind: String, Decodable, Sendable { case device, channel, place, provider, codingAgent = "coding_agent", connector, mcp, memory }
    public enum State: String, Decodable, Sendable { case ok, needsYou = "needs_you", unused, off }
    public struct Open: Decodable, Sendable, Hashable {
        public var kind: String; public var id: String?; public var pane: String?
        public init(kind: String, id: String? = nil, pane: String? = nil) { self.kind = kind; self.id = id; self.pane = pane }
    }
    public struct Agent: Decodable, Sendable, Hashable, Identifiable { public var id: String; public var name: String; public var avatar: String?; public var state: State; public var reason: String? }
    public var id: String; public var column: Column; public var kind: Kind; public var name: String; public var line: String
    public var state: State; public var reason: String?; public var open: Open?; public var agents: [Agent]?
}
public struct SetupResult: Decodable, Sendable {
    public struct Edge: Decodable, Sendable, Hashable { public var from: String; public var to: String }
    public struct Row: Decodable, Sendable, Hashable, Identifiable {
        public var kind: String; public var id: String; public var name: String
        /// "mac" | "cloud".
        public var runsOn: String; public var model: String?; public var reachesYouIn: String
        public var nextRun: String?; public var monthUsd: Double; public var paused: Bool?
    }
    public var nodes: [SetupNode]; public var edges: [Edge]; public var rows: [Row]
}

// MARK: Your cloud (docs/spec/30 K1)

/// Your cloud as the Mac's engine sees it: connected, reachable, and the agents its registry lists.
public struct CloudStatus: Decodable, Sendable, Hashable {
    public struct Agent: Decodable, Sendable, Hashable, Identifiable { public var id: String; public var name: String; public var avatar: String?; public var deployedAt: String }
    public var connected: Bool
    public var url: String?
    public var reachable: Bool?
    public var version: String?
    public var error: String?
    public var connectedAt: String?
    /// Piopio deployed it with your Cloudflare token, so it can update it.
    public var managed: Bool?
    public var agents: [Agent]
    public init(connected: Bool, agents: [Agent]) { self.connected = connected; self.agents = agents }
}
public struct CloudConnectParams: Encodable, Sendable {
    public var url: String; public var token: String
    public init(url: String, token: String) { self.url = url; self.token = token }
}
/// Connect with a Cloudflare API token: Piopio deploys its Worker. With several accounts and none picked, `accounts`.
public struct CloudSetupParams: Encodable, Sendable {
    public var apiToken: String; public var accountId: String?
    public init(apiToken: String, accountId: String? = nil) { self.apiToken = apiToken; self.accountId = accountId }
}
public struct CloudSetupResult: Decodable, Sendable {
    public struct Account: Decodable, Sendable, Hashable, Identifiable { public var id: String; public var name: String }
    public var status: CloudStatus?
    public var accounts: [Account]?
}
/// Moves an agent to your cloud ("cloud") or back to this Mac ("local"); `lines` says what moved.
public struct AgentMoveParams: Encodable, Sendable {
    public var ref: ContainerRef; public var to: String
    public init(ref: ContainerRef, to: String) { self.ref = ref; self.to = to }
}
public struct AgentMoveResult: Decodable, Sendable { public var lines: [String] }
