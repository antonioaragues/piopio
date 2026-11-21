import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI
import UniformTypeIdentifiers

// Build mode (docs/spec/05-build, docs/design 2a): projects with their sessions in the sidebar, and a
// session view with tool cards. Approvals, checkpoints, the inspector and git arrive in milestones 2.2–2.4.

@MainActor
enum BuildActions {
    /// Asks for a folder, adds it as a project, and starts a session in it when it has none.
    static func addProject(engine: EngineController, select: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a folder to work on. Sessions run with pi-coding-agent inside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await add(url, engine: engine, select: select) }
    }

    /// With Build off (docs/spec/15): asks for a folder to chat about and starts a chat in it.
    static func addFolderToChat(engine: EngineController, select: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder to chat about. Chats can read its files; they don't run commands."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let project = await engine.addProject(url, lens: .chat) else { return }
            await chat(in: project, engine: engine, select: select)
        }
    }

    /// A chat in a folder (the Folder lens, docs/spec/04-chat §2): reads files, no commands.
    static func chat(in project: ProjectInfo, engine: EngineController, select: (String) -> Void) async {
        if let ref = await engine.createBuildSession(in: project, profile: .chat) {
            try? await engine.refreshCatalog()
            select(ref.id)
        }
    }

    static func add(_ url: URL, engine: EngineController, select: (String) -> Void) async {
        guard let project = await engine.addProject(url, lens: .build) else { return }
        if let latest = engine.sessions(in: project).first {
            select(latest.ref.id)
        } else if let ref = await engine.createBuildSession(in: project) {
            select(ref.id)
        }
    }
}

/// A Build session (docs/design 2a): header with the project and branch, transcript with tool cards, composer.
struct BuildSessionView: View {
    let engine: EngineController
    let session: ThreadModel
    let summary: SessionSummary
    /// Shown in Chat (docs/spec/04-chat §2): file browser and preview instead of the terminal and git.
    var chatLens = false

    /// The right column (docs/design/session-panel): closed by default; opens on Summary the first time a turn changes
    /// files; your toggle is then kept per session.
    @State private var showInspector = false
    /// Stepped aside because the window got too narrow (docs/design/card-layout): back when it widens, or when you open it.
    @State private var panelAutoHidden = false
    @State private var sessionWidth = 1200.0
    /// The conversation keeps at least this much beside the panel.
    static let minConversation = 460.0
    private var panelShown: Bool { showInspector && !panelAutoHidden }
    private var panelWidth: Double { inspectorTab == .browser ? 440 : inspectorTab == .files ? 280 : 300 }
    @AppStorage("sessionPanel") private var inspectorTab = SessionPanel.inspector
    /// The file the Files panel shows in place of its tree (a path chip, a file card, Read).
    @State private var previewing: String?
    @State private var filesFilter = FilesFilter.all
    @State private var reviewing = false
    @State private var reviewFile: String?
    @State private var git: GitModel?
    @State private var committing = false
    @State private var creatingPR = false
    @AppStorage("buildTerminal") private var showTerminal = false

    private var project: ProjectInfo? { engine.projects.first { $0.path == (summary.projectPath ?? summary.cwd) } }

