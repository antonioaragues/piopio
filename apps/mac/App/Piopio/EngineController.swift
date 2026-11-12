import AppKit
import Observation
import PiopioKit
import PiopioTranscript
import ServiceManagement

/// Owns the Local Engine: starts it (or attaches to a running one), answers its secret requests from the
/// Keychain, mirrors the session catalog, and fans out session events to open threads.
@Observable @MainActor
final class EngineController {
    enum Status: Equatable { case starting, ready, failed(String) }

    private(set) var status: Status = .starting
    private(set) var threads: [SessionSummary] = []
    /// Agents (docs/spec/06-agents).
    private(set) var agents: [SessionSummary] = []
    /// Teams (docs/spec/19): a lead, members and a board.
    private(set) var teams: [TeamInfo] = []
    /// Teams as definitions (docs/spec/20 P3): the Teams section and the team pages.
    private(set) var teamDefinitions: [TeamDefinition] = []
    /// Build: folders added as projects, and their sessions (newest first).
    private(set) var projects: [ProjectInfo] = []
    private(set) var buildSessions: [SessionSummary] = []
    private(set) var models: [ModelInfo] = []
    private(set) var defaultModel: ModelRef?
    private(set) var hasKey = ProcessInfo.processInfo.environment["PIOPIO_FAUX"] == "1" ? false : Keychain.exists(secretOpenRouter)
    /// Model providers and how each is connected (docs/spec/10-model-providers).
    private(set) var providers: [ProviderInfo] = []
    /// The sign-in in progress (Settings › Models shows it as a sheet).
    var login: ProviderLogin?
    /// Connected apps (docs/spec/12-connectors) and the app sign-in in progress.
    private(set) var connectors: [ConnectorInfo] = []
    var connectorLogin: ConnectorLogin?
    /// The engine has worked in this run (so a failure now is a crash, shown as a banner).
    private(set) var wasReady = false
    /// Latest session status per open thread (sidebar status dots).
    var liveStatus: [String: SessionStatus] = [:]
    var isLost: Bool { if case .failed = status { wasReady && !isMaintaining } else { false } }
    /// Scripted echo model instead of OpenRouter (`PIOPIO_FAUX=1`), for development.
    let faux = ProcessInfo.processInfo.environment["PIOPIO_FAUX"] == "1"

    @ObservationIgnored private let scriptedSecrets = ScriptedSecrets()
    @ObservationIgnored private(set) var client: EngineClient?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var openThreads: [String: ThreadModel] = [:]
    @ObservationIgnored private var handlers: [String: ([SessionEvent]) -> Void] = [:]
    @ObservationIgnored private var orphans: [String: [[SessionEvent]]] = [:]

    var searchTarget: SearchResult?

    let home = EngineClient.defaultHome()
    private var socket: URL { home.appending(path: "engine.sock") }

    var needsKey: Bool { !faux && !hasKey && !providers.contains(where: \.isConnected) }

    private(set) var isMaintaining = false
    private(set) var dataGeneration = 0

    /// The only backup/restore entry point: stop writers, perform a verified operation, then reconnect.
    private func offlineData<T: Sendable>(_ operation: @escaping @Sendable (URL) throws -> T) async throws -> T {
        guard !isMaintaining else { throw EngineError(code: "BUSY", message: "A data operation is already running.") }
        try await flushDrafts()
        isMaintaining = true
        stopping = true
        let background = runsInBackground
        defer { isMaintaining = false }
        do {
            if let client {
                _ = try await client.call("engine.shutdown", Empty(), as: Empty.self)
            }
            if background { try await Self.agent.unregister(); agentTick += 1 }
            await client?.close(); client = nil
            for _ in 0..<200 {
                if !FileManager.default.fileExists(atPath: socket.path), process?.isRunning != true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !FileManager.default.fileExists(atPath: socket.path), process?.isRunning != true else {
                throw EngineError(code: "BUSY", message: "The engine is still stopping. Your data has not been changed.")
            }
            try await Task.sleep(for: .milliseconds(150))
            process = nil
            handlers = [:]; orphans = [:]; openThreads = [:]; liveStatus = [:]
            let folder = home
            let result = try await Task.detached { try operation(folder) }.value
            if background { try Self.agent.register(); agentTick += 1 }
            stopping = false
            dataGeneration += 1
            await start()
            return result
        } catch {
            if background, Self.agent.status == .notRegistered { try? Self.agent.register(); agentTick += 1 }
            stopping = false
            dataGeneration += 1
            await start()
            throw error
        }
    }

    func createBackup(at target: URL) async throws {
        var values = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "app.piopio.Piopio") ?? [:]
        values.removeValue(forKey: "customEnginePath")
        let preferences = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        try await offlineData { home in _ = try BackupArchive.create(home: home, at: target, preferences: preferences) }
    }

