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
    /// The message being edited in the composer (sending re-asks from it as a new version).
    private(set) var editing: (itemId: String, original: String)?
    /// Raw provider error shown by "Details".
    var errorDetail: String?
    /// Opens the composer's model picker ("Use another model" in error cards).
    var showModelPicker = false
    /// Build: the checkpoint "Restore…" was clicked on (the session view confirms it).
    var restoring: CheckpointItem?
    /// A plan being edited before approval (its sheet), and one being sent back (the bar's note field).
    var editingPlan: PendingPrompt?
    var revisingPlan: String?

    @ObservationIgnored private weak var engine: EngineController?
    @ObservationIgnored private var subscriptionId: String?

    /// Pending item to scroll to once the transcript is loaded (search results).
    @ObservationIgnored private var pendingReveal: String?
    @ObservationIgnored private let notifies: Bool

    init(ref: ContainerRef, engine: EngineController, notifies: Bool = true, compact: Bool = false) {
        document = TranscriptDocument(compact: compact, versions: ref.kind == .thread)
        self.ref = ref
        self.engine = engine
        self.notifies = notifies
        document.onFollowingChange = { [weak self] following in self?.isFollowing = following }
        document.onAction = { [weak self] action in self?.handle(action) }
        document.bottomInset = 150 // the floating composer sits over the bottom of the transcript
    }

    var isRunning: Bool { state?.status == .running }
    var attachmentCount: Int { _ = state; return document.attachmentCount }
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

    private func load() async {
        guard !loaded, let engine else { return }
        do {
            let sub = try await engine.subscribe(ref) { [weak self] events in self?.apply(events) }
            subscriptionId = sub.subscriptionId
            state = sub.snapshot.state
            await document.load(sub.snapshot)
            loaded = true
            if let pendingReveal {
                self.pendingReveal = nil
                document.reveal(pendingReveal)
            }
        } catch {
            self.error = String(describing: error)
        }
    }

    func close() {
        if let subscriptionId { engine?.unsubscribe(subscriptionId) }
        subscriptionId = nil
    }

    private func apply(_ events: [SessionEvent]) {
        document.apply(events)
        revision += 1
        let wasRunning = state?.status == .running
        for case .state(let s) in events { state = s }
        for case .resnapshot(let snap) in events { state = snap.state }
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
    func send(_ text: String, attachments: [Attachment] = [], steer: Bool = false) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let editing {
            self.editing = nil
            await call("sessions.edit", EditParams(ref: ref, itemId: editing.itemId, text: trimmed))
        } else {
            await call("sessions.submit", SubmitParams(ref: ref, text: trimmed, attachments: attachments, whenBusy: steer ? .steer : .followUp, clientRequestId: UUID().uuidString))
        }
    }

    var webEnabled: Bool { state?.tools?.web ?? true }

    func setWeb(_ enabled: Bool) async {
        await call("sessions.configure", ConfigureParams(ref: ref, web: enabled))
    }

    /// Asks where to save, then writes the export.
    func export(_ format: ExportParams.Format) async {
        guard let client = engine?.client else { return }
        do {
            let result = try await client.call("sessions.export", ExportParams(ref: ref, format: format), as: ExportResult.self)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = result.filename
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try result.content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            report(error)
        }
    }

    func copyAsMarkdown() async {
        guard let client = engine?.client,
              let result = try? await client.call("sessions.export", ExportParams(ref: ref, format: .markdown), as: ExportResult.self) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.content, forType: .string)
    }

    func cancelEditing() { editing = nil }

    func beginEditing(_ itemId: String, original: String) { editing = (itemId, original) }

    private func handle(_ action: TranscriptAction) {
        switch action {
        case .edit(let id):
            if case .user(let u) = document.item(id) { beginEditing(id, original: u.text) }
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
        case .copy:
            break // handled by the document
        case .restoreCheckpoint(let id):
            if case .checkpoint(let c) = document.item(id) { restoring = c }
        case .openSession(let id):
            NotificationCenter.default.post(name: .selectBuildSession, object: id)
        case .openFile(let path, let line):
            viewing = FileTarget(path: path, line: line)
        case .openTopic(let topicId, let itemId):
            NotificationCenter.default.post(name: .openTopic, object: TopicTarget(spaceId: ref.id, topicId: topicId, itemId: itemId))
        case .wrongTopic(let itemId):
            chooseTopic(for: itemId)
        case .undoMemory(let revisionId):
            Task { do { try await engine?.spaceCall("spaces.memory.undo", RevisionParams(ref: spaceRef, revisionId: revisionId)) } catch { report(error) } }
        case .decideMemory(let proposalId, let accept):
            Task { do { try await engine?.spaceCall("spaces.memory.decide", DecideParams(ref: spaceRef, proposalId: proposalId, accept: accept)) } catch { report(error) } }
        case .decideApproval(let approvalId, let approve):
            Task { do { try await engine?.decide(ref, approvalId: approvalId, approve: approve) } catch { report(error) } }
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

    /// The Space this conversation belongs to (memory belongs to the Space, not the topic).
    private var spaceRef: ContainerRef { ContainerRef(kind: .space, id: ref.id) }

    /// Wrong topic (04-chat S2): a menu of the other topics and New Topic…, at the pointer.
    private func chooseTopic(for itemId: String) {
        guard let engine, case .routing(let routing) = document.item(itemId) else { return }
        let menu = NSMenu()
        for topic in engine.space(ref.id)?.topics ?? [] where topic.id != routing.topicId {
            menu.addItem(ClosureMenuItem(title: topic.title) { [weak self] in self?.reroute(itemId, toTopic: topic.id) })
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(title: "New Topic…") { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Move to a new topic"
            alert.informativeText = "The message goes to a new topic, and the organizer learns from the correction."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Topic title"
            alert.accessoryView = field
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { self?.reroute(itemId, newTopic: name) }
        })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func reroute(_ itemId: String, toTopic: String? = nil, newTopic: String? = nil) {
        Task {
            do { try await engine?.reroute(ref, itemId: itemId, toTopic: toTopic, newTopic: newTopic) } catch { report(error) }
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

    func clearQueue() async {
        await call("sessions.queue.clear", RefParams(ref: ref))
    }

    /// Calls the engine for this thread; failures show above the composer.
    private func call(_ method: String, _ params: some Encodable & Sendable) async {
        guard let client = engine?.client else { return }
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
            self.error = errorIsAuth ? "Add your OpenRouter key in Settings to start chatting." : e.message
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
    // MARK: Composer, plan mode and tree (Build)

    /// Text to put in the composer (a message brought back from the session tree, terminal output).
    var draft: String?
    /// The file shown in the viewer (BR4).
    var viewing: FileTarget?
    var showTree = false
    var planMode: Bool { state?.planMode ?? false }
    var todos: [Todo] { state?.todos ?? [] }
    /// The session's folder (a worktree for worktree sessions).
    var cwd: String? { engine?.buildSessions.first { $0.ref.id == ref.id }?.cwd }

    func setPlanMode(_ on: Bool) async {
        await call("sessions.configure", ConfigureParams(ref: ref, planMode: on))
    }

    func compact() async {
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

    func tree() async -> [TreeNode] {
        guard let client = engine?.client else { return [] }
        return (try? await client.call("sessions.tree", RefParams(ref: ref), as: TreeResult.self).nodes) ?? []
    }

    func navigate(to node: TreeNode) async {
        guard let client = engine?.client else { return }
        do {
            let result = try await client.call("sessions.navigate", NavigateParams(ref: ref, entryId: node.entryId), as: NavigateResult.self)
            if let text = result.editorText { draft = text }
            error = nil
        } catch {
            report(error)
        }
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
}
