// Generated from the engine's protocol (packages/protocol/src/index.ts) by packages/protocol/src/swift.ts.
// Don't edit: run `corepack pnpm schema` from the repository root. Helpers go in Protocol.swift.
// See docs/spec/03-engine-protocol.md, "Swift types".

import Foundation

/// A field that may be absent, null or a value: absent leaves it as it is, null clears it.
public enum Nullable<Wrapped: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    case null
    case value(Wrapped)
    public init(_ value: Wrapped?) { self = value.map(Nullable.value) ?? .null }
    public var value: Wrapped? { if case .value(let v) = self { v } else { nil } }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = c.decodeNil() ? .null : .value(try c.decode(Wrapped.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .value(let v): try c.encode(v) }
    }
}

public struct AcceptWorkParams: Codable, Sendable, Hashable {
    public var project: String
    public var sessionId: String
    public init(project: String, sessionId: String) { self.project = project; self.sessionId = sessionId }
}

public struct ActivityDay: Codable, Sendable, Hashable {
    public var day: String
    public var count: Double
    public init(day: String, count: Double) { self.day = day; self.count = count }
}

public struct ActivityGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var rows: [ActivityRow]
    public init(id: String, title: String, rows: [ActivityRow]) { self.id = id; self.title = title; self.rows = rows }
}

public struct ActivityParams: Codable, Sendable, Hashable {
    public var range: SpendRange
    public init(range: SpendRange) { self.range = range }
}

public struct ActivityResult: Codable, Sendable, Hashable {
    public var range: SpendRange
    public var from: String
    public var to: String
    public var groups: [ActivityGroup]
    public var year: [ActivityDay]
    public var backfilling: Bool?
    public init(range: SpendRange, from: String, to: String, groups: [ActivityGroup], year: [ActivityDay], backfilling: Bool? = nil) { self.range = range; self.from = from; self.to = to; self.groups = groups; self.year = year; self.backfilling = backfilling }
}

public struct ActivityRow: Codable, Sendable, Hashable, Identifiable {
    public enum Unit: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case count, ms, files
        public var description: String { rawValue }
    }
    public var id: String
    public var label: String
    public var value: Double
    public var previous: Double?
    public var unit: Unit?
    public var detail: String?
    public init(id: String, label: String, value: Double, previous: Double? = nil, unit: Unit? = nil, detail: String? = nil) { self.id = id; self.label = label; self.value = value; self.previous = previous; self.unit = unit; self.detail = detail }
}

public struct AddWorkTaskParams: Codable, Sendable, Hashable {
    public var project: String
    public var title: String
    public var brief: String
    public var done: String?
    public init(project: String, title: String, brief: String, done: String? = nil) { self.project = project; self.title = title; self.brief = brief; self.done = done }
}

public struct AddressPrParams: Codable, Sendable, Hashable {
    public enum What: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case comments, ci
        public var description: String { rawValue }
    }
    public var ref: ContainerRef
    public var what: What
    public init(ref: ContainerRef, what: What) { self.ref = ref; self.what = what }
}

public struct AgentDecideParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var approvalId: String
    public var approve: Bool
    public var args: JSONValue?
    public var always: Bool?
    public var reason: String?
    public init(ref: ContainerRef, approvalId: String, approve: Bool, args: JSONValue? = nil, always: Bool? = nil, reason: String? = nil) { self.ref = ref; self.approvalId = approvalId; self.approve = approve; self.args = args; self.always = always; self.reason = reason }
}

public struct AgentDraftResult: Codable, Sendable, Hashable {
    public var name: String
    public var instructions: String
    public var schedule: String?
    public init(name: String, instructions: String, schedule: String?) { self.name = name; self.instructions = instructions; self.schedule = schedule }
    private enum CodingKeys: String, CodingKey { case name, instructions, schedule }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.name, forKey: .name)
        try c.encode(self.instructions, forKey: .instructions)
        try c.encode(self.schedule, forKey: .schedule)
    }
}

public struct AgentFile: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case image, pdf, text, other
        public var description: String { rawValue }
    }
    public var name: String
    public var note: String?
    public var kind: Kind
    public var size: Double
    public var addedAt: String
    public var path: String
    public var readable: Bool
    public init(name: String, note: String? = nil, kind: Kind, size: Double, addedAt: String, path: String, readable: Bool) { self.name = name; self.note = note; self.kind = kind; self.size = size; self.addedAt = addedAt; self.path = path; self.readable = readable }
}

public struct AgentFileParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var name: String
    public var note: String?
    public var rename: String?
    public init(ref: ContainerRef, name: String, note: String? = nil, rename: String? = nil) { self.ref = ref; self.name = name; self.note = note; self.rename = rename }
}

public struct AgentFilesAddParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var attachments: [Attachment]
    public init(ref: ContainerRef, attachments: [Attachment]) { self.ref = ref; self.attachments = attachments }
}

public struct AgentFilesAdded: Codable, Sendable, Hashable {
    public var files: [AgentFile]
    public init(files: [AgentFile]) { self.files = files }
}

public struct AgentFilesResult: Codable, Sendable, Hashable {
    public var files: [AgentFile]
    public var folder: String
    public init(files: [AgentFile], folder: String) { self.files = files; self.folder = folder }
}

public struct AgentGetResult: Codable, Sendable, Hashable {
    public struct Commit: Codable, Sendable, Hashable {
        public var commit: String
        public var at: String
        public var message: String
        public init(commit: String, at: String, message: String) { self.commit = commit; self.at = at; self.message = message }
    }
    public var definition: JSONValue
    public var instructions: String
    public var folder: String
    public var errors: [DefinitionError]
    public var history: [Commit]
    public init(definition: JSONValue, instructions: String, folder: String, errors: [DefinitionError], history: [Commit]) { self.definition = definition; self.instructions = instructions; self.folder = folder; self.errors = errors; self.history = history }
}

public struct AgentInfo: Codable, Sendable, Hashable {
    public enum Location: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case local, cloud
        public var description: String { rawValue }
    }
    public struct Contact: Codable, Sendable, Hashable, Identifiable {
        public enum Role: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case owner, contact
            public var description: String { rawValue }
        }
        public var id: String
        public var name: String
        public var role: Role
        public init(id: String, name: String, role: Role) { self.id = id; self.name = name; self.role = role }
    }
    public struct Status: Codable, Sendable, Hashable {
        public var paused: Bool
        public var spendUsd: Double
        public var budgetUsd: Double?
        public var inbox: Int
        public var nextRun: String?
        public init(paused: Bool, spendUsd: Double, budgetUsd: Double? = nil, inbox: Int, nextRun: String? = nil) { self.paused = paused; self.spendUsd = spendUsd; self.budgetUsd = budgetUsd; self.inbox = inbox; self.nextRun = nextRun }
    }
    public var slug: String
    public var avatar: String?
    public var description: String?
    public var folder: String
    public var location: Location
    public var model: String
    public var contacts: [Contact]
    public var invalid: Bool?
    public var asksFirst: Bool?
    public var draft: Bool?
    public var status: Status?
    public init(slug: String, avatar: String? = nil, description: String? = nil, folder: String, location: Location, model: String, contacts: [Contact], invalid: Bool? = nil, asksFirst: Bool? = nil, draft: Bool? = nil, status: Status? = nil) { self.slug = slug; self.avatar = avatar; self.description = description; self.folder = folder; self.location = location; self.model = model; self.contacts = contacts; self.invalid = invalid; self.asksFirst = asksFirst; self.draft = draft; self.status = status }
}

public struct AgentMemoryResult: Codable, Sendable, Hashable {
    public struct Partition: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        public var bank: String
        public init(id: String, label: String, bank: String) { self.id = id; self.label = label; self.bank = bank }
    }
    public var provider: String
    public var partitions: [Partition]
    public init(provider: String, partitions: [Partition]) { self.provider = provider; self.partitions = partitions }
}

public struct AgentMoveParams: Codable, Sendable, Hashable {
    public enum To: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case cloud, local
        public var description: String { rawValue }
    }
    public var ref: ContainerRef
    public var to: To
    public init(ref: ContainerRef, to: To) { self.ref = ref; self.to = to }
}

public struct AgentMoveResult: Codable, Sendable, Hashable {
    public var lines: [String]
    public init(lines: [String]) { self.lines = lines }
}

public struct AgentMsgItem: Codable, Sendable, Hashable, Identifiable {
    public struct Agent: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public enum Direction: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case `in`, out
        public var description: String { rawValue }
    }
    public var id: String
    public var at: String
    public var fromAgent: Agent
    public var toAgent: Agent
    public var text: String
    public var direction: Direction
    public var mode: AgentMsgMode
    public var status: AgentMsgStatus?
    public var reply: String?
    public var traceId: String?
    public init(id: String, at: String, fromAgent: Agent, toAgent: Agent, text: String, direction: Direction, mode: AgentMsgMode, status: AgentMsgStatus? = nil, reply: String? = nil, traceId: String? = nil) { self.id = id; self.at = at; self.fromAgent = fromAgent; self.toAgent = toAgent; self.text = text; self.direction = direction; self.mode = mode; self.status = status; self.reply = reply; self.traceId = traceId }
    private enum CodingKeys: String, CodingKey { case id, at, fromAgent, toAgent, text, direction, mode, status, reply, traceId, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.at = try c.decode(String.self, forKey: .at)
        self.fromAgent = try c.decode(Agent.self, forKey: .fromAgent)
        self.toAgent = try c.decode(Agent.self, forKey: .toAgent)
        self.text = try c.decode(String.self, forKey: .text)
        self.direction = try c.decode(Direction.self, forKey: .direction)
        self.mode = try c.decode(AgentMsgMode.self, forKey: .mode)
        self.status = try c.decodeIfPresent(AgentMsgStatus.self, forKey: .status)
        self.reply = try c.decodeIfPresent(String.self, forKey: .reply)
        self.traceId = try c.decodeIfPresent(String.self, forKey: .traceId)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("agent_msg", forKey: .kind)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.at, forKey: .at)
        try c.encode(self.fromAgent, forKey: .fromAgent)
        try c.encode(self.toAgent, forKey: .toAgent)
        try c.encode(self.text, forKey: .text)
        try c.encode(self.direction, forKey: .direction)
        try c.encode(self.mode, forKey: .mode)
        try c.encodeIfPresent(self.status, forKey: .status)
        try c.encodeIfPresent(self.reply, forKey: .reply)
        try c.encodeIfPresent(self.traceId, forKey: .traceId)
    }
}

public enum AgentMsgMode: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case ask, tell, reply
    public var description: String { rawValue }
}

public enum AgentMsgStatus: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case waiting, replied, noReply = "no_reply", sent, failed
    public var description: String { rawValue }
}

public struct AgentPauseParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var paused: Bool
    public init(ref: ContainerRef, paused: Bool) { self.ref = ref; self.paused = paused }
}

public struct AgentPeopleResult: Codable, Sendable, Hashable {
    public var people: [AgentPerson]
    public init(people: [AgentPerson]) { self.people = people }
}

public struct AgentPerson: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case owner, contact, agent
        public var description: String { rawValue }
    }
    public var contactId: String
    public var name: String
    public var role: Role
    public var conversationId: String
    public var started: Bool
    public var lastAt: String?
    public var preview: String?
    public init(contactId: String, name: String, role: Role, conversationId: String, started: Bool, lastAt: String? = nil, preview: String? = nil) { self.contactId = contactId; self.name = name; self.role = role; self.conversationId = conversationId; self.started = started; self.lastAt = lastAt; self.preview = preview }
}

public struct AgentRunNowParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var scheduleId: String?
    public var prompt: String?
    /// A trial run right after it's set up (docs/spec/21 D4)
    public var trial: Bool?
    public init(ref: ContainerRef, scheduleId: String? = nil, prompt: String? = nil, trial: Bool? = nil) { self.ref = ref; self.scheduleId = scheduleId; self.prompt = prompt; self.trial = trial }
}

public struct AgentRunNowResult: Codable, Sendable, Hashable {
    public var runId: String
    public init(runId: String) { self.runId = runId }
}

public struct AgentRunsResult: Codable, Sendable, Hashable {
    public struct Run: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case schedule, heartbeat, reminder, trigger, manual, automation
            public var description: String { rawValue }
        }
        public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case running, done, failed, skipped
            public var description: String { rawValue }
        }
        public var id: String
        public var kind: Kind
        public var source: String
        public var prompt: String
        public var firedAt: String
        public var status: Status
        public var summary: String?
        public var sent: Int
        public var costUsd: Double?
        public init(id: String, kind: Kind, source: String, prompt: String, firedAt: String, status: Status, summary: String? = nil, sent: Int, costUsd: Double? = nil) { self.id = id; self.kind = kind; self.source = source; self.prompt = prompt; self.firedAt = firedAt; self.status = status; self.summary = summary; self.sent = sent; self.costUsd = costUsd }
    }
    public struct Held: Codable, Sendable, Hashable, Identifiable {
        public enum Reason: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case quiet, limit, paused
            public var description: String { rawValue }
        }
        public var id: String
        public var to: String
        public var text: String
        public var notBefore: String
        public var reason: Reason
        public init(id: String, to: String, text: String, notBefore: String, reason: Reason) { self.id = id; self.to = to; self.text = text; self.notBefore = notBefore; self.reason = reason }
    }
    public struct Upcoming: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case schedule, heartbeat, reminder, watch
            public var description: String { rawValue }
        }
        public var id: String
        public var kind: Kind
        public var label: String
        public var next: String?
        /// A repeating one's cron
        public var cron: String?
        public init(id: String, kind: Kind, label: String, next: String? = nil, cron: String? = nil) { self.id = id; self.kind = kind; self.label = label; self.next = next; self.cron = cron }
    }
    public var runs: [Run]
    public var outbox: [Held]
    public var upcoming: [Upcoming]
    public init(runs: [Run], outbox: [Held], upcoming: [Upcoming]) { self.runs = runs; self.outbox = outbox; self.upcoming = upcoming }
}

public struct AgentSaveParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var definition: JSONValue
    public var instructions: String
    public var message: String?
    public init(ref: ContainerRef, definition: JSONValue, instructions: String, message: String? = nil) { self.ref = ref; self.definition = definition; self.instructions = instructions; self.message = message }
}

public struct AgentSaveResult: Codable, Sendable, Hashable {
    public var errors: [DefinitionError]
    public var saved: Bool
    public init(errors: [DefinitionError], saved: Bool) { self.errors = errors; self.saved = saved }
}

public struct AgentTemplate: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var avatar: String
    public var description: String
    public var instructions: String
    public var schedule: String?
    public init(id: String, name: String, avatar: String, description: String, instructions: String, schedule: String? = nil) { self.id = id; self.name = name; self.avatar = avatar; self.description = description; self.instructions = instructions; self.schedule = schedule }
}

public struct AgentTemplatesResult: Codable, Sendable, Hashable {
    public var templates: [AgentTemplate]
    public init(templates: [AgentTemplate]) { self.templates = templates }
}

public struct AgentTrace: Codable, Sendable, Hashable {
    public struct Hop: Codable, Sendable, Hashable, Identifiable {
        public struct From: Codable, Sendable, Hashable, Identifiable {
            public var id: String
            public var name: String
            public init(id: String, name: String) { self.id = id; self.name = name }
        }
        public struct To: Codable, Sendable, Hashable, Identifiable {
            public var id: String
            public var name: String
            public init(id: String, name: String) { self.id = id; self.name = name }
        }
        public var id: String
        public var parent: String?
        public var hop: Int
        public var mode: AgentMsgMode
        public var from: From
        public var to: To
        public var text: String
        public var reply: String?
        public var at: String
        public var status: AgentMsgStatus
        public var costUsd: Double?
        public var error: String?
        public init(id: String, parent: String? = nil, hop: Int, mode: AgentMsgMode, from: From, to: To, text: String, reply: String? = nil, at: String, status: AgentMsgStatus, costUsd: Double? = nil, error: String? = nil) { self.id = id; self.parent = parent; self.hop = hop; self.mode = mode; self.from = from; self.to = to; self.text = text; self.reply = reply; self.at = at; self.status = status; self.costUsd = costUsd; self.error = error }
    }
    public var traceId: String
    public var costUsd: Double
    public var hops: [Hop]
    public init(traceId: String, costUsd: Double, hops: [Hop]) { self.traceId = traceId; self.costUsd = costUsd; self.hops = hops }
}

public struct AgentUndoParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var undoId: String
    public init(ref: ContainerRef, undoId: String) { self.ref = ref; self.undoId = undoId }
}

public struct AgentsDecideResult: Codable, Sendable, Hashable {
    public var status: ApprovalStatus
    public init(status: ApprovalStatus) { self.status = status }
}

public struct AgentsDeployParams: Codable, Sendable, Hashable {
    public struct Telegram: Codable, Sendable, Hashable {
        public var token: String
        public init(token: String) { self.token = token }
    }
    public var ref: ContainerRef
    public var definition: JSONValue
    public var instructions: String
    public var memory: [CloudMemory]?
    public var reminders: [JSONValue]?
    public var telegram: Telegram?
    public init(ref: ContainerRef, definition: JSONValue, instructions: String, memory: [CloudMemory]? = nil, reminders: [JSONValue]? = nil, telegram: Telegram? = nil) { self.ref = ref; self.definition = definition; self.instructions = instructions; self.memory = memory; self.reminders = reminders; self.telegram = telegram }
}

public struct AgentsDeployResult: Codable, Sendable, Hashable {
    public var deployedAt: String
    public var lines: [String]
    public init(deployedAt: String, lines: [String]) { self.deployedAt = deployedAt; self.lines = lines }
}

public struct AgentsExportParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public init(ref: ContainerRef) { self.ref = ref }
}

public struct AgentsExportResult: Codable, Sendable, Hashable {
    public struct Telegram: Codable, Sendable, Hashable {
        public var token: String
        public init(token: String) { self.token = token }
    }
    public var definition: JSONValue
    public var instructions: String
    public var memory: [CloudMemory]
    public var reminders: [JSONValue]
    public var telegram: Telegram?
    public init(definition: JSONValue, instructions: String, memory: [CloudMemory], reminders: [JSONValue], telegram: Telegram? = nil) { self.definition = definition; self.instructions = instructions; self.memory = memory; self.reminders = reminders; self.telegram = telegram }
}

public struct AgentsFilesDeleteParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var name: String
    public init(ref: ContainerRef, name: String) { self.ref = ref; self.name = name }
}

public struct AgentsRetireParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public init(ref: ContainerRef) { self.ref = ref }
}

public struct AgentsStatusParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public init(ref: ContainerRef) { self.ref = ref }
}

public struct AgentsStatusResult: Codable, Sendable, Hashable {
    public var paused: Bool
    public var spendUsd: Double
    public var budgetUsd: Double?
    public var inbox: Double
    public var nextRun: String?
    public init(paused: Bool, spendUsd: Double, budgetUsd: Double? = nil, inbox: Double, nextRun: String? = nil) { self.paused = paused; self.spendUsd = spendUsd; self.budgetUsd = budgetUsd; self.inbox = inbox; self.nextRun = nextRun }
}

public struct AgentsTriggersParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public init(ref: ContainerRef) { self.ref = ref }
}

public struct AgentsTriggersResult: Codable, Sendable, Hashable {
    public struct Trigger: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var url: String
        public init(id: String, url: String) { self.id = id; self.url = url }
    }
    public var triggers: [Trigger]
    public init(triggers: [Trigger]) { self.triggers = triggers }
}

public struct AnswerSideParams: Codable, Sendable, Hashable, Identifiable {
    public enum Choice: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case new, here, start, dismiss
        public var description: String { rawValue }
    }
    public var ref: ContainerRef
    /// The offer's or proposal's tool call id
    public var id: String
    public var choice: Choice
    public init(ref: ContainerRef, id: String, choice: Choice) { self.ref = ref; self.id = id; self.choice = choice }
}

public struct AnswerSideResult: Codable, Sendable, Hashable {
    public var ref: ContainerRef?
    public var askAlways: Bool?
    public init(ref: ContainerRef? = nil, askAlways: Bool? = nil) { self.ref = ref; self.askAlways = askAlways }
}

public struct AppConversationResult: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public init(ref: ContainerRef) { self.ref = ref }
}

public struct AppResult: Codable, Sendable, Hashable {
    public var app: AppView
    public init(app: AppView) { self.app = app }
}

public struct AppSourceStatus: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case file, calendar, piopio
        public var description: String { rawValue }
    }
    public struct Account: Codable, Sendable, Hashable, Identifiable {
        public enum State: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case ok, failed, gone
            public var description: String { rawValue }
        }
        public var id: String
        public var label: String
        public var state: State
        public var error: String?
        public var readAt: String?
        public var failedAt: String?
        public init(id: String, label: String, state: State, error: String? = nil, readAt: String? = nil, failedAt: String? = nil) { self.id = id; self.label = label; self.state = state; self.error = error; self.readAt = readAt; self.failedAt = failedAt }
    }
    public enum State: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case ok, failed, waiting
        public var description: String { rawValue }
    }
    public var name: String
    public var kind: Kind
    public var file: String
    public var path: String
    public var columns: [String]?
    public var accounts: [Account]?
    public var state: State
    public var error: String?
    public var readAt: String?
    public var failedAt: String?
    public init(name: String, kind: Kind, file: String, path: String, columns: [String]? = nil, accounts: [Account]? = nil, state: State, error: String? = nil, readAt: String? = nil, failedAt: String? = nil) { self.name = name; self.kind = kind; self.file = file; self.path = path; self.columns = columns; self.accounts = accounts; self.state = state; self.error = error; self.readAt = readAt; self.failedAt = failedAt }
}

public struct AppToolParams: Codable, Sendable, Hashable {
    public struct Agent: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public struct Preview: Codable, Sendable, Hashable {
        public var profile: String
        public var local: [String]
        public init(profile: String, local: [String]) { self.profile = profile; self.local = local }
    }
    public var name: String
    public var args: JSONValue
    public var agent: Agent?
    public var ref: ContainerRef?
    public var sites: [String]?
    public var preview: Preview?
    public var profile: String?
    public var groups: [String]
    public var shortcuts: [String]
    public init(name: String, args: JSONValue, agent: Agent? = nil, ref: ContainerRef? = nil, sites: [String]? = nil, preview: Preview? = nil, profile: String? = nil, groups: [String], shortcuts: [String]) { self.name = name; self.args = args; self.agent = agent; self.ref = ref; self.sites = sites; self.preview = preview; self.profile = profile; self.groups = groups; self.shortcuts = shortcuts }
}

public struct AppToolResult: Codable, Sendable, Hashable {
    public struct Image: Codable, Sendable, Hashable {
        public var mimeType: String
        public var data: String
        public init(mimeType: String, data: String) { self.mimeType = mimeType; self.data = data }
    }
    public struct Card: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case reminder, event, contact, note, music, shortcut
            public var description: String { rawValue }
        }
        public var kind: Kind
        public var title: String
        public var detail: String?
        public init(kind: Kind, title: String, detail: String? = nil) { self.kind = kind; self.title = title; self.detail = detail }
    }
    public struct Undo: Codable, Sendable, Hashable {
        public var name: String
        public var args: JSONValue
        public var title: String
        public init(name: String, args: JSONValue, title: String) { self.name = name; self.args = args; self.title = title }
    }
    public var ok: Bool
    public var output: String
    public var images: [Image]?
    public var needsSite: String?
    public var card: Card?
    public var undo: Undo?
    public init(ok: Bool, output: String, images: [Image]? = nil, needsSite: String? = nil, card: Card? = nil, undo: Undo? = nil) { self.ok = ok; self.output = output; self.images = images; self.needsSite = needsSite; self.card = card; self.undo = undo }
}

public struct AppUndo: Codable, Sendable, Hashable {
    public var label: String
    public var at: String
    public init(label: String, at: String) { self.label = label; self.at = at }
}

public struct AppUndoParams: Codable, Sendable, Hashable {
    public var path: String
    public var force: Bool?
    public init(path: String, force: Bool? = nil) { self.path = path; self.force = force }
}

public struct AppView: Codable, Sendable, Hashable {
    public var path: String
    public var title: String
    public var html: String
    public var sources: [AppSourceStatus]
    public var data: [String: JSONValue]
    public var stale: [String]
    public var allowed: Bool
    public var updatedAt: String?
    public var undo: AppUndo?
    public var conversation: String?
    public init(path: String, title: String, html: String, sources: [AppSourceStatus], data: [String: JSONValue], stale: [String], allowed: Bool, updatedAt: String? = nil, undo: AppUndo? = nil, conversation: String? = nil) { self.path = path; self.title = title; self.html = html; self.sources = sources; self.data = data; self.stale = stale; self.allowed = allowed; self.updatedAt = updatedAt; self.undo = undo; self.conversation = conversation }
}

public struct ApprovalItem: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case connector
        public var description: String { rawValue }
    }
    public var id: String
    public var at: String
    public var approvalId: String
    public var tool: String
    public var title: String
    public var args: JSONValue
    public var status: ApprovalStatus
    public var editedArgs: JSONValue?
    public var reason: String?
    public var expiresAt: String
    public var always: String
    public var source: Source?
    public init(id: String, at: String, approvalId: String, tool: String, title: String, args: JSONValue, status: ApprovalStatus, editedArgs: JSONValue? = nil, reason: String? = nil, expiresAt: String, always: String, source: Source? = nil) { self.id = id; self.at = at; self.approvalId = approvalId; self.tool = tool; self.title = title; self.args = args; self.status = status; self.editedArgs = editedArgs; self.reason = reason; self.expiresAt = expiresAt; self.always = always; self.source = source }
    private enum CodingKeys: String, CodingKey { case id, at, approvalId, tool, title, args, status, editedArgs, reason, expiresAt, always, source, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.at = try c.decode(String.self, forKey: .at)
        self.approvalId = try c.decode(String.self, forKey: .approvalId)
        self.tool = try c.decode(String.self, forKey: .tool)
        self.title = try c.decode(String.self, forKey: .title)
        self.args = try c.decode(JSONValue.self, forKey: .args)
        self.status = try c.decode(ApprovalStatus.self, forKey: .status)
        self.editedArgs = try c.decodeIfPresent(JSONValue.self, forKey: .editedArgs)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.expiresAt = try c.decode(String.self, forKey: .expiresAt)
        self.always = try c.decode(String.self, forKey: .always)
        self.source = try c.decodeIfPresent(Source.self, forKey: .source)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("approval", forKey: .kind)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.at, forKey: .at)
        try c.encode(self.approvalId, forKey: .approvalId)
        try c.encode(self.tool, forKey: .tool)
        try c.encode(self.title, forKey: .title)
        try c.encode(self.args, forKey: .args)
        try c.encode(self.status, forKey: .status)
        try c.encodeIfPresent(self.editedArgs, forKey: .editedArgs)
        try c.encodeIfPresent(self.reason, forKey: .reason)
        try c.encode(self.expiresAt, forKey: .expiresAt)
        try c.encode(self.always, forKey: .always)
        try c.encodeIfPresent(self.source, forKey: .source)
    }
}

