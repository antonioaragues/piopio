import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// The Inspector (docs/design/inspector, options 2a and 4a): Build's right-hand panel, one column (Setup, Read,
// Changes, Plan; the Session and Changes tabs became one on 2026-11-15), and the footer every panel shares (context
// and cost, nowhere else).

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
    /// "Read" opens the Files panel on the files it touched.
    let onRead: () -> Void
    @State private var changesOpen: Bool
    @State private var files: [FileChange] = []

    init(engine: EngineController, session: ThreadModel, summary: SessionSummary, project: ProjectInfo?, git: GitModel?, chatLens: Bool,
         committing: Binding<Bool>, onReview: @escaping (String?) -> Void, onRead: @escaping () -> Void) {
        self.engine = engine; self.session = session; self.summary = summary; self.project = project; self.git = git
        self.chatLens = chatLens; self._committing = committing; self.onReview = onReview; self.onRead = onRead
        // PIOPIO_DEMO_INSPECTOR_CHANGES=1: captures open with Changes unfolded.
        let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_INSPECTOR_CHANGES"] == "1"
        _changesOpen = State(initialValue: demo || Self.remembered(summary.ref.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                SessionTab(engine: engine, session: session, summary: summary, project: project, git: git, chatLens: chatLens,
                           committing: $committing, files: files, changesOpen: $changesOpen, onReview: onReview, onRead: onRead)
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

/// Setup, then what it read, what it changed (not in a chat's lens), then the plan (4a's order).
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
    let onRead: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            setup.inspectorBlock()
            read.inspectorBlock()
            if !chatLens {
                ChangesBlock(engine: engine, session: session, summary: summary, git: git, files: files,
                             commit: git?.status?.repo == true && (git?.changedCount ?? 0) > 0 ? { committing = true } : nil,
                             onReview: onReview, open: $changesOpen)
                    .inspectorBlock()
            }
            PlanBlock(session: session).inspectorBlock(last: true)
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
                GridRow {
                    label("Tools")
                    ToolsSummary(engine: engine, thread: session, summary: summary)
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

    /// "Read  2 files · 144 commands ›": opens Files on what it touched.
    private var read: some View {
        let inputs = SessionDigest.inputs(items: session.document.items, cwd: summary.cwd, exists: { _ in true })
        let files = inputs.read.count, commands = inputs.commands
        var parts: [String] = []
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        if commands > 0 { parts.append(commands == 1 ? "1 command" : "\(commands) commands") }
        return HStack(alignment: .firstTextBaseline) {
            Text("Read").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if parts.isEmpty {
                Text("Nothing yet").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
            } else {
                Button(action: onRead) {
                    Text(parts.joined(separator: " · ") + " ›").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                }
                .buttonStyle(.plain)
                .help("The files it read and changed, in Files")
            }
        }
    }
}

/// Setup › Tools: the apps and skills it can use, in one line; unfolds into the switches for this conversation.
struct ToolsSummary: View {
    let engine: EngineController
    let thread: ThreadModel
    let summary: SessionSummary
    @State private var servers: [McpServerInfo] = []
    @State private var skills = 0
    @State private var open = false

    var body: some View {
        let choices = ToolChoices.compute(engine: engine, ref: summary.ref, servers: servers)
        let off = Set(summary.toolsOff ?? [])
        let names = choices.filter { $0.available && !off.contains($0.id) }.map(\.title)
        VStack(alignment: .leading, spacing: 8) {
            if choices.isEmpty && skills == 0 {
                HStack(spacing: 4) {
                    Text("No apps or skills ·").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                    SummaryLink("Add…") { ToolChoices.openSettings("Connectors") }.help("Connect apps and MCP servers, or add skills, in Settings")
                }
            } else {
                FoldButton(open: open, help: "What it can use, and switches for this conversation") { open.toggle() } label: {
                    Text(Self.line(names: names, skills: skills)).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                }
                if open {
                    UsesRow(engine: engine, thread: thread, summary: summary)
                    SkillsRow(thread: thread)
                }
            }
        }
        .task(id: summary.ref.id) {
            servers = await ToolChoices.load(engine: engine, cwd: summary.ref.kind == .build ? summary.cwd : nil)
            skills = await thread.commands().filter { $0.kind == .skill }.count
        }
    }

    /// "Gmail, Calendar · 3 skills", "No apps on · 1 skill".
    static func line(names: [String], skills: Int) -> String {
        let apps = names.isEmpty ? "No apps on" : names.joined(separator: ", ")
        return skills == 0 ? apps : "\(apps) · \(skills == 1 ? "1 skill" : "\(skills) skills")"
    }
}

/// The plan as a timeline (docs/design/plan-timeline, 1a in grey ink): a rail of markers joined by a line, done steps
/// checked in `fg3`, the current one ringed in ink with its detail open, the rest just their titles. Clicking a step
/// with a detail opens or closes it; the agent alone moves the plan along. Done shows every step checked, with how
/// long it took in the header; none says why, with a way to ask for one.
struct PlanBlock: View {
    let session: ThreadModel
    /// Steps (by title) whose detail is flipped from its default: open for the current one, closed for the rest.
    @State private var flipped: Set<String> = []

    var body: some View {
        let todos = session.todos
        let done = todos.filter { $0.status == .done }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Plan").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(counter(todos, done: done)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
            }
            if todos.isEmpty {
                none
            } else {
                timeline(todos)
            }
        }
        .animation(.easeOut(duration: 0.2), value: todos.map(\.status))
    }

    /// "2 of 6"; "6 of 6 · 34 min" once it's done.
    private func counter(_ todos: [Todo], done: Int) -> String {
        guard !todos.isEmpty else { return "None" }
        let base = "\(done) of \(todos.count)"
        guard done == todos.count, let duration = Self.duration(session.document.items) else { return base }
        return "\(base) · \(duration)"
    }

    @ViewBuilder private var none: some View {
        let answered = session.document.items.contains { if case .assistant = $0 { true } else { false } }
        HStack(spacing: 4) {
            if answered && !session.isRunning {
                Text("Short task — no plan needed.").foregroundStyle(Color.dsFg3)
                SummaryLink("Ask for one") {
                    Task { _ = await session.send("Make a plan for this with the todo tool before you go on.") }
                }
                .help("Ask it to write the steps down")
            } else {
                Text("It makes one for longer tasks.").foregroundStyle(Color.dsFg3)
            }
        }
        .font(.system(size: 12))
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
