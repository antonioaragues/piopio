import Darwin
import Foundation
import Testing
@testable import PiopioKit

/// A one-connection Unix socket server standing in for the engine: it writes lines and reads the client's.
private final class FakeEngine: @unchecked Sendable {
    private let listener: Int32
    private var peer: Int32 = -1
    private let path: String
    private let accepted = DispatchSemaphore(value: 0)

    init(path: String) throws {
        self.path = path
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, byte) in path.utf8.enumerated() { raw[i] = byte }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) } }) == 0,
              listen(listener, 1) == 0 else { throw EngineError(code: "TEST", message: "can't listen on \(path)") }
        DispatchQueue.global().async { [self] in
            peer = accept(listener, nil, nil)
            accepted.signal()
        }
    }

    func send(_ text: String) {
        accepted.wait()
        accepted.signal()
        _ = text.withCString { write(peer, $0, strlen($0)) }
    }

    /// The first line the client writes, or nil after `timeout` seconds.
    func readLine(timeout: Int32) -> String? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(peer, &byte, 1) == 1 {
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return nil
    }

    func close() {
        Darwin.close(peer)
        Darwin.close(listener)
        unlink(path)
    }
}

/// A reverse request whose answer waits on something the engine sends after it (a check that calls back, a browser
/// action that waits for an event) used to hold the receive loop, so what it waited for never arrived.
@Test func aSlowReverseRequestDoesNotHoldUpWhatComesAfterIt() async throws {
    let path = "/tmp/pk-\(UUID().uuidString.prefix(8)).sock"
    let engine = try FakeEngine(path: path)
    defer { engine.close() }
    let client = EngineClient(socketPath: path)
    await client.setReverseHandler { _, _ in
        for await event in client.providerEvents { if case .changed = event { break } }
        return .object(["ok": .bool(true)])
    }
    try await client.connect()
    engine.send(#"{"jsonrpc":"2.0","id":"r1","method":"secrets.get","params":{}}"# + "\n" + #"{"jsonrpc":"2.0","method":"providers.changed","params":{}}"# + "\n")
    let reply = await Task.detached { engine.readLine(timeout: 5) }.value
    #expect(reply?.contains(#""id":"r1""#) == true)
    await client.close()
}
