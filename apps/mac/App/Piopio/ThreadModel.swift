import AppKit
import Observation
import PiopioKit
import PiopioTranscript

/// One open thread: its transcript document, live session state, and actions.
@Observable @MainActor
final class ThreadModel {
    let ref: ContainerRef
    @ObservationIgnored let document = TranscriptDocument()
    private(set) var state: SessionState?
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var errorIsAuth = false
    var isFollowing = true
    /// The message being edited in the composer (sending re-asks from it as a new version).
    private(set) var editing: (itemId: String, original: String)?
    /// Raw provider error shown by "Details".
    var errorDetail: String?

    @ObservationIgnored private weak var engine: EngineController?
    @ObservationIgnored private var subscriptionId: String?

    init(ref: ContainerRef, engine: EngineController) {
        self.ref = ref
        self.engine = engine
        document.onFollowingChange = { [weak self] following in self?.isFollowing = following }
        document.onAction = { [weak self] action in self?.handle(action) }
    }

    var isRunning: Bool { state?.status == .running }
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
        for case .state(let s) in events { state = s }
        for case .resnapshot(let snap) in events { state = snap.state }
    }

    /// Sends a message: a new version of the edited message when editing; otherwise a new message
    /// (queued after the current answer, or steering it with `steer`).
    func send(_ text: String, steer: Bool = false) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let editing {
            self.editing = nil
            await call("sessions.edit", EditParams(ref: ref, itemId: editing.itemId, text: trimmed))
        } else {
            await call("sessions.submit", SubmitParams(ref: ref, text: trimmed, whenBusy: steer ? .steer : .followUp, clientRequestId: UUID().uuidString))
        }
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
        case .showErrorDetail(let id):
            if case .assistant(let a) = document.item(id) { errorDetail = a.errorDetail ?? a.error }
        case .copy:
            break // handled by the document
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
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func stop() async {
        _ = try? await engine?.client?.call("sessions.abort", RefParams(ref: ref), as: Empty.self)
    }

    func setModel(_ model: ModelRef) async {
        _ = try? await engine?.client?.call("sessions.configure", ConfigureParams(ref: ref, model: model), as: Empty.self)
    }

    /// `"default"` returns to the model's default.
    func setThinking(_ level: String) async {
        await call("sessions.configure", ConfigureParams(ref: ref, thinking: level))
    }

    func scrollToLatest() {
        document.scrollToLatest()
    }
}
