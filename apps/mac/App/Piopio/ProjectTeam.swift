import AppKit
import PiopioKit
import SwiftUI

// Who works in a project (docs/spec/21 D6, design 4a/4b/5c-2): Piopio alone or a team, as two cards; the picker the
// empty Board shows; the fit check before a team starts in a folder; and the project's AGENTS.md and NOTES.md.

/// A team to bring into a project: one of yours (its members, a board of its own here) or a template.
enum TeamChoice: Identifiable, Hashable {
    case yours(TeamDefinition)
    case template(TeamTemplate)
    var id: String { switch self { case .yours(let d): "def:\(d.id)"; case .template(let t): "tpl:\(t.id)" } }
    var name: String { switch self { case .yours(let d): d.name; case .template(let t): t.name } }
    var roles: [TeamRole] { switch self { case .yours(let d): d.roles; case .template(let t): t.roles } }
}

/// The members as a short chain (design 4a): Lead → Builder ×3 → QA → CI, in 16pt avatars.
struct MiniChain: View {
    let roles: [TeamRole]
    let team: String
    var atOnce: Int?

    var body: some View {
        let order = ["lead", "write", "review", "integrate"]
        let sorted = roles.sorted { (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9) }
        HStack(spacing: 5) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { i, role in
                if i > 0 { Text("→").font(.system(size: 10.5)).foregroundStyle(Color.dsFg3) }
                if role.kind == "integrate" {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(AgentHue.system).frame(width: 16, height: 16)
                        .overlay(Text("CI").font(.system(size: 6.5, weight: .bold)).foregroundStyle(Color(white: 0.08)))
                } else {
                    SidebarAvatar(id: role.agent ?? "\(team)/\(role.id)", name: role.name, size: 16)
                }
                Text(role.name + (role.kind == "write" && (atOnce ?? 1) > 1 ? " ×\(atOnce!)" : "")).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(1)
            }
        }
    }
}

/// "Who works here" (design 4a): two cards side by side. Piopio alone, or a team with its mini chain.
struct WhoWorksHere: View {
    let engine: EngineController
    let project: ProjectInfo
    let team: TeamInfo?
    @Binding var item: SidebarItem
    let templates: [TeamTemplate]
    @Binding var choosing: TeamChoice?
    @State private var confirmRemove = false
    @State private var error: String?

    private var def: TeamDefinition? { team.flatMap { t in engine.teamDefinitions.first { $0.id == t.definitionId } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                card(on: team == nil, action: { if team != nil { confirmRemove = true } }) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            radio(team == nil)
                            Text("Piopio alone").font(.system(size: 13.5, weight: .semibold))
                        }
                        Text("Each conversation works on its own.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    }
                }
                card(on: team != nil, action: {}) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            radio(team != nil)
                            Text("A team").font(.system(size: 13.5, weight: .semibold))
                            Spacer(minLength: 4)
                            teamMenu
                        }
                        if let team {
                            MiniChain(roles: team.roles, team: team.definitionId ?? team.id, atOnce: team.maxParallel)
                            if let def, !def.saved { Text("Only in this project until you save it for reuse.").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                        } else {
                            Text("A lead plans bigger work on a board; members work in parallel and review each other.")
                                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if team == nil {
                Button("No team fits? Describe one for this project…") { item = .start(.team) }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
        }
        .alert("Remove \(team?.name ?? "the team") from \(project.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                guard let team else { return }
                Task {
                    do { try await engine.removeTeam(team); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its conversations stay, as conversations with Piopio. Its board and routines go. Its branch\(team?.git.map { ", \($0.branch)," } ?? "") stays, with any work you haven't merged.")
        }
    }

    @ViewBuilder private var teamMenu: some View {
        if let team {
            Menu {
                Button("Open Team") { item = .team(team.definitionId ?? team.id) }
                if let def, !def.saved { Button("Save for Reuse") { Task { try? await engine.updateTeamDefinition(def, saved: true) } } }
                Divider()
                Button("Remove from Project…", role: .destructive) { confirmRemove = true }
            } label: {
                HStack(spacing: 4) {
                    Text(team.name)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12.5))
            }
            .menuStyle(.button).buttonStyle(ComposerChipStyle()).menuIndicator(.hidden).fixedSize()
        } else {
            Menu {
                let yours = engine.teamDefinitions.filter(\.saved)
                if !yours.isEmpty {
                    Section("Your teams") { ForEach(yours) { d in Button(d.name) { choosing = .yours(d) } } }
                }
                Section("New, from a template") { ForEach(templates) { t in Button(t.name) { choosing = .template(t) } } }
            } label: {
                HStack(spacing: 4) {
                    Text("Choose a team")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12.5))
            }
            .menuStyle(.button).buttonStyle(ComposerChipStyle()).menuIndicator(.hidden).fixedSize()
            .disabled(templates.isEmpty)
        }
    }

    private func radio(_ on: Bool) -> some View {
        Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.system(size: 13)).foregroundStyle(on ? Color.accentColor : Color.dsFg3)
    }

