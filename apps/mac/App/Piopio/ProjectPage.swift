import AppKit
import PiopioKit
import SwiftUI

// A project's settings (docs/spec/18 §19, design docs/design/project-settings): a sheet, opened from the settings
// button on the project's sidebar row, its context menu, or "Write them" on a new project's page. There's no project
// page: the row folds its conversations, + starts one, and its board is a row under the project.
//
// The sheet has Folders (its own and linked ones), Instructions (AGENTS.md) and Memory (NOTES.md), How it works
// (permissions for new conversations, and how work is done here: docs/spec/26 §4) and Automations. Changes apply as
// they're made; Done closes. Instructions and Memory are edited in the sheet itself or in your editor.

extension Notification.Name {
    /// Opens a project's settings. Object: the project's id, or "<id>|instructions" / "<id>|memory" to open that file.
    static let projectSettings = Notification.Name("piopio.projectSettings")
}

/// What the settings sheet opens on.
struct ProjectSheet: Identifiable {
    let projectId: String
    var file: ProjectFile?
    var id: String { projectId }

    init?(note object: Any?) {
        guard let raw = object as? String else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        projectId = parts[0]
        file = parts.count > 1 ? ProjectFile(rawValue: parts[1]) : nil
    }
}

/// The two files a project's conversations read: AGENTS.md (or CLAUDE.md, when that's the one it has) and NOTES.md.
enum ProjectFile: String {
    case instructions, memory

    var title: String { self == .instructions ? "Instructions" : "Memory" }
    var symbol: String { self == .instructions ? "doc.text" : "brain" }

    func name(_ project: ProjectInfo) -> String { self == .instructions ? (project.contextFile ?? "AGENTS.md") : "NOTES.md" }
    func url(_ project: ProjectInfo) -> URL { URL(fileURLWithPath: project.path).appendingPathComponent(name(project)) }
    func starter(_ project: ProjectInfo) -> String { self == .instructions ? "# \(project.name)\n\n" : "# Notes\n\n" }

    var about: String {
        self == .instructions ? "What every conversation here is told" : "What its conversations keep for each other"
    }

    func hint(_ project: ProjectInfo) -> String {
        switch self {
        case .instructions: "What every conversation in \(project.name) is told before it starts: what it's about, what matters, how to answer."
        case .memory: "Every conversation in \(project.name) reads this, and adds a line when something should be kept. Edit freely: it's your file."
        }
    }

    /// How much of NOTES.md each turn reads (runtimes/build.ts, MAX_NOTES).
    static let memoryLimit = 6_000
}

/// Opens a file in the editor from Settings › Open files in, or the default app for it.
@MainActor func openInEditor(_ url: URL) {
    if let editor = Editor.preferred { editor.open(url.path) } else { NSWorkspace.shared.open(url) }
}

// MARK: The sheet

struct ProjectSettingsSheet: View {
    let engine: EngineController
    let sheet: ProjectSheet
    @Binding var item: SidebarItem
    let close: () -> Void
    @State private var file: ProjectFile?
    @State private var error: String?
    @State private var dropping = false
    @State private var confirmRemove = false

    init(engine: EngineController, sheet: ProjectSheet, item: Binding<SidebarItem>, close: @escaping () -> Void) {
        self.engine = engine
        self.sheet = sheet
        _item = item
        self.close = close
        _file = State(initialValue: sheet.file)
    }

    private var project: ProjectInfo? { engine.projects.first { $0.id == sheet.projectId } }

