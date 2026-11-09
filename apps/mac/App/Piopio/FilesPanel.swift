import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// The Files panel (docs/design/inspector, option 3a): the project as a tree with what the agent touched marked (N new,
// M changed, R read), a filter, All or Touched, and a file's preview in the same panel (Diff or File).

enum FilesFilter: String { case all, touched }

/// What the agent did to a path: new, changed or read.
enum TouchMark: Comparable {
    case read, changed, new

    var letter: String { switch self { case .new: "N"; case .changed: "M"; case .read: "R" } }
    var color: Color { switch self { case .new: .dsGreen; case .changed: .dsWarn; case .read: .dsRead } }
    var word: String { switch self { case .new: "new"; case .changed: "modified"; case .read: "read" } }
}

struct FilesPanel: View {
    let engine: EngineController
    let session: ThreadModel
    let summary: SessionSummary
    let cwd: String
    @Binding var filter: FilesFilter
    /// The file shown in place of the tree (relative to the project), or nil for the tree.
    @Binding var preview: String?
    /// Mentions a file in the composer ("@path").
    let mention: (String) -> Void
    @State private var changes: [FileChange] = []
    @State private var query = ""
    @State private var matches: [FileMatch] = []
    @FocusState private var searching: Bool

    /// What this agent touched: the files it read and the ones it wrote or edited with its tools. Not everything that
    /// changed in the folder since the session started, which also counts your commits and other agents' work.
    private var marks: [String: TouchMark] {
        var out: [String: TouchMark] = [:]
        let inputs = SessionDigest.inputs(items: session.document.items, cwd: cwd, exists: { _ in true })
        for path in inputs.read where !path.hasPrefix("/") { out[path] = .read }
        let added = Set(changes.filter { $0.status == .added }.map(\.path))
        for path in inputs.edited where !path.hasPrefix("/") { out[path] = added.contains(path) ? .new : .changed }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            if let path = preview {
                FilePreviewPane(engine: engine, session: session, cwd: cwd, path: path, change: changes.first { $0.path == path },
                                mark: marks[path], back: { preview = nil }, mention: mention)
            } else {
                tree
            }
            InspectorFooter(thread: session)
        }
        .task(id: session.revision / 4) { changes = await session.changes(since: .session) }
        .onReceive(NotificationCenter.default.publisher(for: .focusFileFilter)) { _ in preview = nil; searching = true }
    }

    // MARK: Tree

    private var tree: some View {
        let marks = self.marks
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("", text: $query, prompt: Text("Filter files").foregroundStyle(Color.dsFg3))
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
                    .onSubmit { if let first = matches.first(where: { $0.kind == .file }) { preview = first.path } }
                Text("⌘P").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            NeutralSegmented(selection: $filter, options: [(.all, "All"), (.touched, marks.isEmpty ? "Touched" : "Touched \(marks.count)")])
            HStack {
                Text(URL(fileURLWithPath: cwd).lastPathComponent)
                Spacer(minLength: 6)
                Text(BuildSummaryPaths.parent(cwd)).lineLimit(1).truncationMode(.head)
            }
            .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            .padding(.horizontal, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(matches) { match in
                            FileTreeRow(name: match.path, depth: 0, folder: match.kind == .folder, open: false, mark: marks[match.path], dot: false, selected: false) {
                                if match.kind == .file { preview = match.path }
                            }
                        }
                        if matches.isEmpty { Text("No files match.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(8) }
                    } else if filter == .touched {
                        TouchedTree(marks: marks) { preview = $0 }
                        if marks.isEmpty { Text("Nothing touched yet.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(8) }
                    } else {
                        LazyFileTree(engine: engine, cwd: cwd, marks: marks) { preview = $0 }
                    }
                }
            }
            legend
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { matches = []; return }
            try? await Task.sleep(for: .milliseconds(120))
            matches = await session.files(matching: q)
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            ForEach([TouchMark.new, .changed, .read], id: \.self) { mark in
                Text(mark.letter).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(mark.color)
                Text(mark == .new ? "new" : mark == .changed ? "changed" : "read")
                if mark != .read { Text("·") }
            }
        }
        .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
        .padding(.horizontal, 8)
    }
}

