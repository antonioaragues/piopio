import AppKit
import Observation
import PiopioKit
import ServiceManagement

/// Owns the Local Engine: starts it (or attaches to a running one), answers its secret requests from the
/// Keychain, mirrors the session catalog, and fans out session events to open threads.
@Observable @MainActor
final class EngineController {
    enum Status: Equatable { case starting, ready, failed(String) }

    private(set) var status: Status = .starting
    private(set) var threads: [SessionSummary] = []
    /// Chat: Spaces, with their topics (docs/spec/04-chat §3).
    private(set) var spaces: [SessionSummary] = []
    /// Agents (docs/spec/06-agents).
    private(set) var agents: [SessionSummary] = []
    /// Build: folders added as projects, and their sessions (newest first).
    private(set) var projects: [ProjectInfo] = []
    private(set) var buildSessions: [SessionSummary] = []
    private(set) var models: [ModelInfo] = []
    private(set) var defaultModel: ModelRef?
    private(set) var hasKey = Keychain.read(secretOpenRouter) != nil
    /// Model providers and how each is connected (docs/spec/10-model-providers).
    private(set) var providers: [ProviderInfo] = []
    /// The sign-in in progress (Settings › Models shows it as a sheet).
    var login: ProviderLogin?
    /// The engine has worked in this run (so a failure now is a crash, shown as a banner).
    private(set) var wasReady = false
    /// Latest session status per open thread (sidebar status dots).
    var liveStatus: [String: SessionStatus] = [:]
    var isLost: Bool { if case .failed = status { wasReady } else { false } }
    /// Scripted echo model instead of OpenRouter (`PIOPIO_FAUX=1`), for development.
    let faux = ProcessInfo.processInfo.environment["PIOPIO_FAUX"] == "1"

    @ObservationIgnored private(set) var client: EngineClient?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var openThreads: [String: ThreadModel] = [:]
    @ObservationIgnored private var handlers: [String: ([SessionEvent]) -> Void] = [:]
    @ObservationIgnored private var orphans: [String: [[SessionEvent]]] = [:]

    let home = EngineClient.defaultHome()
    private var socket: URL { home.appending(path: "engine.sock") }

    var needsKey: Bool { !faux && !hasKey && !providers.contains(where: \.isConnected) }

    // MARK: Lifecycle

    func start() async {
        status = .starting
        do {
            try FileManager.default.createDirectory(at: home.appending(path: "logs"), withIntermediateDirectories: true)
            var hello = try await connect()
            if hello == nil {
                // In background mode launchd owns the engine: wait for it instead of starting a second one.
                if runsInBackground {
                    if Self.agent.status == .requiresApproval {
                        throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Allow Piopio in System Settings › General › Login Items, or turn off background mode in Settings › Engines.")
                    }
                } else {
                    try launchEngine()
                }
                for _ in 0..<100 where hello == nil {
                    try await Task.sleep(for: .milliseconds(100))
                    hello = try await connect()
                }
                guard hello != nil else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine did not start. See \(home.path)/logs/engine.log") }
            }
            // After an app update, a background engine still runs the old version: restart it once.
            if let hello, runsInBackground, let bundled = Self.bundledEngineVersion, hello.version != bundled, !restartedStale {
                restartedStale = true
                let old = client
                client = nil
                await old?.close()
                restartBackgroundEngine()
                return
            }
            engineVersion = hello?.version
            try await refreshCatalog()
            try await loadModels()
            await loadProviders()
            status = .ready
            wasReady = true
        } catch {
            status = .failed(String(describing: error))
        }
    }