    var body: some View {
        // The session in its card, and the panel beside it (docs/design/card-layout): Files and the Inspector flat on
        // the window, the Browser in a card of its own.
        HStack(spacing: CardLayout.margin) {
            VStack(spacing: 0) {
                if !reviewing { header }
                if !reviewing, let side = summary.side { SideStartedBar(engine: engine, side: side) }
                if let notice = git?.notice {
                    Text(notice.text).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                        .lineLimit(2).padding(.horizontal, 24).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let worktree = summary.worktree, let finished = worktree.finished {
                    Text(finished == .merged ? "Merged \(worktree.branch) into \(worktree.base). The worktree was removed; this session now works in the project folder." : "The worktree and \(worktree.branch) were discarded. This session now works in the project folder.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                        .padding(.horizontal, 24).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let project, project.needsTrust, project.trust == .undecided {
                    TrustBanner(engine: engine, project: project)
                        .padding(.horizontal, 24).padding(.bottom, 8)
                }
                if reviewing {
                    DiffReview(session: session, title: summary.title, selected: reviewFile, commit: !chatLens && git?.status?.repo == true && (git?.changedCount ?? 0) > 0 ? { committing = true } : nil) { reviewing = false }
                } else {
                    conversation
                }
                if showTerminal, !chatLens, let cwd = summary.cwd {
                    TerminalDrawer(cwd: cwd, session: session, previewProfile: summary.projectPath ?? cwd) { showTerminal = false }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
            .contentCard()
            if panelShown && !reviewing {
                VStack(spacing: 0) {
                    switch inspectorTab {
                    case .files:
                        if let cwd = summary.cwd {
                            FilesPanel(engine: engine, session: session, summary: summary, cwd: cwd, filter: $filesFilter, preview: $previewing, mention: mention)
                        }
                    case .browser:
                        BrowserPanel(refID: summary.ref.id, onStop: { Task { await session.stop() } },
                                     onClose: { withAnimation(.easeOut(duration: 0.2)) { showInspector = false } })
                    case .inspector:
                        InspectorPanel(engine: engine, session: session, summary: summary, project: project, git: git, chatLens: chatLens,
                                       committing: $committing, onReview: review, onRead: {
                                           filesFilter = .touched
                                           previewing = nil
                                           inspectorTab = .files
                                       })
                    }
                }
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .contentCard(inspectorTab == .browser)
            }
        }
        .ownsContentCard()
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
            // Crossing the line hides or brings back the panel; opening it in between is yours and stays.
            let line = panelWidth + CardLayout.margin + Self.minConversation
            let wasNarrow = sessionWidth < line, narrow = width < line
            sessionWidth = width
            guard narrow != wasNarrow else { return }
            withAnimation(.easeOut(duration: 0.15)) { panelAutoHidden = narrow }
        }
        // The model opened a page here: show the Browser view (docs/spec/22 §5).
        .onChange(of: BrowserCenter.shared.reveals[summary.ref.id]) { _, count in
            guard count != nil else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                inspectorTab = .browser
                showInspector = true
                panelAutoHidden = false
            }
        }
        .task { await session.open() }
        .task(id: summary.ref.id) {
            showInspector = Self.inspectorChoice(summary.ref.id) ?? hasChanges
            // PIOPIO_DEMO_PANEL=files | files:touched | files:<path> | inspector: captures open on that panel.
            if let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_PANEL"] {
                let parts = demo.split(separator: ":", maxSplits: 1).map(String.init)
                inspectorTab = parts[0] == "files" ? .files : .inspector
                if parts.count == 2 { if parts[1] == "touched" { filesFilter = .touched } else { previewing = parts[1] } }
                showInspector = true
            }
        }
        .onChange(of: hasChanges) { _, changed in
            // Opens on the Inspector the first time a turn changes files; a panel you already have open stays as it is.
            if changed, !showInspector, Self.inspectorChoice(summary.ref.id) == nil {
                inspectorTab = .inspector
                withAnimation(.easeOut(duration: 0.15)) { showInspector = true }
            }
        }
        .onChange(of: summary.followUps) { _, items in session.setFollowUps(items ?? ThreadView.demoFollowUps) }
        .onAppear { session.setFollowUps(summary.followUps ?? ThreadView.demoFollowUps) }
        .onReceive(NotificationCenter.default.publisher(for: .revealInInspector)) { note in
            guard let target = note.object as? RevealTarget, target.sessionId == session.ref.id, let cwd = summary.cwd else { return }
            previewing = target.path.hasPrefix(cwd + "/") ? String(target.path.dropFirst(cwd.count + 1)) : target.path
            inspectorTab = .files
            withAnimation(.easeOut(duration: 0.15)) { showInspector = true; panelAutoHidden = false }
        }
        .task(id: summary.cwd) {
            guard let cwd = summary.cwd else { return }
            let model = GitModel(cwd: cwd, engine: engine)
            git = model
            await model.refresh()
        }
        .onChange(of: session.state?.status) { _, status in
            if status == .idle { Task { await git?.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await git?.refresh() } }
        .sheet(isPresented: $committing) { if let git { CommitSheet(git: git) } }
        .sheet(item: Binding(get: { session.viewing }, set: { session.viewing = $0 })) { target in
            if let cwd = summary.cwd { FileViewer(engine: engine, cwd: cwd, target: target) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCommit)) { note in
            if note.object as? String == session.ref.id { committing = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .previewFile)) { note in
            if chatLens, let path = note.object as? String { openFile(path) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showReview)) { note in
            if note.object as? String == session.ref.id { reviewing = true }
        }
        .sheet(item: Binding(get: { session.restoring }, set: { session.restoring = $0 })) { checkpoint in
            RestoreSheet(session: session, checkpoint: checkpoint)
        }
        .sheet(item: Binding(get: { session.editingPlan }, set: { session.editingPlan = $0 })) { prompt in
            PlanEditorSheet(session: session, prompt: prompt)
        }
    }

    private var conversation: some View {
        ZStack(alignment: .bottom) {
            TranscriptView(document: session.document)
            // The thread dissolves before it reaches the composer (chat v3).
            LinearGradient(colors: [Color.dsWin.opacity(0), Color.dsWin], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .allowsHitTesting(false)
            VStack(spacing: 8) {
                if !session.isFollowing {
                    JumpToLatestButton { session.scrollToLatest() }
                }
                // What the session waits on you for is the composer's tray (docs/design/grey "Composer tray").
                // This conversation's tasks on the board (docs/spec/26 §5), live, then the merge card.
                if let work = project.flatMap({ engine.work(in: $0) }) { ConversationPlan(engine: engine, work: work, conversationId: summary.ref.id) }
                SideConversations(engine: engine, parentId: summary.ref.id)
                // Its pull request (docs/spec/05-build G7): checks, comments, Fix CI and Address comments.
                PullRequestBlock(engine: engine, summary: summary)
                Composer(engine: engine, thread: session).frame(maxWidth: DS.column)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 20)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                session.document.bottomInset = height + 40
            }
        }
        .modifier(SideOffers(engine: engine, ref: summary.ref, document: session.document))
        .onReceive(NotificationCenter.default.publisher(for: .createPullRequest)) { note in
            if note.object as? String == summary.ref.id { creatingPR = true }
        }
        .sheet(isPresented: $creatingPR) { CreatePRSheet(engine: engine, ref: summary.ref) { creatingPR = false } }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptOffer)) { note in
            guard note.object as? String == summary.ref.id, let kind = note.userInfo?["kind"] as? String, let call = note.userInfo?["call"] as? String else { return }
            takeOffer(kind, call: call)
        }
    }

