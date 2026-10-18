import PiopioKit
import PiopioTranscript
import SwiftUI

struct ThreadView: View {
    let engine: EngineController
    let thread: ThreadModel
    let title: String
    @State private var showModels = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                TranscriptView(document: thread.document)
                if !thread.isFollowing {
                    Button { thread.scrollToLatest() } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.bottom, 10)
                }
            }
            if let error = thread.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            Composer(thread: thread)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showModels = true } label: {
                    Label(modelName, systemImage: "cpu").labelStyle(.titleAndIcon)
                }
                .help("Change model")
                .popover(isPresented: $showModels, arrowEdge: .bottom) {
                    ModelPicker(engine: engine, selected: thread.state?.model) { model in
                        showModels = false
                        Task { await thread.setModel(model) }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if let usage = thread.state?.usage, usage.inputTokens + usage.outputTokens > 0 {
                    Text(cost(usage))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(Int(usage.inputTokens)) in · \(Int(usage.outputTokens)) out · \(Int(usage.cacheReadTokens)) cached tokens")
                }
            }
        }
        .task { await thread.open() }
    }

    private var modelName: String {
        guard let ref = thread.state?.model else { return "Model" }
        return engine.model(ref)?.name ?? ref.id
    }

    private func cost(_ u: Usage) -> String {
        u.costUsd < 0.01 ? String(format: "$%.4f", u.costUsd) : String(format: "$%.2f", u.costUsd)
    }
}
