import Foundation
import Testing
@testable import PiopioKit

// The engine's protocol against the app's Swift types. The types are generated from the protocol
// (Protocol.generated.swift, by packages/protocol/src/swift.ts), so their shape can't drift by hand; this checks what
// generation alone doesn't: that they read and write what the engine sends, and that the app calls each method with
// the method's own types.
//
// packages/protocol/schema/protocol.samples.json holds samples of every definition (packages/protocol/src/samples.ts:
// the required fields only, and every field across each union's branches). Each must decode into its generated type
// with the app's decoder, and encode back to the same JSON.
//
// When a sample fails, the generator is wrong (packages/protocol/src/swift.ts): fix it there and run
// `corepack pnpm schema`. Don't loosen the check or drop a sample: each failure is a decode the app would fail at run
// time, often silently (a `try?` turns it into nil).

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func samples() throws -> [String: [JSONValue]] {
    let data = try Data(contentsOf: repository.appending(path: "packages/protocol/schema/protocol.samples.json"))
    return try JSONDecoder().decode([String: [JSONValue]].self, from: data)
}

/// Every definition of the schema, by its name in the samples, and the Swift type the app reads or writes it as.
private func everyType() -> [(name: String, type: any (Codable & Sendable).Type)] {
    ProtocolTypes.definitions.map { ($0.key, $0.value) }
        + ProtocolTypes.params.map { ("\($0.key).params", $0.value) }
        + ProtocolTypes.results.map { ("\($0.key).result", $0.value) }
        + ProtocolTypes.notifications.map { ("\($0.key).notification", $0.value) }
        + ProtocolTypes.reverseParams.map { ("\($0.key).params", $0.value) }
        + ProtocolTypes.reverseResults.map { ("\($0.key).result", $0.value) }
}

/// The value without its nulls: a field that's absent and one that's null read the same in a type that only reads it.
private func withoutNulls(_ v: JSONValue) -> JSONValue {
    switch v {
    case .object(let o): .object(o.compactMapValues { $0 == .null ? nil : withoutNulls($0) })
    case .array(let a): .array(a.map(withoutNulls))
    default: v
    }
}

/// Whether `a` is `b` or, for objects, some of `b`'s fields with the same values.
private func isPart(_ a: JSONValue, of b: JSONValue) -> Bool {
    switch (a, b) {
    case (.object(let x), .object(let y)): x.allSatisfy { key, value in y[key].map { isPart(value, of: $0) } ?? false }
    case (.array(let x), .array(let y)): x.count == y.count && zip(x, y).allSatisfy { isPart($0, of: $1) }
    default: a == b
    }
}

/// Why `value` doesn't decode as `type`, or doesn't encode back to itself (to some of itself, for a `partial` type:
/// params several methods share, which send only what all of them take).
private func problem(_ value: JSONValue, _ type: any (Codable & Sendable).Type, partial: Bool) -> String? {
    do {
        let decoded = try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
        let back = withoutNulls(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded)))
        let same = partial ? isPart(back, of: withoutNulls(value)) : back == withoutNulls(value)
        return same ? nil : "encodes back as \(back)"
    } catch {
        return "\(error)"
    }
}

@Test func everySampleDecodesAndEncodesBack() throws {
    let all = try samples()
    let shared = Dictionary(grouping: ProtocolTypes.params.values, by: { ObjectIdentifier($0) }).filter { $0.value.count > 1 }
    var problems: [String] = []
    for (name, type) in everyType().sorted(by: { $0.name < $1.name }) {
        guard let values = all[name] else { problems.append("\(name): no samples (is the schema current?)"); continue }
        let partial = name.hasSuffix(".params") && shared[ObjectIdentifier(type)] != nil
        for (i, value) in values.enumerated() {
            if let p = problem(value, type, partial: partial) { problems.append("\(name) sample \(i) as \(type): \(p)") }
        }
    }
    #expect(problems.isEmpty, "\(problems.count) samples don't round-trip:\n\(problems.prefix(40).joined(separator: "\n"))")
}

@Test func everyDefinitionHasASwiftType() throws {
    let typed = Set(everyType().map(\.name))
    let missing = try samples().keys.filter { !typed.contains($0) }.sorted()
    #expect(missing.isEmpty, "No generated Swift type for \(missing.joined(separator: ", ")): run `corepack pnpm schema`")
}

/// Every `client.call("m", P(…), as: R.self)` in the app's sources uses m's generated types: P its params, R its result.
@Test func theAppCallsEachMethodWithItsTypes() throws {
    let results = try NSRegularExpression(pattern: #"call\("([A-Za-z.]+)",[^\n]*?as: ([A-Za-z0-9_.]+)\.self"#)
    let params = try NSRegularExpression(pattern: #"call\("([A-Za-z.]+)", ([A-Z][A-Za-z0-9_]*)\("#)
    let last = { (s: String) in s.split(separator: ".").last.map(String.init) ?? s }
    var problems: [String] = []
    for folder in ["apps/mac/App", "apps/mac/Sources"] {
        let files = FileManager.default.enumerator(at: repository.appending(path: folder), includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let group = { (m: NSTextCheckingResult, i: Int) in String(text[Range(m.range(at: i), in: text)!]) }
            for match in results.matches(in: text, range: range) {
                let method = group(match, 1), type = group(match, 2)
                guard let expected = ProtocolTypes.results[method] else { problems.append("\(file.lastPathComponent) calls \(method), which the engine's protocol doesn't have"); continue }
                if last(String(describing: expected)) != last(type) { problems.append("\(file.lastPathComponent) reads \(method) as \(type); its result is \(expected)") }
            }
            for match in params.matches(in: text, range: range) {
                let method = group(match, 1), type = group(match, 2)
                guard let expected = ProtocolTypes.params[method] else { continue }
                if last(String(describing: expected)) != type { problems.append("\(file.lastPathComponent) sends \(method) a \(type); its params are \(expected)") }
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
