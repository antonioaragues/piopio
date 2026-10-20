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
