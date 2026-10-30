import PiopioKit
import PiopioTranscript
import SwiftUI
import UniformTypeIdentifiers

/// The composer (docs/design/grey 11b, 11e): a box as wide as the reading column. Attachments, text, then + (attach),
/// the edit mode (Build) and web search as plain text, and on the right the context ring past 60%, the model with its
/// thinking level, and send. ↩ sends (queued while answering, shown above the box), ⌥↩ steers, ⇧↩ adds a line,
/// esc or ⌘. stops or cancels an edit. With the box empty, Tab takes the
/// highlighted "Ask next" suggestion and ↑/↓ move it.
struct Composer: View {
    let engine: EngineController
    let thread: ThreadModel
    @Binding private var text: String
    @Binding private var attachments: [PendingAttachment]
    @State private var attachError: String?
    @State private var dropTargeted = false
    @FocusState private var focused: Bool
    /// Build: @-mention and /command suggestions shown above the box (docs/spec/05-build BR5).
    @State private var suggestions: [Suggestion] = []
    @State private var highlighted = 0
    @State private var sessionCommands: [SessionCommand] = []

    init(engine: EngineController, thread: ThreadModel) {
        self.engine = engine; self.thread = thread
        _text = Binding(get: { thread.composerText }, set: { thread.composerText = $0 })
        _attachments = Binding(get: { thread.composerAttachments }, set: { thread.composerAttachments = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(thread.queue, id: \.id) { item in
                HStack(spacing: 8) {
                    Text(thread.debate?.status == .running ? "Next round" : item.mode == .steer ? "Steering" : "Queued").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                    Text(item.text ?? "Queued message").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(1)
                    Spacer()
                    if let queued = item.text {
                        Button("Edit") { text = queued; focused = true; Task { await thread.removeQueued(item.id) } }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                            .help("Put it back in the box")
                        Text("·").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    Button("Remove") { Task { await thread.removeQueued(item.id) } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                        .help("Remove from queue").accessibilityLabel("Remove queued message")
                }
                .padding(.horizontal, 16)
            }
            if let attachError {
                Text(attachError).font(.system(size: 12)).foregroundStyle(Color.dsFg2).padding(.horizontal, 16)
            }
            if let error = thread.error {
                HStack {
                    Text(error).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    Spacer()
                    if !text.isEmpty { Button("Retry") { Task { await thread.retrySend() } }.buttonStyle(PillStyle(compact: true)).disabled(thread.isSubmitting) }
                    if thread.errorIsAuth { Button("Open Settings") { ThreadModel.openSettings() }.buttonStyle(PillStyle(compact: true)) }
                }
                .padding(.horizontal, 16)
            }
            if let context = thread.state?.context, let tokens = context.tokens, tokens / max(1, context.window) >= 0.85 {
                HStack(spacing: 4) {
                    Text("This conversation is at \(Int(min(1, tokens / max(1, context.window)) * 100))% of its context.").foregroundStyle(Color.dsFg3)
                    if isBuild {
                        Button("Compact now") { Task { await thread.compact() } }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 16)
            }
            if !suggestions.isEmpty { suggestionList }
            box
            if thread.isRunning {
                Text(thread.debate?.status == .running ? "esc to stop the debate" : text.isEmpty ? "esc to stop" : "↩ to queue · ⌥↩ to steer now · esc to stop").font(.system(size: 11)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity)
            }
        }
        .onChange(of: text) { _, value in
            suggest(for: value)
            thread.composing = !value.isEmpty
        }
        .onChange(of: thread.draft) { _, draft in
            guard let draft else { return }
            // Put above what you're writing (a quote from Select and ask, a mention, terminal output).
            text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? draft : draft + text
            thread.draft = nil
            focused = true
        }
        // Build: pi's commands. Chat: prompt templates and skills from pi's folder and packages.
        .task(id: thread.ref.id) { sessionCommands = await thread.commands() }
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
                    Button("Cancel") { cancelEdit() }.buttonStyle(.plain).foregroundStyle(Color.dsFg)
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.dsFg2)
            }
            if !attachments.isEmpty { chips }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(Color.dsFg3).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $text).accessibilityLabel("Message")
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 22, maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg]) { providers in paste(providers) }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if !suggestions.isEmpty { accept(suggestions[min(highlighted, suggestions.count - 1)]); return .handled }
                        send(steer: press.modifiers.contains(.option))
                        return .handled
                    }
                    .onKeyPress(characters: .decimalDigits) { press in
                        // 1–9 pick an answer while the agent asks and the box is empty (docs/design/grey 11d).
                        guard text.isEmpty, let prompt = thread.prompts.first, prompt.kind == .question || prompt.kind == .select,
                              let options = prompt.options, let n = Int(press.characters), options.indices.contains(n - 1) else { return .ignored }
                        Task { await thread.respond(prompt, PromptResponse(choice: options[n - 1])) }
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        if !suggestions.isEmpty {
                            accept(suggestions[min(highlighted, suggestions.count - 1)])
                            return .handled
                        }
                        guard text.isEmpty, let next = thread.document.askNext.current else { return .ignored }
                        text = next
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        if suggestions.isEmpty {
                            guard text.isEmpty, !thread.document.askNext.items.isEmpty else { return .ignored }
                            thread.document.askNext.move(1)
                            return .handled
                        }
                        highlighted = (highlighted + 1) % suggestions.count
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        if suggestions.isEmpty {
                            guard text.isEmpty, !thread.document.askNext.items.isEmpty else { return .ignored }
                            thread.document.askNext.move(-1)
                            return .handled
                        }
                        highlighted = (highlighted + suggestions.count - 1) % suggestions.count
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if !suggestions.isEmpty { suggestions = []; return .handled }
                        if thread.editing != nil { cancelEdit(); return .handled }
                        guard thread.isRunning else { return .ignored }
                        Task { await thread.stop() }
                        return .handled
                    }
            }
            .font(.system(size: 14))
            HStack(spacing: 2) {
                if thread.editing == nil {
                    Button(action: pickFiles) { Image(systemName: "plus").font(.system(size: 13)) }
                        .buttonStyle(IconButtonStyle(size: 26))
                        .help(isBuild ? "Mention files or folders (or drop them here)" : "Attach images, PDFs, text files or a folder (or drop them here)")
                        .accessibilityLabel(isBuild ? "Mention files or folders" : "Attach files or images")
                }
                if isBuild { EditModeChip(engine: engine, thread: thread) }
                if thread.debate != nil { Text("Debate").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).padding(.horizontal, 6) }
                // Spaces always have the web tools (no per-conversation switch yet).
                if thread.editing == nil && !isBuild && thread.ref.kind != .space && thread.ref.kind != .agent {
                    Button { Task { await thread.setWeb(!thread.webEnabled) } } label: {
                        Text(thread.webEnabled ? "Web search on" : "Web search off")
                    }
                    .buttonStyle(ChipStyle(active: thread.webEnabled))
                    .help(thread.webEnabled ? "Web search and page reading are on" : "Web search and page reading are off")
                }
                Spacer(minLength: 6)
                if let debate = thread.debate, debate.status == .running {
                    Text("Round \(debate.round) of up to \(debate.maxRounds)").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).padding(.horizontal, 6)
                } else {
                    ModelChip(engine: engine, thread: thread)
                }
                let stopping = thread.isRunning && text.isEmpty
                Button { stopping ? stop() : send(steer: false) } label: {
                    Image(systemName: stopping ? "stop.fill" : "arrow.up")
                        .font(.system(size: stopping ? 9 : 12, weight: .semibold))
                        .foregroundStyle(canSend || stopping ? Color.dsInvFg : Color.dsFg3)
                        .frame(width: 28, height: 28)
                        .background(canSend || stopping ? Color.dsInv : Color.dsChip, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !thread.isRunning)
                .accessibilityLabel(stopping ? "Stop response" : thread.isRunning ? "Send after this answer" : "Send message")
                .help(thread.isRunning ? (text.isEmpty ? "Stop (esc, ⌘.)" : "Queue after the current answer (↩) · Steer it now (⌥↩)") : "Send (↩)")
            }
        }
        .padding(.top, 12)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .composerBox()
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.composer, style: .continuous).strokeBorder(Color.dsFg3, lineWidth: dropTargeted ? 1 : 0))
        .background {
            Button("") { if thread.isRunning { stop() } }.keyboardShortcut(".", modifiers: .command).hidden()
        }
        .onAppear { focused = true }
    }

    /// Build sessions take files by path (the agent reads them) and have their own tools.
    private var isBuild: Bool { thread.ref.kind == .build }
    /// A Space's Main: @topic and /new, /main (04-chat S3).
    var isSpaceMain: Bool { thread.ref.kind == .space && thread.ref.conversationId == nil }

    private var canSend: Bool { !thread.isSubmitting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var placeholder: String {
        if thread.editing != nil { return "Edit your message" }
        if let debate = thread.debate {
            if debate.status == .running { return "Add a note for the next round…" }
            if !thread.isRunning { return "Ask for changes to the draft…" }
        }
        if thread.isRunning { return "Add to the queue, or ⌥↩ to steer now…" }
        if isBuild && thread.planMode { return "Plan only: describe what you want; the agent proposes a plan first" }
        if thread.ref.kind == .space, let space = engine.space(thread.ref.id) {
            if let id = thread.ref.conversationId { return "Message \(space.topics?.first { $0.id == id }?.title ?? "this topic")…" }
            return "Message \(space.title)…"
        }
        if thread.document.lastItem != nil { return "Reply…" }
        if isBuild, engine.buildSessions.first(where: { $0.ref.id == thread.ref.id })?.profile == .chat { return "Ask about these files, @mention one, or search the web…" }
        return isBuild ? "Ask, @mention files, or /command…" : "Message…"
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { a in
                    if let image = a.thumbnail {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
                            .overlay(alignment: .topTrailing) { removeAttachment(a).padding(3) }
                            .help(a.name)
                    } else {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(a.name).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).lineLimit(1)
                                Text(a.kindLabel).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                            }
                            removeAttachment(a)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 40)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
                    }
                }
            }
        }
    }

    private func removeAttachment(_ a: PendingAttachment) -> some View {
        Button { attachments.removeAll { $0.id == a.id } } label: {
            Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.dsFg3)
        }
        .buttonStyle(.plain)
        .help("Remove").accessibilityLabel("Remove attachment \(a.name)")
    }

    // MARK: Actions

    private func cancelEdit() {
        thread.cancelEditing()
        text = ""
    }

    private func stop() { Task { await thread.stop() } }

    private func pickFiles() {
        if isBuild {
            // Build reads files itself: they become @paths in the message.
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            if let cwd = thread.cwd { panel.directoryURL = URL(fileURLWithPath: cwd) }
            guard panel.runModal() == .OK else { return }
            for url in panel.urls { mention(url) }
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .pdf, .text, .sourceCode, .json, .xml, .commaSeparatedText, .data, .folder]
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        attachError = nil
        for url in urls {
            // A folder: in Build the agent reads it itself (@path); elsewhere its readable files are attached.
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if isBuild { mention(url) } else { addFolder(url) }
                continue
            }
            do { attachments.append(try AttachmentLoader.load(url)) } catch { attachError = error.localizedDescription }
        }
    }

    /// The folder's files, skipping hidden ones, dependencies and build output, and anything that can't be attached;
    /// at most `folderLimit`, so a whole repo can't flood the message.
    private func addFolder(_ folder: URL) {
        let skipped: Set<String> = ["node_modules", "build", "dist", ".build", "DerivedData", "Pods", "vendor", "__pycache__"]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var added = 0, unreadable = 0, more = false
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skipped.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard added < Self.folderLimit else { more = true; break }
            if let file = try? AttachmentLoader.load(url) { attachments.append(file); added += 1 } else { unreadable += 1 }
        }
        if more { attachError = "Attached the first \(Self.folderLimit) files of \(folder.lastPathComponent)." }
        else if added == 0 { attachError = "Nothing in \(folder.lastPathComponent) could be attached." }
        else if unreadable > 0 { attachError = "Skipped \(unreadable) file\(unreadable == 1 ? "" : "s") in \(folder.lastPathComponent) that can't be attached." }
    }

    private static let folderLimit = 20

    private func paste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in isBuild ? mention(url) : add([url]) }
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

    /// Build: a dropped file becomes its path (relative to the project) in the message; the agent reads it.
    private func mention(_ url: URL) {
        var path = url.path
        if let cwd = engine.buildSessions.first(where: { $0.ref.id == thread.ref.id })?.cwd, path.hasPrefix(cwd + "/") {
            path = String(path.dropFirst(cwd.count + 1))
        }
        text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + path + " "
    }

    private func send(steer: Bool) {
        let message = text
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Piopio's own commands run here; pi's templates, skills and extension commands go to the agent as typed.
        if isBuild, let command = BuiltInCommand.all.first(where: { "/\($0.name)" == message.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            text = ""
            command.run(thread)
            return
        }
        let files = attachments.map(\.attachment)
        attachError = nil
        Task { await thread.send(message, attachments: files, steer: steer && thread.isRunning) }
    }
}

