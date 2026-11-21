import Foundation

/// The composer's `/` menu (docs/spec/32 §4): one matching rule for every kind of command, and the command chip.
public enum CommandMenu {
    /// How well a command matches what's typed after `/`, lower is better; nil when it doesn't. Name prefix, then
    /// name substring, then (from two letters) a keyword or a word of the description. `names` are what the row is
    /// called and what's typed for it ("greet" and "skill:greet").
    public static func score(_ query: String, names: [String], keywords: [String] = [], description: String = "") -> Int? {
        let q = query.lowercased()
        if q.isEmpty { return 0 }
        let lowered = names.map { $0.lowercased() }
        if lowered.contains(where: { $0.hasPrefix(q) }) { return 0 }
        if lowered.contains(where: { $0.contains(q) }) { return 1 }
        guard q.count >= 2 else { return nil }
        if keywords.contains(where: { $0.lowercased().hasPrefix(q) }) { return 2 }
        let words = description.lowercased().split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(q) }) { return 3 }
        return nil
    }

    /// `items` that match `query`, best first; equal scores keep their order.
    public static func filter<T>(_ items: [T], query: String, match: (T) -> (names: [String], keywords: [String], description: String)) -> [T] {
        items.enumerated()
            .compactMap { i, item in
                let m = match(item)
                return score(query, names: m.names, keywords: m.keywords, description: m.description).map { (score: $0, index: i, item: item) }
            }
            .sorted { ($0.score, $0.index) < ($1.score, $1.index) }
            .map(\.item)
    }

    /// A message that starts with one of `commands` and a space: the command, shown as a chip, and the words after it,
    /// in the box. `/goal ` is ("goal", ""); `/goal` alone, or an unknown `/name`, is nil.
    public static func leading(_ text: String, commands: Set<String>) -> (command: String, rest: String)? {
        guard text.hasPrefix("/"), let space = text.firstIndex(of: " ") else { return nil }
        let name = String(text[text.index(after: text.startIndex)..<space])
        guard commands.contains(name) else { return nil }
        return (name, String(text[text.index(after: space)...]))
    }
}