    var body: some View {
        Group {
            if let project {
                if let file {
                    ProjectFileEditor(project: project, file: file) { self.file = nil }
                        .frame(width: 760, height: 620)
                } else {
                    settings(project).frame(width: 600, height: 620)
                }
            } else {
                VStack(spacing: 12) {
                    Text("This project is gone.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                    Button("Close", action: close).buttonStyle(PillStyle())
                }
                .frame(width: 400, height: 160)
            }
        }
        .background(Color.dsWin)
    }

    private func settings(_ project: ProjectInfo) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(Color.dsFg2)
                    .frame(width: 32, height: 32)
                    .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(Self.tilde(project.path)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    folders(project).inspectorBlock()
                    files(project).inspectorBlock()
                    how(project).inspectorBlock()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Automations").font(.system(size: 13, weight: .semibold))
                        ProjectAutomationsLink(engine: engine, project: project)
                    }
                    .inspectorBlock(last: true)
                }
                .padding(.horizontal, 20)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack(spacing: 14) {
                Button("Remove from Piopio…") { confirmRemove = true }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(2) }
                Spacer()
                Button("Done", action: close).buttonStyle(PillStyle(kind: .strong)).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .onExitCommand(perform: close)
        .alert("Remove “\(project.name)” from Piopio?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                close()
                if case .newSession(let id) = item, id == project.id { item = .home }
                if case .board(let id) = item, id == project.id { item = .home }
                Task { await engine.removeProject(project) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its folder and files stay where they are, and you can open it again with Open Folder.")
        }
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Folders

    private func folders(_ project: ProjectInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Folders").font(.system(size: 13, weight: .semibold))
                Text("Every conversation here can use them; @ finds their files").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            .padding(.bottom, 4)
            folderRow(name: project.name, path: project.path, symbol: "folder", access: "Its own")
            ForEach(project.folders ?? [], id: \.path) { f in
                folderRow(name: URL(fileURLWithPath: f.path).lastPathComponent, path: f.path, symbol: "link",
                          access: f.missing == true ? "Missing" : f.edit ? "Can edit" : "Read only", linked: f, project: project)
            }
            HStack(spacing: 10) {
                Button { addFolders(project) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        Text("Add folder…")
                    }
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("or drop folders here").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            .padding(.top, 4)
        }
        .padding(8).padding(-8)
        .background(dropping ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(dropping ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        .dropDestination(for: URL.self) { urls, _ in
            link(urls, project)
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
    }

    private func folderRow(name: String, path: String, symbol: String, access: String, linked: ProjectInfo.LinkedFolder? = nil, project: ProjectInfo? = nil) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 16)
            Text(name).font(.system(size: 13)).lineLimit(1)
            Text(Self.tilde(path)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let linked, let project {
                Menu {
                    Button { setEdit(linked, false, project) } label: {
                        if !linked.edit { Label("Read only", systemImage: "checkmark") } else { Text("Read only") }
                        Text("Conversations read it; Piopio asks before changing anything there")
                    }
                    Button { setEdit(linked, true, project) } label: {
                        if linked.edit { Label("Can edit", systemImage: "checkmark") } else { Text("Can edit") }
                        Text("Changed under the project's permissions, like its own folder")
                    }
                    Divider()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    Button("Unlink") { Task { await engine.unlinkFolder(linked.path, from: project) } }
                } label: { Text(access).font(.system(size: 12.5)) }
                    .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(linked.edit ? Color.dsFg2 : Color.dsFg3)
                    .accessibilityLabel("\(name): \(access)")
            } else {
                Text(access).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).padding(.trailing, 6)
            }
        }
        .frame(height: 28)
        .help(path)
    }

    private func addFolders(_ project: ProjectInfo) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Link"
        panel.message = "Folders to link to \(project.name). They start as read only."
        guard panel.runModal() == .OK else { return }
        link(panel.urls, project)
    }

    private func link(_ urls: [URL], _ project: ProjectInfo) {
        let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard !dirs.isEmpty else { error = "Only folders can be linked."; return }
        Task {
            error = nil
            for url in dirs {
                do { try await engine.linkFolder(url, edit: false, to: project) }
                catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
            }
        }
    }