public enum ApprovalMode: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case readOnly = "read_only", ask, autoEdit = "auto_edit", fullAuto = "full_auto"
    public var description: String { rawValue }
}

public struct ApprovalRule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ApprovalRuleKind
    public var pattern: String
    public var createdAt: String
    public init(id: String, kind: ApprovalRuleKind, pattern: String, createdAt: String) { self.id = id; self.kind = kind; self.pattern = pattern; self.createdAt = createdAt }
}

public enum ApprovalRuleKind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case command, tool, path, host
    public var description: String { rawValue }
}

public enum ApprovalStatus: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case pending, approved, denied, expired, cancelled
    public var description: String { rawValue }
}

public struct AssistantItem: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case streaming, done, error, aborted
        public var description: String { rawValue }
    }
    public struct Outbound: Codable, Sendable, Hashable {
        public var from: String
        /// Quick replies offered with it (a new agent's greeting)
        public var suggestions: [String]?
        public init(from: String, suggestions: [String]? = nil) { self.from = from; self.suggestions = suggestions }
    }
    public var id: String
    public var at: String
    public var parts: [AssistantPart]
    public var model: String?
    public var usage: Usage?
    public var status: Status
    public var error: String?
    public var errorKind: ErrorKind?
    public var errorDetail: String?
    public var outbound: Outbound?
    public var thinkingMs: Double?
    public init(id: String, at: String, parts: [AssistantPart], model: String? = nil, usage: Usage? = nil, status: Status, error: String? = nil, errorKind: ErrorKind? = nil, errorDetail: String? = nil, outbound: Outbound? = nil, thinkingMs: Double? = nil) { self.id = id; self.at = at; self.parts = parts; self.model = model; self.usage = usage; self.status = status; self.error = error; self.errorKind = errorKind; self.errorDetail = errorDetail; self.outbound = outbound; self.thinkingMs = thinkingMs }
    private enum CodingKeys: String, CodingKey { case id, at, parts, model, usage, status, error, errorKind, errorDetail, outbound, thinkingMs, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.at = try c.decode(String.self, forKey: .at)
        self.parts = try c.decode([AssistantPart].self, forKey: .parts)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        self.status = try c.decode(Status.self, forKey: .status)
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
        self.errorKind = try c.decodeIfPresent(ErrorKind.self, forKey: .errorKind)
        self.errorDetail = try c.decodeIfPresent(String.self, forKey: .errorDetail)
        self.outbound = try c.decodeIfPresent(Outbound.self, forKey: .outbound)
        self.thinkingMs = try c.decodeIfPresent(Double.self, forKey: .thinkingMs)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("assistant", forKey: .kind)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.at, forKey: .at)
        try c.encode(self.parts, forKey: .parts)
        try c.encodeIfPresent(self.model, forKey: .model)
        try c.encodeIfPresent(self.usage, forKey: .usage)
        try c.encode(self.status, forKey: .status)
        try c.encodeIfPresent(self.error, forKey: .error)
        try c.encodeIfPresent(self.errorKind, forKey: .errorKind)
        try c.encodeIfPresent(self.errorDetail, forKey: .errorDetail)
        try c.encodeIfPresent(self.outbound, forKey: .outbound)
        try c.encodeIfPresent(self.thinkingMs, forKey: .thinkingMs)
    }
}

public enum AssistantPart: Codable, Sendable, Hashable {
    case text(String)
    case thinking(text: String, redacted: Bool? = nil)
    private enum CodingKeys: String, CodingKey { case type, text, redacted }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "thinking": self = .thinking(text: try c.decode(String.self, forKey: .text), redacted: try c.decodeIfPresent(Bool.self, forKey: .redacted))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown type \(tag)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("text", forKey: .type); try c.encode(text, forKey: .text)
        case .thinking(let text, let redacted): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("thinking", forKey: .type); try c.encode(text, forKey: .text); try c.encodeIfPresent(redacted, forKey: .redacted)
        }
    }
}

public enum Attachment: Codable, Sendable, Hashable {
    case image(name: String, mimeType: String, data: String, path: String? = nil)
    case text(name: String, mimeType: String? = nil, text: String, path: String? = nil)
    private enum CodingKeys: String, CodingKey { case kind, name, mimeType, data, path, text }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .kind)
        switch tag {
        case "image": self = .image(name: try c.decode(String.self, forKey: .name), mimeType: try c.decode(String.self, forKey: .mimeType), data: try c.decode(String.self, forKey: .data), path: try c.decodeIfPresent(String.self, forKey: .path))
        case "text": self = .text(name: try c.decode(String.self, forKey: .name), mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType), text: try c.decode(String.self, forKey: .text), path: try c.decodeIfPresent(String.self, forKey: .path))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown kind \(tag)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .image(let name, let mimeType, let data, let path): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("image", forKey: .kind); try c.encode(name, forKey: .name); try c.encode(mimeType, forKey: .mimeType); try c.encode(data, forKey: .data); try c.encodeIfPresent(path, forKey: .path)
        case .text(let name, let mimeType, let text, let path): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("text", forKey: .kind); try c.encode(name, forKey: .name); try c.encodeIfPresent(mimeType, forKey: .mimeType); try c.encode(text, forKey: .text); try c.encodeIfPresent(path, forKey: .path)
        }
    }
}

public struct AttachmentInfo: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case image, text
        public var description: String { rawValue }
    }
    public var name: String
    public var kind: Kind
    public var mimeType: String?
    public var size: Double?
    public var stored: String?
    public init(name: String, kind: Kind, mimeType: String? = nil, size: Double? = nil, stored: String? = nil) { self.name = name; self.kind = kind; self.mimeType = mimeType; self.size = size; self.stored = stored }
}

public enum AuthMethod: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case apiKey = "api_key", oauth
    public var description: String { rawValue }
}

public struct Automation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var on: AutomationTrigger
    public var cron: String?
    /// time, once: epoch ms
    public var at: Double?
    public var tz: String?
    public var folder: String?
    public var from: String?
    public var subject: String?
    /// “piopio”, or an agent's id
    public var runsAs: String
    /// A project's id; only when Piopio runs it
    public var project: String?
    public var prompt: String
    public var result: AutomationDelivery
    /// An agent's contact the result is for (default its owner)
    public var deliverTo: String?
    public var approval: AutomationApproval
    public var budgetPerRunUsd: Double?
    public var enabled: Bool
    /// “you”, “piopio”, or the agent that made it
    public var by: String
    public var createdAt: String
    /// time: the next run, epoch ms
    public var next: Double?
    public var lastRun: String?
    public var runCount: Int
    /// Not opened since it was made (the list's “New” badge)
    public var fresh: Bool?
    public var aliases: [String]?
    /// “Every Monday at 09:00”, “When a file appears in ~/Inbox”
    public var label: String
    /// “Piopio”, “Piopio in shop”, “Rita”
    public var runnerName: String
    /// “Rita’s chat”, “Telegram”, “A conversation in shop”, “Only if it needs you”
    public var resultLabel: String
    /// webhook: where to POST
    public var url: String?
    public var lastStatus: AutomationRunStatus?
    public var lastSummary: String?
    public init(id: String, name: String, on: AutomationTrigger, cron: String? = nil, at: Double? = nil, tz: String? = nil, folder: String? = nil, from: String? = nil, subject: String? = nil, runsAs: String, project: String? = nil, prompt: String, result: AutomationDelivery, deliverTo: String? = nil, approval: AutomationApproval, budgetPerRunUsd: Double? = nil, enabled: Bool, by: String, createdAt: String, next: Double? = nil, lastRun: String? = nil, runCount: Int, fresh: Bool? = nil, aliases: [String]? = nil, label: String, runnerName: String, resultLabel: String, url: String? = nil, lastStatus: AutomationRunStatus? = nil, lastSummary: String? = nil) { self.id = id; self.name = name; self.on = on; self.cron = cron; self.at = at; self.tz = tz; self.folder = folder; self.from = from; self.subject = subject; self.runsAs = runsAs; self.project = project; self.prompt = prompt; self.result = result; self.deliverTo = deliverTo; self.approval = approval; self.budgetPerRunUsd = budgetPerRunUsd; self.enabled = enabled; self.by = by; self.createdAt = createdAt; self.next = next; self.lastRun = lastRun; self.runCount = runCount; self.fresh = fresh; self.aliases = aliases; self.label = label; self.runnerName = runnerName; self.resultLabel = resultLabel; self.url = url; self.lastStatus = lastStatus; self.lastSummary = lastSummary }
}

public enum AutomationApproval: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case wait, skip
    public var description: String { rawValue }
}

public struct AutomationChange: Codable, Sendable, Hashable {
    public var name: String?
    public var on: AutomationTrigger?
    /// time: a 5-field cron, or a local date-time once
    public var when: String?
    public var folder: String?
    public var from: String?
    public var subject: String?
    public var runsAs: String?
    public var project: Nullable<String>?
    public var prompt: String?
    public var result: AutomationDelivery?
    public var approval: AutomationApproval?
    public var budgetPerRunUsd: Nullable<Double>?
    public var enabled: Bool?
    public init(name: String? = nil, on: AutomationTrigger? = nil, when: String? = nil, folder: String? = nil, from: String? = nil, subject: String? = nil, runsAs: String? = nil, project: Nullable<String>? = nil, prompt: String? = nil, result: AutomationDelivery? = nil, approval: AutomationApproval? = nil, budgetPerRunUsd: Nullable<Double>? = nil, enabled: Bool? = nil) { self.name = name; self.on = on; self.when = when; self.folder = folder; self.from = from; self.subject = subject; self.runsAs = runsAs; self.project = project; self.prompt = prompt; self.result = result; self.approval = approval; self.budgetPerRunUsd = budgetPerRunUsd; self.enabled = enabled }
}

public enum AutomationDelivery: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case chat, telegram, conversation, quiet
    public var description: String { rawValue }
}

public struct AutomationDetail: Codable, Sendable, Hashable {
    public var automation: Automation
    public var runs: [AutomationRun]
    public var summary: AutomationSummary
    public init(automation: Automation, runs: [AutomationRun], summary: AutomationSummary) { self.automation = automation; self.runs = runs; self.summary = summary }
}

public struct AutomationIdParams: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct AutomationResult: Codable, Sendable, Hashable {
    public var automation: Automation
    public init(automation: Automation) { self.automation = automation }
}

public struct AutomationRun: Codable, Sendable, Hashable, Identifiable {
    public enum Cause: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case time, event, now
        public var description: String { rawValue }
    }
    public var id: String
    public var automation: String
    public var firedAt: String
    public var cause: Cause
    public var status: AutomationRunStatus
    public var summary: String?
    public var costUsd: Double?
    public var conversation: String?
    public var agent: String?
    public var agentRun: String?
    public init(id: String, automation: String, firedAt: String, cause: Cause, status: AutomationRunStatus, summary: String? = nil, costUsd: Double? = nil, conversation: String? = nil, agent: String? = nil, agentRun: String? = nil) { self.id = id; self.automation = automation; self.firedAt = firedAt; self.cause = cause; self.status = status; self.summary = summary; self.costUsd = costUsd; self.conversation = conversation; self.agent = agent; self.agentRun = agentRun }
}

public struct AutomationRunResult: Codable, Sendable, Hashable {
    public var run: AutomationRun
    public init(run: AutomationRun) { self.run = run }
}

public enum AutomationRunStatus: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case running, done, quiet, waiting, skipped, failed
    public var description: String { rawValue }
}

public struct AutomationSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// “Every Monday at 09:00”, “When an email from the bank arrives”
    public var when: String
    /// “Rita”, “Piopio in shop”
    public var runsAs: String
    public var does: String
    /// “Rita’s chat”, “Telegram”, “A conversation in shop”, “Only if it needs you”
    public var tellsYou: String
    /// “This Mac, only while it's awake”
    public var runsOn: String
    /// webhook: where to POST
    public var url: String?
    /// time: the next run, epoch ms
    public var next: Double?
    public init(id: String, name: String, when: String, runsAs: String, does: String, tellsYou: String, runsOn: String, url: String? = nil, next: Double? = nil) { self.id = id; self.name = name; self.when = when; self.runsAs = runsAs; self.does = does; self.tellsYou = tellsYou; self.runsOn = runsOn; self.url = url; self.next = next }
}

public enum AutomationTrigger: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case time, folder, email, webhook
    public var description: String { rawValue }
}

public struct AutomationsAddParams: Codable, Sendable, Hashable {
    public var automationChange: AutomationChange
    public var prompt: String
    public init(automationChange: AutomationChange, prompt: String) { self.automationChange = automationChange; self.prompt = prompt }
    private enum CodingKeys: String, CodingKey { case prompt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.automationChange = try AutomationChange(from: decoder)
        self.prompt = try c.decode(String.self, forKey: .prompt)
    }
    public func encode(to encoder: Encoder) throws {
        try self.automationChange.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.prompt, forKey: .prompt)
    }
}

public struct AutomationsParams: Codable, Sendable, Hashable {
    public var runsAs: String?
    public var project: String?
    public init(runsAs: String? = nil, project: String? = nil) { self.runsAs = runsAs; self.project = project }
}

public struct AutomationsResult: Codable, Sendable, Hashable {
    public var automations: [Automation]
    public init(automations: [Automation]) { self.automations = automations }
}

public struct AutomationsRunsParams: Codable, Sendable, Hashable, Identifiable {
    public var id: String?
    public var limit: Double?
    public init(id: String? = nil, limit: Double? = nil) { self.id = id; self.limit = limit }
}

public struct AutomationsRunsResult: Codable, Sendable, Hashable {
    public var runs: [AutomationRun]
    public init(runs: [AutomationRun]) { self.runs = runs }
}

public struct AutomationsUpdateParams: Codable, Sendable, Hashable, Identifiable {
    public var automationChange: AutomationChange
    public var id: String
    public init(automationChange: AutomationChange, id: String) { self.automationChange = automationChange; self.id = id }
    private enum CodingKeys: String, CodingKey { case id }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.automationChange = try AutomationChange(from: decoder)
        self.id = try c.decode(String.self, forKey: .id)
    }
    public func encode(to encoder: Encoder) throws {
        try self.automationChange.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.id, forKey: .id)
    }
}

public struct BackgroundProcess: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case running, exited, stopped
        public var description: String { rawValue }
    }
    public var id: String
    public var command: String
    public var description: String?
    public var cwd: String
    public var status: Status
    public var exitCode: Int?
    public var startedAt: String
    public var endedAt: String?
    public var urls: [String]
    public init(id: String, command: String, description: String? = nil, cwd: String, status: Status, exitCode: Int? = nil, startedAt: String, endedAt: String? = nil, urls: [String]) { self.id = id; self.command = command; self.description = description; self.cwd = cwd; self.status = status; self.exitCode = exitCode; self.startedAt = startedAt; self.endedAt = endedAt; self.urls = urls }
}

public struct BranchInfo: Codable, Sendable, Hashable {
    public var index: Int
    public var count: Int
    public var previous: String?
    public var next: String?
    public init(index: Int, count: Int, previous: String? = nil, next: String? = nil) { self.index = index; self.count = count; self.previous = previous; self.next = next }
}

public struct BrowserSitesResult: Codable, Sendable, Hashable {
    public struct Site: Codable, Sendable, Hashable {
        public enum Level: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case allowed, blocked
            public var description: String { rawValue }
        }
        public var site: String
        public var level: Level
        public init(site: String, level: Level) { self.site = site; self.level = level }
    }
    public var sites: [Site]
    public init(sites: [Site]) { self.sites = sites }
}

public struct Budget: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case agent, automation
        public var description: String { rawValue }
    }
    public enum Period: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case month, run
        public var description: String { rawValue }
    }
    public var id: String
    public var kind: Kind
    public var name: String
    public var spentUsd: Double
    public var limitUsd: Double
    public var period: Period
    public var resets: String?
    public var ref: ContainerRef?
    public var automation: String?
    public init(id: String, kind: Kind, name: String, spentUsd: Double, limitUsd: Double, period: Period, resets: String? = nil, ref: ContainerRef? = nil, automation: String? = nil) { self.id = id; self.kind = kind; self.name = name; self.spentUsd = spentUsd; self.limitUsd = limitUsd; self.period = period; self.resets = resets; self.ref = ref; self.automation = automation }
}

public struct BudgetChanged: Codable, Sendable, Hashable {
    public var notify: String?
    public init(notify: String? = nil) { self.notify = notify }
}

public struct BudgetReleaseParams: Codable, Sendable, Hashable {
    public var run: String?
    public var month: Bool?
    public init(run: String? = nil, month: Bool? = nil) { self.run = run; self.month = month }
}

public struct BudgetSetParams: Codable, Sendable, Hashable {
    public var monthUsd: Double?
    public init(monthUsd: Double?) { self.monthUsd = monthUsd }
    private enum CodingKeys: String, CodingKey { case monthUsd }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.monthUsd, forKey: .monthUsd)
    }
}

public struct Budgets: Codable, Sendable, Hashable {
    public var budgets: [Budget]
    public var piopio: PiopioBudget
    public init(budgets: [Budget], piopio: PiopioBudget) { self.budgets = budgets; self.piopio = piopio }
}

public struct CatalogChanged: Codable, Sendable, Hashable {
    public var upserted: [SessionSummary]
    public var removed: [ContainerRef]
    public init(upserted: [SessionSummary], removed: [ContainerRef]) { self.upserted = upserted; self.removed = removed }
}

public struct ChangesParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var since: ChangesSince
    public init(ref: ContainerRef, since: ChangesSince) { self.ref = ref; self.since = since }
}

public struct ChangesResult: Codable, Sendable, Hashable {
    public var base: String?
    public var files: [FileChange]
    public init(base: String? = nil, files: [FileChange]) { self.base = base; self.files = files }
}

public enum ChangesSince: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case session, turn
    public var description: String { rawValue }
}

public struct CheckpointItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var at: String
    public var checkpointId: String
    public var label: String
    public var files: Int?
    public init(id: String, at: String, checkpointId: String, label: String, files: Int? = nil) { self.id = id; self.at = at; self.checkpointId = checkpointId; self.label = label; self.files = files }
    private enum CodingKeys: String, CodingKey { case id, at, checkpointId, label, files, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.at = try c.decode(String.self, forKey: .at)
        self.checkpointId = try c.decode(String.self, forKey: .checkpointId)
        self.label = try c.decode(String.self, forKey: .label)
        self.files = try c.decodeIfPresent(Int.self, forKey: .files)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("checkpoint", forKey: .kind)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.at, forKey: .at)
        try c.encode(self.checkpointId, forKey: .checkpointId)
        try c.encode(self.label, forKey: .label)
        try c.encodeIfPresent(self.files, forKey: .files)
    }
}

public struct CloudConnectParams: Codable, Sendable, Hashable {
    public var url: String
    public var token: String
    public init(url: String, token: String) { self.url = url; self.token = token }
}

public struct CloudMemory: Codable, Sendable, Hashable {
    public enum CreatedBy: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case agent, user, extraction
        public var description: String { rawValue }
    }
    public var partition: String
    public var text: String
    public var kind: String
    public var createdBy: CreatedBy
    public var at: String
    public var tags: [String]?
    public var pinned: Bool?
    public init(partition: String, text: String, kind: String, createdBy: CreatedBy, at: String, tags: [String]? = nil, pinned: Bool? = nil) { self.partition = partition; self.text = text; self.kind = kind; self.createdBy = createdBy; self.at = at; self.tags = tags; self.pinned = pinned }
}

public struct CloudSetupParams: Codable, Sendable, Hashable {
    public var apiToken: String
    public var accountId: String?
    public init(apiToken: String, accountId: String? = nil) { self.apiToken = apiToken; self.accountId = accountId }
}

public struct CloudSetupResult: Codable, Sendable, Hashable {
    public struct Account: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public var status: CloudStatus?
    public var accounts: [Account]?
    public init(status: CloudStatus? = nil, accounts: [Account]? = nil) { self.status = status; self.accounts = accounts }
}

public struct CloudStatus: Codable, Sendable, Hashable {
    public struct Agent: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var avatar: String?
        public var deployedAt: String
        public init(id: String, name: String, avatar: String? = nil, deployedAt: String) { self.id = id; self.name = name; self.avatar = avatar; self.deployedAt = deployedAt }
    }
    public var connected: Bool
    public var url: String?
    public var reachable: Bool?
    public var version: String?
    public var error: String?
    public var connectedAt: String?
    public var managed: Bool?
    public var agents: [Agent]
    public init(connected: Bool, url: String? = nil, reachable: Bool? = nil, version: String? = nil, error: String? = nil, connectedAt: String? = nil, managed: Bool? = nil, agents: [Agent]) { self.connected = connected; self.url = url; self.reachable = reachable; self.version = version; self.error = error; self.connectedAt = connectedAt; self.managed = managed; self.agents = agents }
}

public struct CommandsResult: Codable, Sendable, Hashable {
    public var commands: [SessionCommand]
    public init(commands: [SessionCommand]) { self.commands = commands }
}

public struct CompactionItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var at: String
    public var summary: String
    public init(id: String, at: String, summary: String) { self.id = id; self.at = at; self.summary = summary }
    private enum CodingKeys: String, CodingKey { case id, at, summary, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.at = try c.decode(String.self, forKey: .at)
        self.summary = try c.decode(String.self, forKey: .summary)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("compaction", forKey: .kind)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.at, forKey: .at)
        try c.encode(self.summary, forKey: .summary)
    }
}

public struct ConfigureParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var model: ModelRef?
    public var thinking: String?
    public var web: Bool?
    public var approvalMode: ApprovalMode?
    public var planMode: Bool?
    public var toolsOff: [String]?
    public init(ref: ContainerRef, model: ModelRef? = nil, thinking: String? = nil, web: Bool? = nil, approvalMode: ApprovalMode? = nil, planMode: Bool? = nil, toolsOff: [String]? = nil) { self.ref = ref; self.model = model; self.thinking = thinking; self.web = web; self.approvalMode = approvalMode; self.planMode = planMode; self.toolsOff = toolsOff }
}

public struct ConfigureWorkParams: Codable, Sendable, Hashable {
    public var project: String
    public var parallel: Bool?
    public var review: Bool?
    public var reviewLimit: Int?
    /// Empty removes it
    public var testCommand: String?
    public var maxParallel: Int?
    public var buildModel: Nullable<String>?
    public var reviewModel: Nullable<String>?
    public var helperMode: ApprovalMode?
    public var budgetPerJob: Nullable<Double>?
    public var playbook: String?
    /// A folder without git: make it a repo first, so tasks get branches
    public var initGit: Bool?
    public init(project: String, parallel: Bool? = nil, review: Bool? = nil, reviewLimit: Int? = nil, testCommand: String? = nil, maxParallel: Int? = nil, buildModel: Nullable<String>? = nil, reviewModel: Nullable<String>? = nil, helperMode: ApprovalMode? = nil, budgetPerJob: Nullable<Double>? = nil, playbook: String? = nil, initGit: Bool? = nil) { self.project = project; self.parallel = parallel; self.review = review; self.reviewLimit = reviewLimit; self.testCommand = testCommand; self.maxParallel = maxParallel; self.buildModel = buildModel; self.reviewModel = reviewModel; self.helperMode = helperMode; self.budgetPerJob = budgetPerJob; self.playbook = playbook; self.initGit = initGit }
}

public struct ConnectorAccountParams: Codable, Sendable, Hashable {
    public var accountId: String
    public init(accountId: String) { self.accountId = accountId }
}

public struct ConnectorAuthNotification: Codable, Sendable, Hashable {
    public var loginId: String
    public var connector: String
    public var event: ProviderAuthEvent
    public init(loginId: String, connector: String, event: ProviderAuthEvent) { self.loginId = loginId; self.connector = connector; self.event = event }
}

public struct ConnectorCalendarsResult: Codable, Sendable, Hashable {
    public struct Calendar: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var primary: Bool
        public var color: String?
        public var enabled: Bool
        public init(id: String, name: String, primary: Bool, color: String? = nil, enabled: Bool) { self.id = id; self.name = name; self.primary = primary; self.color = color; self.enabled = enabled }
    }
    public var calendars: [Calendar]
    public init(calendars: [Calendar]) { self.calendars = calendars }
}

public struct ConnectorConfigureParams: Codable, Sendable, Hashable {
    public var connector: String
    public var chats: Bool?
    public var dontAsk: [String]?
    public var permissions: [String: ConnectorPermission]?
    public var clientId: String?
    public var clientSecret: String?
    public init(connector: String, chats: Bool? = nil, dontAsk: [String]? = nil, permissions: [String: ConnectorPermission]? = nil, clientId: String? = nil, clientSecret: String? = nil) { self.connector = connector; self.chats = chats; self.dontAsk = dontAsk; self.permissions = permissions; self.clientId = clientId; self.clientSecret = clientSecret }
}

public struct ConnectorInfo: Codable, Sendable, Hashable, Identifiable {
    public struct Account: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        public var addedAt: String
        public var problem: String?
        public init(id: String, label: String, addedAt: String, problem: String? = nil) { self.id = id; self.label = label; self.addedAt = addedAt; self.problem = problem }
    }
    public struct Capability: Codable, Sendable, Hashable, Identifiable {
        public enum Access: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case read, write, send, destructive
            public var description: String { rawValue }
        }
        public var id: String
        public var label: String
        public var tools: [String]
        public var access: Access
        public var permission: ConnectorPermission
        public var choices: [ConnectorPermission]
        public var note: String?
        public init(id: String, label: String, tools: [String], access: Access, permission: ConnectorPermission, choices: [ConnectorPermission], note: String? = nil) { self.id = id; self.label = label; self.tools = tools; self.access = access; self.permission = permission; self.choices = choices; self.note = note }
    }
    public var id: String
    public var name: String
    public var category: String
    public var description: String
    public var ready: Bool
    public var ownClient: Bool
    public var needsSecret: Bool
    public var setupHelp: String
    public var connecting: Bool
    public var chats: Bool
    public var accounts: [Account]
    public var capabilities: [Capability]
    public init(id: String, name: String, category: String, description: String, ready: Bool, ownClient: Bool, needsSecret: Bool, setupHelp: String, connecting: Bool, chats: Bool, accounts: [Account], capabilities: [Capability]) { self.id = id; self.name = name; self.category = category; self.description = description; self.ready = ready; self.ownClient = ownClient; self.needsSecret = needsSecret; self.setupHelp = setupHelp; self.connecting = connecting; self.chats = chats; self.accounts = accounts; self.capabilities = capabilities }
}

