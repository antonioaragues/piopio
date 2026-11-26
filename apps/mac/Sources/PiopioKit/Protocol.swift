import Foundation

// The engine protocol's types are generated (Protocol.generated.swift, from packages/protocol/src/index.ts; see
// docs/spec/03-engine-protocol.md, "Swift types"). This file holds what the schema can't say: computed helpers,
// convenience initializers, and the app's own types around the protocol.

public let protocolVersion = "1.0"
public let secretOpenRouter = "provider.openrouter.apiKey"

extension ContainerRef {
    /// Unique per conversation: a Space topic is "<space>/<topic>", everything else its id.
    public var key: String { conversationId.map { "\(id)/\($0)" } ?? id }
}

extension AssistantPart {
    /// Its text, whether an answer or thinking.
    public var text: String {
        switch self {
        case .text(let text): text
        case .thinking(let text, _): text
        }
    }
    public var isThinking: Bool { if case .thinking = self { true } else { false } }
    /// The part with `delta` added to its text (a streamed answer's next words).
    public func appending(_ delta: String) -> AssistantPart {
        switch self {
        case .text(let text): .text(text + delta)
        case .thinking(let text, let redacted): .thinking(text: text + delta, redacted: redacted)
        }
    }
}

extension AssistantItem {
    /// The answer's text, without its thinking.
    public var text: String { parts.filter { !$0.isThinking }.map(\.text).joined() }
}

extension TimelineItem: Identifiable {
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

extension SessionSummary: Identifiable {
    public var id: String { ref.key }
    /// Listed with the project's conversations: yours, all with Piopio; helpers' sessions are reached from their tasks.
    public var listed: Bool { parent == nil && helper == nil }
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

extension Attachment {
    public var name: String {
        switch self {
        case .image(let name, _, _, _), .text(let name, _, _, _): name
        }
    }
}

extension LearnItem: Identifiable {
    public var id: String { "\(to.rawValue):\(name ?? ""):\(text)" }
}

extension HookInfo: Identifiable { public var id: String { path } }
extension SkillInfo: Identifiable { public var id: String { path } }
extension CustomSubagentInfo: Identifiable { public var id: String { path } }
extension FileChange: Identifiable { public var id: String { path } }
extension AgentPerson: Identifiable { public var id: String { contactId } }
extension AgentFile: Identifiable { public var id: String { name } }
extension WorkInfo: Identifiable { public var id: String { project } }
extension GitHubRepo: Identifiable { public var id: String { fullName } }
extension GitCommitFile: Identifiable { public var id: String { path } }
extension GitCommit: Identifiable { public var id: String { hash } }
extension GitFile: Identifiable { public var id: String { path } }
extension GitBranch: Identifiable { public var id: String { name } }
extension FileMatch: Identifiable { public var id: String { path } }
extension DirEntry: Identifiable { public var id: String { path } }
extension TreeNode: Identifiable { public var id: String { entryId } }
extension SessionCommand: Identifiable { public var id: String { name } }
extension PiPackage: Identifiable { public var id: String { source } }
extension SpendDay: Identifiable { public var id: String { day } }
extension SpendItem: Identifiable { public var id: String { ref.key } }
extension PiopioBudget.Held: Identifiable { public var id: String { run } }
extension ExtraCostSummary.Breakdown: Identifiable { public var id: String { kind } }
extension MemoryBanksResult.Bank: Identifiable { public var id: String { bank } }
extension McpDetectResult.Found: Identifiable { public var id: String { app } }
extension McpDetectResult.Found.Server: Identifiable { public var id: String { name } }
extension McpServerInfo: Identifiable { public var id: String { "\(scope.rawValue):\(name)" } }

extension SearchResult: Identifiable {
    public var id: String { "\(ref.kind.rawValue)/\(ref.key)/\(itemId ?? "title")" }
}

extension ApprovalMode: Identifiable {
    public var id: String { rawValue }
}

extension Automation {
    public var isPiopio: Bool { runsAs == "piopio" }

    /// One the app holds before the engine has it (the New automation draft): the engine's words come from the app.
    public init(id: String, name: String, on: AutomationTrigger, runsAs: String, prompt: String, result: AutomationDelivery, approval: AutomationApproval, by: String = "you", createdAt: String = "",
                cron: String? = nil, at: Double? = nil, folder: String? = nil, from: String? = nil, subject: String? = nil, project: String? = nil,
                budgetPerRunUsd: Double? = nil, enabled: Bool = false, next: Double? = nil, label: String, runnerName: String, resultLabel: String) {
        self.init(id: id, name: name, on: on, cron: cron, at: at, folder: folder, from: from, subject: subject, runsAs: runsAs, project: project, prompt: prompt,
                  result: result, approval: approval, budgetPerRunUsd: budgetPerRunUsd, enabled: enabled, by: by, createdAt: createdAt, next: next, runCount: 0,
                  label: label, runnerName: runnerName, resultLabel: resultLabel)
    }
}

extension EngineSettings.Memory {
    public var searchesByMeaning: Bool { localOnly != true && (semantic ?? false) }
}

extension ModelInfo {
    public var ref: ModelRef { ModelRef(provider: provider, id: id) }
    public var isAgent: Bool { agent == true }
}

extension ProviderInfo {
    public var isAgent: Bool { kind == .agent }
    public var isConnected: Bool { status == .connected || status == .needsAttention }
}

extension SubmitParams {
    public init(ref: ContainerRef, text: String, attachments: [Attachment] = [], whenBusy: WhenBusy? = nil, clientRequestId: String? = nil) {
        self.init(ref: ref, input: Input(text: text, attachments: attachments.isEmpty ? nil : attachments), whenBusy: whenBusy, clientRequestId: clientRequestId)
    }
}

/// What the engine tells the app unasked, as the app's controllers take it.
public enum ProviderNotification: Sendable { case auth(ProviderAuthNotification), changed, connectorAuth(ConnectorAuthNotification), connectorsChanged, workChanged, watchdogChanged, automationsChanged, libraryChanged, appData(AppView), budgetChanged(BudgetChanged) }

extension PresentedFile {
    /// It wasn't where the agent said (the card says so, and doesn't open it).
    public var isMissing: Bool { missing == true }
}
