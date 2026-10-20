import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Review in Build (docs/spec/05-build §5 BR2–BR3, §7; docs/design 2a inspector, 4c diff review):
// what the session changed, its checkpoints, the context meter and spend; a diff review with line comments.

/// The right-hand inspector of a Build session.
struct BuildInspector: View {
    let session: ThreadModel
    /// Opens the commit sheet; nil when there's nothing to commit (or no git).
    let commit: (() -> Void)?
    let onReview: (String?) -> Void
    @State private var files: [FileChange] = []
    @State private var reverting: FileChange?
    @State private var loadedRevision = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    changes
                    checkpoints
                }
                .padding(14)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            footer.padding(14)
        }
        .task(id: session.revision / 4) { await refresh() } // event batches arrive quickly while working
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

    private var changes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Changes").font(.system(size: 13, weight: .semibold))
                Spacer()
                let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
                if added > 0 { Text("+\(added)").foregroundStyle(Color.dsGreen) }
                if removed > 0 { Text("−\(removed)").foregroundStyle(Color.dsRed) }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            if files.isEmpty {
                Text("No files changed yet.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            ForEach(files) { file in
                ChangeRow(file: file, open: { onReview(file.path) }, revert: { reverting = file })
            }
            if !files.isEmpty || commit != nil {
                HStack(spacing: 8) {
                    Button("Review diff") { onReview(nil) }
                        .buttonStyle(PillStyle(kind: .secondary))
                        .frame(maxWidth: .infinity)
                        .disabled(files.isEmpty)
                    if let commit {
                        Button("Commit…", action: commit)
                            .buttonStyle(PillStyle(kind: .strong))
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private var checkpoints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Checkpoints").font(.system(size: 13, weight: .semibold))
            if session.checkpoints.isEmpty {
                Text("Taken before the agent first changes files in a turn.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            ForEach(session.checkpoints.reversed(), id: \.id) { checkpoint in
                Button { session.restoring = checkpoint } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Circle().strokeBorder(Color.dsFg3, lineWidth: 1.2).frame(width: 9, height: 9).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(checkpoint.label).font(.system(size: 12.5)).foregroundStyle(Color.dsFg)
                            Text(subtitle(checkpoint)).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Restore to here…")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let context = session.state?.context {
                HStack {
                    Text("Context").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                    Spacer()
                    Text("\(context.tokens.map { ContextChip.short($0) } ?? "–") / \(ContextChip.short(context.window))").font(.system(size: 12).monospacedDigit())
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.dsLine)
                        Capsule().fill(Color.accentColor).frame(width: max(3, geo.size.width * min(1, (context.tokens ?? 0) / max(1, context.window))))
                    }
                }
                .frame(height: 4)
            }
            HStack {
                Text("Spent this session").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                Spacer()
                Text(String(format: "$%.2f", session.state?.usage.costUsd ?? 0)).font(.system(size: 12).monospacedDigit())
            }
        }
    }

    private func subtitle(_ c: CheckpointItem) -> String {
        var parts = [BuildSessionView.relative(c.at)]
        if let files = c.files { parts.append(files == 1 ? "1 file" : "\(files) files") }
        return parts.joined(separator: " · ")
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
            Text(file.status.letter).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(file.status.color)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(hovering ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
        .onHover { hovering = $0 }
    }
}

extension FileChange.Status {
    var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        }
    }

    var color: Color {
        switch self {
        case .added: .dsGreen
        case .modified: .dsAmber
        case .deleted: .dsRed
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
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed) }
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
    @State var selected: String?
    let close: () -> Void
    @State private var since: ChangesSince = .session
    @State private var files: [FileChange] = []
    @AppStorage("diffSplit") private var split = false
    @State private var diff = UnifiedDiff("")
    @State private var commentLine: UnifiedDiff.Row?
    @State private var comment = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $since) {
                    Text("Whole session").tag(ChangesSince.session)
                    Text("Last turn").tag(ChangesSince.turn)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(files) { file in
                            Button { selected = file.path } label: {
                                HStack(spacing: 6) {
                                    Text(file.status.letter).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(file.status.color).frame(width: 12)
                                    Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                                    Spacer(minLength: 4)
                                    Text("+\(file.added)").foregroundStyle(Color.dsGreen)
                                    Text("−\(file.removed)").foregroundStyle(Color.dsRed)
                                }
                                .font(.system(size: 11).monospacedDigit())
                                .padding(.horizontal, 8)
                                .frame(height: 26)
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
                HStack(spacing: 8) {
                    Text(selected ?? "").font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Picker("", selection: $split) {
                        Text("Unified").tag(false)
                        Text("Split").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if let first = session.checkpoints.first {
                        Button("Restore checkpoint…") { session.restoring = since == .turn ? session.checkpoints.last ?? first : first }
                            .buttonStyle(PillStyle(kind: .toolbar))
                    }
                    Button("Done") { close() }.buttonStyle(PillStyle(kind: .strong)).keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
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
        .background(Color.dsWin)
        .task(id: since) {
            files = await session.changes(since: since)
            if selected == nil || !files.contains(where: { $0.path == selected }) { selected = files.first?.path }
            await loadDiff()
        }
        .onChange(of: selected) { _, _ in Task { await loadDiff() } }
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

    /// Inline comment (BR3): sends a follow-up that quotes the line.
    private var commentBox: some View {
        HStack(spacing: 8) {
            TextField("Ask the agent about this line, or request a change", text: $comment)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
                .onSubmit { sendComment() }
            Button("Ask agent ↩") { sendComment() }.buttonStyle(PillStyle(kind: .primary)).disabled(comment.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { commentLine = nil }.buttonStyle(PillStyle())
        }
        .padding(.leading, 110)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .background(Color.dsAccentSoft)
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
