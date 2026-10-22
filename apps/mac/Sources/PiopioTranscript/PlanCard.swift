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
    static let footerHeight: CGFloat = 46
    nonisolated(unsafe) static let summaryFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    nonisolated(unsafe) static let stepFont = NSFont.systemFont(ofSize: 13.5)
    nonisolated(unsafe) static let smallFont = NSFont.systemFont(ofSize: 12.5)

    func height(width: CGFloat) -> CGFloat {
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
        total += 10 + Self.footerHeight
        return total + 8
    }

    /// Markdown markers dropped, for measuring.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    /// Inline Markdown (`code`, **bold**) as SwiftUI text.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct PlanCardView: View {
    let plan: PlanContent
    let act: @MainActor (TranscriptAction) -> Void

    private var pending: Bool { plan.state == .pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "list.number").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: DS.accent))
                Text("Plan").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: DS.fg2))
                status
                Spacer()
            }
            .frame(height: PlanContent.headerHeight)
            .padding(.bottom, 8)
            Text(PlanContent.inline(plan.summary)).font(Font(PlanContent.summaryFont)).foregroundStyle(Color(nsColor: DS.fg))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Color(nsColor: DS.accent))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color(nsColor: DS.accentSoft)))
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4.5 }
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(plan.risks.enumerated()), id: \.offset) { _, risk in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 10.5)).foregroundStyle(Color(nsColor: DS.amber))
                            Text(PlanContent.inline(risk)).font(Font(PlanContent.smallFont)).foregroundStyle(Color(nsColor: DS.fg2)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
            }
            if case .changes(let note?) = plan.state {
                Text("You asked for: \(note)").font(Font(PlanContent.smallFont)).foregroundStyle(Color(nsColor: DS.fg2)).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            Rectangle().fill(Color(nsColor: DS.line)).frame(height: 0.5).padding(.top, 10)
            footer.frame(height: PlanContent.footerHeight)
        }
        .padding(.horizontal, PlanContent.padding)
        .padding(.top, PlanContent.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: DS.card), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(pending ? Color(nsColor: DS.accentLine) : Color(nsColor: DS.line), lineWidth: pending ? 1 : 0.5))
    }

    @ViewBuilder private var status: some View {
        switch plan.state {
        case .pending: label("Waiting for you", DS.amber)
        case .approved: label("Approved", DS.green)
        case .approvedEdited: label("Approved with your edits", DS.green)
        case .changes: label("Sent back", DS.fg3)
        case .unanswered: label("Not answered", DS.fg3)
        }
    }

    private func label(_ text: String, _ color: NSColor) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Color(nsColor: color)).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color(nsColor: color == DS.fg3 ? DS.fg3 : color))
        }
    }

    @ViewBuilder private var footer: some View {
        if pending {
            HStack(spacing: 8) {
                button("Keep planning…", primary: false) { act(.plan(callId: plan.callId, answer: .revise)) }
                    .help("Tell the agent what to change; it plans again")
                Spacer()
                button("Edit…", primary: false) { act(.plan(callId: plan.callId, answer: .edit)) }
                    .help("Change, reorder or remove steps, then approve your version")
                button("Approve and build", primary: true) { act(.plan(callId: plan.callId, answer: .approve)) }
            }
        } else {
            HStack {
                Text(footnote).font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3))
                Spacer()
            }
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

    private func button(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: primary ? .semibold : .medium))
                .foregroundStyle(primary ? Color.white : Color(nsColor: DS.fg))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(primary ? Color(nsColor: DS.accent) : Color(nsColor: DS.chip), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
