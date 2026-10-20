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
    /// Opens a file of the session's folder in the viewer, at a line.
    case openFile(path: String, line: Int?)
    /// Opens a Space topic, at the reply when known.
    case openTopic(topicId: String, itemId: String?)
    /// Wrong topic: choose where a routed message should have gone.
    case wrongTopic(itemId: String)

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
        case .openFile(let path, let line): c.host = "file"; c.queryItems = [URLQueryItem(name: "path", value: path)] + (line.map { [URLQueryItem(name: "line", value: "\($0)")] } ?? [])
        case .openTopic(let topic, let item): c.host = "topic"; c.queryItems = [URLQueryItem(name: "id", value: topic)] + (item.map { [URLQueryItem(name: "item", value: $0)] } ?? [])
        case .wrongTopic(let id): c.host = "wrong-topic"; c.queryItems = [URLQueryItem(name: "item", value: id)]
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
        case "file": guard let path = q("path") else { return nil }; self = .openFile(path: path, line: q("line").flatMap(Int.init))
        case "topic": guard let id = q("id") else { return nil }; self = .openTopic(topicId: id, itemId: q("item"))
        case "wrong-topic": guard let id = q("item") else { return nil }; self = .wrongTopic(itemId: id)
        default: return nil
        }
    }
}