    /// A radio card: the chosen one has a 1.5pt accent border.
    private func card<Content: View>(on: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.accentColor : Color.dsLine, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// The empty Board (design 4b): your teams and templates, each "Use here", or describe one.
struct TeamPickerList: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @Binding var choosing: TeamChoice?
    @State private var templates: [TeamTemplate] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Give it a team").font(.system(size: 15, weight: .semibold))
                Text("A conversation's lead puts bigger work here; members work in parallel and review each other.")
                    .font(.system(size: 13)).foregroundStyle(Color.dsFg2)
            }
            let yours = engine.teamDefinitions.filter(\.saved)
            if !yours.isEmpty {
                group("Your teams") { ForEach(yours) { d in row(.yours(d), detail: d.roles.map(\.name).joined(separator: ", ")) } }
            }
            group("Templates") { ForEach(templates) { t in row(.template(t), detail: t.description) } }
            Button("Or describe one…") { item = .start(.team) }
                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .task { templates = await engine.teamTemplates() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsFg3)
            VStack(spacing: 0) { content() }
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        }
    }

    private func row(_ choice: TeamChoice, detail: String) -> some View {
        HStack(spacing: 12) {
            TeamStack(colors: TeamStack.colors(choice.roles, team: choice.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.name).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            Spacer()
            Button("Use here") { choosing = choice }.buttonStyle(PillStyle(compact: true))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

/// Before a team works in a folder (design 5c-2): what it needs there, each missing thing with its fix, then Add.
struct FitCheckSheet: View {
    let engine: EngineController
    let project: ProjectInfo
    let choice: TeamChoice
    let done: () -> Void
    @State private var fit: FitCheck?
    @State private var startGit = true
    @State private var checks = ""
    @State private var writeAgents = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(choice.name) in \(project.name)").font(.system(size: 15, weight: .semibold))
                MiniChain(roles: choice.roles, team: choice.id)
            }
            if let fit {
                VStack(alignment: .leading, spacing: 12) {
                    row(ok: fit.git, title: fit.git ? "Git" : "No git yet",
                        detail: fit.git ? "Each task works on its own branch; you merge when it's ready." : "Without it, members share the folder and work one at a time.") {
                        if !fit.git { Toggle("Start git", isOn: $startGit).toggleStyle(.checkbox) }
                    }
                    row(ok: !checks.trimmingCharacters(in: .whitespaces).isEmpty, title: "Checks",
                        detail: fit.checks != nil ? "Found in the folder; they run after each merge. A failure sends the task back." : "None found. Without them, a review is the only check.") {
                        TextField("", text: $checks, prompt: Text("npm test"))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced)).frame(width: 150)
                    }
                    row(ok: fit.agentsMd, title: "AGENTS.md",
                        detail: fit.agentsMd ? "What every member is told about this project." : "Members only know what the lead tells them.") {
                        if !fit.agentsMd { Toggle("Write one with Piopio", isOn: $writeAgents).toggleStyle(.checkbox) }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Add to project", action: add).keyboardShortcut(.defaultAction).disabled(busy || fit == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            fit = await engine.fitCheck(project.path)
            checks = fit?.checks ?? ""
        }
    }

    private func row<Fix: View>(ok: Bool, title: String, detail: String, @ViewBuilder fix: () -> Fix) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 14)).foregroundStyle(ok ? Color.dsGreen : Color.dsWarn).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            fix()
        }
    }

    private func add() {
        busy = true
        let command = checks.trimmingCharacters(in: .whitespaces)
        let initGit = fit?.git == false && startGit
        let agents = fit?.agentsMd == false && writeAgents
        Task {
            defer { busy = false }
            do {
                switch choice {
                case .yours(let d): _ = try await engine.createTeam(name: d.name, template: d.template, cwd: project.path, goal: nil, testCommand: command.isEmpty ? nil : command, initGit: initGit, definition: d.id)
                case .template(let t): _ = try await engine.createTeam(name: t.name, template: t.id, cwd: project.path, goal: nil, testCommand: command.isEmpty ? nil : command, initGit: initGit)
                }
                // AGENTS.md by Piopio (alone): a conversation of its own in the project.
                if agents, let ref = await engine.createBuildSession(in: project) {
                    _ = await engine.thread(ref).send("Read this project and write an AGENTS.md at its root for the team that works here: what the project is, how to build, run and test it, its layout and conventions. Keep it short and concrete.")
                }
                done()
            } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}

/// AGENTS.md and NOTES.md (design 4a): "Edited 2 days ago" and Open, or Create.
struct ProjectFileRow: View {
    let project: ProjectInfo
    let name: String
    let about: String
    let starter: String
    @State private var tick = 0

    var body: some View {
        let url = URL(fileURLWithPath: project.path).appendingPathComponent(name)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        _ = tick
        return HStack(spacing: 10) {
            Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(Color.dsFg2).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium, design: .monospaced))
                Text(about).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Spacer()
            if let modified {
                Text("Edited \(RelativeDateTimeFormatter().localizedString(for: modified, relativeTo: Date()))").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(PillStyle(compact: true))
            } else {
                Button("Create") {
                    try? starter.write(to: url, atomically: true, encoding: .utf8)
                    tick += 1
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(PillStyle(compact: true))
            }
        }
    }
}
