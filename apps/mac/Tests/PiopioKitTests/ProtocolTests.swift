import Foundation
import Testing
@testable import PiopioKit

private func decode<T: Decodable>(_ json: String, as: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private let idleState = #"{"status":"idle","queue":[],"usage":{"inputTokens":0,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0,"costUsd":0}}"#

@Test func decodesTimelineItemsByKind() throws {
    let items: [TimelineItem] = try decode("""
    [{"kind":"user","id":"7","at":"2026-10-18T19:56:31Z","text":"hello"},
     {"kind":"assistant","id":"10","at":"2026-10-18T19:56:31Z","parts":[{"type":"thinking","text":"hm"},{"type":"text","text":"Echo"}],"status":"done","model":"faux/faux-1"},
     {"kind":"tool","id":"tool:c1","at":"2026-10-18T19:56:31Z","callId":"c1","tool":"bash","args":{"command":"ls"},"status":"done","output":"a\\nb","durationMs":12},
     {"kind":"system","id":"s1","at":"2026-10-18T19:56:31Z","level":"error","text":"boom"}]
    """)
    #expect(items.map(\.id) == ["7", "10", "tool:c1", "s1"])
    guard case .assistant(let a) = items[1] else { Issue.record("not assistant"); return }
    #expect(a.text == "Echo")
    guard case .tool(let t) = items[2] else { Issue.record("not tool"); return }
    #expect(t.args?["command"]?.stringValue == "ls")
}

@Test func unknownEventTypesAreTolerated() throws {
    let n: SessionEventsNotification = try decode(#"{"subscriptionId":"s","seq":1,"events":[{"type":"item.future","x":1},{"type":"state","state":\#(idleState)}]}"#)
    #expect(n.events.count == 2)
    #expect(n.events[0] == .unknown("item.future"))
}

@Test func transcriptAppliesStreamingAndIdSwap() throws {
    let snapshot: Snapshot = try decode(#"{"ref":{"kind":"thread","id":"thr_1"},"items":[],"state":\#(idleState)}"#)
    var t = Transcript(snapshot: snapshot)
    let batch: SessionEventsNotification = try decode("""
    {"subscriptionId":"s","seq":1,"events":[
      {"type":"item.added","item":{"kind":"user","id":"7","at":"x","text":"hi"}},
      {"type":"item.added","item":{"kind":"assistant","id":"gen:1","at":"x","parts":[],"status":"streaming"}},
      {"type":"item.delta","itemId":"gen:1","partIndex":0,"partType":"text","textDelta":"Hel"},
      {"type":"item.delta","itemId":"gen:1","partIndex":0,"partType":"text","textDelta":"lo"},
      {"type":"item.replaced","oldId":"gen:1","item":{"kind":"assistant","id":"10","at":"x","parts":[{"type":"text","text":"Hello"}],"status":"done"}}
    ]}
    """)
    t.apply(Array(batch.events.prefix(4)))
    guard case .assistant(let streaming) = t.items[1] else { Issue.record("not assistant"); return }
    #expect(streaming.text == "Hello")
    t.apply(Array(batch.events.suffix(1)))
    #expect(t.items.map(\.id) == ["7", "10"])
}

@Test func lineFramerSplitsOnLFOnly() {
    var f = LineFramer()
    #expect(f.append(Data(#"{"a":"x\#u{2028}y"}"#.utf8)).isEmpty)
    let lines = f.append(Data("\r\n{\"b\":1}\n\n{\"c\"".utf8))
    #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":"x\#u{2028}y"}"#, #"{"b":1}"#])
    #expect(f.append(Data(":2}\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == [#"{"c":2}"#])
}

@Test func decodesProvidersAndSignInSteps() throws {
    let list = try decode(#"{"providers":[{"id":"openai","name":"ChatGPT","methods":[{"type":"oauth","label":"Sign in with ChatGPT","subscription":true}],"status":"connected","connectedWith":"oauth","billing":"ChatGPT subscription","featured":true,"models":44}]}"#, as: ProvidersListResult.self)
    #expect(list.providers[0].isConnected)
    #expect(list.providers[0].methods[0].type == .oauth)
    let note = try decode(#"{"loginId":"l1","provider":"github-copilot","event":{"type":"device_code","userCode":"ABCD-1234","verificationUri":"https://github.com/login/device"}}"#, as: ProviderAuthNotification.self)
    #expect(note.event.userCode == "ABCD-1234")
    let model = try decode(#"{"provider":"openai-api","id":"gpt-6-sol","name":"GPT-6 Sol","contextWindow":400000,"maxOutputTokens":128000,"pricing":{"input":2,"output":10,"cacheRead":0,"cacheWrite":0},"supports":{"vision":true,"reasoning":true},"providerName":"OpenAI API","billing":"OpenAI API billing"}"#, as: ModelInfo.self)
    #expect(model.billing == "OpenAI API billing")
}