    /// Piopio's offers (docs/spec/26 CL9): parallel work in this project, an agent of its own, or a routine here.
    private func takeOffer(_ kind: String, call: String) {
        guard case .tool(let t)? = session.document.item("tool:\(call)") else { return }
        switch kind {
        case "parallel":
            // Already taken: parallel work is on here, and this conversation was told to plan.
            guard let project, engine.work(in: project)?.way.parallel != true else { return }
            Task {
                do { try await engine.acceptParallel(summary.ref, in: project) } catch {
                    await session.send("Switching on parallel work failed: \((error as? EngineError)?.message ?? error.localizedDescription)")
                }
            }
        case "agent":
            // An older card's "Make it an agent" (offer_repeat is gone: Piopio makes automations, docs/spec/27 AU4).
            Task { try? await engine.turnIntoAgent(summary.ref) }
        case "routine":
            // An older card's "Just a routine here": the same thing is an automation now; ask Piopio to make it.
            guard let what = t.args?["what"]?.stringValue else { return }
            Task { await session.send("Make it an automation here: \(t.args?["when"]?.stringValue ?? "on its schedule"), \(what)") }
        default: break
        }
    }

    /// The session changed files: the inspector opens by itself the first time.
    private var hasChanges: Bool {
        _ = session.revision
        return session.document.items.contains { item in
            switch item {
            case .tool(let t): ["edit", "write"].contains(t.tool) && t.status == .done
            case .steps(let s): s.tools.contains { ["edit", "write"].contains($0.tool) && $0.status == .done }
            default: false
            }
        }
    }