/// "~/Proyectos" for a folder's parent.
enum BuildSummaryPaths {
    static func parent(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

/// A row of the tree: caret, name, and on the right the mark letter (a file) or a dot (a folder with something inside).
struct FileTreeRow: View {
    let name: String
    let depth: Int
    let folder: Bool
    let open: Bool
    let mark: TouchMark?
    let dot: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(folder ? (open ? "▾" : "▸") : "").font(.system(size: 9)).foregroundStyle(Color.dsFg3).frame(width: 10)
                Text(name).font(.system(size: 13)).foregroundStyle(mark != nil || folder ? Color.dsFg : Color.dsFg2)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let mark { Text(mark.letter).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(mark.color).help(mark.word) }
                else if dot { Text("•").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.dsWarn).help("Something inside was touched") }
            }
            .padding(.leading, CGFloat(8 + depth * 14)).padding(.trailing, 8).padding(.vertical, 4)
            .background(selected ? Color.dsAccentSoft : hovering ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The whole project, loaded as folders open; touched files carry their letter, folders a dot.
struct LazyFileTree: View {
    let engine: EngineController
    let cwd: String
    let marks: [String: TouchMark]
    let open: (String) -> Void
    @State private var children: [String: [DirEntry]] = [:]
    @State private var expanded: Set<String> = []

    var body: some View {
        // In a stack: an empty ForEach never appears, so a task on it alone never loaded the first level.
        VStack(alignment: .leading, spacing: 1) { rows(dir: "", depth: 0) }
            .task(id: cwd) { children[""] = await engine.listDir(cwd, "") }
    }

    private func rows(dir: String, depth: Int) -> AnyView {
        AnyView(ForEach(children[dir] ?? []) { entry in
            let folder = entry.kind == .folder
            FileTreeRow(name: entry.name, depth: depth, folder: folder, open: expanded.contains(entry.path), mark: folder ? nil : marks[entry.path],
                        dot: folder && marks.keys.contains { $0.hasPrefix(entry.path + "/") }, selected: false) {
                if folder {
                    if expanded.contains(entry.path) { expanded.remove(entry.path) } else {
                        expanded.insert(entry.path)
                        if children[entry.path] == nil { Task { children[entry.path] = await engine.listDir(cwd, entry.path) } }
                    }
                } else {
                    open(entry.path)
                }
            }
            if folder, expanded.contains(entry.path) { rows(dir: entry.path, depth: depth + 1) }
        })
    }
}

/// Only what was touched, as a tree with every folder open.
struct TouchedTree: View {
    let marks: [String: TouchMark]
    let open: (String) -> Void

    private struct Line: Identifiable { let id: String; let name: String; let depth: Int; let folder: Bool }

    /// Folders first at each level, then files, by name.
    private var lines: [Line] {
        var out: [Line] = []
        func walk(_ prefix: String, _ paths: [String], depth: Int) {
            var folders: [String: [String]] = [:], files: [String] = []
            for path in paths {
                if let slash = path.firstIndex(of: "/") {
                    folders[String(path[..<slash]), default: []].append(String(path[path.index(after: slash)...]))
                } else {
                    files.append(path)
                }
            }
            for name in folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                out.append(Line(id: prefix + name + "/", name: name, depth: depth, folder: true))
                walk(prefix + name + "/", folders[name]!, depth: depth + 1)
            }
            for name in files.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                out.append(Line(id: prefix + name, name: name, depth: depth, folder: false))
            }
        }
        walk("", Array(marks.keys), depth: 0)
        return out
    }

    var body: some View {
        ForEach(lines) { line in
            FileTreeRow(name: line.name, depth: line.depth, folder: line.folder, open: true, mark: line.folder ? nil : marks[line.id], dot: line.folder, selected: false) {
                if !line.folder { open(line.id) }
            }
        }
    }
}

// MARK: Preview

