import Foundation

// Block-level markdown for chat transcripts, built for streaming.
//
// `MarkdownStream` consumes text deltas. Blocks before the last one are final and never change,
// so a renderer caches them by index and only re-renders the open tail block on each delta.
// Inline markup (bold, code spans, links) is left to the renderer (Foundation's inline parser).
// This covers what models emit in chat (GFM subset), not all of CommonMark.

public struct MarkdownListItem: Sendable, Hashable {
    public var indent: Int
    public var ordered: Bool
    public var number: Int?
    public var task: Bool?   // nil = not a task item; true/false = [x] / [ ]
    public var text: String
}

public enum TableAlignment: Sendable, Hashable { case leading, center, trailing }

public enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case quote(String)
    case code(language: String?, code: String, closed: Bool)
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    case rule
}

public struct MarkdownStream: Sendable {
    /// Final blocks. Indices are stable.
    public private(set) var closed: [MarkdownBlock] = []
    /// The block still receiving text, if any.
    public private(set) var open: MarkdownBlock?

    private var pendingLine = ""      // text after the last newline
    private var openLines: [String] = []
    private var fence: (marker: Character, length: Int, language: String?)?

    public init() {}

    public init(text: String) {
        append(text)
        finish()
    }

    public var blocks: [MarkdownBlock] { open.map { closed + [$0] } ?? closed }

    public mutating func append(_ delta: String) {
        var rest = Substring(delta)
        while let nl = rest.firstIndex(of: "\n") {
            pendingLine += rest[..<nl]
            consume(line: pendingLine)
            pendingLine = ""
            rest = rest[rest.index(after: nl)...]
        }
        pendingLine += rest
        refreshOpen()
    }

    /// Ends the stream: the tail becomes final.
    public mutating func finish() {
        if !pendingLine.isEmpty {
            consume(line: pendingLine)
            pendingLine = ""
        }
        closeOpen()
    }

    // MARK: Line machine

    private mutating func consume(line: String) {
        if let f = fence {
            if Self.isFenceClose(line, marker: f.marker, length: f.length) {
                closed.append(.code(language: f.language, code: openLines.joined(separator: "\n"), closed: true))
                openLines = []
                fence = nil
                open = nil
            } else {
                openLines.append(line)
            }
            return
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            closeOpen()
            return
        }
        if let f = Self.fenceOpen(line) {
            closeOpen()
            fence = f
            return
        }
        if Self.headingLevel(trimmed) != nil || Self.isRule(trimmed) {
            closeOpen()
            closed.append(Self.parse([line]))
            return
        }
        // A new kind of block starting right after another (no blank line) splits them.
        if let first = openLines.first, Self.kind(of: first) != Self.kind(of: line), !Self.isContinuation(line, of: first) {
            closeOpen()
        } else if let first = openLines.first, let a = Self.listMarker(first), let b = Self.listMarker(line), b.indent <= a.indent, a.ordered != b.ordered {
            // Switching between bullets and numbers at the top level starts a new list.
            closeOpen()
        }
        openLines.append(line)
    }

    private mutating func refreshOpen() {
        var lines = openLines
        if !pendingLine.isEmpty { lines.append(pendingLine) }
        if let f = fence {
            open = .code(language: f.language, code: lines.joined(separator: "\n"), closed: false)
        } else if pendingLine.isEmpty, openLines.isEmpty {
            open = nil
        } else if let fenceStart = Self.fenceOpen(pendingLine), openLines.isEmpty {
            open = .code(language: fenceStart.language, code: "", closed: false)
        } else {
            open = lines.isEmpty ? nil : Self.parse(lines)
        }
    }

    private mutating func closeOpen() {
        if fence != nil { return }
        if !openLines.isEmpty { closed.append(Self.parse(openLines)) }
        openLines = []
        open = nil
    }

    // MARK: Classification

    private enum Kind { case paragraph, list, quote, table }

