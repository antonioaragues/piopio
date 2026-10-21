import AppKit
import PDFKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Projects in the Chat lens (docs/spec/04-chat §2): the same projects as Build, shown in Chat with their
// sessions, a file browser and a preview pane. Chat-profile sessions are knowledge assistants (no bash, web tools).

/// Chat sidebar: projects shown in Chat, with their sessions (both profiles, P2).
struct ChatProjectsSection: View {
    let engine: EngineController
    @Binding var selection: String?
    @State private var collapsed: Set<String> = []

    var body: some View {
        let projects = engine.projects(in: .chat)
        HStack {
            SectionLabel("Projects")
            Spacer()
            Button { addFolder() } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            .buttonStyle(.plain)
            .help("Add a folder of documents to chat about")
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        if projects.isEmpty {
            Text("Folders of notes or documents you add appear here.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.horizontal, 8)
        }
        ForEach(projects) { project in
            let open = !collapsed.contains(project.id)
            Button {
                if open { collapsed.insert(project.id) } else { collapsed.remove(project.id) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.dsFg3).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 8)
                    Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor.opacity(0.8))
                    Text(project.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("New Session") { newSession(project) }
                if project.lenses.contains(.build) {
                    Button("Show Only in Chat") { Task { await engine.setLenses([.chat], for: project) } }
                } else {
                    Button("Show in Build Too") { Task { await engine.setLenses([.chat, .build], for: project) } }
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
                Divider()
                Button("Remove from Piopio") { Task { await engine.removeProject(project) } }
            }
            if open {
                // Sessions sit under the project: aligned with its name, with a guide line from its folder icon.
                VStack(spacing: 0) {
                    ForEach(engine.sessions(in: project).filter { $0.parent == nil }, id: \.ref.id) { session in
                        row(session)
                    }
                    Button { newSession(project) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 9.5, weight: .semibold))
                            Text("New session").font(.system(size: 12))
                        }
                        .foregroundStyle(Color.dsFg3)
                        .padding(.leading, Self.childIndent).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .overlay(alignment: .topLeading) {
                    Rectangle().fill(Color.dsLine).frame(width: 1).padding(.leading, 29).padding(.vertical, 3)
                }
            }
        }
    }

    private func row(_ session: SessionSummary) -> some View {
        let selected = selection == session.ref.id
        return Button { selection = session.ref.id } label: {
            HStack(spacing: 8) {
                Text(session.title).font(.system(size: 13, weight: selected ? .medium : .regular)).foregroundStyle(Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                if session.profile == .build {
                    Image(systemName: "hammer").font(.system(size: 9.5)).foregroundStyle(Color.dsFg3).help("Started in Build (coding tools)")
                }
            }
            .padding(.leading, Self.childIndent)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(alignment: .leading) {
                // The selection starts at the guide line, so the row still reads as inside the project.
                RoundedRectangle(cornerRadius: DS.Radius.row).fill(selected ? Color.dsAccentSoft : .clear).padding(.leading, 36)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Move to Trash", role: .destructive) {
                if selection == session.ref.id { selection = nil }
                Task { await engine.delete(session.ref) }
            }
        }
    }

    /// Where a project's sessions start: under its name (8 padding + chevron 8 + 7 + folder 14 + 7).
    private static let childIndent: CGFloat = 44

    private func newSession(_ project: ProjectInfo) {
        Task { if let ref = await engine.createBuildSession(in: project, profile: .chat) { selection = ref.id } }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add to Chat"
        panel.message = "Choose a folder of notes or documents. Sessions in it can read, search and write its files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let project = await engine.addProject(url, lens: .chat) else { return }
            if let latest = engine.sessions(in: project).first { selection = latest.ref.id } else { newSession(project) }
        }
    }
}

/// The folder as a tree, loaded as folders open (P3).
struct FileBrowser: View {
    let engine: EngineController
    let cwd: String
    @Binding var selected: String?
    @State private var children: [String: [DirEntry]] = [:]
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                rows(dir: "", depth: 0)
            }
            .padding(8)
        }
        .task(id: cwd) { children[""] = await engine.listDir(cwd, "") }
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
            if entry.kind == .folder, expanded.contains(entry.path) {
                rows(dir: entry.path, depth: depth + 1)
            }
        })
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
    let session: ThreadModel
    let close: () -> Void

    private var url: URL { URL(fileURLWithPath: cwd).appending(path: path) }
    private var ext: String { url.pathExtension.lowercased() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Ask about this") { session.draft = "@\(path) " }.buttonStyle(PillStyle(compact: true)).help("Mentions the file in the composer")
                if let editor = Editor.preferred {
                    Button("Open in \(editor.name)") { editor.open(url.path) }.buttonStyle(PillStyle(compact: true))
                } else {
                    Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(PillStyle(compact: true))
                }
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
