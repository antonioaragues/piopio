import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Review in Build (docs/spec/05-build §5 BR2–BR3, §7; docs/design 2a inspector, 4c diff review):
// what the session changed, its checkpoints, the context meter and spend; a diff review with line comments.

/// The right-hand inspector of a Build session (docs/design chat v3): what the session changed, its turns (each with
/// Rewind on hover), the context and spend.
struct BuildInspector: View {
    let session: ThreadModel
    /// Opens the commit sheet; nil when there's nothing to commit (or no git).
    let commit: (() -> Void)?
    let onReview: (String?) -> Void
    @State private var files: [FileChange] = []
    @State private var reverting: FileChange?
    /// Your messages, newest first: what each turn changed.
    @State private var turns: [Turn] = []

    struct Turn: Identifiable {
        let id: String
        let number: Int
        let text: String
        let at: String
        var files = 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !session.todos.isEmpty { checklist }
                    changes
                    turnList
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            footer.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .task(id: session.revision / 4) { await refresh() } // event batches arrive quickly while working
        .task(id: session.revision) { turns = Self.turns(session.document.items) }
        .onChange(of: session.state?.status) { _, _ in Task { await refresh() } }
        .alert(item: $reverting) { file in
            Alert(
                title: Text("Revert \(file.path)?"),
                message: Text(file.status == .added ? "The session created it; reverting removes it." : "It goes back to how it was when the session started. The current version is checkpointed first."),
                primaryButton: .destructive(Text("Revert")) { Task { await revert(file) } },
                secondaryButton: .cancel()
            )
        }
    }

    /// Plain rows (docs/design/grey 9a): path, +N −N; then Review diff and Commit… as text.
    private var changes: some View {
        VStack(alignment: .leading, spacing: 2) {
            if files.isEmpty {
                Text("No changes yet.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
            }
            ForEach(files) { file in ChangeRow(file: file, open: { onReview(file.path) }, revert: { reverting = file }) }
            if !files.isEmpty || commit != nil {
                HStack(spacing: 14) {
                    Button("Review diff") { onReview(nil) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor).disabled(files.isEmpty)
                    if let commit { Button("Commit…", action: commit).buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2) }
                }
                .padding(.top, 8)
            }
        }
    }

    /// The agent's checklist (piopio-todos), latest version.
    private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("Checklist")
                Spacer()
                Text("\(session.todos.filter { $0.status == .done }.count) / \(session.todos.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg2)
            }
            ForEach(Array(session.todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: todo.status == .done ? "checkmark.circle.fill" : todo.status == .inProgress ? "circle.dotted.circle" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(todo.status == .inProgress ? Color.dsFg : Color.dsFg3)
                    Text(todo.text).font(.system(size: 12.5)).foregroundStyle(todo.status == .done ? Color.dsFg3 : Color.dsFg)
                        .strikethrough(todo.status == .done, color: Color.dsFg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One row per message you sent, newest first; hover one to rewind.
    private var turnList: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Turns").padding(.bottom, 4)
            if turns.isEmpty { Text("Your messages show up here.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3) }
            ForEach(turns) { turn in TurnRow(session: session, turn: turn, current: turn.id == turns.first?.id) }
        }
    }

    /// A turn per message you sent: its words, when, how many files it edited.
    static func turns(_ items: [TimelineItem]) -> [Turn] {
        var out: [Turn] = []
        for item in items {
            switch item {
            case .user(let u): out.append(Turn(id: u.id, number: out.count + 1, text: u.text.replacingOccurrences(of: "\n", with: " "), at: u.at))
            case .tool(let t) where !out.isEmpty && (t.tool == "edit" || t.tool == "write") && t.status == .done: out[out.count - 1].files += 1
            case .steps(let s) where !out.isEmpty: out[out.count - 1].files += Set(s.tools.filter { ($0.tool == "edit" || $0.tool == "write") && $0.status == .done }.compactMap { $0.args?["path"]?.stringValue }).count
            default: break
            }
        }
        return out.reversed()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let context = session.state?.context {
                HStack {
                    Text("Context").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                    Spacer()
                    Text("\(context.tokens.map { ContextRing.short($0) } ?? "–") of \(ContextRing.short(context.window))").font(.system(size: 12).monospacedDigit())
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.dsLine)
                        let fraction = min(1, (context.tokens ?? 0) / max(1, context.window))
                        Capsule().fill(Color.dsFg2).frame(width: max(3, geo.size.width * fraction))
                    }
                }
                .frame(height: 3)
            }
            HStack {
                Text("This session").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                Spacer()
                let cost = session.state?.usage.costUsd ?? 0
                Text(cost > 0 && cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)).font(.system(size: 12).monospacedDigit())
            }
        }
    }

    private func refresh() async {
        files = await session.changes(since: .session)
    }

    private func revert(_ file: FileChange) async {
        guard let start = session.checkpoints.first else { return }
        _ = try? await session.restore(start, paths: [file.path], dryRun: false)
        await refresh()
    }
}

