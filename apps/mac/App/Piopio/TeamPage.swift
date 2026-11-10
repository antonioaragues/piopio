import AppKit
import PiopioKit
import SwiftUI

// A team as a definition (docs/spec/20 P3): who's on it and how they work, reused by every project it works in.
// Members · Instructions (TEAM.md) · Memory (the team's NOTES.md) · Projects. No chat: the work is in the projects.

struct TeamPage: View {
    let engine: EngineController
    /// A definition's id; an older selection (a project's team) opens its definition.
    let teamId: String
    @Binding var item: SidebarItem
    @AppStorage("teamTab") private var tab = "members"
    @State private var saving: TeamDefinition?

    private var def: TeamDefinition? {
        engine.teamDefinitions.first { $0.id == teamId }
            ?? engine.teams.first { $0.id == teamId }.flatMap { t in engine.teamDefinitions.first { $0.id == t.definitionId } }
    }

    var body: some View {
        Group {
            if let def {
                VStack(spacing: 0) {
                    PageHeader {
                        PageTitle(name: def.name, subtitle: subtitle(def))
                    } actions: {
                        NeutralSegmented(selection: $tab, options: [("members", "Members"), ("instructions", "Instructions"), ("memory", "Memory"), ("projects", "Projects")])
                            .frame(width: 380)
                        Button("Save as template…") { saving = def }.buttonStyle(PillStyle())
                            .help("A folder with TEAM.md and a card per member, to start other teams from, edit by hand or share")
                    }
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
                    default: TeamMembersEditor(engine: engine, def: def)
                    }
                }
            } else {
                Text("This team is gone.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: teamId) { await engine.loadTeams() }
        .sheet(item: $saving) { def in SaveTemplateSheet(engine: engine, def: def) { saving = nil } }
    }

    private func subtitle(_ def: TeamDefinition) -> String {
        let n = def.projects.count
        return "\(def.roles.count) members · works in \(n == 0 ? "no project yet" : n == 1 ? "1 project" : "\(n) projects")"
    }
}

/// The members: each role card with its model (and agent); edit one, add one, remove one. The team's default model.
private struct TeamMembersEditor: View {
    let engine: EngineController
    let def: TeamDefinition
    @State private var editing: TeamRole?
    @State private var adding = false
    @State private var pickingModel = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Team model").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg2)
                    Button(engine.modelName(def.model) ?? "The app's default") { pickingModel = true }
                        .buttonStyle(PillStyle(compact: true))
                        .popover(isPresented: $pickingModel, arrowEdge: .bottom) {
                            ModelPicker(engine: engine, selected: ref(def.model), role: .build) { m in
                                pickingModel = false
                                act { try await engine.updateTeamDefinition(def, model: "\(m.provider):\(m.id)") }
                            }
                            .frame(width: 340, height: 420)
                        }
                    Text("Members without their own model use it.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Spacer()
                    Button("Add member…") { adding = true }.buttonStyle(PillStyle())
                }
                ForEach(def.roles) { role in card(role) }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
                Text("Changes reach every project this team works in; tasks that already started keep how they began.")
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editing) { role in
            MemberEditor(engine: engine, role: role, isNew: false, canRemove: role.kind != "lead", done: { editing = nil }, save: { save(replacing: role.id, with: $0) }, remove: { removeRole(role) })
        }
        .sheet(isPresented: $adding) {
            MemberEditor(engine: engine, role: TeamRole(name: "", kind: "write", responsibility: ""), isNew: true, canRemove: false, done: { adding = false }, save: { save(replacing: nil, with: $0) }, remove: {})
        }
    }

