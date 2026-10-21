import PiopioKit
import PiopioTranscript
import SwiftUI

/// The main window (docs/design 2a–2c): floating glass sidebar with the mode switcher, then the content.
struct RootView: View {
    let engine: EngineController
    @AppStorage("mode") private var mode: AppMode = .chat
    @State private var selection: String?
    @State private var buildSelection: String?
    @AppStorage("agentSelection") private var agentSelection: String?
    @State private var showNewAgent = false
    @State private var newSessionProject: ProjectInfo?
    @State private var showOnboarding = false
    /// What the Build start screen typed before opening the new session sheet.
    @State private var newSessionPrompt = ""
    @State private var palette: CommandPalette.Mode?
    @State private var paletteQuery = ""
    @State private var showNewSpace = false
    @State private var newSpaceThreads: [String] = []
    @State private var editingInstructions: SessionSummary?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(engine: engine, mode: $mode, selection: $selection, buildSelection: $buildSelection, agentSelection: $agentSelection, onSearch: { palette = .messages; paletteQuery = "" })
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
                    CommandPalette(engine: engine, thread: selectedThread, close: { palette = nil }, newThread: newThread, openThread: open(_:item:), mode: mode, query: paletteQuery)
                        .padding(.top, 96)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newThread)) { _ in
            if mode == .build { newBuildSession() } else { newThread() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBuildSession)) { note in
            mode = .build
            newSessionPrompt = note.userInfo?["prompt"] as? String ?? ""
            newSessionProject = engine.projects.first { $0.id == note.object as? String }
        }
        .sheet(item: $newSessionProject) { project in
            NewSessionSheet(engine: engine, project: project, initialPrompt: newSessionPrompt) { buildSelection = $0.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProject)) { note in
            mode = .build
            if let url = note.object as? URL {
                Task { await BuildActions.add(url, engine: engine) { buildSelection = $0 } }
            } else {
                BuildActions.addProject(engine: engine) { buildSelection = $0 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectBuildSession)) { note in
            mode = .build
            buildSelection = note.object as? String
        }
        .modifier(SpaceAndAgentSheets(engine: engine, mode: $mode, selection: $selection, agentSelection: $agentSelection, showNewAgent: $showNewAgent, showNewSpace: $showNewSpace, newSpaceThreads: $newSpaceThreads, editingInstructions: $editingInstructions))
        .onReceive(NotificationCenter.default.publisher(for: .selectThread)) { note in
            mode = .chat
            selection = note.object as? String
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPalette)) { note in
            paletteQuery = (note.object as? String) ?? ""
            palette = (note.object as? Bool) == true || note.object is String ? .messages : .all
        }
        .onChange(of: selection) { _, _ in updateSelected() }
        .onChange(of: buildSelection) { _, _ in updateSelected() }
        .onChange(of: mode) { _, _ in updateSelected() }
        .onAppear {
            WindowOpener.shared.openMain = { [openWindow] in openWindow(id: "main") }
            WindowOpener.shared.openSettings = { [openSettings] in openSettings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .setMode)) { note in
            if let m = note.object as? AppMode { mode = m }
        }
        .onChange(of: engine.status) { _, status in
            if status == .ready, engine.needsKey || ProcessInfo.processInfo.environment["PIOPIO_DEMO_WELCOME"] == "1" { showOnboarding = true }
            if status == .ready, selection == nil { selection = engine.threads.first?.ref.id }
        }
        .sheet(isPresented: $showOnboarding) {
            WelcomeView(engine: engine) { showOnboarding = false }
        }
    }

    @ViewBuilder private var content: some View {
        switch (engine.status, mode) {
        case (.starting, _):
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Starting the local engine…").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case (.failed(let message), _) where !engine.wasReady:
            EmptyState(label: "Local engine", title: "The engine didn't start", message: message) {
                HStack {
                    Button("Try Again") { Task { await engine.start() } }.buttonStyle(PillStyle(kind: .primary))
                    Button("Show Logs") { engine.revealLogs() }.buttonStyle(PillStyle())
                }
            }
        case (_, .build):
            if let id = buildSelection, let summary = engine.buildSessions.first(where: { $0.ref.id == id }) {
                BuildSessionView(engine: engine, session: engine.thread(summary.ref), summary: summary)
                    .id(id)
            } else {
                BuildEmptyState(engine: engine, selection: $buildSelection)
            }
        case (_, .agents):
            agentsContent
        case (_, .chat):
            if let id = selection, let summary = engine.threads.first(where: { $0.ref.id == id }) {
                ThreadView(engine: engine, thread: engine.thread(summary.ref), summary: summary)
                    .id(id)
            } else if let id = selection, let summary = engine.buildSessions.first(where: { $0.ref.id == id }) {
                BuildSessionView(engine: engine, session: engine.thread(summary.ref), summary: summary, chatLens: true)
                    .id(id)
            } else if let key = selection, let space = engine.space(String(key.split(separator: "/").first ?? "")) {
                let topicId = key.split(separator: "/").dropFirst().first.map(String.init)
                SpaceView(engine: engine, space: space, topicId: topicId, thread: engine.thread(space.ref(topic: topicId)), selection: $selection)
                    .id(key)
            } else {
                EmptyState(label: "Chat", title: "Start a thread, or a Notebook", message: "A thread is one conversation. A Notebook keeps a long-running subject organized into topics.") {
                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Button(action: newThread) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("New thread").font(.system(size: 13, weight: .semibold))
                                    Text("⌘N").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                                }
                                .frame(width: 160, alignment: .leading)
                                .padding(14)
                                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            Button { newSpaceThreads = []; showNewSpace = true } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("New Notebook").font(.system(size: 13, weight: .semibold))
                                    Text("⌘⇧N").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                                }
                                .frame(width: 160, alignment: .leading)
                                .padding(14)
                                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                        if let shortcut = QuickChatController.shortcutLabel {
                            Text("Tip: \(shortcut) opens Quick Chat from any app").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var agentsContent: some View {
        if agentSelection == "inbox" {
            InboxView(engine: engine, agentSelection: $agentSelection)
        } else if let summary = engine.agents.first(where: { $0.ref.id == agentSelection }) {
            AgentPage(engine: engine, summary: summary, selection: $agentSelection)
                .id(summary.ref.id)
        } else {
                EmptyState(label: "Agents", title: "Create your first agent", message: "Agents live in your messaging apps, run on schedules and keep their own memory.") {
                    VStack(spacing: 10) {
                        Button { showNewAgent = true } label: {
                            Label("New Agent…", systemImage: "plus").font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(PillStyle(kind: .primary))
                        Text("Start from a template (personal assistant, daily briefing, habit coach…) or from scratch. It runs on this Mac; channels like Telegram come later.")
                            .font(.system(size: 12)).foregroundStyle(Color.dsFg3).multilineTextAlignment(.center).frame(width: 360)
                    }
                }
        }
    }

    /// What notifications treat as "you're looking at it".
    private func updateSelected() {
        engine.selectedThreadId = mode == .build ? buildSelection : mode == .chat ? selection : agentSelection
    }

    private var selectedThread: ThreadModel? {
        guard mode == .chat, let id = selection, let summary = engine.threads.first(where: { $0.ref.id == id }) else { return nil }
        return engine.thread(summary.ref)
    }

    private func open(_ threadId: String, item: String?) {
        mode = .chat
        selection = threadId
        guard let item, let summary = engine.threads.first(where: { $0.ref.id == threadId }) else { return }
        engine.thread(summary.ref).reveal(item)
    }

    /// ⌘N in Build: a new session in the selected session's project (or the first project).
    private func newBuildSession() {
        let current = engine.buildSessions.first { $0.ref.id == buildSelection }
        let path = current?.projectPath ?? current?.cwd
        if let project = engine.projects.first(where: { $0.path == path }) ?? engine.projects.first {
            newSessionProject = project
        } else {
            NotificationCenter.default.post(name: .openProject, object: nil)
        }
    }

    private func newThread() {
        mode = .chat
        Task {
            if let ref = await engine.createThread() {
                try? await engine.refreshCatalog()
                selection = ref.id
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

// MARK: Sidebar

struct Sidebar: View {
    let engine: EngineController
    @Binding var mode: AppMode
    @Binding var selection: String?
    @Binding var buildSelection: String?
    @Binding var agentSelection: String?
    let onSearch: () -> Void
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 36) // traffic lights
            ModeSwitcher(mode: $mode).padding(.horizontal, 12)
            Button(action: onSearch) {
                HStack {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                    Text("Search")
                    Spacer()
                    Text("⌘⇧F").font(.system(size: 11))
                }
                .font(.system(size: 13))
                .foregroundStyle(Color.dsFg3)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    switch mode {
                    case .chat: chatList
                    case .build: BuildSidebarList(engine: engine, selection: $buildSelection)
                    case .agents: AgentsSection(engine: engine, selection: $agentSelection)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }

            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack(spacing: 6) {
                StatusDot(status: engineDot, size: 6)
                Text("Local engine").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                Spacer()
                if let shortcut = QuickChatController.shortcutLabel {
                    Button { QuickChatController.shared?.show() } label: {
                        Text("\(shortcut) Quick Chat").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
        }
        .alert("Rename Thread", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let thread = renaming { Task { await engine.rename(thread.ref, to: newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var engineDot: StatusDot.Status {
        switch engine.status {
        case .ready: .done
        case .starting: .waiting
        case .failed: .failed
        }
    }

    @ViewBuilder private var chatList: some View {
        SpacesSection(engine: engine, selection: $selection)
        ChatProjectsSection(engine: engine, selection: $selection)
        if engine.threads.isEmpty {
            placeholder("Threads", "Your conversations appear here.")
        }
        ForEach(groups, id: \.title) { group in
            SectionLabel(group.title).padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
            ForEach(group.threads, id: \.ref.id) { thread in
                row(thread)
            }
        }
    }

    private func row(_ thread: SessionSummary) -> some View {
        let selected = selection == thread.ref.id
        return Button { selection = thread.ref.id } label: {
            HStack(spacing: 8) {
                Text(thread.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(Color.dsFg)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let status = engine.liveStatus[thread.ref.id] {
                    switch status {
                    case .running: StatusDot(status: .running)
                    case .error: StatusDot(status: .failed, size: 6)
                    default: EmptyView()
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") {
                newTitle = thread.title
                renaming = thread
            }
            Divider()
            MoveToSpaceMenu(engine: engine, thread: thread)
            Divider()
            Button("Delete", role: .destructive) {
                if selection == thread.ref.id { selection = nil }
                Task { await engine.delete(thread.ref) }
            }
        }
    }

    private func placeholder(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
    }

    private struct Group { let title: String; let threads: [SessionSummary] }

    /// Today / Yesterday / Previous 7 days / Older, by last activity.
    private var groups: [Group] {
        let calendar = Calendar.current
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var buckets: [(String, [SessionSummary])] = [("Today", []), ("Yesterday", []), ("Previous 7 days", []), ("Older", [])]
        for t in engine.threads {
            let date = iso.date(from: t.updatedAt) ?? .distantPast
            let index = calendar.isDateInToday(date) ? 0 : calendar.isDateInYesterday(date) ? 1 : now.timeIntervalSince(date) < 7 * 86_400 ? 2 : 3
            buckets[index].1.append(t)
        }
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, threads: $0.1) }
    }
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

/// The Space and Agent sheets and their notifications (kept apart so the root view type-checks quickly).
private struct SpaceAndAgentSheets: ViewModifier {
    let engine: EngineController
    @Binding var mode: AppMode
    @Binding var selection: String?
    @Binding var agentSelection: String?
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
                mode = .agents
                agentSelection = "inbox"
                if let id = note.object as? String { UserDefaults.standard.set(id, forKey: "inboxFocus") }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newAgent)) { _ in
                mode = .agents
                showNewAgent = true
            }
            .sheet(isPresented: $showNewAgent) {
                NewAgentSheet(engine: engine) { agentSelection = $0.id }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newSpace)) { note in
                mode = .chat
                newSpaceThreads = (note.object as? String).map { [$0] } ?? []
                showNewSpace = true
            }
            .sheet(isPresented: $showNewSpace) {
                NewSpaceSheet(engine: engine, preselected: Set(newSpaceThreads)) { selection = $0 }
            }
            .onReceive(NotificationCenter.default.publisher(for: .editSpaceInstructions)) { note in
                editingInstructions = engine.space(note.object as? String ?? "")
            }
            .sheet(item: $editingInstructions) { space in
                SpaceSettingsSheet(engine: engine, space: space)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTopic)) { note in
                guard let target = note.object as? TopicTarget else { return }
                mode = .chat
                let ref = ContainerRef(kind: .space, id: target.spaceId, conversationId: target.topicId)
                selection = ref.key
                if let item = target.itemId { engine.thread(ref).reveal(item) }
            }
    }
}
