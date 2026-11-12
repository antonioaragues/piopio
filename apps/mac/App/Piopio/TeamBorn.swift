import PiopioKit
import SwiftUI

// A team is born in a project (docs/spec/21 D7, design 5b-2): Piopio offered one for work that divides; this sheet
// shows the team it read from the project, your agents where they fit, the checks it found and what the request might
// cost. "Start with this team" makes it (only in this project) and the same conversation carries on with its lead.

extension Notification.Name {
    /// One of Piopio's offers taken in a transcript (object: the session id; userInfo: kind, call).
    static let transcriptOffer = Notification.Name("piopio.transcriptOffer")
}

struct TeamOffer: Identifiable, Hashable {
    let id = UUID()
    let request: String
    let parts: Int
}

struct TeamForProjectSheet: View {
    let engine: EngineController
    let project: ProjectInfo
    let conversation: ContainerRef
    let offer: TeamOffer
    let done: () -> Void
    @State private var drafted: DraftFor?
    @State private var roles: [TeamRole] = []
    @State private var checks = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("A team for \(project.name)").font(.system(size: 16, weight: .semibold))
                if let found = drafted?.found {
                    Text("Read from the project: " + [found.language, found.checks.map { "tests with \($0)" }, found.git ? "git" : "no git"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                }
            }
            if drafted == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the project…").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                members
                HStack(spacing: 10) {
                    Text("Checks").font(.system(size: 13)).frame(width: 70, alignment: .leading)
                    TextField("", text: $checks, prompt: Text("None: a review is the only check"))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                }
                if let estimate { Text(estimate).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2) }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            HStack {
                if drafted?.found.language != nil {
                    Button("Use Development team instead") { start(template: true) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Start with this team") { start(template: false) }.keyboardShortcut(.defaultAction).disabled(busy || drafted == nil)
            }
        }
        .padding(20)
        .frame(width: 540)
        .disabled(busy)
        .task {
            do {
                let d = try await engine.draftTeam(for: project, request: offer.request)
                // Your agents where they fit, already swapped in; the picker can undo it.
                roles = d.draft.roles.map { r in
                    guard let s = d.suggestions.first(where: { $0.role == r.id }) else { return r }
                    var swapped = r
                    swapped.agent = s.agent
                    swapped.name = s.name
                    return swapped
                }
                checks = d.found.checks ?? ""
                drafted = d
            } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    private var members: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(roles.enumerated()), id: \.element.id) { i, role in
                HStack(spacing: 10) {
                    if role.kind == "integrate" {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(AgentHue.system).frame(width: 22, height: 22)
                            .overlay(Text("CI").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color(white: 0.08)))
                    } else {
                        SidebarAvatar(id: role.agent ?? "new/\(role.id)", name: role.name, size: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(role.name).font(.system(size: 13, weight: .medium))
                            if role.kind == "write" { Text("×3 at once").font(.system(size: 11)).foregroundStyle(Color.dsFg3) }
                            if role.agent != nil { Text("your agent").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.dsFg3) }
                        }
                        Text(JoinTeamSheet.verb(role.kind)).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    Spacer()
                    if role.kind == "review" || role.kind == "write" { who(i) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }

    /// A member who lives only in this team, or one of your agents (suggested ones first).
    private func who(_ i: Int) -> some View {
        let original = drafted?.draft.roles.first { $0.id == roles[i].id }
        let suggested = Set(drafted?.suggestions.filter { $0.role == roles[i].id }.map(\.agent) ?? [])
        let agents = engine.agents.filter { $0.agent?.draft != true }.sorted { suggested.contains($0.ref.id) && !suggested.contains($1.ref.id) }
        return Picker("", selection: Binding(get: { roles[i].agent ?? "" }, set: { id in
            if id.isEmpty {
                roles[i].agent = nil
                roles[i].name = original?.name ?? roles[i].name
            } else if let a = agents.first(where: { $0.ref.id == id }) {
                roles[i].agent = id
                roles[i].name = a.title
            }
        })) {
            Text("Only in this team").tag("")
            ForEach(agents, id: \.ref.id) { a in Text(suggested.contains(a.ref.id) ? "\(a.title) · suggested" : a.title).tag(a.ref.id) }
        }
        .labelsHidden().fixedSize()
    }

    /// "About $0.20–0.60 for this request", from the build model's prices and how many parts it has.
    private var estimate: String? {
        guard let model = engine.model(engine.model(for: .build)), model.pricing.input > 0 else { return nil }
        let tasks = Double(max(offer.parts, 2))
        // A task: the member's work, its review and the lead's share, in tokens (in, out).
        let perTask = (120_000 * model.pricing.input + 11_000 * model.pricing.output) / 1_000_000
        let low = perTask * tasks * 0.5, high = perTask * tasks * 1.5
        func money(_ v: Double) -> String { v < 0.01 ? "<$0.01" : String(format: "$%.2f", v) }
        return "About \(money(low))–\(money(high)) for this request, with \(model.name)."
    }

    private func start(template: Bool) {
        guard let drafted else { return }
        busy = true
        let command = checks.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                let team = template
                    ? try await engine.createTeam(name: "Development team", template: "development", cwd: project.path, goal: nil, testCommand: command.isEmpty ? nil : command)
                    : try await engine.createTeam(name: drafted.draft.name, template: "custom", cwd: project.path, goal: nil, testCommand: command.isEmpty ? nil : command, roles: roles, style: drafted.draft.style)
                try await engine.adopt(conversation, into: team)
                done()
            } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}
