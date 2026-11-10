import AppKit
import PiopioKit
import SwiftUI

// Teams (docs/spec/19): a start page that makes one from a template, and the team's page: its lead's conversation,
// the board as a kanban you can edit (TD5), and its members (role cards).

// MARK: Start

/// New team: a template (development, research, writing…), a name, where it works, and optionally the goal.
struct TeamStart: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var templates: [TeamTemplate] = []
    @State private var chosen = "development"
    @State private var name = ""
    @State private var projectId: String?
    @State private var testCommand = ""
    @State private var goal = ""
    @State private var creating = false
    @State private var error: String?
    @FocusState private var focus: StartField?

    private var template: TeamTemplate? { templates.first { $0.id == chosen } }
    private var needsProject: Bool { template?.workplace == "project" }
    private var project: ProjectInfo? { engine.projects.first { $0.id == projectId && $0.missing != true } }
    private var canCreate: Bool { template != nil && (!needsProject || project != nil) }

    var body: some View {
        StartColumn(top: 96) {
            StartHeader(kind: .team, description: "A lead plans and hands tasks to its members, who work in parallel; reviews and checks happen on the way. You see it all on a board, and can step in anywhere.") {
                TitleField(placeholder: template?.name ?? "Team name", text: $name, focused: $focus) { focus = .text }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Kind of team").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg2)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(templates) { t in templateCard(t) }
                }
            }
            if needsProject {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Project").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg2)
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(engine.projects.filter { $0.missing != true }) { p in Button(p.name) { projectId = p.id } }
                            if !engine.projects.isEmpty { Divider() }
                            Button("Open Folder…") { NotificationCenter.default.post(name: .openProject, object: nil) }
                        } label: {
                            Text(project?.name ?? "Choose a project…").foregroundStyle(project == nil ? Color.dsFg3 : Color.dsFg)
                        }
                        .menuStyle(.button).buttonStyle(PillStyle()).fixedSize()
                        TextField("", text: $testCommand, prompt: Text("Checks after each merge, e.g. npm test (optional)").foregroundStyle(Color.dsFg3))
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    Text(project.map { "It works on its own branch of \($0.name); your branch isn't touched until you merge." } ?? "It works on its own branch of the project; yours isn't touched until you merge.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
            } else if template != nil {
                Text("It works in its own folder, ~/Piopio/Teams/\(slug).").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Goal (optional)").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg2)
                TextEditor(text: $goal)
                    .focused($focus, equals: .text)
                    .font(.system(size: 14)).scrollContentBackground(.hidden).padding(12).frame(height: 96)
                    .composerBox()
                    .accessibilityLabel("Goal")
                StartError(text: error)
                HStack {
                    Text(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You can give it the goal later, in the lead's chat." : "The lead starts planning as soon as it's created.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Spacer()
                    MainAction(title: "Create team ⌘↩", busy: creating, enabled: canCreate, action: create)
                }
            }
        }
        .task {
            templates = await engine.teamTemplates()
            if projectId == nil { projectId = engine.projects.first { $0.missing != true }?.id }
            focus = .name
        }
    }

    private var slug: String {
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? (template?.name ?? "team") : name
        return base.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
    }

    private func templateCard(_ t: TeamTemplate) -> some View {
        let on = t.id == chosen
        return Button { chosen = t.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(t.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
                Text(t.description).font(.system(size: 12)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                Text(t.roles.map(\.name).joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(on ? Color.dsAccentSoft : Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.accentColor.opacity(0.6) : Color.dsLine, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func create() {
        guard canCreate, !creating, let template else { return }
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let team = try await engine.createTeam(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? template.name : name, template: template.id, cwd: needsProject ? project?.path : nil, goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), testCommand: testCommand.trimmingCharacters(in: .whitespaces))
                item = .team(team.id)
            } catch {
                self.error = ((error as? EngineError)?.message ?? String(describing: error)) + " Nothing was created."
            }
        }
    }
}

// MARK: Page

/// A team: its lead's conversation (where you give the goal and talk), the board, the members.
struct TeamPage: View {
    let engine: EngineController
    let teamId: String
    @Binding var item: SidebarItem
    @AppStorage("teamTab") private var tab = "board"

    private var team: TeamInfo? { engine.teams.first { $0.id == teamId } }

    var body: some View {
        if let team {
            VStack(spacing: 0) {
                PageHeader {
                    PageTitle(name: team.name, subtitle: subtitle(team))
                } actions: {
                    NeutralSegmented(selection: $tab, options: [("lead", "Lead"), ("board", "Board"), ("routines", "Routines"), ("members", "Members")])
                        .frame(width: 320)
                }
                switch tab {
                case "lead": lead(team)
                case "members": TeamMembers(team: team)
                case "routines": TeamRoutines(engine: engine, team: team)
                default: TeamBoard(engine: engine, team: team, item: $item)
                }
            }
            .task(id: teamId) { await engine.loadTeams() }
        } else {
            Text("This team is gone.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func subtitle(_ team: TeamInfo) -> String {
        let kind = team.template.prefix(1).uppercased() + team.template.dropFirst()
        let place = team.git.map { "\(URL(fileURLWithPath: team.cwd).lastPathComponent) · \($0.branch)" } ?? "~/Piopio/Teams/\(URL(fileURLWithPath: team.folder).lastPathComponent)"
        return "\(kind) · \(place)"
    }

    @ViewBuilder private func lead(_ team: TeamInfo) -> some View {
        if let id = team.leadSessionId, let summary = engine.buildSessions.first(where: { $0.ref.id == id }) {
            BuildSessionView(engine: engine, session: engine.thread(summary.ref), summary: summary).id(id)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The board (TD5): To do, Doing, Review, Done and Blocked. A card opens its member's session; its menu moves it
/// back, stops it or hands it to another role.
struct TeamBoard: View {
    let engine: EngineController
    let team: TeamInfo
    @Binding var item: SidebarItem
    @State private var adding = false

    private static let columns: [(id: String, title: String, states: Set<String>)] = [
        ("todo", "To do", ["todo"]), ("doing", "Doing", ["doing"]), ("review", "Review", ["review", "integrating"]), ("done", "Done", ["done"]), ("blocked", "Blocked", ["blocked"]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if team.git != nil { TeamLandingCard(engine: engine, team: team).padding([.horizontal, .top], 20) }
            columns
        }
        .sheet(isPresented: $adding) { AddTeamTask(engine: engine, team: team) { adding = false } }
    }

    private var columns: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Self.columns, id: \.id) { column in
                    let tasks = team.tasks.filter { column.states.contains($0.state) }
                    if column.id != "blocked" || !tasks.isEmpty { self.column(column.title, tasks, add: column.id == "todo") }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func column(_ title: String, _ tasks: [TeamTask], add: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(tasks.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
                Spacer()
                if add {
                    Button { adding = true } label: { Image(systemName: "plus").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Add a task")
                }
            }
            .padding(.horizontal, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tasks) { card($0) }
                    if tasks.isEmpty { Text(add ? "The lead adds tasks here. You can too." : "Nothing here.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.horizontal, 4) }
                }
            }
        }
        .frame(width: 240, alignment: .topLeading)
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.dsChip.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func card(_ task: TeamTask) -> some View {
        let role = team.roles.first { $0.id == task.role }
        return Button { if let id = task.reviewSessionId ?? task.sessionId, task.state == "review" { item = .session(id) } else if let id = task.sessionId { item = .session(id) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(task.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3)
                    if task.state == "doing" || task.state == "review" || task.state == "integrating" { ProgressView().controlSize(.mini) }
                    Spacer()
                    Text(role?.name ?? task.role).font(.system(size: 11)).foregroundStyle(Color.dsFg2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.dsChip, in: Capsule())
                }
                Text(task.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                if let line = status(task) { Text(line).font(.system(size: 11.5)).foregroundStyle(task.state == "blocked" ? Color.dsWarn : Color.dsFg3).lineLimit(3) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.sessionId == nil ? task.brief : "Open its session")
        .contextMenu {
            if task.state != "todo" { Button("Move to To do") { update(task, state: "todo") } }
            if task.state != "blocked" { Button("Stop (Blocked)") { update(task, state: "blocked") } }
            if task.state != "done" { Button("Mark Done") { update(task, state: "done") } }
            let writers = team.roles.filter { $0.kind == "write" && $0.id != task.role }
            if !writers.isEmpty {
                Divider()
                ForEach(writers) { r in Button("Give to \(r.name)") { update(task, role: r.id) } }
            }
        }
    }

    private func status(_ task: TeamTask) -> String? {
        switch task.state {
        case "review": "In review"
        case "integrating": "Merging and checking"
        case "blocked": task.blocked
        case "doing": task.attempts > 0 ? "Round \(task.attempts + 1), after a review" : (task.by == "you" ? "Added by you" : nil)
        case "done": task.report.map { $0.replacingOccurrences(of: "\n", with: " ") }
        default: task.by == "you" ? "Added by you" : nil
        }
    }

    private func update(_ task: TeamTask, state: String? = nil, role: String? = nil) {
        Task { try? await engine.updateTeamTask(team, task, state: state, role: role) }
    }
}

/// You add a card to the board: a title, a brief, who does it.
private struct AddTeamTask: View {
    let engine: EngineController
    let team: TeamInfo
    let done: () -> Void
    @State private var title = ""
    @State private var brief = ""
    @State private var role: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New task").font(.system(size: 15, weight: .semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $brief).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(height: 110)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
            Picker("For", selection: $role) {
                ForEach(team.roles.filter { $0.kind == "write" }) { r in Text(r.name).tag(Optional(r.id)) }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task {
                        do {
                            try await engine.addTeamTask(team, title: title, brief: brief, role: role)
                            done()
                        } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { role = team.roles.first { $0.kind == "write" }?.id }
    }
}

/// The role cards: what each member does, and what it may do.
struct TeamMembers: View {
    let team: TeamInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(team.roles) { role in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(role.name).font(.system(size: 14, weight: .semibold))
                            Text(Self.kind(role.kind)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                        }
                        Text(role.responsibility).font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                        if let done = role.done { Text("Done means: \(done)").font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
                }
                Text("At most \(team.maxParallel) tasks run at once. Members \(team.memberMode == "full_auto" ? "run without asking" : "edit files on their own and ask before commands").\(team.testCommand.map { " After each merge: \($0)." } ?? "")")
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    static func kind(_ kind: String) -> String {
        switch kind {
        case "lead": "Plans and assigns"
        case "write": "Does tasks, in parallel"
        case "review": "Reviews every task"
        default: "Merges and runs the checks"
        }
    }
}

/// The merge card (docs/spec/19 §11): what the team's branch would bring to the project's, and the two ways to land
/// it: merge it here, or push it for a pull request. Shown once the branch has work the project doesn't.
struct TeamLandingCard: View {
    let engine: EngineController
    let team: TeamInfo
    @State private var landing: TeamLanding?
    @State private var busy = false
    @State private var confirming = false
    @State private var note: (text: String, warn: Bool)?

    /// Reloads when a card moves or lands.
    private var key: String { team.tasks.map { "\($0.id)\($0.state)\($0.landed ?? "")" }.joined(separator: ",") }

    var body: some View {
        // A stack, not a Group: an empty Group has nothing to run the task on.
        VStack(alignment: .leading, spacing: 0) {
            if let landing, landing.ahead > 0 { card(landing) }
            else if let note { line(note.text, warn: note.warn).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .task(id: key) { landing = await engine.teamLanding(team) }
    }

    private func card(_ l: TeamLanding) -> some View {
        let added = l.files.reduce(0) { $0 + $1.added }, removed = l.files.reduce(0) { $0 + $1.removed }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 15)).foregroundStyle(Color.dsFg2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.open > 0 ? "Done work is ready for \(l.base)" : "Ready for \(l.base)").font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(count(l.tasks.count, "task")).help(l.tasks.map { "\($0.id) \($0.title)" }.joined(separator: "\n"))
                        Text("·")
                        Text(count(l.files.count, "file")).help(l.files.map { "\($0.path)  +\($0.added) −\($0.removed)" }.joined(separator: "\n"))
                        if added > 0 { Text("+\(added)").foregroundStyle(Color.dsGreen) }
                        if removed > 0 { Text("−\(removed)").foregroundStyle(Color.dsRed) }
                        Text("·")
                        Text(l.branch).font(.system(size: 12, design: .monospaced))
                    }
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
                }
                Spacer(minLength: 12)
                if busy { ProgressView().controlSize(.small) }
                if l.remote != nil {
                    Button("Push for a PR") { Task { await land("push") } }.buttonStyle(PillStyle())
                        .help("Pushes \(l.branch) to \(l.remote ?? "the remote")\(l.compareUrl != nil ? " and opens GitHub to create the pull request" : "")")
                }
                Button("Merge into \(l.base)…") { confirming = true }.buttonStyle(PillStyle(kind: .primary))
            }
            if l.open > 0 { line("\(count(l.open, "task")) still on the board; they stay on the team's branch.", warn: false) }
            if l.behind > 0 { line("\(l.base) has \(count(l.behind, "commit")) the team doesn't. If they touch the same files, the merge stops and changes nothing.", warn: false) }
            if let note { line(note.text, warn: note.warn) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .disabled(busy)
        .alert("Merge \(l.branch) into \(l.base)?", isPresented: $confirming) {
            Button("Merge") { Task { await land("merge") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(l.checkedOut == l.base
                ? "In the project's folder, which is on \(l.base): \(count(l.tasks.count, "task")), \(count(l.files.count, "file")). The team keeps working from there."
                : "The project's folder is on \(l.checkedOut ?? "another branch") and stays there; \(l.base) is updated aside. \(count(l.tasks.count, "task")), \(count(l.files.count, "file")).")
        }
    }

    private func line(_ text: String, warn: Bool) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(warn ? Color.dsWarn : Color.dsFg3).fixedSize(horizontal: false, vertical: true)
    }

    private func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    private func land(_ action: String) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await engine.landTeam(team, action: action)
            if action == "push" {
                if let url = result.compareUrl.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
                note = ("Pushed \(team.git?.branch ?? "the team's branch")\(result.compareUrl != nil ? ": create the pull request in your browser." : ".")", false)
            } else {
                note = ("Merged into \(team.git?.base ?? "the project")\(result.commit.map { " (\($0))" } ?? ""). The lead knows.", false)
            }
        } catch {
            note = ((error as? EngineError)?.message ?? error.localizedDescription, true)
        }
        landing = await engine.teamLanding(team)
    }
}

/// Routines (docs/spec/19 T1): what starts the team's work on its own. The lead sets them when you ask it; you can add,
/// run or remove them here.
struct TeamRoutines: View {
    let engine: EngineController
    let team: TeamInfo
    @State private var adding = false
    @State private var error: String?

    private var routines: [TeamRoutine] { team.routines ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("What starts the team's work on its own. Ask the lead (“every Monday, a brief on our competitors”), or add one here.")
                        .font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 16)
                    Button("Add routine…") { adding = true }.buttonStyle(PillStyle())
                }
                if routines.isEmpty {
                    Text("No routines yet.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(.top, 8)
                }
                ForEach(routines) { row($0) }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $adding) { AddTeamRoutine(engine: engine, team: team) { adding = false } }
    }

    private func row(_ r: TeamRoutine) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.icon(r.on)).font(.system(size: 14)).foregroundStyle(Color.dsFg2).frame(width: 20).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.label ?? r.on).font(.system(size: 13.5, weight: .semibold))
                Text(r.prompt).font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                Text(meta(r)).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                if let url = r.url {
                    HStack(spacing: 6) {
                        Text(url).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
                            .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Color.dsFg2)
                    }
                }
            }
            Spacer(minLength: 12)
            Button("Run now") { act { try await engine.runTeamRoutine(team, r) } }.buttonStyle(PillStyle(compact: true))
                .help("The lead gets it now, as if it had fired")
            Button { act { try await engine.removeTeamRoutine(team, r) } } label: { Image(systemName: "trash").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Remove this routine").padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }

    private func meta(_ r: TeamRoutine) -> String {
        var parts: [String] = []
        if let next = r.next { parts.append("Next \(Self.day.string(from: Date(timeIntervalSince1970: next / 1000)))") }
        parts.append(r.runs == 0 ? "Hasn't run yet" : "Ran \(r.runs == 1 ? "once" : "\(r.runs) times")")
        if let last = r.lastRun.flatMap(Self.iso.date(from:)) { parts.append("last \(Self.day.string(from: last))") }
        parts.append(r.by == "lead" ? "set by the lead" : "set by you")
        return parts.joined(separator: " · ")
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return f
    }()

    static func icon(_ on: String) -> String {
        switch on {
        case "folder": "folder"
        case "email": "envelope"
        case "webhook": "link"
        default: "clock"
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}

/// A routine by hand: a time (repeating or once), a folder, an email or a webhook, and what the team does then.
private struct AddTeamRoutine: View {
    let engine: EngineController
    let team: TeamInfo
    let done: () -> Void
    @State private var on = "time"
    @State private var repeats = "weekly"
    @State private var weekday = 2 // Calendar: 1 is Sunday
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var once = Date().addingTimeInterval(3600)
    @State private var folder = ""
    @State private var from = ""
    @State private var subject = ""
    @State private var prompt = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New routine").font(.system(size: 15, weight: .semibold))
            Picker("When", selection: $on) {
                Text("At a time").tag("time")
                Text("A file in a folder").tag("folder")
                Text("An email").tag("email")
                Text("A webhook call").tag("webhook")
            }
            switch on {
            case "time":
                Picker("Repeats", selection: $repeats) {
                    Text("Every day").tag("daily")
                    Text("Every weekday").tag("weekdays")
                    Text("Every week").tag("weekly")
                    Text("Once").tag("once")
                }
                if repeats == "weekly" {
                    Picker("On", selection: $weekday) {
                        ForEach(1...7, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d % 7]).tag((d % 7) + 1) }
                    }
                }
                if repeats == "once" { DatePicker("At", selection: $once, in: Date()...) }
                else { DatePicker("At", selection: $time, displayedComponents: .hourAndMinute) }
            case "folder":
                HStack {
                    TextField("Folder", text: $folder, prompt: Text("~/Inbox/Reports")).textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseFolder)
                }
            case "email":
                TextField("From", text: $from, prompt: Text("Part of the sender's name or address")).textFieldStyle(.roundedBorder)
                TextField("Subject", text: $subject, prompt: Text("Words in the subject")).textFieldStyle(.roundedBorder)
                Text("Checked every 5 minutes in your connected mail.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            default:
                Text("You get a URL on this Mac that other apps can POST to; the body comes with the routine.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Text("Then the team…").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg2)
            TextEditor(text: $prompt).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(height: 90)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
                .accessibilityLabel("What the team does then")
            Text("The lead gets this and plans it like a request from you.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Add", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// A cron for the repeating times, a local date-time for once.
    private var when: String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hm = "\(c.minute ?? 0) \(c.hour ?? 9)"
        switch repeats {
        case "daily": return "\(hm) * * *"
        case "weekdays": return "\(hm) * * 1-5"
        case "weekly": return "\(hm) * * \(weekday - 1)"
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm"
            return f.string(from: once)
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await engine.addTeamRoutine(team, on: on, prompt: prompt, when: on == "time" ? when : nil, folder: on == "folder" ? folder : nil, from: on == "email" ? from : nil, subject: on == "email" ? subject : nil)
                done()
            } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
    }
}
