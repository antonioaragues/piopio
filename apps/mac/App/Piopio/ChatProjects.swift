import AppKit
import PDFKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Projects in the Chat lens (docs/spec/04-chat §2): the same projects as Build, shown in Chat with their
// sessions, a file browser and a preview pane. Chat-profile sessions are knowledge assistants (no bash, web tools).

/// The folder as a tree, loaded as folders open (P3).
struct FileBrowser: View {
    let engine: EngineController
    let cwd: String
    @Binding var selected: String?
    /// Mentions a file in the session's composer ("@path").
    var mention: ((String) -> Void)?
    @State private var children: [String: [DirEntry]] = [:]
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                rows(dir: "", depth: 0)
            }
            .padding(8)
        }
        .task(id: cwd) {
            children[""] = await engine.listDir(cwd, "")
            await expand(to: selected)
        }
        .onChange(of: selected) { _, path in Task { await expand(to: path) } }
    }

    /// Opens the folders above a file revealed from elsewhere (a path chip in an answer).
    private func expand(to path: String?) async {
        guard let path, path.contains("/") else { return }
        var dir = ""
        for part in path.split(separator: "/").dropLast() {
            dir = dir.isEmpty ? String(part) : "\(dir)/\(part)"
            expanded.insert(dir)
            if children[dir] == nil { children[dir] = await engine.listDir(cwd, dir) }
        }
    }

    private func rows(dir: String, depth: Int) -> AnyView {
        AnyView(ForEach(children[dir] ?? []) { entry in
            Button {
                if entry.kind == .folder {
                    if expanded.contains(entry.path) { expanded.remove(entry.path) } else {
                        expanded.insert(entry.path)
                        if children[entry.path] == nil { Task { children[entry.path] = await engine.listDir(cwd, entry.path) } }
                    }
                } else {
                    selected = entry.path
                }
            } label: {
                HStack(spacing: 6) {
                    if entry.kind == .folder {
                        Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Color.dsFg3).rotationEffect(.degrees(expanded.contains(entry.path) ? 90 : 0)).frame(width: 8)
                    } else {
                        Color.clear.frame(width: 8)
                    }
                    Image(systemName: icon(entry)).font(.system(size: 11)).foregroundStyle(entry.kind == .folder ? Color.accentColor.opacity(0.8) : Color.dsFg3).frame(width: 14)
                    Text(entry.name).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 14 + 4)
                .frame(height: 24)
                .background(selected == entry.path ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { menu(entry) }
            if entry.kind == .folder, expanded.contains(entry.path) {
                rows(dir: entry.path, depth: depth + 1)
            }
        })
    }

    /// Right-click on a file or folder: open it, find it, copy its path, mention it in the chat.
    @ViewBuilder private func menu(_ entry: DirEntry) -> some View {
        let url = URL(fileURLWithPath: cwd).appending(path: entry.path)
        if entry.kind != .folder {
            Button("Preview") { selected = entry.path }
            if let editor = Editor.preferred { Button("Open in \(editor.name)") { editor.open(url.path) } }
            Button("Open with Default App") { NSWorkspace.shared.open(url) }
        } else if let editor = Editor.preferred {
            Button("Open Folder in \(editor.name)") { editor.open(url.path) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        Button("Copy Path") { copy(url.path) }
        Button("Copy Relative Path") { copy(entry.path) }
        if let mention {
            Divider()
            Button("Mention in Chat") { mention(entry.path) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func icon(_ entry: DirEntry) -> String {
        if entry.kind == .folder { return "folder.fill" }
        switch URL(fileURLWithPath: entry.name).pathExtension.lowercased() {
        case "md", "markdown", "txt": return "doc.text"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff": return "photo"
        case "csv", "xlsx", "numbers": return "tablecells"
        default: return "doc"
        }
    }
}

/// A file of the folder: markdown rendered, PDFs, images, other text as is (P3).
struct FilePreview: View {
    let engine: EngineController
    let cwd: String
    let path: String
    let close: () -> Void

    private var url: URL { URL(fileURLWithPath: cwd).appending(path: path) }
    private var ext: String { url.pathExtension.lowercased() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let editor = Editor.preferred {
                    Button("Open in \(editor.name)") { editor.open(url.path) }.buttonStyle(PillStyle(compact: true))
                } else {
                    Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(PillStyle(compact: true))
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Reveal in Finder")
                Button { close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.dsCard)
        .id(path)
    }

    @ViewBuilder private var content: some View {
        switch ext {
        case "pdf": PDFPreview(url: url)
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff":
            if let image = NSImage(contentsOf: url) {
                ScrollView { Image(nsImage: image).resizable().scaledToFit().padding(16) }
            } else {
                Text("Can't show this image").foregroundStyle(Color.dsFg3)
            }
        case "md", "markdown":
            TextPreview(url: url, markdown: true)
        default:
            TextPreview(url: url, markdown: false)
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

/// Markdown in the transcript's style, or plain monospaced text; read-only and selectable.
private struct TextPreview: NSViewRepresentable {
    let url: URL
    let markdown: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 18, height: 16)
        scroll.drawsBackground = false
        load(into: text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let text = scroll.documentView as? NSTextView { load(into: text) }
    }

    private func load(into text: NSTextView) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            text.string = "Can't read this file."
            return
        }
        if data.prefix(8000).contains(0) {
            text.string = "Binary file: open it in an app to see it."
            return
        }
        let string = String(decoding: data.prefix(2_000_000), as: UTF8.self)
        if markdown {
            text.textStorage?.setAttributedString(MarkdownRendering.attributed(string))
        } else {
            text.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: DS.fg]))
        }
    }
}

extension Notification.Name {
    /// Object: a path relative to the session's folder, shown in the Chat lens preview.
    static let previewFile = Notification.Name("piopio.previewFile")
}