    private func setEdit(_ f: ProjectInfo.LinkedFolder, _ edit: Bool, _ project: ProjectInfo) {
        guard f.edit != edit else { return }
        Task {
            do { try await engine.linkFolder(URL(fileURLWithPath: f.path), edit: edit, to: project) }
            catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    // MARK: Instructions and Memory

    private func files(_ project: ProjectInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            fileRow(.instructions, project)
            fileRow(.memory, project)
        }
    }

    private func fileRow(_ kind: ProjectFile, _ project: ProjectInfo) -> some View {
        let url = kind.url(project)
        let text = try? String(contentsOf: url, encoding: .utf8)
        return HStack(spacing: 10) {
            Image(systemName: kind.symbol).font(.system(size: 13)).foregroundStyle(Color.dsFg2).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(kind.title).font(.system(size: 13))
                    Text(kind.name(project)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg3)
                }
                Text(Self.detail(kind, text)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Edit") { file = kind }
                .buttonStyle(ChipStyle()).font(.system(size: 12.5))
                .help("Edit \(kind.name(project)) here")
            Button {
                if !FileManager.default.fileExists(atPath: url.path) { try? kind.starter(project).write(to: url, atomically: true, encoding: .utf8) }
                openInEditor(url)
            } label: { Image(systemName: "arrow.up.forward.square").font(.system(size: 13)) }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("Open in \(Editor.preferred?.name ?? "its default app")")
                .accessibilityLabel("Open \(kind.name(project)) in \(Editor.preferred?.name ?? "its default app")")
        }
        .padding(.vertical, 6)
    }

    /// "What every conversation here is told · “A PhD thesis…”", or "· 12 lines, all read every turn" for memory.
    static func detail(_ kind: ProjectFile, _ text: String?) -> String {
        guard let text, let first = ProjectFileEditor.firstLine(text) else { return "\(kind.about) · none yet" }
        switch kind {
        case .instructions:
            return "\(kind.about) · “\(first)”"
        case .memory:
            let lines = ProjectFileEditor.lineCount(text)
            let read = text.count <= ProjectFile.memoryLimit ? "all read every turn" : "only the start is read every turn"
            return "\(kind.about) · \(lines) line\(lines == 1 ? "" : "s"), \(read)"
        }
    }

    // MARK: How it works

    private func how(_ project: ProjectInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                Text("New conversations start in").font(.system(size: 13)).foregroundStyle(Color.dsFg2).frame(width: 180, alignment: .leading)
                Menu {
                    ForEach(ApprovalMode.allCases) { m in
                        Button { Task { await engine.setApprovalMode(m, for: project); await engine.loadProjects() } } label: {
                            if m == project.approvalMode { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                            Text(m.summary)
                        }
                    }
                } label: { Text(project.approvalMode.title).font(.system(size: 13)) }
                    .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.hidden).fixedSize()
                    .padding(.leading, -6)
                Text(project.approvalMode.line).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            // What a conversation hears about its pull request (docs/spec/17 §5).
            HStack(spacing: 10) {
                Text("Pull request news").font(.system(size: 13)).foregroundStyle(Color.dsFg2).frame(width: 180, alignment: .leading)
                Picker("", selection: Binding(get: { project.prEvents ?? "tell" }, set: { v in Task { await engine.setPrEvents(v, for: project) } })) {
                    Text("Tell me").tag("tell")
                    Text("The conversation works on it").tag("act")
                    Text("Only in the conversation's panel").tag("off")
                }
                .labelsHidden().fixedSize()
            }
            CheckAfterEditsRow(engine: engine, project: project)
            VStack(alignment: .leading, spacing: 8) {
                Text("How work is done here").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                WayOfWorkingSection(engine: engine, project: project)
            }
        }
    }

}

/// The project's check after the agent's edits (docs/spec/05-build "Diagnostics", roadmap PAR5): what was detected, a
/// command of the user's, or off. When the agent edited files, the check runs before it answers, and the errors in those
/// files go back to it.
struct CheckAfterEditsRow: View {
    let engine: EngineController
    let project: ProjectInfo
    @State private var editing = false
    @State private var draft = ""

    private var check: ProjectInfo.Check { project.check ?? .init(command: nil, source: .auto) }

    var body: some View {
        HStack(spacing: 10) {
            Text("Check after edits").font(.system(size: 13)).foregroundStyle(Color.dsFg2).frame(width: 180, alignment: .leading)
            Menu {
                Button { Task { await engine.setCheck(nil, for: project) } } label: {
                    if check.source == .auto { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
                    Text(check.source == .auto ? (check.command ?? "Nothing found in this project") : "The project's type checker or compiler")
                }
                Button {
                    draft = check.command ?? ""
                    editing = true
                } label: {
                    if check.source == .set { Label("Command…", systemImage: "checkmark") } else { Text("Command…") }
                    Text("A command of your own")
                }
                Button { Task { await engine.setCheck("", for: project) } } label: {
                    if check.source == .off { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
            } label: { Text(title).font(.system(size: 13)) }
                .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.hidden).fixedSize()
                .padding(.leading, -6)
            Text(line).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle)
        }
        .alert("Check after edits", isPresented: $editing) {
            TextField("pnpm run typecheck", text: $draft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await engine.setCheck(command.isEmpty ? nil : command, for: project) }
            }
        } message: {
            Text("Runs in the project folder when the agent has edited files, before it answers. Errors in the files it changed go back to it, twice at most.")
        }
    }

