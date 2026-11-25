import AppKit
import Observation
import PiopioKit
import PiopioTranscript

/// One open thread: its transcript document, live session state, and actions.
@Observable @MainActor
final class ThreadModel {
    let ref: ContainerRef
    @ObservationIgnored let document: TranscriptDocument
    private(set) var state: SessionState?
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var errorIsAuth = false
    var isFollowing = true
    var composerText = "" { didSet { persistDraft() } }
    var composerAttachments: [PendingAttachment] = [] { didSet { persistDraft() } }
    private(set) var isSubmitting = false
    @ObservationIgnored private let draftStore: DraftStore
    @ObservationIgnored private let draftWriter: DraftWriter
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingInput: ComposerDraft?
    /// The stored draft couldn't be read when this model was made (the Mac locked, say: models are made for background
    /// work too). Until it's read, an empty composer isn't saved, since that would delete it; `open()` reads it again.
    @ObservationIgnored private var draftUnread = false
    private var mayWriteDraft: Bool { !draftUnread || !composerText.isEmpty || !composerAttachments.isEmpty }
    private var draftKey: String { "\(ref.kind.rawValue):\(ref.key)" }
    private func currentDraft() -> ComposerDraft {
        let same = pendingInput?.text.trimmingCharacters(in: .whitespacesAndNewlines) == composerText.trimmingCharacters(in: .whitespacesAndNewlines) && pendingInput?.attachments == composerAttachments.map(\.attachment) && pendingInput?.editItemId == editing?.itemId
        return ComposerDraft(text: composerText, attachments: composerAttachments.map(\.attachment), requestId: same ? pendingInput!.requestId : UUID().uuidString, editItemId: editing?.itemId, steer: same ? pendingInput!.steer : false)
    }
    private func persistDraft() {
        draftSaveTask?.cancel()
        guard mayWriteDraft else { return }
        let input = currentDraft()
        draftSaveTask = Task { [weak self, draftWriter, draftKey] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                try await draftWriter.save(input, for: draftKey)
            } catch is CancellationError {} catch {
                self?.error = "Couldn't save this draft: \(error.localizedDescription)"
            }
        }
    }
    func flushDraft() async throws {
        draftSaveTask?.cancel()
        guard mayWriteDraft else { return }
        try await draftWriter.save(currentDraft(), for: draftKey)
        try await draftWriter.save(pendingInput ?? ComposerDraft(), for: draftKey + "/pending")
    }
    func retrySend() async { await send(composerText, attachments: composerAttachments.map(\.attachment), steer: pendingInput?.steer ?? false) }

    /// The message being edited in the composer (sending re-asks from it as a new version).
    private(set) var editing: (itemId: String, original: String)?
    /// Raw provider error shown by "Details".
    var errorDetail: String?
    /// Opens the composer's model picker ("Use another model" in error cards).
    var showModelPicker = false
    /// Opens the context popover from the composer ("View context", or a capture).
    var showContext = false
    /// Build: the checkpoint "Restore…" was clicked on (the session view confirms it).
    var restoring: CheckpointItem?
    /// A plan being edited before approval (its sheet), and one being sent back (the bar's note field).
    var editingPlan: PendingPrompt?
    /// A /learn card being edited (docs/spec/14 M5): its items, to change, move or drop before saving.
    var editingLearn: LearnEdit?
    var revisingPlan: String?

    @ObservationIgnored private weak var engine: EngineController?
    @ObservationIgnored private var subscriptionId: String?

    /// Pending item to scroll to once the transcript is loaded (search results).
    @ObservationIgnored private var pendingReveal: String?
    @ObservationIgnored private let notifies: Bool

    init(ref: ContainerRef, engine: EngineController, notifies: Bool = true, compact: Bool = false) {
        let root = ref.kind == .build ? engine.buildSessions.first { $0.ref.id == ref.id }?.cwd : nil
        document = TranscriptDocument(compact: compact, versions: ref.kind == .thread, build: ref.kind == .build, root: root,
                                      attachments: engine.home.appending(path: "attachments").appending(path: ref.id))
        draftStore = DraftStore(home: engine.home)
        draftWriter = DraftWriter(store: draftStore)
        self.ref = ref
        self.engine = engine
        self.notifies = notifies
        restoreDraft()
        document.onFollowingChange = { [weak self] following in self?.isFollowing = following }
        document.onAction = { [weak self] action in self?.handle(action) }
        document.bottomInset = 150 // the floating composer sits over the bottom of the transcript
        if ref.kind == .build {
            document.rewindPreview = { [weak self] itemId in await self?.rewindPreview(itemId) }
            document.rewind = { [weak self] itemId, files in await self?.rewind(itemId, files: files) }
        }
        document.askNext.onSend = { [weak self] text in
            self?.document.showAskNext(nil)
            Task { await self?.send(text) }
        }
        document.askNext.onDismiss = { [weak self] in self?.dismissAskNext() }
        // After a correction (docs/spec/14 M5): /learn, or not in this conversation.
        document.askNext.onLearn = { [weak self] in
            self?.dismissLearnOffer()
            Task { await self?.send("/learn") }
        }
        document.askNext.onDismissLearn = { [weak self] in self?.dismissLearnOffer() }
        document.rememberDestination = compact ? nil : Self.rememberDestination(ref, engine: engine)
        // A subagent's first message is Piopio's brief (docs/spec/37).
        if ref.kind == .build, engine.buildSessions.first(where: { $0.ref.id == ref.id })?.parent != nil { document.briefFrom = "Piopio" }
    }

    var isRunning: Bool { state?.status == .running }
    /// Nothing needs it now, so EngineController may let it go (it keeps the most recent few): loaded (one that isn't
    /// costs little, and lists make them for every row), off screen, not running or waiting on you, nothing being sent
    /// or edited. Its draft is saved; opened again, it loads from the engine.
    var canLetGo: Bool {
        loaded && document.scrollView.window == nil && state?.status != .running && state?.status != .waitingApproval && prompts.isEmpty
            && queue.isEmpty && !isSubmitting && editing == nil && editingPlan == nil && editingLearn == nil && restoring == nil
    }
    /// Files sent in this conversation; the summary a switch of runner sends ("Conversation so far.md") isn't yours.
    var attachmentCount: Int {
        _ = state
        let handoffs = document.items.reduce(0) { n, item in
            if case .user(let u) = item { n + (u.attachments ?? []).filter { $0.name == "Conversation so far.md" }.count } else { n }
        }
        return document.attachmentCount - handoffs
    }
    var queue: [QueuedInput] { state?.queue ?? [] }
    var supportsThinking: Bool { engine?.model(state?.model)?.supports.reasoning ?? false }

    @ObservationIgnored private var opening: Task<Void, Never>?

    /// Subscribes once; concurrent callers wait for the same load.
    func open() async {
        if let opening { return await opening.value }
        let task = Task { await load() }
        opening = task
        await task.value
    }

    /// The stored draft into the composer, and the message that was being sent (`/pending`) for its retry identity.
    private func restoreDraft() {
        do {
            let saved = try draftStore.load(draftKey)
            let pending = try draftStore.load(draftKey + "/pending")
            draftUnread = false
            if let saved {
                pendingInput = saved
                if let id = saved.editItemId { editing = (id, saved.text) }
                composerAttachments = saved.attachments.map { PendingAttachment(name: $0.name, attachment: $0) }
                composerText = saved.text
            }
            if let pending { pendingInput = pending }
        } catch {
            draftUnread = true
        }
    }

    private func load() async {
        guard !loaded, let engine else { return }
        if draftUnread, composerText.isEmpty, composerAttachments.isEmpty { restoreDraft() }
        do {
            let sub = try await engine.subscribe(ref) { [weak self] events in self?.receive(events) }
            subscriptionId = sub.subscriptionId
            state = sub.snapshot.state
            await document.load(sub.snapshot)
            loaded = true
            revision += 1 // the items are there: views that read them refresh
            if let pendingReveal {
                self.pendingReveal = nil
                document.reveal(pendingReveal)
            }
            if openFailed { openFailed = false; error = nil; errorIsAuth = false }
        } catch {
            // A failed open isn't final: the next `open()` tries again, and one that failed for a missing provider
            // (a Build session needs its model's credential) tries again by itself once providers change.
            opening = nil
            openFailed = true
            report(error)
            if errorIsAuth { openWhenProvidersChange(engine) }
        }
    }

    /// The error is from opening the conversation (it opens by itself once that's fixed), not from sending.
    private(set) var openFailed = false

    /// The composer notice's ✕.
    func dismissError() { error = nil; errorIsAuth = false }

    private func openWhenProvidersChange(_ engine: EngineController) {
        withObservationTracking { _ = engine.providers } onChange: { [weak self] in
            Task { @MainActor in await self?.open() }
        }
    }

    func close() {
        if let subscriptionId { engine?.unsubscribe(subscriptionId) }
        subscriptionId = nil
        buffered = []
    }

    /// On a new engine connection: subscribe again and load what the engine has now (only if it was open).
    func reattach() async {
        guard loaded || opening != nil else { return }
        await opening?.value
        subscriptionId = nil
        buffered = []
        loaded = false
        opening = nil
        await open()
    }

    // Streaming sends a batch per token. Apply at most one batch per frame: the first at once,
    // then whatever piled up, with back-to-back deltas joined (one re-render of the open block, one refresh).
    @ObservationIgnored private var buffered: [SessionEvent] = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var lastFlush: ContinuousClock.Instant?
    private static let frame: Duration = .milliseconds(16)

    private func receive(_ events: [SessionEvent]) {
        buffered += events
        guard !flushScheduled else { return }
        if let lastFlush, ContinuousClock.now - lastFlush < Self.frame {
            flushScheduled = true
            Task { [weak self] in
                try? await Task.sleep(until: lastFlush + Self.frame, tolerance: .milliseconds(2), clock: .continuous)
                self?.flush()
            }
        } else {
            flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !buffered.isEmpty else { return }
        let events = SessionEvent.coalesced(buffered)
        buffered = []
        lastFlush = .now
        apply(events)
    }

    private func apply(_ events: [SessionEvent]) {
        document.apply(events)
        revision += 1
        let wasRunning = state?.status == .running
        for case .state(let s) in events { state = s }
        for case .resnapshot(let snap) in events { state = snap.state }
        refreshAskNext()
        if wasRunning, state?.status == .idle, notifies { engine?.answerFinished(in: self) }
        if notifies, let status = state?.status {
            let failed: Bool = if case .assistant(let a)? = document.lastItem { a.status == .error } else { false }
            engine?.liveStatus[ref.key] = failed && status == .idle ? .error : status
        }
    }

    func reveal(_ itemId: String) {
        if loaded { document.reveal(itemId) } else { pendingReveal = itemId }
    }

    /// Sends a message: a new version of the edited message when editing; otherwise a new message
    /// (queued after the current answer, or steering it with `steer`).
    @discardableResult
    func send(_ text: String, attachments: [Attachment] = [], steer: Bool = false) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return false }
        // Direct entry points (Home, suggestions) get the same recovery as the composer.
        if composerText.isEmpty {
            composerText = text
            composerAttachments = attachments.map { PendingAttachment(name: $0.name, attachment: $0) }
        }
        let candidate = ComposerDraft(text: trimmed, attachments: attachments, editItemId: editing?.itemId, steer: steer)
        let previous = pendingInput
        let input = previous?.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed && previous?.attachments == attachments && previous?.editItemId == candidate.editItemId && previous?.steer == steer ? previous! : candidate
        pendingInput = input
        persistDraft()
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await flushDraft()
            guard let client = engine?.client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "Piopio is reconnecting. Your message is saved; retry when connected.") }
            if let itemId = input.editItemId {
                _ = try await client.call("sessions.edit", EditParams(ref: ref, itemId: itemId, text: trimmed, clientRequestId: input.requestId), as: JSONValue.self)
            } else {
                _ = try await client.call("sessions.submit", SubmitParams(ref: ref, text: trimmed, attachments: attachments, whenBusy: steer ? .steer : .followUp, clientRequestId: input.requestId), as: SubmitResult.self)
            }
            pendingInput = nil
            editing = nil
            if composerText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed && composerAttachments.map(\.attachment) == attachments {
                composerText = ""; composerAttachments = []
            }
            error = nil; errorIsAuth = false
            do { try await flushDraft() } catch { self.error = "Message sent, but the local draft couldn't be updated: \(error.localizedDescription)" }
            return true
        } catch { report(error); return false }
    }

    var webEnabled: Bool { state?.tools?.web ?? true }

    func setWeb(_ enabled: Bool) async {
        await call("sessions.configure", ConfigureParams(ref: ref, web: enabled))
    }

    /// Connectors and MCP servers turned off in this conversation (docs/design/session-panel, step 3).
    func setToolsOff(_ ids: [String]) async {
        await call("sessions.configure", ConfigureParams(ref: ref, toolsOff: ids))
    }

    func cancelEditing() { editing = nil }

    func beginEditing(_ itemId: String, original: String) { editing = (itemId, original) }

    func handle(_ action: TranscriptAction) {
        switch action {
        case .edit(let id):
            // Build: rewind the chat (not the files) to before it, and put it in the composer (chat v3, 14b).
            if ref.kind == .build { Task { await rewind(id, files: false) } }
            else if case .user(let u) = document.item(id) { beginEditing(id, original: u.text) }
        case .regenerate(let id):
            Task { await call("sessions.regenerate", ItemParams(ref: ref, itemId: id)) }
        case .fork(let id):
            Task { await fork(id) }
        case .switchBranch(let branch):
            Task { await call("sessions.switchBranch", SwitchBranchParams(ref: ref, branch: branch)) }
        case .openSettings:
            Self.openSettings()
        case .chooseModel:
            showModelPicker = true
        case .showErrorDetail(let id):
            if case .assistant(let a) = document.item(id) { errorDetail = a.errorDetail ?? a.error }
        case .copy, .copyText:
            break // handled by the document
        case .continueAnswer:
            Task { await send("Continue") }
        case .reply(let text):
            Task { await send(text) }
        case .openVisual(let id):
            guard case .tool(let t)? = document.item(id), let html = t.args?["html"]?.stringValue else { return }
            let visual = ShownVisual(title: t.args?["title"]?.stringValue ?? "Visual", html: html,
                                     send: { [weak self] text in Task { await self?.send(text) } },
                                     prefill: { [weak self] text in self?.draft = text })
            NotificationCenter.default.post(name: .showVisual, object: visual)
        case .prefill(let text):
            draft = text
        case .openApp(let path):
            // Its page, with its conversation beside it (docs/spec/35 §15).
            NotificationCenter.default.post(name: .viewFile, object: URL(fileURLWithPath: path))
        case .pinApp(let path):
            Task { do { try await engine?.pinApp(path) } catch { report(error) } }
        case .offer(let kind, let callId):
            // Piopio's offers (docs/spec/26 CL9): the conversation's page acts on them (parallel work).
            NotificationCenter.default.post(name: .transcriptOffer, object: ref.id, userInfo: ["kind": kind, "call": callId])
        case .openAutomation(let id):
            NotificationCenter.default.post(name: .selectItem, object: SidebarItem.automation(id).raw)
        case .removeAutomation(let id):
            Task { do { try await engine?.removeAutomation(id) } catch { report(error) } }
        case .restoreAutomation(let id):
            Task { do { try await engine?.restoreAutomation(id) } catch { report(error) } }
        case .undoAutomation(let id, let undoId):
            // The document turns it into one of these first; kept for completeness.
            if let undoId { Task { do { try await engine?.undo(ref, undoId: undoId) } catch { report(error) } } }
            else { Task { do { try await engine?.removeAutomation(id) } catch { report(error) } } }
        case .quote(let text):
            // Select and ask: the fragment as a Markdown quote, above what's already in the composer.
            draft = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
        case .remember(let text):
            Task { do { try await remember(text) } catch { report(error) } }
        case .restoreCheckpoint(let id):
            if case .checkpoint(let c) = document.item(id) { restoring = c }
        case .openSession(let id) where id.hasPrefix("run:"):
            // An agent's run, from its line in the chat: the agent page shows it (docs/spec/21 D3).
            NotificationCenter.default.post(name: .openAgentRun, object: id)
        case .openSession(let id):
            NotificationCenter.default.post(name: .selectBuildSession, object: id)
        case .learn(let kind, let callId):
            Task { await learn(kind, callId) }
        case .openConversation(let id):
            // An earlier conversation a turn found (docs/spec/14 M4): a chat or a Build session, wherever it lives.
            NotificationCenter.default.post(name: .selectThread, object: id)
        case .openFile(let path, _) where ref.kind == .thread:
            // A chat has no files panel: the files it made open in the viewer sheet, as the files you sent do.
            NotificationCenter.default.post(name: .viewFile, object: URL(fileURLWithPath: path))
        case .openFile(let path, let line):
            viewing = FileTarget(path: path, line: line)
        case .openAttachment(let stored):
            guard let engine else { return }
            let url = engine.home.appending(path: "attachments").appending(path: ref.id).appending(path: stored)
            NotificationCenter.default.post(name: .viewFile, object: url)
        case .revealFile(let path):
            NotificationCenter.default.post(name: .revealInInspector, object: RevealTarget(sessionId: ref.id, path: path))
        case .decideApproval(let approvalId, let approve):
            Task { do { try await engine?.decide(ref, approvalId: approvalId, approve: approve) } catch { report(error) } }
        case .allowAlways(let approvalId):
            Task { do { try await engine?.decide(ref, approvalId: approvalId, approve: true, always: true) } catch { report(error) } }
        case .editApproval(let approvalId):
            NotificationCenter.default.post(name: .openInbox, object: approvalId)
        case .undoChange(let undoId):
            Task { do { try await engine?.undo(ref, undoId: undoId) } catch { report(error) } }
        case .openTrace(let traceId):
            NotificationCenter.default.post(name: .openTrace, object: traceId)
        case .plan(let callId, let answer):
            guard let prompt = prompts.first(where: { $0.kind == .plan && $0.callId == callId }) else { return }
            switch answer {
            case .approve: Task { await respond(prompt, PromptResponse(decision: .allow)) }
            case .edit: editingPlan = prompt
            case .revise: revisingPlan = prompt.id
            }
        }
    }

    /// Where Remember this saves: About me in conversations; in an agent, its memory of this person.
    static func rememberDestination(_ ref: ContainerRef, engine: EngineController) -> String {
        guard ref.kind == .agent else { return "About me" }
        let name = engine.agents.first { $0.ref.id == ref.id }?.title ?? "the agent"
        return "\(name)'s memory"
    }

    /// A /learn card's choices (docs/spec/14 M5). Review is the document's own.
    func learn(_ kind: String, _ callId: String, items: [LearnItem]? = nil) async {
        guard let engine, let client = engine.client else { return }
        do {
            switch kind {
            case "save": _ = try await client.call("learn.save", LearnSaveParams(ref: ref, callId: callId, items: items), as: LearnSaveResult.self)
            case "later", "dismiss", "undo": try await engine.spaceCall("learn.answer", LearnAnswerParams(ref: ref, callId: callId, choice: kind))
            case "edit":
                guard let item = document.items.last(where: { if case .tool(let t) = $0 { t.callId == callId } else { false } }),
                      case .tool(let t) = item, case .learn(let file, let items)? = t.typedDetails else { return }
                editingLearn = LearnEdit(callId: callId, file: file, items: items, hasProject: ref.kind == .build)
                return
            default: return
            }
            try? await engine.refreshCatalog()
        } catch { report(error) }
    }

    /// Remember this: one fact, written by you, in the bank the destination names.
    private func remember(_ text: String) async throws {
        guard let engine else { return }
        if ref.kind == .agent {
            let person = ref.conversationId?.hasPrefix("person:") == true ? String(ref.conversationId!.dropFirst(7)) : "owner"
            let provider = (await engine.agentMemory(ref))?.provider ?? "builtin"
            let bank = person == "owner" ? "\(ref.id)/owner" : "\(ref.id)/contacts/\(person)"
            try await engine.spaceCall("memory.add", MemoryAddParams(provider: provider, bank: bank, text: text))
        } else {
            try await engine.spaceCall("memory.add", MemoryAddParams(provider: engine.settings?.aboutMe.provider ?? "builtin", bank: "about-me", text: text))
        }
    }

    private func fork(_ itemId: String) async {
        guard let client = engine?.client else { return }
        do {
            let copy = try await client.call("sessions.fork", ItemParams(ref: ref, itemId: itemId), as: CreateSessionResult.self).ref
            try? await engine?.refreshCatalog()
            NotificationCenter.default.post(name: .selectThread, object: copy.id)
        } catch {
            report(error)
        }
    }

    func removeQueued(_ id: String) async {
        await call("sessions.queue.remove", QueueRemoveParams(ref: ref, queueId: id))
    }

    /// Calls the engine for this thread; failures show above the composer.
    private func call(_ method: String, _ params: some Encodable & Sendable) async {
        guard let client = engine?.client else { report(EngineError(code: "ENGINE_UNAVAILABLE", message: "Piopio is reconnecting. Try again when connected.")); return }
        do {
            _ = try await client.call(method, params, as: JSONValue.self)
            error = nil
            errorIsAuth = false
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        if let e = error as? EngineError {
            errorIsAuth = e.code == "AUTH"
            // "OpenRouter isn't connected. Connect it in Settings › Models.": the notice's Open Settings says the rest.
            let first = e.message.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            self.error = errorIsAuth ? (first ?? "Connect a model provider in Settings › Models") : e.message
        } else {
            errorIsAuth = false
            self.error = error.localizedDescription
        }
    }

    static func openSettings() {
        if let open = WindowOpener.shared.openSettings {
            open()
            NSApp.activate()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    func stop() async {
        _ = try? await engine?.client?.call("sessions.abort", RefParams(ref: ref), as: Empty.self)
    }

    func setModel(_ model: ModelRef) async {
        _ = try? await engine?.client?.call("sessions.configure", ConfigureParams(ref: ref, model: model), as: Empty.self)
    }

    /// `"default"` returns to the model's default.
    // MARK: Composer and plan mode (Build)

    /// Text to put in the composer (terminal output).
    var draft: String?
    /// The file shown in the viewer (BR4).
    var viewing: FileTarget?
    var planMode: Bool { state?.planMode ?? false }
    var todos: [Todo] { state?.todos ?? [] }
    /// The session's folder (a worktree for worktree sessions).
    var cwd: String? { engine?.buildSessions.first { $0.ref.id == ref.id }?.cwd }

    func setPlanMode(_ on: Bool) async {
        await call("sessions.configure", ConfigureParams(ref: ref, planMode: on))
    }

    private(set) var isCompactingContext = false

    /// Compacting makes sense once there's context, and waits while it answers, asks you something or already compacts.
    var canCompact: Bool {
        (state?.context?.tokens ?? 0) > 0 && !isRunning && prompts.isEmpty && !isCompactingContext
    }

    func compact() async {
        guard !isCompactingContext else { return }
        isCompactingContext = true
        defer { isCompactingContext = false }
        await call("sessions.compact", RefParams(ref: ref))
    }

    func commands() async -> [SessionCommand] {
        guard let client = engine?.client else { return [] }
        return (try? await client.call("sessions.commands", RefParams(ref: ref), as: CommandsResult.self).commands) ?? []
    }

    func files(matching query: String) async -> [FileMatch] {
        guard let client = engine?.client, let cwd else { return [] }
        return (try? await client.call("projects.files", FilesParams(cwd: cwd, query: query, limit: 12), as: FilesResult.self).files) ?? []
    }

    // MARK: Checkpoints and changes (Build)

    /// Bumped on every event batch, so views that read the document's items refresh.
    private(set) var revision = 0

    var checkpoints: [CheckpointItem] {
        _ = revision
        return document.items.compactMap { if case .checkpoint(let c) = $0 { c } else { nil } }
    }

    func changes(since: ChangesSince) async -> [FileChange] {
        guard let client = engine?.client else { return [] }
        return (try? await client.call("sessions.changes", ChangesParams(ref: ref, since: since), as: ChangesResult.self).files) ?? []
    }

    func diff(_ path: String, since: ChangesSince) async -> String {
        guard let client = engine?.client else { return "" }
        return (try? await client.call("sessions.diff", DiffParams(ref: ref, path: path, since: since), as: DiffResult.self).patch) ?? ""
    }

    /// What a restore would change (`dryRun`), or the restore itself.
    func restore(_ checkpoint: CheckpointItem, paths: [String]? = nil, dryRun: Bool) async throws -> [FileChange] {
        guard let client = engine?.client else { return [] }
        return try await client.call("sessions.restore", RestoreParams(ref: ref, checkpointId: checkpoint.checkpointId, paths: paths, dryRun: dryRun), as: RestoreResult.self).files
    }

    // MARK: Approvals and questions (Build)

    var prompts: [PendingPrompt] { state?.prompts ?? [] }
    var approvalMode: ApprovalMode { state?.approvalMode ?? .autoEdit }

    /// Asks an agent to review this session's changes, or pull request `pr` (05-build "Review by an agent"). The review's
    /// own session, or nil with the error shown.
    func review(pr: Int? = nil) async -> ContainerRef? {
        guard let client = engine?.client else { return nil }
        do {
            let ref = try await client.call("sessions.review", ReviewParams(ref: ref, pr: pr), as: CreateSessionResult.self).ref
            error = nil
            return ref
        } catch {
            report(error)
            return nil
        }
    }

    func setFinding(_ finding: ReviewFinding, _ state: ReviewFinding.State) async {
        await call("sessions.reviewFinding", ReviewFindingParams(ref: ref, id: finding.id, state: state))
    }

    /// Sends findings to this session to fix, and marks them.
    func fix(_ findings: [ReviewFinding], from review: ReviewInfo) async {
        guard !findings.isEmpty else { return }
        let items = findings.map { f in
            var text = "- **\(f.title)** (`\(f.file)\(f.line.map { ":\($0)" } ?? "")`, \(f.severity.rawValue)): \(f.detail)"
            if let s = f.suggestion, !s.isEmpty { text += " Suggested fix: \(s)" }
            return text
        }
        let intro = findings.count == 1 ? "Fix this from the review of \(review.target):" : "Fix these from the review of \(review.target):"
        if await send("\(intro)\n\n\(items.joined(separator: "\n"))") {
            for f in findings { await setFinding(f, .fixing) }
        }
    }

    /// The agent's background commands (docs/spec/05-build §9 TM4).
    var processes: [BackgroundProcess] { state?.processes ?? [] }

    /// A background command's output from `since`; nil when the engine can't say.
    func processOutput(_ id: String, since: Double) async -> ProcessOutputResult? {
        try? await engine?.client?.call("sessions.processOutput", ProcessOutputParams(ref: ref, id: id, since: since), as: ProcessOutputResult.self)
    }

    func stopProcess(_ id: String) async {
        await call("sessions.processStop", ProcessStopParams(ref: ref, id: id))
    }

    func respond(_ prompt: PendingPrompt, _ response: PromptResponse) async {
        await call("sessions.respond", RespondParams(ref: ref, promptId: prompt.id, response: response))
    }

    func setApprovalMode(_ mode: ApprovalMode) async {
        await call("sessions.configure", ConfigureParams(ref: ref, approvalMode: mode))
    }

    func setThinking(_ level: String) async {
        await call("sessions.configure", ConfigureParams(ref: ref, thinking: level))
    }

    func scrollToLatest() {
        document.scrollToLatest()
    }

    // MARK: Rewind (Build, chat v3 14b)

    func rewindPreview(_ itemId: String) async -> RewindPreview? {
        guard let client = engine?.client,
              let r = try? await client.call("sessions.rewind", RewindParams(ref: ref, itemId: itemId, files: true, dryRun: true), as: RewindResult.self) else { return nil }
        return RewindPreview(files: r.files.map { "\($0.status.rewindVerb) \(URL(fileURLWithPath: $0.path).lastPathComponent)" }, turns: r.turns)
    }

    /// Back to before a message; its text goes back into the composer.
    func rewind(_ itemId: String, files: Bool) async {
        guard let client = engine?.client else { return }
        do {
            let r = try await client.call("sessions.rewind", RewindParams(ref: ref, itemId: itemId, files: files), as: RewindResult.self)
            if let text = r.editorText { draft = text }
            error = nil
        } catch {
            report(error)
        }
    }

    // MARK: Ask next (chat v3 14e)

    /// The composer has text: suggestions step aside.
    var composing = false { didSet { if composing != oldValue { refreshAskNext() } } }
    @ObservationIgnored private var followUps: [String]?

    private static let dismissedKey = "askNextDismissed"
    private var askNextDismissed: Bool { (UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []).contains(ref.id) }

    /// The engine's suggestions for after the last answer (nil: none, or turned off in Settings › Chat).
    func setFollowUps(_ items: [String]?) {
        followUps = items
        refreshAskNext()
    }

    func refreshAskNext() {
        let show = !askNextDismissed && !composing && !isRunning && prompts.isEmpty && editing == nil
        document.showAskNext(show ? followUps.map { Array($0.prefix(3)) } : nil)
        document.showLearnOffer(!composing && !isRunning && prompts.isEmpty && editing == nil ? learnOffer : nil)
    }

    // MARK: Learn offer (docs/spec/14 M5)

    private static let learnOfferKey = "learnOfferDismissed"
    private var learnOfferDismissed: Bool { (UserDefaults.standard.stringArray(forKey: Self.learnOfferKey) ?? []).contains(ref.id) }

    /// After you corrected the agent in the last turn: a command you denied with a note, or a message that starts by
    /// correcting it after a turn that used tools. Once per session, and not once it has a /learn card. Build only: it's
    /// where project rules live.
    var learnOffer: String? {
        guard ref.kind == .build, !learnOfferDismissed, engine?.buildSessions.first(where: { $0.ref.id == ref.id })?.parent == nil else { return nil }
        let items = document.items
        if items.contains(where: { if case .tool(let t) = $0 { t.tool == "propose_learnings" } else { false } }) { return nil }
        guard let last = items.lastIndex(where: { if case .user = $0 { true } else { false } }) else { return nil }
        let turn = items[last...]
        let deniedWithNote = turn.contains { if case .tool(let t) = $0 { t.status == .denied && (t.output ?? "").hasPrefix("The user denied this tool call:") } else { false } }
        if deniedWithNote { return "You turned down a step and said why." }
        guard case .user(let u) = items[last], Self.isCorrection(u.text) else { return nil }
        let before = items[..<last]
        let toolsBefore = before.reversed().prefix { if case .user = $0 { false } else { true } }.contains { if case .tool = $0 { true } else { false } }
        return toolsBefore ? "You corrected how it works here." : nil
    }

    /// "No, use…", "Don't…", "That's wrong…", "Instead…" (English and Spanish), at the start of a message.
    static func isCorrection(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let starts = ["no,", "no.", "no ", "nope", "don't", "do not", "that's wrong", "that is wrong", "wrong", "instead", "not like that", "stop,", "no uses", "no hagas", "así no", "eso no", "mal,", "en vez de", "en lugar de"]
        return starts.contains { t.hasPrefix($0) } && t.count > 4
    }

    private func dismissLearnOffer() {
        var ids = UserDefaults.standard.stringArray(forKey: Self.learnOfferKey) ?? []
        if !ids.contains(ref.id) { ids.append(ref.id) }
        UserDefaults.standard.set(Array(ids.suffix(500)), forKey: Self.learnOfferKey)
        document.showLearnOffer(nil)
    }

    private func dismissAskNext() {
        var ids = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        if !ids.contains(ref.id) { ids.append(ref.id) }
        UserDefaults.standard.set(Array(ids.suffix(500)), forKey: Self.dismissedKey)
        document.showAskNext(nil)
    }
}

/// A file to show in a Build session's inspector (a path chip was clicked).
struct RevealTarget { let sessionId: String; let path: String }

extension Notification.Name {
    static let revealInInspector = Notification.Name("piopio.revealInInspector")
}

extension FileChange.Status {
    /// What rewinding does to a file the turn touched.
    var rewindVerb: String {
        switch self {
        case .added: "removes"
        case .modified: "reverts"
        case .deleted: "brings back"
        }
    }
}


/// The Edit… sheet's input (docs/spec/14 M5): the card's items and where rules would go.
struct LearnEdit: Identifiable {
    let callId: String
    let file: String?
    var items: [LearnItem]
    let hasProject: Bool
    var id: String { callId }
}