public struct ConnectorParams: Codable, Sendable, Hashable {
    public var connector: String
    public init(connector: String) { self.connector = connector }
}

public enum ConnectorPermission: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case runs, ask, off
    public var description: String { rawValue }
}

public struct ConnectorSetCalendarParams: Codable, Sendable, Hashable {
    public var accountId: String
    public var calendarId: String
    public var enabled: Bool
    public init(accountId: String, calendarId: String, enabled: Bool) { self.accountId = accountId; self.calendarId = calendarId; self.enabled = enabled }
}

public struct ConnectorsListResult: Codable, Sendable, Hashable {
    public var connectors: [ConnectorInfo]
    public init(connectors: [ConnectorInfo]) { self.connectors = connectors }
}

public enum ContainerKind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case build, thread, agent
    public var description: String { rawValue }
}

public struct ContainerRef: Codable, Sendable, Hashable, Identifiable {
    public var kind: ContainerKind
    public var id: String
    public var conversationId: String?
    public init(kind: ContainerKind, id: String, conversationId: String? = nil) { self.kind = kind; self.id = id; self.conversationId = conversationId }
}

public struct ContinueInParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var cwd: String
    public var approvalMode: ApprovalMode?
    public init(ref: ContainerRef, cwd: String, approvalMode: ApprovalMode? = nil) { self.ref = ref; self.cwd = cwd; self.approvalMode = approvalMode }
}

public struct CreateAgentParams: Codable, Sendable, Hashable {
    public var name: String
    public var template: String?
    public var avatar: String?
    public var model: ModelRef?
    public var owner: String?
    public var instructions: String?
    public var schedule: Nullable<String>?
    public init(name: String, template: String? = nil, avatar: String? = nil, model: ModelRef? = nil, owner: String? = nil, instructions: String? = nil, schedule: Nullable<String>? = nil) { self.name = name; self.template = template; self.avatar = avatar; self.model = model; self.owner = owner; self.instructions = instructions; self.schedule = schedule }
}

public struct CreatePrParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var title: String
    public var body: String
    public var base: String?
    public var draft: Bool?
    public init(ref: ContainerRef, title: String, body: String, base: String? = nil, draft: Bool? = nil) { self.ref = ref; self.title = title; self.body = body; self.base = base; self.draft = draft }
}

public struct CreateSessionParams: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case thread, build
        public var description: String { rawValue }
    }
    public var kind: Kind
    public var cwd: String?
    public var workOn: WorkOn?
    public var profile: SessionProfile?
    public var approvalMode: ApprovalMode?
    public var planMode: Bool?
    public var model: ModelRef?
    public var thinking: String?
    public var title: String?
    public var temporary: Bool?
    public init(kind: Kind, cwd: String? = nil, workOn: WorkOn? = nil, profile: SessionProfile? = nil, approvalMode: ApprovalMode? = nil, planMode: Bool? = nil, model: ModelRef? = nil, thinking: String? = nil, title: String? = nil, temporary: Bool? = nil) { self.kind = kind; self.cwd = cwd; self.workOn = workOn; self.profile = profile; self.approvalMode = approvalMode; self.planMode = planMode; self.model = model; self.thinking = thinking; self.title = title; self.temporary = temporary }
}

public struct CreateSessionResult: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public init(ref: ContainerRef) { self.ref = ref }
}

public struct CustomSubagentInfo: Codable, Sendable, Hashable {
    public enum Where: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case yours, project
        public var description: String { rawValue }
    }
    public var name: String
    public var description: String
    public var tools: [String]?
    public var model: String?
    public var path: String
    public var `where`: Where
    public init(name: String, description: String, tools: [String]? = nil, model: String? = nil, path: String, where: Where) { self.name = name; self.description = description; self.tools = tools; self.model = model; self.path = path; self.`where` = `where` }
}

public struct CwdParams: Codable, Sendable, Hashable {
    public var cwd: String
    public init(cwd: String) { self.cwd = cwd }
}

public struct DefinitionError: Codable, Sendable, Hashable {
    public var path: String
    public var message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}

public struct DiffParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var path: String
    public var since: ChangesSince
    public init(ref: ContainerRef, path: String, since: ChangesSince) { self.ref = ref; self.path = path; self.since = since }
}

public struct DiffResult: Codable, Sendable, Hashable {
    public var patch: String
    public init(patch: String) { self.patch = patch }
}

public struct DirEntry: Codable, Sendable, Hashable {
    public var name: String
    public var path: String
    public var kind: PathKind
    public init(name: String, path: String, kind: PathKind) { self.name = name; self.path = path; self.kind = kind }
}

public struct EditParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var itemId: String
    public var text: String
    public var clientRequestId: String?
    public init(ref: ContainerRef, itemId: String, text: String, clientRequestId: String? = nil) { self.ref = ref; self.itemId = itemId; self.text = text; self.clientRequestId = clientRequestId }
}

public struct Empty: Codable, Sendable, Hashable {
    public init() {}
}

public struct EndpointCheckParams: Codable, Sendable, Hashable, Identifiable {
    public var baseUrl: String
    public var key: String?
    public var id: String?
    public var format: EndpointFormat?
    public var headers: [String: String]?
    public init(baseUrl: String, key: String? = nil, id: String? = nil, format: EndpointFormat? = nil, headers: [String: String]? = nil) { self.baseUrl = baseUrl; self.key = key; self.id = id; self.format = format; self.headers = headers }
}

public struct EndpointCheckResult: Codable, Sendable, Hashable {
    public struct Model: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var contextWindow: Double?
        public var embedding: Bool?
        public init(id: String, contextWindow: Double? = nil, embedding: Bool? = nil) { self.id = id; self.contextWindow = contextWindow; self.embedding = embedding }
    }
    public enum Error: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case refused, auth, notFound = "not_found", empty, tls, invalid, other
        public var description: String { rawValue }
    }
    public var ok: Bool
    public var baseUrl: String?
    public var models: [Model]
    public var message: String?
    public var error: Error?
    public var latencyMs: Double?
    public init(ok: Bool, baseUrl: String? = nil, models: [Model], message: String? = nil, error: Error? = nil, latencyMs: Double? = nil) { self.ok = ok; self.baseUrl = baseUrl; self.models = models; self.message = message; self.error = error; self.latencyMs = latencyMs }
}

public enum EndpointFormat: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case openai, anthropic
    public var description: String { rawValue }
}

public struct EndpointIdParams: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct EndpointSaveParams: Codable, Sendable, Hashable, Identifiable {
    public var id: String?
    public var name: String
    public var baseUrl: String
    public var key: String?
    public var format: EndpointFormat?
    public var headers: [String: String]?
    public var contextWindow: Double?
    public var hidden: [String]?
    public var force: Bool?
    public init(id: String? = nil, name: String, baseUrl: String, key: String? = nil, format: EndpointFormat? = nil, headers: [String: String]? = nil, contextWindow: Double? = nil, hidden: [String]? = nil, force: Bool? = nil) { self.id = id; self.name = name; self.baseUrl = baseUrl; self.key = key; self.format = format; self.headers = headers; self.contextWindow = contextWindow; self.hidden = hidden; self.force = force }
}

public struct EndpointSaveResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct EndpointsDetectResult: Codable, Sendable, Hashable {
    public struct Found: Codable, Sendable, Hashable {
        public var name: String
        public var baseUrl: String
        public var models: Int
        public var preset: String
        public init(name: String, baseUrl: String, models: Int, preset: String) { self.name = name; self.baseUrl = baseUrl; self.models = models; self.preset = preset }
    }
    public var found: [Found]
    public init(found: [Found]) { self.found = found }
}

public struct EngineCapabilities: Codable, Sendable, Hashable {
    public var runtimes: [ContainerKind]
    public var models: [String]
    public init(runtimes: [ContainerKind], models: [String]) { self.runtimes = runtimes; self.models = models }
}

public struct EngineSettings: Codable, Sendable, Hashable {
    public struct Models: Codable, Sendable, Hashable {
        public var utility: UtilityChoice?
        public init(utility: UtilityChoice? = nil) { self.utility = utility }
    }
    public struct Chat: Codable, Sendable, Hashable {
        public var mcp: Bool
        public var mcpServers: [String]?
        public var followUps: Bool?
        public var sideOnUnrelated: SideOnUnrelated?
        public var sidePropose: Bool?
        public var sideWake: Bool?
        public init(mcp: Bool, mcpServers: [String]? = nil, followUps: Bool? = nil, sideOnUnrelated: SideOnUnrelated? = nil, sidePropose: Bool? = nil, sideWake: Bool? = nil) { self.mcp = mcp; self.mcpServers = mcpServers; self.followUps = followUps; self.sideOnUnrelated = sideOnUnrelated; self.sidePropose = sidePropose; self.sideWake = sideWake }
    }
    public struct Build: Codable, Sendable, Hashable {
        public var sandbox: Bool?
        public var autoReview: Bool?
        public init(sandbox: Bool? = nil, autoReview: Bool? = nil) { self.sandbox = sandbox; self.autoReview = autoReview }
    }
    public struct AboutMe: Codable, Sendable, Hashable {
        public var enabled: Bool
        public var capture: Bool
        public var inThreads: Bool
        public var inAgents: Bool?
        public var provider: String
        public init(enabled: Bool, capture: Bool, inThreads: Bool, inAgents: Bool? = nil, provider: String) { self.enabled = enabled; self.capture = capture; self.inThreads = inThreads; self.inAgents = inAgents; self.provider = provider }
    }
    public struct Memory: Codable, Sendable, Hashable {
        public struct Embeddings: Codable, Sendable, Hashable {
            public var baseUrl: String
            public var model: String
            public var dims: Double
            public var provider: String?
            public init(baseUrl: String, model: String, dims: Double, provider: String? = nil) { self.baseUrl = baseUrl; self.model = model; self.dims = dims; self.provider = provider }
        }
        public var providers: [McpMemoryProvider]
        public var semantic: Bool?
        public var localOnly: Bool?
        public var pastChats: Bool?
        public var embeddings: Embeddings?
        public init(providers: [McpMemoryProvider], semantic: Bool? = nil, localOnly: Bool? = nil, pastChats: Bool? = nil, embeddings: Embeddings? = nil) { self.providers = providers; self.semantic = semantic; self.localOnly = localOnly; self.pastChats = pastChats; self.embeddings = embeddings }
    }
    public var models: Models?
    public var chat: Chat
    public var build: Build?
    public var aboutMe: AboutMe
    public var memory: Memory
    public init(models: Models? = nil, chat: Chat, build: Build? = nil, aboutMe: AboutMe, memory: Memory) { self.models = models; self.chat = chat; self.build = build; self.aboutMe = aboutMe; self.memory = memory }
}

public struct EngineStatusResult: Codable, Sendable, Hashable {
    public var uptimeMs: Double
    public var openSessions: Int
    public var subscriptions: Int
    public var runtime: String
    public var memoryMB: Double
    public var dataPath: String
    public init(uptimeMs: Double, openSessions: Int, subscriptions: Int, runtime: String, memoryMB: Double, dataPath: String) { self.uptimeMs = uptimeMs; self.openSessions = openSessions; self.subscriptions = subscriptions; self.runtime = runtime; self.memoryMB = memoryMB; self.dataPath = dataPath }
}

public enum ErrorKind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case auth, credits, model, rateLimit = "rate_limit", provider, network, context, other
    public var description: String { rawValue }
}

public struct ExportParams: Codable, Sendable, Hashable {
    public enum Format: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case markdown, html, jsonl
        public var description: String { rawValue }
    }
    public var ref: ContainerRef
    public var format: Format
    public init(ref: ContainerRef, format: Format) { self.ref = ref; self.format = format }
}

public struct ExportResult: Codable, Sendable, Hashable {
    public struct Visual: Codable, Sendable, Hashable {
        public var callId: String
        public var title: String
        public var html: String
        public init(callId: String, title: String, html: String) { self.callId = callId; self.title = title; self.html = html }
    }
    public var filename: String
    public var mimeType: String
    public var content: String
    public var visuals: [Visual]?
    public init(filename: String, mimeType: String, content: String, visuals: [Visual]? = nil) { self.filename = filename; self.mimeType = mimeType; self.content = content; self.visuals = visuals }
}

public struct ExtraCostParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef?
    public init(ref: ContainerRef? = nil) { self.ref = ref }
}

public struct ExtraCostSummary: Codable, Sendable, Hashable {
    public struct Breakdown: Codable, Sendable, Hashable {
        public var kind: String
        public var calls: Int
        public var knownUsd: Double
        public var unknownCalls: Int
        public init(kind: String, calls: Int, knownUsd: Double, unknownCalls: Int) { self.kind = kind; self.calls = calls; self.knownUsd = knownUsd; self.unknownCalls = unknownCalls }
    }
    public var scope: String
    public var knownUsd: Double
    public var unknownCalls: Int
    public var calls: Int
    public var breakdown: [Breakdown]
    public init(scope: String, knownUsd: Double, unknownCalls: Int, calls: Int, breakdown: [Breakdown]) { self.scope = scope; self.knownUsd = knownUsd; self.unknownCalls = unknownCalls; self.calls = calls; self.breakdown = breakdown }
}

public struct FileChange: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case added, modified, deleted
        public var description: String { rawValue }
    }
    public var path: String
    public var status: Status
    public var added: Int
    public var removed: Int
    public var binary: Bool?
    public init(path: String, status: Status, added: Int, removed: Int, binary: Bool? = nil) { self.path = path; self.status = status; self.added = added; self.removed = removed; self.binary = binary }
}

public struct FileMatch: Codable, Sendable, Hashable {
    public var path: String
    public var kind: PathKind
    public init(path: String, kind: PathKind) { self.path = path; self.kind = kind }
}

public struct FilesParams: Codable, Sendable, Hashable {
    public var cwd: String
    public var query: String
    public var limit: Int?
    public init(cwd: String, query: String, limit: Int? = nil) { self.cwd = cwd; self.query = query; self.limit = limit }
}

public struct FilesResult: Codable, Sendable, Hashable {
    public var files: [FileMatch]
    public init(files: [FileMatch]) { self.files = files }
}

public struct FinishParams: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case merge, discard
        public var description: String { rawValue }
    }
    public var ref: ContainerRef
    public var action: Action
    public init(ref: ContainerRef, action: Action) { self.ref = ref; self.action = action }
}

public struct FitCheck: Codable, Sendable, Hashable {
    public var git: Bool
    /// The test command found in the folder
    public var checks: String?
    public var agentsMd: Bool
    public var language: String?
    public init(git: Bool, checks: String? = nil, agentsMd: Bool, language: String? = nil) { self.git = git; self.checks = checks; self.agentsMd = agentsMd; self.language = language }
}

public struct FitCheckParams: Codable, Sendable, Hashable {
    public var cwd: String
    public init(cwd: String) { self.cwd = cwd }
}

public struct GitBranch: Codable, Sendable, Hashable {
    public var name: String
    public var upstream: String?
    public var lastCommitAt: String?
    public var current: Bool
    public init(name: String, upstream: String? = nil, lastCommitAt: String? = nil, current: Bool) { self.name = name; self.upstream = upstream; self.lastCommitAt = lastCommitAt; self.current = current }
}

public struct GitBranchesResult: Codable, Sendable, Hashable {
    public var branches: [GitBranch]
    public init(branches: [GitBranch]) { self.branches = branches }
}

public struct GitCheckoutParams: Codable, Sendable, Hashable {
    public var cwd: String
    public var branch: String
    public var create: Bool?
    public var base: String?
    public init(cwd: String, branch: String, create: Bool? = nil, base: String? = nil) { self.cwd = cwd; self.branch = branch; self.create = create; self.base = base }
}

public struct GitCommit: Codable, Sendable, Hashable {
    public var hash: String
    public var subject: String
    public var at: String
    public var files: [GitCommitFile]?
    public init(hash: String, subject: String, at: String, files: [GitCommitFile]? = nil) { self.hash = hash; self.subject = subject; self.at = at; self.files = files }
}

public struct GitCommitFile: Codable, Sendable, Hashable {
    public var path: String
    public var added: Int
    public var removed: Int
    public init(path: String, added: Int, removed: Int) { self.path = path; self.added = added; self.removed = removed }
}

public struct GitCommitParams: Codable, Sendable, Hashable {
    public var cwd: String
    public var message: String
    public var paths: [String]?
    public var amend: Bool?
    public init(cwd: String, message: String, paths: [String]? = nil, amend: Bool? = nil) { self.cwd = cwd; self.message = message; self.paths = paths; self.amend = amend }
}

public struct GitCommitResult: Codable, Sendable, Hashable {
    public var commit: String
    public init(commit: String) { self.commit = commit }
}

public struct GitFile: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case added, modified, deleted, renamed, conflicted, untracked
        public var description: String { rawValue }
    }
    public var path: String
    public var status: Status
    public var staged: Bool
    public var from: String?
    public var added: Int?
    public var removed: Int?
    public init(path: String, status: Status, staged: Bool, from: String? = nil, added: Int? = nil, removed: Int? = nil) { self.path = path; self.status = status; self.staged = staged; self.from = from; self.added = added; self.removed = removed }
}

public struct GitHubCloneParams: Codable, Sendable, Hashable {
    public var repo: String
    public var path: String?
    public init(repo: String, path: String? = nil) { self.repo = repo; self.path = path }
}

public struct GitHubCloneResult: Codable, Sendable, Hashable {
    public var project: ProjectInfo
    public init(project: ProjectInfo) { self.project = project }
}

public struct GitHubLogin: Codable, Sendable, Hashable {
    public var login: String
    public init(login: String) { self.login = login }
}

public struct GitHubRepo: Codable, Sendable, Hashable {
    public var fullName: String
    public var description: String?
    public var `private`: Bool
    public var cloneUrl: String
    public var updatedAt: String
    public var defaultBranch: String
    public init(fullName: String, description: String? = nil, private: Bool, cloneUrl: String, updatedAt: String, defaultBranch: String) { self.fullName = fullName; self.description = description; self.`private` = `private`; self.cloneUrl = cloneUrl; self.updatedAt = updatedAt; self.defaultBranch = defaultBranch }
}

public struct GitHubReposResult: Codable, Sendable, Hashable {
    public var repos: [GitHubRepo]
    public init(repos: [GitHubRepo]) { self.repos = repos }
}

public struct GitHubStatus: Codable, Sendable, Hashable {
    public enum Via: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case gh, token
        public var description: String { rawValue }
    }
    public var connected: Bool
    public var via: Via?
    public var login: String?
    public var error: String?
    public init(connected: Bool, via: Via? = nil, login: String? = nil, error: String? = nil) { self.connected = connected; self.via = via; self.login = login; self.error = error }
}

public struct GitHubTokenParams: Codable, Sendable, Hashable {
    public var token: String
    public init(token: String) { self.token = token }
}

public struct GitLogParams: Codable, Sendable, Hashable {
    public var cwd: String
    public var since: String?
    public var limit: Int?
    public init(cwd: String, since: String? = nil, limit: Int? = nil) { self.cwd = cwd; self.since = since; self.limit = limit }
}

public struct GitLogResult: Codable, Sendable, Hashable {
    public var commits: [GitCommit]
    public init(commits: [GitCommit]) { self.commits = commits }
}

public struct GitMessageParams: Codable, Sendable, Hashable {
    public var cwd: String
    public var paths: [String]?
    public init(cwd: String, paths: [String]? = nil) { self.cwd = cwd; self.paths = paths }
}

public struct GitMessageResult: Codable, Sendable, Hashable {
    public var message: String
    public init(message: String) { self.message = message }
}

public struct GitStatus: Codable, Sendable, Hashable {
    public var repo: Bool
    public var branch: String?
    public var detached: Bool?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var files: [GitFile]
    public init(repo: Bool, branch: String? = nil, detached: Bool? = nil, upstream: String? = nil, ahead: Int, behind: Int, files: [GitFile]) { self.repo = repo; self.branch = branch; self.detached = detached; self.upstream = upstream; self.ahead = ahead; self.behind = behind; self.files = files }
}

public struct GitSyncParams: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case push, pull, fetch
        public var description: String { rawValue }
    }
    public var cwd: String
    public var action: Action
    public init(cwd: String, action: Action) { self.cwd = cwd; self.action = action }
}

public struct GitSyncResult: Codable, Sendable, Hashable {
    public var output: String
    public init(output: String) { self.output = output }
}

public struct HelloParams: Codable, Sendable, Hashable {
    public var token: String
    public var client: String
    public var protocolVersion: String
    public var services: [String]?
    public init(token: String, client: String, protocolVersion: String, services: [String]? = nil) { self.token = token; self.client = client; self.protocolVersion = protocolVersion; self.services = services }
}

public struct HelloResult: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case local, cloud
        public var description: String { rawValue }
    }
    public var engineId: String
    public var kind: Kind
    public var version: String
    public var protocolVersion: String
    public var capabilities: EngineCapabilities
    public init(engineId: String, kind: Kind, version: String, protocolVersion: String, capabilities: EngineCapabilities) { self.engineId = engineId; self.kind = kind; self.version = version; self.protocolVersion = protocolVersion; self.capabilities = capabilities }
}

public struct HomeAgenda: Codable, Sendable, Hashable {
    public struct Today: Codable, Sendable, Hashable {
        public enum State: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case done, failed, skipped, running, upcoming, event
            public var description: String { rawValue }
        }
        public var at: String?
        public var label: String
        public var source: HomeAgenda.Source
        /// The automation it belongs to (docs/spec/27)
        public var automation: String?
        public var state: State
        /// Upcoming after midnight, within the next 24 hours
        public var tomorrow: Bool?
        public init(at: String? = nil, label: String, source: HomeAgenda.Source, automation: String? = nil, state: State, tomorrow: Bool? = nil) { self.at = at; self.label = label; self.source = source; self.automation = automation; self.state = state; self.tomorrow = tomorrow }
    }
    public struct Source: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case agent, project, piopio
            public var description: String { rawValue }
        }
        public var kind: Kind
        public var id: String
        public var name: String
        public init(kind: Kind, id: String, name: String) { self.kind = kind; self.id = id; self.name = name }
    }
    public struct Away: Codable, Sendable, Hashable {
        public var at: String
        public var source: HomeAgenda.Source
        /// The automation it belongs to (docs/spec/27)
        public var automation: String?
        public var text: String
        public var costUsd: Double?
        public var quiet: Bool
        public var failed: Bool?
        public init(at: String, source: HomeAgenda.Source, automation: String? = nil, text: String, costUsd: Double? = nil, quiet: Bool, failed: Bool? = nil) { self.at = at; self.source = source; self.automation = automation; self.text = text; self.costUsd = costUsd; self.quiet = quiet; self.failed = failed }
    }
    public var today: [Today]
    public var away: [Away]
    /// Messages held by quiet hours or limits, across agents
    public var held: Int
    public init(today: [Today], away: [Away], held: Int) { self.today = today; self.away = away; self.held = held }
}

public struct HomeAgendaParams: Codable, Sendable, Hashable {
    public var since: String?
    public init(since: String? = nil) { self.since = since }
}

public struct HookImportParams: Codable, Sendable, Hashable {
    public var project: String
    public init(project: String) { self.project = project }
}

public struct HookImportResult: Codable, Sendable, Hashable {
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}

public struct HookInfo: Codable, Sendable, Hashable {
    public enum Where: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case yours, project
        public var description: String { rawValue }
    }
    public var path: String
    public var name: String
    public var on: Bool
    public var `where`: Where
    public var spec: HookSpec?
    public var sentence: String
    public init(path: String, name: String, on: Bool, where: Where, spec: HookSpec? = nil, sentence: String) { self.path = path; self.name = name; self.on = on; self.`where` = `where`; self.spec = spec; self.sentence = sentence }
}

public struct HookPathResult: Codable, Sendable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct HookSaveParams: Codable, Sendable, Hashable {
    public var path: String?
    public var project: String?
    public var spec: HookSpec
    public init(path: String? = nil, project: String? = nil, spec: HookSpec) { self.path = path; self.project = project; self.spec = spec }
}

public struct HookSpec: Codable, Sendable, Hashable {
    public enum When: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case before, after, end
        public var description: String { rawValue }
    }
    public enum Tool: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case edit, write, bash, any
        public var description: String { rawValue }
    }
    public var when: When
    public var tools: [Tool]?
    public var files: String?
    public var command: String?
    public var run: String?
    public var stop: String?
    public init(when: When, tools: [Tool]? = nil, files: String? = nil, command: String? = nil, run: String? = nil, stop: String? = nil) { self.when = when; self.tools = tools; self.files = files; self.command = command; self.run = run; self.stop = stop }
}

public struct HookToggleParams: Codable, Sendable, Hashable {
    public var path: String
    public var on: Bool
    public init(path: String, on: Bool) { self.path = path; self.on = on }
}

public struct HookTryParams: Codable, Sendable, Hashable {
    public var spec: HookSpec
    public var project: String?
    public init(spec: HookSpec, project: String? = nil) { self.spec = spec; self.project = project }
}

public struct HookTryResult: Codable, Sendable, Hashable {
    public var code: Int
    public var output: String
    public var ms: Double
    public var file: String?
    public init(code: Int, output: String, ms: Double, file: String? = nil) { self.code = code; self.output = output; self.ms = ms; self.file = file }
}

public struct HooksDeleteParams: Codable, Sendable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct HooksListParams: Codable, Sendable, Hashable {
    public var project: String?
    public init(project: String? = nil) { self.project = project }
}

public struct HooksResult: Codable, Sendable, Hashable {
    public struct Claude: Codable, Sendable, Hashable {
        public var spec: HookSpec
        public var sentence: String
        public init(spec: HookSpec, sentence: String) { self.spec = spec; self.sentence = sentence }
    }
    public var hooks: [HookInfo]
    public var claude: [Claude]
    public init(hooks: [HookInfo], claude: [Claude]) { self.hooks = hooks; self.claude = claude }
}

