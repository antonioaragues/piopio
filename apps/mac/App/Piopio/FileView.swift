import AppKit
import PDFKit
import PiopioKit
import PiopioTranscript
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// One file viewer for every place that shows a file (roadmap D8): Build's Files and the file cards, a folder chat's
// preview, and files you sent. Markdown and HTML are rendered (with their source a click away), PDFs and images are
// shown as themselves, code and text get line numbers and highlighting, and anything else goes through Quick Look.

enum FileKind {
    case markdown, html, pdf, image, text, other

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdx", "mdown"].contains(ext) { return .markdown }
        if ["html", "htm", "xhtml"].contains(ext) { return .html }
        if ext == "pdf" { return .pdf }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image), ext != "svg" { return .image }
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) || type.conforms(to: .propertyList) { return .text }
        }
        // No extension, or one the system doesn't know: text when the start has no NUL bytes.
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 8000), !head.isEmpty, !head.contains(0) { return .text }
        }
        return .other
    }

    var icon: String {
        switch self {
        case .markdown, .text: "doc.text"
        case .html: "globe"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .other: "doc"
        }
    }
}

/// A file's content, shown the way its kind reads best. `line` scrolls code to a line and marks it.
struct FileContentView: View {
    let url: URL
    var line: Int?
    @State private var showSource: Bool

    /// HTML opened at a line (a change the agent made) starts on its source, where the line is.
    init(url: URL, line: Int? = nil) {
        self.url = url
        self.line = line
        _showSource = State(initialValue: line != nil && FileKind.of(url) == .html)
    }

