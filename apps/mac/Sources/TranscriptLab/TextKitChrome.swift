import AppKit
import Observation
import PiopioKit
import PiopioTranscript
import SwiftUI

// Spike S2b: TextKit 2 transcript with card chrome.
//
// - Cards (code, quote, table, user bubble) are single paragraphs (lines joined with U+2028)
//   tagged with `.piopioCard`; a custom NSTextLayoutFragment draws their rounded background.
// - Tool calls are NSTextAttachments with a view provider (AppKit or SwiftUI view) that expands in place.
// - `TranscriptBuilder` is nonisolated: the attributed string is built off the main thread and
//   loaded progressively (newest items first, older history prepended in chunks).

extension NSAttributedString.Key {
    static let piopioCard = NSAttributedString.Key("piopio.card")
}

enum CardStyle: String { case code, quote, table, user }

private let lineSeparator = "\u{2028}"

/// Moves an NSAttributedString between isolation domains (it is immutable once built).
struct SendableText: @unchecked Sendable { let value: NSAttributedString }

// MARK: Builder (any thread)

nonisolated struct TranscriptBuilder: Sendable {
    let cardViews: ToolCardKind

    private var body: NSFont { .systemFont(ofSize: 14) }
    private var mono: NSFont { .monospacedSystemFont(ofSize: 12.5, weight: .regular) }

    func render(_ items: ArraySlice<TimelineItem>) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for item in items { out.append(render(item)) }
        return out
    }

    func render(_ item: TimelineItem) -> NSAttributedString {
        switch item {
        case .user(let u):
            let text = Inline.ns(u.text.replacingOccurrences(of: "\n", with: lineSeparator), font: body)
            return card(text, .user, spacingAfter: 16)
        case .assistant(let a):
            let out = NSMutableAttributedString()
            for block in MarkdownStream(text: a.text).blocks { out.append(render(block)) }
            return out
        case .tool(let t):
            let attachment = ToolCardAttachment(card: ToolCard(tool: t.tool, status: t.status.rawValue, output: t.output ?? ""), kind: cardViews)
            let s = NSMutableAttributedString(attachment: attachment)
            s.append(NSAttributedString(string: "\n"))
            s.addAttribute(.paragraphStyle, value: style(spacing: 10), range: NSRange(location: 0, length: s.length))
            return s
        case .system(let s):
            return NSAttributedString(string: s.text + "\n", attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style()])
        case .compaction(let c):
            return NSAttributedString(string: "— \(c.summary)\n", attributes: [.font: body, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style()])
        case .checkpoint(let c):
            return NSAttributedString(string: "— \(c.label)\n", attributes: [.font: body, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style()])
        case .routing(let r):
            return NSAttributedString(string: "↳ \(r.topicTitle)\n", attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style()])
        }
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

    /// One paragraph that the card fragment draws a background behind.
    private func card(_ s: NSAttributedString, _ kind: CardStyle, spacingAfter: CGFloat = 14) -> NSAttributedString {
        let inset = CardLayoutFragment.padding + 4
        let m = NSMutableAttributedString(attributedString: line(s, style(spacing: spacingAfter + CardLayoutFragment.padding, before: CardLayoutFragment.padding + 2, indent: kind == .user ? 120 : inset, tail: -inset)))
        m.addAttribute(.piopioCard, value: kind.rawValue, range: NSRange(location: 0, length: m.length))
        return m
    }
}

// MARK: Card fragment

final class CardLayoutFragment: NSTextLayoutFragment {
    static let padding: CGFloat = 10
    var card: CardStyle = .code

    /// Background rect in fragment coordinates: the text's lines plus padding, full width (user: right-aligned bubble).
    private var cardRect: CGRect {
        guard let first = textLineFragments.first else { return .zero }
        var text = first.typographicBounds
        for l in textLineFragments.dropFirst() { text = text.union(l.typographicBounds) }
        let p = Self.padding
        // Fragment coordinates start at the paragraph's indent; cards span the container width.
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let originX = layoutFragmentFrame.minX
        let left: CGFloat = (card == .user ? 120 - p : 4) - originX
        return CGRect(x: left, y: text.minY - p, width: containerWidth - 8 - (left + originX - 4), height: text.height + 2 * p)
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(cardRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = cardRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        switch card {
        case .quote:
            context.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height))
        case .code, .table, .user:
            let color: NSColor = card == .user ? .controlAccentColor.withAlphaComponent(0.12) : .quaternaryLabelColor.withAlphaComponent(0.18)
            context.setFillColor(color.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.fillPath()
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

final class CardLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let raw = paragraph.attributedString.attribute(.piopioCard, at: 0, effectiveRange: nil) as? String,
           let style = CardStyle(rawValue: raw) {
            let f = CardLayoutFragment(textElement: textElement, range: range)
            f.card = style
            return f
        }
        return NSTextLayoutFragment(textElement: textElement, range: range)
    }
}

// MARK: Tool card attachment

enum ToolCardKind: String, Sendable { case appkit, swiftui }

@Observable
final class ToolCard: @unchecked Sendable {
    let tool: String
    let status: String
    let output: String
    var expanded = false
    @ObservationIgnored var onToggle: (@MainActor (ToolCard) -> Void)?

