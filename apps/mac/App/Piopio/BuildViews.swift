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

    @AppStorage("buildInspector") private var showInspector = true
    @AppStorage("inspectorTab") private var inspectorTab = ChatInspectorTab.changes
    @State private var previewing: String?
    @State private var reviewing = false
    @State private var reviewFile: String?
    @State private var git: GitModel?
    @State private var committing = false
    @AppStorage("buildTerminal") private var showTerminal = false

    private var project: ProjectInfo? { engine.projects.first { $0.path == summary.cwd } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if let notice = git?.notice {
                    Text(notice.text).font(.system(size: 12)).foregroundStyle(notice.failed ? Color.dsRed : Color.dsFg2)
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
                    DiffReview(session: session, selected: reviewFile) { reviewing = false }
                } else {
                    conversation
                }
                if showTerminal, !chatLens, let cwd = summary.cwd {
                    TerminalDrawer(cwd: cwd, session: session) { showTerminal = false }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
            if chatLens, !reviewing, let path = previewing, let cwd = summary.cwd {
                FilePreview(engine: engine, cwd: cwd, path: path, session: session) { previewing = nil }
                    .frame(width: 440)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(Color.dsLine, lineWidth: 0.5))
                    .padding(.vertical, 8)
            }
            if showInspector && !reviewing {
                VStack(spacing: 0) {
                    do {
                        Picker("", selection: $inspectorTab) {
                            ForEach(ChatInspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                    }
                    if inspectorTab == .files, let cwd = summary.cwd {
                        FileBrowser(engine: engine, cwd: cwd, selected: $previewing)
                    } else {
                        BuildInspector(session: session, commit: !chatLens && git?.status?.repo == true && (git?.changedCount ?? 0) > 0 ? { committing = true } : nil) { file in
                            reviewFile = file
                            reviewing = true
                        }
                    }
                }
                .frame(width: chatLens ? 260 : 290)
                .glassPanel()
                .padding(8)
            }
        }
        .task { await session.open() }
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
        .background {
            Button("") { if !chatLens { showTerminal.toggle() } }.keyboardShortcut("`", modifiers: .control).hidden()
        }
        .onChange(of: session.prompts.isEmpty) { _, empty in if empty { session.document.bottomInset = 150 } }
        .onReceive(NotificationCenter.default.publisher(for: .showCommit)) { note in
            if note.object as? String == session.ref.id { committing = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .previewFile)) { note in
            if chatLens, let path = note.object as? String { previewing = path }
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
                VStack(spacing: 8) {
                    if !session.isFollowing {
                        Button { session.scrollToLatest() } label: {
                            Label("Jump to latest", systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(PillStyle(kind: .toolbar, compact: true))
                    }
                    if !session.prompts.isEmpty {
                        PromptStack(session: session)
                            .frame(maxWidth: 636)
                            .padding(.horizontal, 24)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                session.document.bottomInset = 150 + height + 8
                            }
                    }
                    if session.state?.status != .running, session.prompts.isEmpty, let followUps = summary.followUps, !followUps.isEmpty {
                        FollowUps(items: followUps, label: nil) { text in Task { await session.send(text) } }
                            .frame(maxWidth: 636).padding(.horizontal, 24)
                    }
                    Composer(engine: engine, thread: session)
                        .frame(maxWidth: 636)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }
            }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                subtitle.font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button { session.showTree = true } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(PillStyle(kind: .toolbar))
            .help("Session tree: go back to an earlier message (/tree)")
            .popover(isPresented: Binding(get: { session.showTree }, set: { session.showTree = $0 }), arrowEdge: .bottom) {
                SessionTreePopover(session: session)
            }
            ApprovalModeMenu(engine: engine, session: session, project: project)
            if !chatLens {
                if let git { GitMenu(git: git, engine: engine, summary: summary, committing: $committing) }
                if let cwd = summary.cwd { OpenInEditorMenu(path: cwd) }
                Button { showTerminal.toggle() } label: {
                    Image(systemName: "terminal").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(PillStyle(kind: .toolbar))
                .help(showTerminal ? "Hide the terminal (⌃`)" : "Terminal in this folder (⌃`)")
            }
            if let cwd = summary.cwd {
                Menu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) }
                    Button("Open in Terminal") { openTerminal(cwd) }
                    Divider()
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cwd, forType: .string)
                    }
                } label: {
                    Image(systemName: "folder").font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(PillStyle(kind: .toolbar))
                .menuIndicator(.hidden)
                .fixedSize()
                .help(cwd)
            }
            Button { withAnimation(.easeOut(duration: 0.15)) { showInspector.toggle() } } label: {
                Image(systemName: "sidebar.right").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(PillStyle(kind: .toolbar))
            .help(showInspector ? "Hide the inspector" : chatLens ? "Show the files and changes" : "Show changes, checkpoints and context")
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 60)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    /// "financial_ia · main · ● Done · $0.0011" (docs/design v2, 2a).
    private var subtitle: Text {
        var parts = [project?.name ?? URL(fileURLWithPath: summary.cwd ?? "").lastPathComponent]
        if let branch = summary.worktree?.branch ?? project?.branch { parts.append(branch) }
        let (state, color): (String, Color) = switch session.state?.status {
        case .running?: ("Working", .accentColor)
        case .waitingApproval?: ("Needs you", .dsAmber)
        case .error?: ("Failed", .dsRed)
        default: ("Done", .dsGreen)
        }
        var tail: [String] = []
        if let usage = session.state?.usage, usage.costUsd > 0 {
            tail.append(usage.costUsd < 0.01 ? String(format: "$%.4f", usage.costUsd) : String(format: "$%.2f", usage.costUsd))
        }
        if session.planMode { tail.append("plan mode") }
        return Text(parts.joined(separator: " · ") + " · ") + Text("● \(state)").foregroundColor(color) + Text(tail.isEmpty ? "" : " · " + tail.joined(separator: " · "))
    }

    static func relative(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func openTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}