/// The context ring: only past 60% of the model's context, in grey ink. Clicking compacts the conversation (Build).
/// Otherwise the number lives in the inspector.
struct ContextRing: View {
    let context: SessionState.Context
    let compact: (() -> Void)?

    var body: some View {
        if fraction > 0.6 {
            Button { compact?() } label: {
                ZStack {
                    Circle().stroke(Color.dsLine, lineWidth: 3)
                    Circle().trim(from: 0, to: fraction).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(compact == nil)
            .help("Context \(Int(fraction * 100))% full: \(context.tokens.map { "\(Self.short($0)) of " } ?? "")\(Self.short(context.window)) tokens." + (compact != nil ? " Click to compact the conversation." : ""))
        }
    }

    private var fraction: Double { min(1, (context.tokens ?? 0) / max(1, context.window)) }
    private var color: Color { fraction > 0.85 ? .dsFg : .dsFg2 }

    static func short(_ n: Double) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", n / 1_000_000).replacingOccurrences(of: ".0M", with: "M") : n >= 1000 ? "\(Int((n / 1000).rounded()))k" : "\(Int(n))"
    }
}

/// Capsule chip inside the composer (model, thinking, tools). `active` = accent tint.
/// A composer selector (docs/design/grey principle 6): plain 12.5 text in fg2, no chevron or capsule; a grey fill on
/// hover (radius 6, 3×6). `active` means it's on (web search, a picked option): fg instead of fg2.
struct ChipStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View { ChipBody(configuration: configuration, active: active) }
}

