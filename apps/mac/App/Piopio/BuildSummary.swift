import AppKit
import PiopioKit
import SwiftUI

/// Build's Summary column (docs/design/summary/ia.html): five groups in order of attention, each a card of verbs.
/// **Now** (while it works or waits on you), **Made** (Wrote · Changed · Saved), **Plan** (the checklist), **Context**
/// (how full, You gave · Follows · Read) and **Setup** (Works in · On · Runs on · Uses · Knows); the cost in the
/// footer. Empty groups are hidden. Model and mode live in the composer only.
struct SessionSummaryPanel: View {
    let engine: EngineController
    let session: ThreadModel
    let summary: SessionSummary
    let project: ProjectInfo?
    let git: GitModel?
    let chatLens: Bool
    @Binding var committing: Bool
    let onReview: (String?) -> Void
    /// Opens a file of the project (relative to its folder) in the preview beside the conversation.
    let onOpen: (String) -> Void
    @State private var files: [FileChange] = []
    @State private var commits: [GitCommit] = []
    @State private var skills: [SessionCommand] = []
    @State private var servers: [McpServerInfo] = []
    @State private var compacting = false
    @State private var open: Set<Fold> = []

    private enum Fold: Hashable { case changed, gave, read, uses, knows }
    private static let shortList = 6

    var body: some View {
        let made = SessionDigest.split(files)
        let inputs = SessionDigest.inputs(items: session.document.items, cwd: summary.cwd, exists: exists)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    now
                    madeGroup(made)
                    plan
                    contextGroup(inputs)
                    setup
                }
                .padding(.horizontal, 16)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack {
                Text("This session").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                Spacer()
                Text(Self.money(session.state?.usage.costUsd ?? 0)).font(.system(size: 12).monospacedDigit())
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .task(id: session.revision / 4) { files = await session.changes(since: .session) }
        .task(id: session.revision / 4) { await loadCommits() }
        .task(id: summary.ref.id) {
            skills = await session.commands().filter { $0.kind == .skill }
            servers = await ToolChoices.load(engine: engine, cwd: summary.cwd)
        }
        .onChange(of: git?.status?.files.count) { _, _ in Task { await loadCommits() } }
        .onChange(of: session.state?.status) { _, _ in Task { files = await session.changes(since: .session) } }
    }

    // MARK: Now

