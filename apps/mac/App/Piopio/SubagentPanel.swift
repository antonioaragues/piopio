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
                SubagentConversation(engine: engine, thread: engine.thread(child.ref), queuedBrief: child.parent?.state == "queued" ? child.parent?.brief ?? "" : nil)
                    .id(child.ref.id)
            } else {
                Text("This subagent is gone.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The tabs give way in steps as the column narrows: every title (each up to 140pt); then only the open one's title
    /// and the others as their glyph (the title in the tooltip); then one menu that lists them all.
    private func tabs(_ children: [SessionSummary]) -> some View {
        HStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) { ForEach(children, id: \.ref.id) { tab($0, titled: true) } }
                HStack(spacing: 2) { ForEach(children, id: \.ref.id) { tab($0, titled: $0.ref.id == selected) } }
                menu(children)
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            ToolbarIcon(symbol: "arrow.up.left.and.arrow.down.right", label: "Open in full", help: "Open this subagent's session") {
                NotificationCenter.default.post(name: .selectBuildSession, object: selected)
            }
            ToolbarIcon(symbol: "xmark", label: "Close", help: "Close the subagent") { close() }
                .padding(.trailing, 6)
        }
        .frame(height: Shell.cardBarHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }

    private func tab(_ child: SessionSummary, titled: Bool) -> some View {
        let on = child.ref.id == selected
        return Button { select(child.ref.id) } label: {
            HStack(spacing: 6) {
                SubagentGlyph(state: child.parent?.state ?? "working").scaleEffect(0.85)
                if titled { Text(child.title).font(.system(size: 12.5)).lineLimit(1).frame(maxWidth: 140, alignment: .leading).fixedSize() }
            }
            .foregroundStyle(on ? Color.dsFg : Color.dsFg2)
            .padding(.horizontal, titled ? 8 : 6).padding(.vertical, 4)
            .background(on ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(child.title)
        .accessibilityLabel("Subagent \(child.title)")
    }

    /// The narrowest: the open one's title, and a menu of all of them with where each stands.
    private func menu(_ children: [SessionSummary]) -> some View {
        let current = children.first { $0.ref.id == selected }
        return Menu {
            ForEach(children, id: \.ref.id) { child in
                Button {
                    select(child.ref.id)
                } label: {
                    let state = child.parent?.state ?? "working"
                    Text("\(child.ref.id == selected ? "✓ " : "")\(child.title) · \(state == "working" ? (child.parent?.line ?? "working") : state)")
                }
            }
        } label: {
            HStack(spacing: 6) {
                SubagentGlyph(state: current?.parent?.state ?? "working").scaleEffect(0.85)
                Text(current?.title ?? "Subagents").font(.system(size: 12.5)).lineLimit(1)
                Text("\(children.count)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            .foregroundStyle(Color.dsFg)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .help("All of this conversation's subagents")
    }
}

/// One subagent's transcript and composer, laid out as a conversation is, in the column's width.
private struct SubagentConversation: View {
    let engine: EngineController
    let thread: ThreadModel
    /// Still waiting its turn: its brief so far (what you write joins it), shown where its transcript will be.
    let queuedBrief: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            TranscriptView(document: thread.document)
            if let queuedBrief { queued(queuedBrief) }
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

    private func queued(_ brief: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                SubagentGlyph(state: "queued")
                Text("Queued · starts when one finishes").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
            }
            if !brief.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("From Piopio · the brief").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsFg2)
                    let text = Text(brief).font(.system(size: 13)).foregroundStyle(Color.dsFg).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    // Its own height when short; a long brief scrolls inside 320pt.
                    if brief.count > 700 { ScrollView { text }.frame(height: 320) } else { text.fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("What you write below joins it.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dsWin)
    }
}
