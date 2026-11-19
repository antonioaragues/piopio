import PiopioKit
import PiopioTranscript
import SwiftUI

// Agents, keeping the sidebar (docs/design/automations, the agents and automations handoff, screen 1): the sidebar's
// Agents row opens your agents as a second column, and the agent's page fills the rest. The sidebar never changes.

/// The list column (264) beside an agent's page, or beside the new agent page.
struct AgentsSplit<Page: View>: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    /// The agent whose page shows; nil on the new agent page.
    let selected: String?
    @ViewBuilder var page: Page

    /// The column on the window beside the sidebar, the page in the content card (docs/design/card-layout).
    var body: some View {
        HStack(spacing: 0) {
            AgentsColumn(engine: engine, item: $item, selected: selected)
                .frame(width: 264)
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentCard()
        }
        .ownsContentCard()
    }
}

/// "Agents" and its +, a search field, and a row per agent: its tile, name, when you last talked, and the last line
/// of your chat with it (or what it's doing now).
struct AgentsColumn: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    let selected: String?
    @State private var query = ""
    /// The last line of your chat with each agent, and when (agents.conversations' owner row).
    @State private var previews: [String: (text: String, at: String?)] = [:]
    @Environment(\.sidebarControl) private var control

    private var agents: [SessionSummary] {
        let all = engine.agents.sorted { (previews[$0.ref.id]?.at ?? $0.updatedAt) > (previews[$1.ref.id]?.at ?? $1.updatedAt) }
        return query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) || ($0.agent?.description ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agents").font(.system(size: 20, weight: .bold)).tracking(-0.4).foregroundStyle(Color.dsFg)
                Spacer()
                Button { NotificationCenter.default.post(name: .newAgent, object: nil) } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsInvFg)
                        .frame(width: 28, height: 28)
                        .background(Color.dsInv, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New agent")
                .accessibilityLabel("New agent")
            }
            .padding(.leading, control.collapsed ? (control.fullScreen ? 48 : Shell.collapsedLeading) : 16)
            .padding(.trailing, 16)
            .padding(.top, 22).padding(.bottom, 12)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                TextField("", text: $query, prompt: Text("Search agents").foregroundStyle(Color.dsFg3))
                    .textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
            .padding(.horizontal, 12).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(agents, id: \.ref.id) { row($0) }
                    if agents.isEmpty, !query.isEmpty {
                        Text("No agent matches.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).padding(.top, 12)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: engine.agents.map(\.updatedAt)) { await loadPreviews() }
    }

    private func loadPreviews() async {
        for agent in engine.agents {
            let people = await engine.agentPeople(agent.ref)
            if let owner = people.first(where: { $0.role == "owner" }), let text = owner.preview, !text.isEmpty {
                previews[agent.ref.id] = (text, owner.lastAt)
            }
        }
    }

    private func row(_ a: SessionSummary) -> some View {
        let isSelected = a.ref.id == selected
        return AgentColumnRow(selected: isSelected) {
            item = .agent(a.ref.id)
        } content: {
            HStack(alignment: .center, spacing: 11) {
                if a.agent?.draft == true {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.dsFg3, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 40, height: 40)
                } else {
                    AgentTile(id: a.ref.id, name: a.title, glyph: a.agent?.avatar, size: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(a.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                        // In your cloud (docs/spec/30 §7): a glyph, not a chip.
                        if a.agent?.location == "cloud" { Image(systemName: "cloud").font(.system(size: 10.5)).foregroundStyle(Color.dsFg2).help("In your cloud: keeps going with your Mac off") }
                        Spacer(minLength: 4)
                        Text(Self.time(previews[a.ref.id]?.at ?? a.updatedAt)).font(.system(size: 11)).foregroundStyle(Color.dsFg3).monospacedDigit()
                    }
                    HStack(spacing: 5) {
                        if engine.liveStatus[a.ref.key] == .running { SidebarDot(status: .running) }
                        else if (a.agent?.status?.inbox ?? 0) > 0 { SidebarDot(status: .waiting) }
                        Text(line(a)).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(1)
                    }
                }
            }
        }
        .contextMenu {
            Button("Reveal Definition in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.agent?.folder ?? "")]) }
            Divider()
            Button("Delete Agent…", role: .destructive) { delete(a) }
        }
    }

    /// What it's doing now, else the last line of your chat, else what it's for.
    private func line(_ a: SessionSummary) -> String {
        if engine.liveStatus[a.ref.key] == .running { return "Working…" }
        if a.agent?.draft == true { return "Learning its job" }
        if a.agent?.status?.paused == true { return "Paused" }
        if let text = previews[a.ref.id]?.text { return text.replacingOccurrences(of: "\n", with: " ") }
        return a.agent?.description ?? ""
    }

    /// "08:00" today, "Thu" this week, "12 Nov" before.
    static func time(_ iso: String) -> String {
        guard let d = ISODate.parse(iso) else { return "" }
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        if Date().timeIntervalSince(d) < 6 * 86_400 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    private func delete(_ a: SessionSummary) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(a.title)”?"
        alert.informativeText = "Its conversations and memory are deleted. Its definition folder goes to the Trash. Its automations stop."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if a.ref.id == selected { item = .index(.agents) }
        Task { await engine.delete(a.ref) }
    }
}

/// A row of the column: radius 11, the selected grey (#EAEAE6), a lighter one under the pointer.
private struct AgentColumnRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(selected ? Color.dsChip : hovering ? Color.dsChip.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
