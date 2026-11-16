import Foundation

/// "Use theirs and mine" for a project's AGENTS.md or NOTES.md edited in the settings sheet (docs/spec/18 §19).
public enum LineMerge {
    /// The file changed on disk (`theirs`) while you edited (`mine`), both from `base`. When `theirs` only added lines
    /// to `base` (what conversations do with memory), returns `mine` with those lines at the end, once each; nil when
    /// `theirs` also changed or removed lines, which can't be combined line by line.
    public static func merge(base: String, theirs: String, mine: String) -> String? {
        let b = base.components(separatedBy: "\n")
        var added: [String] = []
        var i = 0
        for line in theirs.components(separatedBy: "\n") {
            if i < b.count && line == b[i] { i += 1 } else { added.append(line) }
        }
        guard i == b.count else { return nil }
        let have = Set(mine.components(separatedBy: "\n"))
        let extra = added.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !have.contains($0) }
        guard !extra.isEmpty else { return mine }
        var out = mine
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        return out + extra.joined(separator: "\n") + "\n"
    }
}