    private static func inspectorChoice(_ id: String) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: "inspectorOpen") as? [String: Bool])?[id]
    }

    /// A toolbar view icon: opens the column on that view, or closes it when that view is already showing.
    private func show(_ view: SessionPanel) {
        withAnimation(.easeOut(duration: 0.15)) {
            if panelShown && inspectorTab == view { showInspector = false } else { inspectorTab = view; showInspector = true; panelAutoHidden = false }
        }
        rememberInspector()
    }

    private func rememberInspector() {
        var all = (UserDefaults.standard.dictionary(forKey: "inspectorOpen") as? [String: Bool]) ?? [:]
        all[summary.ref.id] = showInspector
        UserDefaults.standard.set(all, forKey: "inspectorOpen")
    }

    /// A file in the Files panel, in place of the tree.
    private func openFile(_ path: String) {
        previewing = path
        inspectorTab = .files
        withAnimation(.easeOut(duration: 0.15)) { showInspector = true; panelAutoHidden = false }
        rememberInspector()
    }

    /// Mention in chat: "@path " at the end of the draft.
    private func mention(_ path: String) {
        let current = session.draft ?? ""
        session.draft = current + (current.isEmpty || current.hasSuffix(" ") ? "" : " ") + "@\(path) "
    }

    private var canCommit: Bool { !chatLens && git?.status?.repo == true && (git?.changedCount ?? 0) > 0 }

    private func review(_ file: String?) {
        reviewFile = file
        reviewing = true
    }

    private func viewButton(_ view: SessionPanel) -> some View {
        let on = panelShown && inspectorTab == view
        // A blue dot on Inspector while something waits on you (an approval, a question, a command the sandbox stopped).
        let needsYou = view == .inspector && session.state?.status == .waitingApproval
        return ToolbarIcon(symbol: view.symbol, label: view.title, on: on, help: on ? "Hide the \(view.title.lowercased())" : view.help) { show(view) }
            .overlay(alignment: .topTrailing) {
                if needsYou {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Color.dsWin, lineWidth: 1.5))
                        .offset(x: -4, y: 3)
                        .accessibilityLabel("Needs you")
                }
            }
    }

    /// The toolbar (docs/design/session-panel): the title and "project · branch", then the
    /// views as icons (Summary, Changes, Files, Terminal), a divider and ··· (with Open in <editor>). Git lives in Summary's branch
    /// row. Status and cost aren't here: status is in the sidebar, cost in the column's footer.
    private var header: some View {
        PageHeader {
            PageTitle(name: summary.title, subtitle: subtitle)
        } actions: {
            HStack(spacing: 2) {
                viewButton(.inspector)
                viewButton(.files)
                viewButton(.browser)
                if !chatLens {
                    Button { showTerminal.toggle() } label: { Image(systemName: "apple.terminal") }
                        .buttonStyle(IconButtonStyle(on: showTerminal))
                        .accessibilityLabel("Terminal")
                        .help(showTerminal ? "Hide the terminal (⌃`)" : "Terminal (⌃`)")
                }
            }
            ToolbarDivider()
            Menu {
                Button("Review All Changes") { review(nil) }
                if summary.pr == nil, git?.status?.repo == true { Button("Create Pull Request…") { creatingPR = true } }
                if let cwd = summary.cwd {
                    Divider()
                    if let editor = Editor.preferred { Button("Open in \(editor.name)") { editor.open(cwd) } }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cwd, forType: .string)
                    }
                }
                Divider()
                ExportMenuItems(engine: engine, ref: summary.ref)
                Divider()
                Button("Turn into an Agent…") { run { try await engine.turnIntoAgent(summary.ref) } }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More")
                .help("Session tree, review, open in an editor or Finder, export")
            Button("") { show(.inspector) }.keyboardShortcut("i", modifiers: .command).hidden().frame(width: 0)
            Button("") {
                if panelShown && inspectorTab == .files { NotificationCenter.default.post(name: .focusFileFilter, object: nil) } else { show(.files) }
            }
            .keyboardShortcut("p", modifiers: .command).hidden().frame(width: 0)
        }
        .background {
            Button("") { if !chatLens { showTerminal.toggle() } }.keyboardShortcut("`", modifiers: .control).hidden()
        }
    }

    /// "smart-paste · pi/engine-protocol", or "· no git".
    private var subtitle: String {
        let name = project?.name ?? URL(fileURLWithPath: summary.cwd ?? "").lastPathComponent
        let branch = git?.status?.branch ?? summary.worktree?.branch ?? project?.branch
        let place = branch.map { "\(name) · \($0)" } ?? (git?.status?.repo == false ? "\(name) · no git" : name)
        // A coding agent runs it (docs/spec/31 CA3).
        if let m = engine.model(summary.model), m.isAgent { return "\(place) · runs in \(ModelPicker.providerTag(m))" }
        return place
    }

    static func relative(_ iso: String) -> String {
        guard let date = ISODate.parse(iso) else { return "" }
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

}


/// The right column's panels, each an icon in the session toolbar (docs/design/inspector, option 5a). The raw value
/// is what's saved; the Inspector is called Summary, as in chats (2026-11-15).
enum SessionPanel: String, CaseIterable {
    case inspector = "Inspector", files = "Files", browser = "Browser"

