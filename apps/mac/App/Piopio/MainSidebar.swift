import PiopioKit
import PiopioTranscript
import SwiftUI

/// The one sidebar (docs/design/grey 9a): a 52pt top bar (traffic lights, toggle, compose), Search ⌘K, Home and
/// Needs you, then Pinned · Projects · Notebooks · Agents · Chats, and a footer with the cost today and Settings.
/// Rows are plain: a 16pt outline glyph, the name, and status only as a blue dot (needs you) or a grey ring (running).
/// Long lists show only what's live: a project's sessions that are running, waiting on you or touched in the last
/// 3 days (the rest fold into "N earlier sessions"), and a few of each section ("N more ›" opens the full index).
/// Section headers collapse; pins and collapsed sections persist.
struct MainSidebar: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @AppStorage("collapsedSections") private var collapsedRaw = ""
    @AppStorage("pinnedItems") private var pinnedRaw = ""
    @State private var showingEarlier: Set<String> = []
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""
    private var areas: AreaSet { Areas.shared.set }

    /// How many of each section show before "N more ›".
    private static let caps: [SidebarSection: Int] = [.projects: 4, .notebooks: 4, .agents: 4, .chats: 6]
    /// A session counts as live this long after its last activity.
    private static let liveWindow: TimeInterval = 3 * 86_400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights' row: the toggle and compose on the right.
            HStack(spacing: 2) {
                Spacer()
                SidebarToggle()
                NewMenu(engine: engine)
            }
            .padding(.horizontal, 12)
            .frame(height: Shell.barHeight)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    searchRow
                    navRow(.home, "Home", symbol: "house")
                    navRow(.needsYou, "Needs you", symbol: "tray", count: engine.needsYouCount)
                    pinnedSection
                    if areas.showsProjects { projectsSection }
                    if areas.showsNotebooks { notebooksSection }
                    if areas.showsAgents { agentsSection }
                    if areas.showsChats { chatsSection }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            footer
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let s = renaming { Task { await engine.rename(s.ref, to: newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: Search and footer

    /// Search ⌘K: opens the search and command box (10b).
    private var searchRow: some View {
        Button { NotificationCenter.default.post(name: .showPalette, object: nil) } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Color.dsFg2).frame(width: 18)
                Text("Search").font(.system(size: 13)).foregroundStyle(Color.dsFg)
                Spacer()
                Text("⌘K").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            }
            .rowChrome(selected: false)
        }
        .buttonStyle(.plain)
        .help("Search and commands (⌘K)")
    }

    /// Avatar, name, "This Mac · $0.91 today", and Settings.
    private var footer: some View {
        HStack(spacing: 10) {
            Text(String(HomeView.firstName.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dsFg2)
                .frame(width: 24, height: 24)
                .background(Color.dsChip, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(HomeView.firstName).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                Text(footerLine).font(.system(size: 11)).foregroundStyle(Color.dsFg3).lineLimit(1)
                    .help("OpenRouter spending today for this API key, including other apps that share it. Other providers are not included.")
            }
            Spacer(minLength: 4)
            Button { WindowOpener.shared.openSettings?() } label: { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle()).help("Settings (⌘,)").accessibilityLabel("Settings")
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(height: Shell.barHeight)
    }

    private var footerLine: String {
        switch engine.status {
        case .starting: return "This Mac · starting…"
        case .failed: return "This Mac · engine stopped"
        case .ready: return "This Mac" + ((engine.usage?.todayUsd).map { " · \(Self.money($0)) today" } ?? "")
        }
    }

    static func money(_ usd: Double) -> String {
        usd >= 1 ? String(format: "$%.2f", usd) : usd >= 0.01 || usd == 0 ? String(format: "$%.2f", usd) : String(format: "$%.3f", usd)
    }

    // MARK: Sections

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    private var pinned: [String] { pinnedRaw.split(separator: "\n").map(String.init) }

    private func toggle(_ section: SidebarSection) {
        var c = collapsed
        if c.contains(section.rawValue) { c.remove(section.rawValue) } else { c.insert(section.rawValue) }
        collapsedRaw = c.sorted().joined(separator: ",")
    }

    private func togglePin(_ item: SidebarItem) {
        let raw = item.raw
        pinnedRaw = (pinned.contains(raw) ? pinned.filter { $0 != raw } : pinned + [raw]).joined(separator: "\n")
    }

    private func pinButton(_ item: SidebarItem) -> some View {
        Button(pinned.contains(item.raw) ? "Unpin" : "Pin") { togglePin(item) }
    }

    @ViewBuilder
    private func header(_ section: SidebarSection, total: Int, shown: Int, add: (() -> Void)?, addHelp: String = "") -> some View {
        let isCollapsed = collapsed.contains(section.rawValue)
        HStack(spacing: 4) {
            Button { toggle(section) } label: {
                HStack(spacing: 4) {
                    SectionLabel(section.title)
                    if isCollapsed { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.dsFg3) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show \(section.title)" : "Hide \(section.title)")
            if let add {
                Button(action: add) {
                    Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Color.dsFg3).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(addHelp)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func more(_ text: String, _ target: SidebarItem) -> some View {
        Button { item = target } label: {
            HStack(spacing: 3) {
                Text(text)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
            .padding(.leading, 36).padding(.trailing, 8).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var pinnedSection: some View {
        // Pins from hidden areas are kept, and come back with their area.
        let items = pinned.map(SidebarItem.init(raw:)).filter { exists($0) && areas.shows($0, engine: engine) }
        if !items.isEmpty {
            header(.pinned, total: items.count, shown: items.count, add: nil)
            if !collapsed.contains(SidebarSection.pinned.rawValue) {
                ForEach(items, id: \.raw) { pinnedRow($0) }
            }
        }
    }

    private func exists(_ i: SidebarItem) -> Bool {
        switch i {
        case .project(let id): engine.projects.contains { $0.id == id }
        case .session(let id): engine.buildSessions.contains { $0.ref.id == id }
        case .notebook(let key): engine.space(String(key.split(separator: "/").first ?? "")) != nil
        case .agent(let id): engine.agents.contains { $0.ref.id == id }
        case .chat(let id): engine.threads.contains { $0.ref.id == id }
        default: false
        }
    }

    @ViewBuilder private func pinnedRow(_ i: SidebarItem) -> some View {
        switch i {
        case .project(let id): if let p = engine.projects.first(where: { $0.id == id }) { projectRow(p) }
        case .session(let id): if let s = engine.buildSessions.first(where: { $0.ref.id == id }) { sessionRow(s, indent: false) }
        case .notebook(let key): if let s = engine.space(String(key.split(separator: "/").first ?? "")) { notebookRow(s) }
        case .agent(let id): if let a = engine.agents.first(where: { $0.ref.id == id }) { agentRow(a) }
        case .chat(let id): if let t = engine.threads.first(where: { $0.ref.id == id }) { chatRow(t) }
        default: EmptyView()
        }
    }

    // MARK: Projects

    /// Projects by their latest activity.
    private var sortedProjects: [ProjectInfo] {
        engine.projects.sorted { latest($0) > latest($1) }
    }

    private func latest(_ p: ProjectInfo) -> String {
        engine.sessions(in: p).map(\.updatedAt).max() ?? p.addedAt
    }

    @ViewBuilder private var projectsSection: some View {
        let projects = sortedProjects
        let cap = Self.caps[.projects]!
        let pinnedHere = Set(pinned)
        let shown = Array(projects.prefix(cap))
        if areas.contains(.build) {
            header(.projects, total: projects.count, shown: shown.count, add: { BuildActions.addProject(engine: engine) { item = .session($0) } }, addHelp: "Add a project folder (⌘O)")
        } else {
            header(.projects, total: projects.count, shown: shown.count, add: { BuildActions.addFolderToChat(engine: engine) { item = .session($0) } }, addHelp: "Add a folder to chat about")
        }
        if !collapsed.contains(SidebarSection.projects.rawValue) {
            ForEach(shown) { project in
                if !pinnedHere.contains(SidebarItem.project(project.id).raw) { projectRow(project) }
                projectSessions(project)
            }
            if projects.count > cap { more("\(projects.count - cap) more projects", .index(.projects)) }
        }
    }

    @ViewBuilder private func projectSessions(_ project: ProjectInfo) -> some View {
        let all = engine.sessions(in: project).filter { $0.parent == nil && areas.showsSession(chatProfile: $0.profile == .chat) }
        let (live, earlier) = split(all)
        let showAll = showingEarlier.contains(project.id)
        ForEach(showAll ? live + earlier : live, id: \.ref.id) { s in sessionRow(s, indent: true) }
        if !earlier.isEmpty {
            Button {
                if showAll { showingEarlier.remove(project.id) } else { showingEarlier.insert(project.id) }
            } label: {
                Text(showAll ? "Hide earlier sessions" : "\(earlier.count) earlier session\(earlier.count == 1 ? "" : "s")")
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                    .padding(.leading, 36).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Live sessions (running, waiting on you, or recent; those that need you first) and the rest.
    private func split(_ sessions: [SessionSummary]) -> ([SessionSummary], [SessionSummary]) {
        let now = Date()
        let urgent = { (s: SessionSummary) in self.engine.liveStatus[s.ref.id] == .waitingApproval || self.engine.liveStatus[s.ref.id] == .running }
        let recent = { (s: SessionSummary) in now.timeIntervalSince(Self.date(s.updatedAt)) < Self.liveWindow }
        let live = sessions.filter { urgent($0) || recent($0) || item == .session($0.ref.id) }
            .sorted { (urgent($0) ? 0 : 1, $1.updatedAt) < (urgent($1) ? 0 : 1, $0.updatedAt) }
        let ids = Set(live.map(\.ref.id))
        return (live, sessions.filter { !ids.contains($0.ref.id) })
    }

    static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }

    private func projectRow(_ project: ProjectInfo) -> some View {
        let selected = item == .project(project.id)
        return Button { item = .project(project.id) } label: {
            HStack(spacing: 10) {
                RowGlyph(symbol: "folder")
                Text(project.name).font(.system(size: 13))
                    .foregroundStyle(project.missing == true ? Color.dsFg3 : Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                if project.missing == true {
                    Text("missing").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                } else if let branch = project.branch {
                    Text(branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
            }
            .rowChrome(selected: selected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if areas.contains(.build) { Button("New Session…") { NotificationCenter.default.post(name: .newBuildSession, object: project.id) } }
            if areas.contains(.chat) { Button("New Chat in This Folder") { Task { await BuildActions.chat(in: project, engine: engine) { item = .session($0) } } } }
            pinButton(.project(project.id))
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
            Divider()
            Button("Remove from Piopio") {
                if case .session(let id) = item, engine.sessions(in: project).contains(where: { $0.ref.id == id }) { item = .home }
                Task { await engine.removeProject(project) }
            }
        }
    }

    private func sessionRow(_ s: SessionSummary, indent: Bool) -> some View {
        let selected = item == .session(s.ref.id)
        return Button { item = .session(s.ref.id) } label: {
            HStack(spacing: 8) {
                Text(s.title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                if let worktree = s.worktree, worktree.finished == nil {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5)).foregroundStyle(Color.dsFg3).help("Worktree on \(worktree.branch)")
                }
                SidebarDot(status: dotStatus(s))
            }
            .rowChrome(selected: selected, leading: indent ? 36 : 8)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { newTitle = s.title; renaming = s }
            pinButton(.session(s.ref.id))
            Divider()
            Button("Move to Trash", role: .destructive) {
                if selected { item = .home }
                Task { await engine.delete(s.ref) }
            }
        }
    }

    private func dotStatus(_ s: SessionSummary) -> SidebarDot.Status {
        switch engine.liveStatus[s.ref.id] {
        case .running?: .running
        case .waitingApproval?: .waiting
        case .error?: .failed
        default: Date().timeIntervalSince(Self.date(s.updatedAt)) < Self.liveWindow ? .done : .idle
        }
    }

    // MARK: Notebooks

    @ViewBuilder private var notebooksSection: some View {
        let spaces = engine.spaces
        let cap = Self.caps[.notebooks]!
        header(.notebooks, total: spaces.count, shown: min(cap, spaces.count), add: { NotificationCenter.default.post(name: .newSpace, object: nil) }, addHelp: "New notebook (⌘⇧N)")
        if !collapsed.contains(SidebarSection.notebooks.rawValue) {
            ForEach(spaces.prefix(cap), id: \.ref.id) { notebookRow($0) }
            if spaces.count > cap { more("\(spaces.count - cap) more", .index(.notebooks)) }
        }
    }

    private func notebookRow(_ space: SessionSummary) -> some View {
        let selected: Bool = { if case .notebook(let key) = item { return key.split(separator: "/").first.map(String.init) == space.ref.id } else { return false } }()
        let unread = space.activeTopics.contains { $0.unread == true }
        let running = space.activeTopics.contains { $0.running == true }
        return Button { item = .notebook(space.ref.id) } label: {
            HStack(spacing: 10) {
                RowGlyph(symbol: "book.closed")
                Text(space.title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                if running { SidebarDot(status: .running) } else if unread { SidebarDot(status: .waiting).help("New replies") }
            }
            .rowChrome(selected: selected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            pinButton(.notebook(space.ref.id))
            Divider()
            SpaceMenu(engine: engine, space: space, selection: chatSelection)
        }
    }

    /// The selection as the older views take it (a thread id or a "space/topic" key).
    private var chatSelection: Binding<String?> {
        Binding(get: { item.engineId }, set: { id in item = id.flatMap(engine.item(for:)) ?? .home })
    }

    // MARK: Agents

    @ViewBuilder private var agentsSection: some View {
        let agents = engine.agents
        let cap = Self.caps[.agents]!
        header(.agents, total: agents.count, shown: min(cap, agents.count), add: { NotificationCenter.default.post(name: .newAgent, object: nil) }, addHelp: "New agent")
        if !collapsed.contains(SidebarSection.agents.rawValue) {
            ForEach(agents.prefix(cap), id: \.ref.id) { agentRow($0) }
            if agents.count > cap { more("\(agents.count - cap) more", .index(.agents)) }
        }
    }

    private func agentRow(_ agent: SessionSummary) -> some View {
        let selected = item == .agent(agent.ref.id)
        let status = agent.agent?.status
        return Button { item = .agent(agent.ref.id) } label: {
            HStack(spacing: 10) {
                RowGlyph(symbol: "smallcircle.circle")
                Text(agent.title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                if engine.liveStatus[agent.ref.key] == .running { SidebarDot(status: .running) }
                else if let inbox = status?.inbox, inbox > 0 { SidebarDot(status: .waiting).help("Wrote to you") }
                else if status?.paused == true { Text("Paused").font(.system(size: 11)).foregroundStyle(Color.dsFg3) }
            }
            .help(Self.agentLine(agent))
            .rowChrome(selected: selected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            pinButton(.agent(agent.ref.id))
            Button("Reveal Definition in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agent.agent?.folder ?? "")]) }
            Divider()
            Button("Delete Agent…", role: .destructive) {
                let alert = NSAlert()
                alert.messageText = "Delete “\(agent.title)”?"
                alert.informativeText = "Its conversations and memory are deleted. Its definition folder goes to the Trash."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Delete")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                if selected { item = .home }
                Task { await engine.delete(agent.ref) }
            }
        }
    }

    /// "Next run tomorrow 7:00", "Paused", or what it does.
    static func agentLine(_ agent: SessionSummary) -> String {
        if agent.agent?.status?.paused == true { return "Paused" }
        if let next = agent.agent?.status?.nextRun { return "Next run \(when(next))" }
        return agent.agent?.description ?? "Local agent"
    }

    /// "today 21:00", "tomorrow 7:00", "Tue 8:00", "23 Oct".
    static func when(_ iso: String) -> String {
        let d = date(iso)
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "today \(time)" }
        if cal.isDateInTomorrow(d) { return "tomorrow \(time)" }
        if d.timeIntervalSinceNow < 6 * 86_400 { return "\(d.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: Chats

    @ViewBuilder private var chatsSection: some View {
        let threads = engine.threads
        let cap = Self.caps[.chats]!
        header(.chats, total: threads.count, shown: min(cap, threads.count), add: { NotificationCenter.default.post(name: .newChat, object: nil) }, addHelp: "New chat")
        if !collapsed.contains(SidebarSection.chats.rawValue) {
            ForEach(threads.prefix(cap), id: \.ref.id) { chatRow($0) }
            if threads.count > cap { more("\(threads.count - cap) earlier", .index(.chats)) }
        }
    }

    private func chatRow(_ thread: SessionSummary) -> some View {
        let selected = item == .chat(thread.ref.id)
        return Button { item = .chat(thread.ref.id) } label: {
            HStack(spacing: 10) {
                RowGlyph(symbol: thread.debate != nil ? "person.2" : "bubble.left").help(thread.debate != nil ? "Debate" : "")
                Text(thread.title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                if engine.liveStatus[thread.ref.id] == .running { SidebarDot(status: .running) }
            }
            .rowChrome(selected: selected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { newTitle = thread.title; renaming = thread }
            pinButton(.chat(thread.ref.id))
            Divider()
            MoveToSpaceMenu(engine: engine, thread: thread)
            Divider()
            Button("Delete", role: .destructive) {
                if selected { item = .home }
                Task { await engine.delete(thread.ref) }
            }
        }
    }

    // MARK: Home and Needs you

    private func navRow(_ target: SidebarItem, _ title: String, symbol: String, count: Int = 0) -> some View {
        let selected = item == target
        return Button { item = target } label: {
            HStack(spacing: 10) {
                RowGlyph(symbol: symbol)
                Text(title).font(.system(size: 13)).foregroundStyle(Color.dsFg)
                Spacer()
                if count > 0 { Text("\(count)").font(.system(size: 12)).foregroundStyle(Color.dsFg2).monospacedDigit() }
            }
            .rowChrome(selected: selected)
        }
        .buttonStyle(.plain)
    }
}

/// A sidebar row's 16pt outline glyph in fg2.
struct RowGlyph: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Color.dsFg2).frame(width: 18)
    }
}

/// Compose (docs/design/grey 10a): a short menu where each kind's subtitle says where it lives.
struct NewMenu: View {
    let engine: EngineController

    static func help(_ areas: AreaSet) -> String {
        var kinds: [String] = []
        if areas.contains(.chat) { kinds.append("chat") }
        if areas.contains(.build) { kinds.append("session") }
        if areas.contains(.chat) { kinds.append("notebook") }
        if areas.contains(.agents) { kinds.append("agent") }
        return "New " + ListFormatter.localizedString(byJoining: kinds).replacingOccurrences(of: " and ", with: " or ") + " (⌘N)"
    }

    var body: some View {
        let areas = Areas.shared.set
        Menu {
            if areas.contains(.chat) {
                Button { NotificationCenter.default.post(name: .newChat, object: nil) } label: { Text("Chat"); Text("Saved under Chats") }
            }
            if areas.contains(.build) {
                Menu {
                    ForEach(engine.projects) { project in
                        Button(project.name) { NotificationCenter.default.post(name: .newBuildSession, object: project.id) }
                    }
                    if !engine.projects.isEmpty { Divider() }
                    Button("Open Folder…") { NotificationCenter.default.post(name: .openProject, object: nil) }
                } label: { Text("Session in a project"); Text("Pick a folder") }
            }
            if areas.contains(.chat) {
                Button { NotificationCenter.default.post(name: .newSpace, object: nil) } label: { Text("Notebook"); Text("Topics and memory") }
                Button { NotificationCenter.default.post(name: .newDebate, object: nil) } label: { Text("Debate"); Text("Two models work on it until they agree") }
            }
            if areas.contains(.agents) {
                Button { NotificationCenter.default.post(name: .newAgent, object: nil) } label: { Text("Agent"); Text("Runs on its own") }
            }
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Self.help(areas))
        .accessibilityLabel("New")
    }
}

/// The sidebar's status (docs/design/grey): a 6pt blue dot = needs you, a 10pt grey ring = running, nothing otherwise.
struct SidebarDot: View {
    enum Status { case running, waiting, done, idle, failed }
    let status: Status

    var body: some View {
        switch status {
        case .running: RunningRing()
        case .waiting: Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel("Needs you")
        case .failed: Circle().strokeBorder(Color.dsFg3, lineWidth: 1).frame(width: 7, height: 7).accessibilityLabel("Failed")
        case .done, .idle: EmptyView()
        }
    }
}

private extension View {
    /// A sidebar row: radius 7, 6×8 padding, a grey fill when selected or under the pointer.
    func rowChrome(selected: Bool, leading: CGFloat = 8, height: CGFloat = 29) -> some View {
        modifier(RowChrome(selected: selected, leading: leading, height: height))
    }
}

private struct RowChrome: ViewModifier {
    let selected: Bool
    let leading: CGFloat
    let height: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.leading, leading)
            .padding(.trailing, 8)
            .frame(minHeight: height)
            .background(selected ? Color.dsChip : hovering ? Color.dsChip.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension Notification.Name {
    static let newChat = Notification.Name("piopio.newChat")
}
