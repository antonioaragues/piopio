import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// File viewer and "Open in <Editor>" (docs/spec/05-build BR4).

/// Editors Piopio can hand a file or folder to. Those with a URL scheme open at the line.
struct Editor: Identifiable, Hashable {
    let id: String // bundle identifier
    let name: String
    /// `{path}` and `{line}` are filled in.
    let lineURL: String?

    static let known = [
        Editor(id: "dev.zed.Zed", name: "Zed", lineURL: "zed://file{path}:{line}"),
        Editor(id: "com.microsoft.VSCode", name: "VS Code", lineURL: "vscode://file{path}:{line}"),
        Editor(id: "com.todesktop.230313mzl4w4u92", name: "Cursor", lineURL: "cursor://file{path}:{line}"),
        Editor(id: "com.apple.dt.Xcode", name: "Xcode", lineURL: nil),
        Editor(id: "com.sublimetext.4", name: "Sublime Text", lineURL: "subl://open?url=file://{path}&line={line}"),
    ]

    static var installed: [Editor] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    /// The one chosen in Settings › General, else the first installed.
    static var preferred: Editor? {
        let installed = installed
        if let id = UserDefaults.standard.string(forKey: "editor"), let editor = installed.first(where: { $0.id == id }) { return editor }
        return installed.first
    }

    /// Opens a file (at a line when the editor supports it) or a folder.
    func open(_ path: String, line: Int? = nil) {
        if let line, let template = lineURL,
           let url = URL(string: template.replacingOccurrences(of: "{path}", with: path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path).replacingOccurrences(of: "{line}", with: "\(line)")),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// "Open ⌄" (chat v3, 14d): the project in an editor, Terminal or Finder; Copy path; the default app. One click on
/// the button repeats the last choice, whose app icon it shows.
struct OpenMenu: View {
    let path: String
    @AppStorage("lastOpenTarget") private var last = ""
    @AppStorage("editor") private var defaultEditor = ""

    private static let terminal = "com.apple.Terminal"
    private static let finder = "com.apple.finder"

    var body: some View {
        Menu {
            ForEach(Editor.installed) { editor in
                Button { open(editor.id) } label: { Label { Text(editor.name) } icon: { AppIcon(bundleId: editor.id) } }
            }
            Button { open(Self.terminal) } label: { Label { Text("Terminal") } icon: { AppIcon(bundleId: Self.terminal) } }
            Button { open(Self.finder) } label: { Label { Text("Finder") } icon: { AppIcon(bundleId: Self.finder) } }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            if !Editor.installed.isEmpty {
                Menu("Default App") {
                    ForEach(Editor.installed) { editor in
                        Button { defaultEditor = editor.id } label: {
                            if editor.id == Editor.preferred?.id { Label(editor.name, systemImage: "checkmark") } else { Text(editor.name) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 14))
                Text("Open in \(name(target))").font(.system(size: 13))
            }
        } primaryAction: {
            open(target)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PillStyle(kind: .toolbar))
        .fixedSize()
        .help("Open the project in \(name(target)) (more in the menu)")
    }

    /// The last app used, else the default editor, else Finder.
    private var target: String {
        if !last.isEmpty, last == Self.terminal || last == Self.finder || Editor.installed.contains(where: { $0.id == last }) { return last }
        return Editor.preferred?.id ?? Self.finder
    }

    private func name(_ id: String) -> String {
        id == Self.terminal ? "Terminal" : id == Self.finder ? "Finder" : Editor.installed.first { $0.id == id }?.name ?? "the editor"
    }

    private func open(_ id: String) {
        last = id
        if id == Self.finder {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else if let editor = Editor.installed.first(where: { $0.id == id }) {
            editor.open(path)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// An app's icon, by bundle identifier.
struct AppIcon: View {
    let bundleId: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
        } else {
            Image(systemName: "app")
        }
    }
}

/// A file to show: path relative to the session's folder, and the line to show first.
struct FileTarget: Identifiable, Hashable {
    let path: String
    var line: Int?
    var id: String { "\(path):\(line ?? 0)" }
}

/// Read-only, highlighted view of a file with a quick-edit mode (BR4).
struct FileViewer: View {
    let engine: EngineController
    let cwd: String
    let target: FileTarget
    @Environment(\.dismiss) private var dismiss
    @State private var file: ReadFileResult?
    @State private var error: String?
    @State private var editing = false
    @State private var draft = ""
    @State private var saving = false

    private var lines: [Substring] { file?.content.split(separator: "\n", omittingEmptySubsequences: false) ?? [] }
    private var fullPath: String { target.path.hasPrefix("/") ? target.path : "\(cwd)/\(target.path)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(Color.dsFg3)
                Text(target.path).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.head)
                if let file { Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
                Spacer()
                if editing {
                    Button("Cancel") { editing = false }.buttonStyle(PillStyle(compact: true))
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }.buttonStyle(PillStyle(kind: .primary, compact: true)).keyboardShortcut("s").disabled(saving)
                } else {
                    if file?.binary == false, file?.truncated == false {
                        Button("Edit") { draft = file?.content ?? ""; editing = true }.buttonStyle(PillStyle(compact: true)).help("Make a quick change")
                    }
                    ForEach(Editor.installed.prefix(2)) { editor in
                        Button("Open in \(editor.name)") { editor.open(fullPath, line: target.line) }.buttonStyle(PillStyle(compact: true))
                    }
                    Button("Done") { dismiss() }.buttonStyle(PillStyle(kind: .strong, compact: true)).keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            content
        }
        .frame(width: 860, height: 620)
        .background(Color.dsWin)
        .task {
            do {
                file = try await engine.client?.call("projects.readFile", ReadFileParams(cwd: cwd, path: target.path), as: ReadFileResult.self)
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let error {
            Text(error).font(.system(size: 13)).foregroundStyle(Color.dsFg2).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let file {
            if file.binary {
                Text("Binary file").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if editing {
                TextEditor(text: $draft)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                HStack(spacing: 0) {
                                    Text("\(index + 1)").foregroundStyle(Color.dsFg3).frame(width: 52, alignment: .trailing).padding(.trailing, 12)
                                    Text(highlighted(String(line))).fixedSize()
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .frame(height: 18)
                                .background(index + 1 == target.line ? Color.dsAccentSoft : .clear)
                                .id(index + 1)
                            }
                            if file.truncated {
                                Text("… the file is larger than 2 MB; open it in an editor to see the rest.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(12)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onAppear { if let line = target.line { DispatchQueue.main.async { proxy.scrollTo(line, anchor: .center) } } }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func highlighted(_ line: String) -> AttributedString {
        let ns = NSMutableAttributedString(string: line.isEmpty ? " " : line, attributes: [.foregroundColor: DS.fg])
        for (range, token) in Highlighter.tokens(line) where NSMaxRange(range) <= ns.length {
            ns.addAttribute(.foregroundColor, value: Highlighter.color(token), range: range)
        }
        return AttributedString(ns)
    }

    private func save() async {
        saving = true
        do {
            _ = try await engine.client?.call("projects.writeFile", WriteFileParams(cwd: cwd, path: target.path, content: draft), as: Empty.self)
            file = ReadFileResult(content: draft, size: draft.utf8.count, truncated: false, binary: false)
            editing = false
        } catch {
            self.error = String(describing: error)
        }
        saving = false
    }
}