    var title: String { self == .inspector ? "Summary" : rawValue }

    /// The same icons as a chat's toolbar. Not sidebar.right: Files and the Browser open the side panel too.
    var symbol: String {
        switch self {
        case .inspector: "list.bullet.rectangle"
        case .files: "folder"
        case .browser: "globe"
        }
    }

    var help: String {
        switch self {
        case .inspector: "Summary: setup, what it read and changed, and the plan (⌘I)"
        case .files: "Files: the project, with what it touched (⌘P)"
        case .browser: "Browser: the pages this session opened, and yours"
        }
    }
}

/// A row that tints on hover.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverRow(configuration: configuration) }

    private struct HoverRow: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(hovering ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                .onHover { hovering = $0 }
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

// MARK: Approvals and questions (docs/design/grey 11c, 11d; docs/spec/05-build §6, AP1)

/// In the composer's tray (docs/design/grey "Composer tray"), the card has no box of its own and the composer is its
/// text field: Deny and Keep planning take what you typed there, and questions have no "Something else…" row.
struct PromptTrayContext {
    /// What's typed in the composer, trimmed; taking it empties the composer.
    var takeReply: () -> String?
    /// Puts the cursor in the composer.
    var focusReply: () -> Void
    /// The pager and the collapse button, at the end of the title row.
    var accessory: AnyView
}

struct PromptCard: View {
    let session: ThreadModel
    let prompt: PendingPrompt
    /// The first card answers ⌘↩.
    let primary: Bool
    var step: String?
    var tray: PromptTrayContext?
    @State private var denying = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if prompt.kind == .plan { planBar } else { card }
        }
        .modifier(PromptShell(inTray: tray != nil))
    }

    /// Plans are read in the transcript (docs/spec/09 P1); above the composer, only a bar with the answers and ⌘↩.
    private var planBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                Text("Build this plan?").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
                Text(prompt.title.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
                Spacer(minLength: 8)
                tray?.accessory
            }
            if denying {
                denyField(placeholder: "What should change in the plan?", send: "Send")
            } else {
                HStack(spacing: 14) {
                    Button("Keep planning") { keepPlanning() }.buttonStyle(PillStyle(compact: true))
                        .help(tray != nil ? "Sends what you typed below as the change to make, or puts the cursor there" : "")
                    Button("Edit") { session.editingPlan = prompt }.buttonStyle(PillStyle(compact: true))
                    Spacer()
                    Button { answer(PromptResponse(decision: .allow)) } label: { Text(primary ? "Approve and build ⌘↩" : "Approve and build") }
                        .buttonStyle(PillStyle(kind: .primary, compact: true))
                        .keyboardShortcut(primary ? KeyboardShortcut(.return, modifiers: .command) : nil)
                }
            }
        }
        .onChange(of: session.revisingPlan) { _, id in
            if id == prompt.id { session.revisingPlan = nil; if let tray { tray.focusReply() } else { denying = true } }
        }
    }

    /// In the tray, what you typed below is the change to make; with nothing typed, the cursor goes there.
    private func keepPlanning() {
        guard let tray else { denying = true; return }
        if let reply = tray.takeReply() { answer(PromptResponse(decision: .deny, text: reply)) } else { tray.focusReply() }
    }

    /// Approvals and questions (docs/design/grey 11c, 11d): a blue dot and the question, its context on the right,
    /// what will happen, then the secondary actions as text and one black answer on the right.
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2.5 }
                Text(heading).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let step { Text(step).font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                else if let counts = diffCounts { DiffCounts(added: counts.added, removed: counts.removed) }
                else if let tool = prompt.tool { Text(tool).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1) }
                tray?.accessory
            }
            if let message = prompt.message {
                Text(message).font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            }
            if let detail = prompt.detail, !detail.isEmpty {
                if diffCounts != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(detail.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line).font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(line.hasPrefix("-") ? Color.dsFg2 : Color.dsFg)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16).padding(.vertical, 1)
                                    .background(line.hasPrefix("+") ? Color(nsColor: DS.addbg) : line.hasPrefix("-") ? Color(nsColor: DS.delbg) : .clear)
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, -16)
                } else {
                    ScrollView {
                        Text(detail).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color.dsFg).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let reason = prompt.reason {
                Text("Always asks: \(reason.prefix(1).lowercased() + reason.dropFirst())").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            actions
        }
    }

    /// An edit's detail is a patch: how many lines it adds and removes.
    private var diffCounts: (added: Int, removed: Int)? {
        guard prompt.kind == .approval, let lines = prompt.detail?.components(separatedBy: "\n") else { return nil }
        let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count, removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        return added + removed > 0 && lines.count > 1 ? (added, removed) : nil
    }

    private var heading: String { prompt.question }

    @ViewBuilder private var actions: some View {
        switch prompt.kind {
        case .approval: approvalActions
        case .question, .select: choiceActions
        case .confirm:
            HStack(spacing: 14) {
                Button("Cancel") { answer(PromptResponse(confirmed: false)) }.buttonStyle(PillStyle(compact: true))
                Spacer()
                Button(primary ? "Confirm ⌘↩" : "Confirm") { answer(PromptResponse(confirmed: true)) }.buttonStyle(PillStyle(kind: .primary, compact: true))
                    .keyboardShortcut(primary ? KeyboardShortcut(.return, modifiers: .command) : nil)
            }
        case .input:
            if tray != nil { Text("Type your answer below and press ↩").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
            else { freeAnswer(placeholder: prompt.placeholder ?? "Your answer") }
        case .plan: EmptyView() // plans answer from the plan bar
        }
    }

    @ViewBuilder private var approvalActions: some View {
        if denying {
            denyField(placeholder: "Tell the agent why, or what to do instead (optional)", send: "Deny")
        } else {
            HStack(spacing: 14) {
                Button("Deny") { deny() }.buttonStyle(PillStyle(compact: true))
                    .help(tray != nil ? "Denies it; what you typed below goes to the agent as the reason" : "")
                if let rule = prompt.rule {
                    Button(Self.alwaysLabel(rule)) { answer(PromptResponse(decision: .always)) }
                        .buttonStyle(PillStyle(compact: true))
                        .help("Adds a rule to this project (Settings › Approvals)")
                }
                Spacer()
                Button { answer(PromptResponse(decision: .allow)) } label: { Text(primary ? "Allow ⌘↩" : "Allow") }
                    .buttonStyle(PillStyle(kind: .primary, compact: true))
                    .keyboardShortcut(primary ? KeyboardShortcut(.return, modifiers: .command) : nil)
            }
        }
    }

    /// In the tray, Deny goes at once, with what you typed below as the reason; on a card, it asks for the reason first.
    private func deny() {
        guard let tray else { denying = true; return }
        answer(PromptResponse(decision: .deny, text: tray.takeReply()))
    }

    private func denyField(placeholder: String, send label: String) -> some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { answer(PromptResponse(decision: .deny, text: note)) }
                .onAppear { focused = true }
            Button("Cancel") { denying = false; text = "" }.buttonStyle(PillStyle(compact: true))
            Button(label) { answer(PromptResponse(decision: .deny, text: note)) }.buttonStyle(PillStyle(kind: .primary, compact: true))
        }
    }

    /// The options as numbered rows (the number keys pick them while the composer is empty), then "Something else…",
    /// and Skip for the agent to go on without an answer.
    @ViewBuilder private var choiceActions: some View {
        let options = prompt.options ?? []
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                Button { answer(PromptResponse(choice: option)) } label: { OptionRow(number: i + 1, text: option) }
                    .buttonStyle(.plain)
            }
            if prompt.kind == .question, tray == nil {
                HStack(spacing: 10) {
                    if !options.isEmpty { KeyBadge(text: "\(options.count + 1)") }
                    TextField(options.isEmpty ? "Your answer" : "Something else…", text: $text)
                        .textFieldStyle(.plain).font(.system(size: 13.5)).onSubmit { send() }
                    if note != nil { Button("Send") { send() }.buttonStyle(PillStyle(kind: .primary, compact: true)) }
                }
                .padding(.horizontal, 6).frame(minHeight: 34)
            }
        }
        .padding(.horizontal, -6)
        if prompt.kind == .question {
            HStack(spacing: 12) {
                Button("Skip") { answer(PromptResponse(text: "Skipped")) }.buttonStyle(PillStyle(compact: true))
                if options.count > 1 { Text("1–\(options.count) to pick").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                Spacer()
            }
            .padding(.horizontal, -4)
        }
    }

    private func freeAnswer(placeholder: String) -> some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .onSubmit { send() }
            Button("Send") { send() }.buttonStyle(PillStyle(kind: .primary, compact: true)).disabled(note == nil)
        }
    }

    private var note: String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func send() {
        guard let note else { return }
        answer(PromptResponse(text: note))
    }

    private func answer(_ response: PromptResponse) {
        Task { await session.respond(prompt, response) }
    }

    static func alwaysLabel(_ rule: PendingPrompt.SuggestedRule) -> String {
        switch rule.kind {
        case .command: "Always allow \(rule.pattern)"
        case .tool: "Always allow \(rule.pattern)"
        case .path: "Allow edits in \(URL(fileURLWithPath: String(rule.pattern.dropLast(3))).lastPathComponent)"
        }
    }
}

