import AppKit
import PiopioKit
import SwiftUI

// A team's members as the path a task takes (docs/spec/21 D5, design 3a): Plans → Does tasks → Reviews → Merges. A
// card opens its editor below the chain (not a sheet); one "Add member" offers your agents or a member that lives only
// in this team (5f-2); the team's settings are the base its team-only members inherit (5f-3).

struct TeamChain: View {
    let engine: EngineController
    let def: TeamDefinition
    @Binding var item: SidebarItem
    @State private var selected: String?
    @State private var adding = false
    @State private var pickingModel = false
    @State private var error: String?
    @State private var templates: [TeamTemplate] = []

    private static let columns: [(kind: String, title: String)] = [("lead", "Plans"), ("write", "Does tasks"), ("review", "Reviews"), ("integrate", "Merges")]

    /// How many tasks run at once (its first project's, or the default).
    private var atOnce: Int { def.projects.first.flatMap { p in engine.teams.first { $0.id == p.teamId }?.maxParallel } ?? 3 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("How a task moves through the team").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("Team model").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                    Button(engine.modelName(def.model) ?? "The app's default") { pickingModel = true }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg)
                        .popover(isPresented: $pickingModel, arrowEdge: .bottom) {
                            ModelPicker(engine: engine, selected: modelRef(def.model), role: .build) { m in
                                pickingModel = false
                                act { try await engine.updateTeamDefinition(def, model: "\(m.provider):\(m.id)") }
                            }
                            .frame(width: 340, height: 420)
                        }
                    Text("·").foregroundStyle(Color.dsFg3)
                    Button("Add member") { adding = true }.buttonStyle(PillStyle(compact: true))
                        .popover(isPresented: $adding, arrowEdge: .bottom) { addMenu.frame(width: 320) }
                }
                chain
                if let id = selected, let role = def.roles.first(where: { $0.id == id }) {
                    MemberInlineEditor(engine: engine, def: def, role: role, item: $item, close: { selected = nil }, onError: { error = $0 })
                        .id(role.id + (role.agent ?? ""))
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
                TeamSettings(engine: engine, def: def)
                Text("Changing a member changes it in every project this team works in. Tasks already started keep how they began.")
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            templates = await engine.teamTemplates()
            // PIOPIO_DEMO_MEMBER=<role id> opens that member's editor for captures; "add" opens Add member.
            if let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_MEMBER"] {
                if demo == "add" { adding = true } else { selected = demo }
            }
        }
    }

    // MARK: The chain

    private var chain: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(Self.columns.enumerated()), id: \.offset) { i, column in
                if i > 0 { Text("→").font(.system(size: 15)).foregroundStyle(Color.dsFg3).padding(.top, 34) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(column.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsFg3).padding(.leading, 2)
                    let roles = def.roles.filter { $0.kind == column.kind }
                    ForEach(roles) { card($0) }
                    if roles.isEmpty { empty(column.kind) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func card(_ role: TeamRole) -> some View {
        let on = selected == role.id
        let agent = role.agent.flatMap { id in engine.agents.first { $0.ref.id == id } }
        let merges = role.kind == "integrate"
        return Button { withAnimation(.easeOut(duration: 0.15)) { selected = on ? nil : role.id } } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if merges {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AgentHue.system).frame(width: 26, height: 26)
                            .overlay(Text("CI").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(white: 0.08)))
                    } else {
                        SidebarAvatar(id: role.agent ?? "\(def.id)/\(role.id)", name: agent?.title ?? role.name, glyph: agent?.agent?.avatar, size: 26)
                    }
                    Text(role.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                    if role.kind == "write" {
                        Text("×\(atOnce) at once").font(.system(size: 10.5)).foregroundStyle(Color.dsFg2)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.dsChip, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                Text(Self.sentence(role, branches: def.roles.contains { $0.kind == "integrate" }))
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if merges {
                        Text("No model · automatic").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                    } else if let agent {
                        Button { item = .agent(agent.ref.id) } label: {
                            (Text("Is your agent ").foregroundStyle(Color.dsFg3) + Text("\(agent.title) ↗").foregroundStyle(Color.accentColor)).font(.system(size: 11.5))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(engine.modelName(role.model) ?? "Team model").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                    }
                    Spacer(minLength: 0)
                    if !merges { tag(role, agent: agent) }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.dsChip : Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.accentColor : Color.dsLine, style: StrokeStyle(lineWidth: on ? 1.5 : 1, dash: merges && !on ? [4, 3] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `your agent` (filled in its colour) or `team only` (outlined), design 5f.
    private func tag(_ role: TeamRole, agent: SessionSummary?) -> some View {
        Group {
            if role.agent != nil {
                Text("your agent").foregroundStyle(Color(white: 0.08))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(AgentHue.color(role, team: def.id), in: Capsule())
            } else {
                Text("team only").foregroundStyle(Color.dsFg3)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 1))
            }
        }
        .font(.system(size: 10.5, weight: .medium))
    }

    private func empty(_ kind: String) -> some View {
        let text = kind == "review" ? "No one reviews: finished tasks are done." : kind == "integrate" ? "No checks: work stays in the folder." : "No one yet."
        return Text(text).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    /// The role as a sentence: what it does, not a grey label.
    static func sentence(_ role: TeamRole, branches: Bool) -> String {
        switch role.kind {
        case "lead": "Plans and assigns. Talks to you in every conversation."
        case "write": branches ? "Does tasks, each on its own branch." : "Does tasks, several at once."
        case "review": "Reviews every task. Sends it back if it's wrong."
        default: "Merges approved work and runs the checks."
        }
    }

    // MARK: Adding

    /// One "Add member" with two origins (design 5f-2): your agents, or a new member who lives only in this team.
    private var addMenu: some View {
        let members = Set(def.roles.compactMap(\.agent))
        let agents = engine.agents.filter { !members.contains($0.ref.id) && $0.agent?.draft != true }
        var seen = Set(def.roles.map { $0.name.lowercased() })
        let presets = templates.flatMap(\.roles).filter { $0.kind == "write" || $0.kind == "review" }.filter { seen.insert($0.name.lowercased()).inserted }
        return VStack(alignment: .leading, spacing: 2) {
            if !agents.isEmpty {
                section("Your agents")
                ForEach(agents, id: \.ref.id) { a in
                    row(title: a.title, detail: [engine.modelName(a.agent?.model), a.agent?.description].compactMap { $0 }.joined(separator: " · ")) {
                        SidebarAvatar(id: a.ref.id, name: a.title, glyph: a.agent?.avatar, size: 20)
                    } action: {
                        add(TeamRole(name: a.title, kind: "write", responsibility: a.agent?.description ?? "You do the tasks you're given, as \(a.title).", agent: a.ref.id))
                    }
                }
            }
            section("New, only in this team")
            row(title: "Blank member", detail: "Uses the team's setup") {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.dsFg3, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 20, height: 20)
            } action: {
                add(TeamRole(name: "New member", kind: "write", responsibility: ""))
            }
            ForEach(presets.prefix(6)) { r in
                row(title: "From a role: \(r.name)", detail: Self.sentence(r, branches: false)) {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 14)).foregroundStyle(Color.dsFg2).frame(width: 20)
                } action: {
                    add(TeamRole(name: r.name, kind: r.kind, responsibility: r.responsibility, done: r.done))
                }
            }
        }
        .padding(8)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsFg3).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
    }

    private func row<Icon: View>(title: String, detail: String, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Color.dsFg)
                    if !detail.isEmpty { Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1) }
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func add(_ role: TeamRole) {
        adding = false
        act {
            try await engine.updateTeamDefinition(def, roles: def.roles + [role])
            // The new member opens for editing.
            if let fresh = engine.teamDefinitions.first(where: { $0.id == def.id })?.roles.last { selected = fresh.id }
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}

/// A member, edited in place under the chain (design 3a): what it's responsible for, what done means, who it is (a new
/// member or one of your agents), its model; "Remove from team" and, for a team-only member, "Make it one of your agents".
private struct MemberInlineEditor: View {
    let engine: EngineController
    let def: TeamDefinition
    let role: TeamRole
    @Binding var item: SidebarItem
    let close: () -> Void
    let onError: (String?) -> Void
    @State private var draft: TeamRole
    @State private var pickingModel = false

    init(engine: EngineController, def: TeamDefinition, role: TeamRole, item: Binding<SidebarItem>, close: @escaping () -> Void, onError: @escaping (String?) -> Void) {
        self.engine = engine; self.def = def; self.role = role; self._item = item; self.close = close; self.onError = onError
        self._draft = State(initialValue: role)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Name", text: $draft.name).textFieldStyle(.plain).font(.system(size: 15, weight: .semibold)).fixedSize()
                if role.kind != "lead", role.kind != "integrate" {
                    Picker("", selection: $draft.kind) {
                        Text("Does tasks").tag("write")
                        Text("Reviews every task").tag("review")
                    }
                    .labelsHidden().fixedSize()
                }
                Spacer()
                if role.agent == nil, role.kind == "write" || role.kind == "review" {
                    Button("Make it one of your agents") { run { _ = try await engine.promoteMember(def, role) } }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                        .help("It becomes an agent of yours, with this role as its instructions; it stays on this team")
                }
                if role.kind != "lead" {
                    Button("Remove from team") { run { try await engine.updateTeamDefinition(def, roles: def.roles.filter { $0.id != role.id }); close() } }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                }
            }
            if role.kind == "integrate" {
                Text("It merges each approved task into the team's branch and runs the project's checks (set in the project's Settings). It has no model.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            } else {
                field("Responsible for") {
                    TextEditor(text: $draft.responsibility).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(height: 90)
                        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
                }
                field("Done means") {
                    TextField("What done means for its work (optional)", text: Binding(get: { draft.done ?? "" }, set: { draft.done = $0.isEmpty ? nil : $0 })).textFieldStyle(.roundedBorder)
                }
                field("Who it is") {
                    HStack(spacing: 10) {
                        Picker("", selection: Binding(get: { draft.agent ?? "" }, set: { draft.agent = $0.isEmpty ? nil : $0 })) {
                            Text("A new member").tag("")
                            ForEach(engine.agents.filter { $0.agent?.draft != true }, id: \.ref.id) { a in Text(a.title).tag(a.ref.id) }
                        }
                        .labelsHidden().fixedSize()
                        Text(draft.agent == nil ? "or one of your agents: brings its instructions and model" : "Keeps its instructions, plus TEAM.md; writes what it learns to the team's notes")
                            .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                }
                field("Model") {
                    HStack(spacing: 8) {
                        Button(engine.modelName(draft.model).map { $0 } ?? (draft.agent != nil ? "The agent's" : "The team's · \(engine.modelName(def.model) ?? "default")")) { pickingModel = true }
                            .buttonStyle(PillStyle(compact: true))
                            .popover(isPresented: $pickingModel, arrowEdge: .bottom) {
                                ModelPicker(engine: engine, selected: modelRef(draft.model), role: .build) { m in
                                    pickingModel = false
                                    draft.model = "\(m.provider):\(m.id)"
                                }
                                .frame(width: 340, height: 420)
                            }
                        if draft.model != nil { Button("Use the team's") { draft.model = nil }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close", action: close).buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                if draft != role {
                    Button("Save") { run { try await engine.updateTeamDefinition(def, roles: def.roles.map { $0.id == role.id ? draft : $0 }) } }
                        .buttonStyle(PillStyle(kind: .primary, compact: true)).keyboardShortcut("s", modifiers: .command)
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(16)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
    }

    private func field<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).frame(width: 110, alignment: .leading)
            content()
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); onError(nil) } catch { onError((error as? EngineError)?.message ?? error.localizedDescription) }
        }
    }
}

/// The team's settings (design 5f-3): the base its team-only members inherit; your agents keep theirs.
private struct TeamSettings: View {
    let engine: EngineController
    let def: TeamDefinition
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Team settings").font(.system(size: 14, weight: .semibold)).padding(.bottom, 4)
            Text("The base for members who live only in this team; your agents keep their own model.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).padding(.bottom, 10)
            row("Members may", "what they do without asking") {
                Picker("", selection: Binding(get: { def.memberMode }, set: { v in act { try await engine.updateTeamDefinition(def, memberMode: v) } })) {
                    Text("Only read").tag("read_only")
                    Text("Edit, ask before commands").tag("ask")
                    Text("Edit files on their own").tag("auto_edit")
                    Text("Do everything on their own").tag("full_auto")
                }
                .labelsHidden().fixedSize()
            }
            row("Review", "sent back at most") {
                Stepper(value: Binding(get: { def.reviewLimit ?? 3 }, set: { n in act { try await engine.updateTeamDefinition(def, reviewLimit: n) } }), in: 1...10) {
                    Text("\(def.reviewLimit ?? 3) time\((def.reviewLimit ?? 3) == 1 ? "" : "s"), then ask me").font(.system(size: 13))
                }
                .fixedSize()
            }
            row("Budget", "per job, across members") {
                TextField("No limit", value: Binding(get: { def.budgetPerJob }, set: { v in act { try await engine.updateTeamDefinition(def, budgetPerJob: v ?? 0) } }), format: .currency(code: "USD"))
                    .textFieldStyle(.roundedBorder).frame(width: 100)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn).padding(.top, 6) }
        }
        .padding(16)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
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
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}
