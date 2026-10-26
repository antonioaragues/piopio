import AppKit
import PiopioKit

/// Copy as (chat v3 follow-up): an answer as Markdown (what Copy has always done), as plain text without the Markdown
/// marks, or as rich text for Mail, Notes or Pages (headings, bold, lists, code; the plain text goes with it).
public enum CopyFormat: String, CaseIterable, Sendable {
    case markdown = "Markdown"
    case plain = "Plain Text"
    case rich = "Rich Text"

    /// Puts `markdown` on the pasteboard in this format.
    @MainActor public func copy(_ markdown: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch self {
        case .markdown:
            pb.setString(markdown, forType: .string)
        case .plain:
            pb.setString(Self.plain(markdown), forType: .string)
        case .rich:
            let rich = Self.rich(markdown)
            if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pb.setData(rtf, forType: .rtf)
            }
            pb.setString(Self.plain(markdown), forType: .string)
        }
    }

    /// The text as it reads: no **, #, ` or link syntax; bullets as "•", tables as tab-separated rows.
    static func plain(_ markdown: String) -> String {
        var out: [String] = []
        for block in MarkdownStream(text: markdown).blocks {
            switch block {
            case .heading(_, let text): out.append(inline(text))
            case .paragraph(let text): out.append(inline(text))
            case .quote(let text): out.append(text.split(separator: "\n").map { "“\(inline(String($0)))”" }.joined(separator: "\n"))
            case .list(let items):
                out.append(items.enumerated().map { i, item in
                    let marker = item.task.map { $0 ? "☑" : "☐" } ?? (item.ordered ? "\(item.number ?? i + 1)." : "•")
                    return String(repeating: "  ", count: item.indent) + "\(marker) \(inline(item.text))"
                }.joined(separator: "\n"))
            case .code(_, let code, _): out.append(code)
            case .table(let header, _, let rows): out.append(([header] + rows).map { $0.map(inline).joined(separator: "\t") }.joined(separator: "\n"))
            case .rule: out.append("———")
            }
        }
        return out.joined(separator: "\n\n")
    }

    /// Inline Markdown as its text: [title](url) → "title (url)", emphasis and code marks dropped.
    static func inline(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)", options: .regularExpression)
        for mark in ["**", "__", "~~", "`"] { t = t.replacingOccurrences(of: mark, with: "") }
        t = t.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*]+)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        return t
    }

    /// The answer as the transcript draws it, in the plain colors of a document (black text, blue links).
    static func rich(_ markdown: String) -> NSAttributedString {
        let rendered = NSMutableAttributedString(attributedString: ItemRenderer(compact: true).render(MarkdownStream(text: markdown).blocks))
        let all = NSRange(location: 0, length: rendered.length)
        rendered.mutableString.replaceOccurrences(of: lineSeparator, with: "\n", range: all)
        let range = NSRange(location: 0, length: rendered.length)
        rendered.removeAttribute(.piopioCard, range: range)
        rendered.removeAttribute(.piopioPill, range: range)
        rendered.enumerateAttribute(.foregroundColor, in: range) { _, r, _ in
            let isLink = rendered.attribute(.link, at: r.location, effectiveRange: nil) != nil
            rendered.addAttribute(.foregroundColor, value: isLink ? NSColor.systemBlue : NSColor.black, range: r)
        }
        return rendered
    }
}
