import PiopioKit
import SwiftUI

struct ContextPopover: View {
    let thread: ThreadModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var expanded: Group.Kind?
    @State private var confirming = false

    private typealias Context = SessionState.Context
    private typealias Group = Context.Breakdown.Group
    private let disclosureWidth: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Context").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if let context = thread.state?.context {
                overview(context)
                if let tokens = context.tokens {
                    if let breakdown = context.breakdown, !breakdown.groups.isEmpty {
                        breakdownRows(breakdown, total: tokens)
                    } else {
                        Text("A breakdown will appear when pi has context to estimate.")
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
        .frame(width: 360)
        .background(Color.dsCard)
    }

    private func overview(_ context: Context) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.tokens.map(Self.short) ?? "—").font(.system(size: 25, weight: .medium))
                Text("/ \(Self.short(context.window)) tokens").font(.system(size: 14)).foregroundStyle(Color.dsFg2)
                Spacer()
                if let tokens = context.tokens {
                    Text((tokens / context.window).formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)

            if let tokens = context.tokens {
                meter(tokens: tokens, window: context.window, groups: context.breakdown?.groups ?? [])
                HStack {
                    Text("Estimated by pi")
                    Spacer()
                    Text("\(Self.short(max(0, context.window - tokens))) free").monospacedDigit()
                }
                .font(.system(size: 11)).foregroundStyle(Color.dsFg2)
            }
        }
    }

    private func meter(tokens: Double, window: Double, groups: [Group]) -> some View {
        GeometryReader { geometry in
            let occupied = min(1, max(0, tokens / window)) * geometry.size.width
            let sum = groups.reduce(0) { $0 + $1.tokens }
            let scale = max(sum, tokens)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.dsTrack)
                Rectangle().fill(Color.dsFg3.opacity(0.55)).frame(width: occupied)
                if scale > 0 {
                    HStack(spacing: 0) {
                        ForEach(groups, id: \.kind) { group in
                            Rectangle().fill(group.kind.color(for: colorScheme)).frame(width: occupied * group.tokens / scale)
                        }
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func breakdownRows(_ breakdown: Context.Breakdown, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("In this context").fontWeight(.medium).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("Approx. tokens")
            }
            .font(.system(size: 11)).foregroundStyle(Color.dsFg2)
            .padding(.trailing, disclosureWidth)
            .padding(.bottom, 4)

            ForEach(breakdown.groups, id: \.kind) { group in
                let isExpanded = expanded == group.kind
                Button { expanded = isExpanded ? nil : group.kind } label: {
                    tokenRow(group.tokens) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(group.kind.color(for: colorScheme)).frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            Text(group.kind.title)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.dsFg2)
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
                    .padding(.leading, 24)
                    .padding(.bottom, 8)
                }
                Divider()
            }

            let difference = total - breakdown.groups.reduce(0) { $0 + $1.tokens }
            VStack(alignment: .leading, spacing: 4) {
                if difference > 0 {
                    Text("≈ \(Self.short(difference)) tokens unassigned")
                } else if difference < 0 {
                    Text("Category estimates exceed pi’s total by ≈ \(Self.short(-difference)). The segments show their relative shares.")
                }
                Text(breakdown.source == .request ? "Based on the latest prepared request. Cached tokens still occupy context." : "Based on the saved session. The next request may add or change context.")
            }
            .font(.system(size: 11)).foregroundStyle(Color.dsFg2)
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
        VStack(alignment: .trailing, spacing: 7) {
            if confirming && canCompact(context) {
                Text("Summarize older messages and keep the most recent ones in context.")
                    .foregroundStyle(Color.dsFg2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Cancel") { confirming = false }
                    Button("Compact") {
                        confirming = false
                        Task { await thread.compact() }
                    }
                }
            } else {
                Button(thread.isCompactingContext ? "Compacting…" : "Compact…") { confirming = true }
                    .disabled(!canCompact(context))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func canCompact(_ context: Context) -> Bool {
        (context.tokens ?? 0) > 0 && !thread.isRunning && thread.prompts.isEmpty && !thread.isCompactingContext
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

    func color(for scheme: ColorScheme) -> Color {
        let (light, dark): (UInt32, UInt32) = switch self {
        case .instructions: (0x8054C2, 0xB99AF4)
        case .tools: (0x3168C0, 0x76A9FA)
        case .conversation: (0x087F80, 0x55C6BD)
        case .toolUse: (0xA85C10, 0xEAB36A)
        case .attachments: (0xB74870, 0xF290B4)
        case .summaries: (0x47782E, 0x9AC677)
        }
        let rgb = scheme == .dark ? dark : light
        return Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