enum ChatInspectorTab: String, CaseIterable {
    case changes = "Changes"
    case files = "Files"
}

/// Build with no session selected (docs/design 5c, 7a). With no project yet: open a folder (button, ⌘O or drop).
/// With projects: what to build first (a prompt, the project, Start ⌘↩), then recent sessions to pick up again.
struct BuildEmptyState: View {
    let engine: EngineController
    @Binding var selection: String?
    @State private var targeted = false
    @State private var prompt = ""
    @State private var projectId: String?
    @FocusState private var focused: Bool

    private var projects: [ProjectInfo] { engine.projects(in: .build) }

    var body: some View {
        Group {
            if projects.isEmpty { firstFolder } else { start }
        }
        .background(targeted ? Color.dsAccentSoft.opacity(0.4) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await BuildActions.add(url, engine: engine) { selection = $0 } }
            }
            return true
        }
    }

    private var firstFolder: some View {
        EmptyState(label: "Build", title: "Open a folder to start building", message: "Each folder becomes a Project. Sessions run with pi-coding-agent inside it, and sessions you start with the pi CLI show up here too.") {
            VStack(spacing: 10) {
                Text("Drop a folder here").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                Button("Open Folder… ⌘O") { BuildActions.addProject(engine: engine) { selection = $0 } }
                    .buttonStyle(PillStyle(kind: .primary))
            }
            .frame(width: 360, height: 110)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(targeted ? Color.dsAccentLine : Color.dsLine, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }

    private var project: ProjectInfo? { projects.first { $0.id == projectId } ?? projects.first }

    private var start: some View {
        GeometryReader { geo in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("BUILD").font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(Color.dsFg3)
                Text("What do you want to build?").font(.system(size: 22, weight: .bold)).foregroundStyle(Color.dsFg).padding(.top, 6)
                Text("Describe a task; a session starts in the project, on its current branch or a new one.").font(.system(size: 13)).foregroundStyle(Color.dsFg2).padding(.top, 4)
                promptCard.padding(.top, 18)
                let recent = Array(engine.buildSessions.filter { $0.parent == nil }.sorted { $0.updatedAt > $1.updatedAt }.prefix(6))
                if !recent.isEmpty {
                    Text("RECENT").font(.system(size: 10.5, weight: .semibold)).tracking(0.4).foregroundStyle(Color.dsFg3).padding(.top, 28).padding(.bottom, 6)
                    VStack(spacing: 2) { ForEach(recent, id: \.ref.id) { recentRow($0) } }
                }
                HStack(spacing: 4) {
                    Button("Open another folder… ⌘O") { BuildActions.addProject(engine: engine) { selection = $0 } }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    Text("or drop one anywhere here").foregroundStyle(Color.dsFg3)
                }
                .font(.system(size: 12))
                .padding(.top, 22)
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, minHeight: geo.size.height * 0.85)
        }
        }
        .onAppear { focused = true }
    }

    /// docs/design 7a: the prompt first, with an accent halo while focused.
    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Fix the flaky upload test, add a dark mode toggle, explain this codebase…")
                        .font(.system(size: 14)).foregroundStyle(Color.dsFg3).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(height: 76)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            HStack(spacing: 8) {
                Menu {
                    ForEach(projects) { p in
                        Button { projectId = p.id } label: {
                            if p.id == project?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text(project?.name ?? "Project")
                        if let branch = project?.branch { Text(branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3) }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(ChipStyle())
                .fixedSize()
                Spacer()
                Button {
                    begin()
                } label: {
                    Text("Start ⌘↩").font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(PillStyle(kind: .primary, compact: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(project == nil)
            }
            .padding(10)
        }
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(focused ? Color.dsAccentLine : Color.dsLine, lineWidth: focused ? 1 : 0.5))
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel + 4, style: .continuous).fill(focused ? Color.dsAccentSoft : .clear).padding(-4))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    /// The new session sheet, with this prompt (where branch, permissions and model are chosen).
    private func begin() {
        guard let project else { return }
        NotificationCenter.default.post(name: .newBuildSession, object: project.id, userInfo: ["prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines)])
        prompt = ""
    }

    private func recentRow(_ s: SessionSummary) -> some View {
        Button { selection = s.ref.id } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(Color.dsFg3).frame(width: 18)
                Text(s.title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                Spacer(minLength: 8)
                Text(projects.first { $0.path == (s.projectPath ?? s.cwd) }?.name ?? "").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
                Text(BuildSessionView.relative(s.updatedAt)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
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

// MARK: Approvals and questions (docs/design 2a approval card; docs/spec/05-build §6, AP1)

/// What the session waits on you for, stacked above the composer: always visible, even when scrolled up.
struct PromptStack: View {
    let session: ThreadModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(session.prompts.enumerated()), id: \.element.id) { index, prompt in
                PromptCard(session: session, prompt: prompt, primary: index == 0)
            }
        }
    }
}

struct PromptCard: View {
    let session: ThreadModel
    let prompt: PendingPrompt
    /// The first card answers ⌘↩.
    let primary: Bool
    @State private var denying = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if prompt.kind == .plan { planBar } else { card }
    }

    /// Plans are read in the transcript (docs/spec/09 P1); above the composer, only a bar with the answers and ⌘↩.
    private var planBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Color.dsAmber).frame(width: 7, height: 7)
                Text("Plan ready").font(.system(size: 13, weight: .semibold))
                Text("· " + prompt.title.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(1)
                Spacer(minLength: 8)
                if !denying {
                    Button("Keep planning…") { denying = true }.buttonStyle(PillStyle(compact: true))
                    Button("Edit…") { session.editingPlan = prompt }.buttonStyle(PillStyle(compact: true))
                    Button { answer(PromptResponse(decision: .allow)) } label: { Text(primary ? "Approve and build ⌘↩" : "Approve and build") }
                        .buttonStyle(PillStyle(kind: .primary, compact: true))
                        .keyboardShortcut(primary ? KeyboardShortcut(.return, modifiers: .command) : nil)
                }
            }
            if denying {
                HStack(spacing: 8) {
                    TextField("What should change in the plan?", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                        .focused($focused)
                        .onSubmit { answer(PromptResponse(decision: .deny, text: note)) }
                        .onAppear { focused = true }
                    Button("Cancel") { denying = false; text = "" }.buttonStyle(PillStyle(compact: true))
                    Button("Send") { answer(PromptResponse(decision: .deny, text: note)) }.buttonStyle(PillStyle(kind: .strong, compact: true))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsAccentLine, lineWidth: 1))
        .onChange(of: session.revisingPlan) { _, id in
            if id == prompt.id { denying = true; session.revisingPlan = nil }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(Color.dsAmber).frame(width: 7, height: 7)
                Text(heading).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
                Spacer()
                if let tool = prompt.tool { Text(tool).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
            }
            if prompt.kind != .approval {
                Text(prompt.title).font(.system(size: 13.5)).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true)
            }
            if let message = prompt.message {
                Text(message).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            }
            if let detail = prompt.detail, !detail.isEmpty {
                ScrollView {
                    Text(detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            }
            if let reason = prompt.reason {
                Text("Always asks: \(reason.prefix(1).lowercased() + reason.dropFirst())").font(.system(size: 12)).foregroundStyle(Color.dsAmber)
            }
            actions
        }
        .padding(14)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsAccentLine, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: DS.Radius.card + 4).fill(Color.dsAccentSoft).padding(-4))
    }

    private var heading: String {
        switch prompt.kind {
        case .approval: prompt.title == "Run a command" || prompt.title.isEmpty ? "Approval needed" : "Approval needed · \(prompt.title.prefix(1).lowercased() + prompt.title.dropFirst())"
        case .question: "The agent asks"
        case .confirm, .select, .input: "An extension asks"
        case .plan: "Plan ready"
        }
    }

    @ViewBuilder private var actions: some View {
        switch prompt.kind {
        case .approval: approvalActions
        case .question, .select: choiceActions
        case .confirm:
            HStack {
                Spacer()
                Button("Cancel") { answer(PromptResponse(confirmed: false)) }.buttonStyle(PillStyle())
                Button("Confirm") { answer(PromptResponse(confirmed: true)) }.buttonStyle(PillStyle(kind: .primary))
                    .keyboardShortcut(primary ? KeyboardShortcut(.return, modifiers: .command) : nil)
            }
        case .input: freeAnswer(placeholder: prompt.placeholder ?? "Your answer")
        case .plan: EmptyView() // plans answer from the plan bar
        }
    }

    @ViewBuilder private var approvalActions: some View {
        if denying {
            HStack(spacing: 8) {
                TextField("Tell the agent why, or what to do instead (optional)", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .onSubmit { answer(PromptResponse(decision: .deny, text: note)) }
                    .onAppear { focused = true }
                Button("Cancel") { denying = false; text = "" }.buttonStyle(PillStyle())
                Button("Deny") { answer(PromptResponse(decision: .deny, text: note)) }.buttonStyle(PillStyle(kind: .strong))
            }
        } else {
            HStack(spacing: 8) {
                Button("Deny") { denying = true }.buttonStyle(PillStyle())
                Spacer()
                if let rule = prompt.rule {
                    Button(Self.alwaysLabel(rule)) { answer(PromptResponse(decision: .always)) }
                        .buttonStyle(PillStyle())
                        .help("Adds a rule to this project (Settings › Approvals)")
                }
                Button { answer(PromptResponse(decision: .allow)) } label: { Text(primary ? "Allow once ⌘↩" : "Allow once") }
                    .buttonStyle(PillStyle(kind: .primary))
                    .keyboardShortcut(primary ? KeyboardShortcut(.return, modifiers: .command) : nil)
            }
        }
    }

    @ViewBuilder private var choiceActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let options = prompt.options, !options.isEmpty {
                FlowRow(options) { option in
                    Button(option) { answer(PromptResponse(choice: option)) }.buttonStyle(OptionStyle())
                }
            }
            if prompt.kind == .question { freeAnswer(placeholder: prompt.options?.isEmpty == false ? "Or answer in your own words" : "Your answer") }
        }
    }

    private func freeAnswer(placeholder: String) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
                .onSubmit { send() }
            Button("Send") { send() }.buttonStyle(PillStyle(kind: .primary)).disabled(note == nil)
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
        case .command: "Always for \(rule.pattern)"
        case .tool: "Always for \(rule.pattern)"
        case .path: "Always in \(URL(fileURLWithPath: String(rule.pattern.dropLast(3))).lastPathComponent)"
        }
    }
}

