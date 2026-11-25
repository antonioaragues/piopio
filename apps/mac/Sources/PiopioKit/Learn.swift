import Foundation

/// What a /learn card (docs/spec/14 M5) saves and where: the card's Save and its Edit… sheet both read it from here.
extension LearnItem {
    /// What it still needs before Save writes it, in words for the sheet ("a name", "instructions"); empty when ready.
    public var missing: [String] {
        let has = { (s: String?) in !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var out: [String] = []
        if !has(text) { out.append(to == .skill ? "when it's used" : "words") }
        if to == .skill {
            if !has(name) && !has(addTo) { out.append("a name") }
            if !has(body) { out.append("instructions") }
        }
        return out
    }

    /// Where Save writes `items`: "AGENTS.md, About me and the skill release-notes", "2 skills". `file` is the
    /// project's instructions file (AGENTS.md when nil).
    public static func destinations(_ items: [LearnItem], file: String?) -> String {
        var places: [String] = []
        if items.contains(where: { $0.to == .project }) { places.append(file ?? "AGENTS.md") }
        if items.contains(where: { $0.to == .aboutMe }) { places.append("About me") }
        let skills = items.filter { $0.to == .skill }
        if skills.count == 1, let name = skills[0].addTo ?? skills[0].name, !name.isEmpty { places.append("the skill \(name)") }
        else if skills.count == 1 { places.append("a skill") }
        else if skills.count > 1 { places.append("\(skills.count) skills") }
        return listed(places)
    }

    /// "a", "a and b", "a, b and c".
    public static func listed(_ parts: [String]) -> String {
        guard let last = parts.last else { return "" }
        return parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
    }
}
