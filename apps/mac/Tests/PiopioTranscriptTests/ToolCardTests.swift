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
    #expect(bashCard.title == "Ran")
    #expect(bashCard.detail == "npm test")
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
    #expect(card.detail == "python3 -c 'print(1)'")
    #expect(card.body.hasPrefix("$ cd /Users/me/app && python3"))
    #expect(card.glyph == "apple.terminal")
}

@Test func theActivityLineFollowsTheOrderThingsHappened() {
    let ran = ToolItem(id: "a", at: "", callId: "a", tool: "bash", args: .object(["command": .string("ls")]), status: .error)
    let read = ToolItem(id: "b", at: "", callId: "b", tool: "read", args: .object(["path": .string("/p/notes.md")]), status: .done)
    let steps = StepsItem(id: "s", at: "", tools: [ran, read], thinking: "Hmm", thinkingMs: 4000)
    let parts = ItemRenderer.activityParts(steps, root: "/p")
    #expect(parts.map(\.text) == ["Thought for 4s", "ran a command (it failed)", "read"])
    #expect(parts[2].chip == "notes.md")
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

/// Board updates and routines in a lead conversation are events, not your messages (docs/spec/20 §4).
@Test @MainActor func boardUpdatesAreEventRowsNotBubbles() {
    let renderer = ItemRenderer()
    // A done task shows in the plan block, not as a line (docs/spec/21 AD9).
    let done = renderer.render(.user(UserItem(id: "u1", at: "", text: "[Board] T1 “Signup form” is done. Merged into team/shop-ab12.\n\nReport:\n> Added the form.")))
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
    // The conversation became the lead's (docs/spec/21 D7): one quiet line.
    let joined = renderer.render(.user(UserItem(id: "u4", at: "", text: "[Board] The user brought in App team; you lead it now, in this conversation.")))
    #expect(joined.string.contains("App team joined · the lead takes it from here"))

    let routine = renderer.render(.user(UserItem(id: "u2", at: "", text: "[Routine] Every Monday at 09:00: Write the brief")))
    #expect(routine.string.contains("Routine · Every Monday at 09:00: Write the brief"))
    #expect(!routine.string.contains("[Routine]"))
}
