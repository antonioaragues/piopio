import AppKit
import Testing
@testable import PiopioKit
@testable import PiopioTranscript

@Test func parsesUnifiedPatchesIntoDiffRows() {
    let patch = "--- a.ts\n+++ a.ts\n@@ -1,3 +1,3 @@\n keep\n-old\n+new\n+added\n\\ No newline at end of file"
    let parsed = DiffLine.parse(patch)
    #expect(parsed.added == 2)
    #expect(parsed.removed == 1)
    #expect(parsed.lines.map(\.kind) == [.hunk, .context, .removed, .added, .added])
    #expect(parsed.lines[1].text == "keep")
}

@Test func toolCardsFollowTheirDetails() {
    let edit = ToolItem(id: "t1", at: "", callId: "c1", tool: "edit", args: .object(["path": .string("a.ts")]), status: .done,
                        details: .object(["type": .string("diff"), "path": .string("a.ts"), "diff": .string("@@ -1 +1 @@\n-old\n+new")]))
    let editCard = ItemRenderer.toolCard(edit)
    #expect(editCard.title == "Edited")
    #expect(editCard.detail == "a.ts")
    #expect(editCard.expanded)
    #expect(editCard.added == 1 && editCard.removed == 1)

    let bash = ToolItem(id: "t2", at: "", callId: "c2", tool: "bash", args: .object(["command": .string("npm test\necho done")]), status: .error, output: "boom",
                        details: .object(["type": .string("terminal"), "command": .string("npm test"), "exitCode": .number(2)]), durationMs: 1500)
    let bashCard = ItemRenderer.toolCard(bash)
    #expect(bashCard.title == "Command failed")
    #expect(bashCard.detail.isEmpty)
    #expect(bashCard.body == "$ npm test\necho done\n\nboom")
    #expect(bashCard.trailing == "exit 2 · 2s")
    #expect(bashCard.failed)
    #expect(!bashCard.expanded)

    let read = ToolItem(id: "t3", at: "", callId: "c3", tool: "read", args: .object(["path": .string("x.swift"), "offset": .number(10), "limit": .number(5)]), status: .running)
    #expect(ItemRenderer.toolTitle(read) == ("Reading", "x.swift:10–14"))
}

@Test func commandsDropTheProjectsOwnCd() {
    #expect(ItemRenderer.displayCommand("cd /Users/me/app && npm test", root: "/Users/me/app") == ("npm test", nil))
    #expect(ItemRenderer.displayCommand("cd \"/Users/me/app\"; ls", root: "/Users/me/app") == ("ls", nil))
    #expect(ItemRenderer.displayCommand("cd /tmp/other && make", root: "/Users/me/app") == ("make", "other"))
    #expect(ItemRenderer.displayCommand("npm test", root: "/Users/me/app") == ("npm test", nil))

    let bash = ToolItem(id: "t", at: "", callId: "c", tool: "bash", args: .object(["command": .string("cd /Users/me/app && python3 -c 'print(1)'")]), status: .done, output: "1",
                        details: .object(["type": .string("terminal"), "command": .string("x"), "exitCode": .number(0)]), durationMs: 400)
    let card = ItemRenderer.toolCard(bash, root: "/Users/me/app")
    #expect(card.title == "Ran a command")
    #expect(card.detail.isEmpty)
    #expect(card.body.hasPrefix("$ cd /Users/me/app && python3"))
    #expect(card.glyph == "apple.terminal")
}

@Test func commandLabelsKeepTheExactCommandInDetailsAndApprovals() {
    let command = "cd /p && python3 -c 'print(1)'\necho done"
    var item = ToolItem(id: "t", at: "", callId: "c", tool: "bash", args: .object([
        "command": .string(command), "description": .string("  Revisando\n el proyecto  ")
    ]), status: .running, details: .object(["type": .string("terminal"), "command": .string(command)]))
    let card = ItemRenderer.toolCard(item)
    #expect(card.title == "Revisando el proyecto")
    #expect(card.detail.isEmpty)
    #expect(card.body == "$ " + command)
    #expect(card.action?.1 == .copyText(command))
    #expect(ItemRenderer.stepsCard(StepsItem(id: "s", at: "", tools: [item])).title == "Revisando el proyecto…")
    item.status = .pendingApproval
    #expect(ItemRenderer.toolCard(item).detail == command)
    #expect(ItemRenderer.toolCard(item).waiting)
    item.status = .interrupted
    #expect(ItemRenderer.toolCard(item).trailing == "stopped")
    item.args = .object(["command": .string(command), "description": .string(" \n ")])
    #expect(ItemRenderer.toolCard(item).title == "Command stopped")
}

