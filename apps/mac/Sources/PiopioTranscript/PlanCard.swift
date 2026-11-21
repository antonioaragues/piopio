import AppKit
import PiopioKit
import SwiftUI

/// A plan as the transcript shows it (docs/spec/09 P1–P3): the summary, numbered steps, the files it expects to
/// change and its risks, and either the answer buttons or how you answered.
public struct PlanContent: Sendable, Hashable {
    public enum State: Sendable, Hashable { case pending, approved, approvedEdited, changes(String?), unanswered }
    public var callId: String
    public var summary: String
    public var steps: [String]
    public var files: [String]
    public var risks: [String]
    public var state: State

    public init(callId: String, summary: String, steps: [String], files: [String] = [], risks: [String] = [], state: State) {
        self.callId = callId; self.summary = summary; self.steps = steps; self.files = files; self.risks = risks; self.state = state
    }

    // Layout, shared by the view and the height the text view reserves for it.
    static let padding: CGFloat = 16
    static let stepIndent: CGFloat = 30
    static let headerHeight: CGFloat = 22
    static let footerHeight: CGFloat = 40
    /// Answered and folded: the header line alone.
    static let foldedHeight: CGFloat = 46
    nonisolated(unsafe) static let summaryFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    nonisolated(unsafe) static let stepFont = NSFont.systemFont(ofSize: 13.5)
    nonisolated(unsafe) static let smallFont = NSFont.systemFont(ofSize: 12.5)

    /// Answered plans fold to one line in the transcript; the side panel carries the plan from there.
    public var answered: Bool { state != .pending }

    func height(width: CGFloat, folded: Bool = false) -> CGFloat {
        if folded { return Self.foldedHeight }
        let inner = max(120, width - Self.padding * 2)
        func h(_ text: String, _ font: NSFont, _ w: CGFloat) -> CGFloat {
            ceil(NSAttributedString(string: Self.plain(text), attributes: [.font: font]).boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        var total = Self.padding + Self.headerHeight + 8
        total += h(summary, Self.summaryFont, inner) + 12
        for step in steps { total += max(20, h(step, Self.stepFont, inner - Self.stepIndent)) + 8 }
        if !files.isEmpty { total += 6 + h("Files  " + files.joined(separator: "   "), .monospacedSystemFont(ofSize: 11.5, weight: .regular), inner - 44) + 4 }
        for risk in risks { total += h(risk, Self.smallFont, inner - 20) + 6 }
        if case .changes(let note?) = state { total += h(note, Self.smallFont, inner) + 6 }
        // A plan waiting for you has no footer: the box below the transcript takes the answer.
        total += answered ? 10 + Self.footerHeight : 14
        return total + 8
    }

    /// Markdown markers dropped, for measuring.
    public static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    /// Inline Markdown (`code`, **bold**) as SwiftUI text.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// The plan in the transcript (docs/design/plan-flow). While it waits it's a document to read: no buttons, because
/// the composer's tray is the one place that takes the answer. Once answered it folds to one line ("Plan · 7 steps ·
/// Approved ›") that opens it again; the side panel's Plan carries it from there.
struct PlanCardView: View {
    let plan: PlanContent
    let expanded: Bool
    let toggle: @MainActor () -> Void

    private var folded: Bool { plan.answered && !expanded }
    // `expanded` is the transcript card's: true for a plan waiting for you, false once answered until you open it.

    var body: some View {
        Group {
            if folded {
                Button(action: toggle) { header.contentShape(Rectangle()) }.buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(height: PlanContent.foldedHeight - 8)
                    .help("Show the plan")
            } else {
                full
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: DS.card), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: DS.line), lineWidth: 0.5))
    }

    /// "Plan  7 steps", and on the right how it stands: "● Waiting for you", or the answer with a chevron.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("Plan").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: DS.fg2))
            Text(plan.steps.count == 1 ? "1 step" : "\(plan.steps.count) steps").font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3))
            Spacer(minLength: 8)
            if plan.answered {
                Text(outcome).font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3))
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(nsColor: DS.fg3))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            } else {
                HStack(spacing: 5) {
                    Circle().fill(Color(nsColor: DS.accent)).frame(width: 6, height: 6)
                    Text("Waiting for you").font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg2))
                }
            }
        }
        .frame(height: PlanContent.headerHeight)
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if plan.answered { Button(action: toggle) { header.contentShape(Rectangle()) }.buttonStyle(.plain).help("Fold the plan") } else { header }
            }
            .padding(.bottom, 8)
            Text(PlanContent.inline(plan.summary)).font(Font(PlanContent.summaryFont)).foregroundStyle(Color(nsColor: DS.fg))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Color(nsColor: DS.fg3))
                            .frame(width: 20, alignment: .trailing)
                        Text(PlanContent.inline(step)).font(Font(PlanContent.stepFont)).foregroundStyle(Color(nsColor: DS.fg))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !plan.files.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Files").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color(nsColor: DS.fg3))
                    Text(plan.files.joined(separator: "   ")).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color(nsColor: DS.fg2))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
            }
            if !plan.risks.isEmpty {
                // Risks and open questions in grey ink: a dot, not an amber warning.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(plan.risks.enumerated()), id: \.offset) { _, risk in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("·").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color(nsColor: DS.fg3)).frame(width: 10)
                            Text(PlanContent.inline(risk)).font(Font(PlanContent.smallFont)).foregroundStyle(Color(nsColor: DS.fg2)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
            }
            if case .changes(let note?) = plan.state {
                Text("You asked for: \(note)").font(Font(PlanContent.smallFont)).foregroundStyle(Color(nsColor: DS.fg2)).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            if plan.answered {
                Rectangle().fill(Color(nsColor: DS.line)).frame(height: 0.5).padding(.top, 10)
                HStack {
                    Text(footnote).font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3))
                    Spacer()
                }
                .frame(height: PlanContent.footerHeight)
            }
        }
        .padding(.horizontal, PlanContent.padding)
        .padding(.top, PlanContent.padding)
        .padding(.bottom, plan.answered ? 0 : 14)
    }

    private var outcome: String {
        switch plan.state {
        case .approved: "Approved"
        case .approvedEdited: "Approved with your edits"
        case .changes: "Sent back"
        case .unanswered: "Not answered"
        case .pending: ""
        }
    }

    private var footnote: String {
        switch plan.state {
        case .approved: "Plan mode turned off and the agent built it."
        case .approvedEdited: "The agent built your edited version."
        case .changes: "The agent kept planning."
        case .unanswered: "The run stopped before you answered."
        case .pending: ""
        }
    }
}

extension PlanContent {
    /// The session's latest plan proposal, for the side panel: the plan, and whether the agent has written its todo
    /// list since (then the list is the plan, as the approved plan asks it to track the steps with `todo`).
    public static func latest(in items: [TimelineItem]) -> (plan: PlanContent, todosSince: Bool)? {
        var found: PlanContent?
        var todosSince = false
        for item in items {
            let tools: [ToolItem] = switch item {
            case .tool(let t): [t]
            case .steps(let s): s.tools
            default: []
            }
            for tool in tools {
                if tool.tool == "propose_plan" { found = ItemRenderer.planContent(tool); todosSince = false }
                else if tool.tool == "todo", found != nil { todosSince = true }
            }
        }
        return found.map { ($0, todosSince) }
    }
}
