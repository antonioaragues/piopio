import PiopioKit
import PiopioTranscript
import SwiftUI

/// The main window (docs/design v2): one floating glass sidebar (Home, Needs you, Projects, Notebooks, Agents,
/// Chats), and the content for what it selects. There are no modes: the item's type decides the view.
struct RootView: View {
    let engine: EngineController
    @AppStorage("sidebarItem") private var itemRaw = "home"
    @State private var showNewAgent = false
    @State private var newSessionProject: ProjectInfo?
    @State private var showOnboarding = false
    /// What a start screen typed before opening the new session sheet.
    @State private var newSessionPrompt = ""
    @State private var palette: CommandPalette.Mode?
    @State private var paletteQuery = ""
    @State private var showNewSpace = false
    @State private var newSpaceThreads: [String] = []
    @State private var editingInstructions: SessionSummary?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var item: SidebarItem { SidebarItem(raw: itemRaw) }
    private var itemBinding: Binding<SidebarItem> { Binding(get: { SidebarItem(raw: itemRaw) }, set: { itemRaw = $0.raw }) }

    var body: some View {
        HStack(spacing: 0) {
            MainSidebar(engine: engine, item: itemBinding)
                .frame(width: 268)
                .glassPanel()
                .padding(8)
            VStack(spacing: 0) {
                if engine.isLost { EngineBanner(engine: engine) }
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.dsWin)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            if let mode = palette, engine.status == .ready {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08).ignoresSafeArea().onTapGesture { palette = nil }
                    CommandPalette(engine: engine, thread: selectedThread, close: { palette = nil }, newThread: newChat, openThread: open(_:item:), mode: mode, query: paletteQuery)
                        .padding(.top, 96)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newThread)) { _ in
            // ⌘N follows the selection: a session in its project, otherwise a chat.
            if case .session = item { newBuildSession() } else if case .project = item { newBuildSession() } else { newChat() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in newChat() }
        .onReceive(NotificationCenter.default.publisher(for: .newBuildSession)) { note in
            newSessionPrompt = note.userInfo?["prompt"] as? String ?? ""
            newSessionProject = engine.projects.first { $0.id == note.object as? String }
        }
        .sheet(item: $newSessionProject) { project in
            NewSessionSheet(engine: engine, project: project, initialPrompt: newSessionPrompt) { itemRaw = SidebarItem.session($0.id).raw }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProject)) { note in
            if let url = note.object as? URL {
                Task { await BuildActions.add(url, engine: engine) { itemRaw = SidebarItem.session($0).raw } }
            } else {
                BuildActions.addProject(engine: engine) { itemRaw = SidebarItem.session($0).raw }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectBuildSession)) { note in
            if let id = note.object as? String { itemRaw = SidebarItem.session(id).raw }
        }
        .modifier(SpaceAndAgentSheets(engine: engine, item: itemBinding, showNewAgent: $showNewAgent, showNewSpace: $showNewSpace, newSpaceThreads: $newSpaceThreads, editingInstructions: $editingInstructions))
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
        .onChange(of: itemRaw) { _, _ in engine.selectedThreadId = item.engineId }
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
            if status == .ready, engine.needsKey || ProcessInfo.processInfo.environment["PIOPIO_DEMO_WELCOME"] == "1" { showOnboarding = true }
        }
        .sheet(isPresented: $showOnboarding) {
            WelcomeView(engine: engine) { showOnboarding = false }
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
        case .index(.projects):
            ProjectsIndex(engine: engine, item: itemBinding)
        case .project(let id):
            ProjectsIndex(engine: engine, item: itemBinding, focus: id)
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
        case .notebook(let key):
            if let space = engine.space(String(key.split(separator: "/").first ?? "")) {
                let topicId = key.split(separator: "/").dropFirst().first.map(String.init)
                SpaceView(engine: engine, space: space, topicId: topicId, thread: engine.thread(space.ref(topic: topicId)), selection: chatSelection)
                    .id(key)
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
        }
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

    private func open(_ threadId: String, item found: String?) {
        itemRaw = (engine.item(for: threadId) ?? .chat(threadId)).raw
        guard let found, let summary = engine.threads.first(where: { $0.ref.id == threadId }) else { return }
        engine.thread(summary.ref).reveal(found)
    }

    /// ⌘N on a session or project: a new session in that project (or the first one).
    private func newBuildSession() {
        let project: ProjectInfo? = {
            switch item {
            case .session(let id): return engine.buildSessions.first { $0.ref.id == id }.flatMap { engine.project(of: $0) }
            case .project(let id): return engine.projects.first { $0.id == id }
            default: return nil
            }
        }()
        if let project = project ?? engine.projects.first {
            newSessionProject = project
        } else {
            NotificationCenter.default.post(name: .openProject, object: nil)
        }
    }

    private func newChat() {
        Task {
            if let ref = await engine.createThread() {
                try? await engine.refreshCatalog()
                itemRaw = SidebarItem.chat(ref.id).raw
            }
        }
    }
}

