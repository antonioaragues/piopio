import PiopioKit
import SwiftUI
import UniformTypeIdentifiers

/// Message input. Enter sends (queued after the current answer while the model is busy), ⌥Enter steers the
/// running answer, ⇧Enter adds a line, Esc stops (or cancels an edit).
struct Composer: View {
    let thread: ThreadModel
    @State private var text = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var attachError: String?
    @State private var dropTargeted = false
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
            if !attachments.isEmpty { chips }
            if let attachError {
                Text(attachError).font(.callout).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if thread.editing == nil {
                    Button(action: pickFiles) { Image(systemName: "paperclip").font(.title3) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Attach images, PDFs or text files (or drop them here)")
                    Button { Task { await thread.setWeb(!thread.webEnabled) } } label: {
                        Image(systemName: "globe").font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(thread.webEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .help(thread.webEnabled ? "Web search and page reading are on" : "Web search and page reading are off")
                }
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
        .background(dropTargeted ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear))
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
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
                .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg]) { providers in paste(providers) }
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

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { a in
                    HStack(spacing: 4) {
                        Image(systemName: a.isImage ? "photo" : "doc.text").foregroundStyle(.secondary)
                        Text(a.name).lineLimit(1)
                        Button { attachments.removeAll { $0.id == a.id } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
            }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .text, .sourceCode, .json, .xml, .commaSeparatedText, .data]
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        attachError = nil
        for url in urls {
            do { attachments.append(try AttachmentLoader.load(url)) } catch { attachError = error.localizedDescription }
        }
    }

    private func paste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
            } else if let type = [UTType.png, .tiff, .jpeg].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        do { attachments.append(try AttachmentLoader.load(imageData: data)) } catch { attachError = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func send(steer: Bool) {
        let message = text
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let files = attachments.map(\.attachment)
        text = ""
        attachments = []
        attachError = nil
        Task { await thread.send(message, attachments: files, steer: steer && thread.isRunning) }
    }
}
