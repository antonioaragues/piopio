/// What Piopio is for you (docs/spec/15-onboarding-and-areas): Build, Chat and Agents, each shown or hidden.
/// Hiding an area is UI only: nothing is deleted and nothing that runs stops.
public enum Area: String, CaseIterable, Sendable, Identifiable {
    case build, chat, agents
    public var id: String { rawValue }
}

/// The areas that are on. Never empty: the last one can't be turned off.
public struct AreaSet: Equatable, Sendable {
    public private(set) var areas: Set<Area>

    public static let all = AreaSet(Set(Area.allCases))

    /// An empty set means all of them (nothing chosen yet).
    public init(_ areas: Set<Area>) {
        self.areas = areas.isEmpty ? Set(Area.allCases) : areas
    }

    /// From the stored form, "build,chat,agents". Unknown names are ignored; missing or empty means all.
    public init(stored: String?) {
        let names = (stored ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        self.init(Set(names.compactMap(Area.init(rawValue:))))
    }

    public var stored: String { ordered.map(\.rawValue).joined(separator: ",") }

    /// In the app's order: Build, Chat, Agents.
    public var ordered: [Area] { Area.allCases.filter(areas.contains) }

    public func contains(_ area: Area) -> Bool { areas.contains(area) }

    /// False for the only area that's on.
    public func canTurnOff(_ area: Area) -> Bool { areas != [area] }

    /// Turns an area on or off; turning off the last one does nothing. Returns whether anything changed.
    @discardableResult
    public mutating func set(_ area: Area, on: Bool) -> Bool {
        if on { return areas.insert(area).inserted }
        guard areas.contains(area), canTurnOff(area) else { return false }
        areas.remove(area)
        return true
    }

    // MARK: What shows

    /// Projects are folders: Build sessions with Build, and folders to chat about with Chat.
    public var showsProjects: Bool { contains(.build) || contains(.chat) }
    public var showsNotebooks: Bool { contains(.chat) }
    public var showsChats: Bool { contains(.chat) }
    public var showsAgents: Bool { contains(.agents) }

    /// A session in a project: Build sessions with Build, chat sessions (the Folder lens) with Chat.
    public func showsSession(chatProfile: Bool) -> Bool { contains(chatProfile ? .chat : .build) }
}

/// When the first-run welcome shows.
public enum WelcomeGate: Equatable, Sendable {
    /// A new install: show it.
    case show
    /// Someone who already uses Piopio, before areas existed: keep everything on, don't show it, show the tip once.
    case existingUser
    /// Done or skipped before.
    case done

    /// `hasHistory`: a model is connected, or there are projects, chats, notebooks or agents.
    public static func decide(done: Bool, hasHistory: Bool, forced: Bool = false) -> WelcomeGate {
        if forced { return .show }
        if done { return .done }
        return hasHistory ? .existingUser : .show
    }
}
