import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// The Inspector (docs/design/inspector, options 2a and 4a): Build's right-hand panel, one column (Setup, Tools,
// Skills, Read, Changes, Plan, Background (docs/spec/43); the Session and Changes tabs became one on 2026-11-15), and the footer every panel
// shares (context and cost, nowhere else).

/// The Inspector: its column and the shared footer. Whether Changes is open is kept per session.
struct InspectorPanel: View {
    let engine: EngineController
    let session: ThreadModel
    let summary: SessionSummary
    let project: ProjectInfo?
    let git: GitModel?
    let chatLens: Bool
    @Binding var committing: Bool
    let onReview: (String?) -> Void
    /// Read: a file it read or you mentioned, in the preview; "Show in Files", the Files panel on what it touched.
    let onOpenFile: (String) -> Void
    let onShowInFiles: () -> Void
    /// What the conversation left running and ran (docs/spec/43): the column's last block, nil when there's none.
    let background: BackgroundBlock?
    @State private var changesOpen: Bool
    @State private var files: [FileChange] = []

    init(engine: EngineController, session: ThreadModel, summary: SessionSummary, project: ProjectInfo?, git: GitModel?, chatLens: Bool,
         committing: Binding<Bool>, onReview: @escaping (String?) -> Void, onOpenFile: @escaping (String) -> Void,
         onShowInFiles: @escaping () -> Void, background: BackgroundBlock? = nil) {
        self.engine = engine; self.session = session; self.summary = summary; self.project = project; self.git = git
        self.chatLens = chatLens; self._committing = committing; self.onReview = onReview
        self.onOpenFile = onOpenFile; self.onShowInFiles = onShowInFiles
        self.background = background
        // PIOPIO_DEMO_INSPECTOR_CHANGES=1: captures open with Changes unfolded.
        let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_INSPECTOR_CHANGES"] == "1"
        _changesOpen = State(initialValue: demo || Self.remembered(summary.ref.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                SessionTab(engine: engine, session: session, summary: summary, project: project, git: git, chatLens: chatLens,
                           committing: $committing, files: files, changesOpen: $changesOpen, onReview: onReview, onOpenFile: onOpenFile,
                           onShowInFiles: onShowInFiles,
                           background: background)
                    .padding(.top, 4)
            }
            InspectorFooter(thread: session)
        }
        .task(id: session.revision / 4) { files = await session.changes(since: .session) } // events arrive in quick batches
        .onChange(of: session.state?.status) { _, _ in Task { files = await session.changes(since: .session) } }
        .onChange(of: changesOpen) { _, open in Self.remember(open, for: summary.ref.id) }
    }

    private static func remembered(_ id: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: "inspectorChangesOpen") as? [String: Bool])?[id] ?? false
    }

    private static func remember(_ open: Bool, for id: String) {
        var all = (UserDefaults.standard.dictionary(forKey: "inspectorChangesOpen") as? [String: Bool]) ?? [:]
        all[id] = open ? true : nil
        UserDefaults.standard.set(all, forKey: "inspectorChangesOpen")
    }
}

/// Every panel's footer (§4): how full the context is and what the session cost.
struct InspectorFooter: View {
    let thread: ThreadModel
    @State private var showingContext = false

    var body: some View {
        let cost = thread.state?.usage.costUsd ?? 0
        HStack(spacing: 8) {
            if let context = thread.state?.context {
                Button { showingContext.toggle() } label: {
                    HStack(spacing: 7) {
                        if let tokens = context.tokens {
                            let fraction = min(1, max(0, tokens / context.window))
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.dsTrack)
                                Capsule().fill(fraction >= 0.85 ? Color.dsFg : Color.dsFg2).frame(width: 32 * fraction)
                            }
                            .frame(width: 32, height: 3)
                        }
                        Text("\(context.tokens.map(ContextPopover.short) ?? "—") of \(ContextPopover.short(context.window))")
                            .monospacedDigit().lineLimit(1).fixedSize()
                        Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("View context breakdown")
                .accessibilityLabel("Context breakdown")
                .accessibilityValue(context.tokens.map { "\(ContextPopover.short($0)) of \(ContextPopover.short(context.window)) tokens" } ?? "Waiting for the next response")
                .popover(isPresented: $showingContext, arrowEdge: .bottom) { ContextPopover(thread: thread) }
            }
            Spacer(minLength: 8)
            Text(cost > 0 && cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost))
                .monospacedDigit().foregroundStyle(Color.dsFg)
                .help("What this conversation has cost")
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.dsFg3)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }
}

