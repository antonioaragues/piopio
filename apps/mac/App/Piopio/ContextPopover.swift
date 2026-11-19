import PiopioKit
import SwiftUI

/// What fills the model's context (docs/spec/05-build BR7), opened from the inspector footer or the composer's warning.
/// In grey ink (docs/design/grey): one bar, plain rows that expand, Compact as plain text and its confirmation as the one
/// black action. The categories are pi's total spread by their estimated shares, so they add up to it.
struct ContextPopover: View {
    let thread: ThreadModel
    @State private var expanded: Group.Kind?
    @State private var confirming = false

    private typealias Context = SessionState.Context
    private typealias Group = Context.Breakdown.Group
    private let disclosureWidth: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Context").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if let context = thread.state?.context {
                overview(context)
                if context.tokens != nil {
                    if let breakdown = context.breakdown, !breakdown.groups.isEmpty {
                        breakdownRows(breakdown)
                    } else {
                        Text("A breakdown appears once there's context to estimate.")
                            .foregroundStyle(Color.dsFg2)
                    }
                } else {
                    Text("Waiting for the next model response to update context usage.")
                        .foregroundStyle(Color.dsFg2)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                compactControls(context)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.dsFg)
        .padding(18)
        .frame(width: 340)
        .background(Color.dsCard)
    }

    private func overview(_ context: Context) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.tokens.map(Self.short) ?? "—").font(.system(size: 22, weight: .medium))
                Text("/ \(Self.short(context.window)) tokens").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                Spacer()
                if let tokens = context.tokens {
                    Text((tokens / max(1, context.window)).formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)

            if let tokens = context.tokens {
                let fraction = min(1, max(0, tokens / max(1, context.window)))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.dsTrack)
                        Capsule().fill(fraction >= 0.85 ? Color.dsFg : Color.dsFg2).frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
                HStack {
                    Text("Estimated")
                    Spacer()
                    Text("\(Self.short(max(0, context.window - tokens))) free").monospacedDigit()
                }
                .font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            }
        }
    }

    private func breakdownRows(_ breakdown: Context.Breakdown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("In this context").accessibilityAddTraits(.isHeader)
                Spacer()
                Text("Approx. tokens")
            }
            .font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            .padding(.trailing, disclosureWidth)
            .padding(.bottom, 4)

            ForEach(breakdown.groups, id: \.kind) { group in
                let isExpanded = expanded == group.kind
                Button { expanded = isExpanded ? nil : group.kind } label: {
                    tokenRow(group.tokens) { Text(group.kind.title) }
                        .overlay(alignment: .trailing) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.dsFg3)
                                .frame(width: 10)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))

                if isExpanded {
                    VStack(spacing: 6) {
                        ForEach(group.parts, id: \.label) { part in
                            tokenRow(part.tokens) { Text(part.label) }
                                .accessibilityElement(children: .combine)
                        }
                    }
                    .foregroundStyle(Color.dsFg2)
                    .padding(.leading, 12)
                    .padding(.bottom, 8)
                }
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
            }

            Text(breakdown.source == .request
                ? "Based on the latest request. Cached tokens still count."
                : "Based on the saved conversation. The next request may change it.")
                .font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                .padding(.top, 9)
        }
    }

    private func tokenRow<Label: View>(_ tokens: Double, @ViewBuilder label: () -> Label) -> some View {
        HStack {
            label()
            Spacer(minLength: 12)
            Text("≈ \(Self.short(tokens))").monospacedDigit().fixedSize(horizontal: true, vertical: false)
        }
        .padding(.trailing, disclosureWidth)
    }

    private func compactControls(_ context: Context) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            if confirming && thread.canCompact {
                Text("Summarize older messages and keep the most recent ones in context.")
                    .foregroundStyle(Color.dsFg2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Button("Cancel") { confirming = false }.buttonStyle(PillStyle(compact: true))
                    Button("Compact") {
                        confirming = false
                        Task { await thread.compact() }
                    }
                    .buttonStyle(PillStyle(kind: .primary, compact: true))
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Button(thread.isCompactingContext ? "Compacting…" : "Compact…") { confirming = true }
                    .buttonStyle(PillStyle(compact: true))
                    .disabled(!thread.canCompact)
                    .help("Summarize the conversation so far to free up room")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    static func short(_ tokens: Double) -> String {
        let precision = FloatingPointFormatStyle<Double>().precision(.fractionLength(0...1))
        if tokens >= 1_000_000 { return (tokens / 1_000_000).formatted(precision) + "M" }
        if tokens >= 1_000 { return (tokens / 1_000).formatted(precision) + "k" }
        return tokens.formatted(.number.precision(.fractionLength(0)))
    }
}

private extension SessionState.Context.Breakdown.Group.Kind {
    var title: String {
        switch self {
        case .instructions: "Instructions"
        case .tools: "Tool definitions"
        case .conversation: "Conversation"
        case .toolUse: "Tool use"
        case .attachments: "Your attachments"
        case .summaries: "Summaries"
        }
    }
}