private struct ChipBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(active || hovering ? Color.dsFg : Color.dsFg2)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(hovering || configuration.isPressed ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.selector, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// "Sonnet 4.5 medium" (docs/design/grey 11f): the model, with its thinking level in fg3, as plain text. The popover holds the model
/// picker and, for models that reason, Thinking: Off / Low / Medium / High.
struct ModelChip: View {
    let engine: EngineController
    let thread: ThreadModel

    var body: some View {
        Button { thread.showModelPicker = true } label: {
            HStack(spacing: 4) {
                Text(engine.model(thread.state?.model).map { Self.label($0, engine: engine) } ?? thread.state?.model?.id ?? "Model")
                if thread.supportsThinking, let level = ThinkingLevel.title(thread.state?.thinking) { Text(level.lowercased()).foregroundStyle(Color.dsFg3) }
            }
        }
        .buttonStyle(ComposerChipStyle())
        .help("Model and thinking")
        .popover(isPresented: Binding(get: { thread.showModelPicker }, set: { thread.showModelPicker = $0 }), arrowEdge: .top) {
            ModelPicker(engine: engine, selected: thread.state?.model, accessory: thread.supportsThinking ? AnyView(thinking) : nil) { model in
                thread.showModelPicker = false
                Task { await thread.setModel(model) }
            }
        }
        .background {
            Button("") { cycleThinking() }.keyboardShortcut("t", modifiers: .command).hidden().disabled(!thread.supportsThinking)
        }
    }

    /// Thinking sits in the same menu, because the two choices go together.
    private var thinking: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Thinking").font(.system(size: 13)).foregroundStyle(Color.dsFg)
                Spacer()
                Text("⌘T to cycle").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            }
            NeutralSegmented(
                selection: Binding(get: { ThinkingLevel.value(thread.state?.thinking) }, set: { v in Task { await thread.setThinking(v) } }),
                options: ThinkingLevel.levels.map { (value: $0.value, title: $0.title) }
            )
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func cycleThinking() {
        let levels = ThinkingLevel.levels.map(\.value)
        let i = levels.firstIndex(of: ThinkingLevel.value(thread.state?.thinking)) ?? 0
        Task { await thread.setThinking(levels[(i + 1) % levels.count]) }
    }

    /// "Anthropic: Claude Haiku 5.5" → "Claude Haiku 5.5".
    static func short(_ m: ModelInfo) -> String {
        m.name.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? m.name
    }

    /// The chip's text: the model, and where it runs once more than one provider is connected (docs/spec/10:
    /// the selected model's provider is always visible).
    static func label(_ m: ModelInfo, engine: EngineController) -> String {
        let name = short(m).replacingOccurrences(of: "Claude ", with: "")
        return Set(engine.models.map(\.provider)).subtracting(["faux"]).count > 1 ? "\(name) · \(ModelPicker.providerTag(m))" : name
    }
}