extension View {
    /// An Inspector block: 18 pt above and below, and a hairline under it unless it's the last.
    func inspectorBlock(last: Bool = false) -> some View {
        padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { if !last { Rectangle().fill(Color.dsLine).frame(height: 0.5) } }
    }
}

// MARK: Session

/// Setup, Tools and Skills, then what it read, what it changed (not in a chat's lens), then the plan (4a's order).
struct SessionTab: View {
    let engine: EngineController
    let session: ThreadModel
    let summary: SessionSummary
    let project: ProjectInfo?
    let git: GitModel?
    let chatLens: Bool
    @Binding var committing: Bool
    /// What the session changed since it started (committed or not).
    let files: [FileChange]
    @Binding var changesOpen: Bool
    let onReview: (String?) -> Void
    let onOpenFile: (String) -> Void
    let onShowInFiles: () -> Void
    var background: BackgroundBlock?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No plan, no Plan block (docs/design/plan-flow): then the block above it is the last. Background, when
            // there is any, is always the last (docs/spec/43 BG5).
            let plan = PlanBlock.shown(session) != nil
            let tail = plan || background != nil
            setup.inspectorBlock()
            ToolsBlock(engine: engine, thread: session, summary: summary).inspectorBlock()
            SkillsBlock(thread: session).inspectorBlock()
            ReadBlock(thread: session, cwd: summary.cwd, openFile: onOpenFile, showInFiles: onShowInFiles)
                .inspectorBlock(last: chatLens && !tail)
            if !chatLens {
                ChangesBlock(engine: engine, session: session, summary: summary, git: git, files: files,
                             commit: git?.status?.repo == true && (git?.changedCount ?? 0) > 0 ? { committing = true } : nil,
                             onReview: onReview, open: $changesOpen)
                    .inspectorBlock(last: !tail)
            }
            if plan { PlanBlock(session: session).inspectorBlock(last: background == nil) }
            if let background { background.inspectorBlock(last: true) }
        }
        .padding(.horizontal, 18)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setup").font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    label("Project")
                    projectValue
                }
                GridRow {
                    label("Runs on")
                    Text("This Mac").font(.system(size: 13))
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(width: 72, alignment: .leading)
    }

    /// "piopio · main ⌄": the folder (Reveal in Finder on click) and the branch, whose chevron is the git menu.
    private var projectValue: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            let name = project?.name ?? summary.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
            // Text, not a Button: a button's taller frame and baseline set this row lower than Runs on and Tools.
            Text(name).font(.system(size: 13)).lineLimit(1).help(summary.cwd ?? "")
                .onTapGesture { if let cwd = summary.cwd { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) } }
                .accessibilityAddTraits(.isButton).accessibilityHint("Reveal in Finder")
            if let git, git.status?.repo == true {
                Text("· \(git.status?.branch ?? summary.worktree?.branch ?? "HEAD")").font(.system(size: 13)).foregroundStyle(Color.dsFg3).lineLimit(1)
                // The menu's 28 pt button floats over a 1 pt line on the baseline, so the row is as tall as its text,
                // like Runs on and Tools.
                if !chatLens {
                    Color.clear.frame(width: 16, height: 1)
                        .overlay { GitMenu(git: git, engine: engine, summary: summary, committing: $committing, inRow: true).offset(y: -4) }
                }
            } else if summary.cwd != nil {
                Text("· no git").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Tools, a block of its own (docs/design/tools-panel, option A): folded, how many of its switches are on; open, at
/// full width, what this conversation can switch (only for itself): web search in chats, then apps and MCP servers.
/// Connected apps or servers that Settings keeps off aren't switches here: one grey line at the end names them. Skills
/// aren't switches, so they're a block of their own (SkillsBlock; docs/design/chat-summary).
struct ToolsBlock: View {
    let engine: EngineController
    let thread: ThreadModel
    let summary: SessionSummary
    /// Chats: web search is the first switch.
    var web = false
    @State private var servers: [McpServerInfo] = []
    /// PIOPIO_DEMO_TOOLS_OPEN=1: captures open with Tools unfolded.
    @State private var open = ProcessInfo.processInfo.environment["PIOPIO_DEMO_TOOLS_OPEN"] == "1"

    var body: some View {
        let choices = ToolChoices.compute(engine: engine, ref: summary.ref, servers: servers)
        let off = Set(summary.toolsOff ?? [])
        let switchable = choices.filter(\.available)
        let unavailable = choices.filter { !$0.available }
        let on = switchable.filter { !off.contains($0.id) }.count + (web && thread.webEnabled ? 1 : 0)
        let total = switchable.count + (web ? 1 : 0)
        VStack(alignment: .leading, spacing: 0) {
            if total == 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tools").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("None ·").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                    SummaryLink("Connect…") { ToolChoices.openSettings("Connectors") }
                        .help("Connect apps and MCP servers in Settings")
                }
            } else {
                BlockFold(title: "Tools", line: Self.line(on: on, of: total), open: $open,
                          help: open ? "Hide the tools" : "What it can use, and switches for this conversation")
                if open { list(switchable: switchable, unavailable: unavailable, off: off).padding(.top, 10) }
            }
        }
        .task(id: summary.ref.id) {
            servers = await ToolChoices.load(engine: engine, cwd: summary.ref.kind == .build ? summary.cwd : nil)
        }
    }

    private func list(switchable: [ToolChoice], unavailable: [ToolChoice], off: Set<String>) -> some View {
        let apps = switchable.filter { $0.group == .app }, mcp = switchable.filter { $0.group == .mcp }
        return VStack(alignment: .leading, spacing: 0) {
            if web {
                BlockSubheading("Web")
                HStack(spacing: 9) {
                    Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 18)
                    Text("Web search").font(.system(size: 13)).foregroundStyle(thread.webEnabled ? Color.dsFg : Color.dsFg2)
                    Spacer(minLength: 4)
                    Toggle("", isOn: Binding(get: { thread.webEnabled }, set: { on in Task { await thread.setWeb(on) } }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .accessibilityLabel("Web search in this conversation")
                }
                .frame(minHeight: 26)
            }
            if !apps.isEmpty {
                BlockSubheading("Apps")
                ForEach(apps) { ToolChoiceRow(choice: $0, off: off, thread: thread) }
            }
            if !mcp.isEmpty {
                BlockSubheading("MCP servers")
                ForEach(mcp) { ToolChoiceRow(choice: $0, off: off, thread: thread) }
            }
            HStack(spacing: 6) {
                Text("For this \(summary.ref.kind == .build ? "session" : "chat") only.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                SummaryLink("Settings…") { ToolChoices.openSettings("Connectors") }
            }
            .padding(.top, 10)
            if !unavailable.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.offInSettings(unavailable, chatMcpOff: web && !(engine.settings?.chat.mcp ?? false)))
                        .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                    SummaryLink("Turn on…") { ToolChoices.openSettings(unavailable.contains { $0.group == .app } ? "Connectors" : "MCP servers") }
                }
                .padding(.top, 4)
                .help(unavailable.compactMap(\.note).first ?? "")
            }
        }
    }

    /// "Sentry is off in Settings.", or, in a chat while Settings keeps MCP off for chats, "MCP servers are off for
    /// chats in Settings."
    static func offInSettings(_ unavailable: [ToolChoice], chatMcpOff: Bool) -> String {
        if chatMcpOff, unavailable.allSatisfy({ $0.group == .mcp }) { return "MCP servers are off for chats in Settings." }
        let names = unavailable.map(\.title)
        return "\(ListFormatter.localizedString(byJoining: names)) \(names.count == 1 ? "is" : "are") off in Settings."
    }

    /// "3 on", "2 of 3 on".
    static func line(on: Int, of total: Int) -> String { on == total ? "\(on) on" : "\(on) of \(total) on" }
}