/// "+2 −1" for a patch.
struct DiffCounts: View {
    let added: Int
    let removed: Int
    var body: some View {
        HStack(spacing: 6) {
            if added > 0 { Text("+\(added)").foregroundStyle(Color.dsGreen) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Color.dsRed) }
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

/// A question's option: a key badge and the answer, a grey fill on hover.
private struct OptionRow: View {
    let number: Int
    let text: String
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            KeyBadge(text: "\(number)")
            Text(text).font(.system(size: 13.5)).foregroundStyle(Color.dsFg).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
        .background(hovering ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// An 18pt key badge: a number in a hairline square.
struct KeyBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Color.dsFg2)
            .frame(width: 18, height: 18)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.dsLine, lineWidth: 1))
    }
}

/// A card on its own (Needs you) gets the ask card; in the composer's tray, only the padding.
private struct PromptShell: ViewModifier {
    let inTray: Bool
    func body(content: Content) -> some View {
        if inTray { content.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading) }
        else { content.askCard() }
    }
}

extension PendingPrompt {
    /// Whether what you type in the composer answers it: the reason for a denial, your own answer, what to change in
    /// a plan. A pick from a list or a yes/no can't take words, so the composer stays a composer for those.
    var takesReply: Bool { kind == .approval || kind == .question || kind == .input || kind == .plan }

