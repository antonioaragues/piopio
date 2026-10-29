import PiopioKit
import PiopioTranscript
import SwiftUI

/// The Projects index (docs/design v2, 0b): every project and session, filterable, with what needs you.
struct ProjectsIndex: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    /// The project the sidebar opened it at (expanded and highlighted).
    var focus: String?
    @State private var filter = ""
    @AppStorage("projectsScope") private var scope: Scope = .active
    @AppStorage("projectsSort") private var sort: Sort = .recent
    @State private var expanded: Set<String> = []
    @State private var showingEarlier: Set<String> = []

    enum Scope: String, CaseIterable { case active = "Active", all = "All", archived = "Archived" }
    enum Sort: String, CaseIterable { case recent = "Recent", name = "Name" }

    private static let archiveAfter: TimeInterval = 30 * 86_400
    private static let liveWindow: TimeInterval = 3 * 86_400

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Projects").font(.system(size: 26, weight: .bold)).tracking(-0.5)
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                        Text("Folders on your Mac, with sessions for working in code or chatting about their files.").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                    }
                    Spacer()
                    Button("Open Folder… ⌘O") { BuildActions.addProject(engine: engine) { item = .session($0) } }
                        .buttonStyle(PillStyle(kind: .strong))
                }
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                        TextField("Filter projects and sessions", text: $filter).textFieldStyle(.plain).font(.system(size: 13))
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                    Picker("", selection: $scope) { ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Menu {
                        Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    } label: { Text(sort.rawValue) }
                        .menuStyle(.button).buttonStyle(ChipStyle()).fixedSize()
                }
                .padding(.top, 20)
                table.padding(.top, 14)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .onAppear { if let focus { expanded.insert(focus) } }
        .onChange(of: focus) { _, f in if let f { expanded.insert(f) } }
    }

    private var subtitle: String {
        let sessions = engine.buildSessions.filter { $0.parent == nil }
        let waiting = sessions.filter { engine.liveStatus[$0.ref.id] == .waitingApproval }.count
        var parts = ["\(engine.projects.count) project\(engine.projects.count == 1 ? "" : "s")", "\(sessions.count) session\(sessions.count == 1 ? "" : "s")"]
        if waiting > 0 { parts.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        return parts.joined(separator: " · ")
    }

    private func sessions(_ p: ProjectInfo) -> [SessionSummary] {
        let all = engine.sessions(in: p).filter { $0.parent == nil }
        let now = Date()
        let scoped = all.filter { s in
            let age = now.timeIntervalSince(MainSidebar.date(s.updatedAt))
            switch scope {
            case .active: return age < Self.archiveAfter || engine.liveStatus[s.ref.id] == .running || engine.liveStatus[s.ref.id] == .waitingApproval
            case .archived: return age >= Self.archiveAfter
            case .all: return true
            }
        }
        guard !filter.isEmpty else { return scoped }
        return scoped.filter { $0.title.localizedCaseInsensitiveContains(filter) || p.name.localizedCaseInsensitiveContains(filter) }
    }

    private var projects: [ProjectInfo] {
        let list = engine.projects.filter { p in
            filter.isEmpty || p.name.localizedCaseInsensitiveContains(filter) || !sessions(p).isEmpty
        }.filter { scope != .archived || !sessions($0).isEmpty }
        switch sort {
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent: return list.sorted { latest($0) > latest($1) }
        }
    }

    private func latest(_ p: ProjectInfo) -> String { engine.sessions(in: p).map(\.updatedAt).max() ?? p.addedAt }

    private var table: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Branch").frame(width: 150, alignment: .leading)
                Text("Updated").frame(width: 120, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
            .padding(.horizontal, 16).frame(height: 32)
            ForEach(projects) { p in
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                projectRow(p)
                if expanded.contains(p.id) { sessionRows(p) }
            }
            if projects.isEmpty {
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                Text(engine.projects.isEmpty ? "No projects yet. Open a folder to start." : "Nothing matches.")
                    .font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity).frame(height: 60)
            }
        }
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }

    private func projectRow(_ p: ProjectInfo) -> some View {
        let open = expanded.contains(p.id)
        let count = engine.sessions(in: p).filter { $0.parent == nil }.count
        return Button {
            if open { expanded.remove(p.id) } else { expanded.insert(p.id) }
        } label: {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.dsFg3)
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                    InitialTile(name: p.name)
                    Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
                    Text("\(count) session\(count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(p.branch ?? "no git").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg2).frame(width: 150, alignment: .leading)
                Text(BuildSessionView.relative(latest(p))).font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 120, alignment: .leading)
            }
            .padding(.horizontal, 16).frame(height: 38)
            .background(focus == p.id ? Color.dsAccentSoft : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("New Session…") { NotificationCenter.default.post(name: .newBuildSession, object: p.id) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
        }
    }

    @ViewBuilder private func sessionRows(_ p: ProjectInfo) -> some View {
        let list = sessions(p).sorted { $0.updatedAt > $1.updatedAt }
        let now = Date()
        let recent = list.filter { now.timeIntervalSince(MainSidebar.date($0.updatedAt)) < Self.liveWindow || engine.liveStatus[$0.ref.id] != nil && engine.liveStatus[$0.ref.id] != .idle }
        let earlier = list.filter { s in !recent.contains { $0.ref.id == s.ref.id } }
        let showAll = showingEarlier.contains(p.id) || !filter.isEmpty || scope == .archived
        ForEach(showAll ? list : recent, id: \.ref.id) { s in sessionRow(s, project: p) }
        if !showAll, !earlier.isEmpty {
            Button("Show \(earlier.count) earlier session\(earlier.count == 1 ? "" : "s")") { showingEarlier.insert(p.id) }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                .padding(.leading, 58).frame(maxWidth: .infinity, alignment: .leading).frame(height: 30)
        }
        if list.isEmpty {
            Button("Start a session in \(p.name)…") { NotificationCenter.default.post(name: .newBuildSession, object: p.id) }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                .padding(.leading, 58).frame(maxWidth: .infinity, alignment: .leading).frame(height: 30)
        }
    }

    private func sessionRow(_ s: SessionSummary, project p: ProjectInfo) -> some View {
        let status = engine.liveStatus[s.ref.id]
        return Button { item = .session(s.ref.id) } label: {
            HStack {
                HStack(spacing: 8) {
                    SidebarDot(status: status == .running ? .running : status == .waitingApproval ? .waiting : status == .error ? .failed : .done)
                    Text(s.title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                }
                .padding(.leading, 42)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(s.worktree?.branch ?? p.branch ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg2).frame(width: 150, alignment: .leading)
                Group {
                    switch status {
                    case .waitingApproval?: Text("Needs you").foregroundStyle(Color.dsAmber)
                    case .running?: Text("Running").foregroundStyle(Color.dsFg2)
                    default: Text(BuildSessionView.relative(s.updatedAt)).foregroundStyle(Color.dsFg2)
                    }
                }
                .font(.system(size: 12)).frame(width: 120, alignment: .leading)
            }
            .padding(.horizontal, 16).frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The full list of notebooks, agents or chats ("N more ›").
struct SectionIndex: View {
    let engine: EngineController
    let section: SidebarSection
    @Binding var item: SidebarItem
    @State private var filter = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title).font(.system(size: 26, weight: .bold)).tracking(-0.5)
                        Text("\(rows.count) \(section.title.lowercased())").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                    }
                    Spacer()
                    Button(newTitle) { NotificationCenter.default.post(name: newName, object: nil) }.buttonStyle(PillStyle(kind: .strong))
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                    TextField("Filter", text: $filter).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                .padding(.top, 20)
                VStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.ref.id) { i, s in
                        if i > 0 { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
                        row(s)
                    }
                    if filtered.isEmpty {
                        Text("Nothing here.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity).frame(height: 60)
                    }
                }
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
                .padding(.top, 14)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
    }

    private var rows: [SessionSummary] {
        switch section {
        case .notebooks: engine.spaces
        case .agents: engine.agents
        default: engine.threads
        }
    }

    private var filtered: [SessionSummary] { filter.isEmpty ? rows : rows.filter { $0.title.localizedCaseInsensitiveContains(filter) } }

    private var newTitle: String {
        switch section {
        case .notebooks: "New Notebook ⌘⇧N"
        case .agents: "New Agent"
        default: "New Chat ⌘N"
        }
    }

    private var newName: Notification.Name {
        switch section {
        case .notebooks: .newSpace
        case .agents: .newAgent
        default: .newChat
        }
    }

    private func row(_ s: SessionSummary) -> some View {
        Button {
            switch section {
            case .notebooks: item = .notebook(s.ref.id)
            case .agents: item = .agent(s.ref.id)
            default: item = .chat(s.ref.id)
            }
        } label: {
            HStack(spacing: 10) {
                switch section {
                case .agents: AgentAvatar(summary: s, size: 26)
                case .notebooks: InitialTile(name: s.title, size: 22)
                default: Image(systemName: "bubble.left").font(.system(size: 12)).foregroundStyle(Color.dsFg3).frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg).lineLimit(1)
                    if let sub = subtitle(s) { Text(sub).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1) }
                }
                Spacer()
                Text(BuildSessionView.relative(s.updatedAt)).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 16).frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ s: SessionSummary) -> String? {
        switch section {
        case .notebooks:
            let n = s.activeTopics.count
            return "\(n) topic\(n == 1 ? "" : "s")"
        case .agents: return MainSidebar.agentLine(s)
        default: return nil
        }
    }
}
