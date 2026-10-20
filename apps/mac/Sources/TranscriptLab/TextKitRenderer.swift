import AppKit
import PiopioKit
import PiopioTranscript

// Candidate B: the whole transcript in one TextKit 2 NSTextView (viewport-based layout).
// Streaming replaces only the attributed range of the open tail block.
// Free wins: selection across messages, find, accessibility of plain text.
// Costs: cards (tool calls, code blocks with chrome, tables) need attachments or custom fragments.

@MainActor
final class TextKitRenderer: LabRenderer {
    let name = "textkit"
    private let scroll: NSScrollView
    private let textView: NSTextView
    private var storage: NSTextStorage { textView.textStorage! }

    // Streaming state
    private var stream: MarkdownStream?
    private var renderedClosed = 0
    private var closedEnd = 0   // UTF-16 offset where the open tail starts

    private let body = NSFont.systemFont(ofSize: 14)
    private let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    init() {
        scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 20)
        precondition(textView.textLayoutManager != nil, "expected a TextKit 2 text view")
    }

    var view: NSView { scroll }
    func scrollView() -> NSScrollView? { scroll }

    func load(_ items: [TimelineItem]) {
        let out = NSMutableAttributedString()
        for item in items { out.append(render(item)) }
        storage.setAttributedString(out)
    }

    func beginStreaming() {
        stream = MarkdownStream()
        renderedClosed = 0
        closedEnd = storage.length
    }

    func append(_ delta: String) {
        guard var s = stream else { return }
        s.append(delta)
        stream = s
        replaceTail(with: s)
    }

    func finishStreaming() {
        guard var s = stream else { return }
        s.finish()
        replaceTail(with: s)
        storage.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        stream = nil
    }

    private func replaceTail(with s: MarkdownStream) {
        let tail = NSMutableAttributedString()
        let newlyClosed = s.closed[renderedClosed...]
        for block in newlyClosed { tail.append(render(block)) }
        let closedLength = tail.length
        if let open = s.open { tail.append(render(open)) }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: closedEnd, length: storage.length - closedEnd), with: tail)
        storage.endEditing()
        closedEnd += closedLength
        renderedClosed = s.closed.count
    }

    // MARK: Rendering

    private func paragraphStyle(spacing: CGFloat = 8, indent: CGFloat = 0, head: CGFloat? = nil) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing
        p.firstLineHeadIndent = indent
        p.headIndent = head ?? indent
        p.lineHeightMultiple = 1.1
        return p
    }

    private func render(_ item: TimelineItem) -> NSAttributedString {
        let out = NSMutableAttributedString()
        switch item {
        case .user(let u):
            out.append(NSAttributedString(string: "You\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
            let text = Inline.ns(u.text, font: body)
            text.addAttributes([.backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.4), .paragraphStyle: paragraphStyle(spacing: 14)], range: NSRange(location: 0, length: text.length))
            out.append(text)
            out.append(NSAttributedString(string: "\n"))
        case .assistant(let a):
            for block in MarkdownStream(text: a.text).blocks { out.append(render(block)) }
            out.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        case .tool(let t):
            out.append(NSAttributedString(string: "⚙︎ \(t.tool) · \(t.status.rawValue)\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraphStyle(spacing: 10)]))
        case .system(let s):
            out.append(NSAttributedString(string: s.text + "\n", attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]))
        case .compaction(let c):
            out.append(NSAttributedString(string: "— " + c.summary + "\n", attributes: [.font: body, .foregroundColor: NSColor.tertiaryLabelColor]))
        case .checkpoint(let c):
            out.append(NSAttributedString(string: "— \(c.label)\n", attributes: [.font: body, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return out
    }

    private func render(_ block: MarkdownBlock) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func line(_ s: NSAttributedString, style: NSParagraphStyle) {
            let m = NSMutableAttributedString(attributedString: s)
            m.append(NSAttributedString(string: "\n"))
            m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
            out.append(m)
        }
        switch block {
        case .heading(let level, let text):
            line(Inline.ns(text, font: .boldSystemFont(ofSize: level <= 2 ? 19 : 15)), style: paragraphStyle(spacing: 6))
        case .paragraph(let text):
            line(Inline.ns(text, font: body), style: paragraphStyle())
        case .quote(let text):
            line(Inline.ns(text, font: body, color: .secondaryLabelColor), style: paragraphStyle(indent: 14))
        case .list(let items):
            for (i, item) in items.enumerated() {
                let marker = item.task.map { $0 ? "☑︎ " : "☐ " } ?? (item.ordered ? "\(item.number ?? i + 1). " : "•  ")
                let indent = CGFloat(item.indent) * 8 + 6
                let m = NSMutableAttributedString(string: marker, attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor])
                m.append(Inline.ns(item.text, font: body))
                line(m, style: paragraphStyle(spacing: i == items.count - 1 ? 8 : 3, indent: indent, head: indent + 18))
            }
        case .code(let language, let code, _):
            if let language { line(NSAttributedString(string: language, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]), style: paragraphStyle(spacing: 2, indent: 10)) }
            let m = NSMutableAttributedString(string: code, attributes: [.font: mono, .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.25)])
            for (range, token) in Highlighter.tokens(code) where NSMaxRange(range) <= m.length {
                m.addAttribute(.foregroundColor, value: Highlighter.color(token), range: range)
            }
            line(m, style: paragraphStyle(spacing: 0, indent: 10))
            if let last = out.string.utf16.indices.last.map({ out.string.utf16.distance(from: out.string.utf16.startIndex, to: $0) }) {
                out.addAttribute(.paragraphStyle, value: paragraphStyle(spacing: 10, indent: 10), range: NSRange(location: last, length: 1))
            }
        case .table(let header, _, let rows):
            let widths = header.indices.map { c in ([header] + rows).map { $0.indices.contains(c) ? $0[c].count : 0 }.max() ?? 0 }
            func row(_ cells: [String]) -> String { cells.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "   ") }
            let text = ([row(header), widths.map { String(repeating: "─", count: $0) }.joined(separator: "   ")] + rows.map(row)).joined(separator: "\n")
            line(NSAttributedString(string: text, attributes: [.font: mono]), style: paragraphStyle(spacing: 10, indent: 10))
        case .rule:
            line(NSAttributedString(string: "———", attributes: [.font: body, .foregroundColor: NSColor.tertiaryLabelColor]), style: paragraphStyle())
        }
        return out
    }
}