    private func card(_ role: TeamRole) -> some View {
        let agent = role.agent.flatMap { id in engine.agents.first { $0.ref.id == id } }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(role.name).font(.system(size: 14, weight: .semibold))
                    Text(Self.kind(role.kind)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                }
                Text(role.responsibility).font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                if let done = role.done { Text("Done means: \(done)").font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 6) {
                    if let agent { Label(agent.title, systemImage: "person.crop.circle").font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
                    Text(role.kind == "integrate" ? "No model: it merges and runs the checks" : engine.modelName(role.model).map { "Model: \($0)" } ?? (agent != nil ? "The agent's model" : "The team's model"))
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
            }
            Spacer(minLength: 12)
            Button("Edit") { editing = role }.buttonStyle(PillStyle(compact: true))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }

    private func save(replacing id: String?, with role: TeamRole) {
        var roles = def.roles
        if let id, let i = roles.firstIndex(where: { $0.id == id }) { roles[i] = role } else { roles.append(role) }
        act { try await engine.updateTeamDefinition(def, roles: roles); editing = nil; adding = false }
    }

    private func removeRole(_ role: TeamRole) {
        act { try await engine.updateTeamDefinition(def, roles: def.roles.filter { $0.id != role.id }); editing = nil }
    }

    private func ref(_ raw: String?) -> ModelRef? {
        guard let raw else { return nil }
        let p = raw.split(separator: ":", maxSplits: 1).map(String.init)
        return p.count == 2 ? ModelRef(provider: p[0], id: p[1]) : ModelRef(provider: "openrouter", id: raw)
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
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

/// One member: name, what it may do, what it's responsible for, what done means, its model, the agent it is.
private struct MemberEditor: View {
    let engine: EngineController
    @State var role: TeamRole
    let isNew: Bool
    let canRemove: Bool
    let done: () -> Void
    let save: (TeamRole) -> Void
    let remove: () -> Void
    @State private var pickingModel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New member" : "Edit \(role.name)").font(.system(size: 15, weight: .semibold))
            TextField("Name", text: $role.name, prompt: Text("Designer")).textFieldStyle(.roundedBorder)
            if role.kind != "lead" {
                Picker("Does", selection: $role.kind) {
                    Text("Tasks, in parallel").tag("write")
                    Text("Reviews every task").tag("review")
                    Text("Merges and runs the checks").tag("integrate")
                }
            }
            Text("Responsible for").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsFg2)
            TextEditor(text: $role.responsibility).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(height: 96)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
                .accessibilityLabel("What this member is responsible for")
            TextField("Done means", text: Binding(get: { role.done ?? "" }, set: { role.done = $0.isEmpty ? nil : $0 }), prompt: Text("What done means for its work (optional)"))
                .textFieldStyle(.roundedBorder)
            if role.kind != "integrate" {
                HStack(spacing: 8) {
                    Text("Model").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsFg2)
                    Button(engine.modelName(role.model) ?? (role.agent != nil ? "The agent's" : "The team's")) { pickingModel = true }
                        .buttonStyle(PillStyle(compact: true))
                        .popover(isPresented: $pickingModel, arrowEdge: .bottom) {
                            ModelPicker(engine: engine, selected: nil, role: .build) { m in
                                pickingModel = false
                                role.model = "\(m.provider):\(m.id)"
                            }
                            .frame(width: 340, height: 420)
                        }
                    if role.model != nil { Button("Use the team's") { role.model = nil }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
                }
                Picker("Based on agent", selection: Binding(get: { role.agent ?? "" }, set: { role.agent = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag("")
                    ForEach(engine.agents, id: \.ref.id) { a in Text(a.title).tag(a.ref.id) }
                }
                Text("An agent brings its instructions, and its model when this member has none.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            HStack {
                if canRemove { Button("Remove member", role: .destructive, action: remove) }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save(role) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(role.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
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

/// Where the team works: each project, with its running tasks; a team no project uses can be removed.
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
                ForEach(def.projects, id: \.teamId) { place in
                    let project = engine.projects.first { $0.path == place.cwd }
                    let running = engine.teams.first { $0.id == place.teamId }?.tasks.filter { ["doing", "review", "integrating"].contains($0.state) }.count ?? 0
                    Button { if let project { item = .project(project.id) } } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(Color.dsFg2)
                            Text(project?.name ?? URL(fileURLWithPath: place.cwd).lastPathComponent).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.dsFg)
                            Spacer()
                            if running > 0 { Text("\(running) running").font(.system(size: 12)).foregroundStyle(Color.dsFg3); SidebarDot(status: .running) }
                        }
                        .padding(12)
                        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if def.projects.isEmpty {
                    Text("It doesn't work in any project now.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                    Button("Remove this team") {
                        Task {
                            do { try await engine.removeTeamDefinition(def); item = .home } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
                        }
                    }
                    .buttonStyle(PillStyle())
                    Text("Its folder, with TEAM.md and NOTES.md, stays on disk.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
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