public struct IdParams: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct InboxChanged: Codable, Sendable, Hashable {
    public struct Approval: Codable, Sendable, Hashable {
        public var agent: ContainerRef
        public var agentName: String
        public var approvalId: String
        public var title: String
        public init(agent: ContainerRef, agentName: String, approvalId: String, title: String) { self.agent = agent; self.agentName = agentName; self.approvalId = approvalId; self.title = title }
    }
    public var count: Int
    public var approval: Approval?
    public init(count: Int, approval: Approval? = nil) { self.count = count; self.approval = approval }
}

public struct InboxItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case approval, message, runFailed = "run_failed", budget, paused
        public var description: String { rawValue }
    }
    public var id: String
    public var agent: ContainerRef
    public var agentName: String
    public var avatar: String?
    public var kind: Kind
    public var at: String
    public var title: String
    public var body: String
    public var needsYou: Bool
    public var read: Bool
    public var conversationId: String?
    public var approval: ApprovalItem?
    public init(id: String, agent: ContainerRef, agentName: String, avatar: String? = nil, kind: Kind, at: String, title: String, body: String, needsYou: Bool, read: Bool, conversationId: String? = nil, approval: ApprovalItem? = nil) { self.id = id; self.agent = agent; self.agentName = agentName; self.avatar = avatar; self.kind = kind; self.at = at; self.title = title; self.body = body; self.needsYou = needsYou; self.read = read; self.conversationId = conversationId; self.approval = approval }
}

public struct InboxListResult: Codable, Sendable, Hashable {
    public var count: Int
    public var items: [InboxItem]
    public init(count: Int, items: [InboxItem]) { self.count = count; self.items = items }
}

public struct InboxReadParams: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var agentId: String
        public var id: String
        public init(agentId: String, id: String) { self.agentId = agentId; self.id = id }
    }
    public var items: [Item]
    public init(items: [Item]) { self.items = items }
}

public struct ItemParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var itemId: String
    public init(ref: ContainerRef, itemId: String) { self.ref = ref; self.itemId = itemId }
}

public struct LearnAnswerParams: Codable, Sendable, Hashable {
    public enum Choice: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case later, dismiss, undo
        public var description: String { rawValue }
    }
    public var ref: ContainerRef
    public var callId: String
    public var choice: Choice
    public init(ref: ContainerRef, callId: String, choice: Choice) { self.ref = ref; self.callId = callId; self.choice = choice }
}

public struct LearnItem: Codable, Sendable, Hashable {
    public enum Destination: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case project, aboutMe = "about_me", skill
        public var description: String { rawValue }
    }
    public var to: Destination
    public var text: String
    public var why: String?
    public var section: String?
    public var name: String?
    public var body: String?
    public var addTo: String?
    public var projectOnly: Bool?
    public init(to: Destination, text: String, why: String? = nil, section: String? = nil, name: String? = nil, body: String? = nil, addTo: String? = nil, projectOnly: Bool? = nil) { self.to = to; self.text = text; self.why = why; self.section = section; self.name = name; self.body = body; self.addTo = addTo; self.projectOnly = projectOnly }
}

public struct LearnSaveParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var callId: String
    public var items: [LearnItem]?
    public init(ref: ContainerRef, callId: String, items: [LearnItem]? = nil) { self.ref = ref; self.callId = callId; self.items = items }
}

public struct LearnSaveResult: Codable, Sendable, Hashable {
    public var file: String?
    public var project: Int
    public var aboutMe: Int
    public var skills: [String]
    public init(file: String? = nil, project: Int, aboutMe: Int, skills: [String]) { self.file = file; self.project = project; self.aboutMe = aboutMe; self.skills = skills }
}

public struct LearnState: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case pending, later, saved, dismissed
        public var description: String { rawValue }
    }
    public var status: Status
    public var file: String?
    public var aboutMe: Int?
    public var skills: [String]?
    public init(status: Status, file: String? = nil, aboutMe: Int? = nil, skills: [String]? = nil) { self.status = status; self.file = file; self.aboutMe = aboutMe; self.skills = skills }
}

public struct LibraryEntry: Codable, Sendable, Hashable, Identifiable {
    public enum How: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case presented, written, visual, added
        public var description: String { rawValue }
    }
    public struct Origin: Codable, Sendable, Hashable {
        public var ref: ContainerRef
        public var title: String
        public var project: String?
        public init(ref: ContainerRef, title: String, project: String? = nil) { self.ref = ref; self.title = title; self.project = project }
    }
    public struct Visual: Codable, Sendable, Hashable {
        public var callId: String
        public var version: String?
        public init(callId: String, version: String? = nil) { self.callId = callId; self.version = version }
    }
    public var id: String
    public var kind: LibraryKind
    public var name: String
    public var path: String?
    public var note: String?
    public var at: String
    public var by: String
    public var how: How
    public var origin: Origin?
    public var visual: Visual?
    public var missing: Bool?
    public var size: Int?
    public var changedAt: String?
    public var pinned: Bool?
    public init(id: String, kind: LibraryKind, name: String, path: String? = nil, note: String? = nil, at: String, by: String, how: How, origin: Origin? = nil, visual: Visual? = nil, missing: Bool? = nil, size: Int? = nil, changedAt: String? = nil, pinned: Bool? = nil) { self.id = id; self.kind = kind; self.name = name; self.path = path; self.note = note; self.at = at; self.by = by; self.how = how; self.origin = origin; self.visual = visual; self.missing = missing; self.size = size; self.changedAt = changedAt; self.pinned = pinned }
}

public struct LibraryEntryResult: Codable, Sendable, Hashable {
    public var item: LibraryEntry
    public init(item: LibraryEntry) { self.item = item }
}

public struct LibraryIdParams: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct LibraryIdsParams: Codable, Sendable, Hashable {
    public var ids: [String]
    public init(ids: [String]) { self.ids = ids }
}

public enum LibraryKind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case app, document, page, visual, image, data, slides, file
    public var description: String { rawValue }
}

public struct LibraryList: Codable, Sendable, Hashable {
    public var items: [LibraryEntry]
    public var pins: [String]
    /// What you removed, to put back
    public var removed: [LibraryEntry]
    public init(items: [LibraryEntry], pins: [String], removed: [LibraryEntry]) { self.items = items; self.pins = pins; self.removed = removed }
}

public struct LibraryPathParams: Codable, Sendable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct LibraryPinParams: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var pinned: Bool
    public init(id: String, pinned: Bool) { self.id = id; self.pinned = pinned }
}

public struct LibraryRelocateParams: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var path: String
    public init(id: String, path: String) { self.id = id; self.path = path }
}

public struct LibrarySavedParams: Codable, Sendable, Hashable {
    public var callId: String
    public var path: String
    public init(callId: String, path: String) { self.callId = callId; self.path = path }
}

public struct LibrarySavedResult: Codable, Sendable, Hashable {
    public var item: LibraryEntry?
    public init(item: LibraryEntry? = nil) { self.item = item }
}

public struct LibraryVisual: Codable, Sendable, Hashable {
    public var title: String
    public var html: String
    public init(title: String, html: String) { self.title = title; self.html = html }
}

public struct ListDirParams: Codable, Sendable, Hashable {
    public var cwd: String
    public var dir: String
    public init(cwd: String, dir: String) { self.cwd = cwd; self.dir = dir }
}

public struct ListDirResult: Codable, Sendable, Hashable {
    public var entries: [DirEntry]
    public init(entries: [DirEntry]) { self.entries = entries }
}

public struct ListSessionsParams: Codable, Sendable, Hashable {
    public var kind: ContainerKind?
    public init(kind: ContainerKind? = nil) { self.kind = kind }
}

public struct ListSessionsResult: Codable, Sendable, Hashable {
    public var sessions: [SessionSummary]
    public init(sessions: [SessionSummary]) { self.sessions = sessions }
}

public struct LoginIdParams: Codable, Sendable, Hashable {
    public var loginId: String
    public init(loginId: String) { self.loginId = loginId }
}

public struct McpAddParams: Codable, Sendable, Hashable {
    public var scope: McpScope
    public var cwd: String?
    public var name: String
    public var command: String?
    public var args: [String]?
    public var url: String?
    public var env: [String: String]?
    public var description: String?
    public var enabled: Bool?
    public var chat: Bool?
    public init(scope: McpScope, cwd: String? = nil, name: String, command: String? = nil, args: [String]? = nil, url: String? = nil, env: [String: String]? = nil, description: String? = nil, enabled: Bool? = nil, chat: Bool? = nil) { self.scope = scope; self.cwd = cwd; self.name = name; self.command = command; self.args = args; self.url = url; self.env = env; self.description = description; self.enabled = enabled; self.chat = chat }
}

public struct McpDetectResult: Codable, Sendable, Hashable {
    public struct Found: Codable, Sendable, Hashable {
        public struct Server: Codable, Sendable, Hashable {
            public var name: String
            public var command: String?
            public var args: [String]?
            public var url: String?
            public var env: [String: String]?
            public init(name: String, command: String? = nil, args: [String]? = nil, url: String? = nil, env: [String: String]? = nil) { self.name = name; self.command = command; self.args = args; self.url = url; self.env = env }
        }
        public var app: String
        public var path: String
        public var servers: [Server]
        public init(app: String, path: String, servers: [Server]) { self.app = app; self.path = path; self.servers = servers }
    }
    public var found: [Found]
    public init(found: [Found]) { self.found = found }
}

public struct McpListParams: Codable, Sendable, Hashable {
    public var cwd: String?
    public init(cwd: String? = nil) { self.cwd = cwd }
}

public struct McpListResult: Codable, Sendable, Hashable {
    public var servers: [McpServerInfo]
    public var errors: [String]
    public init(servers: [McpServerInfo], errors: [String]) { self.servers = servers; self.errors = errors }
}

public struct McpMemoryMapping: Codable, Sendable, Hashable {
    public var tool: String
    public var args: [String: JSONValue]
    public init(tool: String, args: [String: JSONValue]) { self.tool = tool; self.args = args }
}

public struct McpMemoryProvider: Codable, Sendable, Hashable, Identifiable {
    public struct Tools: Codable, Sendable, Hashable {
        public var recall: McpMemoryMapping
        public var retain: McpMemoryMapping?
        public var list: McpMemoryMapping?
        public var forget: McpMemoryMapping?
        public var reflect: McpMemoryMapping?
        public init(recall: McpMemoryMapping, retain: McpMemoryMapping? = nil, list: McpMemoryMapping? = nil, forget: McpMemoryMapping? = nil, reflect: McpMemoryMapping? = nil) { self.recall = recall; self.retain = retain; self.list = list; self.forget = forget; self.reflect = reflect }
    }
    public var id: String
    public var name: String
    public var server: String?
    public var url: String?
    public var tools: Tools
    public init(id: String, name: String, server: String? = nil, url: String? = nil, tools: Tools) { self.id = id; self.name = name; self.server = server; self.url = url; self.tools = tools }
}

public struct McpNameParams: Codable, Sendable, Hashable {
    public var scope: McpScope
    public var cwd: String?
    public var name: String
    public init(scope: McpScope, cwd: String? = nil, name: String) { self.scope = scope; self.cwd = cwd; self.name = name }
}

public struct McpProbe: Codable, Sendable, Hashable {
    public struct Tool: Codable, Sendable, Hashable {
        public var name: String
        public var description: String?
        public init(name: String, description: String? = nil) { self.name = name; self.description = description }
    }
    public var ok: Bool
    public var ms: Double?
    public var tools: [Tool]
    public var error: String?
    public var log: String?
    public init(ok: Bool, ms: Double? = nil, tools: [Tool], error: String? = nil, log: String? = nil) { self.ok = ok; self.ms = ms; self.tools = tools; self.error = error; self.log = log }
}

public struct McpProbeParams: Codable, Sendable, Hashable {
    public var command: String?
    public var args: [String]?
    public var url: String?
    public var env: [String: String]?
    public init(command: String? = nil, args: [String]? = nil, url: String? = nil, env: [String: String]? = nil) { self.command = command; self.args = args; self.url = url; self.env = env }
}

public enum McpScope: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case global, project
    public var description: String { rawValue }
}

public struct McpServerInfo: Codable, Sendable, Hashable {
    public enum Transport: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case stdio, http
        public var description: String { rawValue }
    }
    public var name: String
    public var scope: McpScope
    public var transport: Transport
    public var command: String?
    public var args: [String]?
    public var url: String?
    public var enabled: Bool
    public var description: String?
    public var override: Bool?
    public var env: [String]?
    public var hiddenTools: [String]?
    public var chat: Bool?
    public init(name: String, scope: McpScope, transport: Transport, command: String? = nil, args: [String]? = nil, url: String? = nil, enabled: Bool, description: String? = nil, override: Bool? = nil, env: [String]? = nil, hiddenTools: [String]? = nil, chat: Bool? = nil) { self.name = name; self.scope = scope; self.transport = transport; self.command = command; self.args = args; self.url = url; self.enabled = enabled; self.description = description; self.override = override; self.env = env; self.hiddenTools = hiddenTools; self.chat = chat }
}

public struct McpSetChatParams: Codable, Sendable, Hashable {
    public var name: String
    public var chat: Bool
    public init(name: String, chat: Bool) { self.name = name; self.chat = chat }
}

public struct McpSetEnabledParams: Codable, Sendable, Hashable {
    public var scope: McpScope
    public var cwd: String?
    public var name: String
    public var enabled: Bool
    public init(scope: McpScope, cwd: String? = nil, name: String, enabled: Bool) { self.scope = scope; self.cwd = cwd; self.name = name; self.enabled = enabled }
}

public struct McpSetToolParams: Codable, Sendable, Hashable {
    public var scope: McpScope
    public var cwd: String?
    public var name: String
    public var tool: String
    public var enabled: Bool
    public init(scope: McpScope, cwd: String? = nil, name: String, tool: String, enabled: Bool) { self.scope = scope; self.cwd = cwd; self.name = name; self.tool = tool; self.enabled = enabled }
}

public struct McpStatusParams: Codable, Sendable, Hashable {
    public var scope: McpScope
    public var cwd: String?
    public var name: String
    public var refresh: Bool?
    public init(scope: McpScope, cwd: String? = nil, name: String, refresh: Bool? = nil) { self.scope = scope; self.cwd = cwd; self.name = name; self.refresh = refresh }
}

public struct MemoryAddParams: Codable, Sendable, Hashable {
    public var provider: String
    public var bank: String
    public var text: String
    public var replaces: String?
    public init(provider: String, bank: String, text: String, replaces: String? = nil) { self.provider = provider; self.bank = bank; self.text = text; self.replaces = replaces }
}

public struct MemoryBanksResult: Codable, Sendable, Hashable {
    public struct Bank: Codable, Sendable, Hashable {
        public struct Agent: Codable, Sendable, Hashable, Identifiable {
            public var id: String
            public var name: String
            public var avatar: String?
            public var learns: Bool
            public init(id: String, name: String, avatar: String? = nil, learns: Bool) { self.id = id; self.name = name; self.avatar = avatar; self.learns = learns }
        }
        public var bank: String
        public var label: String
        public var area: String
        public var agent: Agent?
        public var records: Int
        public var facts: Int
        public var messages: Int
        public var ended: Int
        public var updatedAt: String?
        public init(bank: String, label: String, area: String, agent: Agent? = nil, records: Int, facts: Int, messages: Int, ended: Int, updatedAt: String? = nil) { self.bank = bank; self.label = label; self.area = area; self.agent = agent; self.records = records; self.facts = facts; self.messages = messages; self.ended = ended; self.updatedAt = updatedAt }
    }
    public struct Agent: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var avatar: String?
        public var learns: Bool
        public var provider: String
        public init(id: String, name: String, avatar: String? = nil, learns: Bool, provider: String) { self.id = id; self.name = name; self.avatar = avatar; self.learns = learns; self.provider = provider }
    }
    public var banks: [Bank]
    public var agents: [Agent]
    public var bytes: Int
    public init(banks: [Bank], agents: [Agent], bytes: Int) { self.banks = banks; self.agents = agents; self.bytes = bytes }
}

public struct MemoryCountResult: Codable, Sendable, Hashable {
    public var records: Int
    public init(records: Int) { self.records = records }
}

public struct MemoryExportParams: Codable, Sendable, Hashable {
    public var folder: String
    public init(folder: String) { self.folder = folder }
}

public struct MemoryExportResult: Codable, Sendable, Hashable {
    public var files: [String]
    public var records: Int
    public init(files: [String], records: Int) { self.files = files; self.records = records }
}

public struct MemoryHistoryParams: Codable, Sendable, Hashable {
    public var provider: String
    public var bank: String
    public var limit: Double?
    public init(provider: String, bank: String, limit: Double? = nil) { self.provider = provider; self.bank = bank; self.limit = limit }
}

public struct MemoryHistoryResult: Codable, Sendable, Hashable {
    public struct Event: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var at: String
        public var action: String
        public var recordId: String
        public var text: String
        public var by: String
        public init(id: String, at: String, action: String, recordId: String, text: String, by: String) { self.id = id; self.at = at; self.action = action; self.recordId = recordId; self.text = text; self.by = by }
    }
    public var events: [Event]
    public init(events: [Event]) { self.events = events }
}

public struct MemoryIdParams: Codable, Sendable, Hashable, Identifiable {
    public var provider: String
    public var bank: String
    public var id: String
    public init(provider: String, bank: String, id: String) { self.provider = provider; self.bank = bank; self.id = id }
}

public struct MemoryLearningParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var learn: Bool
    public init(ref: ContainerRef, learn: Bool) { self.ref = ref; self.learn = learn }
}

public struct MemoryListParams: Codable, Sendable, Hashable {
    public var provider: String
    public var bank: String
    public var cursor: String?
    public var kinds: [String]?
    public var includeEnded: Bool?
    public var query: String?
    public init(provider: String, bank: String, cursor: String? = nil, kinds: [String]? = nil, includeEnded: Bool? = nil, query: String? = nil) { self.provider = provider; self.bank = bank; self.cursor = cursor; self.kinds = kinds; self.includeEnded = includeEnded; self.query = query }
}

public struct MemoryListResult: Codable, Sendable, Hashable {
    public var records: [MemoryRecordInfo]
    public var cursor: String?
    public var limited: Bool
    public init(records: [MemoryRecordInfo], cursor: String? = nil, limited: Bool) { self.records = records; self.cursor = cursor; self.limited = limited }
}

public struct MemoryRecallParams: Codable, Sendable, Hashable {
    public var provider: String
    public var bank: String
    public var query: String
    public init(provider: String, bank: String, query: String) { self.provider = provider; self.bank = bank; self.query = query }
}

public struct MemoryRecallResult: Codable, Sendable, Hashable {
    public struct Hit: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var text: String
        public var score: Double
        public var at: String?
        public init(id: String, text: String, score: Double, at: String? = nil) { self.id = id; self.text = text; self.score = score; self.at = at }
    }
    public var hits: [Hit]
    public init(hits: [Hit]) { self.hits = hits }
}

public struct MemoryRecordInfo: Codable, Sendable, Hashable, Identifiable {
    public struct Source: Codable, Sendable, Hashable {
        public var ref: String?
        public var itemId: String?
        public var title: String?
        public init(ref: String? = nil, itemId: String? = nil, title: String? = nil) { self.ref = ref; self.itemId = itemId; self.title = title }
    }
    public var id: String
    public var text: String
    public var kind: String
    public var createdBy: String
    public var at: String
    public var pinned: Bool?
    public var source: Source?
    public var replaces: String?
    public var replacedBy: String?
    public var endedAt: String?
    public init(id: String, text: String, kind: String, createdBy: String, at: String, pinned: Bool? = nil, source: Source? = nil, replaces: String? = nil, replacedBy: String? = nil, endedAt: String? = nil) { self.id = id; self.text = text; self.kind = kind; self.createdBy = createdBy; self.at = at; self.pinned = pinned; self.source = source; self.replaces = replaces; self.replacedBy = replacedBy; self.endedAt = endedAt }
}

public struct MemoryReindexResult: Codable, Sendable, Hashable {
    public var pending: Int
    public init(pending: Int) { self.pending = pending }
}

public struct MemoryResult: Codable, Sendable, Hashable {
    public var text: String
    public var revisions: [MemoryRevision]
    public var provider: String
    public var limited: Bool
    public init(text: String, revisions: [MemoryRevision], provider: String, limited: Bool) { self.text = text; self.revisions = revisions; self.provider = provider; self.limited = limited }
}

public struct MemoryRevision: Codable, Sendable, Hashable, Identifiable {
    public struct Author: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case organizer, topic, user
            public var description: String { rawValue }
        }
        public var kind: Kind
        public init(kind: Kind) { self.kind = kind }
    }
    public var id: String
    public var at: String
    public var by: Author
    public var summary: String
    public var added: [String]
    public var removed: [String]
    public init(id: String, at: String, by: Author, summary: String, added: [String], removed: [String]) { self.id = id; self.at = at; self.by = by; self.summary = summary; self.added = added; self.removed = removed }
}

public struct MemoryStatus: Codable, Sendable, Hashable {
    public var semantic: Bool
    public var reason: String?
    public var error: String?
    public var model: String?
    public var via: String?
    public var records: Int
    public var indexed: Int
    public init(semantic: Bool, reason: String? = nil, error: String? = nil, model: String? = nil, via: String? = nil, records: Int, indexed: Int) { self.semantic = semantic; self.reason = reason; self.error = error; self.model = model; self.via = via; self.records = records; self.indexed = indexed }
}

public struct MemoryToolsParams: Codable, Sendable, Hashable {
    public var server: String?
    public var url: String?
    public init(server: String? = nil, url: String? = nil) { self.server = server; self.url = url }
}

public struct MemoryToolsResult: Codable, Sendable, Hashable {
    public struct Tool: Codable, Sendable, Hashable {
        public var name: String
        public var description: String?
        public init(name: String, description: String? = nil) { self.name = name; self.description = description }
    }
    public var tools: [Tool]
    public init(tools: [Tool]) { self.tools = tools }
}

public struct MemoryUpdateParams: Codable, Sendable, Hashable, Identifiable {
    public var provider: String
    public var bank: String
    public var id: String
    public var text: String?
    public var pinned: Bool?
    public init(provider: String, bank: String, id: String, text: String? = nil, pinned: Bool? = nil) { self.provider = provider; self.bank = bank; self.id = id; self.text = text; self.pinned = pinned }
}

public struct MemoryWipeParams: Codable, Sendable, Hashable {
    public var bank: String
    public init(bank: String) { self.bank = bank }
}

public struct MigrationReport: Codable, Sendable, Hashable {
    /// Markdown
    public var report: String?
    public init(report: String? = nil) { self.report = report }
}

public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    public struct Pricing: Codable, Sendable, Hashable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite: Double
        public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) { self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite }
    }
    public struct Supports: Codable, Sendable, Hashable {
        public var vision: Bool
        public var reasoning: Bool
        public init(vision: Bool, reasoning: Bool) { self.vision = vision; self.reasoning = reasoning }
    }
    public var provider: String
    public var id: String
    public var name: String
    public var contextWindow: Double
    public var maxOutputTokens: Double
    public var pricing: Pricing
    public var supports: Supports
    public var providerName: String?
    public var billing: String?
    public var agent: Bool?
    public init(provider: String, id: String, name: String, contextWindow: Double, maxOutputTokens: Double, pricing: Pricing, supports: Supports, providerName: String? = nil, billing: String? = nil, agent: Bool? = nil) { self.provider = provider; self.id = id; self.name = name; self.contextWindow = contextWindow; self.maxOutputTokens = maxOutputTokens; self.pricing = pricing; self.supports = supports; self.providerName = providerName; self.billing = billing; self.agent = agent }
}

public struct ModelRef: Codable, Sendable, Hashable, Identifiable {
    public var provider: String
    public var id: String
    public init(provider: String, id: String) { self.provider = provider; self.id = id }
}

public struct ModelsListParams: Codable, Sendable, Hashable {
    public var refresh: Bool?
    public init(refresh: Bool? = nil) { self.refresh = refresh }
}

public struct ModelsListResult: Codable, Sendable, Hashable {
    public var models: [ModelInfo]
    public var defaultModel: ModelRef
    public init(models: [ModelInfo], defaultModel: ModelRef) { self.models = models; self.defaultModel = defaultModel }
}

public struct NavigateParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var entryId: String
    public init(ref: ContainerRef, entryId: String) { self.ref = ref; self.entryId = entryId }
}

public struct NavigateResult: Codable, Sendable, Hashable {
    public var editorText: String?
    public init(editorText: String? = nil) { self.editorText = editorText }
}

public struct OnDeviceStatus: Codable, Sendable, Hashable {
    public var available: Bool
    public var reason: String?
    public init(available: Bool, reason: String? = nil) { self.available = available; self.reason = reason }
}

public struct PackageEnableParams: Codable, Sendable, Hashable {
    public var source: String
    public var enabled: Bool
    public var kinds: [PackageResourceKind]?
    public init(source: String, enabled: Bool, kinds: [PackageResourceKind]? = nil) { self.source = source; self.enabled = enabled; self.kinds = kinds }
}

public enum PackageKind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case npm, git, local
    public var description: String { rawValue }
}

public struct PackageParams: Codable, Sendable, Hashable {
    public var source: String
    public init(source: String) { self.source = source }
}

public struct PackagePreview: Codable, Sendable, Hashable {
    public var ok: Bool
    public var kind: PackageKind
    public var name: String?
    public var version: String?
    public var description: String?
    public var author: String?
    public var extensions: [String]
    public var skills: [String]
    public var prompts: [String]
    public var themes: [String]
    public var contentsKnown: Bool
    public var error: String?
    public init(ok: Bool, kind: PackageKind, name: String? = nil, version: String? = nil, description: String? = nil, author: String? = nil, extensions: [String], skills: [String], prompts: [String], themes: [String], contentsKnown: Bool, error: String? = nil) { self.ok = ok; self.kind = kind; self.name = name; self.version = version; self.description = description; self.author = author; self.extensions = extensions; self.skills = skills; self.prompts = prompts; self.themes = themes; self.contentsKnown = contentsKnown; self.error = error }
}

public enum PackageResourceKind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case extensions, skills, prompts, themes
    public var description: String { rawValue }
}

public struct PackageResourceParams: Codable, Sendable, Hashable {
    public var source: String
    public var kind: PackageResourceKind
    public var path: String
    public var enabled: Bool
    public init(source: String, kind: PackageResourceKind, path: String, enabled: Bool) { self.source = source; self.kind = kind; self.path = path; self.enabled = enabled }
}

public struct PackagesResult: Codable, Sendable, Hashable {
    public var packages: [PiPackage]
    public init(packages: [PiPackage]) { self.packages = packages }
}

