import PiopioKit
import PiopioTranscript
import SwiftUI

// Making an agent by talking (docs/spec/21 D4, design 5a): answers to tap while it learns its job, the card it shows
// when it "comes alive", and a trial run. And an agent joining a team (design 5d).

/// Answers to tap, above the composer: a new agent's three ideas, or the options of the question it just asked.
/// They go once you answer (by tapping or in your own words).
struct AgentQuickReplies: View {
    let thread: ThreadModel

    var body: some View {
        _ = thread.revision
        let options = Self.options(thread.document.items)
        return Group {
            if !options.isEmpty, !thread.isRunning {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(options, id: \.self) { option in
                            Button(option) { Task { await thread.send(option) } }
                                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.dsFg)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Color.dsCard, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxWidth: 680)
            }
        }
    }

    /// The newest question's options (`ask_owner`) or the greeting's ideas, unless you've answered since.
    static func options(_ items: [TimelineItem]) -> [String] {
        for item in items.reversed() {
            switch item {
            case .user: return []
            case .tool(let t) where t.tool == "ask_owner":
                guard case .array(let list)? = t.args?["options"] else { return [] }
                return list.compactMap(\.stringValue)
            case .assistant(let a):
                if let s = a.outbound?.suggestions, !s.isEmpty { return s }
            default: continue
            }
        }
        return []
    }

    /// "Question 2 of 3", while it's asking.
    static func question(_ items: [TimelineItem]) -> String? {
        for item in items.reversed() {
            switch item {
            case .user: return nil
            case .tool(let t) where t.tool == "ask_owner":
                if case .number(let n)? = t.args?["number"] { return "Question \(Int(n)) of 3" }
                return nil
            default: continue
            }
        }
        return nil
    }
}

/// The card a new agent shows once it has set itself up (design 5a-3): who it is and what was decided, with what
/// needs your OK marked. "Looks good" closes it and offers nothing more to do than watch a trial run.
struct AgentIdentityCard: View {
    let engine: EngineController
    let summary: SessionSummary
    let def: AgentDef
    let runs: AgentRunsResult?
    let rename: () -> Void
    let looksGood: () -> Void
    let change: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SidebarAvatar(id: summary.ref.id, name: def.name, glyph: def.avatar, size: 44)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(AgentHue.color(summary.ref.id).opacity(0.18)).padding(-6))
                VStack(alignment: .leading, spacing: 2) {
                    Text("I'm \(def.name)").font(.system(size: 17, weight: .semibold))
                    Button("Rename · change icon", action: rename).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                row("Does") { Text(def.description ?? "What you told me").foregroundStyle(Color.dsFg) }
                row("When") { Text(when).foregroundStyle(Color.dsFg) }
                row("Uses") {
                    (Text(uses.allowed.isEmpty && uses.asks.isEmpty ? "Only talking" : uses.allowed.joined(separator: " · ")).foregroundStyle(Color.dsFg)
                        + Text(uses.asks.isEmpty ? "" : "\(uses.allowed.isEmpty ? "" : " · ")\(uses.asks.joined(separator: " · "))").foregroundStyle(Color.dsFg)
                        + Text(uses.asks.isEmpty ? "" : "  needs your OK").foregroundStyle(Color.dsAmber))
                }
                row("Reaches") { Text(def.channels?["telegram"] != nil ? "You, here in Piopio and on Telegram" : "You, here in Piopio").foregroundStyle(Color.dsFg) }
            }
            HStack(spacing: 10) {
                Button("Looks good", action: looksGood).buttonStyle(PillStyle(kind: .primary))
                    .help("It runs once now, so you see how it looks")
                Button("Change something", action: change).buttonStyle(PillStyle())
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: 680, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.dsFg3).frame(width: 64, alignment: .leading)
            value().font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Weekdays at 8:00", "When an email from the bank arrives", "Only when you ask".
    private var when: String {
        var parts = (def.schedules ?? []).map { CronText.describe($0.cron) }
        // A routine it set itself: its time in words when it repeats, else what it waits for.
        parts += (runs?.upcoming ?? []).filter { $0.kind == "watch" || $0.kind == "reminder" }.map { u in u.cron.map(CronText.describe) ?? (u.label.components(separatedBy: " · ").first ?? u.label) }
        return parts.isEmpty ? "Only when you ask" : parts.prefix(3).joined(separator: "; ")
    }

    /// What it may use on its own, and what asks you first.
    private var uses: (allowed: [String], asks: [String]) {
        let rules = def.policies?.requireApproval ?? []
        func asks(_ names: [String]) -> Bool { rules.contains { r in r == "*" || names.contains { r == $0 || r.hasPrefix($0 + ":") || r.hasPrefix($0) } } }
        var allowed: [String] = [], asking: [String] = []
        let tools = Set(def.tools.builtin)
        func add(_ title: String, _ names: [String]) { if asks(names) { asking.append(title) } else { allowed.append(title) } }
        if tools.contains("web_search") || tools.contains("web_fetch") { add("Web", ["web_search", "web_fetch"]) }
        if tools.contains("memory") { add("Memory", ["memory"]) }
        if tools.contains("send_message") { add("Messages", ["send_message"]) }
        for app in def.tools.apple ?? [] { add(app.capitalized, ["apple_\(app)_"]) }
        return (allowed, asking)
    }
}

