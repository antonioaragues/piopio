import Foundation

/// A unified diff with line numbers, for the diff review (docs/design 4c): unified rows and side-by-side pairs.
public struct UnifiedDiff: Sendable, Hashable {
    public struct Row: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable { case context, added, removed, hunk }
        public var kind: Kind
        public var text: String
        /// Line numbers in the old and new file (nil where the line doesn't exist on that side).
        public var old: Int?
        public var new: Int?
        public var id: String { "\(kind)-\(old ?? -1)-\(new ?? -1)-\(text.hashValue)" }
    }

    /// One line of the side-by-side view: left (old) and right (new), either may be empty.
    public struct Pair: Sendable, Hashable, Identifiable {
        public var left: Row?
        public var right: Row?
        public var hunk: String?
        public let id: Int
    }

    public var rows: [Row]
    public var binary: Bool

    public var added: Int { rows.filter { $0.kind == .added }.count }
    public var removed: Int { rows.filter { $0.kind == .removed }.count }

    public init(_ patch: String) {
        var rows: [Row] = []
        var old = 0, new = 0
        binary = patch.contains("Binary files ") && !patch.contains("@@")
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                // @@ -12,5 +12,7 @@ context
                let numbers = line.split(separator: " ").dropFirst().prefix(2)
                old = Int(numbers.first?.dropFirst().split(separator: ",").first ?? "") ?? 0
                new = Int(numbers.dropFirst().first?.dropFirst().split(separator: ",").first ?? "") ?? 0
                rows.append(Row(kind: .hunk, text: line))
            } else if rows.isEmpty || line.hasPrefix("\\") {
                continue // file headers before the first hunk; "\ No newline at end of file"
            } else if line.hasPrefix("+") {
                rows.append(Row(kind: .added, text: String(line.dropFirst()), old: nil, new: new))
                new += 1
            } else if line.hasPrefix("-") {
                rows.append(Row(kind: .removed, text: String(line.dropFirst()), old: old, new: nil))
                old += 1
            } else if line.hasPrefix(" ") || !line.isEmpty {
                rows.append(Row(kind: .context, text: String(line.dropFirst()), old: old, new: new))
                old += 1
                new += 1
            }
        }
        self.rows = rows
    }

    /// Side by side: context on both sides, a run of removed lines next to the run of added lines that follows.
    public var pairs: [Pair] {
        var out: [Pair] = []
        var removed: [Row] = [], added: [Row] = []
        func flush() {
            for i in 0..<max(removed.count, added.count) {
                out.append(Pair(left: i < removed.count ? removed[i] : nil, right: i < added.count ? added[i] : nil, hunk: nil, id: out.count))
            }
            removed = []
            added = []
        }
        for row in rows {
            switch row.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(row)
            case .added: added.append(row)
            case .context:
                flush()
                out.append(Pair(left: row, right: row, hunk: nil, id: out.count))
            case .hunk:
                flush()
                out.append(Pair(left: nil, right: nil, hunk: row.text, id: out.count))
            }
        }
        flush()
        return out
    }
}
