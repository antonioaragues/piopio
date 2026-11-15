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
    /// The Summary column (docs/design/session-panel, step 4), shown or hidden for every chat.
    @AppStorage("chat.summary") private var showSummary = false
    /// PIOPIO_DEMO_CHAT_SUMMARY=1: show the column without changing the saved choice (captures).
    private static let demoSummary = ProcessInfo.processInfo.environment["PIOPIO_DEMO_CHAT_SUMMARY"] == "1"
    @State private var showCosts = false

    var body: some View {
        conversation
            .task { await thread.open() }
    }

    private var browserOpen: Bool { BrowserCenter.shared.openPanels.contains(summary.ref.id) }
    /// One panel on the right: the Browser covers the Summary while it's open, and the Summary comes back when it closes.
    private var summaryShown: Bool { (showSummary || Self.demoSummary) && !browserOpen }
    @State private var conversationWidth: Double = 1200
    /// The Browser's width as you last dragged it (every chat shares it).
    @AppStorage("browserWidth") private var browserPreferred = 560.0
    @State private var browserDragStart: Double?

    /// The widest the Browser may be: the chat keeps at least 380pt.
    private var browserMax: Double { max(320, conversationWidth - 380) }
    /// The Browser's width: yours, narrower when the window can't fit it.
    private var browserWidth: Double { min(max(320, browserPreferred), browserMax) }

    private var conversation: some View {
        HStack(spacing: 0) {
            chatColumn
            // The Browser panel (docs/spec/22 §5): opens by itself when the model browses here.
            if browserOpen {
                BrowserPanel(refID: summary.ref.id) { Task { await thread.stop() } }
                    .frame(width: browserWidth)
                    .sidePanel()
                    .overlay(alignment: .leading) { browserResizeHandle }
                    .transition(.move(edge: .trailing))
            } else if summaryShown {
                ChatSummaryPanel(engine: engine, thread: thread, summary: summary)
                    .frame(width: 290)
                    .sidePanel()
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { conversationWidth = $0 }
    }

    /// The Browser's leading edge: drag to resize it, between 320pt and what leaves the chat 380pt.
    private var browserResizeHandle: some View {
        Rectangle().fill(Color.clear).frame(width: 7).contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(DragGesture(coordinateSpace: .global).onChanged { value in
                if browserDragStart == nil { browserDragStart = browserWidth }
                browserPreferred = min(browserMax, max(320, (browserDragStart ?? browserWidth) - value.translation.width))
            }.onEnded { _ in browserDragStart = nil })
            .accessibilityLabel("Browser width").accessibilityValue("\(Int(browserWidth)) points")
            .accessibilityAdjustableAction { direction in
                browserPreferred = min(browserMax, max(320, browserWidth + (direction == .increment ? 40 : -40)))
            }
            .help("Drag to resize the browser")
            .offset(x: -3)
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            header
            if let next = summary.continuedIn { continuedBanner(next) }
            ZStack(alignment: .bottom) {
                TranscriptView(document: thread.document)
                // The thread dissolves before it reaches the composer (chat v3).
                LinearGradient(colors: [Color.dsWin.opacity(0), Color.dsWin], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                    .allowsHitTesting(false)
                VStack(spacing: 8) {
                    if !thread.isFollowing {
                        JumpToLatestButton { thread.scrollToLatest() }
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
            ToolbarIcon(symbol: "globe", label: "Browser", on: browserOpen,
                        help: browserOpen ? "Hide the browser" : "Browser: the pages this chat opened, and yours") {
                withAnimation(.easeOut(duration: 0.15)) {
                    if browserOpen { BrowserCenter.shared.openPanels.remove(summary.ref.id) } else { BrowserCenter.shared.openPanels.insert(summary.ref.id) }
                }
            }
            ToolbarIcon(symbol: "list.bullet.rectangle", label: "Summary", on: summaryShown,
                        help: summaryShown ? "Hide the summary" : "Summary: model, web search, connectors and MCP, files and sources") {
                withAnimation(.easeOut(duration: 0.15)) {
                    // With the Browser in the panel, Summary swaps it out rather than hiding a column you can't see.
                    if browserOpen { BrowserCenter.shared.openPanels.remove(summary.ref.id); showSummary = true } else { showSummary.toggle() }
                }
            }
            moveMenu
            ToolbarDivider()
            Menu {
                Button("Copy as Markdown") { Task { await thread.copyAsMarkdown() } }
                Divider()
                Button("Export as Markdown…") { Task { await thread.export(.markdown) } }
                Button("Export as HTML…") { Task { await thread.export(.html) } }
                Button("Export as JSONL…") { Task { await thread.export(.jsonl) } }
                Divider()
                Button("Cost…") { showCosts = true }
                Divider()
                Button("Turn into an Agent…") { run { try await engine.turnIntoAgent(summary.ref) } }
                    .help("An agent that does this on its own, on a schedule or when you message it. You review it before it's created.")
            } label: {
                Image(systemName: "ellipsis").accessibilityLabel("More")
            }
            .menuStyle(.button)
            .buttonStyle(IconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy, export, or see what this chat cost")
            .popover(isPresented: $showCosts, arrowEdge: .bottom) { CostDetails(engine: engine, thread: thread) }
        }
    }

    /// "Continued in piopio ›": this chat went on in a project folder (18 §5).
    private func continuedBanner(_ next: SessionSummary.Link) -> some View {
        let session = engine.buildSessions.first { $0.ref.id == next.id }
        let place = session.flatMap { engine.project(of: $0)?.name } ?? "a project"
        return HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            Text("Continued in \(place)").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            Spacer()
            if session != nil {
                Button("Open") { NotificationCenter.default.post(name: .selectBuildSession, object: next.id) }
                    .buttonStyle(PillStyle(kind: .toolbar, compact: true))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.dsChip.opacity(0.5))
    }

    /// Continue in a project (18 §5): a new conversation in its folder, with this one's history.
    private var moveMenu: some View {
        ContinueInMenu(engine: engine, ref: summary.ref) { Image(systemName: "folder") }
            .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Continue in a project")
            .help("Continue in a project: a new conversation in its folder, with this one's history")
    }

    private var subtitle: String {
        let place = "Chat"
        var parts = [place, BuildSessionView.relative(summary.updatedAt)]
        let files = thread.attachmentCount
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        if thread.state?.status == .running { parts.append("answering…") }
        return parts.joined(separator: " · ")
    }
}