@Test func scriptLabelsDoNotReplaceOrLeakExecutableSource() {
    let code = "// @options: {\"timeout_ms\": 60000}\n// Task: Consultando el roadmap\nawait tools.read({path: '/p/a'})"
    var item = ToolItem(id: "t", at: "", callId: "c", tool: "codemode", args: .object(["code": .string(code)]), status: .done, output: "Read 3 items")
    let card = ItemRenderer.toolCard(item)
    #expect(card.title == "Consultando el roadmap")
    #expect(card.detail.isEmpty)
    #expect(card.body == code + "\n\nRead 3 items")
    #expect(!card.expanded)
    // Historical scripts have no label. A comment after executable code isn't activity metadata.
    item.args = .object(["code": .string("text('done')\n// Task: Not a label")])
    #expect(ItemRenderer.toolCard(item).title == "Ran a script")
    #expect(ItemRenderer.toolCard(item).detail.isEmpty)
    #expect(ItemRenderer.toolCard(item).body.contains("text('done')"))
}

@Test func externalToolsHaveReadableNamesAndInspectableArguments() {
    let item = ToolItem(id: "t", at: "", callId: "c", tool: "mcp__Claude_Docs__read_document", args: .object(["id": .string("doc-42")]), status: .done, output: "Document contents")
    let card = ItemRenderer.toolCard(item)
    #expect(card.title == "Read document")
    #expect(card.detail == "Claude Docs")
    #expect(card.body.contains("mcp__Claude_Docs__read_document"))
    #expect(card.body.contains("doc-42"))
    #expect(card.body.hasSuffix("Document contents"))
    #expect(!card.expanded)
    let unknown = ToolItem(id: "t2", at: "", callId: "c2", tool: "lookupWorkspace", args: .object(["name": .string("piopio")]), status: .running)
    #expect(ItemRenderer.toolCard(unknown).title == "Lookup Workspace")
    #expect(ItemRenderer.toolCard(unknown).body.contains("lookupWorkspace"))
    #expect(ItemRenderer.toolCard(unknown).body.contains("piopio"))
}

@Test func theActivityLineFollowsTheOrderThingsHappened() {
    let ran = ToolItem(id: "a", at: "", callId: "a", tool: "bash", args: .object(["command": .string("ls")]), status: .error)
    let read = ToolItem(id: "b", at: "", callId: "b", tool: "read", args: .object(["path": .string("/p/notes.md")]), status: .done)
    let steps = StepsItem(id: "s", at: "", tools: [ran, read], thinking: "Hmm", thinkingMs: 4000)
    let parts = ItemRenderer.activityParts(steps, root: "/p")
    #expect(parts.map(\.text) == ["Thought for 4s", "ran a command (it failed)", "read"])
    #expect(parts[2].chip == "notes.md")
}

@Test func screenshotsAStepReadShowOnItsActivityLine() throws {
    let json = #"{"kind":"steps","id":"s","at":"","tools":[{"id":"t","at":"","callId":"c","tool":"read","args":{"path":"/tmp/probe.png"},"status":"done","images":[{"name":"probe.png","kind":"image","mimeType":"image/png","stored":"tools/c-1.png"}]}]}"#
    guard case .steps(let steps) = try JSONDecoder().decode(TimelineItem.self, from: Data(json.utf8)) else { Issue.record("not steps"); return }
    let folder = URL(fileURLWithPath: "/home/attachments/ses_1")
    let card = ItemRenderer.stepsCard(steps, attachments: folder)
    #expect(card.images == [CardImage(url: folder.appending(path: "tools/c-1.png"), stored: "tools/c-1.png", name: "probe.png")])
    // The line grows to fit the thumbnails; without the folder there are none.
    #expect(card.height(width: 600) == DisclosureCard.imageLineHeight)
    #expect(ItemRenderer.stepsCard(steps).images.isEmpty)
}

@Test func handedOverFilesOpenAndMissingOnesSaySo() {
    let item = ToolItem(id: "t9", at: "", callId: "c9", tool: "present_files", args: .object(["files": .array([.object(["path": .string("out/report.pdf")])])]), status: .done,
                        details: .object(["type": .string("files"), "files": .array([
                            .object(["path": .string("/p/out/report.pdf"), "name": .string("report.pdf"), "description": .string("The weekly report"), "size": .number(2048)]),
                            .object(["path": .string("/p/gone.csv"), "name": .string("gone.csv"), "missing": .bool(true)]),
                        ])]))
    guard case .files(let files)? = item.typedDetails else { Issue.record("no files"); return }
    #expect(files.map(\.name) == ["report.pdf", "gone.csv"])
    let card = ItemRenderer.fileCard(files[0], root: "/p")
    #expect(card.title == "report.pdf")
    #expect(card.detail == "The weekly report")
    #expect(card.action?.1 == .openFile(path: "/p/out/report.pdf", line: nil))
    let missing = ItemRenderer.fileCard(files[1], root: "/p")
    #expect(missing.failed && missing.trailing == "not found" && missing.action == nil)
    #expect(ItemRenderer.toolTitle(item) == ("Files for you", "report.pdf"))
    let claude = ToolItem(id: "t10", at: "", callId: "c10", tool: "task", args: .object(["description": .string("Fix tests"), "agent": .string("claude")]), status: .running)
    #expect(ItemRenderer.toolTitle(claude) == ("Claude Code working", "Fix tests"))
}

