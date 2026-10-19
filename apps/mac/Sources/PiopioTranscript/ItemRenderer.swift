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
            let out = NSMutableAttributedString(attributedString: card(text, .user, spacingAfter: 2))
            out.append(userFooter(u))
            return out
        case .assistant(let a):
            let out = NSMutableAttributedString()
            let thinking = a.parts.filter { $0.type == .thinking }.map(\.text).joined()
            if !thinking.isEmpty { out.append(thinkingCard(DisclosureCard(kind: .thinking, title: "Thinking", body: thinking))) }
            for block in MarkdownStream(text: a.text).blocks { out.append(render(block)) }
            out.append(footer(a))
            if a.status != .streaming { out.append(answerFooter(a)) }
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
            let m = NSMutableAttributedString(string: a.error ?? "The model returned an error.", attributes: [.font: body, .foregroundColor: NSColor.systemRed])
            m.append(NSAttributedString(string: "   "))
            if a.errorKind == .auth {
                m.append(action("Open Settings", .openSettings, size: 13))
            } else {
                m.append(action("Retry", .regenerate(itemId: a.id), size: 13))
            }
            if a.errorDetail != nil {
                m.append(NSAttributedString(string: "  ·  ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor]))
                m.append(action("Details", .showErrorDetail(itemId: a.id), size: 13))
            }
            return card(m, .error)
        case .aborted:
            return line(NSAttributedString(string: "Stopped", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor]), style())
        case .done, .streaming:
            return NSAttributedString()
        }
    }

    // MARK: Footers (actions under messages)

    private var footerFont: NSFont { .systemFont(ofSize: 11.5) }

    /// A clickable word handled by `TranscriptDocument` (not underlined, secondary color).
    func action(_ title: String, _ action: TranscriptAction, size: CGFloat = 11.5, help: String? = nil) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor, .link: action.url]
        if let help { attrs[.toolTip] = help }
        return NSAttributedString(string: title, attributes: attrs)
    }

    private func gap() -> NSAttributedString {
        NSAttributedString(string: "    ", attributes: [.font: footerFont])
    }

    /// Under your message: version switcher (when there are versions), Edit, Copy. Right-aligned under the bubble.
    func userFooter(_ u: UserItem) -> NSAttributedString {
        let m = NSMutableAttributedString()
        if let b = u.branch {
            let dim: [NSAttributedString.Key: Any] = [.font: footerFont, .foregroundColor: NSColor.tertiaryLabelColor]
            m.append(b.previous.map { action("‹", .switchBranch($0), size: 13, help: "Previous version") } ?? NSAttributedString(string: "‹", attributes: dim))
            m.append(NSAttributedString(string: "  \(b.index + 1) / \(b.count)  ", attributes: [.font: footerFont, .foregroundColor: NSColor.secondaryLabelColor]))
            m.append(b.next.map { action("›", .switchBranch($0), size: 13, help: "Next version") } ?? NSAttributedString(string: "›", attributes: dim))
            m.append(gap())
        }
        m.append(action("Edit", .edit(itemId: u.id), help: "Edit and resend (keeps this version)"))
        m.append(gap())
        m.append(action("Copy", .copy(itemId: u.id)))
        m.append(NSAttributedString(string: "\n"))
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        p.tailIndent = -(CardLayoutFragment.padding + 4)
        p.paragraphSpacing = 16
        m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
        return m
    }

    /// Under an answer: Copy, Regenerate, Fork, then the model and cost.
    func answerFooter(_ a: AssistantItem) -> NSAttributedString {
        let m = NSMutableAttributedString()
        if !a.text.isEmpty {
            m.append(action("Copy", .copy(itemId: a.id)))
            m.append(gap())
        }
        m.append(action("Regenerate", .regenerate(itemId: a.id), help: "Ask again (keeps this version)"))
        m.append(gap())
        m.append(action("Fork", .fork(itemId: a.id), help: "Continue from here in a new thread"))
        var meta: [String] = []
        if let model = a.model { meta.append(model.split(separator: "/").dropFirst().joined(separator: "/").nilIfEmpty ?? model) }
        if let u = a.usage, u.costUsd > 0 { meta.append(u.costUsd < 0.01 ? String(format: "$%.4f", u.costUsd) : String(format: "$%.2f", u.costUsd)) }
        if !meta.isEmpty {
            var attrs: [NSAttributedString.Key: Any] = [.font: footerFont, .foregroundColor: NSColor.tertiaryLabelColor]
            if let u = a.usage { attrs[.toolTip] = "\(Int(u.inputTokens)) in · \(Int(u.outputTokens)) out · \(Int(u.cacheReadTokens)) cached tokens" }
            m.append(gap())
            m.append(NSAttributedString(string: meta.joined(separator: " · "), attributes: attrs))
        }
        m.append(NSAttributedString(string: "\n"))
        m.addAttribute(.paragraphStyle, value: style(spacing: 18, before: 0), range: NSRange(location: 0, length: m.length))
        return m
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
