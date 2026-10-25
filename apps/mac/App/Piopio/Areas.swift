import PiopioKit
import PiopioTranscript
import SwiftUI

/// The areas that are on (docs/spec/15-onboarding-and-areas), kept in `UserDefaults` "areas". The sidebar, Home,
/// menus, the palette and Quick Chat read this; hiding an area stops and deletes nothing.
@MainActor @Observable final class Areas {
    static let shared = Areas()

    private(set) var set: AreaSet

    private init() {
        // PIOPIO_DEMO_AREAS=chat starts with some areas (captures).
        let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_AREAS"]
        set = AreaSet(stored: demo ?? UserDefaults.standard.string(forKey: "areas"))
    }

    func contains(_ area: Area) -> Bool { set.contains(area) }

    func set(_ area: Area, on: Bool) {
        var next = set
        guard next.set(area, on: on) else { return }
        replace(next)
    }

    func replace(_ next: AreaSet) {
        set = next
        UserDefaults.standard.set(next.stored, forKey: "areas")
        QuickChatController.shared?.applyShortcut()
    }

    // MARK: First run

    /// The welcome was finished or skipped (or this Mac used Piopio before areas existed).
    static var welcomeDone: Bool {
        get { UserDefaults.standard.integer(forKey: "welcomeVersion") >= 1 }
        set { UserDefaults.standard.set(newValue ? 1 : 0, forKey: "welcomeVersion") }
    }

    /// Home's one-time tip for people who used Piopio before areas existed.
    var showsTip: Bool = UserDefaults.standard.bool(forKey: "areasTip") {
        didSet { UserDefaults.standard.set(showsTip, forKey: "areasTip") }
    }
}

extension Area {
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .build: "chevron.left.forwardslash.chevron.right"
        case .chat: "bubble.left.and.bubble.right.fill"
        case .agents: "bird.fill"
        }
    }

    var tint: Color {
        switch self {
        case .build: Color(red: 0.24, green: 0.45, blue: 0.96)
        case .chat: Color(red: 0.10, green: 0.66, blue: 0.62)
        case .agents: Color(red: 0.96, green: 0.58, blue: 0.16)
        }
    }

    /// One line for the welcome's cards and the Settings rows.
    var blurb: String {
        switch self {
        case .build: "Work in your code: sessions in your project folders, with diffs, git and a terminal."
        case .chat: "Ask, draft and think things through. Notebooks keep personal projects together, with their files."
        case .agents: "Small assistants that keep going while you're away: briefings, reminders, messages."
        }
    }

    /// Where an item lives, for the "is hidden" bar.
    @MainActor init?(item: SidebarItem, engine: EngineController) {
        switch item {
        case .session(let id):
            guard let s = engine.buildSessions.first(where: { $0.ref.id == id }) else { return nil }
            self = s.profile == .chat ? .chat : .build
        case .chat, .notebook: self = .chat
        case .agent: self = .agents
        case .index(.agents): self = .agents
        case .index(.chats), .index(.notebooks): self = .chat
        case .index(.projects), .project: self = .build
        default: return nil
        }
    }
}

/// The area's tile: its symbol in white on its color (welcome cards, Settings rows).
struct AreaTile: View {
    let area: Area
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(area.tint.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: area.symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
    }
}

/// A thin bar over an item whose area is hidden (opened from a notification, a link or an automation).
struct HiddenAreaBar: View {
    let area: Area

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            Text("\(area.title) is hidden").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsFg2)
            Spacer()
            Button("Show it in the sidebar") { withAnimation(.easeOut(duration: 0.2)) { Areas.shared.set(area, on: true) } }
                .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14).frame(height: 32)
        .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 16).padding(.top, 10)
    }
}

// MARK: Settings › General › Areas