/// A question's answer: a capsule while it fits on one line; a long answer wraps inside a rounded box
/// no wider than the card instead of running past it.
private struct OptionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .foregroundStyle(Color.dsFg)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Wraps its items onto as many lines as needed; an item wider than a line gets the line's width.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: 6) { ForEach(items, id: \.self) { content($0) } }
    }
}

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

    static func title(_ mode: ApprovalMode) -> String {
        switch mode {
        case .ask: "Ask before edits"
        case .autoEdit: "Auto-edit"
        case .fullAuto: "Full auto"
        }
    }

    static func summary(_ mode: ApprovalMode) -> String {
        switch mode {
        case .ask: "Asks before every edit, command and web request. Reading is automatic."
        case .autoEdit: "Edits files on its own. Asks before commands you haven't allowed."
        case .fullAuto: "Doesn't ask, except for risky commands and writes outside the project."
        }
    }
}

extension CheckpointItem: @retroactive Identifiable {}

extension Notification.Name {
    /// Object: a session id. Opens its diff review (automation).
    static let showReview = Notification.Name("piopio.showReview")
    /// Object: a project id. Opens the new session sheet (7a).
    static let newBuildSession = Notification.Name("piopio.newBuildSession")
    /// Object: a session id. Opens its commit sheet (automation).
    static let showCommit = Notification.Name("piopio.showCommit")
}

