import PiopioKit
import PiopioTranscript
import SwiftUI

/// The main window (docs/design/grey 9a): a sidebar flush to the window edge (Search, Home, Needs you, Projects,
/// Agents, Conversations) that collapses, and the content for what it selects. The item's type decides the view.
struct RootView: View {
    let engine: EngineController
    @AppStorage("sidebarItem") private var itemRaw = "home"
    @AppStorage("sidebarWidth") private var sidebarWidth = 260.0
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @State private var fullScreen = false
    @State private var availableWidth = 1280.0
    @State private var sidebarDragStart: Double?
    @State private var showOnboarding = false
    /// Where you were before a start page, for Esc.
    @State private var previousRaw = "home"
    /// The conversation that asked for New project (Continue in › New Project…): it continues in the new folder.
    @State private var continuing: ContainerRef?
    /// Shared by the start pages' card and the conversations' composer (the move into place when starting).
    @Namespace private var composerSpace
    @State private var palette: CommandPalette.Mode?
    @State private var paletteQuery = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var item: SidebarItem { SidebarItem(raw: itemRaw) }
    private var itemBinding: Binding<SidebarItem> { Binding(get: { SidebarItem(raw: itemRaw) }, set: { itemRaw = $0.raw }) }

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarCollapsed {
            MainSidebar(engine: engine, item: itemBinding)
                .frame(width: min(sidebarWidth, max(200, availableWidth * 0.28)))
                .sidePanel(.trailing, background: .dsSide)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.clear).frame(width: 7).contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if sidebarDragStart == nil { sidebarDragStart = sidebarWidth }
                            sidebarWidth = min(340, max(200, (sidebarDragStart ?? sidebarWidth) + value.translation.width))
                        }.onEnded { _ in sidebarDragStart = nil })
                        .accessibilityLabel("Sidebar width").accessibilityValue("\(Int(sidebarWidth)) points")
                        .accessibilityAdjustableAction { direction in sidebarWidth = min(340, max(200, sidebarWidth + (direction == .increment ? 20 : -20))) }
                        .help("Drag to resize the sidebar")
                }
                .transition(.move(edge: .leading))
            }
            VStack(spacing: 0) {
                if engine.isLost { EngineBanner(engine: engine) }
                if let hidden = hiddenArea { HiddenAreaBar(area: hidden) }
                if engine.isMaintaining { ProgressView("Saving or restoring Piopio data…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    content.id(engine.dataGeneration)
                        .environment(\.composerSpace, composerSpace)
                        .environment(\.startBack, { itemRaw = previousRaw })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.dsWin)
        .overlay(alignment: .topLeading) {
            // In full screen there are no traffic lights to make room for.
            if sidebarCollapsed { SidebarToggle().frame(height: Shell.barHeight).padding(.leading, fullScreen ? 14 : 78) }
        }
        .background { TrafficLightsPosition() }
        .modifier(ShellEvents(fullScreen: $fullScreen, toggleSidebar: toggleSidebar))
        .environment(\.sidebarControl, SidebarControl(collapsed: sidebarCollapsed, fullScreen: fullScreen, toggle: toggleSidebar))
        .onGeometryChange(for: Double.self) { $0.size.width } action: { availableWidth = $0 }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            if let mode = palette, engine.status == .ready {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08).ignoresSafeArea().onTapGesture { palette = nil }
                    CommandPalette(engine: engine, thread: selectedThread, close: { palette = nil }, newThread: newChat, openThread: open(_:item:), openResult: openSearch, mode: mode, query: paletteQuery)
                        .padding(.top, 96)
                }
            }
        }
        .modifier(FileViewerSheet())
        // The conversation start page (docs/spec/18 §4): ⌘N and Conversations' + open it with no project; a project's +
        // (and ⌘O) open it with that project chosen.
        .onReceive(NotificationCenter.default.publisher(for: .newThread)) { _ in newChat() }
        .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in newChat() }
        .onReceive(NotificationCenter.default.publisher(for: .newBuildSession)) { note in
            guard let id = note.object as? String, engine.projects.contains(where: { $0.id == id }) else { return }
            startConversation(target: "project:" + id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProject)) { note in openFolder(note.object as? URL) }
        // The conversation start page's box follows the page (also from a link or a saved selection): a project's has that
        // project chosen, the plain one no project.
        .onChange(of: itemRaw, initial: true) { _, raw in
            let target = UserDefaults.standard.string(forKey: "homeTarget") ?? "chat"
            switch SidebarItem(raw: raw) {
            case .newSession(let id):
                // A project with a team (docs/spec/19 §10): its work goes to the team; the chip switches back to the project.
                let team = engine.projects.first { $0.id == id }.flatMap { engine.team(in: $0) }
                UserDefaults.standard.set(team.map { "team:" + $0.id } ?? "project:" + id, forKey: "homeTarget")
            case .start(.chat) where target.hasPrefix("project:"): UserDefaults.standard.set("chat", forKey: "homeTarget")
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectBuildSession)) { note in
            if let id = note.object as? String { itemRaw = SidebarItem.session(id).raw }
        }
        .modifier(StartSheets(engine: engine, item: itemBinding, continuing: $continuing))
        .onReceive(NotificationCenter.default.publisher(for: .selectThread)) { note in
            guard let id = note.object as? String else { return }
            itemRaw = (engine.item(for: id) ?? .chat(id)).raw
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectItem)) { note in
            if let raw = note.object as? String { itemRaw = raw }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPalette)) { note in
            paletteQuery = (note.object as? String) ?? ""
            palette = (note.object as? Bool) == true || note.object is String ? .messages : .all
        }
        .onChange(of: itemRaw) { old, _ in
            engine.selectedThreadId = item.engineId
            if !SidebarItem(raw: old).isStart { previousRaw = old }
        }
        .onAppear {
            engine.selectedThreadId = item.engineId
            WindowOpener.shared.openMain = { [openWindow] in openWindow(id: "main") }
            WindowOpener.shared.openSettings = { [openSettings] in openSettings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .setMode)) { note in
            // Older entry points (automation, links) name a mode: the closest place in the one sidebar.
            guard let m = note.object as? AppMode else { return }
            switch m {
            case .build: itemRaw = SidebarItem.index(.projects).raw
            case .chat: itemRaw = SidebarItem.home.raw
            case .agents:
                if let id = UserDefaults.standard.string(forKey: "agentSelection"), engine.agents.contains(where: { $0.ref.id == id }) { itemRaw = SidebarItem.agent(id).raw } else { itemRaw = SidebarItem.index(.agents).raw }
            }
        }
        .onChange(of: engine.status) { _, status in
            guard status == .ready, !showOnboarding else { return }
            // First run only (docs/spec/15): people who used Piopio before areas existed keep everything and get a tip.
            let forced = ProcessInfo.processInfo.environment["PIOPIO_DEMO_WELCOME"] == "1"
            switch WelcomeGate.decide(done: Areas.welcomeDone, hasHistory: hasHistory, forced: forced) {
            case .show: showOnboarding = true
            case .existingUser:
                Areas.welcomeDone = true
                Areas.shared.showsTip = true
            case .done: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .runSetupAgain)) { _ in
            WindowOpener.shared.showMain()
            showOnboarding = true
        }
        .overlay {
            if showOnboarding {
                WelcomeView(engine: engine) { target in
                    Areas.welcomeDone = true
                    withAnimation(.easeOut(duration: 0.25)) { showOnboarding = false }
                    if let target { itemRaw = target.raw }
                }
                .transition(.opacity)
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch engine.status {
        case .starting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Starting the local engine…").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where !engine.wasReady:
            EmptyState(label: "Local engine", title: "The engine didn't start", message: message) {
                HStack {
                    Button("Try Again") { Task { await engine.start() } }.buttonStyle(PillStyle(kind: .primary))
                    Button("Show Logs") { engine.revealLogs() }.buttonStyle(PillStyle())
                }
            }
        default:
            page
        }
    }

    @ViewBuilder private var page: some View {
        switch item {
        case .home:
            HomeView(engine: engine, item: itemBinding)
        case .needsYou:
            NeedsYouView(engine: engine, item: itemBinding)
        case .index(.projects) where engine.projects.isEmpty && !Areas.shared.contains(.build):
            HatchEmpty(title: "Chat about a folder", message: "Add a folder and ask about what's in it: notes, documents, a project. Chats read its files; they don't run commands.") {
                Button("Add a Folder…") { BuildActions.addFolderToChat(engine: engine) { itemRaw = SidebarItem.session($0).raw } }.buttonStyle(PillStyle(kind: .primary))
            }
        case .index(.projects) where engine.projects(in: .build).isEmpty:
            BuildFirstRun(engine: engine, item: itemBinding)
        case .index(.projects):
            ProjectsIndex(engine: engine, item: itemBinding)
        case .project(let id):
            ProjectPage(engine: engine, projectId: id, item: itemBinding)
        case .index(.agents) where engine.agents.isEmpty:
            AgentsFirstRun(engine: engine, item: itemBinding)
        case .index(.chats) where engine.threads.isEmpty:
            ChatFirstRun(engine: engine, item: itemBinding)
        case .index(let section):
            SectionIndex(engine: engine, section: section, item: itemBinding)
        case .session(let id):
            if let summary = engine.buildSessions.first(where: { $0.ref.id == id }) {
                BuildSessionView(engine: engine, session: engine.thread(summary.ref), summary: summary, chatLens: summary.profile == .chat)
                    .id(id)
            } else {
                missing
            }
        case .chat(let id):
            if let summary = engine.threads.first(where: { $0.ref.id == id }) {
                ThreadView(engine: engine, thread: engine.thread(summary.ref), summary: summary)
                    .id(id)
            } else {
                missing
            }
        case .agent(let id):
            if let summary = engine.agents.first(where: { $0.ref.id == id }) {
                AgentPage(engine: engine, summary: summary, selection: agentSelection)
                    .id(id)
            } else {
                missing
            }
        // One case for both, so choosing another project in the box keeps the page (and what's typed).
        case .team(let id):
            TeamPage(engine: engine, teamId: id, item: itemBinding)
        case .start(.team):
            TeamStart(engine: engine, item: itemBinding)
        case .start(.chat), .newSession:
            ConversationStart(engine: engine, item: itemBinding)
        case .start(.project):
            NewProjectPage(engine: engine, continuing: continuing) { project in
                let from = continuing
                continuing = nil
                guard let project else { itemRaw = previousRaw; return }
                if let from {
                    // Back to that conversation; it moves on to the new folder's once that has started.
                    itemRaw = (engine.item(for: from.id) ?? .chat(from.id)).raw
                    ContinueInMenu<EmptyView>.continueIn(engine, from, project)
                }
                // Its first conversation: the start page with the new project chosen.
                else { startConversation(target: "project:" + project.id) }
            }
        case .start(let kind):
            StartView(engine: engine, kind: kind, item: itemBinding)
        }
    }

    /// The open item's area when it's hidden (opened from a notification, a link or an automation).
    private var hiddenArea: Area? {
        guard engine.status == .ready, !Areas.shared.set.shows(item, engine: engine) else { return nil }
        return Area(item: item, engine: engine)
    }

    /// Anything that says this Mac used Piopio before: a model, or something made.
    private var hasHistory: Bool {
        !engine.needsKey || !engine.projects.isEmpty || !engine.threads.isEmpty || !engine.agents.isEmpty
    }

    /// The item is gone (deleted elsewhere) or not in the catalog yet.
    private var missing: some View {
        HomeView(engine: engine, item: itemBinding)
    }

    /// The selection as older views take it: a thread id or a "space/topic" key.
    private var chatSelection: Binding<String?> {
        Binding(get: { item.engineId }, set: { id in itemRaw = (id.flatMap(engine.item(for:)) ?? .home).raw })
    }

    private var agentSelection: Binding<String?> {
        Binding(get: { if case .agent(let id) = item { id } else { nil } }, set: { id in itemRaw = (id.map { SidebarItem.agent($0) } ?? .home).raw })
    }

    private var selectedThread: ThreadModel? {
        guard case .chat(let id) = item, let summary = engine.threads.first(where: { $0.ref.id == id }) else { return nil }
        return engine.thread(summary.ref)
    }

    private func openSearch(_ hit: SearchResult) {
        engine.searchTarget = hit
        switch hit.ref.kind {
        case .thread: itemRaw = SidebarItem.chat(hit.ref.id).raw
        case .build: itemRaw = SidebarItem.session(hit.ref.id).raw
        case .space: return // notebooks are gone (docs/spec/18 phase 2)
        case .agent: itemRaw = SidebarItem.agent(hit.ref.id).raw
        }
        if let found = hit.itemId { engine.thread(hit.ref).reveal(found) }
    }

    private func open(_ threadId: String, item found: String?) {
        itemRaw = (engine.item(for: threadId) ?? .chat(threadId)).raw
        guard let found, let summary = engine.threads.first(where: { $0.ref.id == threadId }) else { return }
        engine.thread(summary.ref).reveal(found)
    }

    private func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.18)) { sidebarCollapsed.toggle() }
    }

    /// ⌘O and Open Folder: adds the folder as a project (once) and opens its new conversation page.
    private func openFolder(_ given: URL?) {
        var url = given
        if url == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Open"
            if panel.runModal() == .OK { url = panel.url }
        }
        guard let url else { return }
        Task {
            guard let project = await engine.addProject(url) else { return }
            startConversation(target: "project:" + project.id)
        }
    }

    /// A new conversation with no project, with the cursor in its box.
    private func newChat() { startConversation(target: "chat") }

    /// The conversation start page with `target` chosen in its box ("chat", "project:<id>").
    private func startConversation(target: String) {
        UserDefaults.standard.set(target, forKey: "homeTarget")
        let page: SidebarItem = target.hasPrefix("project:") ? .newSession(String(target.dropFirst(8))) : .start(.chat)
        if itemRaw != page.raw { itemRaw = page.raw }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .focusHome, object: nil) }
    }
}