    /// The composer's placeholder while it waits on this.
    var replyPlaceholder: String {
        switch kind {
        case .approval: "Or tell it what to do instead…"
        case .question: options?.isEmpty == false ? "Or type your own answer…" : "Your answer…"
        case .input: placeholder.map { $0.hasSuffix("…") ? $0 : $0 + "…" } ?? "Your answer…"
        case .plan: "Or say what to change in the plan…"
        case .select, .confirm: "Reply…"
        }
    }

    /// The one answer the collapsed tray offers (⌘↩), when there is one.
    var quickAnswer: (label: String, response: PromptResponse)? {
        switch kind {
        case .approval: ("Allow", PromptResponse(decision: .allow))
        case .plan: ("Approve and build", PromptResponse(decision: .allow))
        case .confirm: ("Confirm", PromptResponse(confirmed: true))
        case .question, .select, .input: nil
        }
    }

    /// One line for the collapsed tray: the question, then the command or the first line of what it's about.
    var oneLine: (question: String, detail: String?) {
        let lines = (detail ?? "").split(separator: "\n").map(String.init)
        let isPatch = lines.count > 1 && lines.contains { $0.hasPrefix("+") || $0.hasPrefix("-") }
        return (question, kind == .approval && !isPatch ? lines.first : nil)
    }
}

extension View {
    /// The card for things that need you (approvals, questions): field fill, a 0.5pt hairline, radius 12, 14×16.
    func askCard() -> some View {
        self
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }
}

/// Wraps its items onto as many lines as needed; an item wider than a line gets the line's width.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = Self.size(subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = Self.size(subviews[index], width: width)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = ([], 0, 0)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    /// Its ideal size, or its size wrapped to the line's width when it wouldn't fit on one.
    private static func size(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}

/// The session's approval mode (toolbar pill, docs/design 2a "Ask before edits").
struct ApprovalModeMenu: View {
    let engine: EngineController
    let session: ThreadModel
    let project: ProjectInfo?

    var body: some View {
        Menu {
            ForEach(ApprovalMode.allCases) { mode in
                Button {
                    Task { await session.setApprovalMode(mode) }
                } label: {
                    Text(Self.title(mode) + (mode == session.approvalMode ? "  ✓" : ""))
                    Text(Self.summary(mode))
                }
            }
            if let project, project.approvalMode != session.approvalMode {
                Divider()
                Button("Use “\(Self.title(session.approvalMode))” for new sessions in \(project.name)") {
                    Task { await engine.setApprovalMode(session.approvalMode, for: project) }
                }
            }
        } label: {
            Text(Self.title(session.approvalMode)).font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(PillStyle(kind: .toolbar))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Self.summary(session.approvalMode))
    }

