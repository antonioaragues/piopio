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
    #expect(page.contains("--c1:#4E79A7") && page.contains("prefers-color-scheme: dark"))
    // Every colour is hex, so a script can add alpha: opaque ones #RRGGBB, translucent ones #RRGGBBAA.
    #expect(page.contains("--fg:#1F1F1E;") && page.contains("--red:#C2493F;") && page.contains("--line:#00000014;") && page.contains("--line:#FFFFFF17;"))
    #expect(!page.contains("rgba("))
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

@Test func aHeadInACommentCantMoveTheCSP() {
    // Spliced into the first "<head>", our CSP would land inside the comment and the page would run without it.
    let html = "<!-- <html><head> --><html lang=\"es\"><head><script>fetch('https://x.example')</script></head><body>x</body></html>"
    for page in [VisualPage.html(html, title: "t"), VisualPage.html(html, title: "t", standalone: true)] {
        let csp = page.range(of: "Content-Security-Policy")!.lowerBound
        #expect(csp < page.range(of: "<!--")!.lowerBound)
        #expect(page.hasPrefix("<!doctype html>\n<html><head>\n<meta charset=\"utf-8\">\n<meta http-equiv=\"Content-Security-Policy\""))
        #expect(page.contains("<html lang=\"es\">"))
    }
}

@Test func scriptLinesCountFromAWholeDocument() {
    let page = VisualPage.html("<html><body>\nFIRST", title: "t")
    let lines = page.components(separatedBy: "\n")
    let first = lines.firstIndex(of: "FIRST")! + 1
    let offset = Int(page.firstMatch(of: /const offset = (\d+);/)!.1)!
    #expect(first - offset == 2)
}

@Test @MainActor func aSavedVisualWorksAnywhere() {
    let page = VisualPage.portable(#"<script src="piopio-lib://chart.js"></script><link rel="stylesheet" href="piopio-lib://katex/katex.css"><p>x</p>"#, title: "Saved")
    #expect(page.contains(VisualPage.portableCSP) && page.contains("connect-src 'none'"))
    #expect(page.contains("window.piopio = { send: () => {}, prefill: () => {}, onData: () => {} }"))
    #expect(!page.contains("messageHandlers") && !page.contains("piopio-lib://"))
    #expect(page.contains("Chart.js v4.4.7") && page.contains("url(data:font/woff2;base64,"))
    #expect(!page.contains("importmap"))
    #expect(page.contains("html{overflow:auto}"))
    let three = VisualPage.portable(#"<script type="module">import * as THREE from "three";</script>"#, title: "3D")
    #expect(three.contains(#""three":"data:text/javascript;base64,"#))
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

@Test func scriptLinesCountFromTheModelsHTML() {
    // The bridge subtracts this from the page's line numbers; line 1 of the fragment is the line after <body>.
    let page = VisualPage.html("FIRST\nSECOND", title: "t")
    let lines = page.components(separatedBy: "\n")
    let first = lines.firstIndex(of: "FIRST")! + 1
    let offset = Int(page.firstMatch(of: /const offset = (\d+);/)!.1)!
    #expect(first - offset == 1)
    #expect(!page.contains(VisualPage.lineOffsetMark))
}

@Test @MainActor func aBlockedLoadIsReportedOnce() {
    let report = VisualChecker.Report()
    report.add("Couldn't load https://example.com/a.png")
    report.add("Blocked by the sandbox: https://example.com/a.png")
    report.add("Couldn't load https://example.com/a.png")
    report.add("ReferenceError: x (line 2 of the HTML)")
    report.add("ReferenceError: x (line 2 of the HTML)")
    #expect(report.problems == ["Blocked by the sandbox: https://example.com/a.png", "ReferenceError: x (line 2 of the HTML)"])
    let summary = VisualChecker.summary(.init(width: 700, height: 950, problems: report.problems, loaded: true, jpeg: nil))
    #expect(summary.contains("Drawn at 700 × 950 px.") && summary.contains("taller than the 900 px") && summary.contains("- ReferenceError"))
    #expect(VisualChecker.summary(.init(width: 700, height: 0, problems: [], loaded: false, jpeg: nil)).contains("didn't finish loading"))
    #expect(TranscriptAction(url: TranscriptAction.prefill(text: "Go with B, but…").url) == .prefill(text: "Go with B, but…"))
}

@Test @MainActor func exportsPutTheVisualWhereItsMarkerIs() async {
    #expect(VisualExport.callId(fromMarker: "Y2FsbHw3") == "call|7")
    VisualStore.shared.noteHeight(140, key: "call|7")
    let html = await VisualExport.fill(#"<p>Before</p><div data-piopio-visual="Y2FsbHw3"></div><div data-piopio-visual="bm9wZQ"></div>"#, html: true) { id in
        id == "call|7" ? ("Spending <now>", "<b>chart</b>") : nil
    }
    #expect(html.hasPrefix("<p>Before</p><iframe title=\"Spending &lt;now&gt;\" sandbox=\"allow-scripts\""))
    #expect(html.contains("height:142px") && html.contains("srcdoc=\"&lt;!doctype html&gt;") && html.contains("&lt;b&gt;chart&lt;/b&gt;"))
    #expect(!html.contains("data-piopio-visual"))
    #expect(VisualExport.strip("**Visual: Spending**\n\n<!-- piopio-visual:Y2FsbHw3 -->\n\nAfter") == "**Visual: Spending**\n\nAfter")
}

/// A visual's picture is kept for the newest `maxPictures` only (re-audit 2026-11-25 §5.2: every one stayed in memory).
@Test @MainActor func onlyTheNewestPicturesAreKept() {
    let store = VisualStore()
    let image = NSImage(size: NSSize(width: 1, height: 1))
    for i in 0..<VisualStore.maxPictures { store.notePicture(image, key: "call\(i)") }
    // One drawn again counts as new: the next one past the limit takes the oldest after it.
    store.notePicture(image, key: "call0")
    store.notePicture(image, key: "new")
    #expect(store.pictures.count == VisualStore.maxPictures)
    #expect(store.pictures["call0"] != nil && store.pictures["new"] != nil)
    #expect(store.pictures["call1"] == nil && store.pictures["call2"] != nil)
}

/// A document's scroll observers go with it (re-audit 2026-11-25 §5.2: each closed conversation left three behind).
@Test @MainActor func aDocumentsObserversGoWithIt() {
    weak var gone: TranscriptDocument?
    autoreleasepool {
        let doc = TranscriptDocument()
        gone = doc
    }
    #expect(gone == nil)
}