    private var title: String {
        switch check.source {
        case .auto: return check.command == nil ? "Automatic · none found" : "Automatic"
        case .set: return "Command"
        case .off: return "Off"
        }
    }

    private var line: String {
        switch check.source {
        case .auto, .set: return check.command.map { "Runs \($0)" } ?? "Nothing to run: set a command"
        case .off: return "The agent sees errors only when it runs a build"
        }
    }
}

// MARK: The editor

/// AGENTS.md or NOTES.md, edited in the sheet (design docs/design/project-settings/editing.html). Plain markdown in a
/// monospaced font. It saves half a second after you stop typing and when you go back; Undo all puts back what was
/// there when it opened. While it's open the file is watched: with nothing typed it reloads, and with your edits pending
/// a bar offers to combine them with the new lines (conversations add lines to memory) or to keep yours.
struct ProjectFileEditor: View {
    let project: ProjectInfo
    let file: ProjectFile
    let back: () -> Void
    @State private var text = ""
    /// The file as last read or written here.
    @State private var base = ""
    /// The file when the editor opened (Undo all).
    @State private var original = ""
    /// What's on disk when it changed under your edits.
    @State private var conflict: String?
    @State private var status = "Saved"
    @State private var saveTask: Task<Void, Never>?
    @State private var loaded = false

    private var url: URL { file.url(project) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: finish) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(project.name)
                    }
                    .font(.system(size: 13)).foregroundStyle(Color.dsFg2).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to \(project.name)'s settings")
                Text(file.title).font(.system(size: 15, weight: .semibold))
                Text(file.name(project)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg3)
                Spacer()
                Button {
                    saveNow()
                    openInEditor(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 12))
                        Text("Open in \(Editor.preferred?.name ?? "default app")")
                    }
                    .font(.system(size: 12.5))
                }
                .buttonStyle(ChipStyle())
                .keyboardShortcut("o", modifiers: .command)
            }
            .padding(.horizontal, 20).frame(height: 56)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            if let conflict { conflictBar(conflict) } else {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Text(file.hint(project)).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            TextEditor(text: $text)
                .font(.system(size: 13.5, design: .monospaced))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .accessibilityLabel(file.title)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack(spacing: 14) {
                Text(status).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                Spacer()
                if file == .memory { meter }
                Button("Undo all") { text = original }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(text == original ? Color.dsFg3 : Color.dsFg2)
                    .disabled(text == original)
                    .help("Put back what was there when you opened it")
                Button("Done", action: finish).buttonStyle(PillStyle(kind: .strong))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .onExitCommand(perform: finish)
        .onAppear(perform: load)
        .onChange(of: text) { _, _ in if loaded { scheduleSave() } }
        .onDisappear { saveNow() }
        .task {
            // Watch the file: conversations add to memory, and you may have it open elsewhere.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                poll()
            }
        }
    }

    /// "12 lines · 410 of ~6,000 characters read every turn", and a 3 pt bar; amber past the limit.
    private var meter: some View {
        let count = text.count
        let over = count > ProjectFile.memoryLimit
        let lines = Self.lineCount(text)
        return HStack(spacing: 8) {
            Text("\(lines) line\(lines == 1 ? "" : "s") · \(count.formatted()) of ~\(ProjectFile.memoryLimit.formatted()) characters read every turn\(over ? "; the end isn't read" : "")")
                .font(.system(size: 12)).foregroundStyle(over ? Color.dsWarn : Color.dsFg3)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.dsChip)
                    Capsule().fill(over ? Color.dsWarn : Color.dsFg2).frame(width: g.size.width * min(1, Double(count) / Double(ProjectFile.memoryLimit)))
                }
            }
            .frame(width: 80, height: 3)
        }
        .help("Each turn reads the first ~\(ProjectFile.memoryLimit.formatted()) characters; the rest stays in the file.")
    }

    private func conflictBar(_ disk: String) -> some View {
        let merged = LineMerge.merge(base: base, theirs: disk, mine: text)
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12))
            Text("\(file.name(project)) changed while you were editing (a conversation, or another app).").font(.system(size: 12.5))
            Spacer(minLength: 8)
            if let merged {
                Button("Use theirs and mine") { resolve(with: merged, disk: disk) }.buttonStyle(PillStyle(compact: true))
            } else {
                Button("Reload") { base = disk; conflict = nil; text = disk; status = "Saved" }.buttonStyle(PillStyle(compact: true))
            }
            Button("Keep mine") { resolve(with: text, disk: disk) }.buttonStyle(PillStyle(compact: true))
        }
        .foregroundStyle(Color.dsWarn)
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(Color.dsWarn.opacity(0.1))
    }

    private func resolve(with result: String, disk: String) {
        base = disk
        conflict = nil
        text = result
        saveNow()
    }

    // MARK: Files

    private func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func load() {
        if !FileManager.default.fileExists(atPath: url.path) { try? file.starter(project).write(to: url, atomically: true, encoding: .utf8) }
        let now = read()
        text = now
        base = now
        original = now
        DispatchQueue.main.async { loaded = true }
    }

    private func scheduleSave() {
        guard conflict == nil, text != base else { return }
        status = "Saving…"
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        guard conflict == nil else { return }
        guard text != base else { status = "Saved"; return }
        let disk = read()
        guard disk == base else { conflict = disk; status = "Not saved: the file changed"; return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            base = text
            status = "Saved"
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func poll() {
        guard loaded, conflict == nil else { return }
        let disk = read()
        guard disk != base else { return }
        if text == base {
            base = disk
            text = disk
        } else {
            conflict = disk
            status = "Not saved: the file changed"
        }
    }

    private func finish() {
        saveNow()
        if conflict == nil { back() }
    }

    /// The first line with words, past the title and HTML comments.
    static func firstLine(_ text: String) -> String? {
        let clean = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        let line = clean.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("# ") }
        return line.map { String($0.prefix(120)) }
    }

    /// Lines with words, not counting headings.
    static func lineCount(_ text: String) -> Int {
        text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }.count
    }
}