public struct PackagesUpdateParams: Codable, Sendable, Hashable {
    public var source: String?
    public init(source: String? = nil) { self.source = source }
}

public struct PastConversation: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case thread, build
        public var description: String { rawValue }
    }
    public var id: String
    public var title: String
    public var kind: Kind
    public init(id: String, title: String, kind: Kind) { self.id = id; self.title = title; self.kind = kind }
}

public enum PathKind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case file, folder
    public var description: String { rawValue }
}

public struct PendingPrompt: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case approval, question, confirm, select, input, plan
        public var description: String { rawValue }
    }
    public struct SuggestedRule: Codable, Sendable, Hashable {
        public var kind: ApprovalRuleKind
        public var pattern: String
        public init(kind: ApprovalRuleKind, pattern: String) { self.kind = kind; self.pattern = pattern }
    }
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
    public var steps: [String]?
    public var at: String
    public init(id: String, kind: Kind, title: String, message: String? = nil, detail: String? = nil, tool: String? = nil, callId: String? = nil, reason: String? = nil, rule: SuggestedRule? = nil, options: [String]? = nil, placeholder: String? = nil, steps: [String]? = nil, at: String) { self.id = id; self.kind = kind; self.title = title; self.message = message; self.detail = detail; self.tool = tool; self.callId = callId; self.reason = reason; self.rule = rule; self.options = options; self.placeholder = placeholder; self.steps = steps; self.at = at }
}

public struct PiPackage: Codable, Sendable, Hashable {
    public struct Resources: Codable, Sendable, Hashable {
        public struct Resource: Codable, Sendable, Hashable {
            public var path: String
            public var enabled: Bool
            public init(path: String, enabled: Bool) { self.path = path; self.enabled = enabled }
        }
        public var extensions: [Resource]
        public var skills: [Resource]
        public var prompts: [Resource]
        public var themes: [Resource]
        public init(extensions: [Resource], skills: [Resource], prompts: [Resource], themes: [Resource]) { self.extensions = extensions; self.skills = skills; self.prompts = prompts; self.themes = themes }
    }
    public var source: String
    public var kind: PackageKind
    public var name: String?
    public var version: String?
    public var description: String?
    public var latest: String?
    public var installedPath: String?
    public var installed: Bool
    public var enabled: Bool
    public var off: [PackageResourceKind]
    public var resources: Resources
    public init(source: String, kind: PackageKind, name: String? = nil, version: String? = nil, description: String? = nil, latest: String? = nil, installedPath: String? = nil, installed: Bool, enabled: Bool, off: [PackageResourceKind], resources: Resources) { self.source = source; self.kind = kind; self.name = name; self.version = version; self.description = description; self.latest = latest; self.installedPath = installedPath; self.installed = installed; self.enabled = enabled; self.off = off; self.resources = resources }
}

public struct PiopioBudget: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case off, ok, near, over, allowed
        public var description: String { rawValue }
    }
    public struct Held: Codable, Sendable, Hashable {
        public var run: String
        public var automation: String
        public var name: String
        public var at: String
        public init(run: String, automation: String, name: String, at: String) { self.run = run; self.automation = automation; self.name = name; self.at = at }
    }
    public var month: String
    public var limitUsd: Double?
    public var spentUsd: Double
    public var resets: String
    public var state: State
    public var held: [Held]
    public init(month: String, limitUsd: Double? = nil, spentUsd: Double, resets: String, state: State, held: [Held]) { self.month = month; self.limitUsd = limitUsd; self.spentUsd = spentUsd; self.resets = resets; self.state = state; self.held = held }
}

public struct Playbook: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case builtin, project
        public var description: String { rawValue }
    }
    public var id: String
    public var name: String
    public var description: String
    public var source: Source
    public init(id: String, name: String, description: String, source: Source) { self.id = id; self.name = name; self.description = description; self.source = source }
}

public struct PlaybooksResult: Codable, Sendable, Hashable {
    public var playbooks: [Playbook]
    public init(playbooks: [Playbook]) { self.playbooks = playbooks }
}

public enum PrChecks: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case pending, passing, failing, none
    public var description: String { rawValue }
}

public struct PrDraft: Codable, Sendable, Hashable {
    public var title: String
    public var body: String
    public var head: String
    public var base: String
    public init(title: String, body: String, head: String, base: String) { self.title = title; self.body = body; self.head = head; self.base = base }
}

public enum PrEvents: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case off, tell, act
    public var description: String { rawValue }
}

public struct PrResult: Codable, Sendable, Hashable {
    public var pr: PrStatus
    public init(pr: PrStatus) { self.pr = pr }
}

public enum PrState: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case `open`, closed, merged
    public var description: String { rawValue }
}

public struct PrStatus: Codable, Sendable, Hashable {
    public struct Check: Codable, Sendable, Hashable {
        public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case queued, inProgress = "in_progress", completed
            public var description: String { rawValue }
        }
        public var name: String
        public var status: Status
        public var conclusion: String?
        public var url: String?
        public var jobId: Double?
        public init(name: String, status: Status, conclusion: String? = nil, url: String? = nil, jobId: Double? = nil) { self.name = name; self.status = status; self.conclusion = conclusion; self.url = url; self.jobId = jobId }
    }
    public struct Comment: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case review, comment, verdict
            public var description: String { rawValue }
        }
        public var id: String
        public var author: String
        public var bot: Bool
        public var body: String
        public var at: String
        public var url: String?
        public var path: String?
        public var line: Int?
        public var kind: Kind
        public init(id: String, author: String, bot: Bool, body: String, at: String, url: String? = nil, path: String? = nil, line: Int? = nil, kind: Kind) { self.id = id; self.author = author; self.bot = bot; self.body = body; self.at = at; self.url = url; self.path = path; self.line = line; self.kind = kind }
    }
    public var repo: String
    public var number: Int
    public var url: String
    public var title: String
    public var state: PrState
    public var draft: Bool
    public var head: String
    public var base: String
    public var headSha: String
    public var summary: PrChecks
    public var checks: [Check]
    public var comments: [Comment]
    public init(repo: String, number: Int, url: String, title: String, state: PrState, draft: Bool, head: String, base: String, headSha: String, summary: PrChecks, checks: [Check], comments: [Comment]) { self.repo = repo; self.number = number; self.url = url; self.title = title; self.state = state; self.draft = draft; self.head = head; self.base = base; self.headSha = headSha; self.summary = summary; self.checks = checks; self.comments = comments }
}

public struct PresentedFile: Codable, Sendable, Hashable {
    public var path: String
    public var name: String
    public var description: String?
    public var size: Int?
    public var missing: Bool?
    public init(path: String, name: String, description: String? = nil, size: Int? = nil, missing: Bool? = nil) { self.path = path; self.name = name; self.description = description; self.size = size; self.missing = missing }
}

public struct ProcessOutputParams: Codable, Sendable, Hashable, Identifiable {
    public var ref: ContainerRef
    public var id: String
    public var since: Double?
    public init(ref: ContainerRef, id: String, since: Double? = nil) { self.ref = ref; self.id = id; self.since = since }
}

public struct ProcessOutputResult: Codable, Sendable, Hashable {
    public var text: String
    public var next: Double
    public var process: BackgroundProcess
    public init(text: String, next: Double, process: BackgroundProcess) { self.text = text; self.next = next; self.process = process }
}

public struct ProcessStopParams: Codable, Sendable, Hashable, Identifiable {
    public var ref: ContainerRef
    public var id: String
    public init(ref: ContainerRef, id: String) { self.ref = ref; self.id = id }
}

public struct ProjectInfo: Codable, Sendable, Hashable, Identifiable {
    public struct Check: Codable, Sendable, Hashable {
        public enum Source: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case auto, set, off
            public var description: String { rawValue }
        }
        public var command: String?
        public var source: Source
        public init(command: String? = nil, source: Source) { self.command = command; self.source = source }
    }
    public enum Trust: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case trusted, untrusted, undecided
        public var description: String { rawValue }
    }
    public struct LinkedFolder: Codable, Sendable, Hashable {
        public var path: String
        public var edit: Bool
        public var missing: Bool?
        public init(path: String, edit: Bool, missing: Bool? = nil) { self.path = path; self.edit = edit; self.missing = missing }
    }
    public var id: String
    public var path: String
    public var name: String
    public var addedAt: String
    public var branch: String?
    public var contextFile: String?
    public var piConfig: Bool
    public var approvalMode: ApprovalMode
    public var prEvents: PrEvents?
    public var rules: [ApprovalRule]
    public var check: Check?
    public var trust: Trust
    public var needsTrust: Bool
    public var network: ProjectNetwork?
    public var lenses: [ProjectLens]
    public var missing: Bool?
    public var folders: [LinkedFolder]?
    public init(id: String, path: String, name: String, addedAt: String, branch: String? = nil, contextFile: String? = nil, piConfig: Bool, approvalMode: ApprovalMode, prEvents: PrEvents? = nil, rules: [ApprovalRule], check: Check? = nil, trust: Trust, needsTrust: Bool, network: ProjectNetwork? = nil, lenses: [ProjectLens], missing: Bool? = nil, folders: [LinkedFolder]? = nil) { self.id = id; self.path = path; self.name = name; self.addedAt = addedAt; self.branch = branch; self.contextFile = contextFile; self.piConfig = piConfig; self.approvalMode = approvalMode; self.prEvents = prEvents; self.rules = rules; self.check = check; self.trust = trust; self.needsTrust = needsTrust; self.network = network; self.lenses = lenses; self.missing = missing; self.folders = folders }
}

public enum ProjectLens: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case build, chat
    public var description: String { rawValue }
}

public enum ProjectNetwork: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case `open`, filtered, off
    public var description: String { rawValue }
}

public struct ProjectParams: Codable, Sendable, Hashable {
    public var project: String
    public init(project: String) { self.project = project }
}

public struct ProjectsAddParams: Codable, Sendable, Hashable {
    public var path: String
    public var lens: ProjectLens?
    public init(path: String, lens: ProjectLens? = nil) { self.path = path; self.lens = lens }
}

public struct ProjectsAddResult: Codable, Sendable, Hashable {
    public var project: ProjectInfo
    public init(project: ProjectInfo) { self.project = project }
}

public struct ProjectsChanged: Codable, Sendable, Hashable {
    public var projects: [ProjectInfo]
    public init(projects: [ProjectInfo]) { self.projects = projects }
}

public struct ProjectsConfigureParams: Codable, Sendable, Hashable, Identifiable {
    public struct LinkFolder: Codable, Sendable, Hashable {
        public var path: String
        public var edit: Bool
        public init(path: String, edit: Bool) { self.path = path; self.edit = edit }
    }
    public var id: String
    public var approvalMode: ApprovalMode?
    public var removeRule: String?
    public var trust: Nullable<Bool>?
    public var linkFolder: LinkFolder?
    public var unlinkFolder: String?
    public var prEvents: PrEvents?
    public var check: Nullable<String>?
    public var network: ProjectNetwork?
    public init(id: String, approvalMode: ApprovalMode? = nil, removeRule: String? = nil, trust: Nullable<Bool>? = nil, linkFolder: LinkFolder? = nil, unlinkFolder: String? = nil, prEvents: PrEvents? = nil, check: Nullable<String>? = nil, network: ProjectNetwork? = nil) { self.id = id; self.approvalMode = approvalMode; self.removeRule = removeRule; self.trust = trust; self.linkFolder = linkFolder; self.unlinkFolder = unlinkFolder; self.prEvents = prEvents; self.check = check; self.network = network }
}

public struct ProjectsCreateParams: Codable, Sendable, Hashable {
    public var name: String
    public var instructions: String?
    public init(name: String, instructions: String? = nil) { self.name = name; self.instructions = instructions }
}

public struct ProjectsListResult: Codable, Sendable, Hashable {
    public var projects: [ProjectInfo]
    public init(projects: [ProjectInfo]) { self.projects = projects }
}

public struct ProjectsRemoveParams: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct PromptResponse: Codable, Sendable, Hashable {
    public enum Decision: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case allow, always, deny
        public var description: String { rawValue }
    }
    public var decision: Decision?
    public var text: String?
    public var choice: String?
    public var confirmed: Bool?
    public var summary: String?
    public var steps: [String]?
    public init(decision: Decision? = nil, text: String? = nil, choice: String? = nil, confirmed: Bool? = nil, summary: String? = nil, steps: [String]? = nil) { self.decision = decision; self.text = text; self.choice = choice; self.confirmed = confirmed; self.summary = summary; self.steps = steps }
}

public struct ProviderAnswerParams: Codable, Sendable, Hashable {
    public var loginId: String
    public var promptId: String
    public var value: String?
    public init(loginId: String, promptId: String, value: String? = nil) { self.loginId = loginId; self.promptId = promptId; self.value = value }
}

public enum ProviderAuthEvent: Codable, Sendable, Hashable {
    public struct Link: Codable, Sendable, Hashable {
        public var url: String
        public var label: String?
        public init(url: String, label: String? = nil) { self.url = url; self.label = label }
    }
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case text, secret, select, manualCode = "manual_code"
        public var description: String { rawValue }
    }
    public struct Option: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        public var description: String?
        public init(id: String, label: String, description: String? = nil) { self.id = id; self.label = label; self.description = description }
    }
    case authUrl(url: String, instructions: String? = nil)
    case deviceCode(userCode: String, verificationUri: String, expiresInSeconds: Double? = nil)
    case progress(String)
    case info(message: String, links: [Link]? = nil)
    case prompt(promptId: String, kind: Kind, message: String, placeholder: String? = nil, options: [Option]? = nil)
    case promptClosed(String)
    case done
    case failed(String)
    private enum CodingKeys: String, CodingKey { case type, url, instructions, userCode, verificationUri, expiresInSeconds, message, links, promptId, kind, placeholder, options }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "auth_url": self = .authUrl(url: try c.decode(String.self, forKey: .url), instructions: try c.decodeIfPresent(String.self, forKey: .instructions))
        case "device_code": self = .deviceCode(userCode: try c.decode(String.self, forKey: .userCode), verificationUri: try c.decode(String.self, forKey: .verificationUri), expiresInSeconds: try c.decodeIfPresent(Double.self, forKey: .expiresInSeconds))
        case "progress": self = .progress(try c.decode(String.self, forKey: .message))
        case "info": self = .info(message: try c.decode(String.self, forKey: .message), links: try c.decodeIfPresent([Link].self, forKey: .links))
        case "prompt": self = .prompt(promptId: try c.decode(String.self, forKey: .promptId), kind: try c.decode(Kind.self, forKey: .kind), message: try c.decode(String.self, forKey: .message), placeholder: try c.decodeIfPresent(String.self, forKey: .placeholder), options: try c.decodeIfPresent([Option].self, forKey: .options))
        case "prompt_closed": self = .promptClosed(try c.decode(String.self, forKey: .promptId))
        case "done": self = .done
        case "failed": self = .failed(try c.decode(String.self, forKey: .message))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown type \(tag)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .authUrl(let url, let instructions): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("auth_url", forKey: .type); try c.encode(url, forKey: .url); try c.encodeIfPresent(instructions, forKey: .instructions)
        case .deviceCode(let userCode, let verificationUri, let expiresInSeconds): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("device_code", forKey: .type); try c.encode(userCode, forKey: .userCode); try c.encode(verificationUri, forKey: .verificationUri); try c.encodeIfPresent(expiresInSeconds, forKey: .expiresInSeconds)
        case .progress(let message): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("progress", forKey: .type); try c.encode(message, forKey: .message)
        case .info(let message, let links): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("info", forKey: .type); try c.encode(message, forKey: .message); try c.encodeIfPresent(links, forKey: .links)
        case .prompt(let promptId, let kind, let message, let placeholder, let options): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("prompt", forKey: .type); try c.encode(promptId, forKey: .promptId); try c.encode(kind, forKey: .kind); try c.encode(message, forKey: .message); try c.encodeIfPresent(placeholder, forKey: .placeholder); try c.encodeIfPresent(options, forKey: .options)
        case .promptClosed(let promptId): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("prompt_closed", forKey: .type); try c.encode(promptId, forKey: .promptId)
        case .done: var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("done", forKey: .type)
        case .failed(let message): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("failed", forKey: .type); try c.encode(message, forKey: .message)
        }
    }
}

public struct ProviderAuthNotification: Codable, Sendable, Hashable {
    public var loginId: String
    public var provider: String
    public var event: ProviderAuthEvent
    public init(loginId: String, provider: String, event: ProviderAuthEvent) { self.loginId = loginId; self.provider = provider; self.event = event }
}

public struct ProviderHiddenParams: Codable, Sendable, Hashable {
    public var provider: String
    public var hidden: [String]
    public init(provider: String, hidden: [String]) { self.provider = provider; self.hidden = hidden }
}

public struct ProviderInfo: Codable, Sendable, Hashable, Identifiable {
    public struct Method: Codable, Sendable, Hashable {
        public var type: AuthMethod
        public var label: String
        public var subscription: Bool?
        public init(type: AuthMethod, label: String, subscription: Bool? = nil) { self.type = type; self.label = label; self.subscription = subscription }
    }
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case notConnected = "not_connected", connecting, connected, needsAttention = "needs_attention"
        public var description: String { rawValue }
    }
    public struct Endpoint: Codable, Sendable, Hashable {
        public var baseUrl: String
        public var local: Bool
        public var keyless: Bool
        public var format: EndpointFormat?
        public var headers: [String: String]?
        public var contextWindow: Double?
        public init(baseUrl: String, local: Bool, keyless: Bool, format: EndpointFormat? = nil, headers: [String: String]? = nil, contextWindow: Double? = nil) { self.baseUrl = baseUrl; self.local = local; self.keyless = keyless; self.format = format; self.headers = headers; self.contextWindow = contextWindow }
    }
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case cloud, subscription, platform, custom, agent
        public var description: String { rawValue }
    }
    public struct Agent: Codable, Sendable, Hashable {
        public var path: String?
        public var version: String?
        public var signedIn: Bool
        public var install: String
        public var signIn: String
        public init(path: String? = nil, version: String? = nil, signedIn: Bool, install: String, signIn: String) { self.path = path; self.version = version; self.signedIn = signedIn; self.install = install; self.signIn = signIn }
    }
    public var id: String
    public var name: String
    public var methods: [Method]
    public var status: Status
    public var connectedWith: AuthMethod?
    public var billing: String?
    public var message: String?
    public var featured: Bool
    public var models: Int
    public var endpoint: Endpoint?
    public var kind: Kind?
    public var agent: Agent?
    public var popular: String?
    public var keyPage: String?
    public var families: [String]?
    public var keyHint: String?
    public var hiddenModels: Int?
    public var sampleModels: [String]?
    public init(id: String, name: String, methods: [Method], status: Status, connectedWith: AuthMethod? = nil, billing: String? = nil, message: String? = nil, featured: Bool, models: Int, endpoint: Endpoint? = nil, kind: Kind? = nil, agent: Agent? = nil, popular: String? = nil, keyPage: String? = nil, families: [String]? = nil, keyHint: String? = nil, hiddenModels: Int? = nil, sampleModels: [String]? = nil) { self.id = id; self.name = name; self.methods = methods; self.status = status; self.connectedWith = connectedWith; self.billing = billing; self.message = message; self.featured = featured; self.models = models; self.endpoint = endpoint; self.kind = kind; self.agent = agent; self.popular = popular; self.keyPage = keyPage; self.families = families; self.keyHint = keyHint; self.hiddenModels = hiddenModels; self.sampleModels = sampleModels }
}

public struct ProviderKeyParams: Codable, Sendable, Hashable {
    public var provider: String
    public var key: String
    public init(provider: String, key: String) { self.provider = provider; self.key = key }
}

public struct ProviderLoginParams: Codable, Sendable, Hashable {
    public var provider: String
    public var method: AuthMethod
    public init(provider: String, method: AuthMethod) { self.provider = provider; self.method = method }
}

public struct ProviderLoginResult: Codable, Sendable, Hashable {
    public var loginId: String
    public init(loginId: String) { self.loginId = loginId }
}

public struct ProviderModelsResult: Codable, Sendable, Hashable {
    public struct Model: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var contextWindow: Double
        public var hidden: Bool
        public var embedding: Bool?
        public init(id: String, name: String, contextWindow: Double, hidden: Bool, embedding: Bool? = nil) { self.id = id; self.name = name; self.contextWindow = contextWindow; self.hidden = hidden; self.embedding = embedding }
    }
    public var models: [Model]
    public init(models: [Model]) { self.models = models }
}

public struct ProviderParams: Codable, Sendable, Hashable {
    public var provider: String
    public init(provider: String) { self.provider = provider }
}

public struct ProviderVerifyResult: Codable, Sendable, Hashable {
    public var ok: Bool?
    public var message: String?
    public var models: Int?
    public init(ok: Bool?, message: String? = nil, models: Int? = nil) { self.ok = ok; self.message = message; self.models = models }
    private enum CodingKeys: String, CodingKey { case ok, message, models }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.ok, forKey: .ok)
        try c.encodeIfPresent(self.message, forKey: .message)
        try c.encodeIfPresent(self.models, forKey: .models)
    }
}

public struct ProvidersListResult: Codable, Sendable, Hashable {
    public var providers: [ProviderInfo]
    public init(providers: [ProviderInfo]) { self.providers = providers }
}

public struct QueueRemoveParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var queueId: String
    public init(ref: ContainerRef, queueId: String) { self.ref = ref; self.queueId = queueId }
}

public struct QueuedInput: Codable, Sendable, Hashable, Identifiable {
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case steer, followUp
        public var description: String { rawValue }
    }
    public var id: String
    public var mode: Mode
    public var text: String?
    public init(id: String, mode: Mode, text: String? = nil) { self.id = id; self.mode = mode; self.text = text }
}

public struct ReadFileParams: Codable, Sendable, Hashable {
    public var cwd: String
    public var path: String
    public init(cwd: String, path: String) { self.cwd = cwd; self.path = path }
}

public struct ReadFileResult: Codable, Sendable, Hashable {
    public var content: String
    public var size: Int
    public var truncated: Bool
    public var binary: Bool
    public init(content: String, size: Int, truncated: Bool, binary: Bool) { self.content = content; self.size = size; self.truncated = truncated; self.binary = binary }
}

public struct RefParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public init(ref: ContainerRef) { self.ref = ref }
}

public struct RenameParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var title: String
    public init(ref: ContainerRef, title: String) { self.ref = ref; self.title = title }
}

public struct RespondParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var promptId: String
    public var response: PromptResponse
    public init(ref: ContainerRef, promptId: String, response: PromptResponse) { self.ref = ref; self.promptId = promptId; self.response = response }
}

public struct RestoreParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var checkpointId: String
    public var paths: [String]?
    public var dryRun: Bool?
    public init(ref: ContainerRef, checkpointId: String, paths: [String]? = nil, dryRun: Bool? = nil) { self.ref = ref; self.checkpointId = checkpointId; self.paths = paths; self.dryRun = dryRun }
}

public struct RestoreResult: Codable, Sendable, Hashable {
    public var files: [FileChange]
    public init(files: [FileChange]) { self.files = files }
}

public struct ResultItem: Codable, Sendable, Hashable, Identifiable {
    public struct Card: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case reminder, message, memory, event, contact, note, music, shortcut, setup, automation, file
            public var description: String { rawValue }
        }
        public var kind: Kind
        public var title: String
        public var detail: String?
        public var automation: AutomationSummary?
        public init(kind: Kind, title: String, detail: String? = nil, automation: AutomationSummary? = nil) { self.kind = kind; self.title = title; self.detail = detail; self.automation = automation }
    }
    public struct Undo: Codable, Sendable, Hashable, Identifiable {
        public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case available, undone, failed, expired
            public var description: String { rawValue }
        }
        public var id: String
        public var status: Status
        public var until: String
        public init(id: String, status: Status, until: String) { self.id = id; self.status = status; self.until = until }
    }
    public var id: String
    public var at: String
    public var callId: String
    public var card: Card
    public var undo: Undo?
    public init(id: String, at: String, callId: String, card: Card, undo: Undo? = nil) { self.id = id; self.at = at; self.callId = callId; self.card = card; self.undo = undo }
    private enum CodingKeys: String, CodingKey { case id, at, callId, card, undo, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.at = try c.decode(String.self, forKey: .at)
        self.callId = try c.decode(String.self, forKey: .callId)
        self.card = try c.decode(Card.self, forKey: .card)
        self.undo = try c.decodeIfPresent(Undo.self, forKey: .undo)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("result", forKey: .kind)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.at, forKey: .at)
        try c.encode(self.callId, forKey: .callId)
        try c.encode(self.card, forKey: .card)
        try c.encodeIfPresent(self.undo, forKey: .undo)
    }
}

public struct ReviewFinding: Codable, Sendable, Hashable, Identifiable {
    public enum Severity: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case bug, risk, nit
        public var description: String { rawValue }
    }
    public enum State: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case `open`, fixing, fixed, dismissed
        public var description: String { rawValue }
    }
    public var id: String
    public var severity: Severity
    public var file: String
    public var line: Int?
    public var title: String
    public var detail: String
    public var suggestion: String?
    public var state: State
    public init(id: String, severity: Severity, file: String, line: Int? = nil, title: String, detail: String, suggestion: String? = nil, state: State) { self.id = id; self.severity = severity; self.file = file; self.line = line; self.title = title; self.detail = detail; self.suggestion = suggestion; self.state = state }
}

public struct ReviewFindingParams: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case `open`, fixing, dismissed
        public var description: String { rawValue }
    }
    public var ref: ContainerRef
    public var id: String
    public var state: State
    public init(ref: ContainerRef, id: String, state: State) { self.ref = ref; self.id = id; self.state = state }
}

public struct ReviewInfo: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case running, done, failed
        public var description: String { rawValue }
    }
    public var reviewer: ContainerRef
    public var target: String
    public var status: Status
    public var summary: String?
    public var findings: [ReviewFinding]
    public var at: String
    public init(reviewer: ContainerRef, target: String, status: Status, summary: String? = nil, findings: [ReviewFinding], at: String) { self.reviewer = reviewer; self.target = target; self.status = status; self.summary = summary; self.findings = findings; self.at = at }
}

public struct ReviewParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var pr: Int?
    public init(ref: ContainerRef, pr: Int? = nil) { self.ref = ref; self.pr = pr }
}

public struct RevisionIdParams: Codable, Sendable, Hashable {
    public var revisionId: String
    public init(revisionId: String) { self.revisionId = revisionId }
}