    var body: some View {
        if FileManager.default.fileExists(atPath: url.path) { content } else {
            Text("This file isn't here anymore.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var content: some View {
        let kind = FileKind.of(url)
        return VStack(spacing: 0) {
            if kind == .markdown || kind == .html {
                // Build's Files panel is narrow: there Open in browser gives way to its icon.
                ViewThatFits(in: .horizontal) {
                    sourceBar(kind, compact: false)
                    sourceBar(kind, compact: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
            }
            Group {
                switch kind {
                case .markdown: if showSource { CodeLines(url: url, line: line) } else { MarkdownDocument(url: url) }
                case .html: if showSource { CodeLines(url: url, line: line) } else { HTMLFile(url: url) }
                case .pdf: PDFDocumentView(url: url)
                case .image: ImageFile(url: url)
                case .text: CodeLines(url: url, line: line)
                case .other: QuickLookView(url: url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(url)
    }
}

extension FileContentView {
    fileprivate func sourceBar(_ kind: FileKind, compact: Bool) -> some View {
        HStack(spacing: 8) {
            if kind == .html, !showSource {
                Image(systemName: "wifi.slash").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    .help("Offline: this preview reads only the files in this file's folder, nothing from the internet. Open in browser for the full page.")
                    .accessibilityLabel("Offline preview")
            }
            Spacer(minLength: 0)
            if kind == .html {
                Group {
                    if compact {
                        Button { HTMLFile.openInBrowser(url) } label: { Image(systemName: "arrow.up.forward.app") }
                            .buttonStyle(IconButtonStyle()).accessibilityLabel("Open in browser")
                    } else {
                        Button("Open in browser") { HTMLFile.openInBrowser(url) }.buttonStyle(PillStyle(compact: true))
                    }
                }
                .help("Open in your default browser, with the network")
            }
            NeutralSegmented(selection: $showSource, options: [(value: false, title: "Rendered"), (value: true, title: "Source")])
                .frame(width: compact ? 150 : 170)
                .accessibilityLabel(kind == .html ? "Show the page rendered or as source" : "Show the Markdown rendered or as source")
        }
    }
}

/// Markdown in the transcript's style, in a reading column; selectable.
private struct MarkdownDocument: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ReadingScrollView()
        let text = NSTextView()
        text.isEditable = false
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.delegate = context.coordinator
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        load(into: text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, context.coordinator.loaded != url else { return }
        load(into: text)
        context.coordinator.loaded = url
    }

    func makeCoordinator() -> Coordinator { Coordinator(url) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var loaded: URL?
        init(_ url: URL) { loaded = url }

        /// A code block's Copy copies; other app links do nothing here; web links open in the browser.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, url.scheme == "piopio-action" else { return false }
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if url.host == "copy-text", let code = parts?.queryItems?.first(where: { $0.name == "text" })?.value {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
            return true
        }
    }

    private func load(into text: NSTextView) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            text.string = "Can't read this file."
            return
        }
        text.textStorage?.setAttributedString(MarkdownRendering.attributed(String(decoding: data.prefix(2_000_000), as: UTF8.self)))
    }

    /// Keeps a reading column of about 680pt, centered in whatever width the viewer has.
    final class ReadingScrollView: NSScrollView {
        override func tile() {
            super.tile()
            guard let text = documentView as? NSTextView else { return }
            let side = max(24, (contentSize.width - 680) / 2)
            if abs(text.textContainerInset.width - side) > 0.5 { text.textContainerInset = NSSize(width: side, height: 24) }
        }
    }
}

/// An HTML file drawn as a page (spec 25 §7, V1). It can read the files in its own folder (a prototype's CSS, scripts
/// and images) and nothing above it; every load from the network is blocked, links out open in your browser only when
/// you click them, and nothing it stores is kept. Scripts run: a prototype needs them, and with no network and no
/// storage there's nowhere for them to send anything.
struct HTMLFile: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // The bundled libraries (spec 25 §5.2), so a visual saved as a file draws here as it did in the conversation.
        config.setURLSchemeHandler(VisualLibrary.shared, forURLScheme: VisualLibrary.scheme)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.setAccessibilityLabel("Preview of \(url.lastPathComponent)")
        context.coordinator.load(url, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded != url { context.coordinator.load(url, in: view) }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stopWatching() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
        private var offline = false
        /// The files the page was drawn from (itself, its CSS, scripts and images) and when each last changed: when
        /// the agent edits one, the page loads again (Build's preview follows the work without a Reload button).
        private var watched: [URL: Date] = [:]
        private var watching: Task<Void, Never>?

        func load(_ url: URL, in view: WKWebView) {
            loaded = url
            Task {
                // The rule goes in before the first load, or the page's first requests would get through.
                if !offline, let rules = await HTMLFile.offline() {
                    view.configuration.userContentController.add(rules)
                    offline = true
                }
                // Both sides resolved the same way: WebKit refuses a file whose path doesn't start with the folder's
                // (/private/tmp against /tmp).
                let file = url.resolvingSymlinksInPath()
                view.loadFileURL(file, allowingReadAccessTo: HTMLFile.readable(for: file))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { [weak self, weak webView] in
                guard let webView else { return }
                let names = (try? await webView.callAsyncJavaScript(
                    "return [...document.querySelectorAll('link[href], script[src], img[src], source[src]')].map(e => e.href || e.src)", arguments: [:], in: nil, contentWorld: .page
                )) as? [String] ?? []
                self?.watch([webView.url].compactMap { $0 } + names.compactMap(URL.init(string:)), in: webView)
            }
        }

        private func watch(_ urls: [URL], in view: WKWebView) {
            watched = Dictionary(urls.filter(\.isFileURL).map { ($0, Self.modified($0) ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
            watching?.cancel()
            watching = Task { [weak self, weak view] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, let view else { return }
                    // A file saved in two steps (written, then renamed into place) can be missing for a moment.
                    if self.watched.contains(where: { url, seen in Self.modified(url).map { $0 != seen } ?? false }) {
                        self.watching = nil
                        view.reload()
                        return
                    }
                }
            }
        }

        func stopWatching() { watching?.cancel(); watching = nil }

        private static func modified(_ url: URL) -> Date? {
            // Not URL.resourceValues: a URL keeps the values it read once, and this asks every second.
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }

        /// The file itself, other pages and anchors in its folder: yes. A web link you clicked: your browser. Anything
        /// else (a script sending the page somewhere, another scheme): no.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let target = action.request.url else { return .cancel }
            if target.isFileURL { return .allow }
            if target.scheme == "about" { return .allow }
            if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(target.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(target)
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            response.canShowMIMEType ? .allow : .cancel
        }
    }

    /// The folder the page may read: its own, unless that's a home folder or above (a page in ~/Downloads may read
    /// ~/Downloads, never all of ~), where it gets only itself.
    static func readable(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        if folder.pathComponents.count <= home.pathComponents.count { return url }
        return folder
    }

    /// Blocks every load that isn't a file or a bundled library: http(s), WebSockets, FTP, anything from elsewhere.
    static func offline() async -> WKContentRuleList? {
        await VisualLibrary.offlineRules(allowing: ["file", "about", "data", "blob", VisualLibrary.scheme])
    }

    /// The page in the browser the system opens web pages with (not Piopio, whatever opens .html files).
    static func openInBrowser(_ url: URL) {
        guard let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Code and text: line numbers and highlighting; the target line marked and scrolled to.
struct CodeLines: View {
    let url: URL
    var line: Int?
    @State private var lines: [String] = []
    @State private var truncated = false
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                Text("Can't read this file.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, text in
                                HStack(spacing: 0) {
                                    Text("\(index + 1)").foregroundStyle(Color.dsFg3).frame(width: 52, alignment: .trailing).padding(.trailing, 12)
                                    Text(Self.highlighted(text)).fixedSize()
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .frame(height: 18)
                                .background(index + 1 == line ? Color.dsAccentSoft : .clear)
                                .id(index + 1)
                            }
                            if truncated {
                                Text("… the file is larger than 2 MB; open it in an editor to see the rest.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(12)
                            }
                        }
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                    }
                    .onChange(of: lines.count) { _, _ in
                        if let line { DispatchQueue.main.async { proxy.scrollTo(line, anchor: .center) } }
                    }
                }
            }
        }
        .task(id: url) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { failed = true; return }
            truncated = data.count > 2_000_000
            lines = String(decoding: data.prefix(2_000_000), as: UTF8.self).components(separatedBy: "\n")
        }
    }

    static func highlighted(_ line: String) -> AttributedString {
        let ns = NSMutableAttributedString(string: line.isEmpty ? " " : line, attributes: [.foregroundColor: DS.fg])
        for (range, token) in Highlighter.tokens(line) where NSMaxRange(range) <= ns.length {
            ns.addAttribute(.foregroundColor, value: Highlighter.color(token), range: range)
        }
        return AttributedString(ns)
    }
}

/// A PDF with continuous pages, zoom to fit, and the page count.
private struct PDFDocumentView: View {
    let url: URL
    @State private var pages = 0

    var body: some View {
        VStack(spacing: 0) {
            PDFKitView(url: url, pages: $pages)
            if pages > 0 {
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                Text(pages == 1 ? "1 page" : "\(pages) pages").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).frame(height: 26)
            }
        }
    }
}

private struct PDFKitView: NSViewRepresentable {
    let url: URL
    @Binding var pages: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        load(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { load(view) }
    }

    private func load(_ view: PDFView) {
        view.document = PDFDocument(url: url)
        let count = view.document?.pageCount ?? 0
        DispatchQueue.main.async { pages = count }
    }
}

/// An image fitted to the viewer; a double-click shows it at its own size. Its pixel size is noted.
private struct ImageFile: View {
    let url: URL
    @State private var actual = false

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            VStack(spacing: 0) {
                Group {
                    if actual {
                        ScrollView([.vertical, .horizontal]) { Image(nsImage: image).padding(16) }
                    } else {
                        Image(nsImage: image).resizable().scaledToFit().padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { actual.toggle() }
                .help(actual ? "Double-click to fit" : "Double-click for actual size")
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                Text("\(Self.pixels(image)) · \(actual ? "actual size" : "fitted")").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).frame(height: 26)
            }
        } else {
            Text("Can't show this image.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
        }
    }

    /// "1200 × 800".
    static func pixels(_ image: NSImage) -> String {
        guard let rep = image.representations.first else { return "" }
        return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
    }
}

/// Everything else (Office documents, Keynote, audio, video…) through Quick Look.
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}

extension Notification.Name {
    /// Show a file (its URL is the object) in the viewer sheet, from anywhere: a file you sent in a conversation.
    static let viewFile = Notification.Name("piopio.viewFile")
}

extension Notification.Name {
    /// Show a visual (a `ShownVisual`) on its own, larger, in a sheet: Open on a visual's card (spec 25 §4.3).
    static let showVisual = Notification.Name("piopio.showVisual")
}

/// A visual to show in the sheet, and where its `piopio.send` goes (the conversation it came from).
struct ShownVisual: Identifiable {
    let id = UUID()
    let title: String
    let html: String
    let send: @MainActor (String) -> Void
    let prefill: @MainActor (String) -> Void
    /// A line under the title: where its buttons' words go, when that isn't the conversation in front of you.
    var note: String? = nil
}

/// Shows visuals posted with `.showVisual` in a sheet (the main window has one).
struct VisualViewerSheet: ViewModifier {
    @State private var shown: ShownVisual?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showVisual)) { note in
                if let visual = note.object as? ShownVisual { shown = visual }
            }
            .sheet(item: $shown) { visual in
                VisualSheet(visual: visual) { shown = nil }
            }
    }
}

