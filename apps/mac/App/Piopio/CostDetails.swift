import PiopioKit
import SwiftUI

/// Conversation estimates and provider-key billing have different scopes and must never be added together.
struct CostDetails: View {
    let engine: EngineController
    var thread: ThreadModel?
    @State private var extra: ExtraCostSummary?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(thread == nil ? "Piopio request costs" : "Cost estimate").font(.headline)
            if let thread {
                LabeledContent("Conversation model estimate", value: money(thread.state?.usage.costUsd ?? 0))
                Text("Includes model usage reported in this conversation. Subagent costs may already be included.").font(.caption)
            }
            if let extra {
                LabeledContent("Additional requests", value: money(extra.knownUsd))
                ForEach(extra.breakdown) { row in
                    LabeledContent(row.kind == "web_search" ? "Web search (\(row.calls))" : "Utility requests (\(row.calls))", value: money(row.knownUsd))
                }
                if extra.unknownCalls > 0 { Text("Cost unavailable for \(extra.unknownCalls) request(s). They are excluded from these amounts.").foregroundStyle(Color.dsAmber) }
                if thread != nil { Text("Additional requests cover this whole chat, notebook or agent, including its branches and topics. Utility work without a conversation belongs to Piopio's app total.") }
                else { Text("Additional requests across Piopio since tracking began. Conversation model estimates are shown in each conversation.") }
            } else if let error { Text(error).foregroundStyle(Color.dsRed) }
            else { ProgressView().controlSize(.small) }
            Divider()
            Text("Provider billing is authoritative. OpenRouter key totals can include other apps and exclude other providers. Missing or subscription pricing is not a promise of zero cost.")
                .font(.caption).foregroundStyle(Color.dsFg2)
        }
        .font(.system(size: 12)).padding(18).frame(width: 340)
        .task {
            do {
                guard let client = engine.client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Connect to the engine to view costs.") }
                extra = try await client.call("usage.extras", ExtraCostParams(ref: thread?.ref), as: ExtraCostSummary.self)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func money(_ value: Double) -> String { String(format: "$%.4f", value) }
}
