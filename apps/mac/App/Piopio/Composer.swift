import SwiftUI

/// Message input. Enter sends (queues a follow-up while the model is answering), ⇧Enter adds a line, Esc stops.
struct Composer: View {
    let thread: ThreadModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(thread.isRunning ? "Queue a follow-up…" : "Message")
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
                        send()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard thread.isRunning else { return .ignored }
                        Task { await thread.stop() }
                        return .handled
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

            if thread.isRunning {
                Button { Task { await thread.stop() } } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .help("Stop (Esc)")
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send (Enter)")
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func send() {
        let message = text
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = ""
        Task { await thread.send(message) }
    }
}