// MARK: The board

/// A project's board (docs/spec/26 §5), from the "Board" row under the project. Until parallel work is on there, it
/// says what goes here and has the switch.
struct ProjectBoardPage: View {
    let engine: EngineController
    let projectId: String
    @Binding var item: SidebarItem
    @State private var fitting = false

    var body: some View {
        let project = engine.projects.first { $0.id == projectId }
        let work = project.flatMap { engine.work(in: $0) }
        VStack(spacing: 0) {
            PageHeader {
                PageTitle(name: "Board", subtitle: project?.name ?? "")
            } actions: {
                if let project {
                    Button { NotificationCenter.default.post(name: .projectSettings, object: project.id) } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(IconButtonStyle()).help("Project settings").accessibilityLabel("Project settings")
                }
            }
            if let project, let work, work.way.parallel || !work.tasks.isEmpty {
                WorkBoard(engine: engine, project: project, work: work, item: $item)
            } else if let project {
                empty(project, work: work)
            } else {
                Text("This project is gone.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: projectId) { await engine.loadWork() }
    }

    /// The empty Board (design 4b, 26 §5): what goes here, and the switch for parallel work.
    private func empty(_ project: ProjectInfo, work: ProjectWork?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Piopio puts parallel work here").font(.system(size: 15, weight: .semibold))
            Text("When something you ask splits into parts that can be done at once, Piopio makes a helper for each part and puts it here. Each part is reviewed, then merged; you merge the whole into \(project.name) when it's ready. Small things Piopio still does in the conversation.")
                .font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            Button(work == nil ? "Switch on parallel work…" : "Switch on parallel work") {
                if work == nil { fitting = true } else { Task { try? await engine.configureWork(ConfigureWorkParams(project: project.id, parallel: true)) } }
            }
            .buttonStyle(PillStyle(kind: .primary))
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $fitting) { ParallelFitSheet(engine: engine, project: project) { fitting = false } }
    }
}