    @ViewBuilder private var now: some View {
        let status = session.state?.status
        if status == .running || status == .waitingApproval {
            let waiting = status == .waitingApproval
            let todos = session.todos
            let current = todos.firstIndex { $0.status == .inProgress }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    StatusDot(status: waiting ? .waiting : .running)
                    Text(waiting ? "Waiting for you" : current.map { todos[$0].text } ?? "Working")
                        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                }
                if waiting {
                    Text("It's asking in the conversation").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                } else if let current {
                    Text("Step \(current + 1) of \(todos.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
                }
            }
            .groupBox()
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Made

    @ViewBuilder private func madeGroup(_ made: (wrote: [FileChange], changed: [FileChange])) -> some View {
        let ahead = chatLens ? 0 : git?.status?.ahead ?? 0
        if !made.wrote.isEmpty || !made.changed.isEmpty || !commits.isEmpty || ahead > 0 {
            VStack(alignment: .leading, spacing: 9) {
                GroupHeader("Made") {
                    if !files.isEmpty { LinkButton("Review all") { onReview(nil) }.help("Every change, as a diff") }
                }
                if !made.wrote.isEmpty {
                    CardRow("Wrote") {
                        ForEach(made.wrote) { file in
                            ItemButton(title: Self.name(file.path), help: "Open \(file.path)") { onOpen(file.path) } trailing: {
                                Text(SessionDigest.kind(of: file.path) ?? "").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                            }
                        }
                    }
                }
                if !made.changed.isEmpty {
                    CardRow("Changed") {
                        let all = open.contains(.changed)
                        ForEach(all ? made.changed : Array(made.changed.prefix(Self.shortList))) { file in
                            ItemButton(title: Self.name(file.path), help: "\(file.path): review the diff") { onReview(file.path) } trailing: {
                                if file.status == .deleted { Text("deleted").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                                if file.added > 0 { Text("+\(file.added)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsGreen) }
                                if file.removed > 0 { Text("−\(file.removed)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsRed) }
                            }
                        }
                        more(made.changed.count, fold: .changed)
                    }
                }
                if !commits.isEmpty || ahead > 0 {
                    CardRow("Saved") {
                        ForEach(commits) { commit in
                            ItemButton(title: commit.subject, help: "Commit \(commit.hash.prefix(7)): click to copy its hash") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(commit.hash, forType: .string)
                            } trailing: {
                                Text(String(commit.hash.prefix(7))).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg3)
                            }
                        }
                        if ahead > 0, let git {
                            HStack(spacing: 8) {
                                Text("\(ahead) to push").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                                LinkButton("Push") { Task { await git.sync(.push) } }
                            }
                        }
                    }
                }
            }
            .groupBox()
        }
    }

    // MARK: Plan

    @ViewBuilder private var plan: some View {
        let todos = session.todos
        if !todos.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                GroupHeader("Plan") {
                    Text("\(todos.filter { $0.status == .done }.count) of \(todos.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
                }
                .padding(.bottom, 3)
                ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: todo.status == .done ? "circle.fill" : "circle")
                            .font(.system(size: 9, weight: todo.status == .inProgress ? .bold : .regular))
                            .foregroundStyle(todo.status == .inProgress ? Color.dsFg : todo.status == .done ? Color.dsFg2 : Color.dsFg3)
                            .frame(width: 11)
                        Text(todo.text).font(.system(size: 12.5))
                            .foregroundStyle(todo.status == .done ? Color.dsFg3 : todo.status == .inProgress ? Color.dsFg : Color.dsFg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(todo.status == .done ? "Done" : todo.status == .inProgress ? "In progress" : "To do")
                }
            }
            .groupBox()
        }
    }

    // MARK: Context

    @ViewBuilder private func contextGroup(_ inputs: SessionDigest.Inputs) -> some View {
        let context = session.state?.context
        let contextFile = project?.contextFile
        let gave = inputs.attachments.count + inputs.mentions.count
        if context != nil || gave > 0 || contextFile != nil || !inputs.read.isEmpty || inputs.commands > 0 {
            VStack(alignment: .leading, spacing: 9) {
                GroupHeader("Context") {
                    if let context { meter(context) }
                }
                if gave > 0 {
                    CardRow("You gave") {
                        let all = open.contains(.gave)
                        let rows = inputs.attachments.map { GaveRow.attachment($0) } + inputs.mentions.map { GaveRow.path($0) }
                        ForEach(all ? rows : Array(rows.prefix(Self.shortList))) { row in
                            switch row {
                            case .attachment(let a):
                                ItemButton(title: a.name, help: a.stored == nil ? "Sent before Piopio kept copies of files" : "Open \(a.name)") {
                                    if let stored = a.stored { session.handle(.openAttachment(stored: stored)) }
                                } trailing: {
                                    Text(a.kind == .image ? "image" : "file").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                                }
                                .disabled(a.stored == nil)
                            case .path(let p):
                                ItemButton(title: p.hasSuffix("/") ? p : Self.name(p), help: "Open \(p)") { openPath(p) } trailing: {
                                    if isFolder(p) { Text("folder").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                                }
                            }
                        }
                        more(rows.count, fold: .gave)
                    }
                }
                if let contextFile {
                    CardRow("Follows") {
                        ItemButton(title: contextFile, help: "The project's instructions, read at the start of every session") { onOpen(contextFile) }
                    }
                }
                if !inputs.read.isEmpty || inputs.commands > 0 {
                    CardRow("Read") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if !inputs.read.isEmpty {
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) { toggle(.read) }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(inputs.read.count == 1 ? "1 file" : "\(inputs.read.count) files").font(.system(size: 13))
                                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.dsFg3)
                                            .rotationEffect(.degrees(open.contains(.read) ? 90 : 0))
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(open.contains(.read) ? "Expanded" : "Collapsed")
                            }
                            if inputs.commands > 0 {
                                Text("\(inputs.read.isEmpty ? "" : "and ")\(inputs.commands) command\(inputs.commands == 1 ? "" : "s")")
                                    .font(.system(size: inputs.read.isEmpty ? 13 : 12)).foregroundStyle(inputs.read.isEmpty ? Color.dsFg : Color.dsFg3)
                            }
                        }
                        if open.contains(.read) {
                            ForEach(inputs.read, id: \.self) { path in
                                ItemButton(title: Self.name(path), help: "Open \(path)", dim: true) { openPath(path) }
                            }
                        }
                    }
                }
            }
            .groupBox()
        }
    }

    private enum GaveRow: Identifiable {
        case attachment(AttachmentInfo), path(String)
        var id: String { switch self { case .attachment(let a): "a:\(a.name)"; case .path(let p): "p:\(p)" } }
    }

    private func meter(_ context: SessionState.Context) -> some View {
        let fraction = min(1, (context.tokens ?? 0) / max(1, context.window))
        return HStack(spacing: 7) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dsLine)
                Capsule().fill(fraction > 0.85 ? Color.dsFg : Color.dsFg2).frame(width: max(3, 40 * fraction))
            }
            .frame(width: 40, height: 3)
            Text("\(Int((fraction * 100).rounded()))% full").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg2)
            if (context.tokens ?? 0) > 0 {
                LinkButton(compacting ? "Compacting…" : "Compact") {
                    compacting = true
                    Task { await session.compact(); compacting = false }
                }
                .disabled(session.isRunning || compacting)
                .help("Summarize the conversation so far to free up room")
            }
        }
        .help("\(context.tokens.map { ContextRing.short($0) } ?? "–") of \(ContextRing.short(context.window)) tokens")
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 9) {
            GroupHeader("Setup") { EmptyView() }
            if let cwd = summary.cwd {
                CardRow("Works in") {
                    ItemButton(title: URL(fileURLWithPath: cwd).lastPathComponent, help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
                    } trailing: {
                        Text(Self.parent(cwd)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.head)
                    }
                }
                CardRow("On") { branch }
            }
            CardRow("Runs on") { Text("This Mac").font(.system(size: 13)) }
            uses
            knows
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder private var branch: some View {
        if let git, git.status?.repo == true {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(git.status?.branch ?? summary.worktree?.branch ?? "HEAD").font(.system(size: 13)).lineLimit(1)
                if let behind = git.status?.behind, behind > 0 {
                    Text("\(behind) to pull").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Spacer(minLength: 4)
                if !chatLens { GitMenu(git: git, engine: engine, summary: summary, committing: $committing, inRow: true) }
            }
            if let worktree = summary.worktree, worktree.finished == nil {
                Text("A separate copy, from \(worktree.base)").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
        } else {
            Text("No git").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
        }
    }

    /// Connected apps and MCP servers: the names of those on, unfolding into a switch each for this session.
    private var uses: some View {
        let choices = ToolChoices.compute(engine: engine, ref: summary.ref, debate: false, servers: servers)
        let off = Set(summary.toolsOff ?? [])
        let on = choices.filter { $0.available && !off.contains($0.id) }
        return CardRow("Uses") {
            if choices.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("No apps").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                    LinkButton("Connect…") { ToolChoices.openSettings("Connectors") }
                        .help("Connect apps and MCP servers in Settings")
                    Spacer(minLength: 0)
                }
            } else {
                FoldButton(open: open.contains(.uses), help: "Turn apps and servers off for this session") { toggle(.uses) } label: {
                    Text(on.isEmpty ? "Nothing on" : on.map(\.title).joined(separator: ", ")).font(.system(size: 13))
                        .foregroundStyle(on.isEmpty ? Color.dsFg3 : Color.dsFg).lineLimit(2).multilineTextAlignment(.leading)
                    if on.count < choices.count {
                        Text("\(on.count) of \(choices.count)").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                }
                if open.contains(.uses) {
                    ForEach(choices) { choice in ToolChoiceRow(choice: choice, off: off, thread: session, icon: false) }
                    Text("Only this session. What's on everywhere is set in Settings.")
                        .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Skills from pi's folders and packages; type / to use one.
    private var knows: some View {
        CardRow("Knows") {
            if skills.isEmpty {
                Text("No skills").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
            } else {
                FoldButton(open: open.contains(.knows), help: "What each skill is for") { toggle(.knows) } label: {
                    Text(skills.prefix(3).map { Self.skillName($0) }.joined(separator: ", ") + (skills.count > 3 ? " and \(skills.count - 3) more" : ""))
                        .font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                }
                if open.contains(.knows) {
                    ForEach(skills) { skill in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.skillName(skill)).font(.system(size: 12.5))
                            if !skill.description.isEmpty {
                                Text(skill.description).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(2)
                            }
                        }
                    }
                    Text("Type / in the message box to use one.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                }
            }
        }
    }

    // MARK: Helpers

    @ViewBuilder private func more(_ count: Int, fold: Fold) -> some View {
        if count > Self.shortList {
            LinkButton(open.contains(fold) ? "Show fewer" : "and \(count - Self.shortList) more") {
                withAnimation(.easeOut(duration: 0.15)) { toggle(fold) }
            }
        }
    }

    private func toggle(_ fold: Fold) {
        if open.contains(fold) { open.remove(fold) } else { open.insert(fold) }
    }

    private func full(_ path: String) -> String {
        path.hasPrefix("/") ? path : (summary.cwd.map { ($0 as NSString).appendingPathComponent(path) } ?? path)
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: full(path)) }

    private func isFolder(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: full(path), isDirectory: &dir) && dir.boolValue
    }

    /// A project file opens in the preview; a folder or a file elsewhere on this Mac, in Finder.
    private func openPath(_ path: String) {
        if path.hasPrefix("/") || isFolder(path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full(path))])
        } else {
            onOpen(path)
        }
    }

    /// The branch's commits since the session started (made by the agent or by you).
    private func loadCommits() async {
        guard !chatLens, let cwd = summary.cwd, git?.status?.repo == true else { commits = []; return }
        commits = (try? await engine.client?.call("git.log", GitLogParams(cwd: cwd, since: summary.createdAt, limit: 10), as: GitLogResult.self).commits) ?? []
    }

    static func name(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return URL(fileURLWithPath: trimmed).lastPathComponent + (path.hasSuffix("/") ? "/" : "")
    }

    /// "~/Proyectos".
    static func parent(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    /// pi names skill commands "skill:<name>"; the card shows the name.
    static func skillName(_ skill: SessionCommand) -> String {
        skill.name.hasPrefix("skill:") ? String(skill.name.dropFirst(6)) : skill.name
    }

    static func money(_ cost: Double) -> String {
        cost > 0 && cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)
    }
}

