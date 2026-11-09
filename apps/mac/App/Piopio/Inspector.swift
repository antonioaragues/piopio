import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// The Inspector (docs/design/inspector, options 2a and 4a): Build's right-hand panel with two tabs, Session (Setup,
// Read, Plan) and Changes (a timeline by commit), and the footer every panel shares (context and cost, nowhere else).

enum InspectorTab: String { case session, changes }

/// The Inspector: its tabs, the open tab's body, the shared footer. The tab is kept per session.
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
    @State private var tab: InspectorTab
    @State private var files: [FileChange] = []

    init(engine: EngineController, session: ThreadModel, summary: SessionSummary, project: ProjectInfo?, git: GitModel?, chatLens: Bool,
         committing: Binding<Bool>, onReview: @escaping (String?) -> Void, onRead: @escaping () -> Void) {
        self.engine = engine; self.session = session; self.summary = summary; self.project = project; self.git = git
        self.chatLens = chatLens; self._committing = committing; self.onReview = onReview; self.onRead = onRead
        // PIOPIO_DEMO_INSPECTOR_TAB=changes: captures open on that tab.
        let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_INSPECTOR_TAB"].flatMap(InspectorTab.init)
        _tab = State(initialValue: chatLens ? .session : demo ?? Self.remembered(summary.ref.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabBar(tab: $tab, changes: chatLens ? nil : files.count)
            ScrollView {
                switch tab {
                case .session:
                    SessionTab(engine: engine, session: session, summary: summary, project: project, git: git, chatLens: chatLens,
                               committing: $committing, onRead: onRead)
                case .changes:
                    ChangesTab(engine: engine, session: session, summary: summary, git: git, files: files,
                               commit: !chatLens && git?.status?.repo == true && (git?.changedCount ?? 0) > 0 ? { committing = true } : nil,
                               onReview: onReview)
                }
            }
            InspectorFooter(thread: session)
        }
        .task(id: session.revision / 4) { files = await session.changes(since: .session) } // events arrive in quick batches
        .onChange(of: session.state?.status) { _, _ in Task { files = await session.changes(since: .session) } }
        .onChange(of: tab) { _, tab in Self.remember(tab, for: summary.ref.id) }
    }

    private static func remembered(_ id: String) -> InspectorTab {
        ((UserDefaults.standard.dictionary(forKey: "inspectorTabs") as? [String: String])?[id]).flatMap(InspectorTab.init) ?? .session
    }

    private static func remember(_ tab: InspectorTab, for id: String) {
        var all = (UserDefaults.standard.dictionary(forKey: "inspectorTabs") as? [String: String]) ?? [:]
        all[id] = tab.rawValue
        UserDefaults.standard.set(all, forKey: "inspectorTabs")
    }
}

/// Session · Changes 38. The active tab is semibold with a 2 pt underline; Changes is left out where there's no git.
struct InspectorTabBar: View {
    @Binding var tab: InspectorTab
    /// The Changes tab's count; nil hides the tab.
    let changes: Int?

