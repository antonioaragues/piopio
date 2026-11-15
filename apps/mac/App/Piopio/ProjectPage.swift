import AppKit
import PiopioKit
import SwiftUI

// The project page (docs/spec/18 §18, design docs/design/project-page, proposal A): a home, not tabs. On the left, the
// box to start a conversation here and the project's conversations; on the right, a column of what the project is,
// in the Summary panel's blocks: instructions, notes, folders (its own and linked ones), who works here, routines.
// A team's board is one line that opens it; Settings is in the … menu. Board and Settings open in place, with a way back.

struct ProjectPage: View {
    let engine: EngineController
    let projectId: String
    @Binding var item: SidebarItem
    /// home, board or settings. Others ask for one through "projectTab" in defaults (Project Settings…, captures).
    @State private var view = "home"
    /// The right column, open by default (18 §18); closing it is remembered.
    @AppStorage("projectColumn") private var columnOpen = true
    /// A team picked on the empty Board: the fit check comes first (docs/spec/21 D6).
    @State private var choosing: TeamChoice?

    private var project: ProjectInfo? { engine.projects.first { $0.id == projectId } }

    var body: some View {
        if let project {
            let team = engine.team(in: project)
            VStack(spacing: 0) {
                switch view {
                case "board":
                    PageHeader { back("Board", project) } actions: { EmptyView() }
                    if let team { TeamBoard(engine: engine, team: team, item: $item) } else { noTeam }
                case "settings":
                    PageHeader { back("Settings", project) } actions: { EmptyView() }
                    ProjectSettings(engine: engine, project: project, team: team, item: $item)
                default:
                    PageHeader { EmptyView() } actions: {
                        Button { withAnimation(.easeOut(duration: 0.15)) { columnOpen.toggle() } } label: { Image(systemName: "list.bullet.rectangle") }
                            .buttonStyle(IconButtonStyle(on: columnOpen))
                            .help(columnOpen ? "Hide the project's details" : "Show the project's details")
                            .accessibilityLabel("Project details")
                        moreMenu(project)
                    }
                    HStack(spacing: 0) {
                        ProjectHome(engine: engine, project: project, team: team, item: $item) { view = "board" }
                        if columnOpen {
                            Rectangle().fill(Color.dsLine).frame(width: 0.5)
                            ProjectColumn(engine: engine, project: project, team: team) { view = "settings" }
                                .frame(width: 300)
                        }
                    }
                }
            }
            .onAppear(perform: takeRequestedView)
            .onChange(of: projectId) { _, _ in view = "home"; takeRequestedView() }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in takeRequestedView() }
            .task(id: projectId) {
                await engine.loadTeams()
                // PIOPIO_DEMO_FIT=<template id>: captures open the fit check for it.
                if let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_FIT"], let t = await engine.teamTemplates().first(where: { $0.id == demo }) {
                    choosing = .template(t)
                }
            }
            .sheet(item: $choosing) { choice in FitCheckSheet(engine: engine, project: project, choice: choice) { choosing = nil } }
        } else {
            Text("This project is gone.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// "Project Settings…" and captures ask for a view through defaults; it's taken once.
    private func takeRequestedView() {
        guard let asked = UserDefaults.standard.string(forKey: "projectTab") else { return }
        UserDefaults.standard.removeObject(forKey: "projectTab")
        view = ["board", "settings"].contains(asked) ? asked : "home"
    }

    /// "‹ Tesis  Board": back to the project's home.
    private func back(_ title: String, _ project: ProjectInfo) -> some View {
        HStack(spacing: 8) {
            Button { view = "home" } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(project.name)
                }
                .font(.system(size: 13)).foregroundStyle(Color.dsFg2).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Back to \(project.name)")
            Text(title).font(.system(size: 13.5, weight: .semibold))
        }
    }

    /// Settings, Reveal in Finder, Remove from Piopio.
    private func moreMenu(_ project: ProjectInfo) -> some View {
        Menu {
            Button("Settings…") { view = "settings" }
            if engine.team(in: project) != nil { Button("Board") { view = "board" } }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
            Divider()
            Button("Remove from Piopio") {
                item = .home
                Task { await engine.removeProject(project) }
            }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize()
            .help("More")
            .accessibilityLabel("More")
    }

    /// The empty Board (design 4b): pick a team right here.
    private var noTeam: some View {
        ScrollView {
            TeamPickerList(engine: engine, item: $item, choosing: $choosing)
                .padding(.top, 48).padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The left of the project's home: its name and where it is, the box (in this project), the team's board in one line,
/// and the conversations, newest first.
private struct ProjectHome: View {
    let engine: EngineController
    let project: ProjectInfo
    let team: TeamInfo?
    @Binding var item: SidebarItem
    let openBoard: () -> Void

    var body: some View {
        let sessions = engine.sessions(in: project).filter(\.listed).sorted { $0.updatedAt > $1.updatedAt }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(project.name).font(.system(size: 26, weight: .bold)).tracking(-0.5).lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.system(size: 11))
                    Text(meta).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                .padding(.top, 3)
                .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
                .help("Reveal in Finder")
                if project.missing == true {
                    Text("This folder is gone. Find it in Finder and open it again, or remove the project.").font(.system(size: 13)).foregroundStyle(Color.dsFg2).padding(.top, 22)
                } else {
                    AskBox(engine: engine, item: $item, projectId: project.id).padding(.top, 22)
                }
                if let team { boardLine(team).padding(.top, 22) }
                HStack {
                    Text("Conversations").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Spacer()
                    if !sessions.isEmpty { Text("\(sessions.count)").font(.system(size: 12)).foregroundStyle(Color.dsFg3).monospacedDigit() }
                }
                .padding(.top, 28).padding(.bottom, 6)
                if sessions.isEmpty {
                    Text(team == nil ? "None yet. Start one above." : "None yet. Each one is with \(team!.name)'s lead.")
                        .font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(.vertical, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(sessions, id: \.ref.id) { s in
                            Rectangle().fill(Color.dsLine).frame(height: 0.5)
                            row(s)
                        }
                        Rectangle().fill(Color.dsLine).frame(height: 0.5)
                    }
                }
            }
            .padding(.horizontal, 44).padding(.top, 8).padding(.bottom, 36)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// "~/Piopio/Tesis · with Piopio · Auto-edit".
    private var meta: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = project.path.hasPrefix(home) ? "~" + project.path.dropFirst(home.count) : project.path
        var parts = [path]
        if let branch = project.branch { parts.append(branch) }
        parts.append(team.map { "with \($0.name)" } ?? "with Piopio")
        parts.append(project.approvalMode.title)
        return parts.joined(separator: " · ")
    }

    /// "Board · 2 doing · 1 in review · 5 done   Open ›".
    private func boardLine(_ team: TeamInfo) -> some View {
        let count = { (states: Set<String>) in team.tasks.filter { states.contains($0.state) }.count }
        var parts = ["Board"]
        let doing = count(["doing", "integrating"]), review = count(["review"]), todo = count(["todo"]), blocked = count(["blocked"]), done = count(["done"])
        if doing > 0 { parts.append("\(doing) doing") }
        if review > 0 { parts.append("\(review) in review") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if todo > 0 { parts.append("\(todo) to do") }
        if done > 0 { parts.append("\(done) done") }
        if parts.count == 1 { parts.append("nothing yet") }
        return Button(action: openBoard) {
            HStack(spacing: 8) {
                if doing > 0 { SidebarDot(status: .running) }
                Text(parts.joined(separator: " · ")).foregroundStyle(Color.dsFg2)
                Spacer()
                Text("Open ›").foregroundStyle(Color.dsFg2)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 14).frame(height: 38)
            .background(Color.dsChip.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(team.name)'s board")
    }

    private func row(_ s: SessionSummary) -> some View {
        let tasks = team?.tasks.filter { $0.conversationId == s.ref.id } ?? []
        let open = tasks.filter { ["todo", "doing", "review", "integrating"].contains($0.state) }.count
        return Button { item = .session(s.ref.id) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.system(size: 13.5)).foregroundStyle(Color.dsFg).lineLimit(1)
                    Text(rowMeta(s, tasks: tasks.count, open: open)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                Spacer(minLength: 8)
                if engine.liveStatus[s.ref.id] == .waitingApproval { SidebarDot(status: .waiting) }
                else if engine.liveStatus[s.ref.id] == .running || open > 0 { SidebarDot(status: .running) }
            }
            .padding(.vertical, 8).frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Move to Trash", role: .destructive) { Task { await engine.delete(s.ref) } }
        }
    }

    private func rowMeta(_ s: SessionSummary, tasks: Int, open: Int) -> String {
        var parts: [String] = []
        switch engine.liveStatus[s.ref.id] {
        case .waitingApproval?: parts.append("Waiting on you")
        case .running?: parts.append("Running")
        default: break
        }
        if s.team?.kind == "lead" { parts.append("With the lead") }
        if tasks > 0 { parts.append(open > 0 ? "\(open) of \(tasks) task\(tasks == 1 ? "" : "s") running" : "\(tasks) task\(tasks == 1 ? "" : "s") done") }
        parts.append(BuildSessionView.relative(s.updatedAt))
        return parts.joined(separator: " · ")
    }
}

/// The project's settings (docs/spec/21 D6, design 4a): who works here (Piopio alone or a team), how the team works
/// here, the project's routines, and its instructions and notes.
private struct ProjectSettings: View {
    let engine: EngineController
    let project: ProjectInfo
    let team: TeamInfo?
    @Binding var item: SidebarItem
    @State private var templates: [TeamTemplate] = []
    @State private var testCommand = ""
    @State private var choosing: TeamChoice?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Who works here") { WhoWorksHere(engine: engine, project: project, team: team, item: $item, templates: templates, choosing: $choosing) }
                if let team { section("How the team works here") { howItWorks(team) } }
                // A project's routines, with or without a team (docs/spec/21 AD5).
                section("Routines") { ProjectRoutinesList(engine: engine, project: project, team: team) }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { templates = await engine.teamTemplates() }
        .task(id: team?.id) { testCommand = team?.testCommand ?? "" }
        .sheet(item: $choosing) { choice in FitCheckSheet(engine: engine, project: project, choice: choice) { choosing = nil } }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content()
        }
    }

    /// Tasks at once · Checks (design 4a).
    private func howItWorks(_ team: TeamInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Tasks at once", "How many run at the same time here") {
                Stepper(value: Binding(get: { team.maxParallel }, set: { n in act { try await engine.updateTeam(team, maxParallel: n) } }), in: 1...8) {
                    Text("\(team.maxParallel)").font(.system(size: 13).monospacedDigit())
                }
                .fixedSize()
            }
            row("Checks", team.git == nil ? "Run after each task, in the project's folder" : "Run on the team's branch after each merge; a failure sends the task back") {
                HStack(spacing: 6) {
                    TextField("", text: $testCommand, prompt: Text("npm test"))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced)).frame(width: 170)
                        .onSubmit { save(team) }
                    if testCommand.trimmingCharacters(in: .whitespaces) != (team.testCommand ?? "") {
                        Button("Save") { save(team) }.buttonStyle(PillStyle(compact: true))
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }

    private func row<V: View>(_ title: String, _ detail: String, @ViewBuilder content: () -> V) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            Spacer()
            content()
        }
        .padding(.vertical, 9)
    }

    private func save(_ team: TeamInfo) {
        let command = testCommand
        act { try await engine.updateTeam(team, testCommand: command) }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}

/// The right column of a project's home (docs/spec/18 §18): what the project is, in the Summary panel's blocks.
/// Instructions (AGENTS.md) and Notes (NOTES.md) as a few lines with Edit; Folders, its own and linked ones (read only
/// or editable; Add folder…, or drop folders here or on the project's row); then who works here, the permissions new
/// conversations start with, and routines. Changing who works here or the routines opens Settings.
struct ProjectColumn: View {
    let engine: EngineController
    let project: ProjectInfo
    let team: TeamInfo?
    let openSettings: () -> Void
    @State private var routines: [TeamRoutine] = []
    @State private var error: String?
    @State private var dropping = false
    @State private var tick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                fileBlock("Instructions", file: project.contextFile ?? "AGENTS.md", empty: "None yet. What every conversation here should know.",
                          starter: "# \(project.name)\n\n")
                    .inspectorBlock()
                fileBlock("Notes", file: "NOTES.md", empty: "None yet. Its conversations add what later ones need.", starter: "# Notes\n\n")
                    .inspectorBlock()
                folders.inspectorBlock()
                about.inspectorBlock(last: true)
            }
            .padding(.horizontal, 18)
        }
        .task(id: project.id) { routines = await engine.routines(in: project) }
    }

    // MARK: Instructions and notes

    private func fileBlock(_ title: String, file: String, empty: String, starter: String) -> some View {
        _ = tick
        let url = URL(fileURLWithPath: project.path).appendingPathComponent(file)
        let preview = Self.preview(url)
        let exists = FileManager.default.fileExists(atPath: url.path)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(exists ? "Edit" : "Write") {
                    if !exists { try? starter.write(to: url, atomically: true, encoding: .utf8); tick += 1 }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                .help("Open \(file)")
            }
            Text(preview ?? empty)
                .font(.system(size: 12.5)).lineSpacing(2)
                .foregroundStyle(preview == nil ? Color.dsFg3 : Color.dsFg2)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, preview == nil ? 0 : 10)
                .overlay(alignment: .leading) { if preview != nil { Rectangle().fill(Color.dsLine).frame(width: 1.5) } }
        }
    }

    /// A file's text without its title line, HTML comments and blank lines; nil when nothing is left.
    static func preview(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let noComments = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        var lines = noComments.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
        // Lists stay one item per line; prose reads as one paragraph.
        let joined = lines.prefix(6).joined(separator: lines.contains { $0.hasPrefix("- ") || $0.hasPrefix("* ") } ? "\n" : " ")
        return joined.isEmpty ? nil : String(joined.prefix(400))
    }

    // MARK: Folders

    private var folders: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Folders").font(.system(size: 13, weight: .semibold))
            folderRow(name: project.name, path: project.path, symbol: "folder", access: "Its own")
            ForEach(project.folders ?? [], id: \.path) { f in
                folderRow(name: URL(fileURLWithPath: f.path).lastPathComponent, path: f.path, symbol: "link", access: f.missing == true ? "Missing" : f.edit ? "Can edit" : "Read only", linked: f)
            }
            Button(action: addFolders) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    Text("Add folder…")
                }
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .help("Link a folder on this Mac: every conversation here is told about it and @ finds its files")
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(6).padding(-6)
        .background(dropping ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(dropping ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        .dropDestination(for: URL.self) { urls, _ in
            link(urls)
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
    }

    private func folderRow(name: String, path: String, symbol: String, access: String, linked: ProjectInfo.LinkedFolder? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 16)
            Text(name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if let linked {
                Menu {
                    Button { setEdit(linked, false) } label: {
                        if !linked.edit { Label("Read only", systemImage: "checkmark") } else { Text("Read only") }
                        Text("Conversations read it; Piopio asks before changing anything there")
                    }
                    Button { setEdit(linked, true) } label: {
                        if linked.edit { Label("Can edit", systemImage: "checkmark") } else { Text("Can edit") }
                        Text("Changed under the project's permissions, like its own folder")
                    }
                    Divider()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    Button("Unlink") { Task { await engine.unlinkFolder(linked.path, from: project) } }
                } label: { Text(access).font(.system(size: 12)) }
                    .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(linked.edit ? Color.dsFg2 : Color.dsFg3)
                    .accessibilityLabel("\(name): \(access)")
            } else {
                Text(access).font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.trailing, 6)
            }
        }
        .frame(height: 26)
        .help(path)
        .contextMenu { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Link"
        panel.message = "Folders to link to \(project.name). They start as read only."
        guard panel.runModal() == .OK else { return }
        link(panel.urls)
    }

    /// Links folders read only (a drop may bring files too: only folders are linked).
    private func link(_ urls: [URL]) {
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

    private func setEdit(_ f: ProjectInfo.LinkedFolder, _ edit: Bool) {
        guard f.edit != edit else { return }
        Task {
            do { try await engine.linkFolder(URL(fileURLWithPath: f.path), edit: edit, to: project) }
            catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    // MARK: Who, permissions, routines

    private var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project").font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    label("Who")
                    HStack(spacing: 6) {
                        Text(team?.name ?? "Piopio").font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Change", action: openSettings).buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    }
                }
                GridRow {
                    label("Starts in")
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
                        .help("The permissions new conversations here start with")
                }
                GridRow {
                    label("Routines")
                    Button(action: openSettings) {
                        Text(routines.isEmpty ? "None · Add ›" : "\(routines.count) ›").font(.system(size: 13)).foregroundStyle(routines.isEmpty ? Color.dsFg3 : Color.dsFg)
                    }
                    .buttonStyle(.plain)
                    .help("What starts work here on its own")
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(width: 64, alignment: .leading)
    }
}
