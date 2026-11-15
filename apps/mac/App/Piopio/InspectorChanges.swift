import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// The Inspector's Changes block (2a, folded into the one column on 2026-11-15): a row like Read ("38 files · 9
/// commits ›") that unfolds into the timeline. Open: +/−, how many are new and Review all; then what isn't saved yet,
/// then each commit since the session started, newest first and open, three before "N earlier commits". A file opens
/// its diff. Without git, one node with the files.
struct ChangesBlock: View {
    let engine: EngineController
    let session: ThreadModel
    let summary: SessionSummary
    let git: GitModel?
    /// What the session changed since it started (committed or not).
    let files: [FileChange]
    /// Commit…, when there's something to commit.
    let commit: (() -> Void)?
    let onReview: (String?) -> Void
    /// Unfolded; kept per session by the Inspector.
    @Binding var open: Bool
    @State private var commits: [GitCommit] = []
    @State private var expanded: Set<String> = []
    @State private var collapsedNewest = false
    @State private var showEarlier = false
    @State private var reverting: String?

    private static let shownCommits = 3
    private var repo: Bool { git?.status?.repo == true }
    private var unsaved: [GitFile] { repo ? (git?.status?.files ?? []) : [] }

    /// Nothing to unfold: no files changed, nothing unsaved, no commits.
    private var nothing: Bool { files.isEmpty && unsaved.isEmpty && commits.isEmpty }
    /// Open, the timeline ends with a node rather than "N earlier commits".
    private var endsWithNode: Bool { !repo || showEarlier || commits.count <= Self.shownCommits }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if open && !nothing {
                // Totals only when this session changed files (commits made elsewhere don't count).
                if files.isEmpty { Spacer().frame(height: 14) } else { totals.padding(.top, 12).padding(.bottom, 14) }
                if !repo {
                    sessionNode
                } else {
                    if !unsaved.isEmpty { unsavedNode(last: commits.isEmpty) }
                    let visible = showEarlier ? commits : Array(commits.prefix(Self.shownCommits))
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, commit in
                        commitNode(commit, newest: index == 0, last: index == visible.count - 1 && (showEarlier || commits.count <= Self.shownCommits))
                    }
                    if !showEarlier, commits.count > Self.shownCommits {
                        let earlier = commits.count - Self.shownCommits
                        SummaryLink(earlier == 1 ? "1 earlier commit" : "\(earlier) earlier commits") { withAnimation(.easeOut(duration: 0.15)) { showEarlier = true } }
                            .padding(.leading, 21)
                    }
                }
            }
        }
        // The last node's own 16 pt gap would double the block's.
        .padding(.bottom, open && !nothing && endsWithNode ? -16 : 0)
        .task(id: session.revision / 4) { await loadCommits() }
        .onChange(of: git?.status) { _, _ in Task { await loadCommits() } }
        .alert("Revert \(reverting ?? "")?", isPresented: Binding(get: { reverting != nil }, set: { if !$0 { reverting = nil } })) {
            Button("Revert", role: .destructive) { if let path = reverting { Task { await revert(path) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes back to how it was when the session started. The current version is checkpointed first.")
        }
    }

    // MARK: Row

    /// "Changes   38 files · 9 commits ›", like Read; the › turns down when it's open.
    private var row: some View {
        var parts: [String] = []
        if !files.isEmpty { parts.append(Self.count(files.count, "file")) }
        if !commits.isEmpty { parts.append(Self.count(commits.count, "commit")) }
        if parts.isEmpty, !unsaved.isEmpty { parts.append("\(unsaved.count) not saved") }
        return HStack(alignment: .firstTextBaseline) {
            Text("Changes").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if nothing {
                Text("Nothing yet").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
            } else {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(parts.joined(separator: " · "))
                        Text("›").rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Hide the changes" : "What it changed: what isn't saved yet, and each commit")
                .accessibilityLabel("Changes, \(parts.joined(separator: ", "))")
                .accessibilityValue(open ? "expanded" : "collapsed")
            }
        }
    }

    /// Open: +A −D, how many files are new, Review all.
    private var totals: some View {
        let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
        let new = files.filter { $0.status == .added }.count
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            DiffCounts(added: added, removed: removed)
            if new > 0 {
                Circle().fill(Color.dsGreen).frame(width: 6, height: 6)
                Text("\(new) new").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Spacer(minLength: 8)
            if !files.isEmpty { SummaryLink("Review all") { onReview(nil) }.help("Every change, as a diff") }
        }
    }

    // MARK: Nodes

    /// Uncommitted changes: an amber ring, their files, Commit….
    private func unsavedNode(last: Bool) -> some View {
        TimelineNode(dot: .ring(Color.dsWarn), last: last) {
            HStack(alignment: .firstTextBaseline) {
                Text("Not saved yet").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
                Text(Self.count(unsaved.count, "file")).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            ForEach(unsaved) { file in
                FileLine(path: file.path, added: file.added ?? 0, removed: file.removed ?? 0, note: file.status == .deleted ? "deleted" : nil) { onReview(file.path) }
                    .contextMenu {
                        Button("Review Diff") { onReview(file.path) }
                        Button("Revert…") { reverting = file.path }
                    }
            }
            if let commit { SummaryLink("Commit…", action: commit).padding(.top, 2) }
        }
    }

    /// A commit: its title and when; "N files +A −D ›" opens its files in place. The newest starts open.
    private func commitNode(_ commit: GitCommit, newest: Bool, last: Bool) -> some View {
        let files = commit.files ?? []
        let open = newest ? !collapsedNewest : expanded.contains(commit.id)
        return TimelineNode(dot: .filled(Color.dsFg3), last: last) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(commit.subject).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).help(commit.subject)
                Spacer(minLength: 6)
                Text(Self.age(commit.at)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3).fixedSize()
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if newest { collapsedNewest.toggle() } else if expanded.contains(commit.id) { expanded.remove(commit.id) } else { expanded.insert(commit.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(Self.count(files.count, "file"))
                    DiffCounts(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed })
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Commit \(commit.hash.prefix(7))")
            .contextMenu {
                Button("Copy Hash") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.hash, forType: .string)
                }
            }
            if open {
                ForEach(files) { file in
                    FileLine(path: file.path, added: file.added, removed: file.removed, note: nil) { onReview(file.path) }
                }
                .padding(.top, 2)
            }
        }
    }

    /// No git: the session's changes as one node.
    private var sessionNode: some View {
        TimelineNode(dot: .ring(Color.dsWarn), last: true) {
            Text("Changed in this session").font(.system(size: 13, weight: .semibold))
            ForEach(files) { file in
                FileLine(path: file.path, added: file.added, removed: file.removed, note: file.status == .deleted ? "deleted" : nil) { onReview(file.path) }
                    .contextMenu {
                        Button("Review Diff") { onReview(file.path) }
                        Button("Revert…") { reverting = file.path }
                    }
            }
        }
    }

    // MARK: Data

    /// The branch's commits since the session started, with their files.
    private func loadCommits() async {
        guard repo, let cwd = summary.cwd else { commits = []; return }
        commits = (try? await engine.client?.call("git.log", GitLogParams(cwd: cwd, since: summary.createdAt, limit: 50), as: GitLogResult.self).commits) ?? []
    }

    private func revert(_ path: String) async {
        guard let start = session.checkpoints.first else { return }
        _ = try? await session.restore(start, paths: [path], dryRun: false)
        await git?.refresh()
    }

    static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    /// "now", "4m", "2h", "3d": the timeline's short ages.
    static func age(_ iso: String, now: Date = .now) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }
}

/// A node of the timeline: its dot in a 9 pt column, the line down to the next node, and its content.
struct TimelineNode<Content: View>: View {
    enum Dot { case ring(Color), filled(Color) }
    let dot: Dot
    let last: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch dot {
                case .ring(let color): Circle().strokeBorder(color, lineWidth: 1.5)
                case .filled(let color): Circle().fill(color)
                }
            }
            .frame(width: 9, height: 9)
            .padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)
        }
        .background(alignment: .topLeading) {
            if !last { Rectangle().fill(Color.dsTrack).frame(width: 1).padding(.top, 15).padding(.leading, 4) }
        }
    }
}

/// A file in the timeline: its name in monospace, +A −D; opens its diff.
struct FileLine: View {
    let path: String
    let added: Int
    let removed: Int
    let note: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
                DiffCounts(added: added, removed: removed)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(path): review the diff")
    }
}
