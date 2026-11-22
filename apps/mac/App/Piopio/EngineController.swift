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
    /// Projects' work (docs/spec/26): each one's way of working and board.
    private(set) var work: [ProjectWork] = []
    /// Automations (docs/spec/27): what starts on its own, run as Piopio or one of your agents. Bumps
    /// `automationsGeneration` on every change, so open pages read their runs again.
    private(set) var automations: [Automation] = []
    private(set) var automationsGeneration = 0
    /// The Library (docs/spec/35 §4): what Piopio and your agents made, newest first, and the pins in their order.
    private(set) var library: [LibraryEntry] = []
    private(set) var libraryPins: [String] = []
    private(set) var libraryLoaded = false
    /// What you removed from the Library, newest first, to put back.
    private(set) var libraryRemoved: [LibraryEntry] = []
    /// The Library couldn't be read (the page offers Retry).
    private(set) var libraryFailed = false
    /// An item the Library should select when it shows (from a pin, ⌘K or Show in Library); the page clears it.
    var libraryFocus: String?
    /// Open apps' latest data, by path, as their files change (docs/spec/35 §14).
    var appUpdates: [String: AppView] = [:]
    /// Which migration report is showing ("work" or "automations").
    @ObservationIgnored private var reportFrom = "work"
    /// The Watchdog's notes about your conversations (docs/spec/17 §4): in Needs you.
    private(set) var watchdogNotes: [WatchdogNote] = []
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
    /// Spend, read again every few minutes while connected: one at a time (each connection used to add its own).
    @ObservationIgnored private var usagePoller: Task<Void, Never>?
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

    /// Show in Library (docs/spec/35 §4.2), posted by a file card, the file viewer or Build's files; listened to once.
    @ObservationIgnored private var showsInLibrary: NSObjectProtocol?
    @ObservationIgnored private var visualSaves: NSObjectProtocol?

    func start() async {
        LibraryMembership.contains = { [weak self] path in self?.library.contains { $0.path == path } ?? false }
        if showsInLibrary == nil {
            showsInLibrary = NotificationCenter.default.addObserver(forName: .showInLibrary, object: nil, queue: .main) { [weak self] note in
                guard let path = note.object as? String else { return }
                MainActor.assumeIsolated { Task { try? await self?.showInLibrary(path) } }
            }
            // A visual saved from its card: the Library links the file to it.
            visualSaves = NotificationCenter.default.addObserver(forName: .visualSaved, object: nil, queue: .main) { [weak self] note in
                guard let callId = note.userInfo?["callId"] as? String, let path = note.userInfo?["path"] as? String else { return }
                MainActor.assumeIsolated {
                    Task {
                        _ = try? await self?.client?.call("library.saved", LibrarySavedParams(callId: callId, path: path), as: Empty.self)
                        await self?.loadLibrary()
                    }
                }
            }
        }
        status = .starting
        do {
            // Only yours (the engine tightens the folders it makes as well, but this one often comes first).
            try FileManager.default.createDirectory(at: home.appending(path: "logs"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
            // Chats open on screen across a restart or a dropped connection subscribe again on this one: their views
            // stay where they are, so they wouldn't ask by themselves (2026-11-20: after Restart, sending worked and
            // nothing came back).
            for thread in Array(openThreads.values) { Task { await thread.reattach() } }
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

    /// Starts over after the engine connection drops; open threads subscribe again once it's back (in `start`).
    private func connectionLost(_ lost: EngineClient) {
        guard !stopping, client === lost else { return }
        client = nil
        handlers = [:]
        orphans = [:]
        let drafts = Array(openThreads.values)
        for t in drafts { t.close() }
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
            // The browser's tools for conversations and Build sessions (docs/spec/22).
            if method == "app.tool", params["groups"]?.arrayValue?.contains(where: { $0.stringValue == "browser" }) == true {
                return await BrowserCenter.shared.handle(params)
            }
            // Visuals the model just made, drawn and checked before anyone looks (docs/spec/25 §3.2).
            if method == "app.tool", params["groups"]?.arrayValue?.contains(where: { $0.stringValue == "visuals" }) == true {
                return await VisualChecker.handle(params)
            }
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
            hello = try await client.connectAndHello(client: "Piopio.app", tokenFile: home.appending(path: "engine.token"), services: ["app.tool", "secrets.set", "browser", "visuals"])
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
        Task { [weak self] in await self?.loadWork(); await self?.loadWatchdog(); await self?.loadAutomations(); await self?.loadLibrary() }
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
                case .workChanged:
                    await self.loadWork()
                case .watchdogChanged:
                    await self.loadWatchdog()
                case .automationsChanged:
                    await self.loadAutomations()
                case .libraryChanged:
                    await self.loadLibrary()
                case .appData(let app):
                    self.appUpdates[app.path] = app
                case .connectorAuth(let auth):
                    if self.connectorLogin?.loginId == auth.loginId { self.connectorLogin?.apply(auth.event) }
                    if auth.event.type == "done" { await self.loadConnectors() }
                }
            }
        }
        // Spend (sidebar footer, Home): now, then every few minutes. A new connection replaces the last one's poller.
        usagePoller?.cancel()
        usagePoller = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // Held only while reading, not while waiting, so the controller can go.
                    guard let self, self.client != nil else { return }
                    await self.loadUsage()
                }
                try? await Task.sleep(for: .seconds(180))
            }
        }
        return hello
    }

    private func launchEngine() throws {
        let p = Process()
        if let custom = Self.customEngine {
            // Dev setting, Debug builds only: `defaults write app.piopio.Piopio customEnginePath /path/to/engine/dist/main.js`.
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
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
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

    /// Debug builds only: in a release, any program running as the user could set this and have Piopio run its script
    /// as the engine, which the app answers with Keychain secrets and Apple tools.
    private static var customEngine: URL? {
        #if !DEBUG
        return nil
        #else
        guard let path = UserDefaults.standard.string(forKey: "customEnginePath"), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
        #endif
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
        // With PIOPIO_FAUX the scripted model is the only connected one: a choice saved by the real app
        // (UserDefaults outlive a scratch PIOPIO_HOME) would fail every send.
        if let raw = UserDefaults.standard.string(forKey: role.rawValue), let i = raw.firstIndex(of: "/"), !faux || raw[..<i] == "faux" {
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

    /// Quick Chat's model (a fast one by choice); defaults to the chat model.
    var quickChatModel: ModelRef? { model(for: .quick) }

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

    // MARK: GitHub (docs/spec/05-build G4–G8)

    func gitHubStatus() async -> GitHubStatus? {
        try? await client?.call("github.status", Empty(), as: GitHubStatus.self)
    }

    func setGitHubToken(_ token: String) async throws -> String {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("github.setToken", GitHubTokenParams(token: token), as: GitHubLogin.self).login
    }

    func signOutOfGitHub() async {
        _ = try? await client?.call("github.signOut", Empty(), as: Empty.self)
    }

    func gitHubRepos() async throws -> [GitHubRepo] {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("github.repos", Empty(), as: GitHubReposResult.self).repos
    }

    /// Clones it into ~/Piopio and adds it as a project.
    func clone(_ repo: String) async throws -> ProjectInfo {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let project = try await client.call("github.clone", GitHubCloneParams(repo: repo), as: GitHubCloneResult.self).project
        await loadProjects()
        return project
    }

    // MARK: Your cloud (docs/spec/30 K1)

    /// The last status read (nil until Settings or an agent's panel asks). `cloudConnected` hides cloud choices until then.
    private(set) var cloud: CloudStatus?
    var cloudConnected: Bool { cloud?.connected == true }

    @discardableResult
    func loadCloud() async -> CloudStatus? {
        guard let client else { return cloud }
        if let status = try? await client.call("cloud.status", Empty(), as: CloudStatus.self) { cloud = status }
        return cloud
    }

    func connectCloud(url: String, token: String) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        cloud = try await client.call("cloud.connect", CloudConnectParams(url: url, token: token), as: CloudStatus.self)
    }

    /// Connect with a Cloudflare token: Piopio deploys its Worker (accounts to pick from when there are several).
    func setupCloud(apiToken: String, accountId: String? = nil) async throws -> [CloudSetupResult.Account]? {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let result = try await client.call("cloud.setup", CloudSetupParams(apiToken: apiToken, accountId: accountId), as: CloudSetupResult.self)
        if let status = result.status { cloud = status; try? await refreshCatalog() }
        return result.accounts
    }

    /// The Worker again from this Piopio, with the current OpenRouter key.
    func updateCloud() async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        cloud = try await client.call("cloud.update", Empty(), as: CloudStatus.self)
    }

    func disconnectCloud() async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("cloud.disconnect", Empty(), as: Empty.self)
        cloud = CloudStatus(connected: false, agents: [])
    }

    /// Moves an agent to the cloud or back ("cloud" / "local"); what moved, in lines.
    func moveAgent(_ ref: ContainerRef, to place: String) async throws -> [String] {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let lines = try await client.call("agents.move", AgentMoveParams(ref: ContainerRef(kind: .agent, id: ref.id), to: place), as: AgentMoveResult.self).lines
        // Its open conversations followed the copy that stopped: new models subscribe to where it runs now.
        forget(ref.id)
        try? await refreshCatalog()
        await loadCloud()
        return lines
    }

    func prDraft(_ ref: ContainerRef) async throws -> PrDraft {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("sessions.pr.draft", RefParams(ref: ref), as: PrDraft.self)
    }

    @discardableResult
    func createPR(_ ref: ContainerRef, title: String, body: String, base: String?, draft: Bool) async throws -> PrStatus {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let pr = try await client.call("sessions.pr.create", CreatePrParams(ref: ref, title: title, body: body, base: base, draft: draft), as: PrResult.self).pr
        try? await refreshCatalog()
        return pr
    }

    func pullRequest(_ ref: ContainerRef) async throws -> PrStatus {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("sessions.pr.get", RefParams(ref: ref), as: PrResult.self).pr
    }

    /// Address comments ("comments") or Fix CI ("ci"): handed to the conversation.
    func addressPR(_ ref: ContainerRef, _ what: String) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("sessions.pr.address", AddressPrParams(ref: ref, what: what), as: Empty.self)
    }

    /// The project's work branch as a pull request (the Board's merge card).
    func createWorkPR(_ work: ProjectWork, title: String, body: String, draft: Bool) async throws -> PrStatus {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("work.createPR", WorkPrParams(project: work.project, title: title, body: body, draft: draft), as: PrResult.self).pr
    }

    func setPrEvents(_ value: String, for project: ProjectInfo) async {
        _ = try? await client?.call("projects.configure", ProjectsConfigureParams(id: project.id, prEvents: value), as: ProjectsAddResult.self)
        await loadProjects()
    }

    /// The project's check after the agent's edits: a command, "" for off, nil for the detected one (05-build "Diagnostics").
    func setCheck(_ command: String?, for project: ProjectInfo) async {
        _ = try? await client?.call("projects.configure", ProjectsCheckParams(id: project.id, check: command), as: ProjectsAddResult.self)
        await loadProjects()
    }

    // MARK: The Watchdog (docs/spec/17 §4)

    func loadWatchdog() async {
        if let notes = try? await client?.call("watchdog.list", Empty(), as: WatchdogListResult.self).notes { watchdogNotes = notes }
    }

    func dismissWatchdog(_ note: WatchdogNote) async {
        _ = try? await client?.call("watchdog.dismiss", IdParams(id: note.id), as: Empty.self)
        await loadWatchdog()
    }

    // MARK: Side conversations (docs/spec/24)

    /// A side conversation by hand: `/side <what>`, with your words as its brief.
    @discardableResult
    func startSide(from ref: ContainerRef, brief: String) async throws -> ContainerRef {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let child = try await client.call("sessions.side.start", StartSideParams(ref: ref, brief: brief), as: CreateSessionResult.self).ref
        try? await refreshCatalog()
        return child
    }

    /// Your answer to a side card (docs/spec/24 §1): returns the new conversation, and whether to offer Always start.
    @discardableResult
    func answerSide(_ ref: ContainerRef, id: String, choice: String) async throws -> AnswerSideResult {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let result = try await client.call("sessions.side.answer", AnswerSideParams(ref: ref, id: id, choice: choice), as: AnswerSideResult.self)
        try? await refreshCatalog()
        return result
    }

    /// A conversation's side conversations, oldest first.
    func sides(of id: String) -> [SessionSummary] {
        (buildSessions + threads).filter { $0.side?.parent.id == id }.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: A project's work (docs/spec/26)

    func loadWork() async {
        if let list = try? await client?.call("work.list", Empty(), as: WorkListResult.self).work { work = list }
    }

    /// A project's work: its way of working and board; nil until parallel work was first switched on there.
    func work(in project: ProjectInfo) -> ProjectWork? {
        work.first { $0.project == project.id }
    }

    /// How work is done here (docs/spec/26 §4). "" clears a model or the checks; a budget of 0 clears it.
    @discardableResult
    func configureWork(_ params: ConfigureWorkParams) async throws -> ProjectWork {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let result = try await client.call("work.configure", params, as: WorkResult.self).work
        await loadWork()
        return result
    }

    /// "Work in parallel" on Piopio's offer: parallel work goes on, and that conversation plans it.
    func acceptParallel(_ ref: ContainerRef, in project: ProjectInfo) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("work.accept", AcceptWorkParams(project: project.id, sessionId: ref.id), as: WorkResult.self)
        await loadWork()
    }

    /// The playbooks a project can plan with.
    func playbooks(in project: ProjectInfo) async -> [Playbook] {
        (try? await client?.call("work.playbooks", ProjectParams(project: project.id), as: PlaybooksResult.self).playbooks) ?? []
    }

    func addTask(_ project: ProjectInfo, title: String, brief: String) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("work.addTask", AddWorkTaskParams(project: project.id, title: title, brief: brief), as: Empty.self)
        await loadWork()
    }

    func updateTask(_ project: ProjectInfo, _ task: WorkTask, state: String? = nil) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("work.updateTask", UpdateWorkTaskParams(project: project.id, taskId: task.id, state: state), as: Empty.self)
        await loadWork()
    }

    /// A model's display name from its "provider:id".
    func modelName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count == 2 ? parts[1] : raw
        return models.first { $0.id == id && (parts.count < 2 || $0.provider == parts[0]) }?.name ?? id
    }

    /// Home's agenda (docs/spec/21 D2): `since` is your last visit.
    func homeAgenda(since: String?) async -> HomeAgenda? {
        try? await client?.call("home.agenda", HomeAgendaParams(since: since), as: HomeAgenda.self)
    }

    // MARK: Automations (docs/spec/27)

    func loadAutomations() async {
        if let list = try? await client?.call("automations.list", AutomationsParams(), as: AutomationsResult.self).automations {
            automations = list
            automationsGeneration += 1
        }
    }

    /// One automation, its latest runs and its card's words; opening it clears its "New" badge.
    func automation(_ id: String) async -> AutomationDetail? {
        try? await client?.call("automations.get", AutomationIdParams(id: id), as: AutomationDetail.self)
    }

    @discardableResult
    func addAutomation(_ change: AutomationChange) async throws -> Automation {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let made = try await client.call("automations.add", change, as: AutomationResult.self).automation
        await loadAutomations()
        return made
    }

    @discardableResult
    func updateAutomation(_ id: String, _ change: AutomationChange) async throws -> Automation {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        var change = change
        change.id = id
        let changed = try await client.call("automations.update", change, as: AutomationResult.self).automation
        await loadAutomations()
        return changed
    }

    // MARK: Library (docs/spec/35 §4)

    func loadLibrary() async {
        guard let client else { return }
        do {
            let list = try await client.call("library.list", Empty(), as: LibraryList.self)
            library = list.items
            libraryPins = list.pins
            libraryRemoved = list.removed ?? []
            libraryLoaded = true
            libraryFailed = false
        } catch {
            libraryFailed = !libraryLoaded
        }
    }

    /// Put back an item you removed.
    func restoreLibraryItem(_ id: String) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("library.restore", LibraryIdParams(id: id), as: Empty.self)
        await loadLibrary()
    }

    /// The pinned items, in their order: the shelf, and under Library in the sidebar.
    var pinnedLibrary: [LibraryEntry] {
        let byId = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return libraryPins.compactMap { byId[$0] }
    }

    func pinLibrary(_ id: String, _ pinned: Bool) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("library.pin", LibraryPinParams(id: id, pinned: pinned), as: Empty.self)
        await loadLibrary()
    }

    /// A pin dropped on another: it takes that one's place (after it when moving right or down, before it otherwise).
    func movePin(_ id: String, onto target: String) async {
        guard id != target, let from = libraryPins.firstIndex(of: id), let to = libraryPins.firstIndex(of: target) else { return }
        var ids = libraryPins
        ids.remove(at: from)
        ids.insert(id, at: from < to ? min(to, ids.count) : to)
        try? await reorderLibraryPins(ids)
    }

    func reorderLibraryPins(_ ids: [String]) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        // Shown at once (the shelf and the sidebar animate it), before the engine confirms.
        libraryPins = ids
        _ = try await client.call("library.reorder", LibraryIdsParams(ids: ids), as: Empty.self)
        await loadLibrary()
    }

    /// Remove from Library: hidden; the file stays where it is.
    func removeFromLibrary(_ id: String) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("library.remove", LibraryIdParams(id: id), as: Empty.self)
        await loadLibrary()
    }

    @discardableResult
    func addToLibrary(_ path: String) async throws -> LibraryEntry {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let item = try await client.call("library.add", LibraryPathParams(path: path), as: LibraryEntryResult.self).item
        await loadLibrary()
        return item
    }

    /// Show in Library: the file is listed if it wasn't (or comes back if you'd removed it), then the Library selects it.
    func showInLibrary(_ path: String) async throws {
        let item = try await addToLibrary(path)
        libraryFocus = item.id
        NotificationCenter.default.post(name: .selectItem, object: SidebarItem.library.raw)
    }

    /// An app: its page, sources and data, its files read again; the engine watches it until `closeApp`.
    func openApp(_ path: String) async throws -> AppView {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("apps.open", LibraryPathParams(path: path), as: AppResult.self).app
    }

    func refreshApp(_ path: String) async throws -> AppView {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("apps.refresh", LibraryPathParams(path: path), as: AppResult.self).app
    }

    /// Allow: the sources the app's manifest lists now.
    func allowApp(_ path: String) async throws -> AppView {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("apps.allow", LibraryPathParams(path: path), as: AppResult.self).app
    }

    /// The conversation about an app, made the first time (in the app's project, or its own folder).
    func appConversation(_ path: String) async throws -> ContainerRef {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let ref = try await client.call("apps.conversation", LibraryPathParams(path: path), as: AppConversationResult.self).ref
        try? await refreshCatalog()
        return ref
    }

    /// Undo the conversation's latest change to the page (its data stays). CONFLICT: it changed outside Piopio since.
    func undoApp(_ path: String, force: Bool = false) async throws -> AppView {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("apps.undo", AppUndoParams(path: path, force: force), as: AppResult.self).app
    }

    /// Stop reading: the app's sources aren't allowed any more and what it read from calendars is forgotten.
    func revokeApp(_ path: String) async throws -> AppView {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("apps.revoke", LibraryPathParams(path: path), as: AppResult.self).app
    }

    func closeApp(_ path: String) async {
        _ = try? await client?.call("apps.close", LibraryPathParams(path: path), as: Empty.self)
        appUpdates[path] = nil
    }

    /// A visual in the Library: its title and HTML (kept beside the index), for its picture and to show it large.
    func libraryVisual(_ id: String) async -> LibraryVisual? {
        try? await client?.call("library.visual", LibraryIdParams(id: id), as: LibraryVisual.self)
    }

    /// Locate…: where a missing file is now.
    func relocateLibraryItem(_ id: String, to path: String) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("library.relocate", LibraryRelocateParams(id: id, path: path), as: LibraryEntryResult.self)
        await loadLibrary()
    }

    func removeAutomation(_ id: String) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        _ = try await client.call("automations.remove", AutomationIdParams(id: id), as: Empty.self)
        await loadAutomations()
    }

    /// Redo after a card's Undo: it comes back as it was (while the engine still has it).
    @discardableResult
    func restoreAutomation(_ id: String) async throws -> Automation {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let back = try await client.call("automations.restore", AutomationIdParams(id: id), as: AutomationResult.self).automation
        await loadAutomations()
        return back
    }

    /// Run now, even while it's paused.
    func runAutomation(_ id: String) async throws -> AutomationRun {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let run = try await client.call("automations.run", AutomationIdParams(id: id), as: AutomationRunResult.self).run
        try? await refreshCatalog()
        await loadAutomations()
        return run
    }

    /// Who an automation runs as, as a name: "Piopio", or the agent's.
    func runnerName(_ runsAs: String) -> String {
        runsAs == "piopio" ? "Piopio" : (agents.first { $0.ref.id == runsAs }?.title ?? "An agent")
    }

    /// What the work branch would bring to the project's; nil for a project whose work isn't on a branch.
    func landing(_ work: ProjectWork) async -> WorkLanding? {
        guard work.git != nil else { return nil }
        return try? await client?.call("work.landing", ProjectParams(project: work.project), as: WorkLanding.self)
    }

    /// What a conversation's tasks cost so far, and the budget per job.
    func job(_ work: ProjectWork, conversationId: String) async -> WorkJob? {
        try? await client?.call("work.job", WorkJobParams(project: work.project, conversationId: conversationId), as: WorkJob.self)
    }

    /// Before parallel work goes on in a folder (docs/spec/21 D6): git, checks, AGENTS.md.
    func fitCheck(_ cwd: String) async -> FitCheck? {
        try? await client?.call("work.fitCheck", FitCheckParams(cwd: cwd), as: FitCheck.self)
    }

    /// Merges the work branch into the project's ("merge"), or pushes it for a pull request ("push").
    func land(_ work: ProjectWork, action: String) async throws -> WorkLandResult {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let result = try await client.call("work.land", WorkLandParams(project: work.project, action: action), as: WorkLandResult.self)
        await loadWork()
        return result
    }

    /// What changed when teams became ways of working (docs/spec/26 §8), until you dismiss it.
    /// What changed when teams became ways of working (26 §8), else when routines became automations (27 §6), until
    /// you dismiss it.
    func migrationReport() async -> String? {
        if let report = try? await client?.call("work.migrationReport", Empty(), as: MigrationReport.self).report {
            reportFrom = "work"
            return report
        }
        reportFrom = "automations"
        return try? await client?.call("automations.migrationReport", Empty(), as: MigrationReport.self).report
    }

    func dismissMigrationReport() async {
        _ = try? await client?.call("\(reportFrom).dismissMigrationReport", Empty(), as: Empty.self)
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
        inboxCount + buildSessions.filter { liveStatus[$0.ref.id] == .waitingApproval }.count + watchdogNotes.count
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

    // MARK: An agent's files (docs/spec/06-agents §14)

    func agentFiles(_ ref: ContainerRef) async -> AgentFilesResult? {
        try? await client?.call("agents.files", RefParams(ref: ContainerRef(kind: .agent, id: ref.id)), as: AgentFilesResult.self)
    }

    func addAgentFiles(_ ref: ContainerRef, _ attachments: [Attachment]) async throws -> [AgentFile] {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        return try await client.call("agents.files.add", AgentFilesAddParams(ref: ContainerRef(kind: .agent, id: ref.id), attachments: attachments), as: AgentFilesAdded.self).files
    }

    func noteAgentFile(_ ref: ContainerRef, name: String, note: String) async throws {
        try await spaceCall("agents.files.note", AgentFileParams(ref: ContainerRef(kind: .agent, id: ref.id), name: name, note: note))
    }

    func deleteAgentFile(_ ref: ContainerRef, name: String) async throws {
        try await spaceCall("agents.files.delete", AgentFileParams(ref: ContainerRef(kind: .agent, id: ref.id), name: name))
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

    /// Links a folder on the Mac to the project, or changes whether it can be edited (docs/spec/18 §18).
    func linkFolder(_ url: URL, edit: Bool, to project: ProjectInfo) async throws {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine isn't running.") }
        _ = try await client.call("projects.configure", ProjectsConfigureParams(id: project.id, linkFolder: .init(path: url.path, edit: edit)), as: ProjectsAddResult.self)
        await loadProjects()
    }

    /// Unlinks a folder from the project. Nothing on disk changes.
    func unlinkFolder(_ path: String, from project: ProjectInfo) async {
        _ = try? await client?.call("projects.configure", ProjectsConfigureParams(id: project.id, unlinkFolder: path), as: ProjectsAddResult.self)
        await loadProjects()
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
        // A coding agent's models keep its own order (Opus first, docs/spec/31); the rest by name.
        models = list.models.filter { !$0.isAgent }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } + list.models.filter(\.isAgent)
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
}


/// Scripted UI checks never access or modify the user's Keychain.
private actor ScriptedSecrets {
    private var values: [String: String] = [:]
    func get(_ name: String) -> String? { values[name] }
    func set(_ name: String, value: String?) { values[name] = value }
}
