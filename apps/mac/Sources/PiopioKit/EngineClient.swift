import Foundation
import Network

public struct EngineError: Error, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var description: String { message }
    public init(code: String, message: String) { self.code = code; self.message = message }
}

/// Answers engine → client requests (e.g. `secrets.get`). Returns the JSON `result`.
public typealias ReverseRequestHandler = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

/// JSON-RPC 2.0 client for an Engine over a Unix domain socket (Local Engine).
public actor EngineClient {
    public nonisolated let sessionEvents: AsyncStream<SessionEventsNotification>
    private let eventsContinuation: AsyncStream<SessionEventsNotification>.Continuation
    public nonisolated let catalogChanges: AsyncStream<CatalogChanged>
    private let catalogContinuation: AsyncStream<CatalogChanged>.Continuation
    public nonisolated let projectChanges: AsyncStream<[ProjectInfo]>
    private let projectsContinuation: AsyncStream<[ProjectInfo]>.Continuation
    public nonisolated let attention: AsyncStream<SessionAttention>
    private let attentionContinuation: AsyncStream<SessionAttention>.Continuation
    public nonisolated let inboxChanges: AsyncStream<InboxChanged>
    private let inboxContinuation: AsyncStream<InboxChanged>.Continuation
    /// Provider sign-in steps and "providers changed" (docs/spec/10).
    public nonisolated let providerEvents: AsyncStream<ProviderNotification>
    private let providersContinuation: AsyncStream<ProviderNotification>.Continuation

    private let socketPath: String
    private let queue = DispatchQueue(label: "piopio.engine-client")
    private var connection: NWConnection?
    private var framer = LineFramer()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    /// Each waiting call's time limit, cancelled when it's answered.
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var reverseHandler: ReverseRequestHandler?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let limits: (normal: Duration, slow: Duration)

    /// `limits` is for tests: the app waits as long as the protocol says (`callTimeout`, `slowCallTimeout`).
    public init(socketPath: String, limits: (normal: Duration, slow: Duration) = (EngineClient.callTimeout, EngineClient.slowCallTimeout)) {
        self.socketPath = socketPath
        self.limits = limits
        (sessionEvents, eventsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (catalogChanges, catalogContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (projectChanges, projectsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (attention, attentionContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (inboxChanges, inboxContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (providerEvents, providersContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Default Local Engine socket: `$PIOPIO_HOME/engine.sock` or `~/Library/Application Support/Piopio/engine.sock`.
    public static func defaultHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["PIOPIO_HOME"] { return URL(fileURLWithPath: home) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Piopio")
    }

    public func setReverseHandler(_ handler: @escaping ReverseRequestHandler) {
        reverseHandler = handler
    }

    public func connect() async throws {
        let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connection = conn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.set() { cont.resume() }
                case .failed(let error), .waiting(let error):
                    if once.set() { cont.resume(throwing: error) }
                default: break
                }
            }
            conn.start(queue: queue)
        }
        receive(on: conn)
    }

    /// Connects and authenticates with the token file next to the socket.
    public func connectAndHello(client: String, tokenFile: URL, services: [String]? = nil) async throws -> HelloResult {
        try await connect()
        let token = try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try await call("engine.hello", HelloParams(token: token, client: client, protocolVersion: protocolVersion, services: services), as: HelloResult.self)
    }

    /// How long a call waits for its answer: the protocol's CALL_TIMEOUT_MS, SLOW_CALL_TIMEOUT_MS and SLOW_METHODS
    /// (packages/protocol/src/index.ts). ProtocolContractTests checks these against protocol.schema.json.
    public static let callTimeout: Duration = .milliseconds(60_000)
    public static let slowCallTimeout: Duration = .milliseconds(1_800_000)
    public static let slowMethods: Set<String> = [
        "agents.deploy", "agents.export", "agents.retire", "agents.runNow", "apps.refresh", "automations.run",
        "cloud.connect", "cloud.setup", "cloud.update", "endpoints.check", "endpoints.detect", "git.commit", "git.sync",
        "github.clone", "github.repos", "mcp.probe", "memory.export", "packages.install", "packages.preview",
        "packages.update", "providers.models", "providers.verifyKey", "sessions.export", "stats.export",
    ]

    /// A call, and its answer. An engine that doesn't answer in time (stuck, not gone: a closed connection fails every
    /// call at once) ends it with `TIMEOUT`; a late answer is dropped.
    public func call<P: Encodable & Sendable, R: Decodable>(_ method: String, _ params: P, as: R.Type = R.self) async throws -> R {
        guard let connection else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let id = nextId
        nextId += 1
        let body = try encoder.encode(Request(id: id, method: method, params: params))
        let limit = Self.slowMethods.contains(method) ? limits.slow : limits.normal
        let line = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            pending[id] = cont
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                await self?.fail(id, EngineError(code: "TIMEOUT", message: "The engine didn't answer \(method) in \(limit.components.seconds) s."))
            }
            send(body, on: connection, failing: id)
        }
        return try decoder.decode(ResultEnvelope<R>.self, from: line).result
    }

    public func close() {
        connection?.cancel()
        connection = nil
        failAll(EngineError(code: "ENGINE_UNAVAILABLE", message: "Connection closed"))
    }

    // MARK: I/O

    /// Writes one line. With `failing`, a write that fails ends that call with the error instead of leaving it waiting.
    private nonisolated func send(_ body: Data, on conn: NWConnection, failing id: Int? = nil) {
        var framed = body
        framed.append(0x0A)
        conn.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let error, let id, let self else { return }
            Task { await self.fail(id, EngineError(code: "ENGINE_UNAVAILABLE", message: "Couldn't reach the engine: \(error)")) }
        })
    }

    private func fail(_ id: Int, _ error: Error) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private nonisolated func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty { await self.ingest(data) }
                if isComplete || error != nil {
                    await self.close()
                } else {
                    self.receive(on: conn)
                }
            }
        }
    }

    private func ingest(_ chunk: Data) async {
        for line in framer.append(chunk) {
            guard let head = try? decoder.decode(Head.self, from: line) else { continue }
            if let method = head.method {
                if method == "session.events" {
                    if let n = try? decoder.decode(NotificationEnvelope<SessionEventsNotification>.self, from: line) {
                        eventsContinuation.yield(n.params)
                    }
                } else if method == "catalog.changed" {
                    if let n = try? decoder.decode(NotificationEnvelope<CatalogChanged>.self, from: line) {
                        catalogContinuation.yield(n.params)
                    }
                } else if method == "session.attention" {
                    if let n = try? decoder.decode(NotificationEnvelope<SessionAttention>.self, from: line) {
                        attentionContinuation.yield(n.params)
                    }
                } else if method == "inbox.changed" {
                    if let n = try? decoder.decode(NotificationEnvelope<InboxChanged>.self, from: line) {
                        inboxContinuation.yield(n.params)
                    }
                } else if method == "providers.auth" {
                    if let n = try? decoder.decode(NotificationEnvelope<ProviderAuthNotification>.self, from: line) {
                        providersContinuation.yield(.auth(n.params))
                    }
                } else if method == "providers.changed" {
                    providersContinuation.yield(.changed)
                } else if method == "connectors.auth" {
                    if let n = try? decoder.decode(NotificationEnvelope<ConnectorAuthNotification>.self, from: line) {
                        providersContinuation.yield(.connectorAuth(n.params))
                    }
                } else if method == "connectors.changed" {
                    providersContinuation.yield(.connectorsChanged)
                } else if method == "work.changed" {
                    providersContinuation.yield(.workChanged)
                } else if method == "automations.changed" {
                    providersContinuation.yield(.automationsChanged)
                } else if method == "library.changed" {
                    providersContinuation.yield(.libraryChanged)
                } else if method == "apps.data" {
                    if let n = try? decoder.decode(NotificationEnvelope<AppResult>.self, from: line) {
                        providersContinuation.yield(.appData(n.params.app))
                    }
                } else if method == "watchdog.changed" {
                    providersContinuation.yield(.watchdogChanged)
                } else if method == "budget.changed" {
                    let n = try? decoder.decode(NotificationEnvelope<BudgetChanged>.self, from: line)
                    providersContinuation.yield(.budgetChanged(n?.params ?? BudgetChanged(notify: nil)))
                } else if method == "projects.changed" {
                    if let n = try? decoder.decode(NotificationEnvelope<ProjectsChanged>.self, from: line) {
                        projectsContinuation.yield(n.params.projects)
                    }
                } else if let id = head.id {
                    // Answered on its own: a slow one (a browser action, a Keychain prompt, a check that calls the
                    // engine back) held up this loop, and with it every reply and event behind it.
                    Task { await self.answerReverse(id: id, method: method, line: line) }
                }
            } else if case .int(let id)? = head.id, let cont = pending.removeValue(forKey: id) {
                deadlines.removeValue(forKey: id)?.cancel()
                if let error = head.error {
                    cont.resume(throwing: EngineError(code: error.data?.code ?? "INTERNAL", message: error.message))
                } else {
                    cont.resume(returning: line)
                }
            }
        }
    }

    private func answerReverse(id: RPCId, method: String, line: Data) async {
        guard let connection else { return }
        let params = (try? decoder.decode(NotificationEnvelope<JSONValue>.self, from: line).params) ?? .null
        let reply: Data?
        if let reverseHandler {
            do {
                reply = try encoder.encode(ReverseResult(id: id, result: try await reverseHandler(method, params)))
            } catch {
                reply = try? encoder.encode(ReverseError(id: id, error: .init(code: -32000, message: String(describing: error))))
            }
        } else {
            reply = try? encoder.encode(ReverseError(id: id, error: .init(code: -32601, message: "No handler for \(method)")))
        }
        if let reply { send(reply, on: connection) }
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        for cont in waiting.values { cont.resume(throwing: error) }
        eventsContinuation.finish()
        catalogContinuation.finish()
        projectsContinuation.finish()
        attentionContinuation.finish()
        inboxContinuation.finish()
        providersContinuation.finish()
    }
}

// MARK: Wire envelopes

enum RPCId: Codable, Sendable, Hashable {
    case int(Int), string(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .string(try c.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

private struct Request<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: P
}

private struct Head: Decodable {
    struct RPCErrorBody: Decodable { struct Data: Decodable { let code: String }; let code: Int; let message: String; let data: Data? }
    let id: RPCId?
    let method: String?
    let error: RPCErrorBody?
}

private struct ResultEnvelope<R: Decodable>: Decodable { let result: R }
private struct NotificationEnvelope<P: Decodable>: Decodable { let params: P }
private struct ReverseResult: Encodable { let jsonrpc = "2.0"; let id: RPCId; let result: JSONValue }
private struct ReverseError: Encodable {
    struct Body: Encodable { let code: Int; let message: String }
    let jsonrpc = "2.0"
    let id: RPCId
    let error: Body
}

/// Thread-safe one-shot flag for continuation resumption from Network callbacks.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