@Test func aCommandAutoReviewRanSaysSoAndWhy() {
    let item = ToolItem(id: "t11", at: "", callId: "c11", tool: "bash", args: .object(["command": .string("pnpm test")]), status: .done, output: "ok",
                        details: .object(["type": .string("terminal"), "command": .string("pnpm test"), "exitCode": .number(0)]), review: "Runs the project's tests.")
    let card = ItemRenderer.toolCard(item)
    #expect(card.trailing.contains("auto-reviewed"))
    #expect(card.body.hasPrefix("# Auto review ran this without asking: Runs the project's tests.\n$ pnpm test"))
    var plain = item
    plain.review = nil
    #expect(!ItemRenderer.toolCard(plain).trailing.contains("auto-reviewed"))
}

@Test func codeSpanPathsWithALineOpenAtThatLine() {
    #expect(ItemRenderer.splitLine("src/app.ts:42") == ("src/app.ts", 42))
    #expect(ItemRenderer.splitLine("src/app.ts:42:5") == ("src/app.ts", 42))
    #expect(ItemRenderer.splitLine("src/app.ts") == ("src/app.ts", nil))
    #expect(ItemRenderer.splitLine("localhost:8080:x") == ("localhost:8080:x", nil))
    #expect(ItemRenderer.splitLine("a:b") == ("a:b", nil))
    #expect(ItemRenderer.splitLine(":12") == (":12", nil))
}

