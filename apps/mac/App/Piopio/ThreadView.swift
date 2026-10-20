import PiopioKit
import PiopioTranscript
import SwiftUI

/// A thread (docs/design 8a): 60pt header, centered transcript, floating glass composer.
struct ThreadView: View {
    let engine: EngineController
    let thread: ThreadModel
    let summary: SessionSummary

    var body: some View {
        VStack(spacing: 0) {
            header
            if let suggestion = summary.suggestion {
                SpaceSuggestionBanner(engine: engine, thread: summary, suggestion: suggestion)
            }
            ZStack(alignment: .bottom) {
                TranscriptView(document: thread.document)
                VStack(spacing: 8) {
                    if !thread.isFollowing {
                        Button { thread.scrollToLatest() } label: {
                            Label("Jump to latest", systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(PillStyle(kind: .toolbar, compact: true))
                    }
                    Composer(engine: engine, thread: thread)
                        .frame(maxWidth: 636)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
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

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            Spacer(minLength: 12)
            Menu {
                Button("Copy as Markdown") { Task { await thread.copyAsMarkdown() } }
                Divider()
                Button("Export as Markdown…") { Task { await thread.export(.markdown) } }
                Button("Export as HTML…") { Task { await thread.export(.html) } }
                Button("Export as JSONL…") { Task { await thread.export(.jsonl) } }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(PillStyle(kind: .toolbar))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy or export this thread")
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 60)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var subtitle: String {
        var parts = ["Thread"]
        let files = thread.attachmentCount
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        if let usage = thread.state?.usage, usage.costUsd > 0 {
            parts.append(usage.costUsd < 0.01 ? String(format: "$%.4f", usage.costUsd) : String(format: "$%.2f", usage.costUsd))
        }
        if thread.state?.status == .running { parts.append("answering…") }
        return parts.joined(separator: " · ")
    }
}
