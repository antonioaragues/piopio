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
                HStack {
                    Text(error).font(.callout).foregroundStyle(.red)
                    Spacer()
                    if thread.errorIsAuth { Button("Open Settings") { ThreadModel.openSettings() }.controlSize(.small) }
                }
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
                if thread.supportsThinking {
                    Menu {
                        ForEach(Self.thinkingLevels, id: \.value) { level in
                            Button {
                                Task { await thread.setThinking(level.value) }
                            } label: {
                                if (thread.state?.thinking ?? "default") == level.value { Label(level.title, systemImage: "checkmark") } else { Text(level.title) }
                            }
                        }
                    } label: {
                        Label("Thinking: \(Self.thinkingTitle(thread.state?.thinking))", systemImage: "brain")
                    }
                    .help("How much the model reasons before answering")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Copy as Markdown") { Task { await thread.copyAsMarkdown() } }
                    Divider()
                    Button("Export as Markdown…") { Task { await thread.export(.markdown) } }
                    Button("Export as HTML…") { Task { await thread.export(.html) } }
                    Button("Export as JSONL…") { Task { await thread.export(.jsonl) } }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Copy or export this thread")
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
        .alert("Error details", isPresented: Binding(get: { thread.errorDetail != nil }, set: { if !$0 { thread.errorDetail = nil } })) {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(thread.errorDetail ?? "", forType: .string)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(thread.errorDetail ?? "")
        }
    }

    private static let thinkingLevels: [(value: String, title: String)] = [
        ("default", "Model default"), ("off", "Off"), ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Maximum"),
    ]

    private static func thinkingTitle(_ value: String?) -> String {
        thinkingLevels.first { $0.value == (value ?? "default") }.map { $0.value == "default" ? "Default" : $0.title } ?? (value ?? "Default")
    }

    private var modelName: String {
        guard let ref = thread.state?.model else { return "Model" }
        return engine.model(ref)?.name ?? ref.id
    }

    private func cost(_ u: Usage) -> String {
        u.costUsd < 0.01 ? String(format: "$%.4f", u.costUsd) : String(format: "$%.2f", u.costUsd)
    }
}
