import PiopioKit
import SwiftUI

/// Overview › Setup (docs/spec/34 §6): one map of what you have and where each piece runs. You and your devices and
/// channels on the left, where Piopio runs in the middle (This Mac, the cloud, with their agents inside), what it uses on
/// the right. A verdict on top ("2 need you · 9 working · 3 unused"); each node has Home's status tile (green working,
/// orange needs you, with its reason and Fix; none when unused, dashed). Hovering a node shows what it touches. Under it,
/// the same facts as a table: What runs where (§6.2). Docs/design/overview Redesign, option A.
struct OverviewSetupTab: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var setup: SetupResult?
    @State private var error: String?
    @State private var hovered: String?
    @State private var width: CGFloat = 760

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let setup {
                if setup.nodes.isEmpty {
                    Text("Nothing set up yet.").font(.system(size: 13)).foregroundStyle(Color.dsFg2).padding(.top, 20)
                } else {
                    verdict(setup).padding(.bottom, 18)
                    if width < 640 { stacked(setup) } else { map(setup) }
                }
                if !setup.rows.isEmpty {
                    OverviewSection("What runs where") { table(setup.rows) }
                }
            } else if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Color.dsFg2).padding(.top, 20)
            } else {
                ProgressView().controlSize(.small).padding(.top, 30).frame(maxWidth: .infinity)
            }
        }
        .background(GeometryReader { geo in Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { _, w in width = w } })
        .task { await load() }
    }

    // MARK: The verdict

    /// "● 2 need you · ● 9 working · 3 unused": the same counts the map draws, agents inside places included.
    private func verdict(_ s: SetupResult) -> some View {
        let states = s.nodes.map(\.state) + s.nodes.flatMap { ($0.agents ?? []).map(\.state) }
        let needs = states.filter { $0 == .needsYou }.count
        let working = states.filter { $0 == .ok }.count
        let unused = states.filter { $0 == .unused || $0 == .off }.count
        return HStack(spacing: 8) {
            if needs > 0 { pill("\(needs) need\(needs == 1 ? "s" : "") you", tone: .approval) }
            if working > 0 { pill("\(working) working", tone: .ready) }
            if unused > 0 {
                Text("\(unused) unused").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Color.dsTrack, in: Capsule())
                    .help("Not used in 30 days, or turned off: drawn dashed below.")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func pill(_ text: String, tone: StatusTone) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tone.dot).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(tone.dot)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(tone.tint, in: Capsule())
    }

    // MARK: The map

    private func map(_ s: SetupResult) -> some View {
        let lit = litIDs(s)
        return HStack(alignment: .top, spacing: 56) {
            ForEach([SetupNode.Column.you, .piopio, .uses], id: \.self) { column in
                VStack(alignment: .leading, spacing: 10) {
                    Text(Self.title(column)).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg3)
                    ForEach(s.nodes.filter { $0.column == column }) { node in
                        nodeView(node, lit: lit)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.vertical, 4)
        .overlayPreferenceValue(NodeFrames.self) { anchors in
            GeometryReader { geo in
                let frames = anchors.mapValues { geo[$0] }
                let needs = needsYouIDs(s)
                ForEach(Array(s.edges.enumerated()), id: \.offset) { _, edge in
                    if let a = frames[edge.from], let b = frames[edge.to] {
                        let on = hovered != nil && (lit?.contains(edge.from) ?? false) && (lit?.contains(edge.to) ?? false)
                        // A line to something that needs you is orange and dashed; the rest stay grey.
                        let warn = needs.contains(edge.from) || needs.contains(edge.to)
                        Self.curve(from: a, to: b)
                            .stroke(warn ? StatusTone.approval.dot : on ? Color.dsFg2 : Color.dsLine, style: StrokeStyle(lineWidth: warn ? 1.3 : 1, dash: warn ? [4, 4] : []))
                            .opacity(hovered == nil || on ? 1 : 0.4)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Narrow: the columns one under the other, without lines.
    private func stacked(_ s: SetupResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([SetupNode.Column.you, .piopio, .uses], id: \.self) { column in
                let nodes = s.nodes.filter { $0.column == column }
                if !nodes.isEmpty {
                    Text(Self.title(column)).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg3).padding(.top, 6)
                    ForEach(nodes) { node in nodeView(node, lit: nil) }
                }
            }
        }
    }

    /// Nodes and agents ("agent:<id>") that need you, for their lines.
    private func needsYouIDs(_ s: SetupResult) -> Set<String> {
        Set(s.nodes.filter { $0.state == .needsYou }.map(\.id) + s.nodes.flatMap { ($0.agents ?? []).filter { $0.state == .needsYou }.map { "agent:\($0.id)" } })
    }

    /// What the hovered node touches: itself, the nodes its edges reach, and (for a place) its agents and theirs.
    private func litIDs(_ s: SetupResult) -> Set<String>? {
        guard let hovered else { return nil }
        var ids: Set<String> = [hovered]
        if let place = s.nodes.first(where: { $0.id == hovered }) { ids.formUnion((place.agents ?? []).map { "agent:\($0.id)" }) }
        // An agent lights the place it lives in.
        if hovered.hasPrefix("agent:"), let place = s.nodes.first(where: { ($0.agents ?? []).contains { "agent:\($0.id)" == hovered } }) { ids.insert(place.id) }
        let seeds = ids
        for edge in s.edges where seeds.contains(edge.from) || seeds.contains(edge.to) {
            ids.insert(edge.from)
            ids.insert(edge.to)
        }
        return ids
    }

    /// A node: Home's status tile with its glyph (green working, orange needs you; none when unused or off), the name,
    /// and its line, or the reason in orange with Fix when it needs you. A place lists its agents as pills.
    private func nodeView(_ node: SetupNode, lit: Set<String>?) -> some View {
        let quiet = node.state == .unused || node.state == .off
        let needs = node.state == .needsYou
        let tone: StatusTone? = needs ? .approval : quiet ? nil : .ready
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: Self.glyph(node))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tone?.dot ?? Color.dsFg3)
                    .frame(width: 28, height: 28)
                    .background(tone?.tint ?? .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name).font(.system(size: 13, weight: .medium)).foregroundStyle(quiet ? Color.dsFg3 : Color.dsFg).lineLimit(1)
                    Text(needs ? (node.reason ?? node.line) : node.line)
                        .font(.system(size: 12)).foregroundStyle(needs ? StatusTone.approval.dot : Color.dsFg3)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if needs, node.open != nil {
                    Button("Fix") { open(node.open) }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                }
            }
            if let agents = node.agents, !agents.isEmpty {
                Flow(spacing: 5, lineSpacing: 5) {
                    ForEach(agents) { agent in agentPill(agent, lit: lit) }
                }
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(quiet ? Color.clear : Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(needs ? StatusTone.approval.dot : hovered == node.id ? Color.dsFg3 : Color.dsLine, style: StrokeStyle(lineWidth: needs ? 1 : (quiet ? 1 : 0.5), dash: quiet ? [3, 3] : []))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .anchorPreference(key: NodeFrames.self, value: .bounds) { [node.id: $0] }
        .opacity(lit.map { $0.contains(node.id) ? 1 : 0.4 } ?? (quiet ? 0.8 : 1))
        .onHover { hovered = $0 ? node.id : (hovered == node.id ? nil : hovered) }
        .onTapGesture { open(node.open) }
        .help(node.reason ?? "")
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// An agent inside a place: a small pill (its avatar and name); orange when it needs you.
    private func agentPill(_ agent: SetupNode.Agent, lit: Set<String>?) -> some View {
        let id = "agent:\(agent.id)"
        let quiet = agent.state == .unused || agent.state == .off
        let needs = agent.state == .needsYou
        return Button { open(.init(kind: "agent", id: agent.id, pane: nil)) } label: {
            HStack(spacing: 5) {
                if let avatar = agent.avatar, !avatar.isEmpty { Text(avatar).font(.system(size: 11)) }
                if needs { Circle().fill(StatusTone.approval.dot).frame(width: 6, height: 6) }
                Text(agent.name).font(.system(size: 12)).foregroundStyle(needs ? StatusTone.approval.dot : quiet ? Color.dsFg3 : Color.dsFg).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(needs ? StatusTone.approval.tint : hovered == id ? Color.dsFg3.opacity(0.25) : Color.dsTrack, in: Capsule())
            .overlay(Capsule().strokeBorder(quiet ? Color.dsLine : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: NodeFrames.self, value: .bounds) { [id: $0] }
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .help(agent.reason ?? agent.name)
    }

    /// A gentle S from the side of one box to the facing side of the other.
    static func curve(from a: CGRect, to b: CGRect) -> Path {
        let forward = a.midX <= b.midX
        let start = CGPoint(x: forward ? a.maxX : a.minX, y: a.midY)
        let end = CGPoint(x: forward ? b.minX : b.maxX, y: b.midY)
        let bend = max(abs(end.x - start.x) * 0.5, 24)
        var p = Path()
        p.move(to: start)
        p.addCurve(to: end, control1: CGPoint(x: start.x + (forward ? bend : -bend), y: start.y), control2: CGPoint(x: end.x - (forward ? bend : -bend), y: end.y))
        return p
    }

    // MARK: What runs where (§6.2)

    private func table(_ rows: [SetupResult.Row]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
            GridRow {
                ForEach(["Name", "Runs on", "Model", "Reaches you in", "Next run", "This month"], id: \.self) { title in
                    Text(title).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                        .gridColumnAlignment(title == "This month" ? .trailing : .leading)
                }
            }
            .padding(.bottom, 6)
            ForEach(rows, id: \.self) { row in
                let quiet = row.paused == true
                GridRow {
                    HStack(spacing: 6) {
                        Image(systemName: row.kind == "agent" ? "bird" : "clock.arrow.circlepath").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                        Text(row.name).lineLimit(1)
                        if quiet { Text("paused").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                    }
                    Text(row.runsOn == "cloud" ? "Cloud" : "This Mac")
                    Text(row.model.map(Self.modelName) ?? "—").lineLimit(1)
                    Text(row.reachesYouIn).lineLimit(1)
                    Text(row.nextRun.flatMap(OverviewPage.date).map(Self.when) ?? "—").lineLimit(1)
                    Text(MainSidebar.money(row.monthUsd)).monospacedDigit()
                }
                .font(.system(size: 13))
                .foregroundStyle(quiet ? Color.dsFg3 : Color.dsFg)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .onTapGesture { open(.init(kind: row.kind, id: row.id, pane: nil)) }
                Divider().overlay(Color.dsLine).gridCellUnsizedAxes(.horizontal)
            }
        }
    }

    // MARK: Opening

    private func open(_ target: SetupNode.Open?) {
        guard let target else { return }
        switch target.kind {
        case "agent": if let id = target.id { item = engine.item(for: id) ?? .agent(id) }
        case "automation": if let id = target.id { item = .automation(id) }
        case "project": if let id = target.id { item = .project(id) }
        case "settings": ToolChoices.openSettings(Self.settingsSection(target.pane))
        default: break
        }
    }

    /// The engine's pane names, as Settings' sections.
    static func settingsSection(_ pane: String?) -> String {
        switch pane {
        case "connectors": "Connectors"
        case "mcp": "MCP servers"
        case "memory": "Memory"
        case "cloud", "engines", "mac": "This Mac & cloud"
        case "browser": "Browser"
        case "extensions", "skills": "Extensions"
        case "approvals": "Approvals"
        default: "Models"
        }
    }

    private func load() async {
        guard let client = engine.client else { error = "Connect to the engine to see your setup."; return }
        do {
            setup = try await client.call("stats.setup", Empty(), as: SetupResult.self)
            error = nil
        } catch {
            if setup == nil { self.error = error.localizedDescription }
        }
    }

    // MARK: Words and glyphs

    static func title(_ c: SetupNode.Column) -> String {
        switch c {
        case .you: "You"
        case .piopio: "Piopio"
        case .uses: "Uses"
        }
    }

    static func glyph(_ n: SetupNode) -> String {
        switch n.kind {
        case .device: n.name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "laptopcomputer"
        case .channel: "paperplane"
        case .place: n.id.contains("cloud") || n.name.localizedCaseInsensitiveContains("cloud") || n.name.localizedCaseInsensitiveContains("server") ? "cloud" : "desktopcomputer"
        case .provider: "sparkles"
        case .codingAgent: "chevron.left.forwardslash.chevron.right"
        case .connector: "app.connected.to.app.below.fill"
        case .mcp: "puzzlepiece.extension"
        case .memory: "brain.head.profile"
        }
    }

    /// "openrouter/anthropic/claude-sonnet-5.5" → "claude-sonnet-5.5".
    static func modelName(_ model: String) -> String { model.split(separator: "/").last.map(String.init) ?? model }

    static func when(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened)
            : Calendar.current.isDateInTomorrow(d) ? "tomorrow \(d.formatted(date: .omitted, time: .shortened))"
            : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

/// Where each node (and each agent inside a place) is, for the lines between them.
private struct NodeFrames: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
