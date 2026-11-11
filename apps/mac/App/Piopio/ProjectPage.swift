import AppKit
import PiopioKit
import SwiftUI

// The project page (docs/spec/20 §5): where work happens. Its conversations, its Board when a team works here, and
// Settings: who works here (Piopio or a team), the checks, routines, instructions and notes.

struct ProjectPage: View {
    let engine: EngineController
    let projectId: String
    @Binding var item: SidebarItem
    @AppStorage("projectTab") private var tab = "conversations"

    private var project: ProjectInfo? { engine.projects.first { $0.id == projectId } }

    var body: some View {
        if let project {
            let team = engine.team(in: project)
            VStack(spacing: 0) {
                PageHeader {
                    PageTitle(name: project.name, subtitle: subtitle(project, team))
                } actions: {
                    NeutralSegmented(selection: $tab, options: [("conversations", "Conversations"), ("board", "Board"), ("settings", "Settings")])
                        .frame(width: 330)
                    Button("New conversation") { NotificationCenter.default.post(name: .newBuildSession, object: project.id) }
                        .buttonStyle(PillStyle(kind: .primary))
                        .disabled(project.missing == true)
                }
                switch tab {
                case "board":
                    if let team { TeamBoard(engine: engine, team: team, item: $item) } else { noTeam }
                case "settings": ProjectSettings(engine: engine, project: project, team: team, item: $item)
                default: ProjectConversations(engine: engine, project: project, team: team, item: $item)
                }
            }
            .task(id: projectId) { await engine.loadTeams() }
        } else {
            Text("This project is gone.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func subtitle(_ p: ProjectInfo, _ team: TeamInfo?) -> String {
        var parts = [p.branch ?? "no git"]
        parts.append(team.map { "with \($0.name)" } ?? "with Piopio")
        return parts.joined(separator: " · ")
    }

    private var noTeam: some View {
        VStack(spacing: 10) {
            Text("No team works here").font(.system(size: 15, weight: .semibold))
            Text("With a team, a conversation's lead puts bigger work on a board, where members work in parallel and review each other.")
                .font(.system(size: 13)).foregroundStyle(Color.dsFg2).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Choose a team in Settings") { tab = "settings" }.buttonStyle(PillStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The project's conversations, newest first; those with the team's lead say so, with their tasks.
private struct ProjectConversations: View {
    let engine: EngineController
    let project: ProjectInfo
    let team: TeamInfo?
    @Binding var item: SidebarItem

    var body: some View {
        let sessions = engine.sessions(in: project).filter(\.listed).sorted { $0.updatedAt > $1.updatedAt }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if sessions.isEmpty {
                    Text(team == nil ? "No conversations yet." : "No conversations yet. Each one is with \(team!.name)'s lead.")
                        .font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                }
                ForEach(sessions, id: \.ref.id) { s in row(s) }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ s: SessionSummary) -> some View {
        let tasks = team?.tasks.filter { $0.conversationId == s.ref.id } ?? []
        let open = tasks.filter { ["todo", "doing", "review", "integrating"].contains($0.state) }.count
        return Button { item = .session(s.ref.id) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.dsFg).lineLimit(1)
                    Text(meta(s, tasks: tasks.count, open: open)).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Spacer(minLength: 8)
                if engine.liveStatus[s.ref.id] == .running || open > 0 { SidebarDot(status: .running) }
                else if engine.liveStatus[s.ref.id] == .waitingApproval { SidebarDot(status: .waiting) }
            }
            .padding(12)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func meta(_ s: SessionSummary, tasks: Int, open: Int) -> String {
        var parts = [s.team?.kind == "lead" ? "With the lead" : "With Piopio"]
        if tasks > 0 { parts.append(open > 0 ? "\(open) of \(tasks) task\(tasks == 1 ? "" : "s") running" : "\(tasks) task\(tasks == 1 ? "" : "s") done") }
        parts.append(BuildSessionView.relative(s.updatedAt))
        return parts.joined(separator: " · ")
    }
}

/// Who works here (PT8: the one place to give a project a team), the team's checks and pace, its routines, and the
/// project's instructions and notes.
private struct ProjectSettings: View {
    let engine: EngineController
    let project: ProjectInfo
    let team: TeamInfo?
    @Binding var item: SidebarItem
    @State private var templates: [TeamTemplate] = []
    @State private var testCommand = ""
    @State private var busy = false
    @State private var confirmRemove = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Who works here") { who }
                if let team { section("Checks") { checks(team) } }
                // A project's routines, with or without a team (docs/spec/21 AD5).
                section("Routines") { ProjectRoutinesList(engine: engine, project: project, team: team) }
                section("Instructions and notes") { files }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .disabled(busy)
        .task { templates = await engine.teamTemplates() }
        .task(id: team?.id) { testCommand = team?.testCommand ?? "" }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content()
        }
    }

    /// The team's definition: saved for reuse, or only here.
    private var def: TeamDefinition? { team.flatMap { t in engine.teamDefinitions.first { $0.id == t.definitionId } } }

    @ViewBuilder private var who: some View {
        if let team {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.3").font(.system(size: 14)).foregroundStyle(Color.dsFg2).frame(width: 20).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(team.name).font(.system(size: 13.5, weight: .semibold))
                    Text(team.roles.map(\.name).joined(separator: ", ")).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    if let def, !def.saved {
                        Text("Only in this project. Save it to use it in other projects too.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    Text("Every conversation here is with its lead. It does small things itself and puts bigger work on the Board.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let def, !def.saved {
                    Button("Save for reuse") { act { try await engine.updateTeamDefinition(def, saved: true) } }.buttonStyle(PillStyle(compact: true))
                        .help("List it under your teams, to use it in other projects")
                }
                Button("Open team") { item = .team(team.definitionId ?? team.id) }.buttonStyle(PillStyle(compact: true))
                Button("Remove…") { confirmRemove = true }.buttonStyle(PillStyle(compact: true))
            }
            .card()
            .alert("Remove \(team.name) from \(project.name)?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { act { try await engine.removeTeam(team) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its conversations stay, as conversations with Piopio. Its board and routines go. Its branch\(team.git.map { ", \($0.branch)," } ?? "") stays, with any work you haven't merged.")
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bird").font(.system(size: 14)).foregroundStyle(Color.dsFg2).frame(width: 20).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Piopio").font(.system(size: 13.5, weight: .semibold))
                    Text("Each conversation works on its own. Give the project a team to plan bigger work on a board, with members working in parallel.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Menu {
                    // Your teams first (docs/spec/20 P3): the same members, a board of its own here.
                    if engine.teamDefinitions.contains(where: \.saved) {
                        Section("Your teams") {
                            ForEach(engine.teamDefinitions.filter(\.saved)) { d in Button(d.name) { reuse(d) } }
                        }
                    }
                    Section("New, from a template") {
                        ForEach(templates) { t in Button(t.name) { assign(t) } }
                    }
                } label: { Text("Give it a team") }
                    .menuStyle(.button).buttonStyle(PillStyle(compact: true)).fixedSize()
                    .disabled(templates.isEmpty)
            }
            .card()
        }
    }

    private func checks(_ team: TeamInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Test command", text: $testCommand, prompt: Text("npm test"))
                    .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                    .onSubmit { save(team) }
                Button("Save") { save(team) }.buttonStyle(PillStyle(compact: true))
                    .disabled(testCommand.trimmingCharacters(in: .whitespaces) == (team.testCommand ?? ""))
            }
            Text(team.git == nil ? "Runs after each task, in the project's folder." : "Runs on the team's branch after each merge; a failure sends the task back.")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            Stepper(value: Binding(get: { team.maxParallel }, set: { n in act { try await engine.updateTeam(team, maxParallel: n) } }), in: 1...8) {
                Text("Up to \(team.maxParallel) task\(team.maxParallel == 1 ? "" : "s") at once").font(.system(size: 13))
            }
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 8) {
            fileRow("AGENTS.md", "What every conversation here is told.")
            fileRow("NOTES.md", "What its conversations keep for each other.")
        }
    }

