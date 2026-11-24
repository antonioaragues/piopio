import Foundation

/// Something the user clicked in the transcript. Copy is handled by the document itself.
public enum TranscriptAction: Equatable, Sendable {
    case edit(itemId: String)
    case regenerate(itemId: String)
    case fork(itemId: String)
    case switchBranch(String)
    case openSettings
    case chooseModel
    case showErrorDetail(itemId: String)
    case copy(itemId: String)
    case restoreCheckpoint(itemId: String)
    /// Opens another session (a subagent's).
    case openSession(String)
    /// Opens one of your conversations, a chat or a Build session (an earlier one a turn found, docs/spec/14 M4).
    case openConversation(String)
    /// Opens a file of the session's folder in the viewer, at a line.
    case openFile(path: String, line: Int?)
    /// A path chip in an answer: shows the file in the inspector's Files tab.
    case revealFile(path: String)
    /// Answers an agent's approval request (06-agents §9).
    case decideApproval(approvalId: String, approve: Bool)
    /// Opens the approval in the Inbox, to edit what it does before approving.
    case editApproval(approvalId: String)
    /// Reverses a change a result card shows (06-agents §4.2).
    case undoChange(undoId: String)
    /// Opens the trace of messages between agents (06-agents §7 AA5).
    case openTrace(traceId: String)
    /// A connected app's change in a chat: allow it, and don't ask again for that action.
    case allowAlways(approvalId: String)
    /// Answers a plan from its card: approve as is, edit it first, or send it back with a note.
    case plan(callId: String, answer: PlanAnswer)
    /// Select and ask: the selected text goes to the composer as a quote, above what you're writing.
    case quote(text: String)
    /// Remember this: a fact to save to memory (About me in chats, the agent's memory of the person in agents).
    case remember(text: String)
    /// Copies a code block.
    case copyText(String)
    /// Stopped · continue: asks the model to carry on.
    case continueAnswer
    /// A file you sent: the engine's copy, relative to the conversation's attachments folder (roadmap D8).
    case openAttachment(stored: String)
    /// Answers a card by sending this text (an offer's "Do it here, one by one", docs/spec/21 D7).
    case reply(text: String)
    /// A visual (docs/spec/25) on its own, larger: the item that holds it.
    case openVisual(itemId: String)
    /// A visual's `piopio.prefill`: this text in the composer, for you to finish.
    case prefill(text: String)
    /// An app made in the conversation (docs/spec/35 §17): open its page, or pin it in the Library.
    case openApp(path: String)
    case pinApp(path: String)
    /// One of Piopio's offers taken: "parallel" (work in parallel).
    case offer(kind: String, callId: String)
    /// An automation's card (docs/spec/27 §4): open it in Automations, or take it out again (Undo, where the card has
    /// no undo record of its own).
    case openAutomation(id: String)
    case removeAutomation(id: String)
    /// The card's Undo: its own undo record (an agent's) or removal; the card then reads "Undone … Redo".
    case undoAutomation(id: String, undoId: String?)
    /// Redo: the automation removed by Undo comes back as it was.
    case restoreAutomation(id: String)
    public enum PlanAnswer: String, Sendable { case approve, edit, revise }

    static let scheme = "piopio-action"

