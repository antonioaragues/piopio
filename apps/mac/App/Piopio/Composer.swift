import PiopioKit
import PiopioTranscript
import SwiftUI
import UniformTypeIdentifiers

/// Floating glass composer (docs/design 2a, 8a): attachments, text, then a row of chips (attach, model,
/// thinking, web search) and a round send button. ↩ sends (queued while answering), ⌥↩ steers,
/// ⇧↩ adds a line, esc stops or cancels an edit.
struct Composer: View {
    let engine: EngineController
    let thread: ThreadModel
    @State private var text = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var attachError: String?
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(thread.queue, id: \.id) { item in
                HStack(spacing: 8) {
                    Text(item.mode == .steer ? "Steering" : "Queued").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Text(item.text ?? "Queued message").font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(1)
                    Spacer()
                    Button { Task { await thread.removeQueued(item.id) } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dsFg3)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from queue")
                }
                .padding(.horizontal, 16)
            }
            if let attachError {
                Text(attachError).font(.system(size: 12)).foregroundStyle(Color.dsRed).padding(.horizontal, 16)
            }
            if let error = thread.error {
                HStack {
                    Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed)
                    Spacer()
                    if thread.errorIsAuth { Button("Open Settings") { ThreadModel.openSettings() }.buttonStyle(PillStyle(compact: true)) }
                }
                .padding(.horizontal, 16)
            }
            box
        }
        .onChange(of: thread.editing?.itemId) { _, id in
            guard id != nil, let original = thread.editing?.original else { return }
            text = original
            focused = true
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 8) {
            if thread.editing != nil {
                HStack(spacing: 6) {
                    Image(systemName: "pencil").font(.system(size: 11))
                    Text("Editing your message. Sending keeps the original as another version.")
                    Spacer()
                    Button("Cancel") { cancelEdit() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.dsFg2)
            }
            if !attachments.isEmpty { chips }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(Color.dsFg3).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 22, maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg]) { providers in paste(providers) }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        send(steer: press.modifiers.contains(.option))
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if thread.editing != nil { cancelEdit(); return .handled }
                        guard thread.isRunning else { return .ignored }
                        Task { await thread.stop() }
                        return .handled
                    }
            }
            .font(.system(size: 13.5))
            HStack(spacing: 6) {
                if thread.editing == nil {
                    Button(action: pickFiles) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
                        .buttonStyle(.plain)
                        .background(Color.dsChip, in: Circle())
                        .help("Attach images, PDFs or text files (or drop them here)")
                }
                ModelChip(engine: engine, thread: thread)
                if thread.supportsThinking { ThinkingChip(thread: thread) }
                if thread.editing == nil {
                    Button { Task { await thread.setWeb(!thread.webEnabled) } } label: {
                        Label("Web search", systemImage: "globe").labelStyle(.titleOnly)
                    }
                    .buttonStyle(ChipStyle(active: thread.webEnabled))
                    .help(thread.webEnabled ? "Web search and page reading are on" : "Web search and page reading are off")
                }
                Spacer(minLength: 6)
                if thread.isRunning {
                    Text("⌥↩ steer · esc abort").font(.system(size: 11)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                Button { thread.isRunning && text.isEmpty ? stop() : send(steer: false) } label: {
                    Image(systemName: thread.isRunning && text.isEmpty ? "stop.fill" : "arrow.up")
                        .font(.system(size: thread.isRunning && text.isEmpty ? 9 : 12, weight: .bold))
                        .foregroundStyle(Color.dsInvFg)
                        .frame(width: 28, height: 28)
                        .background(Color.dsInv.opacity(canSend || thread.isRunning ? 1 : 0.25), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !thread.isRunning)
                .help(thread.isRunning ? (text.isEmpty ? "Stop (esc)" : "Queue after the current answer (↩) · Steer it now (⌥↩)") : "Send (↩)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .glassPanel(radius: DS.Radius.composer, material: .regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.composer).strokeBorder(dropTargeted || thread.editing != nil ? Color.dsAccentLine : .clear, lineWidth: 1))
        .onAppear { focused = true }
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var placeholder: String {
        if thread.editing != nil { return "Edit your message" }
        return thread.isRunning ? "Queue a follow-up…" : "Message"
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { a in
                    HStack(spacing: 6) {
                        Image(systemName: a.isImage ? "photo" : "doc.text").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                        Text(a.name).font(.system(size: 12.5)).lineLimit(1)
                        Button { attachments.removeAll { $0.id == a.id } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.dsFg3)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
                }
            }
        }
    }

    // MARK: Actions

    private func cancelEdit() {
        thread.cancelEditing()
        text = ""
    }

    private func stop() { Task { await thread.stop() } }

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

/// Capsule chip inside the composer (model, thinking, tools). `active` = accent tint.
struct ChipStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(active ? Color.accentColor : Color.dsFg2)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(active ? Color.dsAccentSoft : Color.dsChip, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct ModelChip: View {
    let engine: EngineController
    let thread: ThreadModel

    var body: some View {
        Button { thread.showModelPicker = true } label: {
            Text(engine.model(thread.state?.model).map(Self.short) ?? thread.state?.model?.id ?? "Model")
        }
        .buttonStyle(ChipStyle())
        .help("Change model")
        .popover(isPresented: Binding(get: { thread.showModelPicker }, set: { thread.showModelPicker = $0 }), arrowEdge: .top) {
            ModelPicker(engine: engine, selected: thread.state?.model) { model in
                thread.showModelPicker = false
                Task { await thread.setModel(model) }
            }
        }
    }

    /// "Anthropic: Claude Haiku 5.5" → "Claude Haiku 5.5".
    static func short(_ m: ModelInfo) -> String {
        m.name.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? m.name
    }
}

struct ThinkingChip: View {
    let thread: ThreadModel
    static let levels: [(value: String, title: String)] = [("default", "Default"), ("off", "Off"), ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Maximum")]

    var body: some View {
        Menu {
            ForEach(Self.levels, id: \.value) { level in
                Button {
                    Task { await thread.setThinking(level.value) }
                } label: {
                    if current == level.value { Label(level.title, systemImage: "checkmark") } else { Text(level.title) }
                }
            }
        } label: {
            Text("Think · \(Self.levels.first { $0.value == current }?.title.lowercased() ?? current)")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ChipStyle())
        .fixedSize()
        .help("How much the model reasons before answering")
    }

    private var current: String { thread.state?.thinking ?? "default" }
}
