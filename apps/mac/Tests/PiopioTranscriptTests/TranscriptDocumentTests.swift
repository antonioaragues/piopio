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

@MainActor @Test func actionRowsCarryActionsAndBranchSwitchers() async {
    let edited = TimelineItem.user(UserItem(id: "21", at: "", text: "second, edited", branch: BranchInfo(index: 1, count: 2, previous: "1")))
    let failed = TimelineItem.assistant(AssistantItem(id: "24", at: "", parts: [], status: .error, error: "OpenRouter rejected the API key.", errorKind: .auth, errorDetail: "401"))
    let doc = await loaded([edited, failed])
    #expect(doc.text.contains("Open Settings"))
    var actions: [TranscriptAction] = []
    doc.onAction = { actions.append($0) }
    let storage = doc.textView.textStorage!
    var urls: [URL] = []
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in if let u = value as? URL { urls.append(u) } }
    let parsed = urls.compactMap(TranscriptAction.init(url:))
    // Your message: a row with its versions and Edit, shown on hover.
    let row = doc.actionRow("21")
    #expect(row?.branch?.index == 1 && row?.branch?.count == 2)
    #expect(row?.canEdit == true && row?.canRewind == false)
    #expect(row?.visible == false)
    // The failed answer has no text to copy: its card offers the fixes.
    #expect(doc.actionRow("24") == nil)
    #expect(parsed.contains(.regenerate(itemId: "24")))
    #expect(parsed.contains(.openSettings))
    #expect(parsed.contains(.showErrorDetail(itemId: "24")))
    doc.handle(.edit(itemId: "21"))
    #expect(actions == [.edit(itemId: "21")])
    expectConsistent(doc)
}