enum ThinkingLevel {
    static let levels: [(value: String, title: String)] = [("off", "Off"), ("low", "Low"), ("medium", "Medium"), ("high", "High")]

    /// The level to show on the chip; nil for the model's default.
    static func title(_ level: String?) -> String? {
        guard let level, level != "default" else { return nil }
        return level == "xhigh" ? "Maximum" : levels.first { $0.value == level }?.title
    }

    /// The segment to select ("xhigh" shows as High; the default as Medium).
    static func value(_ level: String?) -> String {
        switch level {
        case "off", "low", "medium", "high": level!
        case "xhigh": "high"
        default: "medium"
        }
    }
}

/// Composer selectors (model, mode): plain text, a grey fill on hover (the same as ChipStyle).
struct ComposerChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ChipStyle().makeBody(configuration: configuration) }
}

/// "Ask before edits" (docs/design/grey 11g): how Build works on your files, as plain text. Each mode is described by
/// what it lets the agent do. Full auto sits below a divider.
struct EditModeChip: View {
    let engine: EngineController
    let thread: ThreadModel

    enum Mode: CaseIterable { case planOnly, askFirst, autoEdit, fullAuto }

    private var current: Mode {
        if thread.planMode { return .planOnly }
        return switch thread.approvalMode {
        case .ask: .askFirst
        case .autoEdit: .autoEdit
        case .fullAuto: .fullAuto
        }
    }

