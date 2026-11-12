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
    /// A team picked on the empty Board: the fit check comes first (docs/spec/21 D6).
    @State private var choosing: TeamChoice?

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

    private func subtitle(_ p: ProjectInfo, _ team: TeamInfo?) -> String {
        var parts = [p.branch ?? "no git"]
        parts.append(team.map { "with \($0.name)" } ?? "with Piopio")
        return parts.joined(separator: " · ")
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
                section("Instructions and notes") {
                    VStack(alignment: .leading, spacing: 10) {
                        ProjectFileRow(project: project, name: "AGENTS.md", about: "What every conversation here is told.", starter: "# \(project.name)\n\nWhat this project is, how to build and test it, and its conventions.\n")
                        ProjectFileRow(project: project, name: "NOTES.md", about: "What its conversations keep for each other.", starter: "# Notes\n\n")
                    }
                }
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
