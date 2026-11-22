import PiopioKit
import PiopioTranscript
import SwiftUI
import UniformTypeIdentifiers

/// The composer (docs/design/grey 11b, 11e): a box as wide as the reading column. Attachments, text, then + (attach),
/// the edit mode (Build) and web search as plain text, and on the right the model with its
/// thinking level, and send. ↩ sends (queued while answering, shown above the box), ⌥↩ steers, ⇧↩ adds a line,
/// esc or ⌘. stops or cancels an edit. With the box empty, Tab takes the
/// highlighted "Ask next" suggestion and ↑/↓ move it.
struct Composer: View {
    let engine: EngineController
    let thread: ThreadModel
    /// MCP servers as configured, for the + menu's switches (loaded when the conversation opens).
    @Binding private var text: String
    @Binding private var attachments: [PendingAttachment]
    @State private var attachError: String?
    @State private var dropTargeted = false
    @FocusState private var focused: Bool
    /// Build: @-mention and /command suggestions shown above the box (docs/spec/05-build BR5).
    @State private var suggestions: [Suggestion] = []
    @State private var highlighted = 0
    @State private var sessionCommands: [SessionCommand] = []
    /// The command chip at the start of the box (docs/spec/32 §4.2). Its own state, set only by picking a command, a
    /// space after one, or a message put in the box (a draft, an edit): the text field can't be rewritten under it
    /// while you type.
    @State private var chip: CommandChip?
    /// The tray (docs/design/grey "Composer tray"): which of the waiting prompts it shows, and whether it's folded to
    /// one line.
    @State private var trayIndex = 0
    @State private var trayCollapsed = false