    func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([home.appending(path: "logs/engine.log")])
    }

    /// Closes the connection; an engine this app started stops with it (a background engine keeps running).
    func stop() {
        stopping = true
        Task { await client?.close() }
        process?.terminate()
        process = nil
    }

    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var restartedStale = false
    private(set) var engineVersion: String?

    // MARK: Background mode

    /// The LaunchAgent that runs the engine after the app quits (docs/spec/02-architecture §3.3).
    static let agent = SMAppService.agent(plistName: "app.piopio.engine.plist")
    private var agentTick = 0

    /// Background mode needs the launcher and engine inside the app (release builds).
    var canRunInBackground: Bool { Self.launcher != nil }
    var runsInBackground: Bool {
        _ = agentTick
        return canRunInBackground && [.enabled, .requiresApproval].contains(Self.agent.status)
    }

    /// Moves the engine between this app (a child process) and launchd. Open threads reconnect.
    func setRunsInBackground(_ on: Bool) async {
        guard on != runsInBackground else { return }
        stopping = true
        await client?.close()
        client = nil
        do {
            if on {
                // One engine per data folder: the child must be gone before launchd starts its own.
                if let p = process {
                    p.terminate()
                    for _ in 0..<50 where p.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                    process = nil
                }
                try Self.agent.register()
                if Self.agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try await Self.agent.unregister()
            }
        } catch {
            status = .failed("Background mode: \(error.localizedDescription)")
        }
        agentTick += 1
        stopping = false
        await start()
    }

    /// Restarts the launchd-managed engine (Restart button, version mismatch).
    private func restartBackgroundEngine() {
        let kickstart = Process()
        kickstart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kickstart.arguments = ["kickstart", "-k", "gui/\(getuid())/app.piopio.engine"]
        try? kickstart.run()
        kickstart.waitUntilExit()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await start()
        }
    }

    /// Starts over after the engine connection drops; open threads re-subscribe when their views reappear.
    private func connectionLost(_ lost: EngineClient) {
        guard !stopping, client === lost else { return }
        client = nil
        handlers = [:]
        orphans = [:]
        for t in openThreads.values { t.close() }
        openThreads = [:]
        if let p = process, !p.isRunning { process = nil }
        Task { await start() }
    }

    /// Connects to a running engine. Returns nil when nothing is listening.
    private func connect() async throws -> HelloResult? {
        guard FileManager.default.fileExists(atPath: socket.path) else { return nil }
        let client = EngineClient(socketPath: socket.path)
        await client.setReverseHandler { method, params in
            // Apple app tools for agents (06-agents §4.1), run with this app's permissions.
            if method == "app.tool" { return await AppleTools.shared.handle(params) }
            // Provider sign-ins and refreshed tokens (docs/spec/10 §10): the Keychain is the store.
            if method == "secrets.set", let name = params["name"]?.stringValue, let value = params["value"]?.stringValue {
                try? Keychain.write(name, value: value)
                return .object([:])
            }
            if method == "secrets.delete", let name = params["name"]?.stringValue {
                Keychain.delete(name)
                return .object([:])
            }
            guard method == "secrets.get", let name = params["name"]?.stringValue else { return .object(["value": .null]) }
            return .object(["value": Keychain.read(name).map(JSONValue.string) ?? .null])
        }
        let hello: HelloResult
        do {
            hello = try await client.connectAndHello(client: "Piopio.app", tokenFile: home.appending(path: "engine.token"), services: ["app.tool", "secrets.set"])
        } catch {
            await client.close()
            return nil
        }
        self.client = client
        Task { [weak self] in
            for await batch in client.sessionEvents { self?.dispatch(batch) }
            // The stream ends when the connection drops (engine crash, sleep, kill): reconnect.
            self?.connectionLost(client)
        }
        Task { [weak self] in
            for await change in client.catalogChanges { self?.applyCatalog(change) }
        }
        Task { [weak self] in
            for await projects in client.projectChanges { self?.projects = projects }
        }
        Task { [weak self] in
            for await change in client.attention { self?.attention(change) }
        }
        Task { [weak self] in
            for await change in client.inboxChanges {
                guard let self else { return }
                self.inboxCount = change.count
                if let a = change.approval { Notifier.shared.approval(agent: a.agent, agentName: a.agentName, approvalId: a.approvalId, title: a.title) }
                await self.loadInbox()
            }
        }
        Task { [weak self] in await self?.loadInbox() }
        Task { [weak self] in
            for await note in client.providerEvents {
                guard let self else { return }
                switch note {
                case .changed:
                    await self.loadProviders()
                    try? await self.loadModels()
                case .auth(let auth):
                    if self.login?.loginId == auth.loginId { self.login?.apply(auth.event) }
                }
            }
        }
        Task { [weak self] in
            // Spend (sidebar footer, Home): now, then every few minutes.
            while let self, self.client != nil {
                await self.loadUsage()
                try? await Task.sleep(for: .seconds(180))
            }
        }
        return hello
    }

    private func launchEngine() throws {
        let p = Process()
        if let custom = Self.customEngine {
            // Dev setting: `defaults write app.piopio.Piopio customEnginePath /path/to/engine/dist/main.js`.
            guard let node = Self.nodeExecutable() else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Node.js ≥ 22.19 not found for the custom engine.") }
            p.executableURL = node
            p.arguments = [custom.path]
        } else if let launcher = Self.launcher {
            p.executableURL = launcher
        } else {
            guard let main = Self.engineMain() else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Engine not found. Build it with `pnpm build`.") }
            guard let node = Self.nodeExecutable() else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Node.js ≥ 22.19 not found (looked in /opt/homebrew/bin, /usr/local/bin).") }
            p.executableURL = node
            p.arguments = [main.path]
        }
        var env = ProcessInfo.processInfo.environment
        env["PIOPIO_HOME"] = home.path
        p.environment = env
        let log = home.appending(path: "logs/engine.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            p.standardError = handle
            p.standardOutput = handle
        }
        try p.run()
        process = p
    }

    /// Contents/MacOS/piopio-engine, present when the engine is bundled (release builds).
    private static var launcher: URL? {
        guard Bundle.main.url(forResource: "main", withExtension: "js", subdirectory: "engine") != nil else { return nil }
        return Bundle.main.url(forAuxiliaryExecutable: "piopio-engine")
    }

    private static var bundledEngineVersion: String? {
        launcher == nil ? nil : Bundle.main.object(forInfoDictionaryKey: "PiopioEngineVersion") as? String
    }

    private static var customEngine: URL? {
        guard let path = UserDefaults.standard.string(forKey: "customEnginePath"), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The repo's engine in dev builds.
    private static func engineMain() -> URL? {
        if let path = Bundle.main.object(forInfoDictionaryKey: "PiopioEngineMain") as? String, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return nil
    }

    private static func nodeExecutable() -> URL? {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/node")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: Catalog

    func refreshCatalog() async throws {
        guard let client else { return }
        threads = try await client.call("sessions.list", ListSessionsParams(kind: .thread), as: ListSessionsResult.self).sessions
        buildSessions = try await client.call("sessions.list", ListSessionsParams(kind: .build), as: ListSessionsResult.self).sessions
        spaces = try await client.call("sessions.list", ListSessionsParams(kind: .space), as: ListSessionsResult.self).sessions
        agents = try await client.call("sessions.list", ListSessionsParams(kind: .agent), as: ListSessionsResult.self).sessions
        if settings == nil { await loadSettings() }
        projects = try await client.call("projects.list", Empty(), as: ProjectsListResult.self).projects
    }

    private func applyCatalog(_ change: CatalogChanged) {
        let removed = Set(change.removed.map(\.id))
        func merged(_ list: [SessionSummary], kind: ContainerKind) -> [SessionSummary] {
            var next = list.filter { !removed.contains($0.ref.id) }
            for s in change.upserted where s.ref.kind == kind {
                if let i = next.firstIndex(where: { $0.ref.id == s.ref.id }) { next[i] = s } else { next.append(s) }
            }
            return next.sorted { $0.updatedAt > $1.updatedAt }
        }
        threads = merged(threads, kind: .thread)
        buildSessions = merged(buildSessions, kind: .build)
        spaces = merged(spaces, kind: .space)
        agents = merged(agents, kind: .agent)
        for id in removed { forget(id) }
    }

    // MARK: Projects

    /// Adds a folder as a project; its pi sessions are imported by the engine.
    func addProject(_ url: URL, lens: ProjectInfo.Lens? = nil) async -> ProjectInfo? {
        guard let client else { return nil }
        do {
            let project = try await client.call("projects.add", ProjectsAddParams(path: url.path, lens: lens), as: ProjectsAddResult.self).project
            try await refreshCatalog()
            return project
        } catch {
            return nil
        }
    }

    /// Projects shown in a mode (04-chat P1).
    func projects(in lens: ProjectInfo.Lens) -> [ProjectInfo] {
        projects.filter { $0.lenses.contains(lens) }
    }

    func setLenses(_ lenses: [ProjectInfo.Lens], for project: ProjectInfo) async {
        _ = try? await client?.call("projects.configure", ProjectsConfigureParams(id: project.id, lenses: lenses), as: ProjectsAddResult.self)
    }

    func listDir(_ cwd: String, _ dir: String) async -> [DirEntry] {
        (try? await client?.call("projects.listDir", ListDirParams(cwd: cwd, dir: dir), as: ListDirResult.self).entries) ?? []
    }

    func removeProject(_ project: ProjectInfo) async {
        _ = try? await client?.call("projects.remove", ProjectsRemoveParams(id: project.id), as: Empty.self)
    }

    func sessions(in project: ProjectInfo) -> [SessionSummary] {
        buildSessions.filter { ($0.projectPath ?? $0.cwd) == project.path }
    }

    func createBuildSession(in project: ProjectInfo, profile: SessionSummary.Profile = .build) async -> ContainerRef? {
        try? await createBuildSession(in: project, workOn: .current, mode: nil, model: nil, profile: profile)
    }

    /// A Build session on the project as it is, a new branch, or its own worktree (docs/design 7a).
    func createBuildSession(in project: ProjectInfo, workOn: WorkOn, mode: ApprovalMode?, model: ModelRef?, profile: SessionSummary.Profile = .build) async throws -> ContainerRef {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine isn't running.") }
        let ref = try await client.call("sessions.create", CreateSessionParams(kind: .build, cwd: project.path, model: model ?? self.model(for: .build), workOn: workOn, approvalMode: mode, profile: profile), as: CreateSessionResult.self).ref
        try? await refreshCatalog()
        return ref
    }

    /// Worktree sessions: merge into the base branch, or discard.
    func finish(_ ref: ContainerRef, _ action: FinishParams.Action) async throws {
        guard let client else { return }
        openThreads[ref.id]?.close()
        openThreads[ref.id] = nil
        _ = try await client.call("sessions.finish", FinishParams(ref: ref, action: action), as: Empty.self)
        try? await refreshCatalog()
    }

    func createThread(model: ModelRef? = nil) async -> ContainerRef? {
        guard let client else { return nil }
        return try? await client.call("sessions.create", CreateSessionParams(kind: .thread, model: model ?? preferredModel), as: CreateSessionResult.self).ref
    }

    func rename(_ ref: ContainerRef, to title: String) async {
        _ = try? await client?.call("sessions.rename", RenameParams(ref: ref, title: title), as: Empty.self)
    }

    func delete(_ ref: ContainerRef) async {
        forget(ref.id)
        _ = try? await client?.call("sessions.delete", RefParams(ref: ref), as: Empty.self)
    }

    /// What a default model is for (Settings › Models, docs/design v2 9a); each stored as "provider/id".
    enum ModelRole: String, CaseIterable, Identifiable {
        case build = "buildModel", chat = "defaultChatModel", quick = "quickChatModel", agent = "agentModel"
        var id: String { rawValue }
    }

    /// The model a new session of that kind starts with: the user's choice, else the chat default, else the engine's.
    func model(for role: ModelRole) -> ModelRef? {
        _ = preferenceTick
        if let raw = UserDefaults.standard.string(forKey: role.rawValue), let i = raw.firstIndex(of: "/") {
            return ModelRef(provider: String(raw[..<i]), id: String(raw[raw.index(after: i)...]))
        }
        return role == .chat ? defaultModel : model(for: .chat)
    }

    func setModel(_ model: ModelRef, for role: ModelRole) {
        UserDefaults.standard.set("\(model.provider)/\(model.id)", forKey: role.rawValue)
        preferenceTick += 1
    }

    /// The model new chats and notebooks start with.
    var preferredModel: ModelRef? { model(for: .chat) }
    func setPreferredModel(_ model: ModelRef) { setModel(model, for: .chat) }

    /// Quick Chat's model (a fast one by choice); defaults to the chat model.
    var quickChatModel: ModelRef? { model(for: .quick) }
    func setQuickChatModel(_ model: ModelRef) { setModel(model, for: .quick) }

    private var preferenceTick = 0

    /// Stops the engine this app started and starts it again.
    func restart() {
        let old = client
        client = nil
        Task { await old?.close() }
        if runsInBackground {
            restartBackgroundEngine()
            return
        }
        process?.terminate()
        process = nil
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await start()
        }
    }

    func model(_ ref: ModelRef?) -> ModelInfo? {
        guard let ref else { return nil }
        return models.first { $0.provider == ref.provider && $0.id == ref.id }
    }

    // MARK: Threads

    func thread(_ ref: ContainerRef) -> ThreadModel {
        if let open = openThreads[ref.key] { return open }
        let t = ThreadModel(ref: ref, engine: self)
        openThreads[ref.key] = t
        return t
    }

    /// Drops the open models of a session (a Space's Main and all its topics).
    private func forget(_ id: String) {
        for key in openThreads.keys where key == id || key.hasPrefix(id + "/") {
            openThreads[key]?.close()
            openThreads[key] = nil
        }
    }

    // MARK: Spaces

    func createSpace(name: String, instructions: String) async -> ContainerRef? {
        guard let client else { return nil }
        let ref = try? await client.call("sessions.create", CreateSessionParams(kind: .space, model: preferredModel, title: name, instructions: instructions.isEmpty ? nil : instructions), as: CreateSessionResult.self).ref
        try? await refreshCatalog()
        return ref
    }

    func space(_ id: String) -> SessionSummary? {
        spaces.first { $0.ref.id == id }
    }

    /// Wrong topic: moves a routed message to another topic, or a new one.
    func reroute(_ ref: ContainerRef, itemId: String, toTopic: String? = nil, newTopic: String? = nil) async throws {
        guard let client else { return }
        _ = try await client.call("spaces.reroute", RerouteParams(ref: ref, itemId: itemId, toTopicId: toTopic, newTopic: newTopic), as: Empty.self)
    }

    func markRead(_ ref: ContainerRef) {
        guard ref.conversationId != nil, space(ref.id)?.topics?.first(where: { $0.id == ref.conversationId })?.unread == true else { return }
        Task { _ = try? await client?.call("spaces.markRead", RefParams(ref: ref), as: Empty.self) }
    }

    func setInstructions(_ instructions: String, for space: ContainerRef) async {
        _ = try? await client?.call("spaces.configure", SpaceConfigureParams(ref: space, instructions: instructions), as: Empty.self)
    }

    /// A Space method without a result (memory, topics, files, settings).
    func spaceCall(_ method: String, _ params: some Encodable & Sendable) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call(method, params, as: Empty.self)
    }

    func memory(of space: ContainerRef) async -> MemoryResult? {
        try? await client?.call("spaces.memory.get", RefParams(ref: space), as: MemoryResult.self)
    }

    func spaceFiles(_ space: ContainerRef) async -> [SpaceFile] {
        (try? await client?.call("spaces.files.list", RefParams(ref: space), as: SpaceFilesResult.self).files) ?? []
    }

    // MARK: Agents

    func agentTemplates() async -> [AgentTemplate] {
        (try? await client?.call("agents.templates", Empty(), as: AgentTemplatesResult.self).templates) ?? []
    }

    func createAgent(name: String, template: String?, avatar: String) async throws -> ContainerRef {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let ref = try await client.call("agents.create", CreateAgentParams(name: name, template: template, avatar: avatar.isEmpty ? nil : avatar, model: model(for: .agent), owner: NSFullUserName().split(separator: " ").first.map(String.init)), as: CreateSessionResult.self).ref
        try? await refreshCatalog()
        return ref
    }

    func agentDefinition(_ ref: ContainerRef) async -> AgentGetResult? {
        try? await client?.call("agents.get", RefParams(ref: ref), as: AgentGetResult.self)
    }

    func saveAgent(_ ref: ContainerRef, definition: JSONValue, instructions: String, message: String) async throws -> AgentSaveResult {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("agents.save", AgentSaveParams(ref: ref, definition: definition, instructions: instructions, message: message.isEmpty ? nil : message), as: AgentSaveResult.self)
    }

    func agentPeople(_ ref: ContainerRef) async -> [AgentPerson] {
        (try? await client?.call("agents.conversations", RefParams(ref: ref), as: AgentPeopleResult.self).people) ?? []
    }

    func agentRuns(_ ref: ContainerRef) async -> AgentRunsResult? {
        try? await client?.call("agents.runs", RefParams(ref: ref), as: AgentRunsResult.self)
    }

    func agentRunNow(_ ref: ContainerRef, scheduleId: String? = nil, prompt: String? = nil) async throws -> String {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("agents.runNow", AgentRunNowParams(ref: ref, scheduleId: scheduleId, prompt: prompt), as: AgentRunNowResult.self).runId
    }

    func agentTriggers(_ ref: ContainerRef) async -> [AgentTriggersResult.Trigger] {
        (try? await client?.call("agents.triggers", RefParams(ref: ref), as: AgentTriggersResult.self).triggers) ?? []
    }

    // MARK: Approvals, Undo, pause and the Inbox (06-agents §4.2, §9, §12)

    /// What waits for you across agents: the sidebar's Inbox count, the Dock badge and the menu bar.
    private(set) var inboxCount = 0 {
        didSet { NSApp.dockTile.badgeLabel = inboxCount > 0 ? "\(inboxCount)" : nil }
    }
    private(set) var inbox: [InboxItem] = []

    func loadInbox() async {
        guard let result = try? await client?.call("inbox.list", Empty(), as: InboxListResult.self) else { return }
        inbox = result.items
        inboxCount = result.count
    }

    /// What the provider has billed (sidebar footer, Home, Settings › Models).
    private(set) var usage: UsageSummary?

    func loadUsage(refresh: Bool = false) async {
        if let u = try? await client?.call("usage.summary", UsageParams(refresh: refresh ? true : nil), as: UsageSummary.self) { usage = u }
    }

    /// Everything that waits for you (docs/design v2 "Needs you"): agents' Inbox items and Build sessions waiting on an approval.
    var needsYouCount: Int {
        inboxCount + buildSessions.filter { liveStatus[$0.ref.id] == .waitingApproval }.count
    }

    func markInboxRead(_ items: [InboxItem]) async {
        let unread = items.filter { !$0.read && $0.approval == nil }
        guard !unread.isEmpty else { return }
        _ = try? await client?.call("inbox.read", InboxReadParams(items: unread.map { .init(agentId: $0.agent.id, id: $0.id) }), as: Empty.self)
        await loadInbox()
    }

    func decide(_ agent: ContainerRef, approvalId: String, approve: Bool, args: JSONValue? = nil, always: Bool = false, reason: String? = nil) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let ref = ContainerRef(kind: .agent, id: agent.id)
        _ = try await client.call("agents.decide", AgentDecideParams(ref: ref, approvalId: approvalId, approve: approve, args: args, always: always ? true : nil, reason: reason), as: JSONValue.self)
        await loadInbox()
    }

    func undo(_ agent: ContainerRef, undoId: String) async throws {
        try await spaceCall("agents.undo", AgentUndoParams(ref: ContainerRef(kind: .agent, id: agent.id), undoId: undoId))
    }

    func trace(_ traceId: String) async throws -> AgentTrace {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("agents.trace", TraceParams(traceId: traceId), as: AgentTrace.self)
    }

    func pause(_ agent: ContainerRef, paused: Bool) async throws {
        try await spaceCall("agents.pause", AgentPauseParams(ref: ContainerRef(kind: .agent, id: agent.id), paused: paused))
    }

    func agentMemory(_ ref: ContainerRef) async -> AgentMemoryResult? {
        try? await client?.call("agents.memory", RefParams(ref: ref), as: AgentMemoryResult.self)
    }

    func memoryList(provider: String, bank: String) async -> MemoryListResult? {
        try? await client?.call("memory.list", MemoryListParams(provider: provider, bank: bank), as: MemoryListResult.self)
    }

    // MARK: Chat settings, About me, moving threads

    /// Engine-wide settings (Settings › Chat, MCP in Chat).
    private(set) var settings: EngineSettings?

    func loadSettings() async {
        settings = try? await client?.call("settings.get", Empty(), as: EngineSettings.self)
    }

    func updateSettings(_ patch: SettingsPatch) async {
        if let next = try? await client?.call("settings.set", patch, as: EngineSettings.self) { settings = next }
    }

    func aboutMe() async -> MemoryResult? {
        try? await client?.call("aboutMe.get", Empty(), as: MemoryResult.self)
    }

    /// Moves threads into a Space: each becomes a topic, or joins `topic`. Returns the topics' ids.
    @discardableResult
    func importThreads(_ threads: [ContainerRef], into space: ContainerRef, topic: String? = nil, keep: Bool = false) async throws -> [String] {
        guard let client else { return [] }
        let ids = try await client.call("spaces.importThreads", ImportThreadsParams(ref: space, threads: threads, topicId: topic, keepThreads: keep), as: ImportThreadsResult.self).topicIds
        if !keep { for t in threads { forget(t.id) } }
        try? await refreshCatalog()
        return ids
    }

    /// Promote to Thread: a copy of the topic as a new thread.
    func promote(_ topic: ContainerRef) async throws -> ContainerRef? {
        guard let client else { return nil }
        let ref = try await client.call("spaces.topics.promote", RefParams(ref: topic), as: CreateSessionResult.self).ref
        try? await refreshCatalog()
        return ref
    }

    func dismissSuggestion(_ thread: ContainerRef) async {
        _ = try? await client?.call("threads.dismissSuggestion", RefParams(ref: thread), as: Empty.self)
    }

    /// Merges a topic into another; returns the summary that joined it.
    func merge(_ topic: ContainerRef, into: String) async throws -> String {
        guard let client else { return "" }
        struct Result: Decodable { var summary: String }
        return try await client.call("spaces.topics.merge", TopicMergeParams(ref: topic, into: into), as: Result.self).summary
    }

    func subscribe(_ ref: ContainerRef, handler: @escaping ([SessionEvent]) -> Void) async throws -> SubscribeResult {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let sub = try await client.call("sessions.subscribe", SubscribeParams(ref: ref, fold: true), as: SubscribeResult.self)
        handlers[sub.subscriptionId] = handler
        // Events that raced ahead of the subscribe response.
        for events in orphans.removeValue(forKey: sub.subscriptionId) ?? [] { handler(events) }
        return sub
    }

    func unsubscribe(_ subscriptionId: String) {
        handlers[subscriptionId] = nil
        Task { _ = try? await client?.call("sessions.unsubscribe", UnsubscribeParams(subscriptionId: subscriptionId), as: Empty.self) }
    }

    private func dispatch(_ batch: SessionEventsNotification) {
        if let handler = handlers[batch.subscriptionId] {
            handler(batch.events)
        } else {
            orphans[batch.subscriptionId, default: []].append(batch.events)
        }
    }

    // MARK: Attention

    /// The thread shown in the main window (notifications skip it while the app is active).
    var selectedThreadId: String?

    func answerFinished(in thread: ThreadModel) {
        guard !(NSApp.isActive && selectedThreadId == thread.ref.key) else { return }
        guard case .assistant(let a)? = thread.document.lastItem else { return }
        let space = space(thread.ref.id)
        let title = thread.ref.conversationId.flatMap { id in space?.topics?.first { $0.id == id }?.title } ?? (threads + buildSessions + spaces).first { $0.ref.id == thread.ref.id }?.title ?? "Piopio"
        let failed = a.status == .error
        let body = failed ? (a.error ?? "The request failed.") : String(a.text.replacingOccurrences(of: "\n", with: " ").prefix(180))
        Notifier.shared.answer(ref: thread.ref, title: title, body: body, failed: failed)
    }

    /// A session waits for you (approval, question) or told you something: notify unless you're looking at it.
    private func attention(_ change: SessionAttention) {
        guard !(NSApp.isActive && selectedThreadId == change.ref.id) else { return }
        let body = change.kind == .waiting ? "Waiting for you · \(change.message)" : change.message
        Notifier.shared.answer(ref: change.ref, title: change.title, body: String(body.prefix(200)), failed: false, sound: change.kind == .waiting)
    }

    // MARK: Approval settings (per project)

    func setApprovalMode(_ mode: ApprovalMode, for project: ProjectInfo) async {
        _ = try? await client?.call("projects.configure", ProjectsConfigureParams(id: project.id, approvalMode: mode), as: ProjectsAddResult.self)
    }

    /// pi project trust (saved in ~/.pi/agent/trust.json, shared with the pi CLI).
    func setTrust(_ trusted: Bool, for project: ProjectInfo) async {
        _ = try? await client?.call("projects.configure", ProjectsConfigureParams(id: project.id, trust: trusted), as: ProjectsAddResult.self)
    }

    func removeRule(_ rule: ApprovalRule, from project: ProjectInfo) async {
        _ = try? await client?.call("projects.configure", ProjectsConfigureParams(id: project.id, removeRule: rule.id), as: ProjectsAddResult.self)
    }

    /// Sessions working or waiting on you (quitting would stop them unless the engine runs in the background).
    var busySessions: [SessionSummary] {
        (threads + buildSessions).filter { [.running, .waitingApproval].contains(liveStatus[$0.ref.id]) }
    }

    // MARK: Models and providers

    func loadModels() async throws {
        guard let client else { return }
        let list = try await client.call("models.list", ModelsListParams(), as: ModelsListResult.self)
        models = list.models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        defaultModel = list.defaultModel
    }

    func loadProviders() async {
        guard let client, let list = try? await client.call("providers.list", Empty(), as: ProvidersListResult.self) else { return }
        providers = list.providers
        hasKey = Keychain.read(secretOpenRouter) != nil
    }

    /// Starts connecting a provider; the sign-in sheet follows `login`.
    func connect(_ provider: ProviderInfo, method: ProviderInfo.Method.Kind) async {
        guard let client else { return }
        let state = ProviderLogin(provider: provider, method: method)
        login = state
        do {
            state.loginId = try await client.call("providers.login", ProviderLoginParams(provider: provider.id, method: method), as: ProviderLoginResult.self).loginId
        } catch {
            state.apply(ProviderAuthEvent(type: "failed", message: (error as? EngineError)?.message ?? error.localizedDescription))
        }
    }

    func answerLogin(_ value: String?) async {
        guard let login, let loginId = login.loginId, let promptId = login.prompt?.promptId else { return }
        login.prompt = nil
        _ = try? await client?.call("providers.answer", ProviderAnswerParams(loginId: loginId, promptId: promptId, value: value), as: Empty.self)
    }

    func cancelLogin() async {
        if let id = login?.loginId, login?.finished == false { _ = try? await client?.call("providers.cancelLogin", LoginIdParams(loginId: id), as: Empty.self) }
        login = nil
    }

    func disconnect(_ provider: ProviderInfo) async {
        _ = try? await client?.call("providers.logout", ProviderParams(provider: provider.id), as: Empty.self)
        if provider.id == "openrouter" { hasKey = false }
        await loadProviders()
        try? await loadModels()
    }

    // MARK: Secrets

    func saveKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.write(secretOpenRouter, value: trimmed)
        hasKey = true
        _ = try? await client?.call("secrets.changed", SecretChangedParams(name: secretOpenRouter), as: Empty.self)
    }

    func removeKey() async {
        Keychain.delete(secretOpenRouter)
        hasKey = false
        _ = try? await client?.call("secrets.changed", SecretChangedParams(name: secretOpenRouter), as: Empty.self)
    }
}