    private var project: ProjectInfo? {
        let cwd = engine.buildSessions.first { $0.ref.id == thread.ref.id }.flatMap { $0.projectPath ?? $0.cwd }
        return engine.projects.first { $0.path == cwd }
    }

    var body: some View {
        Menu {
            ForEach(Mode.allCases, id: \.self) { mode in
                if mode == .fullAuto { Divider() }
                Button { set(mode) } label: {
                    if mode == current { Label(Self.title(mode), systemImage: "checkmark") } else { Text(Self.title(mode)) }
                    Text(Self.summary(mode))
                }
            }
            if let project, current != .planOnly, project.approvalMode != thread.approvalMode {
                Divider()
                Button("Use “\(Self.title(current))” for new sessions in \(project.name)") { Task { await engine.setApprovalMode(thread.approvalMode, for: project) } }
            }
        } label: {
            Text(Self.title(current))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ComposerChipStyle())
        .fixedSize()
        .help(Self.summary(current))
    }

    private func set(_ mode: Mode) {
        Task {
            if mode == .planOnly {
                await thread.setPlanMode(true)
                return
            }
            if thread.planMode { await thread.setPlanMode(false) }
            await thread.setApprovalMode(mode == .askFirst ? .ask : mode == .autoEdit ? .autoEdit : .fullAuto)
        }
    }

