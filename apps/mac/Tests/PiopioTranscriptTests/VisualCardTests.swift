import AppKit
import Testing
@testable import PiopioKit
@testable import PiopioTranscript

// Visuals (docs/spec/25 V2).

@Test @MainActor func libraryServesOnlyItsOwnFiles() {
    #expect(VisualLibrary.file(for: URL(string: "piopio-lib://chart.js")!)?.lastPathComponent == "chart.js")
    #expect(VisualLibrary.file(for: URL(string: "piopio-lib://three/addons/controls/OrbitControls.js")!) != nil)
    #expect(VisualLibrary.file(for: URL(string: "piopio-lib://katex/fonts/KaTeX_Main-Regular.woff2")!) != nil)
    #expect(VisualLibrary.file(for: URL(string: "piopio-lib://nope.js")!) == nil)
    #expect(VisualLibrary.file(for: URL(string: "piopio-lib://katex/../../PiopioTranscript.swift")!) == nil)
    #expect(VisualLibrary.file(for: URL(string: "piopio-lib://katex/%2E%2E/LICENSES.txt")!) == nil)
    #expect(VisualLibrary.file(for: URL(string: "file:///etc/passwd")!) == nil)
    #expect(VisualLibrary.mime("js") == "text/javascript" && VisualLibrary.mime("woff2") == "font/woff2")
}

@Test func aFragmentIsWrappedInPiopiosPage() {
    let page = VisualPage.html("<div id=x>Hi</div>", title: "A <b> title")
    #expect(page.hasPrefix("<!doctype html>"))
    #expect(page.contains("Content-Security-Policy") && page.contains("connect-src 'none'"))
    #expect(page.contains("--fg:rgba(") && page.contains("--c1:#4E79A7") && page.contains("prefers-color-scheme: dark"))
    #expect(page.contains(#""three":"piopio-lib://three.js""#))
    #expect(page.contains("window.piopio = Object.freeze"))
    #expect(page.contains("<title>A &lt;b&gt; title</title>"))
    #expect(page.contains("<body>\n<div id=x>Hi</div>\n</body>"))
    #expect(page.contains("html{overflow:hidden}"))
}

@Test func aWholeDocumentKeepsItsHeadAfterOurs() {
    let page = VisualPage.html("<!DOCTYPE html><html><head><style>body{color:red}</style></head><body>x</body></html>", title: "t")
    let csp = page.range(of: "Content-Security-Policy")!.lowerBound
    let theirs = page.range(of: "body{color:red}")!.lowerBound
    #expect(csp < theirs)
    #expect(page.components(separatedBy: "<!doctype html>").count == 2)
    #expect(page.range(of: "<!DOCTYPE html>") == nil)
}

@Test func aSavedVisualHasNoBridge() {
    let page = VisualPage.standalone("<p>x</p>", title: "Saved")
    #expect(!page.contains("Content-Security-Policy"))
    #expect(page.contains("window.piopio = { send: () => {} }"))
    #expect(!page.contains("messageHandlers"))
    #expect(page.contains("html{overflow:auto}"))
    #expect(VisualCardView.fileName("Usage card: three options") == "Usage card - three options.html")
    #expect(VisualCardView.fileName("  ") == "Visual.html")
}

@Test @MainActor func showVisualRendersAsAVisualCard() {
    let item = ToolItem(id: "t1", at: "", callId: "call-1", tool: "show_visual", args: .object(["title": .string("Spending"), "html": .string("<b>chart</b>")]), status: .done)
    let text = ItemRenderer().render(.tool(item))
    var models: [VisualCardModel] = []
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
        if let v = value as? VisualAttachment { models.append(v.model) }
    }
    #expect(models.count == 1)
    #expect(models.first?.title == "Spending" && models.first?.key == "call-1" && models.first?.itemId == "t1")
    #expect(models.first?.height == VisualCardModel.headerHeight + VisualCardModel.placeholderHeight + 1)

    // Refused (too big): the usual tool card, which says so.
    let refused = ToolItem(id: "t2", at: "", callId: "call-2", tool: "show_visual", args: .object(["title": .string("Big"), "html": .string("x")]), status: .error, output: "Not shown")
    #expect(ItemRenderer.toolTitle(refused) == ("Visual not shown", "Big"))
    #expect(TranscriptAction(url: TranscriptAction.openVisual(itemId: "t1").url) == .openVisual(itemId: "t1"))
}
