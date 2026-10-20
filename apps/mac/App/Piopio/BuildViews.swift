import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI
import UniformTypeIdentifiers

// Build mode (docs/spec/05-build, docs/design 2a): projects with their sessions in the sidebar, and a
// session view with tool cards. Approvals, checkpoints, the inspector and git arrive in milestones 2.2–2.4.

/// Sidebar: Projects (folders) with nested sessions, newest first.
struct BuildSidebarList: View {
    let engine: EngineController
    @Binding var selection: String?
    @State private var collapsed: Set<String> = []
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""

    var body: some View {
        HStack {
            SectionLabel("Projects")
            Spacer()
            Button { BuildActions.addProject(engine: engine) { selection = $0 } } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            .buttonStyle(.plain)
            .help("Add a project folder (⌘O)")
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        if engine.projects.isEmpty {
            Text("Folders you open appear here.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.horizontal, 8)
        }
        ForEach(engine.projects) { project in
            projectRow(project)
            if !collapsed.contains(project.id) {
                ForEach(engine.sessions(in: project), id: \.ref.id) { session in
                    sessionRow(session)
                }
            }
        }
        Button { BuildActions.addProject(engine: engine) { selection = $0 } } label: {
            Label("Add project", systemImage: "plus").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let session = renaming { Task { await engine.rename(session.ref, to: newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func projectRow(_ project: ProjectInfo) -> some View {
        let open = !collapsed.contains(project.id)
        let hasSelection = engine.sessions(in: project).contains { $0.ref.id == selection }
        return Button {
            if open { collapsed.insert(project.id) } else { collapsed.remove(project.id) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.dsFg3)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(hasSelection ? Color.accentColor : Color.dsFg3.opacity(0.55))
                    .frame(width: 14, height: 11)
                Text(project.name).font(.system(size: 13, weight: .medium)).foregroundStyle(project.missing == true ? Color.dsFg3 : Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                if project.missing == true {
                    Text("missing").font(.system(size: 11)).foregroundStyle(Color.dsRed)
                } else if open, let branch = project.branch {
                    Text(branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1)
                } else if !open {
                    let count = engine.sessions(in: project).count
                    if count > 0 { Text("\(count)").font(.system(size: 11)).foregroundStyle(Color.dsFg3).monospacedDigit() }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("New Session") { Task { if let ref = await engine.createBuildSession(in: project) { selection = ref.id } } }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
            Divider()
            Button("Remove from Piopio") {
                if engine.sessions(in: project).contains(where: { $0.ref.id == selection }) { selection = nil }
                Task { await engine.removeProject(project) }
            }
        }
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        let selected = selection == session.ref.id
        return Button { selection = session.ref.id } label: {
            HStack(spacing: 8) {
                StatusDot(status: dot(session), size: 6).frame(width: 10)
                Text(session.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(Color.dsFg)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(selected ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") {
                newTitle = session.title
                renaming = session
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                if selection == session.ref.id { selection = nil }
                Task { await engine.delete(session.ref) }
            }
        }
    }

    /// amber = waiting on you, spinner = running, red = failed, grey = idle (docs/design 2a).
    private func dot(_ session: SessionSummary) -> StatusDot.Status {
        switch engine.liveStatus[session.ref.id] {
        case .running?: .running
        case .waitingApproval?: .waiting
        case .error?: .failed
        default: .idle
        }
    }
}

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
        guard let project = await engine.addProject(url) else { return }
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

    @AppStorage("buildInspector") private var showInspector = true
    @State private var reviewing = false
    @State private var reviewFile: String?

    private var project: ProjectInfo? { engine.projects.first { $0.path == summary.cwd } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if reviewing {
                    DiffReview(session: session, selected: reviewFile) { reviewing = false }
                } else {
                    conversation
                }
            }
            if showInspector && !reviewing {
                BuildInspector(session: session) { file in
                    reviewFile = file
                    reviewing = true
                }
                .frame(width: 290)
                .glassPanel()
                .padding(8)
            }
        }
        .task { await session.open() }
        .onChange(of: session.prompts.isEmpty) { _, empty in if empty { session.document.bottomInset = 150 } }
        .onReceive(NotificationCenter.default.publisher(for: .showReview)) { note in
            if note.object as? String == session.ref.id { reviewing = true }
        }
        .sheet(item: Binding(get: { session.restoring }, set: { session.restoring = $0 })) { checkpoint in
            RestoreSheet(session: session, checkpoint: checkpoint)
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
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            Spacer(minLength: 12)
            ApprovalModeMenu(engine: engine, session: session, project: project)
            if let branch = project?.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12, design: .monospaced))
                    .labelStyle(BranchLabelStyle())
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.dsPill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 0.5))
                    .help("Current branch of \(project?.name ?? "the project")")
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
            .help(showInspector ? "Hide the inspector" : "Show changes, checkpoints and context")
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 60)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var subtitle: String {
        var parts = [project?.name ?? URL(fileURLWithPath: summary.cwd ?? "").lastPathComponent]
        parts.append("started \(Self.relative(summary.createdAt))")
        if let usage = session.state?.usage, usage.costUsd > 0 {
            parts.append(usage.costUsd < 0.01 ? String(format: "$%.4f", usage.costUsd) : String(format: "$%.2f", usage.costUsd))
        }
        if session.state?.status == .running { parts.append("working…") }
        if session.state?.status == .waitingApproval { parts.append("waiting for you") }
        return parts.joined(separator: " · ")
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

private struct BranchLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 10, weight: .medium)).foregroundStyle(Color.dsFg3)
            configuration.title.lineLimit(1)
        }
    }
}

/// Build with no session selected: open a folder (button, ⌘O or drop), or start a session in a project.
struct BuildEmptyState: View {
    let engine: EngineController
    @Binding var selection: String?
    @State private var targeted = false

    var body: some View {
        EmptyState(label: "Build", title: engine.projects.isEmpty ? "Open a folder to start building" : "Pick a session, or start one", message: "Each folder becomes a Project. Sessions run with pi-coding-agent inside it, and sessions you start with the pi CLI show up here too.") {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    Text("Drop a folder here").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                    Button("Open Folder… ⌘O") { BuildActions.addProject(engine: engine) { selection = $0 } }
                        .buttonStyle(PillStyle(kind: .primary))
                }
                .frame(width: 360, height: 110)
                .background(targeted ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(targeted ? Color.dsAccentLine : Color.dsLine, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in await BuildActions.add(url, engine: engine) { selection = $0 } }
                    }
                    return true
                }
                if !engine.projects.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(engine.projects.prefix(4)) { project in
                            Button("New session in \(project.name)") {
                                Task { if let ref = await engine.createBuildSession(in: project) { selection = ref.id } }
                            }
                            .buttonStyle(PillStyle())
                        }
                    }
                }
            }
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
                    Button(option) { answer(PromptResponse(choice: option)) }.buttonStyle(PillStyle(kind: .secondary))
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

/// Wraps its items onto as many lines as needed.
private struct FlowRow<Item: Hashable, Content: View>: View {
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

private struct FlowLayout: Layout {
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
                let size = subviews[index].sizeThatFits(.unspecified)
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
            let size = subviews[index].sizeThatFits(.unspecified)
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
}