/// pi's session tree as your messages (BR6). Picking one goes back to just before it and puts its text in the
/// composer, so sending starts a new branch; the old branch stays in the tree.
struct SessionTreePopover: View {
    let session: ThreadModel
    @State private var nodes: [TreeNode]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session tree").font(.system(size: 13, weight: .semibold))
            Text("Go back to one of your messages to try something else. The current path stays in the tree.")
                .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            if let nodes {
                if nodes.isEmpty { Text("No messages yet.").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(nodes) { node in
                            Button {
                                session.showTree = false
                                Task { await session.navigate(to: node) }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(node.current ? Color.accentColor : Color.dsFg3.opacity(0.5)).frame(width: 6, height: 6)
                                    Text(node.text).font(.system(size: 12.5)).foregroundStyle(node.current ? Color.dsFg : Color.dsFg2).lineLimit(1)
                                    Spacer(minLength: 6)
                                    if node.branches > 1 { Text("\(node.branches) branches").font(.system(size: 10.5)).foregroundStyle(Color.dsFg3) }
                                }
                                .padding(.leading, CGFloat(node.depth) * 14 + 6)
                                .padding(.trailing, 6)
                                .frame(height: 26)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(session.isRunning)
                        }
                    }
                }
                .frame(maxHeight: 360)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 380)
        .task { nodes = await session.tree() }
    }
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
