import AppKit
import PiopioKit
import SwiftUI

// A team as a definition (docs/spec/20 P3): who's on it and how they work, reused by every project it works in.
// Members (the chain of work, docs/spec/21 D5) · TEAM.md · Notes · Projects, and ••• for the rest. No chat: the work
// is in the projects.

struct TeamPage: View {
    let engine: EngineController
    /// A definition's id; an older selection (a project's team) opens its definition.
    let teamId: String
    @Binding var item: SidebarItem
    @AppStorage("teamTab") private var tab = "members"
    @State private var saving: TeamDefinition?
    @State private var error: String?

    private var def: TeamDefinition? {
        engine.teamDefinitions.first { $0.id == teamId }
            ?? engine.teams.first { $0.id == teamId }.flatMap { t in engine.teamDefinitions.first { $0.id == t.definitionId } }
    }

    var body: some View {
        Group {
            if let def {
                VStack(spacing: 0) {
                    PageHeader {
                        HStack(spacing: 10) {
                            TeamStack(colors: TeamStack.colors(def.roles, team: def.id))
                            PageTitle(name: def.name, subtitle: subtitle(def))
                        }
                    } actions: {
                        NeutralSegmented(selection: $tab, options: [("members", "Members"), ("instructions", "TEAM.md"), ("memory", "Notes"), ("projects", "Projects")])
                            .frame(width: 340)
                        more(def)
                    }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn).padding(.horizontal, 24).padding(.top, 6) }
                    switch tab {
                    case "instructions":
                        TeamFileEditor(path: (def.folder as NSString).appendingPathComponent("TEAM.md"),
                                       about: "What every member of \(def.name) is told, in every project: conventions, tools, taste.")
                            .id(def.id + "TEAM")
                    case "memory":
                        TeamFileEditor(path: (def.folder as NSString).appendingPathComponent("NOTES.md"),
                                       about: "What the team learns about how it works, across projects. Members add to it; notes about one project go in that project's NOTES.md.")
                            .id(def.id + "NOTES")
                    case "projects": TeamProjects(engine: engine, def: def, item: $item)
                    default: TeamChain(engine: engine, def: def, item: $item)
                    }
                }
            } else {
                Text("This team is gone.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: teamId) { await engine.loadTeams() }
        .sheet(item: $saving) { def in SaveTemplateSheet(engine: engine, def: def) { saving = nil } }
    }

    /// "Works in piopio", "Works in piopio and 2 more", "Only in piopio" (a team born there, docs/spec/21 AD1).
    private func subtitle(_ def: TeamDefinition) -> String {
        let names = def.projects.map { p in engine.projects.first { $0.path == p.cwd }?.name ?? URL(fileURLWithPath: p.cwd).lastPathComponent }
        if !def.saved, let first = names.first { return "Only in \(first)" }
        switch names.count {
        case 0: return "Works in no project yet"
        case 1: return "Works in \(names[0])"
        case 2: return "Works in \(names[0]) and \(names[1])"
        default: return "Works in \(names[0]) and \(names.count - 1) more"
        }
    }

    /// ••• : save it for reuse, save it as a template, remove it when no project uses it.
    private func more(_ def: TeamDefinition) -> some View {
        Menu {
            if !def.saved {
                Button("Save for Reuse") { act { try await engine.updateTeamDefinition(def, saved: true) } }
            }
            Button("Save as Template…") { saving = def }
            Button("Reveal Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: def.folder)]) }
            if def.projects.isEmpty {
                Divider()
                Button("Remove Team", role: .destructive) { act { try await engine.removeTeamDefinition(def); item = .home } }
            }
        } label: { Image(systemName: "ellipsis").accessibilityLabel("More") }
            .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize()
            .help(def.saved ? "Save as template, Finder" : "Save for reuse, save as template, Finder")
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}

/// TEAM.md or the team's NOTES.md, edited in place: plain files in the team's folder.
private struct TeamFileEditor: View {
    let path: String
    let about: String
    @State private var text = ""
    @State private var saved = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(about).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.buttonStyle(PillStyle(compact: true))
                Button("Save", action: write).buttonStyle(PillStyle(kind: .primary, compact: true)).disabled(text == saved).keyboardShortcut("s", modifiers: .command)
            }
            TextEditor(text: $text).font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden).padding(10)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.dsLine, lineWidth: 1))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
        }
        .padding(24)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .onAppear(perform: read)
    }

    private func read() {
        text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        saved = text
    }

    private func write() {
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            saved = text
            error = nil
        } catch { self.error = "Couldn't save: \(error.localizedDescription)" }
    }
}