    private static func kind(of line: String) -> Kind {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(">") { return .quote }
        if t.hasPrefix("|") { return .table }
        if listMarker(line) != nil { return .list }
        return .paragraph
    }

    /// Indented or lazy lines continue a list item; anything continues a paragraph only if it is a paragraph line.
    private static func isContinuation(_ line: String, of first: String) -> Bool {
        let firstKind = kind(of: first)
        if firstKind == .list { return line.hasPrefix("  ") || line.hasPrefix("\t") }
        return false
    }

    private static func fenceOpen(_ line: String) -> (marker: Character, length: Int, language: String?)? {
        let t = line.drop { $0 == " " }
        guard line.count - t.count <= 3, let c = t.first, c == "`" || c == "~" else { return nil }
        let run = t.prefix { $0 == c }.count
        guard run >= 3 else { return nil }
        let info = t.dropFirst(run).trimmingCharacters(in: .whitespaces)
        if c == "`", info.contains("`") { return nil }
        return (c, run, info.isEmpty ? nil : String(info.split(separator: " ").first ?? ""))
    }

    private static func isFenceClose(_ line: String, marker: Character, length: Int) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= length && t.allSatisfy { $0 == marker }
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let after = trimmed.dropFirst(hashes)
        return after.isEmpty || after.first == " " ? hashes : nil
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { $0 != " " }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    private static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, number: Int?, rest: Substring)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let t = line.dropFirst(indent)
        if let c = t.first, "-*+".contains(c), t.dropFirst().first == " " {
            return (indent, false, nil, t.dropFirst(2))
        }
        let digits = t.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let after = t.dropFirst(digits.count)
            if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " {
                return (indent, true, Int(digits), after.dropFirst(2))
            }
        }
        return nil
    }

    // MARK: Parsing a block's lines

    static func parse(_ lines: [String]) -> MarkdownBlock {
        let first = lines[0].trimmingCharacters(in: .whitespaces)
        if let level = headingLevel(first) {
            return .heading(level: level, text: first.dropFirst(level).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces))
        }
        if isRule(first) { return .rule }
        switch kind(of: lines[0]) {
        case .quote:
            return .quote(lines.map { l in
                var t = Substring(l.trimmingCharacters(in: .whitespaces))
                if t.hasPrefix(">") { t = t.dropFirst() }
                if t.hasPrefix(" ") { t = t.dropFirst() }
                return String(t)
            }.joined(separator: "\n"))
        case .table:
            if let table = parseTable(lines) { return table }
            return .paragraph(lines.joined(separator: "\n"))
        case .list:
            var items: [MarkdownListItem] = []
            for line in lines {
                if let m = listMarker(line) {
                    var text = String(m.rest)
                    var task: Bool?
                    if text.hasPrefix("[ ] ") { task = false; text.removeFirst(4) }
                    else if text.lowercased().hasPrefix("[x] ") { task = true; text.removeFirst(4) }
                    items.append(MarkdownListItem(indent: m.indent, ordered: m.ordered, number: m.number, task: task, text: text))
                } else if !items.isEmpty {
                    items[items.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
                }
            }
            return .list(items)
        case .paragraph:
            return .paragraph(lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
        }
    }

    private static func cells(_ line: String) -> [String] {
        var t = Substring(line.trimmingCharacters(in: .whitespaces))
        if t.hasPrefix("|") { t = t.dropFirst() }
        if t.hasSuffix("|") { t = t.dropLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTable(_ lines: [String]) -> MarkdownBlock? {
        guard lines.count >= 2 else { return nil }
        let header = cells(lines[0])
        let delimiter = cells(lines[1])
        guard delimiter.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) else { return nil }
        let alignments: [TableAlignment] = delimiter.map { d in
            switch (d.hasPrefix(":"), d.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
        let rows = lines.dropFirst(2).map { row -> [String] in
            var c = cells(row)
            if c.count < header.count { c += Array(repeating: "", count: header.count - c.count) }
            return Array(c.prefix(header.count))
        }
        return .table(header: header, alignments: alignments, rows: rows)
    }
}