/// A file in place of the tree: back, where it is, what happened to it, Diff or File, and Open in editor / Mention.
struct FilePreviewPane: View {
    let engine: EngineController
    let session: ThreadModel
    let cwd: String
    let path: String
    let change: FileChange?
    let mark: TouchMark?
    let back: () -> Void
    let mention: (String) -> Void
    @State private var showDiff: Bool
    /// You picked Diff or File; until then it follows whether the file changed (its change may arrive after it opens).
    @State private var chosen = false
    @State private var rows: [UnifiedDiff.Row] = []

    init(engine: EngineController, session: ThreadModel, cwd: String, path: String, change: FileChange?, mark: TouchMark?, back: @escaping () -> Void, mention: @escaping (String) -> Void) {
        self.engine = engine; self.session = session; self.cwd = cwd; self.path = path; self.change = change; self.mark = mark
        self.back = back; self.mention = mention
        _showDiff = State(initialValue: change != nil && change?.status != .deleted)
    }

    private var url: URL { URL(fileURLWithPath: cwd).appending(path: path) }
    private var folder: String { let d = (path as NSString).deletingLastPathComponent; return d.isEmpty ? "" : d + " /" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            Group {
                if showDiff { diff } else { FileContentView(url: url) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack(spacing: 16) {
                SummaryLink("Open in editor") { if let editor = Editor.preferred { editor.open(url.path) } else { NSWorkspace.shared.open(url) } }
                    .help(Editor.preferred.map { "Open in \($0.name)" } ?? "Open in its default app")
                SummaryLink("Mention in chat") { mention(path) }.help("Add @\(path) to your message")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .id(path)
        .task(id: showDiff) { if showDiff { rows = UnifiedDiff(await session.diff(path, since: .session)).rows } }
        .onChange(of: change) { _, change in if !chosen { showDiff = change != nil && change?.status != .deleted } }
        .onExitCommand(perform: back)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: back) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Color.dsFg2).help("Back to the files (Esc)")
                if !folder.isEmpty { Text(folder).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.head) }
                // The name keeps its room; the folder gives way first.
                Text(URL(fileURLWithPath: path).lastPathComponent).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            HStack(spacing: 6) {
                if let mark {
                    Text(mark.word).font(.system(size: 10.5)).foregroundStyle(mark.color)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(mark.color.opacity(0.45), lineWidth: 1))
                }
                if let change { DiffCounts(added: change.added, removed: change.removed) }
                if let kind = SessionDigest.kind(of: path) { Text("· \(kind)").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                Spacer(minLength: 6)
                if change != nil {
                    MiniSegmented(left: "Diff", right: "File", leftOn: Binding(get: { showDiff }, set: { showDiff = $0; chosen = true }))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var diff: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.kind == .hunk ? "" : (row.new ?? row.old).map(String.init) ?? "")
                            .foregroundStyle(Color.dsFg3).frame(width: 26, alignment: .trailing)
                        Text(row.kind == .added ? "+" : row.kind == .removed ? "−" : " ").foregroundStyle(row.kind == .added ? Color.dsGreen : Color.dsRed)
                        Text(row.text).foregroundStyle(row.kind == .hunk ? Color.dsFg3 : Color.dsFg).fixedSize()
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(3)
                    .padding(.vertical, 1.5).padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(row.kind == .added ? Color.dsGreen.opacity(0.12) : row.kind == .removed ? Color.dsRed.opacity(0.12) : .clear)
                }
                if rows.isEmpty { Text("No changes in this session.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(14) }
            }
            .padding(.vertical, 8)
        }
    }
}

/// A two-option control the size of a chip ("Diff | File").
struct MiniSegmented: View {
    let left: String
    let right: String
    @Binding var leftOn: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment(left, on: leftOn) { leftOn = true }
            segment(right, on: !leftOn) { leftOn = false }
        }
        .padding(2)
        .background(Color.dsTrack, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(on ? Color.dsFg : Color.dsFg3)
                .padding(.horizontal, 7).frame(height: 18)
                .background(on ? Color.dsSeg : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    /// ⌘P with the Files panel open: back to the tree, into the filter.
    static let focusFileFilter = Notification.Name("piopio.focusFileFilter")
}