public struct RewindParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var itemId: String
    public var files: Bool
    public var dryRun: Bool?
    public init(ref: ContainerRef, itemId: String, files: Bool, dryRun: Bool? = nil) { self.ref = ref; self.itemId = itemId; self.files = files; self.dryRun = dryRun }
}

public struct RewindResult: Codable, Sendable, Hashable {
    public var files: [FileChange]
    public var turns: Int
    public var editorText: String?
    public init(files: [FileChange], turns: Int, editorText: String? = nil) { self.files = files; self.turns = turns; self.editorText = editorText }
}

public struct SearchParams: Codable, Sendable, Hashable {
    public var query: String
    public var limit: Int?
    public var kind: ContainerKind?
    public init(query: String, limit: Int? = nil, kind: ContainerKind? = nil) { self.query = query; self.limit = limit; self.kind = kind }
}

public struct SearchResult: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case title, user, assistant
        public var description: String { rawValue }
    }
    public var ref: ContainerRef
    public var title: String
    public var itemId: String?
    public var kind: Kind
    public var snippet: String
    public var at: String
    public init(ref: ContainerRef, title: String, itemId: String? = nil, kind: Kind, snippet: String, at: String) { self.ref = ref; self.title = title; self.itemId = itemId; self.kind = kind; self.snippet = snippet; self.at = at }
}

public struct SearchResults: Codable, Sendable, Hashable {
    public var results: [SearchResult]
    public init(results: [SearchResult]) { self.results = results }
}

public struct SecretChangedParams: Codable, Sendable, Hashable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct SecretsDeleteParams: Codable, Sendable, Hashable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct SecretsGetParams: Codable, Sendable, Hashable {
    public var name: String
    public var purpose: String
    public init(name: String, purpose: String) { self.name = name; self.purpose = purpose }
}

public struct SecretsGetResult: Codable, Sendable, Hashable {
    public var value: String?
    public init(value: String?) { self.value = value }
    private enum CodingKeys: String, CodingKey { case value }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.value, forKey: .value)
    }
}

public struct SecretsSetParams: Codable, Sendable, Hashable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

public struct SessionAttention: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case waiting, notify
        public var description: String { rawValue }
    }
    public var ref: ContainerRef
    public var title: String
    public var kind: Kind
    public var message: String
    public init(ref: ContainerRef, title: String, kind: Kind, message: String) { self.ref = ref; self.title = title; self.kind = kind; self.message = message }
}

public struct SessionCommand: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case template, skill, `extension`
        public var description: String { rawValue }
    }
    public var name: String
    public var description: String
    public var kind: Kind
    public var hint: String?
    public var source: String?
    public init(name: String, description: String, kind: Kind, hint: String? = nil, source: String? = nil) { self.name = name; self.description = description; self.kind = kind; self.hint = hint; self.source = source }
}

public struct SessionDecideParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var approvalId: String
    public var approve: Bool
    public var always: Bool?
    public var reason: String?
    public init(ref: ContainerRef, approvalId: String, approve: Bool, always: Bool? = nil, reason: String? = nil) { self.ref = ref; self.approvalId = approvalId; self.approve = approve; self.always = always; self.reason = reason }
}

public enum SessionEvent: Codable, Sendable, Hashable {
    public enum PartType: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case text, thinking
        public var description: String { rawValue }
    }
    case itemAdded(item: TimelineItem, before: String? = nil)
    case itemDelta(itemId: String, partIndex: Int, partType: PartType, textDelta: String)
    case itemUpdated(TimelineItem)
    case itemRemoved(String)
    case itemReplaced(oldId: String, item: TimelineItem)
    case state(SessionState)
    case resnapshot(Snapshot)
    /// A type this app doesn't know (a newer engine's).
    case unknown(String)
    private enum CodingKeys: String, CodingKey { case type, item, before, itemId, partIndex, partType, textDelta, oldId, state, snapshot }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "item.added": self = .itemAdded(item: try c.decode(TimelineItem.self, forKey: .item), before: try c.decodeIfPresent(String.self, forKey: .before))
        case "item.delta": self = .itemDelta(itemId: try c.decode(String.self, forKey: .itemId), partIndex: try c.decode(Int.self, forKey: .partIndex), partType: try c.decode(PartType.self, forKey: .partType), textDelta: try c.decode(String.self, forKey: .textDelta))
        case "item.updated": self = .itemUpdated(try c.decode(TimelineItem.self, forKey: .item))
        case "item.removed": self = .itemRemoved(try c.decode(String.self, forKey: .itemId))
        case "item.replaced": self = .itemReplaced(oldId: try c.decode(String.self, forKey: .oldId), item: try c.decode(TimelineItem.self, forKey: .item))
        case "state": self = .state(try c.decode(SessionState.self, forKey: .state))
        case "resnapshot": self = .resnapshot(try c.decode(Snapshot.self, forKey: .snapshot))
        default: self = .unknown(tag)
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .itemAdded(let item, let before): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("item.added", forKey: .type); try c.encode(item, forKey: .item); try c.encodeIfPresent(before, forKey: .before)
        case .itemDelta(let itemId, let partIndex, let partType, let textDelta): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("item.delta", forKey: .type); try c.encode(itemId, forKey: .itemId); try c.encode(partIndex, forKey: .partIndex); try c.encode(partType, forKey: .partType); try c.encode(textDelta, forKey: .textDelta)
        case .itemUpdated(let item): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("item.updated", forKey: .type); try c.encode(item, forKey: .item)
        case .itemRemoved(let itemId): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("item.removed", forKey: .type); try c.encode(itemId, forKey: .itemId)
        case .itemReplaced(let oldId, let item): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("item.replaced", forKey: .type); try c.encode(oldId, forKey: .oldId); try c.encode(item, forKey: .item)
        case .state(let state): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("state", forKey: .type); try c.encode(state, forKey: .state)
        case .resnapshot(let snapshot): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("resnapshot", forKey: .type); try c.encode(snapshot, forKey: .snapshot)
        case .unknown(let tag): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(tag, forKey: .type)
        }
    }
}

public struct SessionEventsNotification: Codable, Sendable, Hashable {
    public var subscriptionId: String
    public var seq: Int
    public var events: [SessionEvent]
    public init(subscriptionId: String, seq: Int, events: [SessionEvent]) { self.subscriptionId = subscriptionId; self.seq = seq; self.events = events }
}

public enum SessionProfile: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case build, chat
    public var description: String { rawValue }
}

public struct SessionState: Codable, Sendable, Hashable {
    public struct Tools: Codable, Sendable, Hashable {
        public var web: Bool
        public init(web: Bool) { self.web = web }
    }
    public struct Handoff: Codable, Sendable, Hashable {
        public var from: ModelRef
        public init(from: ModelRef) { self.from = from }
    }
    public struct Context: Codable, Sendable, Hashable {
        public struct Breakdown: Codable, Sendable, Hashable {
            public enum Source: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
                case request, session
                public var description: String { rawValue }
            }
            public struct Group: Codable, Sendable, Hashable {
                public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
                    case instructions, tools, conversation, toolUse, attachments, summaries
                    public var description: String { rawValue }
                }
                public struct Part: Codable, Sendable, Hashable {
                    public var label: String
                    public var tokens: Double
                    public init(label: String, tokens: Double) { self.label = label; self.tokens = tokens }
                }
                public var kind: Kind
                public var tokens: Double
                public var parts: [Part]
                public init(kind: Kind, tokens: Double, parts: [Part]) { self.kind = kind; self.tokens = tokens; self.parts = parts }
            }
            public var source: Source
            public var groups: [Group]
            public init(source: Source, groups: [Group]) { self.source = source; self.groups = groups }
        }
        public var tokens: Double?
        public var window: Double
        public var breakdown: Breakdown?
        public init(tokens: Double?, window: Double, breakdown: Breakdown? = nil) { self.tokens = tokens; self.window = window; self.breakdown = breakdown }
        private enum CodingKeys: String, CodingKey { case tokens, window, breakdown }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(self.tokens, forKey: .tokens)
            try c.encode(self.window, forKey: .window)
            try c.encodeIfPresent(self.breakdown, forKey: .breakdown)
        }
    }
    public var status: SessionStatus
    public var queue: [QueuedInput]
    public var model: ModelRef?
    public var thinking: String?
    public var tools: Tools?
    public var usage: Usage
    public var approvalMode: ApprovalMode?
    public var prompts: [PendingPrompt]?
    public var todos: [Todo]?
    public var planMode: Bool?
    public var handoff: Handoff?
    public var processes: [BackgroundProcess]?
    public var context: Context?
    public init(status: SessionStatus, queue: [QueuedInput], model: ModelRef? = nil, thinking: String? = nil, tools: Tools? = nil, usage: Usage, approvalMode: ApprovalMode? = nil, prompts: [PendingPrompt]? = nil, todos: [Todo]? = nil, planMode: Bool? = nil, handoff: Handoff? = nil, processes: [BackgroundProcess]? = nil, context: Context? = nil) { self.status = status; self.queue = queue; self.model = model; self.thinking = thinking; self.tools = tools; self.usage = usage; self.approvalMode = approvalMode; self.prompts = prompts; self.todos = todos; self.planMode = planMode; self.handoff = handoff; self.processes = processes; self.context = context }
}

public enum SessionStatus: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case idle, running, waitingApproval = "waiting_approval", error
    public var description: String { rawValue }
}

public struct SessionSummary: Codable, Sendable, Hashable {
    public struct Temporary: Codable, Sendable, Hashable {
        public var expiresAt: String
        public init(expiresAt: String) { self.expiresAt = expiresAt }
    }
    public struct Parent: Codable, Sendable, Hashable, Identifiable {
        public enum State: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case queued, working, done, failed, stopped
            public var description: String { rawValue }
        }
        public var id: String
        public var callId: String
        public var state: State?
        public var line: String?
        /// When its latest turn started (docs/spec/37)
        public var startedAt: String?
        /// When its latest turn ended
        public var endedAt: String?
        /// What the subagent has cost so far
        public var costUsd: Double?
        /// While queued: what it will be told when it starts
        public var brief: String?
        /// The Watchdog's note while it looks stuck or repeats itself
        public var alert: String?
        /// A custom subagent's name, when the task went to one (roadmap PAR12)
        public var agent: String?
        public init(id: String, callId: String, state: State? = nil, line: String? = nil, startedAt: String? = nil, endedAt: String? = nil, costUsd: Double? = nil, brief: String? = nil, alert: String? = nil, agent: String? = nil) { self.id = id; self.callId = callId; self.state = state; self.line = line; self.startedAt = startedAt; self.endedAt = endedAt; self.costUsd = costUsd; self.brief = brief; self.alert = alert; self.agent = agent }
    }
    public struct Helper: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case build, review
            public var description: String { rawValue }
        }
        public var project: String
        public var kind: Kind
        public var taskId: String
        public init(project: String, kind: Kind, taskId: String) { self.project = project; self.kind = kind; self.taskId = taskId }
    }
    public struct Side: Codable, Sendable, Hashable {
        public enum How: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case asked, manual, offered, proposed
            public var description: String { rawValue }
        }
        public enum State: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case queued, working, needsYou = "needs_you", done, failed, stopped
            public var description: String { rawValue }
        }
        public var parent: SessionSummary.Link
        public var how: How
        public var state: State
        public var line: String?
        /// The tool call that started it (side_start, an offer's or a proposal's), for its line in the parent's transcript
        public var from: String?
        public init(parent: SessionSummary.Link, how: How, state: State, line: String? = nil, from: String? = nil) { self.parent = parent; self.how = how; self.state = state; self.line = line; self.from = from }
    }
    public struct Link: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }
    public struct SideProposal: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var why: String
        public var project: String?
        public var expiresAt: String
        public init(id: String, title: String, why: String, project: String? = nil, expiresAt: String) { self.id = id; self.title = title; self.why = why; self.project = project; self.expiresAt = expiresAt }
    }
    public struct PR: Codable, Sendable, Hashable {
        public var repo: String
        public var number: Int
        public var url: String
        public var title: String
        public var head: String
        public var base: String
        public var state: PrState
        public var checks: PrChecks?
        public init(repo: String, number: Int, url: String, title: String, head: String, base: String, state: PrState, checks: PrChecks? = nil) { self.repo = repo; self.number = number; self.url = url; self.title = title; self.head = head; self.base = base; self.state = state; self.checks = checks }
    }
    public var temporary: Temporary?
    public var learned: [String: LearnState]?
    public var app: String?
    public var ref: ContainerRef
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    public var cwd: String?
    public var model: ModelRef?
    public var projectPath: String?
    public var review: ReviewInfo?
    public var worktree: WorktreeInfo?
    public var profile: SessionProfile?
    public var parent: Parent?
    public var helper: Helper?
    public var side: Side?
    public var sideProposals: [SideProposal]?
    public var pr: PR?
    public var continuedIn: Link?
    public var continuedFrom: Link?
    public var agent: AgentInfo?
    public var followUps: [String]?
    public var toolsOff: [String]?
    public init(temporary: Temporary? = nil, learned: [String: LearnState]? = nil, app: String? = nil, ref: ContainerRef, title: String, createdAt: String, updatedAt: String, cwd: String? = nil, model: ModelRef? = nil, projectPath: String? = nil, review: ReviewInfo? = nil, worktree: WorktreeInfo? = nil, profile: SessionProfile? = nil, parent: Parent? = nil, helper: Helper? = nil, side: Side? = nil, sideProposals: [SideProposal]? = nil, pr: PR? = nil, continuedIn: Link? = nil, continuedFrom: Link? = nil, agent: AgentInfo? = nil, followUps: [String]? = nil, toolsOff: [String]? = nil) { self.temporary = temporary; self.learned = learned; self.app = app; self.ref = ref; self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt; self.cwd = cwd; self.model = model; self.projectPath = projectPath; self.review = review; self.worktree = worktree; self.profile = profile; self.parent = parent; self.helper = helper; self.side = side; self.sideProposals = sideProposals; self.pr = pr; self.continuedIn = continuedIn; self.continuedFrom = continuedFrom; self.agent = agent; self.followUps = followUps; self.toolsOff = toolsOff }
}

public struct SessionsDecideResult: Codable, Sendable, Hashable {
    public var status: ApprovalStatus
    public init(status: ApprovalStatus) { self.status = status }
}

public struct SessionsProcessStopResult: Codable, Sendable, Hashable {
    public var process: BackgroundProcess
    public init(process: BackgroundProcess) { self.process = process }
}

public struct SetSiteParams: Codable, Sendable, Hashable {
    public enum Level: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case allowed, blocked, ask
        public var description: String { rawValue }
    }
    public var site: String
    public var level: Level
    public init(site: String, level: Level) { self.site = site; self.level = level }
}

public struct SettingsPatch: Codable, Sendable, Hashable {
    public struct Models: Codable, Sendable, Hashable {
        public var utility: UtilityChoice?
        public init(utility: UtilityChoice? = nil) { self.utility = utility }
    }
    public struct Build: Codable, Sendable, Hashable {
        public var sandbox: Bool?
        public var autoReview: Bool?
        public init(sandbox: Bool? = nil, autoReview: Bool? = nil) { self.sandbox = sandbox; self.autoReview = autoReview }
    }
    public struct Chat: Codable, Sendable, Hashable {
        public var mcp: Bool?
        public var mcpServers: [String]?
        public var followUps: Bool?
        public var sideOnUnrelated: SideOnUnrelated?
        public var sidePropose: Bool?
        public var sideWake: Bool?
        public init(mcp: Bool? = nil, mcpServers: [String]? = nil, followUps: Bool? = nil, sideOnUnrelated: SideOnUnrelated? = nil, sidePropose: Bool? = nil, sideWake: Bool? = nil) { self.mcp = mcp; self.mcpServers = mcpServers; self.followUps = followUps; self.sideOnUnrelated = sideOnUnrelated; self.sidePropose = sidePropose; self.sideWake = sideWake }
    }
    public struct AboutMe: Codable, Sendable, Hashable {
        public var enabled: Bool?
        public var capture: Bool?
        public var inThreads: Bool?
        public var inAgents: Bool?
        public var provider: String?
        public init(enabled: Bool? = nil, capture: Bool? = nil, inThreads: Bool? = nil, inAgents: Bool? = nil, provider: String? = nil) { self.enabled = enabled; self.capture = capture; self.inThreads = inThreads; self.inAgents = inAgents; self.provider = provider }
    }
    public struct Memory: Codable, Sendable, Hashable {
        public struct Embeddings: Codable, Sendable, Hashable {
            public var baseUrl: String
            public var model: String
            public var dims: Double
            public var provider: String?
            public init(baseUrl: String, model: String, dims: Double, provider: String? = nil) { self.baseUrl = baseUrl; self.model = model; self.dims = dims; self.provider = provider }
        }
        public var providers: [McpMemoryProvider]?
        public var semantic: Bool?
        public var localOnly: Bool?
        public var pastChats: Bool?
        public var embeddings: Embeddings?
        public init(providers: [McpMemoryProvider]? = nil, semantic: Bool? = nil, localOnly: Bool? = nil, pastChats: Bool? = nil, embeddings: Embeddings? = nil) { self.providers = providers; self.semantic = semantic; self.localOnly = localOnly; self.pastChats = pastChats; self.embeddings = embeddings }
    }
    public var models: Models?
    public var build: Build?
    public var chat: Chat?
    public var aboutMe: AboutMe?
    public var memory: Memory?
    public init(models: Models? = nil, build: Build? = nil, chat: Chat? = nil, aboutMe: AboutMe? = nil, memory: Memory? = nil) { self.models = models; self.build = build; self.chat = chat; self.aboutMe = aboutMe; self.memory = memory }
}

public struct SetupNode: Codable, Sendable, Hashable, Identifiable {
    public enum Column: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case you, piopio, uses
        public var description: String { rawValue }
    }
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case device, channel, place, provider, codingAgent = "coding_agent", connector, mcp, memory
        public var description: String { rawValue }
    }
    public enum State: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case ok, needsYou = "needs_you", unused, off
        public var description: String { rawValue }
    }
    public struct Open: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case agent, settings, automation, project, overview
            public var description: String { rawValue }
        }
        public var kind: Kind
        public var id: String?
        public var pane: String?
        public init(kind: Kind, id: String? = nil, pane: String? = nil) { self.kind = kind; self.id = id; self.pane = pane }
    }
    public struct Agent: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var avatar: String?
        public var state: SetupNode.State
        public var reason: String?
        public init(id: String, name: String, avatar: String? = nil, state: SetupNode.State, reason: String? = nil) { self.id = id; self.name = name; self.avatar = avatar; self.state = state; self.reason = reason }
    }
    public var id: String
    public var column: Column
    public var kind: Kind
    public var name: String
    public var line: String
    public var state: State
    public var reason: String?
    public var `open`: Open?
    public var agents: [Agent]?
    public init(id: String, column: Column, kind: Kind, name: String, line: String, state: State, reason: String? = nil, open: Open? = nil, agents: [Agent]? = nil) { self.id = id; self.column = column; self.kind = kind; self.name = name; self.line = line; self.state = state; self.reason = reason; self.`open` = `open`; self.agents = agents }
}

public struct SetupResult: Codable, Sendable, Hashable {
    public struct Edge: Codable, Sendable, Hashable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }
    public struct Row: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case agent, automation
            public var description: String { rawValue }
        }
        public enum RunsOn: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case mac, cloud
            public var description: String { rawValue }
        }
        public var kind: Kind
        public var id: String
        public var name: String
        public var runsOn: RunsOn
        public var model: String?
        public var reachesYouIn: String
        public var nextRun: String?
        public var monthUsd: Double
        public var paused: Bool?
        public init(kind: Kind, id: String, name: String, runsOn: RunsOn, model: String? = nil, reachesYouIn: String, nextRun: String? = nil, monthUsd: Double, paused: Bool? = nil) { self.kind = kind; self.id = id; self.name = name; self.runsOn = runsOn; self.model = model; self.reachesYouIn = reachesYouIn; self.nextRun = nextRun; self.monthUsd = monthUsd; self.paused = paused }
    }
    public var nodes: [SetupNode]
    public var edges: [Edge]
    public var rows: [Row]
    public init(nodes: [SetupNode], edges: [Edge], rows: [Row]) { self.nodes = nodes; self.edges = edges; self.rows = rows }
}

public enum SideOnUnrelated: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case ask, start, off
    public var description: String { rawValue }
}

public struct SkillInfo: Codable, Sendable, Hashable {
    public enum Where: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case yours, project, package
        public var description: String { rawValue }
    }
    public var name: String
    public var description: String
    public var path: String
    public var `where`: Where
    public var manual: Bool
    public var editable: Bool
    public var source: String?
    public init(name: String, description: String, path: String, where: Where, manual: Bool, editable: Bool, source: String? = nil) { self.name = name; self.description = description; self.path = path; self.`where` = `where`; self.manual = manual; self.editable = editable; self.source = source }
}

public struct SkillPathParams: Codable, Sendable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct SkillResult: Codable, Sendable, Hashable {
    public var info: SkillInfo
    public var body: String
    public init(info: SkillInfo, body: String) { self.info = info; self.body = body }
}

public struct SkillSaveParams: Codable, Sendable, Hashable {
    public var path: String?
    public var project: String?
    public var name: String
    public var description: String
    public var body: String
    public var manual: Bool?
    public init(path: String? = nil, project: String? = nil, name: String, description: String, body: String, manual: Bool? = nil) { self.path = path; self.project = project; self.name = name; self.description = description; self.body = body; self.manual = manual }
}

public struct SkillSaveResult: Codable, Sendable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct SkillsDeleteParams: Codable, Sendable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct SkillsListParams: Codable, Sendable, Hashable {
    public var project: String?
    public init(project: String? = nil) { self.project = project }
}

public struct SkillsResult: Codable, Sendable, Hashable {
    public var skills: [SkillInfo]
    public init(skills: [SkillInfo]) { self.skills = skills }
}

public struct Snapshot: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var items: [TimelineItem]
    public var state: SessionState
    public init(ref: ContainerRef, items: [TimelineItem], state: SessionState) { self.ref = ref; self.items = items; self.state = state }
}

public struct SpendDay: Codable, Sendable, Hashable {
    public struct Top: Codable, Sendable, Hashable {
        public var label: String
        public var usd: Double
        public init(label: String, usd: Double) { self.label = label; self.usd = usd }
    }
    public var day: String
    public var macUsd: Double
    public var cloudUsd: Double
    public var calls: Int
    public var unknownCalls: Int
    public var top: [Top]
    public init(day: String, macUsd: Double, cloudUsd: Double, calls: Int, unknownCalls: Int, top: [Top]) { self.day = day; self.macUsd = macUsd; self.cloudUsd = cloudUsd; self.calls = calls; self.unknownCalls = unknownCalls; self.top = top }
}

public struct SpendExport: Codable, Sendable, Hashable {
    public var csv: String
    public var rows: Int
    public init(csv: String, rows: Int) { self.csv = csv; self.rows = rows }
}

public struct SpendExportParams: Codable, Sendable, Hashable {
    public var range: SpendRange
    public init(range: SpendRange) { self.range = range }
}

public struct SpendFilter: Codable, Sendable, Hashable {
    public var agent: String?
    public var automation: String?
    public var place: String?
    public init(agent: String? = nil, automation: String? = nil, place: String? = nil) { self.agent = agent; self.automation = automation; self.place = place }
}

public struct SpendGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var usd: Double
    public var calls: Int
    public var unknownCalls: Int
    public var plan: Bool
    public var tokens: Double
    public var share: Double
    public var ref: ContainerRef?
    public init(id: String, label: String, usd: Double, calls: Int, unknownCalls: Int, plan: Bool, tokens: Double, share: Double, ref: ContainerRef? = nil) { self.id = id; self.label = label; self.usd = usd; self.calls = calls; self.unknownCalls = unknownCalls; self.plan = plan; self.tokens = tokens; self.share = share; self.ref = ref }
}

public enum SpendGroupBy: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case what, model, provider, project, `where`
    public var description: String { rawValue }
}

public struct SpendItem: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var title: String
    public var usd: Double
    public var calls: Int
    public var unknownCalls: Int
    public var plan: Bool
    public var tokens: Double
    public var lastAt: String
    public init(ref: ContainerRef, title: String, usd: Double, calls: Int, unknownCalls: Int, plan: Bool, tokens: Double, lastAt: String) { self.ref = ref; self.title = title; self.usd = usd; self.calls = calls; self.unknownCalls = unknownCalls; self.plan = plan; self.tokens = tokens; self.lastAt = lastAt }
}

public struct SpendItems: Codable, Sendable, Hashable {
    public var items: [SpendItem]
    public init(items: [SpendItem]) { self.items = items }
}

public struct SpendItemsParams: Codable, Sendable, Hashable {
    public var range: SpendRange
    public var groupBy: SpendGroupBy
    public var group: String
    public init(range: SpendRange, groupBy: SpendGroupBy, group: String) { self.range = range; self.groupBy = groupBy; self.group = group }
}

public struct SpendParams: Codable, Sendable, Hashable {
    public var range: SpendRange
    public var groupBy: SpendGroupBy?
    public var filter: SpendFilter?
    public init(range: SpendRange, groupBy: SpendGroupBy? = nil, filter: SpendFilter? = nil) { self.range = range; self.groupBy = groupBy; self.filter = filter }
}

public enum SpendRange: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case today, sevenDays = "7d", month, lastMonth = "last_month", twelveMonths = "12m"
    public var description: String { rawValue }
}

public struct SpendResult: Codable, Sendable, Hashable {
    public struct Tokens: Codable, Sendable, Hashable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite: Double
        public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) { self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite }
    }
    public var range: SpendRange
    public var from: String
    public var to: String
    public var knownUsd: Double
    public var calls: Int
    public var unknownCalls: Int
    public var planCalls: Int
    public var planTokens: Double
    public var tokens: Tokens
    public var forecastUsd: Double?
    public var days: [SpendDay]
    public var groupBy: SpendGroupBy
    public var groups: [SpendGroup]
    public var since: String?
    public var backfilling: Bool?
    public var suggestions: [SpendSuggestion]
    public var cloudAsOf: String?
    public init(range: SpendRange, from: String, to: String, knownUsd: Double, calls: Int, unknownCalls: Int, planCalls: Int, planTokens: Double, tokens: Tokens, forecastUsd: Double? = nil, days: [SpendDay], groupBy: SpendGroupBy, groups: [SpendGroup], since: String? = nil, backfilling: Bool? = nil, suggestions: [SpendSuggestion], cloudAsOf: String? = nil) { self.range = range; self.from = from; self.to = to; self.knownUsd = knownUsd; self.calls = calls; self.unknownCalls = unknownCalls; self.planCalls = planCalls; self.planTokens = planTokens; self.tokens = tokens; self.forecastUsd = forecastUsd; self.days = days; self.groupBy = groupBy; self.groups = groups; self.since = since; self.backfilling = backfilling; self.suggestions = suggestions; self.cloudAsOf = cloudAsOf }
}

