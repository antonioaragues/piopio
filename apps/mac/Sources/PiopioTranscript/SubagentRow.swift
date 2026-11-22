import AppKit
import PiopioKit
import SwiftUI

// A subagent in its parent's transcript (docs/spec/37 SB2, docs/design/subagents option A): one quiet row that stays
// live. A ring while it works, a check when it's done, red when it failed, dashed while queued; then its title and,
// in grey, what it's doing or how it ended. A click opens it beside the conversation (the page acts on it).

/// Where a subagent stands now: the app sets these from the sessions list, as it does sides.
public struct SubagentInfo: Sendable, Hashable {
    public var id: String
    public var title: String
    /// queued, working, done, failed or stopped.
    public var state: String
    /// What it's doing while it works.
    public var line: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var costUsd: Double?

    public init(id: String, title: String, state: String, line: String? = nil, startedAt: Date? = nil, endedAt: Date? = nil, costUsd: Double? = nil) {
        self.id = id; self.title = title; self.state = state; self.line = line
        self.startedAt = startedAt; self.endedAt = endedAt; self.costUsd = costUsd
    }

    /// The grey line: "Reading oauth.ts", "queued · starts when one finishes", "done · 1m 52s · $0.03".
    public var status: String {
        let took = startedAt.flatMap { start in endedAt.map { Self.duration($0.timeIntervalSince(start)) } }
        let cost = costUsd.flatMap { $0 > 0 ? ($0 < 0.01 ? "<$0.01" : String(format: "$%.2f", $0)) : nil }
        switch state {
        case "queued": return "queued · starts when one finishes"
        case "working": return line.map { $0.isEmpty ? "working" : $0 } ?? "working"
        case "done": return (["done", took, cost].compactMap { $0 }).joined(separator: " · ")
        case "failed": return (["failed", took].compactMap { $0 }).joined(separator: " · ")
        default: return "stopped"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(1, Int(seconds.rounded()))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(String(format: "%02d", s % 60))s"
    }
}

/// What the subagent links in the transcript do; the conversation's page acts on them.
public enum SubagentActionKind {
    public static let open = "subagent-open"
}

/// One row: its subagent (or only a title while the call starts it), and whether it's the one open beside.
public final class SubagentRowModel: @unchecked Sendable {
    let id: String?
    let title: String
    let state: String
    let status: String
    let open: Bool
    var onAction: (@MainActor (TranscriptAction) -> Void)?

    init(id: String?, title: String, state: String, status: String, open: Bool) {
        self.id = id; self.title = title; self.state = state; self.status = status; self.open = open
    }

    static let height: CGFloat = 28
}

final class SubagentRowAttachment: NSTextAttachment, @unchecked Sendable {
    let model: SubagentRowModel

    init(model: SubagentRowModel) {
        self.model = model
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = SubagentRowViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class SubagentRowViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let model = (textAttachment as! SubagentRowAttachment).model
        view = MainActor.assumeIsolated { ArrowHostingView(rootView: SubagentRowView(model: model)) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = textContainer?.size.width ?? proposedLineFragment.width
        return CGRect(x: 0, y: -8, width: width, height: SubagentRowModel.height)
    }
}

struct SubagentRowView: View {
    let model: SubagentRowModel
    @State private var hovering = false

    var body: some View {
        Button {
            guard let id = model.id else { return }
            MainActor.assumeIsolated { model.onAction?(.offer(kind: SubagentActionKind.open, callId: id)) }
        } label: {
            HStack(spacing: 9) {
                SubagentGlyph(state: model.state)
                Text(model.title).font(.system(size: 13.5)).foregroundStyle(Color(nsColor: DS.fg)).lineLimit(1).layoutPriority(1)
                Text(model.status).font(.system(size: 13)).foregroundStyle(Color(nsColor: DS.fg3)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(nsColor: DS.fg3))
                    .opacity(model.id != nil && (hovering || model.open) ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background((hovering || model.open) && model.id != nil ? Color(nsColor: DS.chip) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(model.id == nil ? "Starting" : model.open ? "Open beside" : "Open it beside the conversation. Its result comes back here.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subagent \(model.title), \(model.status)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A ring while it works, a check when done, red when failed, dashed while queued, a stop when stopped (the design's
/// status vocabulary: accent ring = running, green = done, red = failed, grey = idle).
public struct SubagentGlyph: View {
    let state: String
    @State private var spin = false

    public init(state: String) { self.state = state }

    public var body: some View {
        Group {
            switch state {
            case "working", "starting":
                Circle().trim(from: 0, to: 0.72)
                    .stroke(Color(nsColor: DS.accent), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .background(Circle().stroke(Color(nsColor: DS.accent).opacity(0.2), lineWidth: 1.6))
                    .frame(width: 11, height: 11)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            case "done":
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color(nsColor: DS.green))
            case "failed":
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color(nsColor: DS.red))
            case "queued":
                Image(systemName: "circle.dashed").font(.system(size: 13)).foregroundStyle(Color(nsColor: DS.fg3))
            default:
                Image(systemName: "stop.circle").font(.system(size: 13)).foregroundStyle(Color(nsColor: DS.fg3))
            }
        }
        .frame(width: 14, height: 14)
    }
}

extension ItemRenderer {
    /// A Piopio `task` call as its subagent's row (docs/spec/37). Claude Code and Codex tasks keep their card (SB7).
    static func isPiopioTask(_ t: ToolItem) -> Bool {
        guard t.tool == "task" else { return false }
        let agent = t.args?["agent"]?.stringValue ?? "piopio"
        return agent == "piopio" || agent.isEmpty
    }

    func subagentRow(_ t: ToolItem) -> NSAttributedString {
        let title = t.args?["description"]?.stringValue ?? "Subagent"
        var sessionId: String?
        var status: String?
        if case .task(let id, let s, _)? = t.typedDetails { sessionId = id; status = s }
        if let id = sessionId, let s = subagents.first(where: { $0.id == id }) {
            let model = SubagentRowModel(id: id, title: s.title.isEmpty ? title : s.title, state: s.state, status: s.status, open: openSubagent == id)
            return attachmentParagraph(SubagentRowAttachment(model: model), spacing: 4)
        }
        // Not in the sessions list (yet, or anymore): what the call itself knows.
        let state: String = switch (t.status, status) {
        case (.error, _), (_, "error"): "failed"
        case (_, "stopped"), (.interrupted, _): "stopped"
        case (_, "queued"): "queued"
        case (_, "done"): "done"
        case (.done, "started"): "working"
        default: "starting"
        }
        let line = state == "starting" ? "starting" : SubagentInfo(id: sessionId ?? "", title: title, state: state).status
        let model = SubagentRowModel(id: sessionId, title: title, state: state, status: line, open: sessionId != nil && openSubagent == sessionId)
        return attachmentParagraph(SubagentRowAttachment(model: model), spacing: 4)
    }

    /// A `[Task]` report that only says how its subagent ended: its row already says it (SB5).
    static func endsOnly(_ title: String) -> Bool {
        title.hasPrefix("Result from ") && (title.hasSuffix(" · finished") || title.hasSuffix(" · failed") || title.hasSuffix(" · was stopped"))
    }
}
