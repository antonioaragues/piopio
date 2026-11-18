import Foundation

/// piopio's mood on Home (docs/design/home): the time of day, unless it's a special date, which wins. It picks how the
/// chick looks, what it says when tapped, and on the holidays the greeting above the box.
public enum PiopioMood: String, CaseIterable, Sendable {
    case morning, afternoon, night, christmas, halloween, newYear, valentine

    public static func at(_ date: Date, calendar: Calendar = .current) -> PiopioMood {
        let c = calendar.dateComponents([.month, .day, .hour], from: date)
        let month = c.month ?? 1, day = c.day ?? 1, hour = c.hour ?? 12
        if month == 12, (24...26).contains(day) { return .christmas }
        if (month == 12 && day == 31) || (month == 1 && day == 1) { return .newYear }
        if month == 10, day == 31 { return .halloween }
        if month == 2, day == 14 { return .valentine }
        return (5..<12).contains(hour) ? .morning : (12..<20).contains(hour) ? .afternoon : .night
    }

    /// A hat hides the tuft.
    public var hatted: Bool { [.night, .christmas, .halloween, .newYear].contains(self) }

    /// "Good morning", "Good afternoon", "Good evening".
    public static func salutation(_ date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<20: "Good afternoon"
        default: "Good evening"
        }
    }

    /// The greeting above the box: the holiday on Christmas, Halloween and New Year, else the time of day.
    public static func greeting(name: String, date: Date, calendar: Calendar = .current) -> String {
        at(date, calendar: calendar).greeting(name: name, date: date, calendar: calendar)
    }

    /// This mood's greeting (a mood forced for captures greets with it too).
    public func greeting(name: String, date: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .christmas: "Merry Christmas, \(name)"
        case .halloween: "Happy Halloween, \(name)"
        case .newYear: "Happy new year, \(name)"
        default: "\(Self.salutation(date, calendar: calendar)), \(name)"
        }
    }

    /// The year New Year's Eve and New Year's Day welcome.
    public static func welcomedYear(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.year ?? 2026) + (c.month == 12 ? 1 : 0)
    }

    /// What it says when tapped (one at random). Morning has none: the first tap wakes it, and after that it talks as
    /// in the afternoon.
    public func lines(name: String, date: Date, calendar: Calendar = .current) -> [String] {
        switch self {
        case .night: ["zzz… still here?", "more tomorrow", "*yawn*"]
        case .christmas: ["Merry Christmas!", "ho ho peep"]
        case .halloween: ["Boo!", "trick or peep?"]
        case .newYear: ["Happy \(Self.welcomedYear(date, calendar: calendar))!", "new year, new peep!"]
        case .valentine: ["♥ peep ♥", "love you, \(name)"]
        case .morning, .afternoon: ["peep!", "peep peep", "what are we doing?", "hi, \(name)!"]
        }
    }

    public static let wakeLine = "good morning!"
    public static let sendLine = "on it!"
}