public struct SpendSuggestion: Codable, Sendable, Hashable, Identifiable {
    public struct Action: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case automation, agent, onDevice = "on_device"
            public var description: String { rawValue }
        }
        public var kind: Kind
        public var id: String?
        public var label: String
        public init(kind: Kind, id: String? = nil, label: String) { self.kind = kind; self.id = id; self.label = label }
    }
    public var id: String
    public var text: String
    public var savingUsd: Double
    public var action: Action?
    public init(id: String, text: String, savingUsd: Double, action: Action? = nil) { self.id = id; self.text = text; self.savingUsd = savingUsd; self.action = action }
}

public struct StartSideParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var brief: String
    public var title: String?
    public init(ref: ContainerRef, brief: String, title: String? = nil) { self.ref = ref; self.brief = brief; self.title = title }
}

public struct StepsItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var at: String
    public var tools: [ToolItem]
    public var thinking: String?
    public var thinkingMs: Double?
    public init(id: String, at: String, tools: [ToolItem], thinking: String? = nil, thinkingMs: Double? = nil) { self.id = id; self.at = at; self.tools = tools; self.thinking = thinking; self.thinkingMs = thinkingMs }
    private enum CodingKeys: String, CodingKey { case id, at, tools, thinking, thinkingMs, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.at = try c.decode(String.self, forKey: .at)
        self.tools = try c.decode([ToolItem].self, forKey: .tools)
        self.thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        self.thinkingMs = try c.decodeIfPresent(Double.self, forKey: .thinkingMs)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("steps", forKey: .kind)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.at, forKey: .at)
        try c.encode(self.tools, forKey: .tools)
        try c.encodeIfPresent(self.thinking, forKey: .thinking)
        try c.encodeIfPresent(self.thinkingMs, forKey: .thinkingMs)
    }
}

public struct StorageCleanParams: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case worktrees
        public var description: String { rawValue }
    }
    public var action: Action
    public init(action: Action) { self.action = action }
}

public struct StorageCleanResult: Codable, Sendable, Hashable {
    public var freedBytes: Double
    public var removed: Int
    public init(freedBytes: Double, removed: Int) { self.freedBytes = freedBytes; self.removed = removed }
}

public struct StorageResult: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public struct Action: Codable, Sendable, Hashable, Identifiable {
            public enum Id: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
                case worktrees
                public var description: String { rawValue }
            }
            public var id: Id
            public var label: String
            public var freesBytes: Double
            public var count: Int
            public init(id: Id, label: String, freesBytes: Double, count: Int) { self.id = id; self.label = label; self.freesBytes = freesBytes; self.count = count }
        }
        public var id: String
        public var label: String
        public var bytes: Double
        public var detail: String?
        public var action: Action?
        public init(id: String, label: String, bytes: Double, detail: String? = nil, action: Action? = nil) { self.id = id; self.label = label; self.bytes = bytes; self.detail = detail; self.action = action }
    }
    public var totalBytes: Double
    public var items: [Item]
    public var path: String
    public init(totalBytes: Double, items: [Item], path: String) { self.totalBytes = totalBytes; self.items = items; self.path = path }
}

public struct SubagentPathParams: Codable, Sendable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct SubagentResult: Codable, Sendable, Hashable {
    public var info: CustomSubagentInfo
    public var instructions: String
    public init(info: CustomSubagentInfo, instructions: String) { self.info = info; self.instructions = instructions }
}

public struct SubagentSaveParams: Codable, Sendable, Hashable {
    public var path: String?
    public var project: String?
    public var name: String
    public var description: String
    public var tools: [String]?
    public var model: String?
    public var instructions: String
    public init(path: String? = nil, project: String? = nil, name: String, description: String, tools: [String]? = nil, model: String? = nil, instructions: String) { self.path = path; self.project = project; self.name = name; self.description = description; self.tools = tools; self.model = model; self.instructions = instructions }
}

public struct SubagentSaveResult: Codable, Sendable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct SubagentsDeleteParams: Codable, Sendable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct SubagentsListParams: Codable, Sendable, Hashable {
    public var project: String?
    public init(project: String? = nil) { self.project = project }
}

public struct SubagentsResult: Codable, Sendable, Hashable {
    public var subagents: [CustomSubagentInfo]
    public init(subagents: [CustomSubagentInfo]) { self.subagents = subagents }
}

public struct SubmitParams: Codable, Sendable, Hashable {
    public struct Input: Codable, Sendable, Hashable {
        public var text: String
        public var attachments: [Attachment]?
        public init(text: String, attachments: [Attachment]? = nil) { self.text = text; self.attachments = attachments }
    }
    public enum WhenBusy: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case followUp, steer, reject
        public var description: String { rawValue }
    }
    public var ref: ContainerRef
    public var input: Input
    public var whenBusy: WhenBusy?
    public var clientRequestId: String?
    public init(ref: ContainerRef, input: Input, whenBusy: WhenBusy? = nil, clientRequestId: String? = nil) { self.ref = ref; self.input = input; self.whenBusy = whenBusy; self.clientRequestId = clientRequestId }
}

public struct SubmitResult: Codable, Sendable, Hashable {
    public enum Disposition: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case started, queued
        public var description: String { rawValue }
    }
    public var accepted: Bool
    public var disposition: Disposition
    public init(accepted: Bool, disposition: Disposition) { self.accepted = accepted; self.disposition = disposition }
}

public struct SubscribeParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var fold: Bool?
    public init(ref: ContainerRef, fold: Bool? = nil) { self.ref = ref; self.fold = fold }
}

public struct SubscribeResult: Codable, Sendable, Hashable {
    public var subscriptionId: String
    public var snapshot: Snapshot
    public init(subscriptionId: String, snapshot: Snapshot) { self.subscriptionId = subscriptionId; self.snapshot = snapshot }
}

public struct SuggestBranchParams: Codable, Sendable, Hashable {
    public var prompt: String
    public init(prompt: String) { self.prompt = prompt }
}

public struct SuggestBranchResult: Codable, Sendable, Hashable {
    public var branch: String
    public init(branch: String) { self.branch = branch }
}

public struct SwitchBranchParams: Codable, Sendable, Hashable {
    public var ref: ContainerRef
    public var branch: String
    public init(ref: ContainerRef, branch: String) { self.ref = ref; self.branch = branch }
}

public struct SystemItem: Codable, Sendable, Hashable, Identifiable {
    public enum Level: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case info, warn, error
        public var description: String { rawValue }
    }
    public struct Run: Codable, Sendable, Hashable, Identifiable {
        public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
            case running, done, failed, skipped
            public var description: String { rawValue }
        }
        /// The automation that started it (docs/spec/27 §4): “From <name>”
        public struct Origin: Codable, Sendable, Hashable, Identifiable {
            public var id: String
            public var name: String
            public init(id: String, name: String) { self.id = id; self.name = name }
        }
        public var id: String
        public var status: Status
        public var sent: Int
        public var summary: String?
        public var costUsd: Double?
        /// The automation that started it (docs/spec/27 §4): “From <name>”
        public var automation: Origin?
        public init(id: String, status: Status, sent: Int, summary: String? = nil, costUsd: Double? = nil, automation: Origin? = nil) { self.id = id; self.status = status; self.sent = sent; self.summary = summary; self.costUsd = costUsd; self.automation = automation }
    }
    public var id: String
    public var at: String
    public var level: Level
    public var text: String
    public var run: Run?
    public init(id: String, at: String, level: Level, text: String, run: Run? = nil) { self.id = id; self.at = at; self.level = level; self.text = text; self.run = run }
    private enum CodingKeys: String, CodingKey { case id, at, level, text, run, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.at = try c.decode(String.self, forKey: .at)
        self.level = try c.decode(Level.self, forKey: .level)
        self.text = try c.decode(String.self, forKey: .text)
        self.run = try c.decodeIfPresent(Run.self, forKey: .run)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("system", forKey: .kind)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.at, forKey: .at)
        try c.encode(self.level, forKey: .level)
        try c.encode(self.text, forKey: .text)
        try c.encodeIfPresent(self.run, forKey: .run)
    }
}

public struct TextParams: Codable, Sendable, Hashable {
    public var text: String
    public init(text: String) { self.text = text }
}

public enum TimelineItem: Codable, Sendable, Hashable {
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
    private enum CodingKeys: String, CodingKey { case kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .kind)
        switch tag {
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
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown kind \(tag)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .user(let v): try v.encode(to: encoder)
        case .assistant(let v): try v.encode(to: encoder)
        case .tool(let v): try v.encode(to: encoder)
        case .system(let v): try v.encode(to: encoder)
        case .compaction(let v): try v.encode(to: encoder)
        case .checkpoint(let v): try v.encode(to: encoder)
        case .steps(let v): try v.encode(to: encoder)
        case .approval(let v): try v.encode(to: encoder)
        case .result(let v): try v.encode(to: encoder)
        case .agentMsg(let v): try v.encode(to: encoder)
        }
    }
}

public struct Todo: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case pending, inProgress = "in_progress", done
        public var description: String { rawValue }
    }
    public var text: String
    public var detail: String?
    public var status: Status
    public init(text: String, detail: String? = nil, status: Status) { self.text = text; self.detail = detail; self.status = status }
}

public enum ToolDetails: Codable, Sendable, Hashable {
    public enum TaskStatus: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case started, queued, done, error, stopped
        public var description: String { rawValue }
    }
    public enum Outcome: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case approved, changes, unanswered
        public var description: String { rawValue }
    }
    public struct Agent: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public enum AgentStatus: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case replied, noReply = "no_reply", failed
        public var description: String { rawValue }
    }
    case diff(path: String, diff: String)
    case file(path: String, language: String? = nil)
    case terminal(command: String, exitCode: Int? = nil)
    case json(JSONValue)
    case todos([Todo])
    case task(sessionId: String? = nil, status: TaskStatus? = nil, costUsd: Double? = nil)
    case files([PresentedFile])
    case conversations(conversations: [PastConversation], withheld: Int? = nil)
    case learn(file: String? = nil, items: [LearnItem])
    case plan(summary: String, steps: [String], files: [String]? = nil, risks: [String]? = nil, outcome: Outcome? = nil, edited: Bool? = nil, note: String? = nil)
    case agent(agent: Agent, joined: Bool? = nil, status: AgentStatus? = nil)
    case automation(automation: AutomationSummary, changed: Bool? = nil)
    private enum CodingKeys: String, CodingKey { case type, path, diff, language, command, exitCode, value, items, sessionId, status, costUsd, files, conversations, withheld, file, summary, steps, risks, outcome, edited, note, agent, joined, automation, changed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "diff": self = .diff(path: try c.decode(String.self, forKey: .path), diff: try c.decode(String.self, forKey: .diff))
        case "file": self = .file(path: try c.decode(String.self, forKey: .path), language: try c.decodeIfPresent(String.self, forKey: .language))
        case "terminal": self = .terminal(command: try c.decode(String.self, forKey: .command), exitCode: try c.decodeIfPresent(Int.self, forKey: .exitCode))
        case "json": self = .json(try c.decode(JSONValue.self, forKey: .value))
        case "todos": self = .todos(try c.decode([Todo].self, forKey: .items))
        case "task": self = .task(sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId), status: try c.decodeIfPresent(TaskStatus.self, forKey: .status), costUsd: try c.decodeIfPresent(Double.self, forKey: .costUsd))
        case "files": self = .files(try c.decode([PresentedFile].self, forKey: .files))
        case "conversations": self = .conversations(conversations: try c.decode([PastConversation].self, forKey: .conversations), withheld: try c.decodeIfPresent(Int.self, forKey: .withheld))
        case "learn": self = .learn(file: try c.decodeIfPresent(String.self, forKey: .file), items: try c.decode([LearnItem].self, forKey: .items))
        case "plan": self = .plan(summary: try c.decode(String.self, forKey: .summary), steps: try c.decode([String].self, forKey: .steps), files: try c.decodeIfPresent([String].self, forKey: .files), risks: try c.decodeIfPresent([String].self, forKey: .risks), outcome: try c.decodeIfPresent(Outcome.self, forKey: .outcome), edited: try c.decodeIfPresent(Bool.self, forKey: .edited), note: try c.decodeIfPresent(String.self, forKey: .note))
        case "agent": self = .agent(agent: try c.decode(Agent.self, forKey: .agent), joined: try c.decodeIfPresent(Bool.self, forKey: .joined), status: try c.decodeIfPresent(AgentStatus.self, forKey: .status))
        case "automation": self = .automation(automation: try c.decode(AutomationSummary.self, forKey: .automation), changed: try c.decodeIfPresent(Bool.self, forKey: .changed))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown type \(tag)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .diff(let path, let diff): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("diff", forKey: .type); try c.encode(path, forKey: .path); try c.encode(diff, forKey: .diff)
        case .file(let path, let language): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("file", forKey: .type); try c.encode(path, forKey: .path); try c.encodeIfPresent(language, forKey: .language)
        case .terminal(let command, let exitCode): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("terminal", forKey: .type); try c.encode(command, forKey: .command); try c.encodeIfPresent(exitCode, forKey: .exitCode)
        case .json(let value): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("json", forKey: .type); try c.encode(value, forKey: .value)
        case .todos(let items): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("todos", forKey: .type); try c.encode(items, forKey: .items)
        case .task(let sessionId, let status, let costUsd): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("task", forKey: .type); try c.encodeIfPresent(sessionId, forKey: .sessionId); try c.encodeIfPresent(status, forKey: .status); try c.encodeIfPresent(costUsd, forKey: .costUsd)
        case .files(let files): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("files", forKey: .type); try c.encode(files, forKey: .files)
        case .conversations(let conversations, let withheld): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("conversations", forKey: .type); try c.encode(conversations, forKey: .conversations); try c.encodeIfPresent(withheld, forKey: .withheld)
        case .learn(let file, let items): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("learn", forKey: .type); try c.encodeIfPresent(file, forKey: .file); try c.encode(items, forKey: .items)
        case .plan(let summary, let steps, let files, let risks, let outcome, let edited, let note): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("plan", forKey: .type); try c.encode(summary, forKey: .summary); try c.encode(steps, forKey: .steps); try c.encodeIfPresent(files, forKey: .files); try c.encodeIfPresent(risks, forKey: .risks); try c.encodeIfPresent(outcome, forKey: .outcome); try c.encodeIfPresent(edited, forKey: .edited); try c.encodeIfPresent(note, forKey: .note)
        case .agent(let agent, let joined, let status): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("agent", forKey: .type); try c.encode(agent, forKey: .agent); try c.encodeIfPresent(joined, forKey: .joined); try c.encodeIfPresent(status, forKey: .status)
        case .automation(let automation, let changed): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("automation", forKey: .type); try c.encode(automation, forKey: .automation); try c.encodeIfPresent(changed, forKey: .changed)
        }
    }
}

public struct ToolItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var at: String
    public var callId: String
    public var tool: String
    public var args: JSONValue
    public var status: ToolStatus
    public var output: String?
    public var details: ToolDetails?
    public var durationMs: Double?
    public var parentCallId: String?
    public var review: String?
    public var images: [AttachmentInfo]?
    public init(id: String, at: String, callId: String, tool: String, args: JSONValue, status: ToolStatus, output: String? = nil, details: ToolDetails? = nil, durationMs: Double? = nil, parentCallId: String? = nil, review: String? = nil, images: [AttachmentInfo]? = nil) { self.id = id; self.at = at; self.callId = callId; self.tool = tool; self.args = args; self.status = status; self.output = output; self.details = details; self.durationMs = durationMs; self.parentCallId = parentCallId; self.review = review; self.images = images }
    private enum CodingKeys: String, CodingKey { case id, at, callId, tool, args, status, output, details, durationMs, parentCallId, review, images, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.at = try c.decode(String.self, forKey: .at)
        self.callId = try c.decode(String.self, forKey: .callId)
        self.tool = try c.decode(String.self, forKey: .tool)
        self.args = try c.decode(JSONValue.self, forKey: .args)
        self.status = try c.decode(ToolStatus.self, forKey: .status)
        self.output = try c.decodeIfPresent(String.self, forKey: .output)
        self.details = try c.decodeIfPresent(ToolDetails.self, forKey: .details)
        self.durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
        self.parentCallId = try c.decodeIfPresent(String.self, forKey: .parentCallId)
        self.review = try c.decodeIfPresent(String.self, forKey: .review)
        self.images = try c.decodeIfPresent([AttachmentInfo].self, forKey: .images)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("tool", forKey: .kind)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.at, forKey: .at)
        try c.encode(self.callId, forKey: .callId)
        try c.encode(self.tool, forKey: .tool)
        try c.encode(self.args, forKey: .args)
        try c.encode(self.status, forKey: .status)
        try c.encodeIfPresent(self.output, forKey: .output)
        try c.encodeIfPresent(self.details, forKey: .details)
        try c.encodeIfPresent(self.durationMs, forKey: .durationMs)
        try c.encodeIfPresent(self.parentCallId, forKey: .parentCallId)
        try c.encodeIfPresent(self.review, forKey: .review)
        try c.encodeIfPresent(self.images, forKey: .images)
    }
}

public enum ToolStatus: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case pendingApproval = "pending_approval", running, done, error, interrupted, denied
    public var description: String { rawValue }
}

public struct TraceParams: Codable, Sendable, Hashable {
    public var traceId: String
    public init(traceId: String) { self.traceId = traceId }
}

public struct TreeNode: Codable, Sendable, Hashable {
    public var entryId: String
    public var text: String
    public var at: String
    public var depth: Int
    public var current: Bool
    public var branches: Int
    public init(entryId: String, text: String, at: String, depth: Int, current: Bool, branches: Int) { self.entryId = entryId; self.text = text; self.at = at; self.depth = depth; self.current = current; self.branches = branches }
}

public struct TreeResult: Codable, Sendable, Hashable {
    public var nodes: [TreeNode]
    public init(nodes: [TreeNode]) { self.nodes = nodes }
}

public struct UnsubscribeParams: Codable, Sendable, Hashable {
    public var subscriptionId: String
    public init(subscriptionId: String) { self.subscriptionId = subscriptionId }
}

public struct UpdateWorkTaskParams: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case todo, blocked, done
        public var description: String { rawValue }
    }
    public var project: String
    public var taskId: String
    public var state: State?
    public var title: String?
    public var brief: String?
    public init(project: String, taskId: String, state: State? = nil, title: String? = nil, brief: String? = nil) { self.project = project; self.taskId = taskId; self.state = state; self.title = title; self.brief = brief }
}

public struct Usage: Codable, Sendable, Hashable {
    public var inputTokens: Double
    public var outputTokens: Double
    public var cacheReadTokens: Double
    public var cacheWriteTokens: Double
    public var costUsd: Double
    public init(inputTokens: Double, outputTokens: Double, cacheReadTokens: Double, cacheWriteTokens: Double, costUsd: Double) { self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens; self.costUsd = costUsd }
}

public struct UsageParams: Codable, Sendable, Hashable {
    public var refresh: Bool?
    public init(refresh: Bool? = nil) { self.refresh = refresh }
}

public struct UsageSummary: Codable, Sendable, Hashable {
    public var connected: Bool
    public var keyHint: String?
    public var todayUsd: Double?
    public var monthUsd: Double?
    public var totalUsd: Double?
    public init(connected: Bool, keyHint: String? = nil, todayUsd: Double? = nil, monthUsd: Double? = nil, totalUsd: Double? = nil) { self.connected = connected; self.keyHint = keyHint; self.todayUsd = todayUsd; self.monthUsd = monthUsd; self.totalUsd = totalUsd }
}

public struct UserItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var at: String
    public var text: String
    public var attachments: [AttachmentInfo]?
    public var branch: BranchInfo?
    public init(id: String, at: String, text: String, attachments: [AttachmentInfo]? = nil, branch: BranchInfo? = nil) { self.id = id; self.at = at; self.text = text; self.attachments = attachments; self.branch = branch }
    private enum CodingKeys: String, CodingKey { case id, at, text, attachments, branch, kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.at = try c.decode(String.self, forKey: .at)
        self.text = try c.decode(String.self, forKey: .text)
        self.attachments = try c.decodeIfPresent([AttachmentInfo].self, forKey: .attachments)
        self.branch = try c.decodeIfPresent(BranchInfo.self, forKey: .branch)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("user", forKey: .kind)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.at, forKey: .at)
        try c.encode(self.text, forKey: .text)
        try c.encodeIfPresent(self.attachments, forKey: .attachments)
        try c.encodeIfPresent(self.branch, forKey: .branch)
    }
}

public enum UtilityChoice: Codable, Sendable, Hashable {
    case auto
    case onDevice
    case off
    case model(ModelRef)
    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            switch text {
            case "auto": self = .auto; return
            case "on_device": self = .onDevice; return
            case "off": self = .off; return
            default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown value \(text)"))
            }
        }
        self = .model(try ModelRef(from: decoder))
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .auto: var c = encoder.singleValueContainer(); try c.encode("auto")
        case .onDevice: var c = encoder.singleValueContainer(); try c.encode("on_device")
        case .off: var c = encoder.singleValueContainer(); try c.encode("off")
        case .model(let v): try v.encode(to: encoder)
        }
    }
}

public struct WatchdogListResult: Codable, Sendable, Hashable {
    public var notes: [WatchdogNote]
    public init(notes: [WatchdogNote]) { self.notes = notes }
}

public struct WatchdogNote: Codable, Sendable, Hashable, Identifiable {
    public enum Rule: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case silent, looping, waiting
        public var description: String { rawValue }
    }
    public var id: String
    public var ref: ContainerRef
    public var title: String
    public var rule: Rule
    public var text: String
    public var at: String
    public init(id: String, ref: ContainerRef, title: String, rule: Rule, text: String, at: String) { self.id = id; self.ref = ref; self.title = title; self.rule = rule; self.text = text; self.at = at }
}

public struct WayOfWorking: Codable, Sendable, Hashable {
    /// Piopio may split work onto the board
    public var parallel: Bool
    /// Every task is reviewed by a helper with fresh eyes
    public var review: Bool
    /// Times a task may be sent back before you're asked
    public var reviewLimit: Int
    /// The checks, run after each merge
    public var testCommand: String?
    /// Tasks at once
    public var maxParallel: Int
    /// The helpers' model for doing tasks; unset: the project's
    public var buildModel: String?
    /// The reviewers' model; unset: the build model
    public var reviewModel: String?
    public var helperMode: ApprovalMode
    /// USD one conversation's tasks may spend
    public var budgetPerJob: Double?
    /// The playbook Piopio plans with: development, research, writing, or a project's own
    public var playbook: String
    public init(parallel: Bool, review: Bool, reviewLimit: Int, testCommand: String? = nil, maxParallel: Int, buildModel: String? = nil, reviewModel: String? = nil, helperMode: ApprovalMode, budgetPerJob: Double? = nil, playbook: String) { self.parallel = parallel; self.review = review; self.reviewLimit = reviewLimit; self.testCommand = testCommand; self.maxParallel = maxParallel; self.buildModel = buildModel; self.reviewModel = reviewModel; self.helperMode = helperMode; self.budgetPerJob = budgetPerJob; self.playbook = playbook }
}

public struct WorkAddTaskResult: Codable, Sendable, Hashable {
    public var task: WorkTask
    public init(task: WorkTask) { self.task = task }
}

public struct WorkChangedNotification: Codable, Sendable, Hashable {
    public var project: String
    public init(project: String) { self.project = project }
}

public struct WorkGetParams: Codable, Sendable, Hashable {
    public var project: String
    public init(project: String) { self.project = project }
}

public struct WorkGetResult: Codable, Sendable, Hashable {
    public var work: WorkInfo?
    public init(work: WorkInfo? = nil) { self.work = work }
}

public struct WorkInfo: Codable, Sendable, Hashable {
    public struct Git: Codable, Sendable, Hashable {
        public var base: String
        public var branch: String
        public var integration: String
        public init(base: String, branch: String, integration: String) { self.base = base; self.branch = branch; self.integration = integration }
    }
    public var project: String
    public var cwd: String
    public var way: WayOfWorking
    public var git: Git?
    public var tasks: [WorkTask]
    public var createdAt: String
    public init(project: String, cwd: String, way: WayOfWorking, git: Git? = nil, tasks: [WorkTask], createdAt: String) { self.project = project; self.cwd = cwd; self.way = way; self.git = git; self.tasks = tasks; self.createdAt = createdAt }
}

public struct WorkJob: Codable, Sendable, Hashable {
    public var cost: Double
    public var tasks: Int
    public var budget: Double?
    public init(cost: Double, tasks: Int, budget: Double? = nil) { self.cost = cost; self.tasks = tasks; self.budget = budget }
}

public struct WorkJobParams: Codable, Sendable, Hashable {
    public var project: String
    public var conversationId: String
    public init(project: String, conversationId: String) { self.project = project; self.conversationId = conversationId }
}

public struct WorkLandParams: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case merge, push
        public var description: String { rawValue }
    }
    public var project: String
    public var action: Action
    public init(project: String, action: Action) { self.project = project; self.action = action }
}

public struct WorkLandResult: Codable, Sendable, Hashable {
    public var commit: String?
    public var compareUrl: String?
    public var output: String?
    public init(commit: String? = nil, compareUrl: String? = nil, output: String? = nil) { self.commit = commit; self.compareUrl = compareUrl; self.output = output }
}

public struct WorkLanding: Codable, Sendable, Hashable {
    public struct File: Codable, Sendable, Hashable {
        public var path: String
        public var added: Int
        public var removed: Int
        public init(path: String, added: Int, removed: Int) { self.path = path; self.added = added; self.removed = removed }
    }
    public struct Task: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }
    public var base: String
    public var branch: String
    public var ahead: Int
    public var behind: Int
    public var files: [File]
    public var tasks: [Task]
    public var `open`: Int
    public var checkedOut: String?
    public var remote: String?
    public var compareUrl: String?
    public init(base: String, branch: String, ahead: Int, behind: Int, files: [File], tasks: [Task], open: Int, checkedOut: String? = nil, remote: String? = nil, compareUrl: String? = nil) { self.base = base; self.branch = branch; self.ahead = ahead; self.behind = behind; self.files = files; self.tasks = tasks; self.`open` = `open`; self.checkedOut = checkedOut; self.remote = remote; self.compareUrl = compareUrl }
}