/// A turn: its number (the current one dark), its first words, what it changed or when; Rewind on hover.
private struct TurnRow: View {
    let session: ThreadModel
    let turn: BuildInspector.Turn
    let current: Bool
    @State private var hovering = false
    @State private var rewinding = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(turn.number)").font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Color.dsFg3)
                .frame(width: 14, alignment: .leading)
            Text(turn.text).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if hovering || rewinding {
                Button { rewinding = true } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.dsFg2) }
                    .buttonStyle(.plain)
                    .help("Rewind to before this message")
                    .disabled(session.isRunning)
                    .popover(isPresented: $rewinding, arrowEdge: .leading) {
                        RewindPopover(itemId: turn.id, preview: { await session.rewindPreview($0) }, perform: { await session.rewind($0, files: $1) }) { rewinding = false }
                    }
            } else {
                Text(turn.files > 0 ? (turn.files == 1 ? "1 file" : "\(turn.files) files") : Self.age(turn.at)).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(hovering ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
    }

    /// "3 d", "5 h", "now".
    static func age(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if s < 86_400 { return "\(Int(s / 3600)) h" }
        return "\(Int(s / 86_400)) d"
    }
}

private struct ChangeRow: View {
    let file: FileChange
    let open: () -> Void
    let revert: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack {
                    Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head).foregroundStyle(Color.dsFg)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hovering {
                Button(action: revert) { Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dsFg2)
                    .help("Revert this file")
            }
            if file.added > 0 { Text("+\(file.added)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsGreen) }
            if file.removed > 0 { Text("−\(file.removed)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsRed) }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(hovering ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
        .padding(.horizontal, -6)
        .help("\(file.status.badge == "M" ? "Modified" : file.status.badge == "NEW" ? "New file" : "Deleted"): \(file.path)")
        .onHover { hovering = $0 }
    }
}

extension FileChange.Status {
    /// NEW / M / D (chat v3 inspector).
    var badge: String {
        switch self {
        case .added: "NEW"
        case .modified: "M"
        case .deleted: "D"
        }
    }

    var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        }
    }

    var color: Color {
        switch self {
        case .added: .dsFg3
        case .modified: .dsFg3
        case .deleted: .dsFg3
        }
    }

    var verb: String {
        switch self {
        case .added: "removed"
        case .modified: "reverted"
        case .deleted: "brought back"
        }
    }
}

// MARK: Restore

/// "Restore to here": lists exactly what changes, then restores (the engine checkpoints the current state first).
struct RestoreSheet: View {
    let session: ThreadModel
    let checkpoint: CheckpointItem
    @Environment(\.dismiss) private var dismiss
    @State private var files: [FileChange]?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore to “\(checkpoint.label)”?").font(.system(size: 15, weight: .semibold))
            if let files {
                if files.isEmpty {
                    Text("The files are already as they were at this checkpoint.").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                } else {
                    Text(files.count == 1 ? "1 file changes:" : "\(files.count) files change:").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(files) { f in
                                HStack {
                                    Text(f.status.letter).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(f.status.color).frame(width: 14)
                                    Text(f.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(f.status.verb).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .padding(10)
                    .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                    Text("The current state is checkpointed first, so you can undo this. The agent is told which files changed.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button("Restore") { Task { await restore() } }
                    .buttonStyle(PillStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(files?.isEmpty != false || working)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            do { files = try await session.restore(checkpoint, dryRun: true) } catch { self.error = String(describing: error); files = [] }
        }
    }

    private func restore() async {
        working = true
        do {
            _ = try await session.restore(checkpoint, dryRun: false)
            dismiss()
        } catch let e as EngineError {
            error = e.message
        } catch {
            self.error = String(describing: error)
        }
        working = false
    }
}

// MARK: Diff review (4c)

/// Replaces the transcript while reviewing: the session's files on the left, the diff on the right.
struct DiffReview: View {
    let session: ThreadModel
    /// The session's name, for the breadcrumb back.
    let title: String
    @State var selected: String?
    /// Commit…, when there's something to commit.
    let commit: (() -> Void)?
    let close: () -> Void
    @State private var since: ChangesSince = .session
    @State private var files: [FileChange] = []
    @AppStorage("diffSplit") private var split = false
    @State private var diff = UnifiedDiff("")
    @State private var commentLine: UnifiedDiff.Row?
    @State private var comment = ""

    var body: some View {
        VStack(spacing: 0) {
        toolbar
        Rectangle().fill(Color.dsLine).frame(height: 0.5)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(files) { file in
                            Button { selected = file.path } label: {
                                HStack(spacing: 6) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(URL(fileURLWithPath: file.path).lastPathComponent).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color.dsFg).lineLimit(1)
                                        let dir = URL(fileURLWithPath: file.path).deletingLastPathComponent().relativePath
                                        if dir != "." && !dir.isEmpty { Text(dir).font(.system(size: 11)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.head) }
                                    }
                                    Spacer(minLength: 4)
                                    if file.added > 0 { Text("+\(file.added)").foregroundStyle(Color.dsGreen) }
                                    if file.removed > 0 { Text("−\(file.removed)").foregroundStyle(Color.dsRed) }
                                }
                                .font(.system(size: 11.5).monospacedDigit())
                                .padding(.horizontal, 8)
                                .frame(minHeight: 40)
                                .help(file.path)
                                .background(selected == file.path ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if files.isEmpty { Text(since == .session ? "No changes in this session." : "No changes since the last checkpoint.").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 260)
            Rectangle().fill(Color.dsLine).frame(width: 0.5)
            VStack(spacing: 0) {
                GeometryReader { viewport in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if diff.binary {
                            Text("Binary file").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding()
                        } else if split {
                            ForEach(diff.pairs) { pair in splitRow(pair) }
                        } else {
                            ForEach(diff.rows) { row in
                                unifiedRow(row)
                                if commentLine == row { commentBox }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(minWidth: max(600, viewport.size.width), alignment: .leading) // row colors reach the edge
                }
                .font(.system(size: 12, design: .monospaced))
                }
            }
        }
        }
        .background(Color.dsWin)
        .task(id: since) {
            files = await session.changes(since: since)
            if selected == nil || !files.contains(where: { $0.path == selected }) { selected = files.first?.path }
            await loadDiff()
        }
        .onChange(of: selected) { _, _ in Task { await loadDiff() } }
    }

    /// The toolbar (docs/design/grey 10d): a breadcrumb back, then what to compare, Unified or Split, Restore, and Commit.
    private var toolbar: some View {
        PageHeader {
            HStack(spacing: 6) {
                Button(title) { close() }.buttonStyle(.plain).font(.system(size: 13.5)).foregroundStyle(Color.dsFg2).keyboardShortcut(.cancelAction)
                Text("/").font(.system(size: 13.5)).foregroundStyle(Color.dsFg3)
                Text("Changes").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg)
            }
        } actions: {
            Button(since == .session ? "Whole session" : "Last turn") { since = since == .session ? .turn : .session }
                .buttonStyle(ChipStyle()).help("Show the whole session's changes, or only the last turn's")
            Button(split ? "Split" : "Unified") { split.toggle() }
                .buttonStyle(ChipStyle()).help(split ? "Show one column" : "Show old and new side by side")
            if let first = session.checkpoints.first {
                Button("Restore checkpoint") { session.restoring = since == .turn ? session.checkpoints.last ?? first : first }
                    .buttonStyle(ChipStyle())
            }
            if let commit {
                Button(files.count == 1 ? "Commit 1 file" : "Commit \(files.count) files", action: commit)
                    .buttonStyle(PillStyle(kind: .primary, compact: true)).disabled(files.isEmpty).padding(.leading, 6)
            } else {
                Button("Done") { close() }.buttonStyle(PillStyle(kind: .primary, compact: true)).padding(.leading, 6)
            }
        }
    }

    private func loadDiff() async {
        commentLine = nil
        guard let selected else { diff = UnifiedDiff(""); return }
        diff = UnifiedDiff(await session.diff(selected, since: since))
    }

    private func unifiedRow(_ row: UnifiedDiff.Row) -> some View {
        HStack(spacing: 0) {
            Text(row.old.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(Color.dsFg3)
            Text(row.new.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(Color.dsFg3)
            Text(marker(row.kind)).frame(width: 22).foregroundStyle(Color.dsFg3)
            Text(row.text.isEmpty ? " " : row.text).foregroundStyle(row.kind == .hunk ? Color.dsFg3 : Color.dsFg).fixedSize()
            Spacer(minLength: 0)
        }
        .frame(height: 19)
        .background(background(row.kind))
        .contentShape(Rectangle())
        .onTapGesture { if row.kind != .hunk { commentLine = row; comment = "" } }
        .help(row.kind == .hunk ? "" : "Click to comment on this line")
    }

    private func splitRow(_ pair: UnifiedDiff.Pair) -> some View {
        HStack(spacing: 0) {
            if let hunk = pair.hunk {
                Text(hunk).foregroundStyle(Color.dsFg3).padding(.leading, 12)
                Spacer(minLength: 0)
            } else {
                side(pair.left, number: pair.left?.old)
                Rectangle().fill(Color.dsLine).frame(width: 0.5)
                side(pair.right, number: pair.right?.new)
            }
        }
        .frame(height: 19)
    }

    private func side(_ row: UnifiedDiff.Row?, number: Int?) -> some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(Color.dsFg3)
            Text(row.map { marker($0.kind) } ?? "").frame(width: 22).foregroundStyle(Color.dsFg3)
            Text(row?.text ?? "").lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(row.map { background($0.kind) } ?? Color.clear)
    }

    /// Inline comment (BR3, docs/design/grey 10d): a small box under the line; it sends a follow-up that quotes it.
    private var commentBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask about this line, or ask for a change", text: $comment)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { sendComment() }
            HStack(spacing: 12) {
                Text("Sent as a follow-up with this line").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Spacer()
                Button("Cancel") { commentLine = nil }.buttonStyle(PillStyle(compact: true))
                Button("Send ↩") { sendComment() }.buttonStyle(PillStyle(kind: .primary, compact: true)).disabled(comment.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .font(.system(size: 13))
        .askCard()
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.leading, 88)
        .padding(.vertical, 8)
    }

    private func sendComment() {
        guard let row = commentLine, let path = selected else { return }
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let line = row.new ?? row.old ?? 0
        let side = row.kind == .removed ? " (a line the session removed)" : ""
        let message = "About `\(path)` line \(line)\(side):\n```\n\(row.text)\n```\n\(text)"
        commentLine = nil
        comment = ""
        close()
        Task { await session.send(message) }
    }

    private func marker(_ kind: UnifiedDiff.Row.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private func background(_ kind: UnifiedDiff.Row.Kind) -> Color {
        switch kind {
        case .added: Color(nsColor: DS.addbg)
        case .removed: Color(nsColor: DS.delbg)
        case .hunk: Color.dsChip
        case .context: .clear
        }
    }
}
