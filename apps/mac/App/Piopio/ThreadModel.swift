import Foundation
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
    var isFollowing = true

    @ObservationIgnored private weak var engine: EngineController?
    @ObservationIgnored private var subscriptionId: String?

    init(ref: ContainerRef, engine: EngineController) {
        self.ref = ref
        self.engine = engine
        document.onFollowingChange = { [weak self] following in self?.isFollowing = following }
    }

    var isRunning: Bool { state?.status == .running }

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

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = engine?.client else { return }
        do {
            _ = try await client.call("sessions.submit", SubmitParams(ref: ref, text: trimmed, whenBusy: .followUp, clientRequestId: UUID().uuidString), as: SubmitResult.self)
            error = nil
        } catch let e as EngineError {
            error = e.code == "AUTH" ? "Add your OpenRouter key in Settings to start chatting." : e.message
        } catch {
            self.error = String(describing: error)
        }
    }

    func stop() async {
        _ = try? await engine?.client?.call("sessions.abort", RefParams(ref: ref), as: Empty.self)
    }

    func setModel(_ model: ModelRef) async {
        _ = try? await engine?.client?.call("sessions.configure", ConfigureParams(ref: ref, model: model), as: Empty.self)
    }

    func setThinking(_ level: String) async {
        _ = try? await engine?.client?.call("sessions.configure", ConfigureParams(ref: ref, thinking: level), as: Empty.self)
    }

    func scrollToLatest() {
        document.scrollToLatest()
    }
}