    private func fileRow(_ name: String, _ about: String) -> some View {
        let url = URL(fileURLWithPath: project.path).appendingPathComponent(name)
        let exists = FileManager.default.fileExists(atPath: url.path)
        return HStack(spacing: 10) {
            Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(Color.dsFg2).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium, design: .monospaced))
                Text(exists ? about : "Not there yet.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Spacer()
            if exists { Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(PillStyle(compact: true)) }
        }
    }

    private func assign(_ t: TeamTemplate) {
        act { _ = try await engine.createTeam(name: t.name, template: t.id, cwd: project.path, goal: nil, testCommand: nil) }
    }

    private func reuse(_ d: TeamDefinition) {
        act { _ = try await engine.createTeam(name: d.name, template: d.template, cwd: project.path, goal: nil, testCommand: nil, definition: d.id) }
    }

    private func save(_ team: TeamInfo) {
        let command = testCommand
        act { try await engine.updateTeam(team, testCommand: command) }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await work(); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}

private extension View {
    func card() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }
}

/// A lead conversation's tasks (docs/spec/20 §4), above its composer: each with its state; one opens its member's
/// session, "Board" the project's board.
struct ConversationTasks: View {
    let engine: EngineController
    let team: TeamInfo
    let conversationId: String

    var body: some View {
        let tasks = team.tasks.filter { $0.conversationId == conversationId }
        if !tasks.isEmpty {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(tasks) { chip($0) } }
                }
                Button("Board") {
                    UserDefaults.standard.set("board", forKey: "projectTab")
                    if let project = engine.projects.first(where: { $0.path == team.cwd }) {
                        NotificationCenter.default.post(name: .selectItem, object: SidebarItem.project(project.id).raw)
                    }
                }
                .buttonStyle(PillStyle(kind: .toolbar, compact: true))
            }
            .frame(maxWidth: 680)
        }
    }

    private func chip(_ t: TeamTask) -> some View {
        let running = ["doing", "review", "integrating"].contains(t.state)
        return Button {
            if let id = (t.state == "review" ? t.reviewSessionId : nil) ?? t.sessionId {
                NotificationCenter.default.post(name: .selectItem, object: SidebarItem.session(id).raw)
            }
        } label: {
            HStack(spacing: 6) {
                if running { ProgressView().controlSize(.mini) }
                else { Image(systemName: t.state == "done" ? "checkmark" : t.state == "blocked" ? "exclamationmark.triangle" : "circle").font(.system(size: 10)).foregroundStyle(t.state == "blocked" ? Color.dsWarn : Color.dsFg3) }
                Text(t.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3)
                Text(t.title).font(.system(size: 12)).foregroundStyle(Color.dsFg).lineLimit(1)
                Text(Self.state(t.state)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.dsCard, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(t.sessionId == nil ? t.brief : "Open its session")
    }

    static func state(_ s: String) -> String {
        switch s {
        case "todo": "To do"
        case "doing": "Doing"
        case "review": "In review"
        case "integrating": "Merging"
        case "done": "Done"
        default: "Blocked"
        }
    }
}
