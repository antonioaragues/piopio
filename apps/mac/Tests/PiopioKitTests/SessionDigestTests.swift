import Foundation
import Testing
@testable import PiopioKit

@Test func newDocumentsAreWrittenEverythingElseIsChanged() {
    let files = [
        FileChange(path: "out/report.pdf", status: .added, added: 0, removed: 0, binary: true),
        FileChange(path: "notes/summary.md", status: .added, added: 12, removed: 0),
        FileChange(path: "report.py", status: .added, added: 38, removed: 0),
        FileChange(path: "README.md", status: .modified, added: 2, removed: 1),
        FileChange(path: "old.png", status: .deleted, added: 0, removed: 0),
    ]
    let split = SessionDigest.split(files)
    #expect(split.wrote.map(\.path) == ["out/report.pdf", "notes/summary.md"])
    #expect(split.changed.map(\.path) == ["report.py", "README.md", "old.png"])
    #expect(SessionDigest.kind(of: "a/B.XLSX") == "Spreadsheet")
    #expect(SessionDigest.kind(of: "main.swift") == nil)
}

@Test func contextListsWhatYouGaveAndWhatItRead() {
    let cwd = "/p"
    let existing: Set<String> = ["src/app.swift", "docs", "informes/q3.pdf", "README.md"]
    let items: [TimelineItem] = [
        .user(UserItem(id: "u1", at: "", text: "Look at @src/app.swift and (@docs/), then @informes/q3.pdf. Not README.md, me@x.com or https://x.com/a.b",
                       attachments: [AttachmentInfo(name: "shot.png", kind: .image)])),
        .tool(ToolItem(id: "t1", at: "", callId: "c1", tool: "read", args: .object(["path": .string("/p/README.md")]), status: .done)),
        .tool(ToolItem(id: "t2", at: "", callId: "c2", tool: "bash", args: .object(["command": .string("ls")]), status: .done)),
        .steps(StepsItem(id: "s1", at: "", tools: [
            ToolItem(id: "t3", at: "", callId: "c3", tool: "read", args: .object(["path": .string("README.md")]), status: .done),
            ToolItem(id: "t4", at: "", callId: "c4", tool: "read", args: .object(["path": .string("src/app.swift")]), status: .done),
            ToolItem(id: "t5", at: "", callId: "c5", tool: "bash", args: .object(["command": .string("rm -rf /")]), status: .denied),
            ToolItem(id: "t6", at: "", callId: "c6", tool: "bash", args: .object(["command": .string("make")]), status: .pendingApproval),
        ])),
        .user(UserItem(id: "u2", at: "", text: "Again @src/app.swift", attachments: [AttachmentInfo(name: "shot.png", kind: .image, stored: "u2/shot.png")])),
    ]
    let inputs = SessionDigest.inputs(items: items, cwd: cwd) { existing.contains($0.hasSuffix("/") ? String($0.dropLast()) : $0) }
    #expect(inputs.attachments.map(\.name) == ["shot.png"])
    #expect(inputs.attachments.first?.stored == "u2/shot.png")
    #expect(inputs.mentions == ["src/app.swift", "docs/", "informes/q3.pdf"])
    #expect(inputs.read == ["README.md", "src/app.swift"])
    #expect(inputs.commands == 1)
}

@Test func editedFilesAreOnlyWhatItsOwnToolsChanged() {
    let items: [TimelineItem] = [
        .tool(ToolItem(id: "t1", at: "", callId: "c1", tool: "edit", args: .object(["path": .string("/p/src/a.swift")]), status: .done)),
        .steps(StepsItem(id: "s1", at: "", tools: [
            ToolItem(id: "t2", at: "", callId: "c2", tool: "write", args: .object(["path": .string("docs/new.md")]), status: .done),
            ToolItem(id: "t3", at: "", callId: "c3", tool: "edit", args: .object(["path": .string("src/a.swift")]), status: .done),
            ToolItem(id: "t4", at: "", callId: "c4", tool: "edit", args: .object(["path": .string("src/failed.swift")]), status: .error),
            ToolItem(id: "t5", at: "", callId: "c5", tool: "bash", args: .object(["command": .string("git commit -am x")]), status: .done),
        ])),
    ]
    #expect(SessionDigest.inputs(items: items, cwd: "/p", exists: { _ in true }).edited == ["src/a.swift", "docs/new.md"])
}