// MARK: Card parts

/// A group's heading: 12pt grey, with what belongs on its right (a count, a link, the context meter).
private struct GroupHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) { self.title = title; self.trailing = trailing() }

    var body: some View {
        HStack(spacing: 8) {
            SectionLabel(title).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            trailing
        }
    }
}

/// A line of the card: the verb on the left in grey, what it answers on the right (like the agent's info panel).
private struct CardRow<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.dsFg3).frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A clickable value in a card: the name, then grey details on the right.
private struct ItemButton<Trailing: View>: View {
    let title: String
    let help: String
    var dim = false
    let action: () -> Void
    let trailing: Trailing

    init(title: String, help: String, dim: Bool = false, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.help = help; self.dim = dim; self.action = action; self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: dim ? 12.5 : 13)).foregroundStyle(dim ? Color.dsFg2 : Color.dsFg)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                trailing
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A value that unfolds into its detail below (Uses, Knows), with a small chevron.
private struct FoldButton<Label: View>: View {
    let open: Bool
    let help: String
    let action: () -> Void
    let label: Label

    init(open: Bool, help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.open = open; self.help = help; self.action = action; self.label = label()
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { action() } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                label
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.dsFg3)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

/// A blue text action (links are the only blue in the chrome).
private struct LinkButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(title, action: action).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
    }
}

private extension View {
    /// A group: vertical padding and the hairline below it (Setup, always last, has none).
    func groupBox() -> some View {
        padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }
}