/// Where the team works (design 3a): each project with what the team is doing there and how many tasks run at once.
private struct TeamProjects: View {
    let engine: EngineController
    let def: TeamDefinition
    @Binding var item: SidebarItem
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Each project has its own board, branch and routines; the members are the same. Give another project this team in its Settings.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                ForEach(def.projects, id: \.teamId) { place in row(place) }
                if def.projects.isEmpty {
                    Text("It doesn't work in any project now. Remove it from ••• (its folder, with TEAM.md and NOTES.md, stays on disk).")
                        .font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ place: TeamDefinition.Place) -> some View {
        let project = engine.projects.first { $0.path == place.cwd }
        let team = engine.teams.first { $0.id == place.teamId }
        let tasks = team?.tasks ?? []
        let doing = tasks.filter { ["doing", "review", "integrating"].contains($0.state) }.count
        let waiting = tasks.filter { $0.state == "blocked" || $0.blocked != nil }.count
        return HStack(spacing: 12) {
            Button { if let project { item = .project(project.id) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(Color.dsFg2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project?.name ?? URL(fileURLWithPath: place.cwd).lastPathComponent).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.dsFg)
                        Text(Self.status(tasks: tasks, doing: doing, waiting: waiting)).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    if doing > 0 { SidebarDot(status: .running) }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let team {
                Stepper(value: Binding(get: { team.maxParallel }, set: { n in
                    Task {
                        do { try await engine.updateTeam(team, maxParallel: n); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
                    }
                }), in: 1...8) {
                    Text("\(team.maxParallel) at once").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                }
                .fixedSize()
                .help("How many tasks its members work on at the same time in this project")
            }
        }
        .padding(12)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }

    /// "2 tasks doing · 1 waits for you", "Idle · last task 3 days ago", "No tasks yet".
    static func status(tasks: [TeamTask], doing: Int, waiting: Int) -> String {
        var parts: [String] = []
        if doing > 0 { parts.append("\(doing) task\(doing == 1 ? "" : "s") doing") }
        if waiting > 0 { parts.append("\(waiting) wait\(waiting == 1 ? "s" : "") for you") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        guard let last = tasks.compactMap({ ISO8601DateFormatter().date(from: $0.updatedAt) }).max() else { return "No tasks yet" }
        let ago = RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
        return "Idle · last task \(ago)"
    }
}

/// Save as template (docs/spec/20 P4): a name, then where the folder went.
private struct SaveTemplateSheet: View {
    let engine: EngineController
    let def: TeamDefinition
    let done: () -> Void
    @State private var name = ""
    @State private var folder: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as template").font(.system(size: 15, weight: .semibold))
            if let folder {
                Text("Saved. New teams can start from it, and you can edit its cards by hand or share the folder.")
                    .font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                Text(folder).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg3).textSelection(.enabled)
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
                    Spacer()
                    Button("Done", action: done).keyboardShortcut(.defaultAction)
                }
            } else {
                TextField("Name", text: $name, prompt: Text(def.name)).textFieldStyle(.roundedBorder)
                Text("Its members, way of working and TEAM.md, as a folder in ~/Piopio/Teams/Templates: TEAM.md and a card per member.")
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
                HStack {
                    Spacer()
                    Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                    Button("Save") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do { folder = try await engine.saveTeamTemplate(def, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name) }
                            catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
                        }
                    }
                    .keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