/// Skills, a block of its own (docs/design/chat-summary): instructions the model loads by itself when a task needs
/// them, or that you call with / (pi's skills: SKILL.md folders in pi's and the shared agent skill folders, and in pi
/// packages). They aren't switches, so they don't share Tools' count. None: one line with Add…; otherwise a fold with
/// each one and what it's for.
struct SkillsBlock: View {
    let thread: ThreadModel
    @State private var skills: [SessionCommand] = []
    @State private var open = false

    private static let explanation = "Skills are instructions the model loads by itself when a task needs them, or that you call with / in the box. They come from skill folders on this Mac and from pi packages."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if skills.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Skills").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("None ·").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                    SummaryLink("Add…") { ToolChoices.openSettings("Extensions") }
                }
                .help(Self.explanation)
            } else {
                BlockFold(title: "Skills", line: skills.count == 1 ? "1 skill" : "\(skills.count) skills", open: $open,
                          help: open ? "Hide the skills" : Self.explanation)
                if open { list.padding(.top, 10) }
            }
        }
        .task(id: thread.ref.id) { skills = await thread.commands().filter { $0.kind == .skill } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(skills) { skill in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.name(skill)).font(.system(size: 13)).lineLimit(1)
                        if !skill.description.isEmpty {
                            Text(skill.description).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 4)
                .help("Type /\(skill.name) to use it\(skill.source.map { " · from \($0)" } ?? "")")
            }
            HStack(spacing: 6) {
                Text("Loaded when a task needs one, or with /.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                SummaryLink("Manage…") { ToolChoices.openSettings("Extensions") }
            }
            .padding(.top, 10)
        }
    }

    /// pi names skill commands "skill:<name>"; the block shows the name.
    static func name(_ skill: SessionCommand) -> String {
        skill.name.hasPrefix("skill:") ? String(skill.name.dropFirst(6)) : skill.name
    }
}