    var body: some View {
        HStack(spacing: 18) {
            item(.session, "Session", count: nil)
            if let changes { item(.changes, "Changes", count: changes) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }

    private func item(_ value: InspectorTab, _ title: String, count: Int?) -> some View {
        let on = tab == value
        return Button { tab = value } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(on ? Color.dsFg : Color.dsFg3)
                if let count, count > 0 { Text("\(count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(Color.dsFg3) }
            }
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) { if on { Rectangle().fill(Color.dsFg).frame(height: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// Every panel's footer (§4): how full the context is, Compact, and what the session cost. The only place they appear.
struct InspectorFooter: View {
    let thread: ThreadModel
    @State private var compacting = false

    var body: some View {
        let cost = thread.state?.usage.costUsd ?? 0
        HStack(spacing: 8) {
            if let context = thread.state?.context {
                let fraction = min(1, (context.tokens ?? 0) / max(1, context.window))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.dsTrack)
                    Capsule().fill(fraction > 0.85 ? Color.dsFg : Color.dsFg2).frame(width: max(2, 40 * fraction))
                }
                .frame(width: 40, height: 3)
                Text("\(context.tokens.map { ContextRing.short($0) } ?? "–") of \(ContextRing.short(context.window))")
                    .monospacedDigit().lineLimit(1).fixedSize()
                    .help("\(Int((fraction * 100).rounded()))% of the context window")
                if (context.tokens ?? 0) > 0 {
                    SummaryLink(compacting ? "Compacting…" : "Compact") {
                        compacting = true
                        Task { await thread.compact(); compacting = false }
                    }
                    .disabled(thread.isRunning || compacting)
                    .help("Summarize the conversation so far to free up room")
                }
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

/// Setup, then what it read, then the plan (4a's order).
struct SessionTab: View {
    let engine: EngineController
    let session: ThreadModel
    let summary: SessionSummary
    let project: ProjectInfo?
    let git: GitModel?
    let chatLens: Bool
    @Binding var committing: Bool
    let onRead: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            setup.inspectorBlock()
            read.inspectorBlock()
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
            Button(name) { if let cwd = summary.cwd { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) } }
                .buttonStyle(.plain).font(.system(size: 13)).lineLimit(1).help(summary.cwd ?? "")
            if let git, git.status?.repo == true {
                Text("· \(git.status?.branch ?? summary.worktree?.branch ?? "HEAD")").font(.system(size: 13)).foregroundStyle(Color.dsFg3).lineLimit(1)
                if !chatLens { GitMenu(git: git, engine: engine, summary: summary, committing: $committing, inRow: true) }
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
        let choices = ToolChoices.compute(engine: engine, ref: summary.ref, debate: summary.debate != nil, servers: servers)
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

/// The plan's three states (4a): in progress (a segmented bar and the steps, the current one bold with "now"), done
/// (one green line with how long it took; the steps on demand) and none (why, and a way to ask for one).
struct PlanBlock: View {
    let session: ThreadModel
    @State private var showSteps = false

    var body: some View {
        let todos = session.todos
        let done = todos.filter { $0.status == .done }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Plan").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(todos.isEmpty ? "None" : "\(done) of \(todos.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
            }
            if todos.isEmpty {
                none
            } else if done == todos.count {
                finished(todos.count)
                if showSteps { steps(todos) }
            } else {
                progress(todos)
                steps(todos)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showSteps)
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

    private func finished(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsGreen)
                Text(count == 1 ? "Its step is done" : "All \(count) steps done").font(.system(size: 13))
                Spacer(minLength: 6)
                if let duration = Self.duration(session.document.items) {
                    Text(duration).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.dsGreen.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            SummaryLink(showSteps ? "Hide steps" : "Show steps") { showSteps.toggle() }
        }
    }

    /// One segment per step: done green, the current one blue, the rest a track.
    private func progress(_ todos: [Todo]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(todo.status == .done ? Color.dsGreen : todo.status == .inProgress ? Color.accentColor : Color.dsTrack)
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private func steps(_ todos: [Todo]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(todo.status).frame(width: 14)
                    Text(todo.text)
                        .font(.system(size: 13, weight: todo.status == .inProgress ? .semibold : .regular))
                        .foregroundStyle(todo.status == .done ? Color.dsFg3 : todo.status == .inProgress ? Color.dsFg : Color.dsFg2)
                        .strikethrough(todo.status == .done, color: Color.dsFg3.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if todo.status == .inProgress { Text("now").font(.system(size: 12)).foregroundStyle(Color.accentColor) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(todo.status == .done ? "Done" : todo.status == .inProgress ? "In progress" : "To do")
            }
        }
    }

    @ViewBuilder private func marker(_ status: Todo.Status) -> some View {
        switch status {
        case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dsGreen)
        case .inProgress: Circle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: 8, height: 8)
        default: Circle().strokeBorder(Color.dsFg3, lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }

    /// From the first checklist update to the last: "34 min", "1 h 5 min"; nil under a minute or without times.
    static func duration(_ items: [TimelineItem]) -> String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ s: String) -> Date? { iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) }
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