/// An agent joins a team (design 5d-1): which team, as what, and what changes for it there.
struct JoinTeamSheet: View {
    let engine: EngineController
    let agent: SessionSummary
    let done: () -> Void
    @State private var teamId = ""
    /// A member's role id to take over, or "" for a new member who does tasks.
    @State private var roleId = ""
    @State private var error: String?
    @State private var busy = false

    private var teams: [TeamDefinition] { engine.teamDefinitions }
    private var team: TeamDefinition? { teams.first { $0.id == teamId } }
    private var replaceable: [TeamRole] { (team?.roles ?? []).filter { $0.kind != "integrate" && $0.agent != agent.ref.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SidebarAvatar(id: agent.ref.id, name: agent.title, glyph: agent.agent?.avatar, size: 22)
                Text("\(agent.title) joins a team").font(.system(size: 15, weight: .semibold))
            }
            if teams.isEmpty {
                Text("You have no teams yet. Make one from Agents › +, or give a project a team in its Settings.")
                    .font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Team", selection: $teamId) {
                    ForEach(teams) { t in Text(t.saved ? t.name : "\(t.name) (only in \(URL(fileURLWithPath: t.projects.first?.cwd ?? "").lastPathComponent))").tag(t.id) }
                }
                Picker("As", selection: $roleId) {
                    ForEach(replaceable) { r in Text("\(Self.verb(r.kind)) · replaces \(r.name)").tag(r.id) }
                    Text("A new member who does tasks").tag("")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("In the team it…").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsFg2)
                    bullet("Keeps its instructions, plus the team's TEAM.md")
                    bullet("Uses its own model, unless you give the member another")
                    bullet("Writes what it learns to the team's notes, not its memory")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.dsChip.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                if !teams.isEmpty { Button("Join", action: join).keyboardShortcut(.defaultAction).disabled(busy || team == nil) }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            await engine.loadTeams()
            if teamId.isEmpty { teamId = teams.first?.id ?? "" }
        }
        .onChange(of: teamId) { _, _ in roleId = replaceable.first { $0.kind == "review" }?.id ?? "" }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("·").foregroundStyle(Color.dsFg3)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func verb(_ kind: String) -> String {
        switch kind {
        case "lead": "Plans and assigns"
        case "write": "Does tasks"
        case "review": "Reviews every task"
        default: "Merges"
        }
    }

    private func join() {
        guard let team else { return }
        var roles = team.roles
        if let i = roles.firstIndex(where: { $0.id == roleId }) {
            roles[i].agent = agent.ref.id
        } else {
            roles.append(TeamRole(name: agent.title, kind: "write", responsibility: agent.agent?.description ?? "You do the tasks you're given, as \(agent.title).", agent: agent.ref.id))
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await engine.updateTeamDefinition(team, roles: roles)
                done()
            } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}