extension Notification.Name {
    static let selectThread = Notification.Name("piopio.selectThread")
    static let setMode = Notification.Name("piopio.setMode")
    /// Object: a folder URL to add, or nil to ask for one.
    static let openProject = Notification.Name("piopio.openProject")
    static let selectBuildSession = Notification.Name("piopio.selectBuildSession")
    /// Object: an approval id to show, or nil.
    static let openInbox = Notification.Name("piopio.openInbox")
    /// Object: a trace id between agents.
    static let openTrace = Notification.Name("piopio.openTrace")
}

// MARK: Banner (8d: what happened → what's safe → one action)

struct EngineBanner: View {
    let engine: EngineController

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.dsRed).frame(width: 7, height: 7)
            Text("**Local engine stopped unexpectedly.** Your threads are saved; reconnecting brings them back.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.dsFg)
            Spacer()
            Button("Restart") { Task { await engine.start() } }.buttonStyle(PillStyle(kind: .strong, compact: true))
            Button("Logs") { engine.revealLogs() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.dsRed.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.dsRed.opacity(0.35), lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

/// The notebook and agent sheets and their notifications (kept apart so the root view type-checks quickly).
private struct SpaceAndAgentSheets: ViewModifier {
    let engine: EngineController
    @Binding var item: SidebarItem
    @Binding var showNewAgent: Bool
    @Binding var showNewSpace: Bool
    @Binding var newSpaceThreads: [String]
    @Binding var editingInstructions: SessionSummary?
    @State private var trace: TraceTarget?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openTrace)) { note in
                if let id = note.object as? String { trace = TraceTarget(id: id) }
            }
            .sheet(item: $trace) { TraceSheet(engine: engine, traceId: $0.id) }
            .onReceive(NotificationCenter.default.publisher(for: .openInbox)) { note in
                item = .needsYou
                if let id = note.object as? String { UserDefaults.standard.set(id, forKey: "inboxFocus") }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newAgent)) { _ in showNewAgent = true }
            .sheet(isPresented: $showNewAgent) {
                NewAgentSheet(engine: engine) { item = .agent($0.id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newSpace)) { note in
                newSpaceThreads = (note.object as? String).map { [$0] } ?? []
                showNewSpace = true
            }
            .sheet(isPresented: $showNewSpace) {
                NewSpaceSheet(engine: engine, preselected: Set(newSpaceThreads)) { item = .notebook($0) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .editSpaceInstructions)) { note in
                editingInstructions = engine.space(note.object as? String ?? "")
            }
            .sheet(item: $editingInstructions) { space in
                SpaceSettingsSheet(engine: engine, space: space)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTopic)) { note in
                guard let target = note.object as? TopicTarget else { return }
                let ref = ContainerRef(kind: .space, id: target.spaceId, conversationId: target.topicId)
                item = .notebook(ref.key)
                if let found = target.itemId { engine.thread(ref).reveal(found) }
            }
    }
}
