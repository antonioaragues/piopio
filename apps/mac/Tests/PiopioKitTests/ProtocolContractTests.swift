import Foundation
import Testing
@testable import PiopioKit

// The engine's protocol against the app's Swift types (re-audit 2026-11-25: 221 methods and their Swift types, kept in
// step by hand, with nothing checking them). packages/protocol/schema/protocol.samples.json holds samples of everything
// the engine may send (packages/protocol/src/samples.ts: the required fields only, and every field across each union's
// branches). Each one must decode into the Swift type the app reads it as, with the app's decoder.
//
// When a sample fails:
// - keyNotFound: Swift requires a field the engine may leave out. Make it optional in Protocol.swift (or make the
//   engine always send it, in packages/protocol, if it always does).
// - dataCorrupted on an enum: the engine sends a value Swift's enum doesn't have. Add the case.
// - typeMismatch: the two sides disagree on a type. Fix the side that's wrong.
// When "the app calls ... but this table doesn't list it": add `"method": Type.self`, the type in that call's `as:`.
// Don't loosen the check or drop a sample to make it pass: each failure is a decode the app would fail at run time.

/// Each method the app calls, and the type it decodes the result as (the `as:` of its `client.call`).
let contractResults: [String: any Decodable.Type] = [
    "aboutMe.get": MemoryResult.self,
    "aboutMe.set": Empty.self,
    "agents.conversations": AgentPeopleResult.self,
    "agents.create": CreateSessionResult.self,
    "agents.decide": JSONValue.self,
    "agents.files": AgentFilesResult.self,
    "agents.files.add": AgentFilesAdded.self,
    "agents.get": AgentGetResult.self,
    "agents.memory": AgentMemoryResult.self,
    "agents.move": AgentMoveResult.self,
    "agents.runNow": AgentRunNowResult.self,
    "agents.runs": AgentRunsResult.self,
    "agents.save": AgentSaveResult.self,
    "agents.templates": AgentTemplatesResult.self,
    "agents.trace": AgentTrace.self,
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
    "automations.update": AutomationResult.self,
    "browser.setSite": Empty.self,
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
    "hooks.importClaude": HookImportResult.self,
    "hooks.list": HooksResult.self,
    "hooks.save": HookPathResult.self,
    "hooks.toggle": HookPathResult.self,
    "hooks.try": HookTryResult.self,
    "inbox.list": InboxListResult.self,
    "inbox.read": Empty.self,
    "learn.save": LearnSaveResult.self,
    "library.add": LibraryEntryResult.self,
    "library.list": LibraryList.self,
    "library.pin": Empty.self,
    "library.relocate": LibraryEntryResult.self,
    "library.remove": Empty.self,
    "library.reorder": Empty.self,
    "library.restore": Empty.self,
    "library.saved": Empty.self,
    "library.visual": LibraryVisual.self,
    "mcp.add": Empty.self,
    "mcp.detect": McpDetectResult.self,
    "mcp.list": McpListResult.self,
    "mcp.probe": McpProbe.self,
    "mcp.remove": Empty.self,
    "mcp.status": McpProbe.self,
    "memory.add": Empty.self,
    "memory.banks": MemoryBanksResult.self,
    "memory.export": MemoryExportResult.self,
    "memory.forget": Empty.self,
    "memory.history": MemoryHistoryResult.self,
    "memory.list": MemoryListResult.self,
    "memory.recall": MemoryRecallResult.self,
    "memory.reindex": MemoryCountResult.self,
    "memory.setLearning": Empty.self,
    "memory.status": MemoryStatus.self,
    "memory.tools": MemoryToolsResult.self,
    "memory.update": Empty.self,
    "memory.wipe": MemoryCountResult.self,
    "models.list": ModelsListResult.self,
    "models.onDevice": OnDeviceStatus.self,
    "packages.list": PackagesResult.self,
    "packages.preview": PackagePreview.self,
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
    "sessions.configure": Empty.self,
    "sessions.continueIn": CreateSessionResult.self,
    "sessions.create": CreateSessionResult.self,
    "sessions.decide": JSONValue.self,
    "sessions.delete": Empty.self,
    "sessions.diff": DiffResult.self,
    "sessions.edit": JSONValue.self,
    "sessions.export": ExportResult.self,
    "sessions.finish": Empty.self,
    "sessions.fork": CreateSessionResult.self,
    "sessions.keep": Empty.self,
    "sessions.list": ListSessionsResult.self,
    "sessions.open": Snapshot.self,
    "sessions.pr.address": Empty.self,
    "sessions.pr.create": PrResult.self,
    "sessions.pr.draft": PrDraft.self,
    "sessions.pr.get": PrResult.self,
    "sessions.processOutput": ProcessOutputResult.self,
    "sessions.rename": Empty.self,
    "sessions.restore": RestoreResult.self,
    "sessions.review": CreateSessionResult.self,
    "sessions.rewind": RewindResult.self,
    "sessions.side.answer": AnswerSideResult.self,
    "sessions.side.start": CreateSessionResult.self,
    "sessions.submit": SubmitResult.self,
    "sessions.subscribe": SubscribeResult.self,
    "sessions.unsubscribe": Empty.self,
    "settings.get": EngineSettings.self,
    "settings.set": EngineSettings.self,
    "skills.get": SkillResult.self,
    "skills.list": SkillsResult.self,
    "skills.save": SkillSaveResult.self,
    "subagents.get": SubagentResult.self,
    "subagents.list": SubagentsResult.self,
    "subagents.save": SubagentSaveResult.self,
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
    "usage.extras": ExtraCostSummary.self,
    "usage.summary": UsageSummary.self,
    "watchdog.dismiss": Empty.self,
    "watchdog.list": WatchdogListResult.self,
    "work.accept": WorkResult.self,
    "work.addTask": Empty.self,
    "work.configure": WorkResult.self,
    "work.createPR": PrResult.self,
    "work.fitCheck": FitCheck.self,
    "work.job": WorkJob.self,
    "work.land": WorkLandResult.self,
    "work.landing": WorkLanding.self,
    "work.list": WorkListResult.self,
    "work.playbooks": PlaybooksResult.self,
    "work.updateTask": Empty.self,
]