    static func title(_ mode: Mode) -> String {
        switch mode {
        case .planOnly: "Plan"
        case .askFirst: "Ask before edits"
        case .autoEdit: "Auto-edit"
        case .fullAuto: "Full auto"
        }
    }

    static func summary(_ mode: Mode) -> String {
        switch mode {
        case .planOnly: "Looks around and writes a plan for you to approve first"
        case .askFirst: "Asks before each change or command"
        case .autoEdit: "Edits files, still asks for commands"
        case .fullAuto: "Only asks for risky commands and writes outside the project"
        }
    }

    static func color(_ mode: Mode) -> Color {
        switch mode {
        case .planOnly: .dsFg3
        case .askFirst: .dsAmber
        case .autoEdit: .dsFg3
        case .fullAuto: .accentColor
        }
    }
}

// MARK: Suggestions (@-mentions and /commands)

/// A row of the suggestion list: a file or folder to mention, or a command.
enum Suggestion: Hashable, Identifiable {
    case file(FileMatch)
    case builtIn(BuiltInCommand)
    case command(SessionCommand)
    /// A Space's Main: a topic to send to, or /new and /main.
    case topic(TopicInfo)
    case spaceCommand(name: String, summary: String)

    var id: String {
        switch self {
        case .file(let f): "file:\(f.path)"
        case .builtIn(let c): "piopio:\(c.name)"
        case .command(let c): "pi:\(c.name)"
        case .topic(let t): "topic:\(t.id)"
        case .spaceCommand(let name, _): "space:\(name)"
        }
    }

    static let spaceCommands: [Suggestion] = [
        .spaceCommand(name: "new", summary: "Start a topic: /new Title, then your message on the next line"),
        .spaceCommand(name: "main", summary: "Answer here in Main instead of routing"),
    ]
}

/// Commands the app handles itself (BR5: /plan, /compact, /model, /tree, plus review, commit, new).
struct BuiltInCommand: Hashable {
    let name: String
    let summary: String

    static let all = [
        BuiltInCommand(name: "plan", summary: "Plan mode on or off: explore and propose a plan before changing anything"),
        BuiltInCommand(name: "compact", summary: "Summarize older messages to free context"),
        BuiltInCommand(name: "model", summary: "Choose the model for this session"),
        BuiltInCommand(name: "tree", summary: "Go back to an earlier message (the session tree)"),
        BuiltInCommand(name: "review", summary: "Review this session's changes"),
        BuiltInCommand(name: "commit", summary: "Commit changes"),
        BuiltInCommand(name: "new", summary: "New session, on a branch or a worktree"),
    ]

    @MainActor func run(_ thread: ThreadModel) {
        switch name {
        case "plan": Task { await thread.setPlanMode(!thread.planMode) }
        case "compact": Task { await thread.compact() }
        case "model": thread.showModelPicker = true
        case "tree": thread.showTree = true
        case "review": NotificationCenter.default.post(name: .showReview, object: thread.ref.id)
        case "commit": NotificationCenter.default.post(name: .showCommit, object: thread.ref.id)
        case "new": NotificationCenter.default.post(name: .newThread, object: nil)
        default: break
        }
    }
}

