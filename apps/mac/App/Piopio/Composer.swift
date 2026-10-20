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
    /// Build: @-mention and /command suggestions shown above the box (docs/spec/05-build BR5).
    @State private var suggestions: [Suggestion] = []
    @State private var highlighted = 0
    @State private var sessionCommands: [SessionCommand] = []

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
            if !suggestions.isEmpty { suggestionList }
            box
        }
        .onChange(of: text) { _, value in if isBuild || isSpaceMain { suggest(for: value) } }
        .onChange(of: thread.draft) { _, draft in
            guard let draft else { return }
            text = draft
            thread.draft = nil
            focused = true
        }
        .task(id: thread.ref.id) { if isBuild { sessionCommands = await thread.commands() } }
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
                        if !suggestions.isEmpty { accept(suggestions[min(highlighted, suggestions.count - 1)]); return .handled }
                        send(steer: press.modifiers.contains(.option))
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard !suggestions.isEmpty else { return .ignored }
                        accept(suggestions[min(highlighted, suggestions.count - 1)])
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
                        highlighted = (highlighted + 1) % suggestions.count
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
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
            .font(.system(size: 13.5))
            HStack(spacing: 6) {
                if thread.editing == nil && !isBuild {
                    Button(action: pickFiles) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
                        .buttonStyle(.plain)
                        .background(Color.dsChip, in: Circle())
                        .help("Attach images, PDFs or text files (or drop them here)")
                }
                ModelChip(engine: engine, thread: thread)
                if thread.supportsThinking { ThinkingChip(thread: thread) }
                if isBuild {
                    Button { Task { await thread.setPlanMode(!thread.planMode) } } label: { Text("Plan") }
                        .buttonStyle(ChipStyle(active: thread.planMode))
                        .help(thread.planMode ? "Plan mode is on: the agent explores and proposes a plan before changing anything" : "Plan mode: explore and propose a plan before changing anything (/plan)")
                }
                if let context = thread.state?.context { ContextChip(context: context) }
                // Spaces always have the web tools (no per-conversation switch yet).
                if thread.editing == nil && !isBuild && thread.ref.kind != .space {
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

    /// Build sessions take files by path (the agent reads them) and have their own tools.
    private var isBuild: Bool { thread.ref.kind == .build }
    /// A Space's Main: @topic and /new, /main (04-chat S3).
    var isSpaceMain: Bool { thread.ref.kind == .space && thread.ref.conversationId == nil }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var placeholder: String {
        if thread.editing != nil { return "Edit your message" }
        if thread.isRunning { return "Queue a follow-up…" }
        if isBuild && thread.planMode { return "Plan mode: describe what you want; the agent proposes a plan first" }
        if isBuild, engine.buildSessions.first(where: { $0.ref.id == thread.ref.id })?.profile == .chat { return "Ask about these files, @mention one, or search the web…" }
        if thread.ref.kind == .space, let space = engine.space(thread.ref.id) {
            if let id = thread.ref.conversationId { return "Message \(space.topics?.first { $0.id == id }?.title ?? "this topic") directly" }
            return "Message \(space.title): the organizer picks the topic (@topic to choose)"
        }
        return isBuild ? "Ask, @mention files, or /command…" : "Message"
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
        text = ""
        attachments = []
        attachError = nil
        Task { await thread.send(message, attachments: files, steer: steer && thread.isRunning) }
    }
}

/// The context meter (docs/spec/05-build BR7): tokens in the model's context window.
struct ContextChip: View {
    let context: SessionState.Context

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dsLine).frame(width: 28, height: 4)
                Capsule().fill(fraction > 0.8 ? Color.dsAmber : Color.accentColor).frame(width: max(2, 28 * fraction), height: 4)
            }
            Text(label).font(.system(size: 11.5)).foregroundStyle(Color.dsFg2).monospacedDigit()
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Color.dsChip, in: Capsule())
        .help("Context: \(context.tokens.map { "\(Int($0)) of " } ?? "")\(Int(context.window)) tokens. pi compacts older messages automatically when it fills up.")
    }

    private var fraction: Double { min(1, (context.tokens ?? 0) / max(1, context.window)) }

    private var label: String {
        let window = Self.short(context.window)
        guard let tokens = context.tokens else { return "– / \(window)" }
        return "\(Self.short(tokens)) / \(window)"
    }

    static func short(_ n: Double) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", n / 1_000_000) : n >= 1000 ? "\(Int((n / 1000).rounded()))k" : "\(Int(n))"
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
                    HStack(spacing: 8) {
                        icon(suggestion).frame(width: 16)
                        Text(title(suggestion)).font(.system(size: 12.5, design: isFile(suggestion) ? .monospaced : .default)).lineLimit(1).truncationMode(.head)
                        Text(subtitle(suggestion)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(index == highlighted ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
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