    var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .edit(let id): c.host = "edit"; c.queryItems = [URLQueryItem(name: "item", value: id)]
        case .regenerate(let id): c.host = "regenerate"; c.queryItems = [URLQueryItem(name: "item", value: id)]
        case .fork(let id): c.host = "fork"; c.queryItems = [URLQueryItem(name: "item", value: id)]
        case .switchBranch(let b): c.host = "branch"; c.queryItems = [URLQueryItem(name: "to", value: b)]
        case .openSettings: c.host = "settings"
        case .chooseModel: c.host = "model"
        case .showErrorDetail(let id): c.host = "error"; c.queryItems = [URLQueryItem(name: "item", value: id)]
        case .copy(let id): c.host = "copy"; c.queryItems = [URLQueryItem(name: "item", value: id)]
        case .restoreCheckpoint(let id): c.host = "restore"; c.queryItems = [URLQueryItem(name: "item", value: id)]
        case .openSession(let id): c.host = "session"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        case .openConversation(let id): c.host = "conversation"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        case .revealFile(let path): c.host = "reveal"; c.queryItems = [URLQueryItem(name: "path", value: path)]
        case .openFile(let path, let line): c.host = "file"; c.queryItems = [URLQueryItem(name: "path", value: path)] + (line.map { [URLQueryItem(name: "line", value: "\($0)")] } ?? [])
        case .decideApproval(let id, let approve): c.host = "approval"; c.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "approve", value: approve ? "1" : "0")]
        case .editApproval(let id): c.host = "edit-approval"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        case .undoChange(let id): c.host = "undo"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        case .openTrace(let id): c.host = "trace"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        case .allowAlways(let id): c.host = "allow-always"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        case .plan(let id, let answer): c.host = "plan"; c.queryItems = [URLQueryItem(name: "call", value: id), URLQueryItem(name: "answer", value: answer.rawValue)]
        case .quote(let text): c.host = "quote"; c.queryItems = [URLQueryItem(name: "text", value: text)]
        case .remember(let text): c.host = "remember"; c.queryItems = [URLQueryItem(name: "text", value: text)]
        case .copyText(let text): c.host = "copy-text"; c.queryItems = [URLQueryItem(name: "text", value: text)]
        case .continueAnswer: c.host = "continue-answer"
        case .openAttachment(let stored): c.host = "attachment"; c.queryItems = [URLQueryItem(name: "stored", value: stored)]
        case .reply(let text): c.host = "reply"; c.queryItems = [URLQueryItem(name: "text", value: text)]
        case .openVisual(let id): c.host = "visual"; c.queryItems = [URLQueryItem(name: "item", value: id)]
        case .openApp(let path): c.host = "app"; c.queryItems = [URLQueryItem(name: "path", value: path)]
        case .pinApp(let path): c.host = "pin-app"; c.queryItems = [URLQueryItem(name: "path", value: path)]
        case .prefill(let text): c.host = "prefill"; c.queryItems = [URLQueryItem(name: "text", value: text)]
        case .offer(let kind, let id): c.host = "offer"; c.queryItems = [URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "call", value: id)]
        case .openAutomation(let id): c.host = "automation"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        case .removeAutomation(let id): c.host = "remove-automation"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        case .undoAutomation(let id, let undoId): c.host = "undo-automation"; c.queryItems = [URLQueryItem(name: "id", value: id)] + (undoId.map { [URLQueryItem(name: "undo", value: $0)] } ?? [])
        case .restoreAutomation(let id): c.host = "restore-automation"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        }
        return c.url!
    }

    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == Self.scheme else { return nil }
        func q(_ name: String) -> String? { c.queryItems?.first { $0.name == name }?.value }
        switch c.host {
        case "edit": guard let id = q("item") else { return nil }; self = .edit(itemId: id)
        case "regenerate": guard let id = q("item") else { return nil }; self = .regenerate(itemId: id)
        case "fork": guard let id = q("item") else { return nil }; self = .fork(itemId: id)
        case "branch": guard let b = q("to") else { return nil }; self = .switchBranch(b)
        case "settings": self = .openSettings
        case "model": self = .chooseModel
        case "error": guard let id = q("item") else { return nil }; self = .showErrorDetail(itemId: id)
        case "copy": guard let id = q("item") else { return nil }; self = .copy(itemId: id)
        case "restore": guard let id = q("item") else { return nil }; self = .restoreCheckpoint(itemId: id)
        case "session": guard let id = q("id") else { return nil }; self = .openSession(id)
        case "conversation": guard let id = q("id") else { return nil }; self = .openConversation(id)
        case "file": guard let path = q("path") else { return nil }; self = .openFile(path: path, line: q("line").flatMap(Int.init))
        case "reveal": guard let path = q("path") else { return nil }; self = .revealFile(path: path)
        case "approval": guard let id = q("id") else { return nil }; self = .decideApproval(approvalId: id, approve: q("approve") == "1")
        case "edit-approval": guard let id = q("id") else { return nil }; self = .editApproval(approvalId: id)
        case "undo": guard let id = q("id") else { return nil }; self = .undoChange(undoId: id)
        case "trace": guard let id = q("id") else { return nil }; self = .openTrace(traceId: id)
        case "allow-always": guard let id = q("id") else { return nil }; self = .allowAlways(approvalId: id)
        case "plan": guard let id = q("call"), let answer = q("answer").flatMap(PlanAnswer.init(rawValue:)) else { return nil }; self = .plan(callId: id, answer: answer)
        case "quote": guard let text = q("text") else { return nil }; self = .quote(text: text)
        case "remember": guard let text = q("text") else { return nil }; self = .remember(text: text)
        case "copy-text": guard let text = q("text") else { return nil }; self = .copyText(text)
        case "continue-answer": self = .continueAnswer
        case "attachment": guard let stored = q("stored") else { return nil }; self = .openAttachment(stored: stored)
        case "reply": guard let text = q("text") else { return nil }; self = .reply(text: text)
        case "visual": guard let id = q("item") else { return nil }; self = .openVisual(itemId: id)
        case "app": guard let path = q("path") else { return nil }; self = .openApp(path: path)
        case "pin-app": guard let path = q("path") else { return nil }; self = .pinApp(path: path)
        case "prefill": guard let text = q("text") else { return nil }; self = .prefill(text: text)
        case "offer": guard let kind = q("kind"), let id = q("call") else { return nil }; self = .offer(kind: kind, callId: id)
        case "automation": guard let id = q("id") else { return nil }; self = .openAutomation(id: id)
        case "remove-automation": guard let id = q("id") else { return nil }; self = .removeAutomation(id: id)
        case "undo-automation": guard let id = q("id") else { return nil }; self = .undoAutomation(id: id, undoId: q("undo"))
        case "restore-automation": guard let id = q("id") else { return nil }; self = .restoreAutomation(id: id)
        default: return nil
        }
    }
}
