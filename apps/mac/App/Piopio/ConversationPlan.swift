import AppKit
import PiopioKit
import SwiftUI

// A conversation with its tasks at work (docs/spec/21 D6, 26 §5): the plan as one live block above the composer (a
// row per task with its helper and a state dot), then the merge card once its work is ready. The transcript keeps
// only what's notable (sent back, blocked).

extension Notification.Name {
    /// One of Piopio's offers taken in a transcript (object: the session id; userInfo: kind, call).
    static let transcriptOffer = Notification.Name("piopio.transcriptOffer")
}

struct ConversationPlan: View {
    let engine: EngineController
    let work: ProjectWork
    let conversationId: String
    @State private var open = true

    private var tasks: [WorkTask] { work.tasks.filter { $0.conversationId == conversationId } }
    private var running: Bool { tasks.contains { ["todo", "doing", "review", "integrating"].contains($0.state) } }

    var body: some View {
        let tasks = tasks
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                block(tasks)
                // Its work is ready once nothing of this conversation's is still on the board.
                if !running, work.git != nil {
                    LandingCard(engine: engine, work: work, conversation: conversationId)
                }
            }
            .frame(maxWidth: 680)
        }
    }

    private func block(_ tasks: [WorkTask]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dsFg3)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("Plan").font(.system(size: 12.5, weight: .semibold))
                    Text(Self.summary(tasks)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                    Spacer()
                    Button("Board") {
                        NotificationCenter.default.post(name: .selectItem, object: SidebarItem.board(work.project).raw)
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tasks) { row($0) }
                }
                .padding(.bottom, 6)
            }
        }
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }

    private func row(_ t: WorkTask) -> some View {
        let (word, color) = Self.state(t)
        return Button {
            if let id = (t.state == "review" ? t.reviewSessionId : nil) ?? t.sessionId {
                NotificationCenter.default.post(name: .selectItem, object: SidebarItem.session(id).raw)
            }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(t.title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                if t.attempts > 1 { Text("round \(t.attempts)").font(.system(size: 11)).foregroundStyle(Color.dsFg3) }
                Spacer(minLength: 8)
                Text(t.helper).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Text(word).font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.sessionId == nil ? t.brief : "Open its session")
    }

    /// "3 tasks · 1 building, 1 in review, 1 approved".
    static func summary(_ tasks: [WorkTask]) -> String {
        var counts: [(String, Int)] = []
        for t in tasks {
            let word = state(t).0
            if let i = counts.firstIndex(where: { $0.0 == word }) { counts[i].1 += 1 } else { counts.append((word, 1)) }
        }
        return "\(tasks.count) task\(tasks.count == 1 ? "" : "s") · " + counts.map { "\($0.1) \($0.0)" }.joined(separator: ", ")
    }

    /// A task's state as the plan says it, and its dot.
    static func state(_ t: WorkTask) -> (String, Color) {
        switch t.state {
        case "todo": ("waiting", Color.dsFg3)
        case "doing": ("building", Color.accentColor)
        case "review": ("in review", Color.dsWarn)
        case "integrating": ("merging", Color.accentColor)
        case "done": (t.landed != nil ? "merged" : "approved", Color.dsGreen)
        default: ("blocked", Color.dsRed)
        }
    }
}
