import AppKit
import PiopioKit
import Testing
@testable import PiopioTranscript

private let usage = Usage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, costUsd: 0)
private let idle = SessionState(status: .idle, queue: [], model: nil, thinking: nil, usage: usage)

private func user(_ id: String, _ text: String) -> TimelineItem { .user(UserItem(id: id, at: "", text: text)) }
private func answer(_ id: String, _ text: String, status: AssistantItem.Status = .done, thinking: String? = nil) -> TimelineItem {
    var parts: [AssistantPart] = []
    if let thinking { parts.append(AssistantPart(type: .thinking, text: thinking)) }
    if !text.isEmpty || status != .streaming { parts.append(AssistantPart(type: .text, text: text)) }
    return .assistant(AssistantItem(id: id, at: "", parts: parts, status: status))
}
private func snapshot(_ items: [TimelineItem]) -> Snapshot { Snapshot(ref: ContainerRef(kind: .thread, id: "thr"), items: items, state: idle) }

@MainActor
private func loaded(_ items: [TimelineItem], window: Int = 300, page: Int = 10) async -> TranscriptDocument {
    let doc = TranscriptDocument(windowSize: window, pageSize: page)
    doc.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600) // a real viewport: paging depends on it
    await doc.load(snapshot(items))
    return doc
}

@MainActor
private func expectConsistent(_ doc: TranscriptDocument) {
    #expect(doc.renderedLength == doc.text.utf16.count, "segment lengths must add up to the document")
}

@MainActor @Test func loadsASnapshot() async {
    let doc = await loaded([user("1", "Hello"), answer("2", "Hi **there**.\n\n```swift\nlet x = 1\n```")])
    #expect(doc.documentIDs == ["1", "2"])
    #expect(doc.text.contains("Hello"))
    #expect(doc.text.contains("Hi there."))
    #expect(doc.text.contains("let x = 1"))
    expectConsistent(doc)
}

@MainActor @Test func streamsAnAnswerThenSwapsToTheFinalItem() async {
    let doc = await loaded([user("1", "Question")])
    let final = "Intro paragraph.\n\n- one\n- two\n\n```ts\nconst a = 1\n```\n\nDone."
    doc.apply([.itemAdded(user("2", "Another")), .itemAdded(answer("gen:1", "", status: .streaming))])
    var sent = final.startIndex
    while sent < final.endIndex {
        let next = final.index(sent, offsetBy: 3, limitedBy: final.endIndex) ?? final.endIndex
        doc.apply([.itemDelta(itemId: "gen:1", partIndex: 0, partType: .text, textDelta: String(final[sent..<next]))])
        expectConsistent(doc)
        sent = next
    }
    #expect(doc.text.contains("const a = 1"))
    doc.apply([.itemReplaced(oldId: "gen:1", item: answer("42", final))])
    #expect(doc.documentIDs == ["1", "2", "42"])
    expectConsistent(doc)

    let fresh = await loaded([user("1", "Question"), user("2", "Another"), answer("42", final)])
    #expect(doc.text == fresh.text)
}

@MainActor @Test func thinkingStreamsIntoACardBeforeTheText() async {
    let doc = await loaded([])
    doc.apply([.itemAdded(answer("a", "", status: .streaming))])
    doc.apply([.itemDelta(itemId: "a", partIndex: 0, partType: .thinking, textDelta: "Let me think")])
    doc.apply([.itemDelta(itemId: "a", partIndex: 1, partType: .text, textDelta: "The answer.")])
    expectConsistent(doc)
    #expect(doc.text.hasPrefix("\u{FFFC}\n"))
    #expect(doc.text.contains("The answer."))
}

@MainActor @Test func updatesAndRemovesItemsInPlace() async {
    let doc = await loaded([user("1", "a"), answer("2", "first"), user("3", "b")])
    doc.apply([.itemUpdated(answer("2", "second version"))])
    #expect(doc.text.contains("second version"))
    #expect(!doc.text.contains("first"))
    doc.apply([.itemRemoved(itemId: "1")])
    #expect(doc.documentIDs == ["2", "3"])
    expectConsistent(doc)
}

@MainActor @Test func keepsAWindowAndPagesInOlderHistory() async throws {
    let items = (0..<350).map { i in i % 2 == 0 ? user("\(i)", "message \(i)") : answer("\(i)", "answer \(i)") }
    let doc = await loaded(items, window: 300, page: 10)
    #expect(doc.documentIDs.count == 300)
    #expect(doc.documentIDs.first == "50")
    for _ in 0..<200 where !doc.hasPrefetchedPage { try await Task.sleep(for: .milliseconds(5)) }
    doc.loadOlderIfNeeded(force: true)
    #expect(doc.documentIDs.count == 310)
    #expect(doc.documentIDs.first == "40")
    #expect(doc.text.hasPrefix("message 40"))
    expectConsistent(doc)
}