/// A block's head that folds: the bold title, then the answer in grey and a chevron on the right.
struct BlockFold: View {
    let title: String
    let line: String
    @Binding var open: Bool
    let help: String

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(line).font(.system(size: 13)).foregroundStyle(Color.dsFg3).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dsFg3)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

/// A grey heading inside an open block (Web, Apps, MCP servers; You gave, Pages).
struct BlockSubheading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 8).padding(.bottom, 2)
    }
}

/// The plan as a timeline (docs/design/plan-timeline, 1a in grey ink): a rail of markers joined by a line, done steps
/// checked in `fg3`, the current one ringed in ink with its detail open, the rest just their titles. Clicking a step
/// with a detail opens or closes it; the agent alone moves the plan along. Done shows every step checked, with how
/// long it took in the header.
///
/// One plan (docs/design/plan-flow): a plan mode proposal waiting for you shows here as "Proposed", in place of any
/// older list, with the same steps as the card in the transcript; one sent back reads "Revising…" while the agent
/// works on it; an approved one shows its steps until the agent writes its todo list, which is the plan from then on.
/// With none of these there is no Plan block at all (`shown` is nil).
struct PlanBlock: View {
    let session: ThreadModel
    /// Steps (by title) whose detail is flipped from its default: open for the current one, closed for the rest.
    @State private var flipped: Set<String> = []

    enum Shown { case todos([Todo]), proposed([Todo]), approved([Todo]), revising }

    @MainActor static func shown(_ session: ThreadModel) -> Shown? {
        if let latest = PlanContent.latest(in: session.document.items) {
            let steps = latest.plan.steps.map(Self.step)
            switch latest.plan.state {
            case .pending: return .proposed(steps)
            case .changes where session.isRunning: return .revising
            case .approved, .approvedEdited: if !latest.todosSince { return .approved(steps) }
            default: break
            }
        }
        return session.todos.isEmpty ? nil : .todos(session.todos)
    }

