import AppKit
import Observation
import PiopioKit

/// Owns the Local Engine: starts it (or attaches to a running one), answers its secret requests from the
/// Keychain, mirrors the session catalog, and fans out session events to open threads.
@Observable @MainActor
final class EngineController {
    enum Status: Equatable { case starting, ready, failed(String) }

    private(set) var status: Status = .starting
    private(set) var threads: [SessionSummary] = []
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
            if try await !connect() {
                try launchEngine()
                var connected = false
                for _ in 0..<100 where !connected {
                    try await Task.sleep(for: .milliseconds(100))
                    connected = try await connect()
                }
                guard connected else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine did not start. See \(home.path)/logs/engine.log") }
            }
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

    func stop() {
        stopping = true
        Task { await client?.close() }
        process?.terminate()
        process = nil
    }

    @ObservationIgnored private var stopping = false

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

    /// Connects to a running engine. Returns false when nothing is listening.
    private func connect() async throws -> Bool {
        guard FileManager.default.fileExists(atPath: socket.path) else { return false }
        let client = EngineClient(socketPath: socket.path)
        await client.setReverseHandler { method, params in
            guard method == "secrets.get", let name = params["name"]?.stringValue else { return .object(["value": .null]) }
            return .object(["value": Keychain.read(name).map(JSONValue.string) ?? .null])
        }
        do {
            _ = try await client.connectAndHello(client: "Piopio.app", tokenFile: home.appending(path: "engine.token"))
        } catch {
            await client.close()
            return false
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
        return true
    }

    private func launchEngine() throws {
        guard let main = Self.engineMain() else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Engine not found. Build it with `pnpm build`.") }
        guard let node = Self.nodeExecutable() else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Node.js ≥ 22.19 not found (looked in /opt/homebrew/bin, /usr/local/bin).") }
        let p = Process()
        p.executableURL = node
        p.arguments = [main.path]
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

    private static func engineMain() -> URL? {
        if let bundled = Bundle.main.url(forResource: "main", withExtension: "js", subdirectory: "engine") { return bundled }
        if let path = Bundle.main.object(forInfoDictionaryKey: "PiopioEngineMain") as? String, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return nil
    }

    private static func nodeExecutable() -> URL? {
        if let bundled = Bundle.main.url(forResource: "node", withExtension: nil, subdirectory: "engine") { return bundled }
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: Catalog

    func refreshCatalog() async throws {
        guard let client else { return }
        threads = try await client.call("sessions.list", ListSessionsParams(kind: .thread), as: ListSessionsResult.self).sessions
    }

    private func applyCatalog(_ change: CatalogChanged) {
        let removed = Set(change.removed.map(\.id))
        var next = threads.filter { !removed.contains($0.ref.id) }
        for s in change.upserted where s.ref.kind == .thread {
            if let i = next.firstIndex(where: { $0.ref.id == s.ref.id }) { next[i] = s } else { next.append(s) }
        }
        threads = next.sorted { $0.updatedAt > $1.updatedAt }
        for id in removed { openThreads[id] = nil }
    }

    func createThread(model: ModelRef? = nil) async -> ContainerRef? {
        guard let client else { return nil }
        return try? await client.call("sessions.create", CreateSessionParams(kind: .thread, model: model ?? preferredModel), as: CreateSessionResult.self).ref
    }

    func rename(_ ref: ContainerRef, to title: String) async {
        _ = try? await client?.call("sessions.rename", RenameParams(ref: ref, title: title), as: Empty.self)
    }

    func delete(_ ref: ContainerRef) async {
        openThreads[ref.id]?.close()
        openThreads[ref.id] = nil
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
        Task { await client?.close() }
        process?.terminate()
        process = nil
        client = nil
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
        if let open = openThreads[ref.id] { return open }
        let t = ThreadModel(ref: ref, engine: self)
        openThreads[ref.id] = t
        return t
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
        guard !(NSApp.isActive && selectedThreadId == thread.ref.id) else { return }
        guard case .assistant(let a)? = thread.document.lastItem else { return }
        let title = threads.first { $0.ref.id == thread.ref.id }?.title ?? "Piopio"
        let failed = a.status == .error
        let body = failed ? (a.error ?? "The request failed.") : String(a.text.replacingOccurrences(of: "\n", with: " ").prefix(180))
        Notifier.shared.answer(threadId: thread.ref.id, title: title, body: body, failed: failed)
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
