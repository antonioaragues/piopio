import AppKit
import Foundation

/// Token spans for lightweight syntax highlighting (a stand-in for tree-sitter in the spike).
enum CodeToken { case keyword, string, comment, number }

nonisolated enum Highlighter {
    private static let keywords: Set<String> = [
        "let", "var", "func", "struct", "class", "enum", "return", "if", "else", "for", "in", "where", "try", "await", "async",
        "import", "export", "const", "function", "def", "lambda", "true", "false", "nil", "null", "self", "case", "switch", "as", "default",
    ]

    /// UTF-16 ranges, so they apply directly to NSString / NSAttributedString.
    static func tokens(_ code: String) -> [(NSRange, CodeToken)] {
        var out: [(NSRange, CodeToken)] = []
        let s = code.utf16
        var i = s.startIndex
        var offset = 0
        func peek(_ k: Int = 0) -> UInt16? {
            guard let j = s.index(i, offsetBy: k, limitedBy: s.endIndex), j < s.endIndex else { return nil }
            return s[j]
        }
        while i < s.endIndex {
            let c = s[i]
            let start = offset
            if (c == 0x2F && peek(1) == 0x2F) || c == 0x23 { // "//" or "#"
                while i < s.endIndex, s[i] != 0x0A { i = s.index(after: i); offset += 1 }
                out.append((NSRange(location: start, length: offset - start), .comment))
                continue
            }
            if c == 0x22 || c == 0x27 { // quotes
                let q = c
                i = s.index(after: i); offset += 1
                while i < s.endIndex, s[i] != q, s[i] != 0x0A {
                    if s[i] == 0x5C, s.index(after: i) < s.endIndex { i = s.index(after: i); offset += 1 }
                    i = s.index(after: i); offset += 1
                }
                if i < s.endIndex, s[i] == q { i = s.index(after: i); offset += 1 }
                out.append((NSRange(location: start, length: offset - start), .string))
                continue
            }
            if isIdentStart(c) {
                var word: [UInt16] = []
                while i < s.endIndex, isIdent(s[i]) { word.append(s[i]); i = s.index(after: i); offset += 1 }
                if keywords.contains(String(decoding: word, as: UTF16.self)) {
                    out.append((NSRange(location: start, length: offset - start), .keyword))
                }
                continue
            }
            if c >= 0x30 && c <= 0x39 {
                while i < s.endIndex, s[i] >= 0x30 && s[i] <= 0x39 || s[i] == 0x2E { i = s.index(after: i); offset += 1 }
                out.append((NSRange(location: start, length: offset - start), .number))
                continue
            }
            i = s.index(after: i); offset += 1
        }
        return out
    }

    private static func isIdentStart(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
    private static func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 0x30 && c <= 0x39) }

    static func color(_ t: CodeToken) -> NSColor {
        switch t {
        case .keyword: .systemPink
        case .string: .systemGreen
        case .comment: .secondaryLabelColor
        case .number: .systemOrange
        }
    }
}

extension NSFont {
    /// Thread-safe trait conversion (NSFontManager is main-thread only).
    func adding(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)), size: pointSize) ?? self
    }
}

nonisolated enum Inline {
    /// Inline markdown (bold, italic, code spans, links) → AttributedString. Falls back to plain text.
    static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(markdown)
    }

    /// Same, with AppKit fonts/colors resolved for TextKit.
    static func ns(_ markdown: String, font: NSFont, color: NSColor = .labelColor) -> NSMutableAttributedString {
        let a = attributed(markdown)
        let out = NSMutableAttributedString()
        for run in a.runs {
            let text = String(a[run.range].characters)
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { f = f.adding(.bold) }
                if intent.contains(.emphasized) { f = f.adding(.italic) }
                if intent.contains(.code) {
                    f = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
                    attrs[.backgroundColor] = NSColor.quaternaryLabelColor
                }
            }
            if let link = run.link { attrs[.link] = link }
            attrs[.font] = f
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }
}