    static func title(_ mode: ApprovalMode) -> String { mode.title }
    static func summary(_ mode: ApprovalMode) -> String { mode.summary }
}

extension CheckpointItem: @retroactive Identifiable {}

extension PendingPrompt {
    /// The title phrased as a question: "Run this command?", "Write a file?", or what the agent asks.
    var question: String {
        switch kind {
        case .approval:
            if title == "Run a command" || title.isEmpty { return "Run this command?" }
            return title.hasSuffix("?") ? title : title + "?"
        case .question, .confirm, .select, .input: return title
        case .plan: return "Build this plan?"
        }
    }
}

extension Notification.Name {
    /// Object: a session id. Opens its diff review (automation).
    static let showReview = Notification.Name("piopio.showReview")
    /// Object: a project id. Opens the new session sheet (7a).
    static let newBuildSession = Notification.Name("piopio.newBuildSession")
    /// Object: a session id. Opens its commit sheet (automation).
    static let showCommit = Notification.Name("piopio.showCommit")
}

/// The project has its own pi resources (.pi extensions, MCP servers, settings, prompts or skills) and no trust
/// decision yet: they don't load until you trust it. The decision is pi's, so the pi CLI uses it too.
struct TrustBanner: View {
    let engine: EngineController
    let project: ProjectInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield").foregroundStyle(Color.dsAmber)
            Text("**\(project.name)** has its own pi setup in .pi (extensions, MCP servers, prompts or skills). It loads only if you trust the project; extensions run code on your Mac.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.dsFg)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Don't Trust") { Task { await engine.setTrust(false, for: project) } }.buttonStyle(PillStyle(compact: true))
            Button("Trust Project") { Task { await engine.setTrust(true, for: project) } }.buttonStyle(PillStyle(kind: .strong, compact: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.dsAmber.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.dsAmber.opacity(0.35), lineWidth: 0.5))
        .help("Applies to sessions you start or reopen from now on.")
    }
}

/// Edit a plan before approving it (docs/spec/09 P3): the summary, then the steps — change, reorder, remove, add.
/// Approving sends your version; the agent builds it instead of its own.
struct PlanEditorSheet: View {
    let session: ThreadModel
    let prompt: PendingPrompt
    @State private var summary = ""
    @State private var steps: [Step] = []
    @Environment(\.dismiss) private var dismiss

    struct Step: Identifiable, Hashable { let id = UUID(); var text: String }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit the plan").font(.system(size: 17, weight: .bold))
            Text("Change the steps, drag to reorder, remove what you don't want. The agent builds your version.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Summary").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                TextField("What it will do", text: $summary, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
            }
            Text("Steps").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
            List {
                ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Color.accentColor)
                            .frame(width: 20, height: 20).background(Circle().fill(Color.dsAccentSoft))
                        TextField("Step", text: binding(step.id), axis: .vertical).textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                        Button { steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus.circle").foregroundStyle(Color.dsFg3) }
                            .buttonStyle(.plain).help("Remove this step")
                    }
                    .padding(.vertical, 3)
                }
                .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(minHeight: 180, maxHeight: 320)
            Button { steps.append(Step(text: "")) } label: { Label("Add a step", systemImage: "plus") }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
            HStack {
                Button("Revert") { load() }.buttonStyle(PillStyle()).help("Back to the agent's plan")
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button("Approve and build") { approve() }
                    .buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(cleaned.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private var cleaned: [String] { steps.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }

    private func binding(_ id: UUID) -> Binding<String> {
        Binding(get: { steps.first { $0.id == id }?.text ?? "" }, set: { value in
            if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].text = value }
        })
    }

    private func load() {
        summary = prompt.title
        steps = (prompt.steps ?? []).map { Step(text: $0) }
    }

    private func approve() {
        let response = PromptResponse(decision: .allow, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), steps: cleaned)
        Task { await session.respond(prompt, response) }
        dismiss()
    }
}

extension Notification.Name {
    /// Object: a path relative to the session's folder, shown in the file preview.
    static let previewFile = Notification.Name("piopio.previewFile")
}
