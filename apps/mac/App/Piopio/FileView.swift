import AppKit
import PDFKit
import PiopioKit
import PiopioTranscript
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// One file viewer for every place that shows a file (roadmap D8): Build's Files and the file cards, a folder chat's
// preview, and a notebook's files. Markdown is rendered (with its source a click away), PDFs and images are shown as
// themselves, code and text get line numbers and highlighting, and anything else goes through Quick Look.

enum FileKind {
    case markdown, pdf, image, text, other

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdx", "mdown"].contains(ext) { return .markdown }
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
    @State private var showSource = false

    var body: some View {
        let kind = FileKind.of(url)
        VStack(spacing: 0) {
            if kind == .markdown {
                HStack {
                    Spacer()
                    NeutralSegmented(selection: $showSource, options: [(value: false, title: "Rendered"), (value: true, title: "Source")])
                        .frame(width: 170)
                        .accessibilityLabel("Show the Markdown rendered or as source")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
            }
            Group {
                switch kind {
                case .markdown: if showSource { CodeLines(url: url, line: line) } else { MarkdownDocument(url: url) }
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

/// A file in a sheet (a notebook's files): its name and size, Open with the default app, Reveal in Finder, Done.
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