/// A visual on its own: its title, the visual scrolling at the sheet's size, Done. A click that sends or fills the
/// composer closes it.
struct VisualSheet: View {
    let visual: ShownVisual
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.3.group").foregroundStyle(Color.dsFg3)
                Text(visual.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                if let note = visual.note { Text(note).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.tail) }
                Spacer()
                Button("Done", action: close).buttonStyle(PillStyle(kind: .strong, compact: true)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            VisualPreview(title: visual.title, html: visual.html)
        }
        .frame(width: 1000, height: 720)
        .background(Color.dsWin)
        .onAppear {
            VisualSheetSender.current = { text, sends in
                close()
                if sends { visual.send(text) } else { visual.prefill(text) }
            }
        }
        .onDisappear { VisualSheetSender.current = nil }
    }
}

/// A file being viewed, for `.sheet(item:)`.
struct ViewedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Shows files posted with `.viewFile` in the viewer sheet (the main window has one). An app opens as an app.
struct FileViewerSheet: ViewModifier {
    let engine: EngineController
    @State private var viewed: ViewedFile?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .viewFile)) { note in
                if let url = note.object as? URL { viewed = ViewedFile(url: url) }
            }
            .sheet(item: $viewed) { file in
                if AppFile.isApp(file.url) { AppSheet(path: file.url.path, engine: engine) } else { FileSheet(url: file.url) }
            }
    }
}

/// A file in a sheet (files you sent, files a chat made): its name and size, Reveal in Finder, Save a copy, Open with the default app, Done.
struct FileSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: FileKind.of(url).icon).foregroundStyle(Color.dsFg3)
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle()).help("Reveal in Finder").accessibilityLabel("Reveal in Finder")
                Button { FileSaving.saveCopy(of: url) } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(IconButtonStyle()).help("Save a copy…").accessibilityLabel("Save a copy")
                Button {
                    dismiss()
                    NotificationCenter.default.post(name: .showInLibrary, object: url.path)
                } label: { Image(systemName: "books.vertical") }
                    .buttonStyle(IconButtonStyle()).help(LibraryMembership.contains(url.path) ? "Show in Library" : "Add to Library")
                    .accessibilityLabel(LibraryMembership.contains(url.path) ? "Show in Library" : "Add to Library")
                Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(PillStyle(compact: true)).help("Open in its default app")
                Button("Done") { dismiss() }.buttonStyle(PillStyle(kind: .strong, compact: true)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            FileContentView(url: url)
        }
        .frame(width: 860, height: 620)
        .background(Color.dsWin)
    }
}