    init(tool: String, status: String, output: String) {
        self.tool = tool; self.status = status; self.output = output
    }

    static let collapsedHeight: CGFloat = 28

    func height(width: CGFloat) -> CGFloat {
        guard expanded else { return Self.collapsedHeight }
        let text = NSAttributedString(string: output, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
        let h = text.boundingRect(with: NSSize(width: max(50, width - 24), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return Self.collapsedHeight + ceil(h) + 12
    }
}

final class ToolCardAttachment: NSTextAttachment, @unchecked Sendable {
    let card: ToolCard
    let kind: ToolCardKind

    init(card: ToolCard, kind: ToolCardKind) {
        self.card = card
        self.kind = kind
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = Self.blank // otherwise TextKit also draws the generic document placeholder
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let blank: NSImage = NSImage(size: NSSize(width: 1, height: 1))

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = ToolCardViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class ToolCardViewProvider: NSTextAttachmentViewProvider {
    private var attachment: ToolCardAttachment { textAttachment as! ToolCardAttachment }

    override func loadView() {
        let card = attachment.card
        let kind = attachment.kind
        view = MainActor.assumeIsolated {
            switch kind {
            case .appkit: AppKitToolCardView(card: card)
            case .swiftui: NSHostingView(rootView: SwiftUIToolCardView(card: card))
            }
        }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = proposedLineFragment.width - 8
        return CGRect(x: 0, y: 0, width: width, height: attachment.card.height(width: width))
    }
}

final class AppKitToolCardView: NSView {
    private let card: ToolCard
    private let header = NSButton()
    private let output = NSTextField(wrappingLabelWithString: "")

    init(card: ToolCard) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        header.isBordered = false
        header.alignment = .left
        header.target = self
        header.action = #selector(toggle)
        header.contentTintColor = .secondaryLabelColor
        output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.textColor = .secondaryLabelColor
        output.isSelectable = true
        addSubview(header)
        addSubview(output)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() {
        card.expanded.toggle()
        update()
        card.onToggle?(card)
    }

    private func update() {
        header.title = "\(card.expanded ? "▾" : "▸")  ⚙︎ \(card.tool) · \(card.status)"
        output.stringValue = card.expanded ? card.output : ""
        output.isHidden = !card.expanded
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The model can change from outside (TextKit relayout after a toggle elsewhere): resync here.
        if output.isHidden == card.expanded { update() }
        header.frame = NSRect(x: 8, y: bounds.height - ToolCard.collapsedHeight, width: bounds.width - 16, height: ToolCard.collapsedHeight)
        output.frame = NSRect(x: 12, y: 6, width: bounds.width - 24, height: max(0, bounds.height - ToolCard.collapsedHeight - 6))
    }
}

struct SwiftUIToolCardView: View {
    let card: ToolCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                card.expanded.toggle()
                card.onToggle?(card)
            } label: {
                Label("\(card.tool) · \(card.status)", systemImage: card.expanded ? "chevron.down" : "chevron.right")
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: ToolCard.collapsedHeight - 4, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if card.expanded {
                Text(card.output).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Renderer

@MainActor
final class TextKitCardsRenderer: LabRenderer {
    let name: String
    private let scroll: NSScrollView
    private let textView: NSTextView
    private let layoutDelegate = CardLayoutDelegate()
    private let builder: TranscriptBuilder
    private var storage: NSTextStorage { textView.textStorage! }
    private var layoutManager: NSTextLayoutManager { textView.textLayoutManager! }

    private var stream: MarkdownStream?
    private var renderedClosed = 0
    private var closedEnd = 0

    /// Main-thread cost of each progressive prepend (ms).
    private(set) var prependCosts: [Double] = []

    init(cardViews: ToolCardKind) {
        builder = TranscriptBuilder(cardViews: cardViews)
        name = "textkit-cards-\(cardViews.rawValue)"
        scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 20)
        precondition(textView.textLayoutManager != nil, "expected a TextKit 2 text view")
        textView.textLayoutManager!.delegate = layoutDelegate
    }

    var view: NSView { scroll }
    func scrollView() -> NSScrollView? { scroll }

    func load(_ items: [TimelineItem]) {
        storage.setAttributedString(builder.render(items[...]))
        wireCards(in: NSRange(location: 0, length: storage.length))
    }

    /// Shows the newest `tail` items as soon as they are built, then prepends older history in chunks.
    /// Returns when the tail is on screen; `backfill` completes when everything is loaded.
    /// Backfill strategy (`PIOPIO_LAB_BACKFILL`): `chunks:N` prepends N items at a time; `swap` builds the
    /// whole document off the main thread and replaces the storage once.
    func loadProgressively(_ items: [TimelineItem], tail: Int = 200) async -> Task<Void, Never> {
        let strategy = ProcessInfo.processInfo.environment["PIOPIO_LAB_BACKFILL"] ?? "window:300:10"
        if strategy.hasPrefix("window:") {
            let parts = strategy.split(separator: ":").compactMap { Int($0) }
            await loadWindowed(items, window: parts.first ?? 300, page: parts.dropFirst().first ?? 10)
            return Task {}
        }
        let chunk = strategy.hasPrefix("chunks:") ? Int(strategy.dropFirst(7)) ?? 250 : 0
        let builder = self.builder
        let split = max(0, items.count - tail)
        let tailText = await Task.detached(priority: .userInitiated) { SendableText(value: builder.render(items[split...])) }.value
        storage.setAttributedString(tailText.value)
        wireCards(in: NSRange(location: 0, length: storage.length))
        textView.scrollToEndOfDocument(nil)
        prependCosts = []
        if chunk == 0 {
            return Task { @MainActor in
                let full = await Task.detached(priority: .utility) { SendableText(value: builder.render(items[...])) }.value
                let t = CACurrentMediaTime()
                storage.setAttributedString(full.value)
                wireCards(in: NSRange(location: 0, length: storage.length))
                textView.scrollToEndOfDocument(nil)
                prependCosts.append((CACurrentMediaTime() - t) * 1000)
            }
        }
        return Task { @MainActor in
            var end = split
            while end > 0 {
                let start = max(0, end - chunk)
                let part = await Task.detached(priority: .utility) { [start, end] in SendableText(value: builder.render(items[start..<end])) }.value
                let t = CACurrentMediaTime()
                let wasAtBottom = isAtBottom
                storage.insert(part.value, at: 0)
                let t1 = CACurrentMediaTime()
                wireCards(in: NSRange(location: 0, length: part.value.length))
                let t2 = CACurrentMediaTime()
                closedEnd += part.value.length
                if wasAtBottom, ProcessInfo.processInfo.environment["PIOPIO_LAB_NOSCROLL"] == nil { textView.scrollToEndOfDocument(nil) }
                let t3 = CACurrentMediaTime()
                prependCosts.append((t3 - t) * 1000)
                if ProcessInfo.processInfo.environment["PIOPIO_LAB_TRACE"] != nil {
                    print(String(format: "prepend %d chars: insert %.1f wire %.1f scroll %.1f ms", part.value.length, (t1 - t) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000))
                }
                end = start
            }
        }
    }

    // MARK: Windowed document (newest items; older pages are prepended on demand near the top)

    private var older: [TimelineItem] = []
    private var page = 50
    private var prefetched: (text: SendableText, count: Int)?
    private var prefetching = false
    private var boundsObserver: NSObjectProtocol?
    /// Main-thread cost of each on-demand page insert, and how far the visible text moved (should be 0).
    private(set) var pageCosts: [Double] = []
    private(set) var maxAnchorDrift = 0

    func loadWindowed(_ items: [TimelineItem], window: Int, page: Int) async {
        self.page = page
        let split = max(0, items.count - window)
        older = Array(items[..<split])
        let builder = self.builder
        let tail = await Task.detached(priority: .userInitiated) { SendableText(value: builder.render(items[split...])) }.value
        storage.setAttributedString(tail.value)
        wireCards(in: NSRange(location: 0, length: storage.length))
        textView.scrollToEndOfDocument(nil)
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadOlderIfNeeded() }
        }
        prefetchOlder()
    }

    private func prefetchOlder() {
        guard !prefetching, prefetched == nil, !older.isEmpty else { return }
        prefetching = true
        let slice = Array(older[max(0, older.count - page)...])
        let builder = self.builder
        Task {
            let text = await Task.detached(priority: .userInitiated) { SendableText(value: builder.render(slice[...])) }.value
            prefetched = (text, slice.count)
            prefetching = false
            loadOlderIfNeeded()
        }
    }

    private func loadOlderIfNeeded() {
        let clip = scroll.contentView
        guard clip.bounds.minY < 4000, let next = prefetched else { return }
        prefetched = nil
        let t = CACurrentMediaTime()
        let anchorBefore = topVisibleOffset()
        let heightBefore = textView.frame.height
        let y0 = clip.bounds.minY
        storage.insert(next.text.value, at: 0)
        let tInsert = CACurrentMediaTime()
        wireCards(in: NSRange(location: 0, length: next.text.value.length))
        older.removeLast(next.count)
        // Lay out the inserted page so the document height is exact, then keep the same text on screen.
        if let content = layoutManager.textContentManager,
           let end = content.location(content.documentRange.location, offsetBy: next.text.value.length),
           let inserted = NSTextRange(location: content.documentRange.location, end: end) {
            layoutManager.ensureLayout(for: inserted)
        }
        let tEnsure = CACurrentMediaTime()
        layoutManager.textViewportLayoutController.layoutViewport()
        clip.scroll(to: NSPoint(x: 0, y: y0 + textView.frame.height - heightBefore))
        scroll.reflectScrolledClipView(clip)
        layoutManager.textViewportLayoutController.layoutViewport()
        if let before = anchorBefore, let after = topVisibleOffset() {
            maxAnchorDrift = max(maxAnchorDrift, abs(after - (before + next.text.value.length)))
        }
        pageCosts.append((CACurrentMediaTime() - t) * 1000)
        if ProcessInfo.processInfo.environment["PIOPIO_LAB_TRACE"] != nil {
            print(String(format: "page %d items (%d chars into %d): insert %.1f, ensureLayout %.1f, rest %.1f ms", next.count, next.text.value.length, storage.length, (tInsert - t) * 1000, (tEnsure - tInsert) * 1000, (CACurrentMediaTime() - tEnsure) * 1000))
        }
        prefetchOlder()
    }

    /// Character offset of the first layout fragment at the top of the viewport.
    private func topVisibleOffset() -> Int? {
        let y = scroll.contentView.bounds.minY + 1
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 30, y: y)),
              let content = layoutManager.textContentManager else { return nil }
        return content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
    }

    private var isAtBottom: Bool {
        let clip = scroll.contentView
        return clip.bounds.maxY >= (scroll.documentView?.frame.height ?? 0) - 40
    }

    /// Tool cards ask for a relayout of their paragraph when they expand or collapse.
    private func wireCards(in range: NSRange) {
        storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
            guard let attachment = value as? ToolCardAttachment else { return }
            attachment.card.onToggle = { [weak self] card in self?.relayout(card) }
        }
    }

    func relayout(_ card: ToolCard) {
        var location: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? ToolCardAttachment)?.card === card { location = range.location; stop.pointee = true }
        }
        guard let location, let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: location),
              let end = content.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return }
        layoutManager.invalidateLayout(for: range)
        layoutManager.textViewportLayoutController.layoutViewport()
    }

    /// The last `count` tool cards in the document (for the toggle benchmark).
    func lastCards(_ count: Int) -> [ToolCard] {
        var cards: [ToolCard] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: .reverse) { value, _, stop in
            if let a = value as? ToolCardAttachment { cards.append(a.card) }
            if cards.count == count { stop.pointee = true }
        }
        return cards
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
        stream = nil
    }

    private func replaceTail(with s: MarkdownStream) {
        let tail = NSMutableAttributedString()
        for block in s.closed[renderedClosed...] { tail.append(builder.render(block)) }
        let closedLength = tail.length
        if let open = s.open { tail.append(builder.render(open)) }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: closedEnd, length: storage.length - closedEnd), with: tail)
        storage.endEditing()
        closedEnd += closedLength
        renderedClosed = s.closed.count
    }
}