/// Board updates and routines in a conversation are events, not your messages (docs/spec/20 §4).
@Test @MainActor func boardUpdatesAreEventRowsNotBubbles() {
    let renderer = ItemRenderer()
    // A done task shows in the plan block, not as a line (docs/spec/21 AD9).
    let done = renderer.render(.user(UserItem(id: "u1", at: "", text: "[Board] T1 “Signup form” is done. Merged into work/shop-ab12.\n\nReport:\n> Added the form.")))
    #expect(done.length == 0)
    // Sent back: notable, a row with what was said.
    let back = renderer.render(.user(UserItem(id: "u3", at: "", text: "[Board] T1 “Signup form” went back to its Builder (QA, round 2).\n\nNotes:\n> The button is cut off.")))
    var cards: [DisclosureCard] = []
    var styles: [String] = []
    back.enumerateAttributes(in: NSRange(location: 0, length: back.length)) { attrs, _, _ in
        if let a = attrs[.attachment] as? DisclosureAttachment { cards.append(a.card) }
        if let s = attrs[.piopioCard] as? String { styles.append(s) }
    }
    #expect(cards.map(\.title) == ["Board · T1 “Signup form” went back to its Builder (QA, round 2)."])
    #expect(!styles.contains(CardStyle.user.rawValue))
    if case .text(let body) = cards.first?.content { #expect(body.contains("The button is cut off.")) } else { Issue.record("no notes") }
    // You chose to work in parallel (docs/spec/26 CL9): one quiet line.
    let parallel = renderer.render(.user(UserItem(id: "u4", at: "", text: "[Board] The user chose to work in parallel. Plan what they asked above.")))
    #expect(parallel.string.contains("Working in parallel · Piopio puts the parts on the board"))

    let routine = renderer.render(.user(UserItem(id: "u2", at: "", text: "[Routine] Every Monday at 09:00: Write the brief")))
    #expect(routine.string.contains("Routine · Every Monday at 09:00: Write the brief"))
    #expect(!routine.string.contains("[Routine]"))
}

/// A side conversation's report (docs/spec/24 §5): "Message from <title> · finished", the answer under it; two at once
/// are two rows.
@Test @MainActor func sideNotesAreMessageRows() {
    let one = ItemRenderer.sideNotes("[Side] “About page” (ses_1) finished. Its work is on side/about-1, not in this checkout until the user merges it.\n\n> Added about.html.\n> Checked it.")
    #expect(one.count == 1)
    #expect(one[0].title == "Message from About page · finished")
    #expect(one[0].body.contains("Added about.html.\nChecked it."))
    let two = ItemRenderer.sideNotes("[Side] “A” (ses_1) finished.\n\n> a\n\n[Task] “B” (ses_2) was stopped.")
    #expect(two.map(\.title) == ["Message from A · finished", "Result from B · was stopped"])
    #expect(two[0].body == "a")
    let rendered = ItemRenderer().render(.user(UserItem(id: "u1", at: "", text: "[Side] “A” (ses_1) finished.\n\n> a")))
    #expect(!rendered.string.contains("[Side]"))
}

/// Piopio's offer of a side conversation (docs/spec/24 §1): the task, its brief, New conversation and Do it here.
@Test @MainActor func sideOfferIsACardWithTwoChoices() {
    let offer = ToolItem(id: "t1", at: "", callId: "c9", tool: "side_offer", args: .object(["title": .string("Centered start page"), "brief": .string("Bring back the centered start page for + and New project")]), status: .done, output: "Offered.")
    let card = sideOfferModel(ItemRenderer().render(.tool(offer)))
    guard case .offer(let callId, let title, let brief, let project)? = card?.content else { Issue.record("no offer card"); return }
    #expect(callId == "c9" && title == "Centered start page" && brief.hasPrefix("Bring back the centered start page") && project == nil)
    // Room for the eyebrow, a title, two lines of brief and the footer, however long the brief is.
    let long = SideOfferModel(.offer(callId: "c", title: "T", brief: String(repeating: "word ", count: 200), project: nil))
    #expect(long.height(width: 560) == SideOfferModel(.offer(callId: "c", title: "T", brief: String(repeating: "word ", count: 400), project: nil)).height(width: 560))
    #expect(long.height(width: 560) > SideOfferModel(.offer(callId: "c", title: "T", brief: "", project: nil)).height(width: 560))
    let proposed = ToolItem(id: "t2", at: "", callId: "c10", tool: "side_propose", args: .object(["title": .string("Fix the team page"), "why": .string("Same bug")]), status: .done, output: "Proposed.")
    // A proposal is a card with Start while it's open, a grey line once it's dismissed or expired.
    var open = ItemRenderer()
    open.openProposals = ["c10": .distantFuture]
    #expect(open.render(.tool(proposed)).string.contains("Fix the team page"))
    #expect(open.render(.tool(proposed)).string.contains("Start"))
    #expect(ItemRenderer().render(.tool(proposed)).string.contains("Proposed a side conversation · Fix the team page · closed"))
}

/// The Watchdog's word on a board helper (docs/spec/17 §4) is notable: a row in the conversation that made the task.
@Test @MainActor func watchdogBoardNotesAreRows() {
    #expect(ItemRenderer.notable("T2 “Signup form” looks stuck: nothing new for 10 minutes while running `npm test`."))
    #expect(ItemRenderer.notable("T2 “Signup form” is repeating itself: the same command failed 3 times in this turn."))
    #expect(!ItemRenderer.notable("T2 “Signup form” is done."))
}

/// The side-offer card in a rendered item, if it has one.
func sideOfferModel(_ text: NSAttributedString) -> SideOfferModel? {
    var found: SideOfferModel?
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
        if let a = value as? SideOfferAttachment { found = a.model; stop.pointee = true }
    }
    return found
}

@Test func anActivityWhoseOnlyStepIsACommandOpensToItsOutput() {
    let bash = ToolItem(id: "t", at: "", callId: "c", tool: "bash", args: .object(["command": .string("swift test"), "description": .string("Running the tests")]),
                        status: .running, details: .object(["type": .string("terminal"), "command": .string("swift test")]))
    let line = ItemRenderer.stepsCard(StepsItem(id: "s", at: "", tools: [bash]))
    #expect(line.title == "Running the tests…")
    #expect(line.soleCommand?.body == "$ swift test")
    line.expanded = true
    #expect(line.height(width: 600) == line.lineHeight + 4 + line.soleCommand!.bodyHeight(width: 600))
    // With a thought or a second step it's the log, as before.
    #expect(ItemRenderer.stepsCard(StepsItem(id: "s", at: "", tools: [bash], thinking: "Hmm")).soleCommand == nil)
    #expect(ItemRenderer.stepsCard(StepsItem(id: "s", at: "", tools: [bash, bash])).soleCommand == nil)
}

@Test func aThoughtOnItsOwnIsAsTallAsItsText() {
    let thought = DisclosureCard(kind: .thinking, title: "Thought", body: "One short line.")
    thought.expanded = true
    let trailing = DisclosureCard(kind: .thinking, title: "Thought", body: "One short line.\n\n\n")
    trailing.expanded = true
    #expect(thought.height(width: 600) == trailing.height(width: 600))
    #expect(thought.height(width: 600) < DisclosureCard.lineHeight + 30)
}
