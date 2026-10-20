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
        default: return nil
        }
    }
}