extension Notification.Name {
    static let selectThread = Notification.Name("piopio.selectThread")
    static let setMode = Notification.Name("piopio.setMode")
    /// Object: a folder URL to add, or nil to ask for one.
    static let openProject = Notification.Name("piopio.openProject")
    static let selectBuildSession = Notification.Name("piopio.selectBuildSession")
    /// An agent's run, from its line in the chat (object: "run:<id>").
    static let openAgentRun = Notification.Name("piopio.openAgentRun")
    /// Object: an approval id to show, or nil.
    static let openInbox = Notification.Name("piopio.openInbox")
    /// Object: a trace id between agents.
    static let openTrace = Notification.Name("piopio.openTrace")
    /// Settings › General › Run setup again: the welcome, with the current areas ticked.
    static let runSetupAgain = Notification.Name("piopio.runSetupAgain")
    /// View › Toggle Sidebar (⌃⌘S).
    static let toggleSidebar = Notification.Name("piopio.toggleSidebar")
}

/// View › Toggle Sidebar, and whether the window is in full screen (no traffic lights to make room for).
private struct ShellEvents: ViewModifier {
    @Binding var fullScreen: Bool
    let toggleSidebar: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in toggleSidebar() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
    }
}

// MARK: Banner (8d: what happened → what's safe → one action)

