import AppKit
import PiopioKit

/// Moves an NSAttributedString across isolation domains (immutable once built).
struct SendableText: @unchecked Sendable { let value: NSAttributedString }

/// Renders timeline items to attributed text. Thread-safe: windows are built off the main thread.
/// Every rendered item ends with a paragraph break (or is empty), so items never share a paragraph.
nonisolated struct ItemRenderer: Sendable {
    private var body: NSFont { .systemFont(ofSize: 14) }
    private var mono: NSFont { .monospacedSystemFont(ofSize: 12.5, weight: .regular) }

    func render(_ items: some Sequence<TimelineItem>) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for item in items { out.append(render(item)) }
        return out
    }

    func render(_ item: TimelineItem) -> NSAttributedString {
        switch item {
        case .user(let u):
            // Your own words, as typed: no markdown interpretation (pasted fences and tables stay readable).
            let text = NSAttributedString(string: u.text.replacingOccurrences(of: "\n", with: lineSeparator), attributes: [.font: body, .foregroundColor: NSColor.labelColor])
            return card(text, .user, spacingAfter: 16)
        case .assistant(let a):
            let out = NSMutableAttributedString()
            let thinking = a.parts.filter { $0.type == .thinking }.map(\.text).joined()
            if !thinking.isEmpty { out.append(thinkingCard(DisclosureCard(kind: .thinking, title: "Thinking", body: thinking))) }
            for block in MarkdownStream(text: a.text).blocks { out.append(render(block)) }
            out.append(footer(a))
            return out
        case .tool(let t):
            let card = DisclosureCard(kind: .tool, title: t.tool, detail: t.status.rawValue, body: t.output ?? "")
            return attachmentParagraph(DisclosureAttachment(card: card))
        case .system(let s):
            if s.level == .error { return card(NSAttributedString(string: s.text, attributes: [.font: body, .foregroundColor: NSColor.systemRed]), .error) }
            return line(NSAttributedString(string: s.text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]), style())
        case .compaction(let c):
            return line(NSAttributedString(string: "Context compacted — \(c.summary)", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor]), style())
        }
    }

    /// Error or stop notice under an assistant answer (empty when it finished normally).
    func footer(_ a: AssistantItem) -> NSAttributedString {
        switch a.status {
        case .error:
            return card(NSAttributedString(string: a.error ?? "The model returned an error.", attributes: [.font: body, .foregroundColor: NSColor.systemRed]), .error)
        case .aborted:
            return line(NSAttributedString(string: "Stopped", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor]), style())
        case .done, .streaming:
            return NSAttributedString()
        }
    }

    func thinkingCard(_ card: DisclosureCard) -> NSAttributedString {
        attachmentParagraph(DisclosureAttachment(card: card))
    }

    func render(_ block: MarkdownBlock) -> NSAttributedString {
        switch block {
        case .heading(let level, let text):
            return line(Inline.ns(text, font: .boldSystemFont(ofSize: level <= 2 ? 19 : 15)), style(spacing: 6, before: 6))
        case .paragraph(let text):
            return line(Inline.ns(text, font: body), style())
        case .quote(let text):
            return card(Inline.ns(text.replacingOccurrences(of: "\n", with: lineSeparator), font: body, color: .secondaryLabelColor), .quote)
        case .list(let items):
            let out = NSMutableAttributedString()
            for (i, item) in items.enumerated() {
                let marker = item.task.map { $0 ? "☑︎ " : "☐ " } ?? (item.ordered ? "\(item.number ?? i + 1). " : "•  ")
                let indent = CGFloat(item.indent) * 8 + 6
                let m = NSMutableAttributedString(string: marker, attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor])
                m.append(Inline.ns(item.text, font: body))
                out.append(line(m, style(spacing: i == items.count - 1 ? 8 : 3, indent: indent, head: indent + 18)))
            }
            return out
        case .code(let language, let code, _):
            let m = NSMutableAttributedString()
            if let language {
                m.append(NSAttributedString(string: language + lineSeparator, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let start = m.length
            m.append(NSAttributedString(string: code.replacingOccurrences(of: "\n", with: lineSeparator), attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
            for (range, token) in Highlighter.tokens(code) where NSMaxRange(range) + start <= m.length {
                m.addAttribute(.foregroundColor, value: Highlighter.color(token), range: NSRange(location: range.location + start, length: range.length))
            }
            return card(m, .code)
        case .table(let header, _, let rows):
            let widths = header.indices.map { c in ([header] + rows).map { $0.indices.contains(c) ? $0[c].count : 0 }.max() ?? 0 }
            func row(_ cells: [String]) -> String { cells.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "   ") }
            let text = NSMutableAttributedString(string: row(header), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)])
            for r in rows { text.append(NSAttributedString(string: lineSeparator + row(r), attributes: [.font: mono])) }
            return card(text, .table)
        case .rule:
            return line(NSAttributedString(string: "———", attributes: [.font: body, .foregroundColor: NSColor.tertiaryLabelColor]), style())
        }
    }

    // MARK: Helpers

    private func style(spacing: CGFloat = 8, before: CGFloat = 0, indent: CGFloat = 0, head: CGFloat? = nil, tail: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing
        p.paragraphSpacingBefore = before
        p.firstLineHeadIndent = indent
        p.headIndent = head ?? indent
        p.tailIndent = tail
        p.lineHeightMultiple = 1.1
        return p
    }

    private func line(_ s: NSAttributedString, _ style: NSParagraphStyle) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        m.append(NSAttributedString(string: "\n"))
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        return m
    }

    private func attachmentParagraph(_ attachment: NSTextAttachment) -> NSAttributedString {
        let s = NSMutableAttributedString(attachment: attachment)
        s.append(NSAttributedString(string: "\n"))
        s.addAttribute(.paragraphStyle, value: style(spacing: 10), range: NSRange(location: 0, length: s.length))
        return s
    }

    /// One paragraph that `CardLayoutFragment` draws a background behind.
    private func card(_ s: NSAttributedString, _ kind: CardStyle, spacingAfter: CGFloat = 14) -> NSAttributedString {
        let p = CardLayoutFragment.padding
        let inset = p + 4
        let indent = kind == .user ? CardLayoutFragment.userIndent : inset
        let m = NSMutableAttributedString(attributedString: line(s, style(spacing: spacingAfter + p, before: p + 2, indent: indent, tail: -inset)))
        m.addAttribute(.piopioCard, value: kind.rawValue, range: NSRange(location: 0, length: m.length))
        return m
    }
}
