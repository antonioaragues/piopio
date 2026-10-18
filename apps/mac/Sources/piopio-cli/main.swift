import Foundation
import PiopioKit

// piopio-cli: Phase 0 spike S1 client for the Local Engine.
//
//   piopio-cli chat [--build <dir>] [--model provider/id] [--session <id>] <message…>
//   piopio-cli list
//   piopio-cli key set openrouter        (reads the key from stdin into the Keychain)
//
// Secrets: answers the engine's secrets.get from the Keychain (service "Piopio").

let usage = """
usage: piopio-cli chat [--build <dir>] [--model provider/id] [--session <id>] <message…>
       piopio-cli list
       piopio-cli key set openrouter
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("piopio-cli: \(message)\n".utf8))
    exit(1)
}

func stderr(_ s: String) {
    fflush(stdout)
    FileHandle.standardError.write(Data(s.utf8))
}

func connect() async throws -> EngineClient {
    let home = EngineClient.defaultHome()
    let client = EngineClient(socketPath: home.appending(path: "engine.sock").path)
    await client.setReverseHandler { method, params in
        guard method == "secrets.get", let name = params["name"]?.stringValue else { return .object(["value": .null]) }
        return .object(["value": Keychain.read(name).map(JSONValue.string) ?? .null])
    }
    do {
        _ = try await client.connectAndHello(client: "piopio-cli", tokenFile: home.appending(path: "engine.token"))
    } catch {
        fail("cannot reach the engine at \(home.path) (\(error)). Start it with: node packages/engine/dist/main.js")
    }
    return client
}

func chat(_ args: [String]) async throws {
    var rest = args[...]
    var buildDir: String?
    var model: ModelRef?
    var sessionId: String?
    while let flag = rest.first, flag.hasPrefix("--") {
        rest = rest.dropFirst()
        guard let value = rest.first else { fail("\(flag) needs a value") }
        rest = rest.dropFirst()
        switch flag {
        case "--build": buildDir = URL(fileURLWithPath: value).standardizedFileURL.path
        case "--model":
            let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail("--model expects provider/id, e.g. openrouter/anthropic/claude-haiku-5.5") }
            model = ModelRef(provider: parts[0], id: parts[1])
        case "--session": sessionId = value
        default: fail("unknown flag \(flag)\n\(usage)")
        }
    }
    let text = rest.joined(separator: " ")
    guard !text.isEmpty else { fail(usage) }

    let client = try await connect()
    let kind: ContainerKind = buildDir == nil ? .thread : .build
    let ref: ContainerRef
    if let sessionId {
        ref = ContainerRef(kind: kind, id: sessionId)
    } else {
        ref = try await client.call("sessions.create", CreateSessionParams(kind: kind, cwd: buildDir, model: model), as: CreateSessionResult.self).ref
    }
    let sub = try await client.call("sessions.subscribe", RefParams(ref: ref), as: SubscribeResult.self)
    var transcript = Transcript(snapshot: sub.snapshot)
    stderr("[\(ref.kind.rawValue) \(ref.id)]\n")

    _ = try await client.call("sessions.submit", SubmitParams(ref: ref, text: text, clientRequestId: UUID().uuidString), as: SubmitResult.self)

    var sawRunning = false
    // Print answers from the reduced transcript: whatever text an answer has beyond what was printed.
    var printed: [String: Int] = [:]
    for case .assistant(let a) in transcript.items { printed[a.id] = a.text.count }
    for await batch in client.sessionEvents where batch.subscriptionId == sub.subscriptionId {
        for event in batch.events {
            if case .itemReplaced(let old, let item) = event { printed[item.id] = printed.removeValue(forKey: old) }
            transcript.apply(event)
            switch event {
            case .itemDelta(_, _, .thinking, let delta):
                stderr(delta)
            case .itemAdded(.tool(let t)):
                stderr("\n⚙︎ \(t.tool) \(t.args.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) } ?? "")\n")
            case .itemUpdated(.tool(let t)) where t.status == .done || t.status == .error:
                stderr("  ↳ \(t.status.rawValue)\(t.durationMs.map { " in \(Int($0)) ms" } ?? "")\n")
            case .itemAdded(.system(let s)):
                stderr("\n[\(s.level.rawValue)] \(s.text)\n")
            default: break
            }
            for case .assistant(let a) in transcript.items.suffix(3) {
                let text = a.text
                let done = printed[a.id] ?? 0
                if text.count > done {
                    print(text.dropFirst(done), terminator: "")
                    fflush(stdout)
                    printed[a.id] = text.count
                }
            }
        }
        if transcript.state.status == .running { sawRunning = true }
        if sawRunning, transcript.state.status == .idle { break }
    }
    print()
    let u = transcript.state.usage
    stderr(String(format: "[%.0f in / %.0f out tokens, $%.5f]\n", u.inputTokens, u.outputTokens, u.costUsd))
    await client.close()
}

func list() async throws {
    let client = try await connect()
    let result = try await client.call("sessions.list", ListSessionsParams(), as: ListSessionsResult.self)
    for s in result.sessions {
        print("\(s.ref.kind.rawValue)\t\(s.ref.id)\t\(s.updatedAt)\t\(s.title)")
    }
    await client.close()
}

func setKey(_ args: [String]) throws {
    guard args == ["set", "openrouter"] else { fail(usage) }
    stderr("Paste your OpenRouter API key and press Enter: ")
    guard let raw = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { fail("no key given") }
    try Keychain.write(secretOpenRouter, value: raw)
    stderr("Saved to the Keychain (service \"Piopio\", account \"\(secretOpenRouter)\").\n")
}

let argv = Array(CommandLine.arguments.dropFirst())
do {
    switch argv.first {
    case "chat": try await chat(Array(argv.dropFirst()))
    case "list": try await list()
    case "key": try setKey(Array(argv.dropFirst()))
    default: fail(usage)
    }
} catch {
    fail("\(error)")
}