/// Methods the app reads with a type this target can't see (the app's own module), or not at all.
let contractResultsElsewhere: Set<String> = ["browser.sites"]

/// Notifications the app decodes (EngineClient.ingest). The others carry nothing it reads: a signal to list again.
let contractNotifications: [String: any Decodable.Type] = [
    "session.events": SessionEventsNotification.self,
    "catalog.changed": CatalogChanged.self,
    "session.attention": SessionAttention.self,
    "inbox.changed": InboxChanged.self,
    "providers.auth": ProviderAuthNotification.self,
    "connectors.auth": ConnectorAuthNotification.self,
    "apps.data": AppResult.self,
    "budget.changed": BudgetChanged.self,
    "projects.changed": ProjectsChanged.self,
]

/// The protocol's own types, decoded wherever they appear.
let contractTypes: [String: any Decodable.Type] = [
    "ContainerRef": ContainerRef.self,
    "TimelineItem": TimelineItem.self,
    "SessionState": SessionState.self,
    "SessionEvent": SessionEvent.self,
    "Snapshot": Snapshot.self,
    "SessionSummary": SessionSummary.self,
    "ModelInfo": ModelInfo.self,
]

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func samples() throws -> [String: [JSONValue]] {
    let data = try Data(contentsOf: repository.appending(path: "packages/protocol/schema/protocol.samples.json"))
    return try JSONDecoder().decode([String: [JSONValue]].self, from: data)
}

/// Why each sample of `name` doesn't decode as `type`, one line each.
private func failures(_ name: String, _ type: any Decodable.Type, _ all: [String: [JSONValue]]) throws -> [String] {
    guard let values = all[name] else { return ["\(name): not in the protocol's samples (is the engine's name right?)"] }
    var out: [String] = []
    for (i, value) in values.enumerated() {
        let data = try JSONEncoder().encode(value)
        do { _ = try JSONDecoder().decode(type, from: data) } catch { out.append("\(name) sample \(i) as \(type): \(error)") }
    }
    return out
}

@Test func everyResultTheAppReadsDecodesFromEverySample() throws {
    let all = try samples()
    let problems = try contractResults.sorted { $0.key < $1.key }.flatMap { try failures("\($0.key).result", $0.value, all) }
    #expect(problems.isEmpty, "\(problems.count) samples don't decode:\n\(problems.prefix(40).joined(separator: "\n"))")
}

@Test func everyNotificationTheAppReadsDecodesFromEverySample() throws {
    let all = try samples()
    let problems = try contractNotifications.sorted { $0.key < $1.key }.flatMap { try failures("\($0.key).notification", $0.value, all) }
        + contractTypes.sorted { $0.key < $1.key }.flatMap { try failures($0.key, $0.value, all) }
    #expect(problems.isEmpty, "\(problems.count) samples don't decode:\n\(problems.prefix(40).joined(separator: "\n"))")
}

/// The table is the app's calls: every `client.call("m", …, as: T.self)` in the app's sources is listed, with T.
@Test func theTableListsEveryCallTheAppMakes() throws {
    let pattern = try NSRegularExpression(pattern: #"call\("([A-Za-z.]+)",[^\n]*?as: ([A-Za-z0-9_.]+)\.self"#)
    var problems: [String] = []
    let all = try samples()
    for folder in ["apps/mac/App", "apps/mac/Sources"] {
        let files = FileManager.default.enumerator(at: repository.appending(path: folder), includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let method = String(text[Range(match.range(at: 1), in: text)!])
                let type = String(text[Range(match.range(at: 2), in: text)!])
                if all["\(method).result"] == nil { problems.append("\(file.lastPathComponent) calls \(method), which the engine's protocol doesn't have"); continue }
                if contractResultsElsewhere.contains(method) { continue }
                guard let listed = contractResults[method] else { problems.append("\(file.lastPathComponent) calls \(method) as \(type), but this table doesn't list it"); continue }
                if String(describing: listed).split(separator: ".").last.map(String.init) != type.split(separator: ".").last.map(String.init) {
                    problems.append("\(file.lastPathComponent) reads \(method) as \(type); the table says \(listed)")
                }
            }
        }
    }
    #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
}

/// How long the app waits for an answer is the protocol's (packages/protocol/src/index.ts SLOW_METHODS): the limits and
/// the slow methods here are the schema's.
@Test func callTimeoutsAreTheProtocols() throws {
    struct Timeouts: Decodable { let defaultMs: Int; let slowMs: Int; let slowMethods: [String] }
    struct Schema: Decodable {
        let timeouts: Timeouts
        enum CodingKeys: String, CodingKey { case timeouts = "x-callTimeouts" }
    }
    let data = try Data(contentsOf: repository.appending(path: "packages/protocol/schema/protocol.schema.json"))
    let t = try JSONDecoder().decode(Schema.self, from: data).timeouts
    #expect(EngineClient.callTimeout == .milliseconds(t.defaultMs))
    #expect(EngineClient.slowCallTimeout == .milliseconds(t.slowMs))
    #expect(EngineClient.slowMethods == Set(t.slowMethods))
}
