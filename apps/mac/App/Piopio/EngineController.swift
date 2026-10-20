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
    /// Build: folders added as projects, and their sessions (newest first).
    private(set) var projects: [ProjectInfo] = []
    private(set) var buildSessions: [SessionSummary] = []
    private(set) var models: [ModelInfo] = []
    private(set) var defaultModel: ModelRef?
    private(set) var hasKey = Keychain.read(secretOpenRouter) != nil
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

    var needsKey: Bool { !faux && !hasKey }

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
            let list = try await client!.call("models.list", ModelsListParams(), as: ModelsListResult.self)
            models = list.models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            defaultModel = list.defaultModel
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
            guard method == "secrets.get", let name = params["name"]?.stringValue else { return .object(["value": .null]) }
            return .object(["value": Keychain.read(name).map(JSONValue.string) ?? .null])
        }
        let hello: HelloResult
        do {
            hello = try await client.connectAndHello(client: "Piopio.app", tokenFile: home.appending(path: "engine.token"))
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
        let ref = try await client.call("sessions.create", CreateSessionParams(kind: .build, cwd: project.path, model: model ?? preferredModel, workOn: workOn, approvalMode: mode, profile: profile), as: CreateSessionResult.self).ref
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

    /// The model new threads start with: the user's choice, else the engine default.
    var preferredModel: ModelRef? {
        _ = preferenceTick
        if let raw = UserDefaults.standard.string(forKey: "defaultChatModel"), let i = raw.firstIndex(of: "/") {
            return ModelRef(provider: String(raw[..<i]), id: String(raw[raw.index(after: i)...]))
        }
        return defaultModel
    }

    func setPreferredModel(_ model: ModelRef) {
        UserDefaults.standard.set("\(model.provider)/\(model.id)", forKey: "defaultChatModel")
        preferenceTick += 1
    }

    /// Quick Chat's model (a fast one by choice); defaults to the default model.
    var quickChatModel: ModelRef? {
        _ = preferenceTick
        if let raw = UserDefaults.standard.string(forKey: "quickChatModel"), let i = raw.firstIndex(of: "/") {
            return ModelRef(provider: String(raw[..<i]), id: String(raw[raw.index(after: i)...]))
        }
        return preferredModel
    }

    func setQuickChatModel(_ model: ModelRef) {
        UserDefaults.standard.set("\(model.provider)/\(model.id)", forKey: "quickChatModel")
        preferenceTick += 1
    }

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

    /// Merges a topic into another; returns the summary that joined it.
    func merge(_ topic: ContainerRef, into: String) async throws -> String {
        guard let client else { return "" }
        struct Result: Decodable { var summary: String }
        return try await client.call("spaces.topics.merge", TopicMergeParams(ref: topic, into: into), as: Result.self).summary
    }

    func subscribe(_ ref: ContainerRef, handler: @escaping ([SessionEvent]) -> Void) async throws -> SubscribeResult {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let sub = try await client.call("sessions.subscribe", RefParams(ref: ref), as: SubscribeResult.self)
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