struct EngineBanner: View {
    let engine: EngineController

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.dsFg2).frame(width: 7, height: 7)
            Text("**Local engine stopped unexpectedly.** Your threads are saved; reconnecting brings them back.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.dsFg)
            Spacer()
            Button("Restart") { Task { await engine.start() } }.buttonStyle(PillStyle(kind: .strong, compact: true))
            Button("Logs") { engine.revealLogs() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.dsFg2.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.dsFg2.opacity(0.35), lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

/// The start pages and the trace sheet, with their notifications (kept apart so the root view
/// type-checks quickly).
private struct StartSheets: ViewModifier {
    let engine: EngineController
    @Binding var item: SidebarItem
    @Binding var continuing: ContainerRef?
    @State private var trace: TraceTarget?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .newDebate)) { _ in item = .start(.debate) }
            .onReceive(NotificationCenter.default.publisher(for: .openTrace)) { note in
                if let id = note.object as? String { trace = TraceTarget(id: id) }
            }
            .sheet(item: $trace) { TraceSheet(engine: engine, traceId: $0.id) }
            .onReceive(NotificationCenter.default.publisher(for: .openInbox)) { note in
                item = .needsYou
                if let id = note.object as? String { UserDefaults.standard.set(id, forKey: "inboxFocus") }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newAgent)) { _ in item = .start(.agent) }
            // New project is a start page too; its object, when a conversation asked, is that conversation.
            .onReceive(NotificationCenter.default.publisher(for: .newProject)) { note in
                continuing = note.object as? ContainerRef
                item = .start(.project)
            }
            // File › Turn Conversation into Agent…: the open conversation (docs/spec/18 phase 3).
            .onReceive(NotificationCenter.default.publisher(for: .turnIntoAgent)) { _ in
                let ref: ContainerRef? = switch item {
                case .chat(let id): ContainerRef(kind: .thread, id: id)
                case .session(let id): ContainerRef(kind: .build, id: id)
                default: nil
                }
                if let ref { run { try await engine.turnIntoAgent(ref) } }
            }
    }
}