public struct WorkListResult: Codable, Sendable, Hashable {
    public var work: [WorkInfo]
    public init(work: [WorkInfo]) { self.work = work }
}

public enum WorkOn: Codable, Sendable, Hashable {
    case current
    case branch(branch: String, base: String? = nil)
    case worktree(branch: String, base: String? = nil)
    private enum CodingKeys: String, CodingKey { case kind, branch, base }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .kind)
        switch tag {
        case "current": self = .current
        case "branch": self = .branch(branch: try c.decode(String.self, forKey: .branch), base: try c.decodeIfPresent(String.self, forKey: .base))
        case "worktree": self = .worktree(branch: try c.decode(String.self, forKey: .branch), base: try c.decodeIfPresent(String.self, forKey: .base))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown kind \(tag)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .current: var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("current", forKey: .kind)
        case .branch(let branch, let base): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("branch", forKey: .kind); try c.encode(branch, forKey: .branch); try c.encodeIfPresent(base, forKey: .base)
        case .worktree(let branch, let base): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("worktree", forKey: .kind); try c.encode(branch, forKey: .branch); try c.encodeIfPresent(base, forKey: .base)
        }
    }
}

public struct WorkPrParams: Codable, Sendable, Hashable {
    public var project: String
    public var title: String
    public var body: String
    public var draft: Bool?
    public init(project: String, title: String, body: String, draft: Bool? = nil) { self.project = project; self.title = title; self.body = body; self.draft = draft }
}

public struct WorkResult: Codable, Sendable, Hashable {
    public var work: WorkInfo
    public init(work: WorkInfo) { self.work = work }
}

public struct WorkTask: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case todo, doing, review, integrating, done, blocked
        public var description: String { rawValue }
    }
    public enum By: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case piopio, you
        public var description: String { rawValue }
    }
    public var id: String
    public var title: String
    public var brief: String
    public var done: String?
    /// What the helper is called on the board: “Builder”, “Researcher”
    public var helper: String
    public var state: State
    public var by: By
    /// The conversation that made it; its updates go there
    public var conversationId: String?
    public var sessionId: String?
    public var reviewSessionId: String?
    public var branch: String?
    public var cwd: String?
    public var report: String?
    public var review: String?
    public var attempts: Int
    public var blocked: String?
    /// When its work was merged into the project's branch
    public var landed: String?
    public var createdAt: String
    public var updatedAt: String
    public init(id: String, title: String, brief: String, done: String? = nil, helper: String, state: State, by: By, conversationId: String? = nil, sessionId: String? = nil, reviewSessionId: String? = nil, branch: String? = nil, cwd: String? = nil, report: String? = nil, review: String? = nil, attempts: Int, blocked: String? = nil, landed: String? = nil, createdAt: String, updatedAt: String) { self.id = id; self.title = title; self.brief = brief; self.done = done; self.helper = helper; self.state = state; self.by = by; self.conversationId = conversationId; self.sessionId = sessionId; self.reviewSessionId = reviewSessionId; self.branch = branch; self.cwd = cwd; self.report = report; self.review = review; self.attempts = attempts; self.blocked = blocked; self.landed = landed; self.createdAt = createdAt; self.updatedAt = updatedAt }
}

public struct WorktreeInfo: Codable, Sendable, Hashable {
    public enum Finished: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
        case merged, discarded
        public var description: String { rawValue }
    }
    public var branch: String
    public var base: String
    public var finished: Finished?
    public init(branch: String, base: String, finished: Finished? = nil) { self.branch = branch; self.base = base; self.finished = finished }
}

public struct WriteFileParams: Codable, Sendable, Hashable {
    public var cwd: String
    public var path: String
    public var content: String
    public init(cwd: String, path: String, content: String) { self.cwd = cwd; self.path = path; self.content = content }
}

/// Every method's params and result type, and every notification's, by name: what the app sends and reads.
public enum ProtocolTypes {
    /// The schema's named definitions (src/schema.ts).
    public static let definitions: [String: any (Codable & Sendable).Type] = [
        "CatalogChanged": CatalogChanged.self,
        "ContainerRef": ContainerRef.self,
        "ModelInfo": ModelInfo.self,
        "SessionEvent": SessionEvent.self,
        "SessionEventsNotification": SessionEventsNotification.self,
        "SessionState": SessionState.self,
        "SessionSummary": SessionSummary.self,
        "Snapshot": Snapshot.self,
        "TimelineItem": TimelineItem.self,
    ]
    /// What each method takes.
    public static let params: [String: any (Codable & Sendable).Type] = [
        "aboutMe.get": Empty.self,
        "aboutMe.set": TextParams.self,
        "aboutMe.undo": RevisionIdParams.self,
        "agents.conversations": RefParams.self,
        "agents.create": CreateAgentParams.self,
        "agents.decide": AgentDecideParams.self,
        "agents.deploy": AgentsDeployParams.self,
        "agents.export": AgentsExportParams.self,
        "agents.files": RefParams.self,
        "agents.files.add": AgentFilesAddParams.self,
        "agents.files.delete": AgentsFilesDeleteParams.self,
        "agents.files.note": AgentFileParams.self,
        "agents.get": RefParams.self,
        "agents.memory": RefParams.self,
        "agents.move": AgentMoveParams.self,
        "agents.pause": AgentPauseParams.self,
        "agents.retire": AgentsRetireParams.self,
        "agents.runNow": AgentRunNowParams.self,
        "agents.runs": RefParams.self,
        "agents.save": AgentSaveParams.self,
        "agents.status": AgentsStatusParams.self,
        "agents.templates": Empty.self,
        "agents.trace": TraceParams.self,
        "agents.triggers": AgentsTriggersParams.self,
        "agents.undo": AgentUndoParams.self,
        "apps.allow": LibraryPathParams.self,
        "apps.close": LibraryPathParams.self,
        "apps.conversation": LibraryPathParams.self,
        "apps.open": LibraryPathParams.self,
        "apps.refresh": LibraryPathParams.self,
        "apps.revoke": LibraryPathParams.self,
        "apps.undo": AppUndoParams.self,
        "automations.add": AutomationsAddParams.self,
        "automations.dismissMigrationReport": Empty.self,
        "automations.get": AutomationIdParams.self,
        "automations.list": AutomationsParams.self,
        "automations.migrationReport": Empty.self,
        "automations.remove": AutomationIdParams.self,
        "automations.restore": AutomationIdParams.self,
        "automations.run": AutomationIdParams.self,
        "automations.runs": AutomationsRunsParams.self,
        "automations.update": AutomationsUpdateParams.self,
        "browser.setSite": SetSiteParams.self,
        "browser.sites": Empty.self,
        "catalog.search": SearchParams.self,
        "cloud.connect": CloudConnectParams.self,
        "cloud.disconnect": Empty.self,
        "cloud.setup": CloudSetupParams.self,
        "cloud.status": Empty.self,
        "cloud.update": Empty.self,
        "connectors.calendars": ConnectorAccountParams.self,
        "connectors.cancel": LoginIdParams.self,
        "connectors.configure": ConnectorConfigureParams.self,
        "connectors.connect": ConnectorParams.self,
        "connectors.disconnect": ConnectorAccountParams.self,
        "connectors.list": Empty.self,
        "connectors.setCalendar": ConnectorSetCalendarParams.self,
        "endpoints.check": EndpointCheckParams.self,
        "endpoints.detect": Empty.self,
        "endpoints.remove": EndpointIdParams.self,
        "endpoints.save": EndpointSaveParams.self,
        "engine.hello": HelloParams.self,
        "engine.shutdown": Empty.self,
        "engine.status": Empty.self,
        "git.branches": CwdParams.self,
        "git.checkout": GitCheckoutParams.self,
        "git.commit": GitCommitParams.self,
        "git.log": GitLogParams.self,
        "git.message": GitMessageParams.self,
        "git.status": CwdParams.self,
        "git.suggestBranch": SuggestBranchParams.self,
        "git.sync": GitSyncParams.self,
        "github.clone": GitHubCloneParams.self,
        "github.repos": Empty.self,
        "github.setToken": GitHubTokenParams.self,
        "github.signOut": Empty.self,
        "github.status": Empty.self,
        "home.agenda": HomeAgendaParams.self,
        "hooks.delete": HooksDeleteParams.self,
        "hooks.importClaude": HookImportParams.self,
        "hooks.list": HooksListParams.self,
        "hooks.save": HookSaveParams.self,
        "hooks.toggle": HookToggleParams.self,
        "hooks.try": HookTryParams.self,
        "inbox.list": Empty.self,
        "inbox.read": InboxReadParams.self,
        "learn.answer": LearnAnswerParams.self,
        "learn.save": LearnSaveParams.self,
        "library.add": LibraryPathParams.self,
        "library.list": Empty.self,
        "library.pin": LibraryPinParams.self,
        "library.relocate": LibraryRelocateParams.self,
        "library.remove": LibraryIdParams.self,
        "library.reorder": LibraryIdsParams.self,
        "library.restore": LibraryIdParams.self,
        "library.saved": LibrarySavedParams.self,
        "library.visual": LibraryIdParams.self,
        "mcp.add": McpAddParams.self,
        "mcp.detect": Empty.self,
        "mcp.list": McpListParams.self,
        "mcp.probe": McpProbeParams.self,
        "mcp.remove": McpNameParams.self,
        "mcp.setChat": McpSetChatParams.self,
        "mcp.setEnabled": McpSetEnabledParams.self,
        "mcp.setTool": McpSetToolParams.self,
        "mcp.status": McpStatusParams.self,
        "memory.add": MemoryAddParams.self,
        "memory.banks": Empty.self,
        "memory.export": MemoryExportParams.self,
        "memory.forget": MemoryIdParams.self,
        "memory.history": MemoryHistoryParams.self,
        "memory.list": MemoryListParams.self,
        "memory.recall": MemoryRecallParams.self,
        "memory.reindex": Empty.self,
        "memory.setLearning": MemoryLearningParams.self,
        "memory.status": Empty.self,
        "memory.tools": MemoryToolsParams.self,
        "memory.update": MemoryUpdateParams.self,
        "memory.wipe": MemoryWipeParams.self,
        "models.list": ModelsListParams.self,
        "models.onDevice": Empty.self,
        "packages.install": PackageParams.self,
        "packages.list": Empty.self,
        "packages.preview": PackageParams.self,
        "packages.remove": PackageParams.self,
        "packages.setEnabled": PackageEnableParams.self,
        "packages.setResource": PackageResourceParams.self,
        "packages.update": PackagesUpdateParams.self,
        "projects.add": ProjectsAddParams.self,
        "projects.configure": ProjectsConfigureParams.self,
        "projects.create": ProjectsCreateParams.self,
        "projects.files": FilesParams.self,
        "projects.list": Empty.self,
        "projects.listDir": ListDirParams.self,
        "projects.readFile": ReadFileParams.self,
        "projects.remove": ProjectsRemoveParams.self,
        "projects.writeFile": WriteFileParams.self,
        "providers.answer": ProviderAnswerParams.self,
        "providers.cancelLogin": LoginIdParams.self,
        "providers.list": Empty.self,
        "providers.login": ProviderLoginParams.self,
        "providers.logout": ProviderParams.self,
        "providers.models": ProviderParams.self,
        "providers.saveKey": ProviderKeyParams.self,
        "providers.setHidden": ProviderHiddenParams.self,
        "providers.verifyKey": ProviderKeyParams.self,
        "secrets.changed": SecretChangedParams.self,
        "sessions.abort": RefParams.self,
        "sessions.agentDraft": RefParams.self,
        "sessions.changes": ChangesParams.self,
        "sessions.commands": RefParams.self,
        "sessions.compact": RefParams.self,
        "sessions.configure": ConfigureParams.self,
        "sessions.continueIn": ContinueInParams.self,
        "sessions.create": CreateSessionParams.self,
        "sessions.decide": SessionDecideParams.self,
        "sessions.delete": RefParams.self,
        "sessions.diff": DiffParams.self,
        "sessions.edit": EditParams.self,
        "sessions.export": ExportParams.self,
        "sessions.finish": FinishParams.self,
        "sessions.fork": ItemParams.self,
        "sessions.keep": RefParams.self,
        "sessions.list": ListSessionsParams.self,
        "sessions.navigate": NavigateParams.self,
        "sessions.open": RefParams.self,
        "sessions.pr.address": AddressPrParams.self,
        "sessions.pr.create": CreatePrParams.self,
        "sessions.pr.draft": RefParams.self,
        "sessions.pr.get": RefParams.self,
        "sessions.processOutput": ProcessOutputParams.self,
        "sessions.processStop": ProcessStopParams.self,
        "sessions.queue.remove": QueueRemoveParams.self,
        "sessions.regenerate": ItemParams.self,
        "sessions.rename": RenameParams.self,
        "sessions.respond": RespondParams.self,
        "sessions.restore": RestoreParams.self,
        "sessions.review": ReviewParams.self,
        "sessions.reviewFinding": ReviewFindingParams.self,
        "sessions.rewind": RewindParams.self,
        "sessions.side.answer": AnswerSideParams.self,
        "sessions.side.start": StartSideParams.self,
        "sessions.submit": SubmitParams.self,
        "sessions.subscribe": SubscribeParams.self,
        "sessions.switchBranch": SwitchBranchParams.self,
        "sessions.tree": RefParams.self,
        "sessions.unsubscribe": UnsubscribeParams.self,
        "settings.get": Empty.self,
        "settings.set": SettingsPatch.self,
        "skills.delete": SkillsDeleteParams.self,
        "skills.get": SkillPathParams.self,
        "skills.list": SkillsListParams.self,
        "skills.save": SkillSaveParams.self,
        "stats.activity": ActivityParams.self,
        "stats.budget.release": BudgetReleaseParams.self,
        "stats.budget.set": BudgetSetParams.self,
        "stats.budgets": Empty.self,
        "stats.export": SpendExportParams.self,
        "stats.items": SpendItemsParams.self,
        "stats.setup": Empty.self,
        "stats.spend": SpendParams.self,
        "stats.storage": Empty.self,
        "stats.storage.clean": StorageCleanParams.self,
        "subagents.delete": SubagentsDeleteParams.self,
        "subagents.get": SubagentPathParams.self,
        "subagents.list": SubagentsListParams.self,
        "subagents.save": SubagentSaveParams.self,
        "usage.extras": ExtraCostParams.self,
        "usage.summary": UsageParams.self,
        "watchdog.dismiss": IdParams.self,
        "watchdog.list": Empty.self,
        "work.accept": AcceptWorkParams.self,
        "work.addTask": AddWorkTaskParams.self,
        "work.configure": ConfigureWorkParams.self,
        "work.createPR": WorkPrParams.self,
        "work.fitCheck": FitCheckParams.self,
        "work.get": WorkGetParams.self,
        "work.job": WorkJobParams.self,
        "work.land": WorkLandParams.self,
        "work.landing": ProjectParams.self,
        "work.list": Empty.self,
        "work.playbooks": ProjectParams.self,
        "work.updateTask": UpdateWorkTaskParams.self,
    ]
    /// What each method answers.
    public static let results: [String: any (Codable & Sendable).Type] = [
        "aboutMe.get": MemoryResult.self,
        "aboutMe.set": Empty.self,
        "aboutMe.undo": Empty.self,
        "agents.conversations": AgentPeopleResult.self,
        "agents.create": CreateSessionResult.self,
        "agents.decide": AgentsDecideResult.self,
        "agents.deploy": AgentsDeployResult.self,
        "agents.export": AgentsExportResult.self,
        "agents.files": AgentFilesResult.self,
        "agents.files.add": AgentFilesAdded.self,
        "agents.files.delete": Empty.self,
        "agents.files.note": AgentFile.self,
        "agents.get": AgentGetResult.self,
        "agents.memory": AgentMemoryResult.self,
        "agents.move": AgentMoveResult.self,
        "agents.pause": Empty.self,
        "agents.retire": Empty.self,
        "agents.runNow": AgentRunNowResult.self,
        "agents.runs": AgentRunsResult.self,
        "agents.save": AgentSaveResult.self,
        "agents.status": AgentsStatusResult.self,
        "agents.templates": AgentTemplatesResult.self,
        "agents.trace": AgentTrace.self,
        "agents.triggers": AgentsTriggersResult.self,
        "agents.undo": Empty.self,
        "apps.allow": AppResult.self,
        "apps.close": Empty.self,
        "apps.conversation": AppConversationResult.self,
        "apps.open": AppResult.self,
        "apps.refresh": AppResult.self,
        "apps.revoke": AppResult.self,
        "apps.undo": AppResult.self,
        "automations.add": AutomationResult.self,
        "automations.dismissMigrationReport": Empty.self,
        "automations.get": AutomationDetail.self,
        "automations.list": AutomationsResult.self,
        "automations.migrationReport": MigrationReport.self,
        "automations.remove": Empty.self,
        "automations.restore": AutomationResult.self,
        "automations.run": AutomationRunResult.self,
        "automations.runs": AutomationsRunsResult.self,
        "automations.update": AutomationResult.self,
        "browser.setSite": Empty.self,
        "browser.sites": BrowserSitesResult.self,
        "catalog.search": SearchResults.self,
        "cloud.connect": CloudStatus.self,
        "cloud.disconnect": Empty.self,
        "cloud.setup": CloudSetupResult.self,
        "cloud.status": CloudStatus.self,
        "cloud.update": CloudStatus.self,
        "connectors.calendars": ConnectorCalendarsResult.self,
        "connectors.cancel": Empty.self,
        "connectors.configure": Empty.self,
        "connectors.connect": ProviderLoginResult.self,
        "connectors.disconnect": Empty.self,
        "connectors.list": ConnectorsListResult.self,
        "connectors.setCalendar": Empty.self,
        "endpoints.check": EndpointCheckResult.self,
        "endpoints.detect": EndpointsDetectResult.self,
        "endpoints.remove": Empty.self,
        "endpoints.save": EndpointSaveResult.self,
        "engine.hello": HelloResult.self,
        "engine.shutdown": Empty.self,
        "engine.status": EngineStatusResult.self,
        "git.branches": GitBranchesResult.self,
        "git.checkout": Empty.self,
        "git.commit": GitCommitResult.self,
        "git.log": GitLogResult.self,
        "git.message": GitMessageResult.self,
        "git.status": GitStatus.self,
        "git.suggestBranch": SuggestBranchResult.self,
        "git.sync": GitSyncResult.self,
        "github.clone": GitHubCloneResult.self,
        "github.repos": GitHubReposResult.self,
        "github.setToken": GitHubLogin.self,
        "github.signOut": Empty.self,
        "github.status": GitHubStatus.self,
        "home.agenda": HomeAgenda.self,
        "hooks.delete": Empty.self,
        "hooks.importClaude": HookImportResult.self,
        "hooks.list": HooksResult.self,
        "hooks.save": HookPathResult.self,
        "hooks.toggle": HookPathResult.self,
        "hooks.try": HookTryResult.self,
        "inbox.list": InboxListResult.self,
        "inbox.read": Empty.self,
        "learn.answer": Empty.self,
        "learn.save": LearnSaveResult.self,
        "library.add": LibraryEntryResult.self,
        "library.list": LibraryList.self,
        "library.pin": Empty.self,
        "library.relocate": LibraryEntryResult.self,
        "library.remove": Empty.self,
        "library.reorder": Empty.self,
        "library.restore": Empty.self,
        "library.saved": LibrarySavedResult.self,
        "library.visual": LibraryVisual.self,
        "mcp.add": Empty.self,
        "mcp.detect": McpDetectResult.self,
        "mcp.list": McpListResult.self,
        "mcp.probe": McpProbe.self,
        "mcp.remove": Empty.self,
        "mcp.setChat": Empty.self,
        "mcp.setEnabled": Empty.self,
        "mcp.setTool": Empty.self,
        "mcp.status": McpProbe.self,
        "memory.add": Empty.self,
        "memory.banks": MemoryBanksResult.self,
        "memory.export": MemoryExportResult.self,
        "memory.forget": Empty.self,
        "memory.history": MemoryHistoryResult.self,
        "memory.list": MemoryListResult.self,
        "memory.recall": MemoryRecallResult.self,
        "memory.reindex": MemoryReindexResult.self,
        "memory.setLearning": Empty.self,
        "memory.status": MemoryStatus.self,
        "memory.tools": MemoryToolsResult.self,
        "memory.update": Empty.self,
        "memory.wipe": MemoryCountResult.self,
        "models.list": ModelsListResult.self,
        "models.onDevice": OnDeviceStatus.self,
        "packages.install": Empty.self,
        "packages.list": PackagesResult.self,
        "packages.preview": PackagePreview.self,
        "packages.remove": Empty.self,
        "packages.setEnabled": Empty.self,
        "packages.setResource": Empty.self,
        "packages.update": Empty.self,
        "projects.add": ProjectsAddResult.self,
        "projects.configure": ProjectsAddResult.self,
        "projects.create": ProjectsAddResult.self,
        "projects.files": FilesResult.self,
        "projects.list": ProjectsListResult.self,
        "projects.listDir": ListDirResult.self,
        "projects.readFile": ReadFileResult.self,
        "projects.remove": Empty.self,
        "projects.writeFile": Empty.self,
        "providers.answer": Empty.self,
        "providers.cancelLogin": Empty.self,
        "providers.list": ProvidersListResult.self,
        "providers.login": ProviderLoginResult.self,
        "providers.logout": Empty.self,
        "providers.models": ProviderModelsResult.self,
        "providers.saveKey": Empty.self,
        "providers.setHidden": Empty.self,
        "providers.verifyKey": ProviderVerifyResult.self,
        "secrets.changed": Empty.self,
        "sessions.abort": Empty.self,
        "sessions.agentDraft": AgentDraftResult.self,
        "sessions.changes": ChangesResult.self,
        "sessions.commands": CommandsResult.self,
        "sessions.compact": Empty.self,
        "sessions.configure": Empty.self,
        "sessions.continueIn": CreateSessionResult.self,
        "sessions.create": CreateSessionResult.self,
        "sessions.decide": SessionsDecideResult.self,
        "sessions.delete": Empty.self,
        "sessions.diff": DiffResult.self,
        "sessions.edit": Empty.self,
        "sessions.export": ExportResult.self,
        "sessions.finish": Empty.self,
        "sessions.fork": CreateSessionResult.self,
        "sessions.keep": Empty.self,
        "sessions.list": ListSessionsResult.self,
        "sessions.navigate": NavigateResult.self,
        "sessions.open": Snapshot.self,
        "sessions.pr.address": Empty.self,
        "sessions.pr.create": PrResult.self,
        "sessions.pr.draft": PrDraft.self,
        "sessions.pr.get": PrResult.self,
        "sessions.processOutput": ProcessOutputResult.self,
        "sessions.processStop": SessionsProcessStopResult.self,
        "sessions.queue.remove": Empty.self,
        "sessions.regenerate": Empty.self,
        "sessions.rename": Empty.self,
        "sessions.respond": Empty.self,
        "sessions.restore": RestoreResult.self,
        "sessions.review": CreateSessionResult.self,
        "sessions.reviewFinding": Empty.self,
        "sessions.rewind": RewindResult.self,
        "sessions.side.answer": AnswerSideResult.self,
        "sessions.side.start": CreateSessionResult.self,
        "sessions.submit": SubmitResult.self,
        "sessions.subscribe": SubscribeResult.self,
        "sessions.switchBranch": Empty.self,
        "sessions.tree": TreeResult.self,
        "sessions.unsubscribe": Empty.self,
        "settings.get": EngineSettings.self,
        "settings.set": EngineSettings.self,
        "skills.delete": Empty.self,
        "skills.get": SkillResult.self,
        "skills.list": SkillsResult.self,
        "skills.save": SkillSaveResult.self,
        "stats.activity": ActivityResult.self,
        "stats.budget.release": PiopioBudget.self,
        "stats.budget.set": PiopioBudget.self,
        "stats.budgets": Budgets.self,
        "stats.export": SpendExport.self,
        "stats.items": SpendItems.self,
        "stats.setup": SetupResult.self,
        "stats.spend": SpendResult.self,
        "stats.storage": StorageResult.self,
        "stats.storage.clean": StorageCleanResult.self,
        "subagents.delete": Empty.self,
        "subagents.get": SubagentResult.self,
        "subagents.list": SubagentsResult.self,
        "subagents.save": SubagentSaveResult.self,
        "usage.extras": ExtraCostSummary.self,
        "usage.summary": UsageSummary.self,
        "watchdog.dismiss": Empty.self,
        "watchdog.list": WatchdogListResult.self,
        "work.accept": WorkResult.self,
        "work.addTask": WorkAddTaskResult.self,
        "work.configure": WorkResult.self,
        "work.createPR": PrResult.self,
        "work.fitCheck": FitCheck.self,
        "work.get": WorkGetResult.self,
        "work.job": WorkJob.self,
        "work.land": WorkLandResult.self,
        "work.landing": WorkLanding.self,
        "work.list": WorkListResult.self,
        "work.playbooks": PlaybooksResult.self,
        "work.updateTask": Empty.self,
    ]
    /// What each notification carries.
    public static let notifications: [String: any (Codable & Sendable).Type] = [
        "apps.data": AppResult.self,
        "automations.changed": Empty.self,
        "budget.changed": BudgetChanged.self,
        "catalog.changed": CatalogChanged.self,
        "connectors.auth": ConnectorAuthNotification.self,
        "connectors.changed": Empty.self,
        "inbox.changed": InboxChanged.self,
        "library.changed": Empty.self,
        "projects.changed": ProjectsChanged.self,
        "providers.auth": ProviderAuthNotification.self,
        "providers.changed": Empty.self,
        "session.attention": SessionAttention.self,
        "session.events": SessionEventsNotification.self,
        "watchdog.changed": Empty.self,
        "work.changed": WorkChangedNotification.self,
    ]
    /// What each request from the engine to the app carries.
    public static let reverseParams: [String: any (Codable & Sendable).Type] = [
        "app.tool": AppToolParams.self,
        "secrets.delete": SecretsDeleteParams.self,
        "secrets.get": SecretsGetParams.self,
        "secrets.set": SecretsSetParams.self,
    ]
    /// What the app answers each request from the engine with.
    public static let reverseResults: [String: any (Codable & Sendable).Type] = [
        "app.tool": AppToolResult.self,
        "secrets.delete": Empty.self,
        "secrets.get": SecretsGetResult.self,
        "secrets.set": Empty.self,
    ]
}