    init(engine: EngineController, thread: ThreadModel) {
        self.engine = engine; self.thread = thread
        _text = Binding(get: { thread.composerText }, set: { thread.composerText = $0 })
        _attachments = Binding(get: { thread.composerAttachments }, set: { thread.composerAttachments = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(thread.queue, id: \.id) { item in
                HStack(spacing: 8) {
                    Text(item.mode == .steer ? "Steering" : "Queued").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
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
            // The context popover opened from elsewhere (a capture, the toolbar) while the context notice isn't showing.
            if thread.showContext, notice?.id != "context" {
                HStack(spacing: 4) {
                    viewContextButton
                    Spacer()
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 16)
            }
            if !suggestions.isEmpty { suggestionList }
            box
        }
        .onChange(of: text) { _, value in
            // Sent, cleared or edited away: the chip goes with its command.
            if let chip, !value.hasPrefix("/\(chip.name) ") { self.chip = nil }
            suggest(for: value)
            thread.composing = !value.isEmpty
        }
        .onChange(of: thread.draft) { _, draft in
            guard let draft else { return }
            // Put above what you're writing (a quote from Select and ask, a mention, terminal output).
            text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? draft : draft + text
            thread.draft = nil
            adoptChip()
            focused = true
        }
        // Build: pi's commands. Chat: prompt templates and skills from pi's folder and packages.
        .task(id: thread.ref.id) { sessionCommands = await thread.commands(); adoptChip() }
        .onChange(of: thread.editing?.itemId) { _, id in
            guard id != nil, let original = thread.editing?.original else { return }
            text = original
            adoptChip()
            focused = true
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        // Something new waiting on you opens the tray again.
        .onChange(of: thread.prompts.map(\.id)) { old, new in
            if new.contains(where: { !old.contains($0) }) { trayCollapsed = false }
            if new.isEmpty { trayIndex = 0; trayCollapsed = false }
        }
    }

    // MARK: Notice

    @State private var contextNoticeDismissed = false

    private var contextFraction: Double { thread.state?.context.map { ($0.tokens ?? 0) / max(1, $0.window) } ?? 0 }

    /// The one notice the box shows: what failed, then a file that couldn't be attached, then a context almost full.
    private var notice: ComposerNotice? {
        if let error = thread.error {
            let auth = thread.errorIsAuth, opening = thread.openFailed, typed = !text.isEmpty
            // Another model only helps when some provider is connected ("No model provider is connected" otherwise).
            let another = engine.providers.contains { $0.status == .connected }
            return ComposerNotice(
                id: "error", symbol: auth ? "key" : "exclamationmark.triangle", title: error,
                detail: opening ? (auth ? "this conversation opens once you connect" : nil) : typed ? "your message is kept" : nil,
                primary: auth ? .init(title: "Open Settings") { ThreadModel.openSettings() }
                    : typed && !opening && !thread.isSubmitting ? .init(title: "Retry") { Task { await thread.retrySend() } } : nil,
                secondary: auth && !opening && another ? .init(title: "Use another model") { thread.showModelPicker = true } : nil,
                dismiss: opening ? nil : { thread.dismissError() })
        }
        if let attachError {
            return ComposerNotice(id: "attach", symbol: "paperclip", title: attachError, dismiss: { self.attachError = nil })
        }
        // Just switched runner (docs/spec/31 CA7): Undo until the first message goes to the new one.
        if let from = thread.state?.handoff?.from, let now = thread.state?.model, !thread.isRunning {
            let runner = { (ref: ModelRef) in engine.model(ref).map { $0.isAgent ? ModelPicker.providerTag($0) : "Piopio's agent" } ?? (ref.provider == "claude-code" ? "Claude Code" : "Piopio's agent") }
            return ComposerNotice(
                id: "handoff", tone: .info, symbol: "arrow.triangle.swap",
                title: "Now running \(runner(now) == "Piopio's agent" ? "on" : "in") \(runner(now))",
                detail: "it starts from a summary of this conversation",
                primary: .init(title: "Undo") { Task { await thread.setModel(from) } })
        }
        if contextFraction >= 0.85, !contextNoticeDismissed {
            return ComposerNotice(
                id: "context", tone: .info, symbol: "gauge.with.dots.needle.67percent",
                title: "\(Int(min(1, contextFraction) * 100))% of context used",
                detail: thread.isCompactingContext ? "compacting…" : nil,
                primary: thread.canCompact && !thread.isCompactingContext ? .init(title: "Compact now") { Task { await thread.compact() } } : nil,
                dismiss: { contextNoticeDismissed = true })
        }
        return nil
    }

    private var viewContextButton: some View {
        Button("View context") { thread.showContext.toggle() }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            .fixedSize()
            .popover(isPresented: Binding(get: { thread.showContext }, set: { thread.showContext = $0 }), arrowEdge: .bottom) {
                ContextPopover(thread: thread)
            }
    }

    // MARK: Tray

    /// The prompt the tray shows: the first one, or the one the pager moved to.
    private var shownPrompt: PendingPrompt? {
        let prompts = thread.prompts
        return prompts.isEmpty ? nil : prompts[min(trayIndex, prompts.count - 1)]
    }

    /// What the agent waits on you for, glued to the top of the composer: an approval, a question, a plan. The
    /// composer below is its text field (Deny's reason, your own answer, what to change in the plan).
    @ViewBuilder private func tray(_ prompt: PendingPrompt) -> some View {
        Group {
            if trayCollapsed { collapsedTray(prompt) } else {
                PromptCard(session: thread, prompt: prompt, primary: true, tray: PromptTrayContext(
                    takeReply: takeReply, focusReply: { focused = true }, accessory: AnyView(trayAccessory)))
                    .id(prompt.id)
            }
        }
        .background(Color.dsWin, in: UnevenRoundedRectangle(topLeadingRadius: DS.Radius.composer, topTrailingRadius: DS.Radius.composer, style: .continuous))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }

    /// "‹ 1 of 3 ›" while more than one waits, and the button that folds the tray to one line.
    private var trayAccessory: some View {
        let count = thread.prompts.count, index = min(trayIndex, max(0, count - 1))
        return HStack(spacing: 0) {
            if count > 1 {
                trayIcon("chevron.left", help: "Previous") { trayIndex = (index + count - 1) % count }
                Text("\(index + 1) of \(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3).padding(.horizontal, 2)
                trayIcon("chevron.right", help: "Next") { trayIndex = (index + 1) % count }
            }
            trayIcon("chevron.down", help: "Fold to one line") { withAnimation(.smooth(duration: 0.2)) { trayCollapsed = true } }
                .padding(.leading, 4)
        }
    }

    private func trayIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dsFg3)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    /// Folded: the question, the command, how many more wait, and the one answer it has (⌘↩).
    private func collapsedTray(_ prompt: PendingPrompt) -> some View {
        let line = prompt.oneLine, more = thread.prompts.count - 1
        return HStack(spacing: 8) {
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            Text(line.question).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1).layoutPriority(1)
            if let detail = line.detail {
                Text(detail).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color.dsFg2).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if more > 0 { Text("\(more) more").font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize() }
            if let quick = prompt.quickAnswer {
                Button("\(quick.label) ⌘↩") { Task { await thread.respond(prompt, quick.response) } }
                    .buttonStyle(PillStyle(kind: .primary, compact: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .fixedSize()
            }
            trayIcon("chevron.up", help: "Show all of it") { withAnimation(.smooth(duration: 0.2)) { trayCollapsed = false } }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.smooth(duration: 0.2)) { trayCollapsed = false } }
    }

    /// What's typed, trimmed, for the tray's Deny or Keep planning; taking it empties the box.
    private func takeReply() -> String? {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return nil }
        text = ""
        return reply
    }

    /// ↩ while the tray waits on words: what you typed answers it instead of going out as a message. ⌥↩, a /command,
    /// attachments and editing a message still send as usual.
    private func answerTray() -> Bool {
        guard thread.editing == nil, attachments.isEmpty, let prompt = shownPrompt, prompt.takesReply else { return false }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, !reply.hasPrefix("/") else { return false }
        let response = switch prompt.kind {
        case .approval, .plan: PromptResponse(decision: .deny, text: reply)
        default: PromptResponse(text: reply)
        }
        text = ""
        Task { await thread.respond(prompt, response) }
        return true
    }

    private var box: some View {
        VStack(spacing: 0) {
            if let notice {
                ComposerNoticeStrip(notice: notice) { if notice.id == "context" { viewContextButton.font(.system(size: 12)) } }
                    .id(notice.id)
            }
            if let prompt = shownPrompt { tray(prompt) }
            field
        }
        .composerBox()
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.composer, style: .continuous).strokeBorder(Color.dsFg3, lineWidth: dropTargeted ? 1 : 0))
        .composerMorph()
        .background {
            Button("") { if thread.isRunning { stop() } }.keyboardShortcut(".", modifiers: .command).hidden()
        }
        .onAppear { focused = true }
    }

    private var field: some View {
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
            HStack(alignment: .top, spacing: 2) {
            if let chip {
                CommandChipView(chip: chip) { removeChip() }.padding(.top, 0.5)
            }
            ZStack(alignment: .topLeading) {
                if fieldText.wrappedValue.isEmpty {
                    Text(placeholder).foregroundStyle(Color.dsFg3).lineLimit(1).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: fieldText).accessibilityLabel("Message")
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
                        guard text.isEmpty, !trayCollapsed, let prompt = shownPrompt, prompt.kind == .question || prompt.kind == .select,
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
                    // ⌫ in an empty box takes the command chip off. The Mac's delete key sends U+007F, not SwiftUI's
                    // `.delete` (U+0008), so both.
                    .onKeyPress(keys: [.delete, KeyEquivalent("\u{7F}")]) { _ in
                        guard chip != nil, fieldText.wrappedValue.isEmpty else { return .ignored }
                        removeChip()
                        return .handled
                    }
                    // A space after a command typed by hand (`/goal`) makes its chip.
                    .onKeyPress(.space) {
                        guard chip == nil, text.hasPrefix("/"), let found = chipCommands[String(text.dropFirst())] else { return .ignored }
                        chip = found
                        text = "/\(found.name) "
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if !suggestions.isEmpty { suggestions = []; return .handled }
                        if chip != nil, fieldText.wrappedValue.isEmpty { removeChip(); return .handled }
                        if thread.editing != nil { cancelEdit(); return .handled }
                        guard thread.isRunning else { return .ignored }
                        Task { await thread.stop() }
                        return .handled
                    }
            }
            }
            .font(.system(size: 14))
            HStack(spacing: 2) {
                if thread.editing == nil {
                    AttachButton(pick: pickFiles, help: isBuild ? "Mention files or folders (⌘U)" : "Add files, photos or folders (⌘U)")
                }
                if isBuild { EditModeChip(engine: engine, thread: thread) }
                Spacer(minLength: 6)
                ModelChip(engine: engine, thread: thread)
                // esc and ⌥↩ are in the button's help and the placeholder, not a label beside it.
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
    }

    /// Build sessions take files by path (the agent reads them) and have their own tools.
    private var isBuild: Bool { thread.ref.kind == .build }

    /// A command with a chip needs words after it.
    private var canSend: Bool { !thread.isSubmitting && !(leading?.rest ?? text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The command chip at the start of the box and the words after it (docs/spec/32 §4.2). The message keeps the
    /// command as typed (`/goal words`), so drafts, the queue and editing see one string; the chip is how it shows.
    private var leading: (chip: CommandChip, rest: String)? {
        guard let chip, let l = CommandMenu.leading(text, commands: [chip.name]) else { return nil }
        return (chip, l.rest)
    }

    /// What the text field edits: the words after the chip, or all of it.
    private var fieldText: Binding<String> {
        Binding(get: { leading?.rest ?? text }, set: { new in
            if let chip { text = "/\(chip.name) " + new } else { text = new }
        })
    }

    /// A message put in the box that starts with a command that takes words shows it as a chip.
    private func adoptChip() {
        guard chip == nil, text.hasPrefix("/"), let l = CommandMenu.leading(text, commands: Set(chipCommands.keys)) else { return }
        chip = chipCommands[l.command]
    }

    private func removeChip() {
        chip = nil
        text = ""
        focused = true
    }

    private var placeholder: String {
        if thread.editing != nil { return "Edit your message" }
        if let prompt = shownPrompt, prompt.takesReply { return prompt.replyPlaceholder }
        if let chip { return chip.hint }
        if thread.isRunning { return "Add to the queue, or ⌥↩ to steer now…" }
        if isBuild && thread.planMode { return "Plan only: describe what you want; the agent proposes a plan first" }
        // An agent is set up by talking (docs/spec/21 D3): its chat says so.
        if thread.ref.kind == .agent, thread.ref.conversationId == nil {
            // A new agent is still asking what it's for (docs/spec/21 D4).
            let draft = engine.agents.first { $0.ref.id == thread.ref.id }?.agent?.draft == true
            return draft ? "In your own words…" : "Reply, or ask it to change how it works…"
        }
        // A coding agent runs this conversation (docs/spec/31 CA3).
        if let m = engine.model(thread.state?.model), m.isAgent {
            let agent = ModelPicker.providerTag(m)
            return thread.document.lastItem != nil ? "Reply to \(agent)…" : "Message \(agent)…"
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

    /// This conversation's summary from the catalog (for what it turned off).
    private var summary: SessionSummary? {
        let id = thread.ref.id
        return engine.threads.first { $0.ref.id == id } ?? engine.buildSessions.first { $0.ref.id == id }
    }

    /// The +: files and folders in one open panel. Build reads them itself, so they become @paths in the message (images
    /// are attached); elsewhere files are attached, and a folder's readable files.
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if isBuild {
            if let cwd = thread.cwd { panel.directoryURL = URL(fileURLWithPath: cwd) }
            guard panel.runModal() == .OK else { return }
            for url in panel.urls { mention(url) }
            return
        }
        panel.allowedContentTypes = [.folder, .image, .pdf, .text, .sourceCode, .json, .xml, .commaSeparatedText, .data]
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
        let (files, note) = AttachmentLoader.folder(folder)
        attachments.append(contentsOf: files)
        if let note { attachError = note }
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

    /// Build: a dropped or picked file becomes an @mention of its path (relative to the project), like one typed after
    /// @; the agent reads it, and Summary lists it under Context › You gave. An image is attached instead, so the box
    /// shows it as a thumbnail and the model sees it.
    private func mention(_ url: URL) {
        if !url.hasDirectoryPath, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            add([url])
            return
        }
        var path = url.path
        if let cwd = engine.buildSessions.first(where: { $0.ref.id == thread.ref.id })?.cwd, path.hasPrefix(cwd + "/") {
            path = String(path.dropFirst(cwd.count + 1))
        }
        if url.hasDirectoryPath, !path.hasSuffix("/") { path += "/" }
        text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + "@" + path + " "
    }

    private func send(steer: Bool) {
        let message = text
        guard !(leading?.rest ?? message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !steer, answerTray() { return }
        // `/side <what>` (docs/spec/24 §6): a side conversation with your words as its brief; this one goes on.
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMessage.hasPrefix("/side ") {
            let brief = String(trimmedMessage.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !brief.isEmpty else { return }
            text = ""
            Task {
                do { try await engine.startSide(from: thread.ref, brief: brief) } catch {
                    text = message
                    attachError = (error as? EngineError)?.message ?? error.localizedDescription
                }
            }
            return
        }
        // Piopio's commands that act run here; the others, and pi's templates, skills and extension commands, go to
        // the agent as typed.
        if let command = builtIns.first(where: { $0.hint == nil && "/\($0.name)" == trimmedMessage }) {
            text = ""
            command.run(thread)
            return
        }
        let files = attachments.map(\.attachment)
        attachError = nil
        Task { await thread.send(message, attachments: files, steer: steer && thread.isRunning) }
    }
}

/// Capsule chip inside the composer (model, thinking, tools). `active` = accent tint.
/// A composer selector (docs/design/grey principle 6): plain 12.5 text in fg2, no chevron or capsule; a grey fill on
/// hover (radius 6, 3×6). `active` means it's on (web search, a picked option): fg instead of fg2.
struct ChipStyle: ButtonStyle {
    var active = false
    /// Quieter than a selector: fg3 until hovered (the model on Home's box).
    var muted = false
    /// Shrinks with a "…" when the row is narrow (the model's name), instead of pushing the composer wider.
    var truncates = false
    func makeBody(configuration: Configuration) -> some View { ChipBody(configuration: configuration, active: active, muted: muted, truncates: truncates) }
}

private struct ChipBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    var muted = false
    var truncates = false
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5))
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: !truncates, vertical: true)
            .foregroundStyle(active || hovering ? Color.dsFg : muted ? Color.dsFg3 : Color.dsFg2)
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
                // A conversation that couldn't open for a missing provider (the notice above says which).
                if thread.state == nil, thread.errorIsAuth { Text("Model needed").foregroundStyle(Color.dsWarn) } else {
                    if let m = engine.model(thread.state?.model) { ModelLabel(model: m, engine: engine) } else { Text(thread.state?.model?.id ?? "Model") }
                }
                if thread.supportsThinking, let level = ThinkingLevel.title(thread.state?.thinking) { Text(level.lowercased()).foregroundStyle(Color.dsFg3).fixedSize() }
            }
        }
        // In a narrow composer (a subagent beside its conversation, docs/spec/37) the name gives way, not the box.
        .buttonStyle(ComposerChipStyle(truncates: true))
        .help("Model and thinking")
        .popover(isPresented: Binding(get: { thread.showModelPicker }, set: { thread.showModelPicker = $0 }), arrowEdge: .top) {
            ModelPicker(engine: engine, selected: thread.state?.model, accessory: thread.supportsThinking ? AnyView(thinking) : nil, agents: thread.ref.kind == .thread || thread.ref.kind == .build) { model in
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
    /// "Opus 5.5 · Claude Code", "Haiku 5.5 · OpenRouter": the model, then who runs it, once there's more than one
    /// (docs/spec/31 §5; ModelLabel adds the agent glyph).
    static func label(_ m: ModelInfo, engine: EngineController) -> String {
        let name = short(m).replacingOccurrences(of: "Claude ", with: "")
        return m.isAgent || Set(engine.models.map(\.provider)).subtracting(["faux"]).count > 1 ? "\(name) · \(ModelPicker.providerTag(m))" : name
    }
}

/// A model as the composer names it: the terminal glyph before a coding agent's (docs/spec/31), then ModelChip.label.
struct ModelLabel: View {
    let model: ModelInfo
    let engine: EngineController

    var body: some View {
        HStack(spacing: 4) {
            if model.isAgent { AgentGlyph(size: 11) }
            Text(ModelChip.label(model, engine: engine))
        }
    }
}

/// The mark of a coding agent (Claude Code): in the composer, the picker and Settings › Models.
struct AgentGlyph: View {
    var size: CGFloat = 12
    var body: some View {
        Image(systemName: "apple.terminal").font(.system(size: size, weight: .regular)).foregroundStyle(Color.dsFg2)
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
    var muted = false
    var truncates = false
    func makeBody(configuration: Configuration) -> some View { ChipStyle(muted: muted, truncates: truncates).makeBody(configuration: configuration) }
}

/// What the conversation may do in its folder (docs/spec/18 §4): Read only, Ask, Auto-edit, Full auto (below a divider),
/// and Plan. Switching into or out of Read only changes the tools live; the history stays.
struct EditModeChip: View {
    let engine: EngineController
    let thread: ThreadModel

    private var project: ProjectInfo? {
        let cwd = engine.buildSessions.first { $0.ref.id == thread.ref.id }.flatMap { $0.projectPath ?? $0.cwd }
        return engine.projects.first { $0.path == cwd }
    }

    var body: some View {
        Menu {
            // Without Build (the area is off), folders are Read only (docs/spec/18 §7): the other modes are greyed.
            let buildOn = Areas.shared.contains(.build)
            ForEach(ApprovalMode.allCases) { mode in
                if mode == .fullAuto { Divider() }
                Button { set(mode) } label: {
                    if !thread.planMode && mode == thread.approvalMode { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                    Text(buildOn || mode == .readOnly ? mode.summary : "Turn on Build in Settings › General to change files")
                }
                .disabled(!buildOn && mode != .readOnly)
            }
            Divider()
            Button { Task { await thread.setPlanMode(true) } } label: {
                if thread.planMode { Label("Plan", systemImage: "checkmark") } else { Text("Plan") }
                Text("Looks around and writes a plan for you to approve first")
            }
            .disabled(!buildOn)
            if let project, !thread.planMode, project.approvalMode != thread.approvalMode {
                Divider()
                Button("Use “\(thread.approvalMode.title)” for new conversations in \(project.name)") { Task { await engine.setApprovalMode(thread.approvalMode, for: project) } }
            }
        } label: {
            Text(thread.planMode ? "Plan" : thread.approvalMode.title)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ComposerChipStyle())
        .fixedSize()
        .help(thread.planMode ? "Plans first; changes after you approve" : thread.approvalMode.summary)
    }

    private func set(_ mode: ApprovalMode) {
        Task {
            if thread.planMode { await thread.setPlanMode(false) }
            await thread.setApprovalMode(mode)
        }
    }
}

// MARK: Suggestions (@-mentions and /commands)

/// A row of the suggestion list: a file or folder to mention, or a command.
enum Suggestion: Hashable, Identifiable {
    case file(FileMatch)
    /// Another session of the project, mentioned as background (`@conversation:<id>`, engine tools/history.ts).
    case conversation(id: String, title: String)
    case builtIn(BuiltInCommand)
    case command(SessionCommand)
    /// One of your agents, brought in for this message (docs/spec/21 D6).
    case agent(id: String, name: String)

    var id: String {
        switch self {
        case .agent(let id, _): "agent:\(id)"
        case .file(let f): "file:\(f.path)"
        case .conversation(let id, _): "conversation:\(id)"
        case .builtIn(let c): "piopio:\(c.name)"
        case .command(let c): "pi:\(c.name)"
        }
    }
}

/// Piopio's own commands (docs/spec/32 §4), the menu's first group in this order. Some act when picked (compact,
/// review…); the others take words: picking one puts a chip in the box with its hint as the placeholder, and the
/// message goes out as `/name words`.
struct BuiltInCommand: Hashable {
    let name: String
    let summary: String
    let icon: String
    var keywords: [String] = []
    /// Build sessions only.
    var buildOnly = false
    /// Takes words: the box's placeholder while its chip is there.
    var hint: String?
    /// The engine runs it (a pi extension, or a template Piopio bundles): listed only where the session has it.
    var engine = false

    static let all = [
        BuiltInCommand(name: "goal", summary: "Keep working until a goal is met", icon: "scope", keywords: ["done", "until", "finish"], buildOnly: true, hint: "What done looks like…", engine: true),
        BuiltInCommand(name: "side", summary: "A side conversation for something else; this one goes on", icon: "bubble.left.and.text.bubble.right", keywords: ["btw", "aside", "meanwhile"], hint: "What the side conversation is about…"),
        BuiltInCommand(name: "automation", summary: "Make an automation: work that starts on its own, once or on a schedule", icon: "clock", keywords: ["schedule", "timer", "remind", "every", "later", "cron"], hint: "What, and when or how often…", engine: true),
        BuiltInCommand(name: "grill-me", summary: "Pressure-test an idea: one question at a time until the plan is clear", icon: "questionmark.bubble", keywords: ["question", "interview", "idea", "pressure"], hint: "The idea to pressure-test…", engine: true),
        BuiltInCommand(name: "browser", summary: "Do it in the browser, where you can watch", icon: "globe", keywords: ["web", "page", "site"], hint: "What to do in the browser…", engine: true),
        BuiltInCommand(name: "compact", summary: "Summarize older messages to free context", icon: "arrow.down.right.and.arrow.up.left", keywords: ["context", "summarize"]),
        BuiltInCommand(name: "review", summary: "Review this session's changes", icon: "checklist", keywords: ["check", "diff"], buildOnly: true),
        BuiltInCommand(name: "commit", summary: "Commit changes", icon: "arrow.triangle.branch", keywords: ["git", "save"], buildOnly: true),
        BuiltInCommand(name: "model", summary: "Choose the model for this session", icon: "cpu", buildOnly: true),
        BuiltInCommand(name: "new", summary: "New session, on a branch or a worktree", icon: "square.and.pencil", keywords: ["worktree", "branch"], buildOnly: true),
    ]

    /// Piopio's commands this conversation has: Build's or both modes', and the engine's only where it lists them.
    static func available(build: Bool, session: [SessionCommand]) -> [BuiltInCommand] {
        let listed = Set(session.map(\.name))
        return all.filter { (build || !$0.buildOnly) && (!$0.engine || listed.contains($0.name)) }
    }

    @MainActor func run(_ thread: ThreadModel) {
        switch name {
        case "compact": Task { await thread.compact() }
        case "model": thread.showModelPicker = true
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

    /// Piopio's commands here, then pi's (templates, skills, extension commands) without those Piopio has by name.
    private var builtIns: [BuiltInCommand] { BuiltInCommand.available(build: isBuild, session: sessionCommands) }
    private var piCommands: [SessionCommand] {
        // Plan is a mode, set in the mode selector (docs/spec/32 §7), not a command: pi's /plan isn't listed.
        let own = Set(BuiltInCommand.all.map(\.name)).union(["plan"])
        return sessionCommands.filter { !own.contains($0.name) }
    }

    /// Every command for `/query`, grouped (Piopio's, skills, templates and extension commands) and matched by one
    /// rule (docs/spec/32 §4.1).
    private func commandSuggestions(_ q: String) -> [Suggestion] {
        let own = CommandMenu.filter(builtIns, query: q) { (names: [$0.name], keywords: $0.keywords, description: $0.summary) }
        let pi = { (kinds: Set<SessionCommand.Kind>) in
            CommandMenu.filter(piCommands.filter { kinds.contains($0.kind) }, query: q) { (names: [Self.label($0), $0.name], keywords: [], description: $0.description) }
        }
        return own.map(Suggestion.builtIn) + (pi([.skill]) + pi([.template, .extension])).map(Suggestion.command)
    }

    /// The commands that take words, by what's typed for them, for the chip.
    var chipCommands: [String: CommandChip] {
        var out: [String: CommandChip] = [:]
        for c in piCommands where c.kind == .skill || (c.kind == .template && c.hint != nil) {
            out[c.name] = CommandChip(name: c.name, label: Self.label(c), icon: Self.icon(c), hint: c.hint ?? "What the skill should do…", help: c.description)
        }
        for c in builtIns { if let hint = c.hint { out[c.name] = CommandChip(name: c.name, label: c.name, icon: c.icon, hint: hint, help: c.summary) } }
        return out
    }

    /// A skill by its name ("greet" for `skill:greet`).
    static func label(_ c: SessionCommand) -> String { c.kind == .skill && c.name.hasPrefix("skill:") ? String(c.name.dropFirst(6)) : c.name }
    static func icon(_ c: SessionCommand) -> String { c.kind == .skill ? "sparkles" : c.kind == .template ? "text.badge.plus" : "puzzlepiece.extension" }

    func suggest(for value: String) {
        // Leading spaces only: `/goal ` has a command and its chip, so the menu closes.
        let trimmed = String(value.drop(while: { $0 == " " }))
        if trimmed.hasPrefix("/"), !trimmed.contains(" "), !value.contains("\n") {
            suggestions = commandSuggestions(String(trimmed.dropFirst()))
            highlighted = 0
            return
        }
        if !isBuild {
            if let query = mentionQuery, query.count >= 2, !chatMentions(query).isEmpty {
                // A chat outside projects: your other such chats whose title matches, sent along as background.
                suggestions = chatMentions(query)
            } else if !suggestions.isEmpty {
                suggestions = []
            }
            highlighted = 0
            return
        }
        guard let query = mentionQuery else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        // The project's other sessions whose title matches, after the files.
        let here = engine.buildSessions.first { $0.ref.id == thread.ref.id }
        let project = here?.projectPath ?? here?.cwd
        let conversations = query.count < 2 || project == nil ? [] : engine.buildSessions
            .filter { $0.ref.id != thread.ref.id && ($0.projectPath ?? $0.cwd) == project && $0.title.localizedCaseInsensitiveContains(query) }
            .prefix(4)
            .map { Suggestion.conversation(id: $0.ref.id, title: $0.title) }
        // Your agents first: `@Rita` brings her in for this message.
        let agents = engine.agents
            .filter { $0.agent?.draft != true && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
            .prefix(4)
            .map { Suggestion.agent(id: $0.ref.id, name: $0.title) }
        Task {
            let files = await thread.files(matching: query)
            guard mentionQuery == query else { return } // typing moved on
            suggestions = Array((agents + files.map(Suggestion.file) + conversations).prefix(12))
            highlighted = 0
        }
    }

    /// Loose chats only (not in a project, not agents): the others whose title matches.
    private func chatMentions(_ query: String) -> [Suggestion] {
        guard thread.ref.kind == .thread,
              engine.threads.first(where: { $0.ref.id == thread.ref.id })?.projectPath == nil else { return [] }
        return engine.threads
            .filter { $0.ref.id != thread.ref.id && $0.projectPath == nil && $0.title.localizedCaseInsensitiveContains(query) }
            .prefix(6)
            .map { Suggestion.conversation(id: $0.ref.id, title: $0.title) }
    }

    func accept(_ suggestion: Suggestion) {
        switch suggestion {
        case .agent(_, let name):
            if let query = mentionQuery { text.removeLast(query.count + 1) }
            text += "@\(name) "
        case .file(let f):
            if let query = mentionQuery { text.removeLast(query.count + 1) }
            text += "@\(f.path)\(f.kind == .folder ? "/" : "") "
        case .conversation(let id, _):
            if let query = mentionQuery { text.removeLast(query.count + 1) }
            text += "@conversation:\(id) "
        case .builtIn(let c) where c.hint != nil:
            chip = chipCommands[c.name]
            text = "/\(c.name) "
        case .builtIn(let c):
            text = ""
            c.run(thread)
        case .command(let c):
            chip = chipCommands[c.name]
            text = "/\(c.name) "
        }
        suggestions = []
    }

    /// A command's group in the menu; nil for mentions.
    private func group(_ s: Suggestion) -> String? {
        switch s {
        case .builtIn: "Piopio"
        case .command(let c): c.kind == .skill ? "Skills" : "Templates and commands"
        default: nil
        }
    }

    /// The rows, with a small label before each group when there's more than one; about eight rows show, and ↑/↓
    /// keep the highlighted one in view.
    var suggestionList: some View {
        let groups = Set(suggestions.compactMap(group))
        let labelled = groups.count > 1
        let rows = suggestions.count, labels = labelled ? groups.count : 0
        let height = min(CGFloat(rows) * 31 + CGFloat(labels) * 24, 8.5 * 31)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        if labelled, let g = group(suggestion), index == 0 || group(suggestions[index - 1]) != g {
                            Text(g).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                                .padding(.horizontal, 10).frame(height: 23, alignment: .bottomLeading)
                        }
                        row(suggestion, highlighted: index == highlighted).id(suggestion.id)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: height)
            .onChange(of: highlighted) { _, i in
                guard suggestions.indices.contains(i) else { return }
                proxy.scrollTo(suggestions[i].id)
            }
        }
        .padding(6)
        .glassPanel(radius: DS.Radius.panel, material: .regularMaterial)
    }

    private func row(_ suggestion: Suggestion, highlighted: Bool) -> some View {
        Button { accept(suggestion) } label: {
            HStack(spacing: 8) {
                icon(suggestion).frame(width: 16)
                switch suggestion {
                case .file: Text(title(suggestion)).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.head)
                default: Text(title(suggestion)).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1).fixedSize()
                }
                Text(subtitle(suggestion)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(highlighted ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(suggestion))
    }

    private func help(_ s: Suggestion) -> String {
        if case .command(let c) = s, let source = c.source { return "\(c.description)\nFrom \(source)" }
        return subtitle(s)
    }

    private func title(_ s: Suggestion) -> String {
        switch s {
        case .file(let f): f.path
        case .conversation(_, let title): title
        case .builtIn(let c): c.name
        case .command(let c): Self.label(c)
        case .agent(_, let name): "@\(name)"
        }
    }

    private func subtitle(_ s: Suggestion) -> String {
        switch s {
        case .file: ""
        case .agent: "Your agent · joins for this message"
        case .conversation: isBuild ? "Conversation in this project, read as background" : "Another chat, sent along as background"
        case .builtIn(let c): c.summary
        case .command(let c): c.description.isEmpty ? (c.kind == .skill ? "Skill" : c.kind == .template ? "Prompt template" : "Extension command") : c.description
        }
    }

    @ViewBuilder private func icon(_ s: Suggestion) -> some View {
        let name: String = switch s {
        case .file(let f): f.kind == .folder ? "folder" : "doc"
        case .conversation: "bubble.left.and.text.bubble.right"
        case .agent: "person.crop.circle"
        case .builtIn(let c): c.icon
        case .command(let c): Self.icon(c)
        }
        Image(systemName: name).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
    }
}

/// A command that takes words, shown as a chip at the start of the box (docs/spec/32 §4.2).
struct CommandChip: Equatable {
    /// What's typed for it ("goal", "skill:greet").
    let name: String
    let label: String
    let icon: String
    /// The box's placeholder while the chip is there.
    let hint: String
    /// Its description, in the chip's help tag.
    let help: String
}

/// The chip: icon and name on a grey fill, and × to take it off (so do ⌫ and esc in an empty box).
struct CommandChipView: View {
    let chip: CommandChip
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: chip.icon).font(.system(size: 10.5))
            Text(chip.label).font(.system(size: 13))
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                    .frame(width: 12, height: 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? Color.dsFg2 : Color.dsFg3)
            .help("Remove /\(chip.name)")
            .accessibilityLabel("Remove command \(chip.label)")
        }
        .foregroundStyle(Color.dsFg)
        .padding(.leading, 6).padding(.trailing, 4)
        .frame(height: 20)
        .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .help(chip.help)
        .fixedSize()
    }
}

/// The composer's + (docs/design/summary, option 2): files and folders in one open panel (⌘U); dropping and pasting
/// work too. It's only for what goes with this message: what the conversation uses and knows is in its Summary column
/// (Setup › Uses, Knows), and commands and skills start with /.
struct AttachButton: View {
    let pick: () -> Void
    var help = "Add files, photos or folders (⌘U)"
    var size: CGFloat = 26
    var bordered = false

    var body: some View {
        Button(action: pick) {
            Image(systemName: "plus").font(.system(size: size > 30 ? 15 : 13))
        }
        .buttonStyle(IconButtonStyle(size: size))
        .keyboardShortcut("u", modifiers: .command)
        .fixedSize()
        .overlay { if bordered { RoundedRectangle(cornerRadius: DS.Radius.selector, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1).allowsHitTesting(false) } }
        .help(help)
        .accessibilityLabel("Add files or folders")
    }
}