    /// A proposed step as a timeline row: its bold lead ("**PIO-7 Precios:** …") or first clause as the title, the
    /// whole step as the detail.
    static func step(_ text: String) -> Todo {
        let plain = PlanContent.plain(text).trimmingCharacters(in: .whitespacesAndNewlines)
        var title = plain
        if text.hasPrefix("**"), let close = text.dropFirst(2).range(of: "**") {
            title = String(text.dropFirst(2)[..<close.lowerBound])
        } else if let cut = plain.firstIndex(where: { ":—(".contains($0) }), plain.distance(from: plain.startIndex, to: cut) >= 8 {
            title = String(plain[..<cut])
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " :.,"))
        return Todo(text: title, detail: title == plain ? nil : plain, status: .pending)
    }

    var body: some View {
        if let shown = Self.shown(session) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Plan").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    trailing(shown)
                }
                switch shown {
                case .todos(let todos): timeline(todos)
                case .proposed(let steps), .approved(let steps): timeline(steps)
                case .revising:
                    Text("It's changing the plan as you asked.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.todos.map(\.status))
        }
    }

    @ViewBuilder private func trailing(_ shown: Shown) -> some View {
        switch shown {
        case .todos(let todos):
            Text(counter(todos)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
        case .proposed(let steps):
            HStack(spacing: 5) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                Text("Proposed · \(steps.count == 1 ? "1 step" : "\(steps.count) steps")").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            .help("Waiting for you: answer in the box below the conversation")
        case .approved(let steps):
            Text("0 of \(steps.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
        case .revising:
            Text("Revising…").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        }
    }

    /// "2 of 6"; "6 of 6 · 34 min" once it's done.
    private func counter(_ todos: [Todo]) -> String {
        let done = todos.filter { $0.status == .done }.count
        let base = "\(done) of \(todos.count)"
        guard done == todos.count, let duration = Self.duration(session.document.items) else { return base }
        return "\(base) · \(duration)"
    }

    private func timeline(_ todos: [Todo]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(todos.enumerated()), id: \.offset) { index, todo in
                step(todo, last: index == todos.count - 1)
            }
        }
    }

    private func isOpen(_ todo: Todo) -> Bool {
        guard todo.detail != nil else { return false }
        return (todo.status == .inProgress) != flipped.contains(todo.text)
    }

    /// The rail (marker, then the line down to the next step) beside the title and, when open, the detail.
    private func step(_ todo: Todo, last: Bool) -> some View {
        let open = isOpen(todo)
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                marker(todo.status).padding(.top, 1.5)
                if !last {
                    Rectangle()
                        .fill(todo.status == .done ? Color.dsFg3 : Color.dsFg3.opacity(0.28))
                        .frame(width: 1.5).frame(minHeight: 8, maxHeight: .infinity)
                }
            }
            .frame(width: 16)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(todo.text)
                        .font(.system(size: 13, weight: todo.status == .inProgress ? .semibold : .regular))
                        .foregroundStyle(todo.status == .done ? Color.dsFg3 : todo.status == .inProgress ? Color.dsFg : Color.dsFg2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if todo.status == .inProgress { Text("now").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                }
                if open, let detail = todo.detail {
                    Text(detail)
                        .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, last ? 0 : 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture {
            guard todo.detail != nil else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                if flipped.contains(todo.text) { flipped.remove(todo.text) } else { flipped.insert(todo.text) }
            }
        }
        .help(todo.detail.map { open ? "" : $0 } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityValue(todo.status == .done ? "Done" : todo.status == .inProgress ? "In progress" : "To do")
        .accessibilityHint(todo.detail == nil ? "" : open ? "Hides what this step covers" : "Shows what this step covers")
        .accessibilityAddTraits(todo.detail == nil ? [] : .isButton)
    }

    /// Done: a filled `fg3` disc with a check. Current: an ink ring. To do: a faint ring.
    @ViewBuilder private func marker(_ status: Todo.Status) -> some View {
        switch status {
        case .done:
            Circle().fill(Color.dsFg3).frame(width: 14, height: 14)
                .overlay { Image(systemName: "checkmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Color.dsWin) }
        case .inProgress:
            Circle().fill(Color.dsWin).overlay { Circle().strokeBorder(Color.dsFg, lineWidth: 2) }.frame(width: 14, height: 14)
        default:
            Circle().strokeBorder(Color.dsFg3.opacity(0.6), lineWidth: 1.5).frame(width: 14, height: 14)
        }
    }

    /// From the first checklist update to the last: "34 min", "1 h 5 min"; nil under a minute or without times.
    static func duration(_ items: [TimelineItem]) -> String? {
        func date(_ s: String) -> Date? { ISODate.parse(s) }
        var times: [Date] = []
        for item in items {
            switch item {
            case .tool(let t) where t.tool == "todo": if let d = date(t.at) { times.append(d) }
            case .steps(let s): times += s.tools.filter { $0.tool == "todo" }.compactMap { date($0.at) }
            default: break
            }
        }
        guard let first = times.min(), let last = times.max() else { return nil }
        let minutes = Int(last.timeIntervalSince(first) / 60)
        guard minutes >= 1 else { return nil }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
