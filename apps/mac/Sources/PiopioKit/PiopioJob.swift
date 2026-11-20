import Foundation

/// piopio's jobs on the New agent page (docs/spec/18 §21): while the page is empty it tries one on every few seconds,
/// and each one's example becomes the box's placeholder. Picking a template dresses it for that template's job.
public enum PiopioJob: String, CaseIterable, Sendable {
    case secretary, doctor, detective, chef, mailCarrier, coach

    public var title: String {
        switch self {
        case .secretary: "Secretary"
        case .doctor: "Doctor"
        case .detective: "Detective"
        case .chef: "Chef"
        case .mailCarrier: "Mail carrier"
        case .coach: "Coach"
        }
    }

    /// What it says when it puts the outfit on.
    public var line: String {
        switch self {
        case .secretary: "Taking notes, boss!"
        case .doctor: "Say ahh… peep!"
        case .detective: "Elementary, my dear peep"
        case .chef: "Oui, chef!"
        case .mailCarrier: "Special delivery!"
        case .coach: "One more lap!"
        }
    }

    /// An agent this job could be, in the user's words.
    public var example: String {
        switch self {
        case .secretary: "Every morning, tell me what's on my calendar and which emails need a reply."
        case .doctor: "Remind me to take my pills at 9:00 and 21:00, and ask if I did."
        case .detective: "Watch my competitors' pricing pages and tell me what changed."
        case .chef: "Plan this week's dinners and send me the shopping list on Sunday."
        case .mailCarrier: "Every evening, sum up my unread newsletters in five lines."
        case .coach: "Keep me on my training plan and check in after each run."
        }
    }

    /// A hat hides the tuft.
    public var hatted: Bool { [.detective, .chef, .mailCarrier].contains(self) }

    /// The next one to try on, round and round.
    public var next: PiopioJob {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// The job that goes with an agent template, if one does.
    public static func forTemplate(_ id: String?) -> PiopioJob? {
        switch id {
        case "daily-briefing": .secretary
        case "research-watcher": .detective
        case "personal-assistant": .mailCarrier
        case "habit-coach": .coach
        case "family-helper": .chef
        default: nil
        }
    }
}