/// One row per area with a switch and what it holds; the last area that's on can't be turned off. Turning Agents
/// off while agents run asks whether to keep them running (the default) or pause them.
struct AreasCard: View {
    let engine: EngineController
    var rerunSetup: () -> Void
    @State private var confirmingAgents = false
    private var areas: Areas { Areas.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Areas").font(.system(size: 13, weight: .semibold))
                Text("What Piopio is for you. Hiding an area keeps everything in it, and nothing that runs stops.")
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            ListCard {
                ForEach(Area.allCases) { area in
                    row(area, last: area == Area.allCases.last)
                }
            }
            Button("Run setup again…", action: rerunSetup)
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                .padding(.top, 2)
        }
        .padding(.bottom, 22)
        .sheet(isPresented: $confirmingAgents) {
            AgentsOffSheet(engine: engine, running: runningAgents) { confirmingAgents = false }
        }
    }

    private func row(_ area: Area, last: Bool) -> some View {
        let on = areas.contains(area)
        let locked = on && !areas.set.canTurnOff(area)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                AreaTile(area: area, size: 28).saturation(on ? 1 : 0).opacity(on ? 1 : 0.55)
                VStack(alignment: .leading, spacing: 2) {
                    Text(area.title).font(.system(size: 13, weight: .semibold))
                    Text(holds(area)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                if let note = note(area, on: on, locked: locked) {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).multilineTextAlignment(.trailing)
                }
                Toggle("", isOn: Binding(get: { on }, set: { value in toggle(area, value) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(locked)
                    .help(locked ? "At least one area stays on" : on ? "Hide \(area.title)" : "Show \(area.title)")
            }
            .padding(.horizontal, 14).frame(minHeight: 54)
            if !last { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 54) }
        }
    }

    private func toggle(_ area: Area, _ on: Bool) {
        if area == .agents, !on, !runningAgents.isEmpty {
            confirmingAgents = true
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { areas.set(area, on: on) }
    }

    /// Agents that do things on their own: not paused, with a schedule or a next run.
    private var runningAgents: [SessionSummary] {
        engine.agents.filter { $0.agent?.status?.paused != true && $0.agent?.status?.nextRun != nil }
    }

    private func note(_ area: Area, on: Bool, locked: Bool) -> String? {
        if locked { return "Always one on" }
        guard on, area == .build else { return nil }
        let working = engine.buildSessions.filter { $0.profile != .chat && engine.liveStatus[$0.ref.id] == .running }.count
        return working == 0 ? nil : "\(working) session\(working == 1 ? " is" : "s are") working;\nhiding lets \(working == 1 ? "it" : "them") finish"
    }

    private func holds(_ area: Area) -> String {
        func n(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
        switch area {
        case .build:
            let sessions = engine.buildSessions.filter { $0.profile != .chat && $0.parent == nil }.count
            return "\(n(engine.projects(in: .build).count, "project")) · \(n(sessions, "session"))"
        case .chat:
            return "\(n(engine.threads.count, "chat")) · \(n(engine.spaces.count, "notebook"))"
        case .agents:
            let scheduled = engine.agents.filter { $0.agent?.status?.nextRun != nil }.count
            return "\(n(engine.agents.count, "agent"))" + (scheduled > 0 ? " · \(scheduled) scheduled" : "")
        }
    }
}

/// Turning Agents off while agents run: keep them running (the default) or pause them.
struct AgentsOffSheet: View {
    let engine: EngineController
    let running: [SessionSummary]
    let done: () -> Void
    @State private var pausing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AreaTile(area: .agents, size: 36)
                Text("Hide Agents?").font(.system(size: 17, weight: .bold))
            }
            Text("\(running.count == 1 ? "1 agent runs" : "\(running.count) agents run") on a schedule. Hidden agents keep working: what they need from you still shows in Needs you and as notifications.")
                .font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(running.prefix(4).enumerated()), id: \.element.ref.id) { i, agent in
                    if i > 0 { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 44) }
                    HStack(spacing: 10) {
                        AgentAvatar(summary: agent, size: 22)
                        Text(agent.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(MainSidebar.when(agent.agent?.status?.nextRun ?? "").capitalizedFirst).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                }
            }
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
            HStack {
                Button("Cancel", action: done).buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button(pausing ? "Pausing…" : "Pause them and hide") { pauseAndHide() }.buttonStyle(PillStyle()).disabled(pausing)
                Button("Keep running and hide") {
                    Areas.shared.set(.agents, on: false)
                    done()
                }
                .buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 480)
    }

    private func pauseAndHide() {
        pausing = true
        Task {
            for agent in running { try? await engine.pause(agent.ref, paused: true) }
            Areas.shared.set(.agents, on: false)
            done()
        }
    }
}

extension AreaSet {
    /// Whether the sidebar, Home and the palette show an item.
    @MainActor func shows(_ item: SidebarItem, engine: EngineController) -> Bool {
        switch item {
        case .home, .needsYou: true
        case .index(let section): shows(section)
        case .project: showsProjects
        case .session(let id): engine.buildSessions.first { $0.ref.id == id }.map { showsSession(chatProfile: $0.profile == .chat) } ?? showsProjects
        case .notebook: showsNotebooks
        case .chat: showsChats
        case .agent: showsAgents
        }
    }

    func shows(_ section: SidebarSection) -> Bool {
        switch section {
        case .pinned: true
        case .projects: showsProjects
        case .notebooks: showsNotebooks
        case .agents: showsAgents
        case .chats: showsChats
        }
    }

    /// A session or chat by its summary (Home's cards).
    func shows(_ summary: SessionSummary) -> Bool {
        switch summary.ref.kind {
        case .build: showsSession(chatProfile: summary.profile == .chat)
        case .space: showsNotebooks
        case .agent: showsAgents
        default: showsChats
        }
    }
}
