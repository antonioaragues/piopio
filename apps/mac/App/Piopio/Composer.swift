import PiopioKit
import SwiftUI

/// Message input. Enter sends (queued after the current answer while the model is busy), ⌥Enter steers the
/// running answer, ⇧Enter adds a line, Esc stops (or cancels an edit).
struct Composer: View {
    let thread: ThreadModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !thread.queue.isEmpty { queue }
            if thread.editing != nil {
                HStack(spacing: 6) {
                    Image(systemName: "pencil").foregroundStyle(.secondary)
                    Text("Editing your message. Sending keeps the original as another version.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        thread.cancelEditing()
                        text = ""
                    }
                    .controlSize(.small)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                editor
                if thread.isRunning {
                    Button { Task { await thread.stop() } } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .help("Stop (Esc)")
                }
                Button { send(steer: false) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(thread.isRunning ? "Queue after the current answer (Enter) · Steer it now (⌥Enter)" : "Send (Enter)")
            }
        }
        .padding(12)
        .onAppear { focused = true }
        .onChange(of: thread.editing?.itemId) { _, id in
            guard id != nil, let original = thread.editing?.original else { return }
            text = original
            focused = true
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: 36, maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send(steer: press.modifiers.contains(.option))
                    return .handled
                }
                .onKeyPress(.escape) {
                    if thread.editing != nil {
                        thread.cancelEditing()
                        text = ""
                        return .handled
                    }
                    guard thread.isRunning else { return .ignored }
                    Task { await thread.stop() }
                    return .handled
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(thread.editing != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator)))
    }

    private var placeholder: String {
        if thread.editing != nil { return "Edit your message" }
        return thread.isRunning ? "Queue a follow-up… (⌥Enter to steer)" : "Message"
    }

    /// Messages waiting for the current answer to finish.
    private var queue: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(thread.queue.count == 1 ? "1 queued message" : "\(thread.queue.count) queued messages")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if thread.queue.count > 1 {
                    Button("Clear") { Task { await thread.clearQueue() } }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            ForEach(thread.queue, id: \.id) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.mode == .steer ? "arrow.turn.down.right" : "clock")
                        .foregroundStyle(.secondary)
                        .help(item.mode == .steer ? "Joins the current answer" : "Sent after the current answer")
                    Text(item.text ?? "Queued message")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button { Task { await thread.removeQueued(item.id) } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from queue")
                }
                .font(.callout)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func send(steer: Bool) {
        let message = text
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = ""
        Task { await thread.send(message, steer: steer && thread.isRunning) }
    }
}