    /// Leaves the previous data folder alongside the restored one for recovery.
    func restoreBackup(from archive: URL, restorePreferences: Bool = true) async throws -> URL {
        _ = try await Task.detached { try BackupArchive.inspect(archive) }.value
        let preferencesURL = archive.appending(path: "preferences.plist")
        let preferences = FileManager.default.fileExists(atPath: preferencesURL.path) ? try Data(contentsOf: preferencesURL) : nil
        let previous = try await offlineData { home in
            let fm = FileManager.default
            let stage = home.deletingLastPathComponent().appending(path: ".piopio-restore-\(UUID().uuidString)")
            let previous = home.deletingLastPathComponent().appending(path: "Piopio-before-restore-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: stage) }
            try BackupArchive.restore(archive, to: stage)
            try fm.moveItem(at: home, to: previous)
            do {
                try fm.moveItem(at: stage, to: home)
                try BackupArchive.rebase(home: home, from: stage)
            } catch {
                try? fm.removeItem(at: home)
                try fm.moveItem(at: previous, to: home)
                throw error
            }
            return previous
        }
        if restorePreferences, let preferences, var values = try PropertyListSerialization.propertyList(from: preferences, options: [], format: nil) as? [String: Any] {
            values.removeValue(forKey: "customEnginePath")
            values["sidebarItem"] = "home"
            UserDefaults.standard.setPersistentDomain(values, forName: Bundle.main.bundleIdentifier ?? "app.piopio.Piopio")
        }
        return previous
    }

    func flushDrafts() async throws {
        for thread in Array(openThreads.values) { try await thread.flushDraft() }
    }

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
            await loadConnectors()
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
        let drafts = Array(openThreads.values)
        for t in drafts { t.close() }
        openThreads = [:]
        if let p = process, !p.isRunning { process = nil }
        Task {
            for thread in drafts { try? await thread.flushDraft() }
            await start()
        }
    }

