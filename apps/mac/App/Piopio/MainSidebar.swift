import PiopioKit
import PiopioTranscript
import SwiftUI

/// The one sidebar (docs/design/grey 9a): a 52pt top bar (traffic lights, toggle), Search ⌘K beside New (a round +), Home and Automations,
/// then Pinned · Agents · Projects · Conversations (docs/spec/18 §21), and a footer with the cost today and Settings.
/// Rows are plain: a 16pt outline glyph, the name, and status only as a blue dot (needs you) or a grey ring (running).
/// Long lists show only what's live: a project's sessions that are running, waiting on you or touched in the last
/// 3 days (the rest fold into "N earlier sessions"), and a few of each section ("N more ›" opens the full index).
/// Section headers collapse; pins and collapsed sections persist.
struct MainSidebar: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @AppStorage("collapsedSections") private var collapsedRaw = ""
    /// Projects whose sessions are folded away (ids, one per line). Clicking a project row folds or unfolds it.
    @AppStorage("collapsedProjects") private var collapsedProjectsRaw = ""
    @AppStorage("pinnedItems") private var pinnedRaw = ""
    @State private var showingEarlier: Set<String> = []
    @State private var renaming: SessionSummary?
    /// Folders on this Mac that aren't projects yet, for the Projects + menu (docs/spec/18 §17).
    @State private var recentFolders: [RecentFolder] = []
    private var naming: ProjectNaming { ProjectNaming.shared }
    @State private var newTitle = ""
    private var areas: AreaSet { Areas.shared.set }

    /// How many of each section show before "N more ›".
    private static let caps: [SidebarSection: Int] = [.agents: 5, .projects: 4, .chats: 6]
    /// A session counts as live this long after its last activity.
    private static let liveWindow: TimeInterval = 3 * 86_400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights' row: the toggle on the right (New sits beside Search).
            HStack(spacing: 2) {
                Spacer()
                SidebarToggle()
            }
            .padding(.horizontal, 12)
            .frame(height: Shell.barHeight)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            // Search, Home (it holds what waits on you, docs/spec/21 D2) and Automations, then Pinned, your agents
            // (docs/spec/18 §21), Projects and Conversations; all of it scrolls.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    searchRow
                    navRow(.home, "Home", symbol: "house", count: engine.needsYouCount)
                    // Automations (docs/spec/27 AU10): what starts on its own, for Piopio and every agent.
                    automationsRow
                    // The Library (docs/spec/35 §4.4): what Piopio made, with your pins under it.
                    libraryRows
                    pinnedSection
                    if areas.showsAgents { agentsSection }
                    if areas.showsProjects { projectsSection }
                    if areas.showsChats { chatsSection }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            // No line above the footer (docs/design/card-layout): the sidebar is the window itself.
            footer
        }
        .onChange(of: item) { _, _ in
            if let id = openProjectId, collapsedProjects.contains(id) { setProject(id, collapsed: false) }
        }
        // Naming a new project shows Projects, even when its section was folded.
        .onChange(of: naming.active) { _, on in
            if on, collapsed.contains(SidebarSection.projects.rawValue) { toggle(.projects) }
        }
        .task(id: engine.projects.map(\.path)) {
            let known = Set(engine.projects.map(\.path))
            recentFolders = await Task.detached { RecentFolder.scan().filter { !known.contains($0.url.path) } }.value
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

    /// Search ⌘K (opens the search and command box, 10b) as a pill, and New beside it: a round black + whose menu
    /// starts a conversation, an agent or a project.
    private var searchRow: some View {
        HStack(spacing: 8) {
            SearchPill()
            ComposeButton()
        }
        .padding(.bottom, 6)
    }

    /// Avatar, name, "This Mac · $0.91 today", and Settings.
    private var footer: some View {
        HStack(spacing: 10) {
            Text(String(HomeView.firstName.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dsFg2)
                .frame(width: 26, height: 26)
                .background(Color.dsChip, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(HomeView.firstName).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                // What requests cost lives here, not in Settings: today's spend opens Overview › Spend (docs/spec/34 §4).
                Button { item = .overview(nil) } label: {
                    Text(footerLine).font(.system(size: 11)).foregroundStyle({ if case .overview = item { return Color.dsFg }; return Color.dsFg3 }()).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("OpenRouter spending today for this API key, including other apps that share it. Other providers are not included. Click for Overview.")
            }
            Spacer(minLength: 4)
            Button { WindowOpener.shared.openSettings?() } label: { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle()).help("Settings (⌘,)").accessibilityLabel("Settings")
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(height: 52)
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
    private var collapsedProjects: Set<String> { Set(collapsedProjectsRaw.split(separator: "\n").map(String.init)) }

    private func setProject(_ id: String, collapsed fold: Bool) {
        var c = collapsedProjects
        if fold { c.insert(id) } else { c.remove(id) }
        collapsedProjectsRaw = c.sorted().joined(separator: "\n")
    }
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
    private func header(_ section: SidebarSection, total: Int, shown: Int, add: (() -> Void)?, addHelp: String = "", addMenu: AnyView? = nil) -> some View {
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
            } else if let addMenu {
                addMenu
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    /// "··· 3 more projects ›": a row of its own, its glyph in the icons' column, so it reads as one more of the section
    /// and not as part of the row above (a project's nested conversations start at about the names' indent).
    private func more(_ text: String, _ target: SidebarItem) -> some View {
        Button { item = target } label: {
            HStack(spacing: 10) {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg3).frame(width: 18)
                HStack(spacing: 3) {
                    Text(text)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                Spacer(minLength: 0)
            }
            .rowChrome(selected: false, height: 28)
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
        case .agent(let id): engine.agents.contains { $0.ref.id == id }
        case .chat(let id): engine.threads.contains { $0.ref.id == id }
        default: false
        }
    }

    @ViewBuilder private func pinnedRow(_ i: SidebarItem) -> some View {
        switch i {
        case .project(let id): if let p = engine.projects.first(where: { $0.id == id }) { projectRow(p) }
        case .session(let id): if let s = engine.buildSessions.first(where: { $0.ref.id == id }) { sessionRow(s, indent: false) }
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
        // + is a menu (docs/spec/18 §17): a new folder, one you have, or one this Mac already has.
        header(.projects, total: projects.count, shown: shown.count, add: nil, addMenu: AnyView(ProjectsAddMenu(recent: recentFolders)))
        if !collapsed.contains(SidebarSection.projects.rawValue) {
            draftRow(.project)
            if naming.active {
                NewProjectRow(error: naming.error, busy: naming.busy, commit: createProject, cancel: { naming.cancel() })
            }
            ForEach(shown) { project in
                if !pinnedHere.contains(SidebarItem.project(project.id).raw) { projectRow(project) }
                projectSessions(project)
            }
            if projects.count > cap { more("\(projects.count - cap) more project\(projects.count - cap == 1 ? "" : "s")", .index(.projects)) }
        }
    }

    /// Makes ~/Piopio/<name> (with its AGENTS.md and NOTES.md) and opens its New conversation; or, when a conversation
    /// asked (Continue in › New Project…), goes back to it and continues it there.
    private func createProject(_ name: String) {
        let from = naming.continuing
        naming.busy = true
        naming.error = nil
        Task {
            defer { naming.busy = false }
            do {
                let project = try await engine.createProject(name: name)
                naming.finish(project)
                if let from {
                    item = engine.item(for: from.id) ?? .chat(from.id)
                    ContinueInMenu<EmptyView>.continueIn(engine, from, project)
                } else {
                    NotificationCenter.default.post(name: .newBuildSession, object: project.id)
                }
            } catch {
                naming.error = ((error as? EngineError)?.message ?? error.localizedDescription) + " Nothing was made."
            }
        }
    }

    /// The project whose session (or new session page, or project page) is open.
    private var openProjectId: String? {
        switch item {
        case .session(let id): engine.buildSessions.first { $0.ref.id == id }.flatMap { engine.project(of: $0) }?.id
        case .project(let id), .newSession(let id), .board(let id): id
        default: nil
        }
    }

    /// A project's + opens its new conversation page (docs/spec/18 §4), unless its folder is gone.
    private func startsSessions(_ project: ProjectInfo) -> Bool {
        project.missing != true
    }

    /// The project's conversations, nested under it on a hairline: the live ones and "N earlier". Hidden while the
    /// project is folded.
    @ViewBuilder private func projectSessions(_ project: ProjectInfo) -> some View {
        let all = engine.sessions(in: project).filter { $0.listed && areas.showsSession(chatProfile: $0.profile == .chat) }
        let (live, earlier) = split(all)
        let showAll = showingEarlier.contains(project.id)
        // No draft row: the project's row is marked while its new conversation page is open. Its board is the first
        // row once it has one (docs/spec/18 §19, 26 §5).
        let work = engine.work(in: project).flatMap { $0.way.parallel || !$0.tasks.isEmpty ? $0 : nil }
        if !collapsedProjects.contains(project.id), !all.isEmpty || work != nil {
            VStack(alignment: .leading, spacing: 1) {
                if let work { boardRow(project, work) }
                // Side conversations sit one level under the conversation they came from (docs/spec/24 §6).
                ForEach(Self.nested(showAll ? live + earlier : live), id: \.0.ref.id) { s, depth in
                    Group { if s.ref.kind == .thread { chatRow(s) } else { sessionRow(s, indent: true) } }
                        .padding(.leading, CGFloat(depth) * 14)
                }
                if !earlier.isEmpty {
                    Button {
                        if showAll { showingEarlier.remove(project.id) } else { showingEarlier.insert(project.id) }
                    } label: {
                        Text(showAll ? "Hide earlier conversations" : "\(earlier.count) earlier conversation\(earlier.count == 1 ? "" : "s")")
                            .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                            .padding(.leading, 8).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 9)
            .overlay(alignment: .leading) { Rectangle().fill(Color.dsLine).frame(width: 1) }
            .padding(.leading, 17)
            .padding(.bottom, 4)
        }
    }

    /// "Board  2 doing ◌": the project's board, with what's moving (or the blue dot when a task is blocked).
    private func boardRow(_ project: ProjectInfo, _ work: ProjectWork) -> some View {
        let doing = work.tasks.filter { ["doing", "review", "integrating"].contains($0.state) }.count
        let blocked = work.tasks.contains { $0.state == "blocked" }
        return Button { item = .board(project.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.3x1").font(.system(size: 11.5)).foregroundStyle(Color.dsFg2).frame(width: 16)
                Text("Board").font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                if doing > 0 {
                    Text("\(doing) doing").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                    SidebarDot(status: .running)
                } else if blocked { SidebarDot(status: .waiting).help("A task is blocked") }
            }
            .rowChrome(selected: item == .board(project.id), height: 30)
        }
        .buttonStyle(.plain)
        .help("\(project.name)'s board")
    }

    /// Live sessions (running, waiting on you, or recent; those that need you first) and the rest.
    private func split(_ sessions: [SessionSummary]) -> ([SessionSummary], [SessionSummary]) {
        let now = Date()
        let urgent = { (s: SessionSummary) in self.engine.liveStatus[s.ref.id] == .waitingApproval || self.engine.liveStatus[s.ref.id] == .running }
        let recent = { (s: SessionSummary) in now.timeIntervalSince(Self.date(s.updatedAt)) < Self.liveWindow }
        let live = sessions.filter { urgent($0) || recent($0) || item == .session($0.ref.id) || item == .chat($0.ref.id) }
            .sorted { (urgent($0) ? 0 : 1, $1.updatedAt) < (urgent($1) ? 0 : 1, $0.updatedAt) }
        let ids = Set(live.map(\.ref.id))
        return (live, sessions.filter { !ids.contains($0.ref.id) })
    }

    static func date(_ iso: String) -> Date {
        ISODate.parse(iso) ?? .distantPast
    }

    private func projectRow(_ project: ProjectInfo) -> some View {
        let plus: ProjectRow.Plus? = startsSessions(project) ? .session : nil
        let folded = collapsedProjects.contains(project.id)
        let work = engine.work(in: project)
        let hasContent = !engine.sessions(in: project).filter { $0.listed }.isEmpty || work.map { $0.way.parallel || !$0.tasks.isEmpty } == true
        let working = work?.tasks.filter { ["doing", "review", "integrating"].contains($0.state) }.count ?? 0
        // The row folds or unfolds its conversations (docs/spec/18 §19); with nothing to show, it starts one there.
        return ProjectRow(project: project, selected: false, isOpen: openProjectId == project.id, plus: plus, folded: hasContent ? folded : nil, working: working,
                          toggle: {
                              if hasContent { withAnimation(.easeOut(duration: 0.15)) { setProject(project.id, collapsed: !folded) } }
                              else if plus != nil { NotificationCenter.default.post(name: .newBuildSession, object: project.id) }
                          },
                          link: { urls in linkFolders(urls, to: project) },
                          settings: { NotificationCenter.default.post(name: .projectSettings, object: project.id) }) {
            NotificationCenter.default.post(name: .newBuildSession, object: project.id)
        }
        .contextMenu {
            Button("New Conversation") { NotificationCenter.default.post(name: .newBuildSession, object: project.id) }
            Button("Project Settings…") { NotificationCenter.default.post(name: .projectSettings, object: project.id) }
            Button("Board") { item = .board(project.id) }
            pinButton(.project(project.id))
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
            Divider()
            Button("Remove from Piopio") {
                if case .session(let id) = item, engine.sessions(in: project).contains(where: { $0.ref.id == id }) { item = .home }
                Task { await engine.removeProject(project) }
            }
        }
    }

    /// Folders dropped on a project's row are linked to it, read only (docs/spec/18 §18); the row says so for a moment
    /// and nothing else moves (§19). Its settings list them.
    private func linkFolders(_ urls: [URL], to project: ProjectInfo) -> Bool {
        let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard !dirs.isEmpty, project.missing != true else { return false }
        Task { for url in dirs { try? await engine.linkFolder(url, edit: false, to: project) } }
        return true
    }

    private func sessionRow(_ s: SessionSummary, indent: Bool) -> some View {
        sessionRowBody(s, indent: indent)
    }

    private func sessionRowBody(_ s: SessionSummary, indent: Bool) -> some View {
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
            .rowChrome(selected: selected, height: indent ? 30 : 29)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { newTitle = s.title; renaming = s }
            pinButton(.session(s.ref.id))
            Divider()
            ExportMenuItems(engine: engine, ref: s.ref)
            Divider()
            Button("Move to Trash", role: .destructive) {
                if selected { item = .home }
                Task { await engine.delete(s.ref) }
            }
        }
    }

    /// Conversations with their side conversations right under them, one level deeper each (docs/spec/24 §6). A side
    /// conversation whose parent isn't in the list stays where it is.
    static func nested(_ list: [SessionSummary]) -> [(SessionSummary, Int)] {
        let ids = Set(list.map(\.ref.id))
        let children = Dictionary(grouping: list.filter { $0.side.map { ids.contains($0.parent.id) } ?? false }, by: { $0.side!.parent.id })
        var out: [(SessionSummary, Int)] = []
        func add(_ s: SessionSummary, _ depth: Int) {
            out.append((s, depth))
            for child in (children[s.ref.id] ?? []).sorted(by: { $0.createdAt < $1.createdAt }) { add(child, depth + 1) }
        }
        for s in list where !(s.side.map { ids.contains($0.parent.id) } ?? false) { add(s, 0) }
        return out
    }

    private func dotStatus(_ s: SessionSummary) -> SidebarDot.Status {
        // A parent shows that one of its side conversations needs you (docs/spec/24 §6).
        if engine.liveStatus[s.ref.id] != .running, engine.sides(of: s.ref.id).contains(where: { $0.side?.state == "needs_you" }) { return .waiting }
        return switch engine.liveStatus[s.ref.id] {
        case .running?: .running
        case .waitingApproval?: .waiting
        case .error?: .failed
        default: Date().timeIntervalSince(Self.date(s.updatedAt)) < Self.liveWindow ? .done : .idle
        }
    }

    /// The selection as the older views take it (a thread id or a "space/topic" key).
    private var chatSelection: Binding<String?> {
        Binding(get: { item.engineId }, set: { id in item = id.flatMap(engine.item(for:)) ?? .home })
    }

    // MARK: Automations

    /// Automations (docs/spec/27 AU10): one row that opens the list. It stays selected on one of them, and shows how
    /// many there are; a ring while one runs.
    private var automationsRow: some View {
        let selected: Bool = switch item {
        case .automations, .automation: true
        default: false
        }
        let running = engine.automations.contains { $0.lastStatus == "running" }
        return Button { item = .automations(nil) } label: {
            HStack(spacing: 10) {
                RowGlyph(symbol: "clock.arrow.circlepath")
                Text("Automations").font(.system(size: 13)).foregroundStyle(Color.dsFg)
                Spacer()
                if running { SidebarDot(status: .running).help("An automation is running") }
                else if !engine.automations.isEmpty { Text("\(engine.automations.count)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
            }
            .rowChrome(selected: selected)
        }
        .buttonStyle(.plain)
    }

    /// The Library pin a dragged pin is over (it lights up where the dragged one lands).
    @State private var pinDropTarget: String?

    // MARK: Library

    /// The Library (docs/spec/35 §4.4): its row, and the five most recent pins under it. A pin opens the item itself.
    @ViewBuilder private var libraryRows: some View {
        Button { item = .library } label: {
            HStack(spacing: 10) {
                RowGlyph(symbol: "books.vertical")
                Text("Library").font(.system(size: 13)).foregroundStyle(Color.dsFg)
                Spacer()
            }
            .rowChrome(selected: { if case .app = item { return true }; return item == .library }())
        }
        .buttonStyle(.plain)
        ForEach(engine.pinnedLibrary.prefix(5)) { pin in
            libraryPinRow(pin)
        }
        .animation(.easeOut(duration: 0.22), value: engine.libraryPins)
    }

    private func libraryPinRow(_ pin: LibraryEntry) -> some View {
        Group {
            Button {
                LibraryOpen.open(pin, engine: engine) { item = $0 } missing: { engine.focusLibrary(pin.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: LibraryKind.symbol(pin.kind)).font(.system(size: 11)).foregroundStyle(Color.dsFg3).frame(width: 14)
                    Text(pin.name).font(.system(size: 13)).foregroundStyle(pin.missing == true ? Color.dsFg3 : Color.dsFg).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                }
                .rowChrome(selected: false, leading: 30, height: 28)
            }
            .buttonStyle(.plain)
            .help(pin.missing == true ? "\(pin.name): the file isn't where it was" : pin.name)
            .draggable(LibraryPinDrag.text(pin.id)) { LibraryDragPreview(item: pin) }
            .modifier(LibraryDropTarget(targeted: pinDropTarget == pin.id, radius: DS.Radius.row))
            .dropDestination(for: String.self) { drops, _ in
                pinDropTarget = nil
                guard let id = LibraryPinDrag.id(drops) else { return false }
                Task { await engine.movePin(id, onto: pin.id) }
                return true
            } isTargeted: { on in
                if on { pinDropTarget = pin.id } else if pinDropTarget == pin.id { pinDropTarget = nil }
            }
            .contextMenu {
                Button("Open") { LibraryOpen.open(pin, engine: engine) { item = $0 } missing: { engine.focusLibrary(pin.id) } }
                Button("Show in Library") { engine.focusLibrary(pin.id) }
                Divider()
                Button("Unpin") { Task { try? await engine.pinLibrary(pin.id, false) } }
            }
        }
    }

    // MARK: Agents

    /// Agents (docs/spec/18 §21): your agents under their own heading, by latest activity, with a + for a new one. The
    /// heading folds the section; "N more ›" opens the Agents page with all of them.
    @ViewBuilder private var agentsSection: some View {
        let agents = engine.agents.sorted { $0.updatedAt > $1.updatedAt }
        let cap = Self.caps[.agents]!
        let pinnedHere = Set(pinned)
        let shown = Array(agents.prefix(cap))
        header(.agents, total: agents.count, shown: shown.count, add: { item = .start(.agent) }, addHelp: "New agent (⌥⌘N)")
        if !collapsed.contains(SidebarSection.agents.rawValue) {
            draftRow(.agent)
            ForEach(shown, id: \.ref.id) { agent in
                if !pinnedHere.contains(SidebarItem.agent(agent.ref.id).raw) { agentRow(agent) }
            }
            if agents.count > cap { more("\(agents.count - cap) more", .index(.agents)) }
        }
    }

    private func agentRow(_ agent: SessionSummary) -> some View {
        let selected = item == .agent(agent.ref.id)
        let status = agent.agent?.status
        return Button { item = .agent(agent.ref.id) } label: {
            HStack(spacing: 10) {
                SidebarAvatar(id: agent.ref.id, name: agent.title, glyph: agent.agent?.avatar).frame(width: 18)
                Text(agent.title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                if agent.agent?.location == "cloud" { Image(systemName: "cloud").font(.system(size: 10)).foregroundStyle(Color.dsFg2).help("In your cloud") }
                Spacer(minLength: 4)
                if engine.liveStatus[agent.ref.key] == .running { SidebarDot(status: .running) }
                // Unread (design 1a): a blue dot when it wrote to you.
                else if let inbox = status?.inbox, inbox > 0 { Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("Wrote to you") }
                else if agent.agent?.draft == true { Text("Draft").font(.system(size: 11)).foregroundStyle(Color.dsFg3) }
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
            ExportMenuItems(engine: engine, ref: agent.ref, noun: "Chat")
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

    /// Conversations with no project (those in a project are listed under it).
    @ViewBuilder private var chatsSection: some View {
        let threads = engine.threads
        let cap = Self.caps[.chats]!
        // + opens the same New conversation page as ⌘N and the compose button, without scrolling back up (CF32).
        header(.chats, total: threads.count, shown: min(cap, threads.count),
               add: { NotificationCenter.default.post(name: .newChat, object: nil) }, addHelp: "New conversation (⌘N)")
        if !collapsed.contains(SidebarSection.chats.rawValue) {
            draftRow(.chat)
            ForEach(Self.nested(Array(threads.prefix(cap))), id: \.0.ref.id) { t, depth in chatRow(t).padding(.leading, CGFloat(depth) * 14) }
            if threads.count > cap { more("\(threads.count - cap) earlier", .index(.chats)) }
        }
    }

    private func chatRow(_ thread: SessionSummary) -> some View {
        let selected = item == .chat(thread.ref.id)
        return Button { item = .chat(thread.ref.id) } label: {
            HStack(spacing: 10) {
                RowGlyph(symbol: "bubble.left")
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
            ContinueInMenu(engine: engine, ref: thread.ref) { Text("Continue in") }
            ExportMenuItems(engine: engine, ref: thread.ref)
            Divider()
            Button("Delete", role: .destructive) {
                if selected { item = .home }
                Task { await engine.delete(thread.ref) }
            }
        }
    }

    // MARK: Drafts

    /// A start page's row (docs/design/start-pages): shown while it's open or once something is typed there, at the
    /// top of the section where the thing will live, in fg2 with "Draft".
    @ViewBuilder private func draftRow(_ kind: StartKind) -> some View {
        let drafts = StartDrafts.shared
        let selected = item == .start(kind)
        if selected || drafts.hasContent(kind) {
            Button { item = .start(kind) } label: {
                HStack(spacing: 10) {
                    RowGlyph(symbol: kind.symbol)
                    Text(drafts.title(kind)).font(.system(size: 13)).foregroundStyle(Color.dsFg2).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("Draft").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                }
                .rowChrome(selected: selected)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Discard Draft", role: .destructive) {
                    drafts.clear(kind)
                    if selected { item = .home }
                }
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

/// New (docs/spec/18 §21): a menu of New Conversation (the New conversation page, with no project) and New Agent (its
/// start page). With Agents off it's a plain button for a new conversation. Projects are made from the Projects +.
/// The sidebar's Search: a pill on the window's field grey that opens the search and command box (⌘K).
private struct SearchPill: View {
    @State private var hovering = false

    var body: some View {
        Button { NotificationCenter.default.post(name: .showPalette, object: nil) } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsFg2)
                Text("Search").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                Spacer(minLength: 4)
                Text("⌘K").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(hovering ? Color.dsChip : Color.dsField, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Search and commands (⌘K)")
    }
}

/// New: a round black + (the sidebar's one black action). Its menu holds what you can start, by the areas that are on
/// (the same as File › New); with neither Agents nor Chat on, it starts a conversation straight away.
struct ComposeButton: View {
    private var areas: AreaSet { Areas.shared.set }

    var body: some View {
        if areas.showsAgents || areas.showsChats {
            Menu {
                Button { NotificationCenter.default.post(name: .newChat, object: nil) } label: {
                    Label("New Conversation", systemImage: "bubble.left")
                }
                .keyboardShortcut("n")
                if areas.showsAgents {
                    Button { NotificationCenter.default.post(name: .newAgent, object: nil) } label: {
                        Label("New Agent", systemImage: "bird")
                    }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                }
                if areas.showsChats {
                    Button { NotificationCenter.default.post(name: .newProject, object: nil) } label: {
                        Label("New Project…", systemImage: "folder.badge.plus")
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(NewButtonStyle())
            .fixedSize()
            .help("New conversation, agent or project")
            .accessibilityLabel("New")
        } else {
            Button { NotificationCenter.default.post(name: .newChat, object: nil) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(NewButtonStyle())
            .help("New conversation (⌘N)")
            .accessibilityLabel("New conversation")
        }
    }
}

/// A 32pt black circle with a white glyph (inverted in dark mode).
private struct NewButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { NewButtonBody(configuration: configuration) }

    private struct NewButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dsInvFg)
                .frame(width: 32, height: 32)
                .background(Color.dsInv.opacity(configuration.isPressed ? 0.75 : hovering ? 0.88 : 1), in: Circle())
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
    }
}

/// The sidebar's status (docs/design/grey): a 6pt blue dot = needs you, a 10pt grey ring = running, nothing otherwise.
struct SidebarDot: View {
    enum Status { case running, waiting, done, idle, failed }
    let status: Status

    var body: some View {
        switch status {
        case .running: RunningRing()
        case .waiting: Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel("Waiting on you")
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

/// A project row: folder, name, and a + that starts a session there (or a chat, in a folder you only chat about).
/// Clicking the row folds or unfolds its sessions (a chevron marks a folded one). On
/// the open project the + always shows (on a grey fill) and the name is medium weight; on the others it shows on hover
/// or keyboard focus, in place of the branch. VoiceOver reaches it as the row's "New session" action.
private struct ProjectRow: View {
    enum Plus { case session, chat }
    let project: ProjectInfo
    let selected: Bool
    let isOpen: Bool
    let plus: Plus?
    /// Whether its sessions are folded away; nil when it has none.
    let folded: Bool?
    /// Its board's tasks in progress (a dot, in place of the branch).
    var working = 0
    let toggle: () -> Void
    /// Folders dropped from Finder: linked to the project (18 §18).
    var link: (([URL]) -> Bool)?
    /// The project's settings sheet (18 §19).
    var settings: (() -> Void)?
    let start: () -> Void
    @State private var hovering = false
    @State private var dropping = false
    @FocusState private var settingsFocused: Bool
    /// "Linked Bibliografía", for a moment after a drop.
    @State private var linked: String?
    @FocusState private var plusFocused: Bool

    private var showsPlus: Bool { plus != nil && (isOpen || hovering || plusFocused || settingsFocused) }
    private var plusLabel: String { "New conversation in \(project.name)" }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    RowGlyph(symbol: "folder")
                    Text(project.name).font(.system(size: 13, weight: isOpen ? .medium : .regular))
                        .foregroundStyle(project.missing == true ? Color.dsFg3 : Color.dsFg).lineLimit(1)
                    if folded == true {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.dsFg3)
                    }
                    Spacer(minLength: 4)
                    if project.missing == true {
                        Text("missing").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                    } else if let linked {
                        Text(linked).font(.system(size: 11)).foregroundStyle(Color.accentColor).lineLimit(1).transition(.opacity)
                    } else if !showsPlus, working > 0 {
                        SidebarDot(status: .running).help("\(working) task\(working == 1 ? "" : "s") in progress")
                    } else if !showsPlus, let branch = project.branch {
                        Text(branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1)
                    }
                    if plus != nil { Color.clear.frame(width: settings == nil ? 22 : 50, height: 1) }
                }
                .rowChrome(selected: selected)
            }
            .buttonStyle(.plain)
            .help(folded == nil ? "New conversation in \(project.name)" : folded == true ? "Show its conversations" : "Hide its conversations")
            .accessibilityValue(folded == nil ? "" : folded == true ? "Collapsed" : "Expanded")
            .accessibilityAction(named: "New conversation") { if plus != nil { start() } }
            .accessibilityAction(named: "Project settings") { settings?() }
            if plus != nil {
              HStack(spacing: 2) {
                // Settings, then + (docs/spec/18 §19): shown on hover and on the project you're in.
                if let settings {
                    Button(action: settings) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.dsFg2)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($settingsFocused)
                    .opacity(showsPlus ? 1 : 0)
                    .help("Project settings")
                    .accessibilityLabel("\(project.name) settings")
                }
                Button(action: start) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isOpen ? Color.dsFg : Color.dsFg2)
                        .frame(width: 26, height: 26)
                        .background(isOpen ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($plusFocused)
                .opacity(showsPlus ? 1 : 0)
                .padding(.trailing, 2)
                .help("New conversation in this folder")
                .accessibilityLabel(plusLabel)
              }
              .padding(.trailing, -2)
            }
        }
        .onHover { hovering = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard link?(urls) == true else { return false }
            let name = urls.first.map(\.lastPathComponent) ?? ""
            withAnimation { linked = urls.count == 1 ? "Linked \(name)" : "Linked \(urls.count) folders" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { linked = nil } }
            return true
        } isTargeted: { dropping = $0 && link != nil }
        .help(dropping ? "Link to \(project.name)" : "")
    }
}

/// New project, named in the sidebar (docs/spec/18 §17): ⇧⌘N, the Projects + menu, the box's popover and Continue in ›
/// New Project… all start it. `continuing` is the conversation to move there once it's made; `fresh` are projects made
/// this session, whose first page offers to write their instructions.
@MainActor @Observable final class ProjectNaming {
    static let shared = ProjectNaming()
    private(set) var active = false
    private(set) var continuing: ContainerRef?
    var busy = false
    var error: String?
    private(set) var fresh: Set<String> = []
    /// Captures (PIOPIO_DEMO_NAME_PROJECT): a name the row types and makes as it appears.
    var demoName: String?

    func begin(continuing ref: ContainerRef?) {
        continuing = ref
        error = nil
        active = true
    }

    func cancel() {
        guard !busy else { return }
        active = false
        continuing = nil
        error = nil
    }

    func finish(_ project: ProjectInfo) {
        fresh.insert(project.id)
        active = false
        continuing = nil
        error = nil
    }
}

/// The Projects + (docs/spec/18 §17): New Project, Open Folder…, and the folders this Mac already has (git repos in the
/// usual places and folders pi worked in), the first four in the menu and the rest under More Folders.
private struct ProjectsAddMenu: View {
    let recent: [RecentFolder]

    var body: some View {
        Menu {
            Button { NotificationCenter.default.post(name: .newProject, object: nil) } label: { Text("New Project"); Text("An empty folder in ~/Piopio") }
            Button { NotificationCenter.default.post(name: .openProject, object: nil) } label: { Text("Open Folder…"); Text("One you already have") }
            if !recent.isEmpty {
                Section("On This Mac") {
                    ForEach(recent.prefix(4)) { folder($0) }
                    if recent.count > 4 {
                        Menu("More Folders") { ForEach(recent.dropFirst(4).prefix(16)) { folder($0) } }
                    }
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Color.dsFg3).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("New project or open a folder")
        .accessibilityLabel("Add a project")
    }

    private func folder(_ f: RecentFolder) -> some View {
        Button { NotificationCenter.default.post(name: .openProject, object: f.url) } label: {
            Text(f.url.lastPathComponent)
            Text(f.branch.map { "\(f.path) · \($0)" } ?? f.path)
        }
    }
}

/// The new project's row, named in place like a new folder in Finder: Return makes it, Esc (or leaving it empty)
/// cancels and nothing is made.
private struct NewProjectRow: View {
    let error: String?
    let busy: Bool
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                RowGlyph(symbol: "folder.badge.plus")
                TextField("", text: $name, prompt: Text("Project name").foregroundStyle(Color.dsFg3))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { if !trimmed.isEmpty { commit(trimmed) } }
                    .onExitCommand(perform: cancel)
                    .disabled(busy)
                    .accessibilityLabel("New project name")
                    .help("Return makes the folder; Esc cancels")
                if busy { ProgressView().controlSize(.mini) }
            }
            .padding(.leading, 8).padding(.trailing, 8)
            .frame(height: 29)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
            // Where it goes; Return makes it and Esc cancels, as in Finder (the row's help says so).
            Text(error ?? "Makes ~/Piopio/\(trimmed.isEmpty ? "Name" : trimmed.replacingOccurrences(of: "/", with: "-"))")
                .font(.system(size: 11)).foregroundStyle(error == nil ? Color.dsFg3 : Color.dsFg2)
                .lineLimit(error == nil ? 1 : 3).truncationMode(.middle)
                .padding(.leading, 36).padding(.bottom, 4)
        }
        .onAppear {
            DispatchQueue.main.async { focused = true }
            if let demo = ProjectNaming.shared.demoName {
                ProjectNaming.shared.demoName = nil
                name = demo
                Task { try? await Task.sleep(for: .seconds(1)); commit(demo) }
            }
        }
        // Clicking away from an empty name gives up, as Finder does with nothing typed.
        .onChange(of: focused) { _, on in if !on && trimmed.isEmpty && !busy { cancel() } }
    }
}
