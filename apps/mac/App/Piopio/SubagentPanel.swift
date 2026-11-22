import PiopioKit
import PiopioTranscript
import SwiftUI

/// A subagent beside its parent conversation (docs/spec/37 SB4, docs/design/subagents option A): tabs for the
/// conversation's subagents, the open one's transcript as it happens, and its own composer, where you steer it while
/// it works, ask a follow-up once it's done, and answer its approvals. Open in full goes to its session.
struct SubagentPanel: View {
    let engine: EngineController
    let parentId: String
    let selected: String
    let select: (String) -> Void
    let close: () -> Void

    private var children: [SessionSummary] {
        engine.buildSessions.filter { $0.parent?.id == parentId }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        let children = children
        VStack(spacing: 0) {
            tabs(children)
            if let child = children.first(where: { $0.ref.id == selected }) {
                SubagentConversation(engine: engine, thread: engine.thread(child.ref))
                    .id(child.ref.id)
            } else {
                Text("This subagent is gone.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func tabs(_ children: [SessionSummary]) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(children, id: \.ref.id) { child in
                        let on = child.ref.id == selected
                        Button { select(child.ref.id) } label: {
                            HStack(spacing: 6) {
                                SubagentGlyph(state: child.parent?.state ?? "working").scaleEffect(0.85)
                                Text(child.title).font(.system(size: 12.5)).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                            }
                            .foregroundStyle(on ? Color.dsFg : Color.dsFg2)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(on ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(child.title)
                    }
                }
                .padding(.leading, 8)
            }
            ToolbarIcon(symbol: "arrow.up.left.and.arrow.down.right", label: "Open in full", help: "Open this subagent's session") {
                NotificationCenter.default.post(name: .selectBuildSession, object: selected)
            }
            ToolbarIcon(symbol: "xmark", label: "Close", help: "Close the subagent") { close() }
                .padding(.trailing, 6)
        }
        .frame(height: Shell.cardBarHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }
}

/// One subagent's transcript and composer, laid out as a conversation is, in the column's width.
private struct SubagentConversation: View {
    let engine: EngineController
    let thread: ThreadModel

    var body: some View {
        ZStack(alignment: .bottom) {
            TranscriptView(document: thread.document)
            LinearGradient(colors: [Color.dsWin.opacity(0), Color.dsWin], startPoint: .top, endPoint: .bottom)
                .frame(height: 80)
                .allowsHitTesting(false)
            VStack(spacing: 8) {
                if !thread.isFollowing { JumpToLatestButton { thread.scrollToLatest() } }
                Composer(engine: engine, thread: thread)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                thread.document.bottomInset = height + 24
            }
        }
        .task { await thread.open() }
    }
}