    /// Connects to a running engine. Returns nil when nothing is listening.
    private func connect() async throws -> HelloResult? {
        guard FileManager.default.fileExists(atPath: socket.path) else { return nil }
        let client = EngineClient(socketPath: socket.path)
        let scripted = faux, temporarySecrets = scriptedSecrets
        await client.setReverseHandler { method, params in
            // Apple app tools for agents (06-agents §4.1), run with this app's permissions.
            if method == "app.tool" { return await AppleTools.shared.handle(params) }
            // Provider sign-ins and refreshed tokens (docs/spec/10 §10): the Keychain is the store.
            if method == "secrets.set", let name = params["name"]?.stringValue, let value = params["value"]?.stringValue {
                if scripted { await temporarySecrets.set(name, value: value) } else { try? Keychain.write(name, value: value) }
                return .object([:])
            }
            if method == "secrets.delete", let name = params["name"]?.stringValue {
                if scripted { await temporarySecrets.set(name, value: nil) } else { Keychain.delete(name) }
                return .object([:])
            }
            guard method == "secrets.get", let name = params["name"]?.stringValue else { return .object(["value": .null]) }
            let value: String?
            if scripted { value = await temporarySecrets.get(name) } else { value = Keychain.read(name) }
            return .object(["value": value.map(JSONValue.string) ?? .null])
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
        Task { [weak self] in await self?.loadTeams() }
        Task { [weak self] in
            for await note in client.providerEvents {
                guard let self else { return }
                switch note {
                case .changed:
                    await self.loadProviders()
                    try? await self.loadModels()
                case .auth(let auth):
                    if self.login?.loginId == auth.loginId { self.login?.apply(auth.event) }
                case .connectorsChanged:
                    await self.loadConnectors()
                case .teamsChanged:
                    await self.loadTeams()
                case .connectorAuth(let auth):
                    if self.connectorLogin?.loginId == auth.loginId { self.connectorLogin?.apply(auth.event) }
                    if auth.event.type == "done" { await self.loadConnectors() }
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
        // Apple's on-device model for utility work (07-shared §1.3), next to the engine launcher.
        if env["PIOPIO_FM"] == nil, let fm = Bundle.main.url(forAuxiliaryExecutable: "piopio-fm") { env["PIOPIO_FM"] = fm.path }
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

    func loadProjects() async {
        if let list = try? await client?.call("projects.list", Empty(), as: ProjectsListResult.self).projects { projects = list }
    }

    func refreshCatalog() async throws {
        guard let client else { return }
        threads = try await client.call("sessions.list", ListSessionsParams(kind: .thread), as: ListSessionsResult.self).sessions
        buildSessions = try await client.call("sessions.list", ListSessionsParams(kind: .build), as: ListSessionsResult.self).sessions
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
    /// Without Build (the area is off), folders are Read only (docs/spec/18 §7). `planMode`: start in Plan.
    func createBuildSession(in project: ProjectInfo, workOn: WorkOn, mode: ApprovalMode?, model: ModelRef?, planMode: Bool = false, profile: SessionSummary.Profile = .build) async throws -> ContainerRef {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine isn't running.") }
        let ref = try await client.call("sessions.create", CreateSessionParams(kind: .build, cwd: project.path, model: model ?? self.model(for: .build), workOn: workOn, planMode: planMode ? true : nil, approvalMode: Areas.shared.contains(.build) ? mode : .readOnly, profile: profile), as: CreateSessionResult.self).ref
        try? await refreshCatalog()
        return ref
    }

    /// A conversation with a team's lead in its project (docs/spec/20 PT4): a Build conversation there, with the
    /// board's tools.
    func createTeamConversation(_ team: TeamInfo, mode: ApprovalMode?, model: ModelRef?) async throws -> ContainerRef {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine isn't running.") }
        let ref = try await client.call("sessions.create", CreateSessionParams(kind: .build, cwd: team.cwd, model: model ?? self.model(for: .build), approvalMode: Areas.shared.contains(.build) ? mode : .readOnly, team: team.id), as: CreateSessionResult.self).ref
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

    /// A conversation with no folder.
    func createThread(model: ModelRef? = nil) async -> ContainerRef? {
        guard let client else { return nil }
        return try? await client.call("sessions.create", CreateSessionParams(kind: .thread, model: model ?? preferredModel), as: CreateSessionResult.self).ref
    }

    /// New project (docs/spec/18 CF4): a folder in ~/Piopio named after it, with AGENTS.md (`instructions`) and NOTES.md.
    func createProject(name: String, instructions: String? = nil) async throws -> ProjectInfo {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine isn't running.") }
        let project = try await client.call("projects.create", ProjectsCreateParams(name: name, instructions: instructions), as: ProjectsAddResult.self).project
        await loadProjects()
        return project
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

    /// The model new conversations start with.
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

    /// Drops the open models of a session (and its agent conversations).
    private func forget(_ id: String) {
        for key in openThreads.keys where key == id || key.hasPrefix(id + "/") {
            openThreads[key]?.close()
            openThreads[key] = nil
        }
    }

    /// An engine method without a result.
    func spaceCall(_ method: String, _ params: some Encodable & Sendable) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call(method, params, as: Empty.self)
    }

    // MARK: Agents

    // MARK: Teams (docs/spec/19)

    func loadTeams() async {
        if let list = try? await client?.call("teams.list", Empty(), as: TeamsListResult.self).teams { teams = list }
        if let defs = try? await client?.call("teams.definitions", Empty(), as: TeamDefinitionsResult.self).definitions { teamDefinitions = defs }
    }

    /// You edit a team (name, members, default model: "" clears it); every project it works in follows.
    func updateTeamDefinition(_ def: TeamDefinition, name: String? = nil, roles: [TeamRole]? = nil, model: String? = nil, saved: Bool? = nil, reviewLimit: Int? = nil, budgetPerJob: Double? = nil) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("teams.updateDefinition", UpdateTeamDefinitionParams(id: def.id, name: name, roles: roles, model: model, saved: saved, reviewLimit: reviewLimit, budgetPerJob: budgetPerJob), as: Empty.self)
        await loadTeams()
    }

    /// A team drafted from a description: the background model's, or one from your words.
    func draftTeam(_ description: String) async throws -> TeamDraft {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("teams.draft", TeamDraftParams(description: description), as: TeamDraftResult.self).draft
    }

    /// A new team, not in a project yet: from a template, or from a draft you adjusted.
    func createTeamDefinition(_ params: CreateTeamDefinitionParams) async throws -> TeamDefinition {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let def = try await client.call("teams.createDefinition", params, as: TeamDefinitionResult.self).definition
        await loadTeams()
        return def
    }

    /// Save as template: a folder you can edit or share; returns it.
    func saveTeamTemplate(_ def: TeamDefinition, name: String?) async throws -> String {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("teams.saveTemplate", SaveTeamTemplateParams(id: def.id, name: name), as: SaveTeamTemplateResult.self).folder
    }

    func removeTeamDefinition(_ def: TeamDefinition) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("teams.removeDefinition", TeamIdParams(id: def.id), as: Empty.self)
        await loadTeams()
    }

    /// A model's display name from its "provider:id".
    func modelName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count == 2 ? parts[1] : raw
        return models.first { $0.id == id && (parts.count < 2 || $0.provider == parts[0]) }?.name ?? id
    }

    func teamTemplates() async -> [TeamTemplate] {
        (try? await client?.call("teams.templates", Empty(), as: TeamTemplatesResult.self).templates) ?? []
    }

    /// The team that works in a project's folder (a project's team, docs/spec/19 §10).
    func team(in project: ProjectInfo) -> TeamInfo? {
        teams.first { $0.cwd == project.path }
    }

    func createTeam(name: String, template: String, cwd: String?, goal: String?, testCommand: String?, initGit: Bool = false, definition: String? = nil) async throws -> TeamInfo {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let team = try await client.call("teams.create", CreateTeamParams(name: name, template: template, cwd: cwd, goal: goal, testCommand: testCommand, model: model(for: .build), initGit: initGit, definition: definition), as: TeamResult.self).team
        await loadTeams()
        await loadProjects() // a team without a folder gets a project (docs/spec/20 PT2)
        try? await refreshCatalog()
        return team
    }

    /// The project's Settings: the team's checks (empty removes them) and how many tasks run at once.
    func updateTeam(_ team: TeamInfo, testCommand: String? = nil, maxParallel: Int? = nil) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("teams.update", UpdateTeamParams(id: team.id, testCommand: testCommand, maxParallel: maxParallel), as: Empty.self)
        await loadTeams()
    }

    /// The project works with Piopio again: the team's conversations stay, as plain ones.
    func removeTeam(_ team: TeamInfo) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("teams.remove", TeamIdParams(id: team.id), as: Empty.self)
        await loadTeams()
        try? await refreshCatalog()
    }

    func addTeamTask(_ team: TeamInfo, title: String, brief: String, role: String?) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("teams.addTask", AddTeamTaskParams(id: team.id, title: title, brief: brief, role: role), as: Empty.self)
        await loadTeams()
    }

    /// Home's agenda (docs/spec/21 D2): `since` is your last visit.
    func homeAgenda(since: String?) async -> HomeAgenda? {
        try? await client?.call("home.agenda", HomeAgendaParams(since: since), as: HomeAgenda.self)
    }

    /// A project's routines (docs/spec/21 AD5): each run opens a session there, with the team's lead when it has one.
    func routines(in project: ProjectInfo) async -> [TeamRoutine] {
        (try? await client?.call("routines.list", ProjectParams(project: project.id), as: RoutinesResult.self).routines) ?? []
    }

    func addRoutine(_ project: ProjectInfo, on: String, prompt: String, when: String? = nil, folder: String? = nil, from: String? = nil, subject: String? = nil) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("routines.add", AddRoutineParams(project: project.id, on: on, prompt: prompt, when: when, folder: folder, from: from, subject: subject), as: Empty.self)
    }