@MainActor @Test func userBubblesShowAttachmentChipsAndWebToolsHaveTitles() async {
    let user = TimelineItem.user(UserItem(id: "1", at: "", text: "Summarize", attachments: [AttachmentInfo(name: "notes.md", kind: .text), AttachmentInfo(name: "photo.jpg", kind: .image)]))
    let search = TimelineItem.tool(ToolItem(id: "t1", at: "", callId: "c1", tool: "web_search", args: .object(["query": .string("swift 6.4")]), status: .done, output: "results"))
    let doc = await loaded([user, search])
    #expect(doc.text.contains("notes.md"))
    #expect(doc.text.contains("photo.jpg"))
    if case .tool(let t) = search { #expect(ItemRenderer.toolTitle(t) == ("Searched the web", "swift 6.4")) }
    expectConsistent(doc)
}

@MainActor @Test func revealPagesInOldItems() async {
    let items = (0..<400).map { i in i % 2 == 0 ? user("\(i)", "message \(i)") : answer("\(i)", "answer \(i)") }
    let doc = await loaded(items, window: 300, page: 10)
    #expect(doc.documentIDs.first == "100")
    doc.reveal("20")
    #expect(doc.documentIDs.first == "20")
    #expect(doc.documentIDs.count == 380)
    expectConsistent(doc)
}

@MainActor @Test func latestAnswerKeepsItsActionsAfterAResnapshot() async throws {
    let doc = await loaded([user("1", "first"), answer("2", "one")])
    #expect(doc.actionRow("2")?.visible == true)
    #expect(doc.actionRow("2")?.canRetry == true)
    #expect(doc.actionRow("1")?.visible == false)
    // An edit: the engine resnapshots onto the new branch, then streams the new answer.
    let branch = TimelineItem.user(UserItem(id: "5", at: "", text: "first, edited", branch: BranchInfo(index: 1, count: 2, previous: "1")))
    doc.apply([.resnapshot(snapshot([branch]))])
    doc.apply([.itemAdded(answer("gen:1", "", status: .streaming)), .itemDelta(itemId: "gen:1", partIndex: 0, partType: .text, textDelta: "Echo")])
    doc.apply([.itemReplaced(oldId: "gen:1", item: answer("7", "Echo"))])
    for _ in 0..<100 where doc.documentIDs != ["5", "7"] { try await Task.sleep(for: .milliseconds(10)) }
    #expect(doc.documentIDs == ["5", "7"])
    #expect(doc.actionRow("7")?.visible == true)
    expectConsistent(doc)
}

@MainActor @Test func projectPathsShowRelativeAsChips() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("piopio-root-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: root + "/RESUMEN.md", contents: Data())
    let doc = TranscriptDocument(build: true, root: root)
    await doc.load(snapshot([user("1", "summary please"), answer("2", "Created `\(root)/RESUMEN.md` and `RESUMEN.md`; see \(root)/docs/a.md.")]))
    #expect(!doc.text.contains(root + "/"))
    #expect(doc.text.contains("RESUMEN.md"))
    #expect(doc.text.contains("docs/a.md"))
    let storage = doc.textView.textStorage!
    var reveals: [TranscriptAction] = []
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { v, _, _ in if let u = v as? URL, let a = TranscriptAction(url: u) { reveals.append(a) } }
    #expect(reveals.filter { $0 == .revealFile(path: root + "/RESUMEN.md") }.count == 2)
    #expect(doc.actionRow("1")?.canRewind == true)
    expectConsistent(doc)
}

@MainActor @Test func askNextStaysAtTheEnd() async {
    let doc = await loaded([user("1", "hi"), answer("2", "hello")])
    let before = doc.text
    doc.showAskNext(["More", "Less"])
    #expect(doc.askNext.items == ["More", "Less"])
    doc.apply([.itemAdded(user("3", "again"))])
    // New items go before the suggestions; hiding them leaves exactly the items.
    #expect(doc.text.contains("again"))
    doc.showAskNext(nil)
    #expect(doc.text.hasPrefix(before))
    #expect(doc.renderedLength == (doc.textView.textStorage?.length ?? 0))
    expectConsistent(doc)
}

@MainActor @Test func columnRecentersWhenTheViewNarrows() async throws {
    let doc = await loaded([user("1", "hi"), answer("2", "hello")])
    // The column is 680 wide, centered, with at least 40 on each side (of the clip view, which leaves room for a scroller).
    func expected() -> CGFloat { max(40, (doc.scrollView.contentView.bounds.width - 680) / 2) }
    for width in [1400.0, 1000.0, 600.0] {
        doc.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        for _ in 0..<50 where abs(doc.textView.textContainerInset.width - expected()) > 0.5 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(abs(doc.textView.textContainerInset.width - expected()) < 0.5, "inset \(doc.textView.textContainerInset.width) clip \(doc.scrollView.contentView.bounds.width) frame \(width)")
    }
}

@Test @MainActor func onlyTheTurnsLastTextHasAnActionRow() async {
    let steps = answer("s1", "") // a step that only called tools
    let items = [user("1", "research this"), answer("2", "Let me look around."), steps, answer("3", "Here's the synthesis."), user("4", "thanks"), answer("5", "You're welcome.")]
    let doc = await loaded(items)
    #expect(TranscriptDocument.midTurn(items) == ["2"])
    #expect(doc.actionRow("2") == nil)
    #expect(doc.actionRow("3") != nil)
    #expect(doc.actionRow("5") != nil)
    // The turn goes on: the text that was last loses its row, the new one gets it.
    let more = answer("s2", "")
    doc.apply([.itemAdded(more), .itemAdded(answer("6", "And one more thing."))])
    #expect(TranscriptDocument.midTurn(items + [more, answer("6", "And one more thing.")]) == ["2", "5"])
    #expect(doc.actionRow("5") == nil)
    #expect(doc.actionRow("6") != nil)
    expectConsistent(doc)
}

@Test func tablesDrawnWithSpacesBecomeTables() {
    let code = """
    Dimension          ESPHome                          Voice & Assist
    **Value prop**     Own your hardware; no cloud      Own your voice; private, local
    **Wedge**          YAML power + ESP32 ubiquity      Open hardware (VPE) + HA
    **Moat**           Component ecosystem              Hardware platform
    """
    let table = TableContent.spaced(code)
    #expect(table?.header == ["Dimension", "ESPHome", "Voice & Assist"])
    #expect(table?.rows.count == 3)
    #expect(table?.rows[0] == ["**Value prop**", "Own your hardware; no cloud", "Own your voice; private, local"])
    // Code stays code.
    #expect(TableContent.spaced("let a = 1\nlet b = 2\nprint(a + b)") == nil)
    #expect(TableContent.spaced("one  two\nthree") == nil)
    // Columns fill the width and wrap: a narrow table is taller than a wide one.
    let t = table!
    #expect(abs(t.widths(for: 600).reduce(0, +) - 600) < 1)
    #expect(t.height(width: 300) > t.height(width: 900))
}

@Test func messageTimesReadNaturally() {
    let now = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
    #expect(MessageTime.relative(now.addingTimeInterval(-20), now: now) == "now")
    #expect(MessageTime.relative(now.addingTimeInterval(-180), now: now) == "3 min ago")
    #expect(MessageTime.relative(now.addingTimeInterval(-2 * 3600), now: now) == "2 h ago")
    #expect(MessageTime.relative(now.addingTimeInterval(-26 * 3600), now: now).hasPrefix("Yesterday, "))
    let older = MessageTime.relative(now.addingTimeInterval(-10 * 86_400), now: now) // "17 Oct, …", "Oct 17, …" or "17 oct, …" by locale
    #expect(older.contains("17") && older.contains(", "))
    #expect(ItemRenderer.date("2026-10-27T11:56:00.123Z") != nil)
    #expect(ItemRenderer.date("") == nil)
}