extension Composer {
    /// The word being typed: "@query" at the end of the text.
    private var mentionQuery: String? {
        let word = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init) ?? ""
        guard text.last != " ", text.last != "\n", word.hasPrefix("@") else { return nil }
        return String(word.dropFirst())
    }

    func suggest(for value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if isSpaceMain {
            if trimmed.hasPrefix("/"), !trimmed.contains(" "), !value.contains("\n") {
                let q = trimmed.dropFirst().lowercased()
                suggestions = Suggestion.spaceCommands.filter { if case .spaceCommand(let name, _) = $0 { q.isEmpty || name.hasPrefix(q) } else { false } }
                    + sessionCommands.filter { q.isEmpty || $0.name.lowercased().contains(q) }.prefix(10).map(Suggestion.command)
            } else if trimmed.hasPrefix("@"), !value.contains("\n") {
                let q = trimmed.dropFirst().lowercased()
                let topics = engine.space(thread.ref.id)?.topics ?? []
                // Stop suggesting once a whole title (and a space) was typed.
                suggestions = topics.contains(where: { q.hasPrefix($0.title.lowercased() + " ") }) ? [] : topics.filter { q.isEmpty || $0.title.lowercased().hasPrefix(q) || $0.title.lowercased().contains(q) }.prefix(8).map(Suggestion.topic)
            } else if !suggestions.isEmpty {
                suggestions = []
            }
            highlighted = 0
            return
        }
        if !isBuild {
            // Threads and topics: templates and skills after "/".
            if trimmed.hasPrefix("/"), !trimmed.contains(" "), !value.contains("\n") {
                let q = trimmed.dropFirst().lowercased()
                suggestions = Array(sessionCommands.filter { q.isEmpty || $0.name.lowercased().contains(q) }.prefix(12).map(Suggestion.command))
            } else if !suggestions.isEmpty {
                suggestions = []
            }
            highlighted = 0
            return
        }
        if trimmed.hasPrefix("/"), !trimmed.contains(" "), !value.contains("\n") {
            let q = trimmed.dropFirst().lowercased()
            let builtIn = BuiltInCommand.all.filter { q.isEmpty || $0.name.hasPrefix(q) }.map(Suggestion.builtIn)
            let pi = sessionCommands.filter { q.isEmpty || $0.name.lowercased().contains(q) }.map(Suggestion.command)
            suggestions = Array((builtIn + pi).prefix(12))
            highlighted = 0
            return
        }
        guard let query = mentionQuery else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        Task {
            let files = await thread.files(matching: query)
            guard mentionQuery == query else { return } // typing moved on
            suggestions = files.map(Suggestion.file)
            highlighted = 0
        }
    }

    func accept(_ suggestion: Suggestion) {
        switch suggestion {
        case .file(let f):
            if let query = mentionQuery { text.removeLast(query.count + 1) }
            text += "@\(f.path)\(f.kind == .folder ? "/" : "") "
        case .builtIn(let c):
            text = ""
            c.run(thread)
        case .command(let c):
            text = "/\(c.name) "
        case .topic(let t):
            text = "@\(t.title) "
        case .spaceCommand(let name, _):
            text = "/\(name) "
        }
        suggestions = []
    }

    var suggestionList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { accept(suggestion) } label: {
                    HStack(spacing: 12) {
                        Text(title(suggestion)).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.head)
                        Text(subtitle(suggestion)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(index == highlighted ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .glassPanel(radius: DS.Radius.panel, material: .regularMaterial)
    }

    private func isFile(_ s: Suggestion) -> Bool { if case .file = s { true } else { false } }

    private func title(_ s: Suggestion) -> String {
        switch s {
        case .file(let f): f.path
        case .builtIn(let c): "/\(c.name)"
        case .command(let c): "/\(c.name)" + (c.hint.map { " \($0)" } ?? "")
        case .topic(let t): "@\(t.title)"
        case .spaceCommand(let name, _): "/\(name)"
        }
    }

    private func subtitle(_ s: Suggestion) -> String {
        switch s {
        case .file: ""
        case .builtIn(let c): c.summary
        case .command(let c): c.description.isEmpty ? (c.kind == .skill ? "Skill" : c.kind == .template ? "Prompt template" : "Extension command") : c.description
        case .topic(let t): t.brief ?? ""
        case .spaceCommand(_, let summary): summary
        }
    }

    @ViewBuilder private func icon(_ s: Suggestion) -> some View {
        let name: String = switch s {
        case .file(let f): f.kind == .folder ? "folder" : "doc"
        case .builtIn: "command"
        case .command(let c): c.kind == .skill ? "sparkles" : c.kind == .template ? "text.badge.plus" : "puzzlepiece.extension"
        case .topic: "number"
        case .spaceCommand: "command"
        }
        Image(systemName: name).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
    }
}