    func removeRoutine(_ project: ProjectInfo, _ routine: TeamRoutine) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("routines.remove", RoutineParams(project: project.id, routineId: routine.id), as: Empty.self)
    }

    func runRoutine(_ project: ProjectInfo, _ routine: TeamRoutine) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("routines.run", RoutineParams(project: project.id, routineId: routine.id), as: Empty.self)
        try? await refreshCatalog()
    }

    /// Make it one of your agents (docs/spec/21 AD3).
    func promoteMember(_ def: TeamDefinition, _ role: TeamRole) async throws -> ContainerRef {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let ref = try await client.call("teams.promoteMember", PromoteMemberParams(id: def.id, roleId: role.id), as: PromoteMemberResult.self).agent
        await loadTeams()
        try? await refreshCatalog()
        return ref
    }

    /// What the team's branch would bring to the project's; nil for a team without a branch.
    func teamLanding(_ team: TeamInfo) async -> TeamLanding? {
        guard team.git != nil else { return nil }
        return try? await client?.call("teams.landing", TeamIdParams(id: team.id), as: TeamLanding.self)
    }

    /// Merges the team's branch into the project's ("merge"), or pushes it for a pull request ("push").
    func landTeam(_ team: TeamInfo, action: String) async throws -> TeamLandResult {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let result = try await client.call("teams.land", TeamLandParams(id: team.id, action: action), as: TeamLandResult.self)
        await loadTeams()
        return result
    }

    func updateTeamTask(_ team: TeamInfo, _ task: TeamTask, state: String? = nil, role: String? = nil) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("teams.updateTask", UpdateTeamTaskParams(id: team.id, taskId: task.id, state: state, role: role), as: Empty.self)
        await loadTeams()
    }

    func agentTemplates() async -> [AgentTemplate] {
        (try? await client?.call("agents.templates", Empty(), as: AgentTemplatesResult.self).templates) ?? []
    }

    func createAgent(name: String, template: String?, avatar: String, instructions: String? = nil, schedule: CreateAgentParams.Schedule = .template) async throws -> ContainerRef {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let ref = try await client.call("agents.create", CreateAgentParams(name: name, template: template, avatar: avatar.isEmpty ? nil : avatar, model: model(for: .agent), owner: NSFullUserName().split(separator: " ").first.map(String.init), instructions: instructions, schedule: schedule), as: CreateSessionResult.self).ref
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

    func agentRunNow(_ ref: ContainerRef, scheduleId: String? = nil, prompt: String? = nil, trial: Bool = false) async throws -> String {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("agents.runNow", AgentRunNowParams(ref: ref, scheduleId: scheduleId, prompt: prompt, trial: trial), as: AgentRunNowResult.self).runId
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
        // A connected app's change in a chat (docs/spec/12-connectors): the chat answers it.
        if agent.kind != .agent {
            _ = try await client.call("sessions.decide", SessionDecideParams(ref: agent, approvalId: approvalId, approve: approve, always: always ? true : nil), as: JSONValue.self)
            return
        }
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

    /// Whether Apple's on-device model can run now (Settings › Models, Memory).
    func onDeviceStatus() async -> OnDeviceStatus? {
        try? await client?.call("models.onDevice", Empty(), as: OnDeviceStatus.self)
    }

    func aboutMe() async -> MemoryResult? {
        try? await client?.call("aboutMe.get", Empty(), as: MemoryResult.self)
    }

    /// Turn into an agent (docs/spec/18 phase 3): fills the Agent start page with a draft from the conversation and
    /// opens it. Nothing is created until Create there.
    func turnIntoAgent(_ ref: ContainerRef) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine isn't running.") }
        let draft = try await client.call("sessions.agentDraft", RefParams(ref: ref), as: AgentDraftResult.self)
        StartDrafts.shared.update(.agent) { d in
            d.name = draft.name
            d.text = draft.instructions
            d.schedule = draft.schedule ?? ""
            d.template = nil
        }
        // "form": the start page with the draft, not a new agent made by talking.
        NotificationCenter.default.post(name: .newAgent, object: "form")
    }

    /// A conversation continues in a project folder (docs/spec/18 §5): a new conversation there, with this one's text
    /// and images as context. This one stays, linked to it.
    func continueIn(_ ref: ContainerRef, project: ProjectInfo) async throws -> ContainerRef {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine isn't running.") }
        let next = try await client.call("sessions.continueIn", ContinueInParams(ref: ref, cwd: project.path, approvalMode: Areas.shared.contains(.build) ? nil : .readOnly), as: CreateSessionResult.self).ref
        try? await refreshCatalog()
        return next
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
        let title = (threads + buildSessions).first { $0.ref.id == thread.ref.id }?.title ?? "Piopio"
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
        ModelNames.set(models.map { ($0.provider, $0.id, ModelChip.short($0).replacingOccurrences(of: "Claude ", with: "")) })
        defaultModel = list.defaultModel
    }

    func loadProviders() async {
        guard let client, let list = try? await client.call("providers.list", Empty(), as: ProvidersListResult.self) else { return }
        providers = list.providers
        if faux { hasKey = await scriptedSecrets.get(secretOpenRouter) != nil } else { hasKey = Keychain.exists(secretOpenRouter) }
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

    // MARK: Connected apps

    func loadConnectors() async {
        guard let client, let list = try? await client.call("connectors.list", Empty(), as: ConnectorsListResult.self) else { return }
        connectors = list.connectors
    }

    /// Starts signing in to an app; the browser opens, the sheet follows `connectorLogin`.
    func connect(_ connector: ConnectorInfo, inline: Bool = false) async {
        guard let client else { return }
        let state = ConnectorLogin(connector: connector, inline: inline)
        connectorLogin = state
        do {
            state.loginId = try await client.call("connectors.connect", ConnectorParams(connector: connector.id), as: ProviderLoginResult.self).loginId
        } catch {
            state.apply(ProviderAuthEvent(type: "failed", message: (error as? EngineError)?.message ?? error.localizedDescription))
        }
    }

    func cancelConnectorLogin() async {
        if let id = connectorLogin?.loginId, connectorLogin?.finished == false { _ = try? await client?.call("connectors.cancel", LoginIdParams(loginId: id), as: Empty.self) }
        connectorLogin = nil
    }

    func disconnect(account: ConnectorInfo.Account) async {
        _ = try? await client?.call("connectors.disconnect", ConnectorAccountParams(accountId: account.id), as: Empty.self)
        await loadConnectors()
    }

    func configure(_ params: ConnectorConfigureParams) async throws {
        guard let client else { return }
        _ = try await client.call("connectors.configure", params, as: Empty.self)
        await loadConnectors()
    }

    /// One capability (all its tools) set to runs, asks first or off.
    func setPermission(_ permission: ConnectorPermission, for capability: ConnectorInfo.Capability, of connector: ConnectorInfo) async {
        try? await configure(ConnectorConfigureParams(connector: connector.id, permissions: Dictionary(uniqueKeysWithValues: capability.tools.map { ($0, permission) })))
    }

    func connectorCalendars(_ accountId: String) async throws -> [ConnectorCalendarsResult.Calendar] {
        guard let client else { return [] }
        return try await client.call("connectors.calendars", ConnectorAccountParams(accountId: accountId), as: ConnectorCalendarsResult.self).calendars
    }

    func setConnectorCalendar(_ accountId: String, _ calendarId: String, enabled: Bool) async {
        _ = try? await client?.call("connectors.setCalendar", ConnectorSetCalendarParams(accountId: accountId, calendarId: calendarId, enabled: enabled), as: Empty.self)
    }

    // Custom endpoints (LiteLLM, Ollama, LM Studio…)

    func checkEndpoint(_ baseUrl: String, key: String?, id: String?, format: String? = nil, headers: [String: String]? = nil) async -> EndpointCheckResult? {
        try? await client?.call("endpoints.check", EndpointCheckParams(baseUrl: baseUrl, key: key, id: id, format: format, headers: headers), as: EndpointCheckResult.self)
    }

    /// Adds or updates an endpoint; throws the engine's reason when the server doesn't answer as expected (unless `force`).
    @discardableResult
    func saveEndpoint(_ params: EndpointSaveParams) async throws -> String {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine isn't running.") }
        let id = try await client.call("endpoints.save", params, as: EndpointSaveResult.self).id
        await loadProviders()
        try? await loadModels()
        return id
    }

    func saveEndpoint(id: String?, name: String, baseUrl: String, key: String?) async throws {
        try await saveEndpoint(EndpointSaveParams(id: id, name: name, baseUrl: baseUrl, key: key))
    }

    func removeEndpoint(_ provider: ProviderInfo) async {
        let roles = ModelRole.allCases.filter { model(for: $0)?.provider == provider.id }
        _ = try? await client?.call("endpoints.remove", EndpointIdParams(id: provider.id), as: Empty.self)
        await loadProviders()
        try? await loadModels()
        reassign(roles)
    }

    // Provider keys and model visibility (Settings › Models)

    func verifyKey(_ provider: String, key: String) async -> ProviderVerifyResult? {
        try? await client?.call("providers.verifyKey", ProviderKeyParams(provider: provider, key: key), as: ProviderVerifyResult.self)
    }

    func saveKey(_ provider: String, key: String) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine isn't running.") }
        _ = try await client.call("providers.saveKey", ProviderKeyParams(provider: provider, key: key), as: Empty.self)
        if provider == "openrouter" { hasKey = true }
        await loadProviders()
        try? await loadModels()
    }

    func providerModels(_ provider: String) async -> [ProviderModelsResult.Model] {
        (try? await client?.call("providers.models", ProviderParams(provider: provider), as: ProviderModelsResult.self).models) ?? []
    }

    func setHidden(_ provider: String, hidden: [String]) async {
        _ = try? await client?.call("providers.setHidden", ProviderHiddenParams(provider: provider, hidden: hidden), as: Empty.self)
        try? await loadModels()
        await loadProviders()
    }

    /// Defaults that used a removed provider move to the first model still available.
    private func reassign(_ roles: [ModelRole]) {
        guard let fallback = models.first(where: { $0.provider != "faux" }) ?? models.first else { return }
        for role in roles { setModel(fallback.ref, for: role) }
    }

    func detectEndpoints() async -> [EndpointsDetectResult.Found] {
        (try? await client?.call("endpoints.detect", Empty(), as: EndpointsDetectResult.self).found) ?? []
    }

    func disconnect(_ provider: ProviderInfo) async {
        let roles = ModelRole.allCases.filter { model(for: $0)?.provider == provider.id }
        defer { reassign(roles) }
        _ = try? await client?.call("providers.logout", ProviderParams(provider: provider.id), as: Empty.self)
        if provider.id == "openrouter" { hasKey = false }
        await loadProviders()
        try? await loadModels()
    }

    // MARK: Secrets

    func saveKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if faux { await scriptedSecrets.set(secretOpenRouter, value: trimmed) } else { try Keychain.write(secretOpenRouter, value: trimmed) }
        hasKey = true
        _ = try? await client?.call("secrets.changed", SecretChangedParams(name: secretOpenRouter), as: Empty.self)
    }

    func removeKey() async {
        if faux { await scriptedSecrets.set(secretOpenRouter, value: nil) } else { Keychain.delete(secretOpenRouter) }
        hasKey = false
        _ = try? await client?.call("secrets.changed", SecretChangedParams(name: secretOpenRouter), as: Empty.self)
    }
}


/// Scripted UI checks never access or modify the user's Keychain.
private actor ScriptedSecrets {
    private var values: [String: String] = [:]
    func get(_ name: String) -> String? { values[name] }
    func set(_ name: String, value: String?) { values[name] = value }
}
