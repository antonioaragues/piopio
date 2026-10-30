import PiopioKit
import PiopioTranscript
import SwiftUI

/// A thread (docs/design/grey 9a, 11a): the 52pt toolbar, the centered transcript, and the composer.
struct ThreadView: View {
    /// PIOPIO_DEMO_FOLLOWUPS: suggestions separated by "||" when the engine has none (captures with the faux model).
    static let demoFollowUps = ProcessInfo.processInfo.environment["PIOPIO_DEMO_FOLLOWUPS"]?.components(separatedBy: "||")
    let engine: EngineController
    let thread: ThreadModel
    let summary: SessionSummary
    @AppStorage("debate.panel") private var showPanel = true
    @State private var showCosts = false

    var body: some View {
        Group {
            if let debate = thread.debate {
                VStack(spacing: 0) {
                    header
                    DebateLayout(engine: engine, thread: thread, debate: debate, showPane: showPanel)
                }
            } else {
                conversation
            }
        }
        .task { await thread.open() }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            header
            if let suggestion = summary.suggestion {
                SpaceSuggestionBanner(engine: engine, thread: summary, suggestion: suggestion)
            }
            ZStack(alignment: .bottom) {
                TranscriptView(document: thread.document)
                // The thread dissolves before it reaches the composer (chat v3).
                LinearGradient(colors: [Color.dsWin.opacity(0), Color.dsWin], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                    .allowsHitTesting(false)
                VStack(spacing: 8) {
                    if !thread.isFollowing {
                        Button { thread.scrollToLatest() } label: {
                            Label("Jump to latest", systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(PillStyle(kind: .toolbar, compact: true))
                    }
                    Composer(engine: engine, thread: thread).frame(maxWidth: 680)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    thread.document.bottomInset = height + 40
                }
            }
        }
        // "Ask next" sits in the thread after the last answer (chat v3, 14e).
        .onChange(of: summary.followUps) { _, items in thread.setFollowUps(items ?? Self.demoFollowUps) }
        .onAppear { thread.setFollowUps(summary.followUps ?? Self.demoFollowUps) }
        .alert("Error details", isPresented: Binding(get: { thread.errorDetail != nil }, set: { if !$0 { thread.errorDetail = nil } })) {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(thread.errorDetail ?? "", forType: .string)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(thread.errorDetail ?? "")
        }
    }

    private var header: some View {
        PageHeader(summary.title, subtitle: subtitle) {
            if let debate = thread.debate { debateControls(debate) } else { moveMenu }
            Menu {
                Button("Copy as Markdown") { Task { await thread.copyAsMarkdown() } }
                Divider()
                Button("Export as Markdown…") { Task { await thread.export(.markdown) } }
                Button("Export as HTML…") { Task { await thread.export(.html) } }
                Button("Export as JSONL…") { Task { await thread.export(.jsonl) } }
                Divider()
                Button("Cost…") { showCosts = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(IconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy, export, or see what this chat cost")
            .popover(isPresented: $showCosts, arrowEdge: .bottom) { CostDetails(engine: engine, thread: thread) }
        }
    }

    private var moveMenu: some View {
        Menu {
            ForEach(engine.spaces, id: \.ref.id) { space in
                Button(space.title) {
                    run {
                        let ids = try await engine.importThreads([summary.ref], into: space.ref, topic: nil)
                        if let id = ids.first { NotificationCenter.default.post(name: .openTopic, object: TopicTarget(spaceId: space.ref.id, topicId: id, itemId: nil)) }
                    }
                }
            }
            if !engine.spaces.isEmpty { Divider() }
            Button("New Notebook…") { NotificationCenter.default.post(name: .newSpace, object: summary.ref.id) }
        } label: { Text("Move to Notebook…") }
            .menuStyle(.button).buttonStyle(PillStyle(kind: .toolbar)).menuIndicator(.hidden).fixedSize()
            .help("Make this chat a topic in a notebook")
    }

    /// Debates: stop it while it runs, add rounds once it ended, and show or hide the draft panel.
    @ViewBuilder private func debateControls(_ debate: DebateState) -> some View {
        if debate.status == .running {
            Button("Stop debate") { Task { await thread.stopDebate() } }
                .buttonStyle(PillStyle(kind: .toolbar)).help("End it now and keep the latest draft")
        } else if debate.status != .agreed {
            Button("Keep going") { Task { await thread.continueDebate() } }
                .buttonStyle(PillStyle(kind: .toolbar)).help("Add as many rounds again as it started with")
        }
        Button { showPanel.toggle() } label: { Image(systemName: "sidebar.right") }
            .buttonStyle(IconButtonStyle(on: showPanel)).help(showPanel ? "Hide the draft" : "Show the draft and objections")
    }

    private var subtitle: String {
        if let debate = thread.debate { return debateSubtitle(debate) }
        var parts = ["Chat", BuildSessionView.relative(summary.updatedAt)]
        let files = thread.attachmentCount
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        if thread.state?.status == .running { parts.append("answering…") }
        return parts.joined(separator: " · ")
    }

    /// "Debate · Round 2 of 6 · GPT-5 reviewing…".
    private func debateSubtitle(_ debate: DebateState) -> String {
        var parts = ["Debate"]
        switch debate.status {
        case .running:
            parts.append("Round \(debate.round) of \(debate.maxRounds)")
            if let turn = debate.turn { parts.append("\(debate.label(turn)) \(turn == .author ? "writing" : "reviewing")…") }
        case .agreed: parts.append("Agreed in round \(debate.round)")
        case .noAgreement: parts.append("No agreement after \(debate.round) rounds")
        case .stopped: parts.append("Stopped in round \(debate.round)")
        }
        if debate.status != .running, thread.state?.status == .running { parts.append("answering…") }
        return parts.joined(separator: " · ")
    }
}
