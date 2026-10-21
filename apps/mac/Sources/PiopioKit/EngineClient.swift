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

    private let socketPath: String
    private let queue = DispatchQueue(label: "piopio.engine-client")
    private var connection: NWConnection?
    private var framer = LineFramer()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var reverseHandler: ReverseRequestHandler?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(socketPath: String) {
        self.socketPath = socketPath
        (sessionEvents, eventsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (catalogChanges, catalogContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (projectChanges, projectsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (attention, attentionContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (inboxChanges, inboxContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
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
    public func connectAndHello(client: String, tokenFile: URL) async throws -> HelloResult {
        try await connect()
        let token = try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try await call("engine.hello", HelloParams(token: token, client: client, protocolVersion: protocolVersion), as: HelloResult.self)
    }

    public func call<P: Encodable & Sendable, R: Decodable>(_ method: String, _ params: P, as: R.Type = R.self) async throws -> R {
        guard let connection else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Not connected") }
        let id = nextId
        nextId += 1
        let body = try encoder.encode(Request(id: id, method: method, params: params))
        let line = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            pending[id] = cont
            send(body, on: connection)
        }
        return try decoder.decode(ResultEnvelope<R>.self, from: line).result
    }

    public func close() {
        connection?.cancel()
        connection = nil
        failAll(EngineError(code: "ENGINE_UNAVAILABLE", message: "Connection closed"))
    }

    // MARK: I/O

    private nonisolated func send(_ body: Data, on conn: NWConnection) {
        var framed = body
        framed.append(0x0A)
        conn.send(content: framed, completion: .contentProcessed { _ in })
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
                } else if method == "projects.changed" {
                    if let n = try? decoder.decode(NotificationEnvelope<ProjectsChanged>.self, from: line) {
                        projectsContinuation.yield(n.params.projects)
                    }
                } else if let id = head.id {
                    await answerReverse(id: id, method: method, line: line)
                }
            } else if case .int(let id)? = head.id, let cont = pending.removeValue(forKey: id) {
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
        for cont in waiting.values { cont.resume(throwing: error) }
        eventsContinuation.finish()
        catalogContinuation.finish()
        projectsContinuation.finish()
        attentionContinuation.finish()
        inboxContinuation.finish()
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
