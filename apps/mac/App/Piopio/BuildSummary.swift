import AppKit
import PiopioKit
import SwiftUI

/// Build's Summary column (docs/design/summary/ia.html): five groups in order of attention, each a card of verbs
/// (SummaryCard.swift). **Now** (while it works or waits on you), **Made** (Wrote · Changed · Saved), **Plan** (the
/// checklist), **Context** (how full, You gave · Follows · Read) and **Setup** (Works in · On · Runs on · Uses ·
/// Knows); the cost in the footer. Empty groups are hidden. Model and mode live in the composer only.
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
    @State private var open: Set<Fold> = []

    private enum Fold: Hashable { case changed, gave, read }
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
            SummaryFooter(label: "This session", cost: session.state?.usage.costUsd ?? 0)
        }
        .task(id: session.revision / 4) { files = await session.changes(since: .session) }
        .task(id: session.revision / 4) { await loadCommits() }
        .onChange(of: git?.status?.files.count) { _, _ in Task { await loadCommits() } }
        .onChange(of: session.state?.status) { _, _ in Task { files = await session.changes(since: .session) } }
    }

    // MARK: Now

    @ViewBuilder private var now: some View {
        let status = session.state?.status
        if status == .running || status == .waitingApproval {
            let todos = session.todos
            let current = todos.firstIndex { $0.status == .inProgress }
            NowGroup(waiting: status == .waitingApproval,
                     title: current.map { todos[$0].text } ?? "Working",
                     detail: status == .waitingApproval ? "It's asking in the conversation" : current.map { "Step \($0 + 1) of \(todos.count)" })
        }
    }

    // MARK: Made

    @ViewBuilder private func madeGroup(_ made: (wrote: [FileChange], changed: [FileChange])) -> some View {
        let ahead = chatLens ? 0 : git?.status?.ahead ?? 0
        if !made.wrote.isEmpty || !made.changed.isEmpty || !commits.isEmpty || ahead > 0 {
            VStack(alignment: .leading, spacing: 9) {
                GroupHeader("Made") {
                    if !files.isEmpty { SummaryLink("Review all") { onReview(nil) }.help("Every change, as a diff") }
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
                                SummaryLink("Push") { Task { await git.sync(.push) } }
                            }
                        }
                    }
                }
            }
            .summaryGroup()
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
            .summaryGroup()
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
                    if let context { ContextMeter(thread: session, context: context, compact: true) }
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
                                ItemButton(title: Self.name(p), help: "Open \(p)") { openPath(p) } trailing: {
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
                        let commands = inputs.commands == 0 ? nil : "\(inputs.commands) command\(inputs.commands == 1 ? "" : "s")"
                        if inputs.read.isEmpty {
                            Text(commands ?? "").font(.system(size: 13))
                        } else {
                            FoldButton(open: open.contains(.read), help: "The files it read") { toggle(.read) } label: {
                                Text(inputs.read.count == 1 ? "1 file" : "\(inputs.read.count) files").font(.system(size: 13))
                                if let commands { Text("and \(commands)").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                            }
                            if open.contains(.read) {
                                ForEach(inputs.read, id: \.self) { path in
                                    ItemButton(title: Self.name(path), help: "Open \(path)", dim: true) { openPath(path) }
                                }
                            }
                        }
                    }
                }
            }
            .summaryGroup()
        }
    }

    private enum GaveRow: Identifiable {
        case attachment(AttachmentInfo), path(String)
        var id: String { switch self { case .attachment(let a): "a:\(a.name)"; case .path(let p): "p:\(p)" } }
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
            UsesRow(engine: engine, thread: session, summary: summary)
            KnowsRow(thread: session)
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

    // MARK: Helpers

    @ViewBuilder private func more(_ count: Int, fold: Fold) -> some View {
        if count > Self.shortList {
            SummaryLink(open.contains(fold) ? "Show fewer" : "and \(count - Self.shortList) more") {
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

    /// "report.md", "informes/".
    static func name(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return URL(fileURLWithPath: trimmed).lastPathComponent + (path.hasSuffix("/") ? "/" : "")
    }

    /// "~/Proyectos".
    static func parent(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
