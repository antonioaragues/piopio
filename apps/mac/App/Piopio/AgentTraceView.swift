import PiopioKit
import PiopioTranscript
import SwiftUI

struct TraceTarget: Identifiable { let id: String }

/// The trace view (06-agents §7 AA5): every message between agents in one exchange, as a tree of hops, with what
/// answering each one cost.
struct TraceSheet: View {
    let engine: EngineController
    let traceId: String
    @Environment(\.dismiss) private var dismiss
    @State private var trace: AgentTrace?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Between agents").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let trace { Text(String(format: "$%.4f in all", trace.costUsd)).font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.hop.id) { row in hop(row.hop, depth: row.depth) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Up to 4 hops, 30 messages an hour between two agents, $0.50 per exchange unless their policies say otherwise.")
                    .font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .task {
            do { trace = try await engine.trace(traceId) } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
        }
    }

    /// Hops depth-first under their parent.
    private var rows: [(hop: AgentTrace.Hop, depth: Int)] {
        guard let hops = trace?.hops else { return [] }
        var out: [(AgentTrace.Hop, Int)] = []
        func walk(_ parent: String?, _ depth: Int) {
            for h in hops where h.parent == parent || (parent == nil && !hops.contains { $0.id == h.parent }) {
                guard !out.contains(where: { $0.0.id == h.id }) else { continue }
                out.append((h, depth))
                walk(h.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    private func hop(_ h: AgentTrace.Hop, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(h.status == "failed" ? Color.dsFg2 : h.status == "waiting" ? Color.accentColor : h.status == "no_reply" ? Color.dsAmber : Color.dsFg3).frame(width: 6, height: 6)
                Text("\(h.from.name) → \(h.to.name)").font(.system(size: 12.5, weight: .semibold))
                Text("\(h.mode) · hop \(h.hop)").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                Spacer()
                if let cost = h.costUsd { Text(String(format: "$%.4f", cost)).font(.system(size: 11)).foregroundStyle(Color.dsFg3) }
                Text(BuildSessionView.relative(h.at)).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            }
            Text(h.text).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(3).textSelection(.enabled)
            if let reply = h.reply { Text("↳ \(reply)").font(.system(size: 12)).foregroundStyle(Color.dsFg).lineLimit(3).textSelection(.enabled) }
            if let error = h.error { Text(error).font(.system(size: 11.5)).foregroundStyle(Color.dsFg2) }
        }
        .padding(10)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
        .padding(.leading, CGFloat(depth) * 22)
    }
}
