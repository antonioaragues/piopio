import PiopioKit
import SwiftUI

/// What the one sidebar selects (docs/design v2): its type decides the content view. Replaces the Build · Chat ·
/// Agents modes and their separate selections. Stored as a string (`@AppStorage("sidebarItem")`).
enum SidebarItem: Hashable {
    case home
    case needsYou
    /// A section's full list ("Projects · 6", "N more ›").
    case index(SidebarSection)
    /// A project: the Projects index, opened at it.
    case project(String)
    /// A Build session or a project chat session.
    case session(String)
    /// A notebook (a Space), or one of its topics: "spaceId" or "spaceId/topicId".
    case notebook(String)
    case agent(String)
    case chat(String)

    var raw: String {
        switch self {
        case .home: "home"
        case .needsYou: "needs"
        case .index(let s): "index:\(s.rawValue)"
        case .project(let id): "project:\(id)"
        case .session(let id): "session:\(id)"
        case .notebook(let key): "notebook:\(key)"
        case .agent(let id): "agent:\(id)"
        case .chat(let id): "chat:\(id)"
        }
    }

    init(raw: String) {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "needs": self = .needsYou
        case "index": self = SidebarSection(rawValue: value).map { .index($0) } ?? .home
        case "project": self = .project(value)
        case "session": self = .session(value)
        case "notebook": self = .notebook(value)
        case "agent": self = .agent(value)
        case "chat": self = .chat(value)
        default: self = .home
        }
    }

    /// The id the engine knows (a thread, session, Space key or agent), for "you're looking at it".
    var engineId: String? {
        switch self {
        case .session(let id), .agent(let id), .chat(let id): id
        case .notebook(let key): key
        default: nil
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case pinned, projects, notebooks, agents, chats
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

extension EngineController {
    /// Which kind of item an engine id is (threads, sessions, notebooks and their topics, agents).
    func item(for id: String) -> SidebarItem? {
        if threads.contains(where: { $0.ref.id == id }) { return .chat(id) }
        if buildSessions.contains(where: { $0.ref.id == id }) { return .session(id) }
        if agents.contains(where: { $0.ref.id == id }) { return .agent(id) }
        if space(String(id.split(separator: "/").first ?? "")) != nil { return .notebook(id) }
        if projects.contains(where: { $0.id == id }) { return .project(id) }
        return nil
    }

    /// The project a session belongs to.
    func project(of session: SessionSummary) -> ProjectInfo? {
        projects.first { $0.path == (session.projectPath ?? session.cwd) }
    }
}

extension Notification.Name {
    /// Object: a `SidebarItem.raw` string.
    static let selectItem = Notification.Name("piopio.selectItem")
}
