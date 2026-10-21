import AppKit
import Observation
import SwiftUI

// Card chrome for the TextKit 2 transcript (docs/design 8e "Transcript", docs/spikes/s2):
// - Static cards (code, table, quote, user bubble, error card, system note) are single paragraphs,
//   lines joined with U+2028, tagged `.piopioCard`; `CardLayoutFragment` draws them behind the text.
// - Capsules behind runs tagged `.piopioPill` (action buttons, file chips) are drawn by the same fragment.
// - Interactive cards (tool calls, thinking) are attachments whose view expands in place.

extension NSAttributedString.Key {
    public static let piopioCard = NSAttributedString.Key("piopio.card")
    /// A capsule behind the run: `PillStyle.rawValue`.
    static let piopioPill = NSAttributedString.Key("piopio.pill")
    /// Natural (single-line) width of a user bubble's text; the document turns it into indents per column width.
    static let piopioBubbleWidth = NSAttributedString.Key("piopio.bubbleWidth")
    /// Hover-revealed actions under a message (value: item id), and the link they open when shown.
    static let piopioFooter = NSAttributedString.Key("piopio.footer")
    static let piopioFooterLink = NSAttributedString.Key("piopio.footerLink")
    static let piopioFooterColor = NSAttributedString.Key("piopio.footerColor")
}

public enum CardStyle: String, Sendable { case code, quote, table, user, errorCard, link, note, pills, divider, approval }

enum PillStyle: String { case primary, secondary, file }

let lineSeparator = "\u{2028}"

/// Draws card backgrounds and pills for the paragraphs that carry them.
final class CardLayoutFragment: NSTextLayoutFragment {
    static let padding: CGFloat = 12
    static let bubblePadH: CGFloat = 14
    static let bubblePadV: CGFloat = 9
    var card: CardStyle = .pills

    private var lines: [NSTextLineFragment] { textLineFragments.filter { $0.characterRange.length > 0 } }

    /// Union of the text lines in fragment coordinates.
    private var textBounds: CGRect {
        guard let first = lines.first else { return .zero }
        return lines.dropFirst().reduce(first.typographicBounds) { $0.union($1.typographicBounds) }
    }

    /// Full column width, in fragment coordinates (fragments start at the paragraph indent).
    private func columnRect(_ text: CGRect, pad: CGFloat) -> CGRect {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let originX = layoutFragmentFrame.minX
        return CGRect(x: -originX, y: text.minY - pad, width: width, height: text.height + 2 * pad)
    }

    private var cardRect: CGRect {
        let text = textBounds
        guard text != .zero else { return .zero }
        switch card {
        case .code, .table, .errorCard, .link, .approval: return columnRect(text, pad: Self.padding)
        case .quote: return columnRect(text, pad: 2)
        case .user:
            // The bubble hugs the text. Line metrics can come back narrower than the text (seen as a 28-pt bubble
            // behind longer text), so the width measured when the message was rendered is the floor.
            var r = text
            if let p = (textElement as? NSTextParagraph)?.attributedString, p.length > 0,
               let natural = p.attribute(.piopioBubbleWidth, at: 0, effectiveRange: nil) as? NSNumber {
                let available = columnRect(text, pad: 0).maxX - r.minX - Self.bubblePadH
                r.size.width = max(r.width, min(CGFloat(natural.doubleValue), available))
            }
            return r.insetBy(dx: -Self.bubblePadH, dy: -Self.bubblePadV)
        case .note: return text.insetBy(dx: -12, dy: -5)
        case .pills: return .zero
        case .divider: return columnRect(text, pad: 0)
        }
    }

    override var renderingSurfaceBounds: CGRect {
        let base = super.renderingSurfaceBounds.union(cardRect)
        return base.insetBy(dx: -8, dy: -6) // pills overhang their glyphs a little
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = cardRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        switch card {
        case .code:
            fill(context, rect, DS.chip, radius: DS.Radius.card)
        case .table, .errorCard, .link:
            fill(context, rect, DS.card, radius: DS.Radius.card)
            stroke(context, rect, DS.line, radius: DS.Radius.card)
        case .approval:
            // docs/design 2a: a 1pt accent line with a 4pt soft halo.
            fill(context, rect.insetBy(dx: -4, dy: -4), DS.accentSoft, radius: DS.Radius.card + 4)
            fill(context, rect, DS.card, radius: DS.Radius.card)
            stroke(context, rect, DS.accentLine, radius: DS.Radius.card)
        case .quote:
            context.setFillColor(DS.line.cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height))
        case .user:
            // 16/16/4/16: the corner by the sender is tighter.
            context.addPath(bubblePath(rect))
            context.setFillColor(DS.bubble.cgColor)
            context.fillPath()
        case .note:
            fill(context, rect, DS.chip, radius: rect.height / 2)
        case .pills:
            break
        case .divider:
            // Hairlines either side of the centered label (docs/design 2a checkpoint divider).
            let text = textBounds.offsetBy(dx: point.x, dy: point.y)
            context.setFillColor(DS.line.cgColor)
            context.fill(CGRect(x: rect.minX, y: text.midY, width: max(0, text.minX - 12 - rect.minX), height: 0.5))
            context.fill(CGRect(x: text.maxX + 12, y: text.midY, width: max(0, rect.maxX - text.maxX - 12), height: 0.5))
        }
        drawPills(at: point, in: context)
        context.restoreGState()
        super.draw(at: point, in: context)
    }

    /// Capsules behind runs tagged `.piopioPill` (in this paragraph's own coordinates).
    private func drawPills(at point: CGPoint, in context: CGContext) {
        guard let paragraph = (textElement as? NSTextParagraph)?.attributedString else { return }
        paragraph.enumerateAttribute(.piopioPill, in: NSRange(location: 0, length: paragraph.length)) { value, range, _ in
            guard let raw = value as? String, let style = PillStyle(rawValue: raw) else { return }
            for line in lines {
                let lr = line.characterRange
                let start = max(range.location, lr.location), end = min(NSMaxRange(range), NSMaxRange(lr))
                guard start < end else { continue }
                let x0 = line.locationForCharacter(at: start).x, x1 = line.locationForCharacter(at: end).x
                let b = line.typographicBounds
                let rect = CGRect(x: b.minX + x0 - 2, y: b.minY + 1, width: x1 - x0 + 4, height: b.height - 2).offsetBy(dx: point.x, dy: point.y)
                switch style {
                case .primary: fill(context, rect, DS.accent, radius: rect.height / 2)
                case .secondary: fill(context, rect, DS.chip, radius: rect.height / 2)
                case .file:
                    fill(context, rect, DS.card, radius: 8)
                    stroke(context, rect, DS.line, radius: 8)
                }
            }
        }
    }

    private func fill(_ c: CGContext, _ r: CGRect, _ color: NSColor, radius: CGFloat) {
        c.setFillColor(color.cgColor)
        c.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        c.fillPath()
    }

    private func stroke(_ c: CGContext, _ r: CGRect, _ color: NSColor, radius: CGFloat) {
        c.setStrokeColor(color.cgColor)
        c.setLineWidth(1)
        c.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        c.strokePath()
    }

    private func bubblePath(_ r: CGRect) -> CGPath {
        let big: CGFloat = 16, small: CGFloat = 4
        let p = CGMutablePath()
        // TextKit's drawing context is flipped: minY is the top.
        p.move(to: CGPoint(x: r.minX + big, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - big, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + big), radius: big)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - small))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - small, y: r.maxY), radius: small)
        p.addLine(to: CGPoint(x: r.minX + big, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - big), radius: big)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + big))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + big, y: r.minY), radius: big)
        p.closeSubpath()
        return p
    }
}

final class CardLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let text = paragraph.attributedString
            var style: CardStyle?
            if let raw = text.attribute(.piopioCard, at: 0, effectiveRange: nil) as? String { style = CardStyle(rawValue: raw) }
            if style == nil {
                var hasPill = false
                text.enumerateAttribute(.piopioPill, in: NSRange(location: 0, length: text.length)) { v, _, stop in
                    if v != nil { hasPill = true; stop.pointee = true }
                }
                if hasPill { style = .pills }
            }
            if let style {
                let f = CardLayoutFragment(textElement: textElement, range: range)
                f.card = style
                return f
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: range)
    }
}

// MARK: Disclosure cards (tool calls, thinking)

/// Model behind an expandable card. Built on any thread; mutated on the main thread.
@Observable
public final class DisclosureCard: @unchecked Sendable {
    /// `activity`: a turn's tool calls folded into one quiet line that opens to their cards (docs/design v2).
    public enum Kind: Sendable { case tool, thinking, activity }
    /// How the expanded body is drawn: plain text, terminal output, diff rows, or nested cards (activity).
    public enum Body: Sendable { case text(String), terminal(String), diff([DiffLine]), cards([DisclosureCard]) }
    /// Activity: done (✓), still working (spinner).
    public var working = false
    public let kind: Kind
    public var title: String
    public var detail: String
    public var trailing: String
    public var content: Body
    /// Line counts shown in green/red after the detail (edit/write).
    public var added = 0
    public var removed = 0
    public var failed = false
    /// Waiting for your approval (amber dot).
    public var waiting = false
    public var expanded = false
    /// The reader opened or closed it, so re-renders keep their choice.
    public var toggledByReader = false
    /// Diff cards show the first `previewLines` until "more lines" is clicked.
    public var showAll = false
    /// A link in the header (a subagent's "Open").
    public var action: (title: String, action: TranscriptAction)?
    @ObservationIgnored var onToggle: (@MainActor (DisclosureCard) -> Void)?
    @ObservationIgnored var onAction: (@MainActor (TranscriptAction) -> Void)?

    public init(kind: Kind, title: String, detail: String = "", trailing: String = "", body: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.trailing = trailing
        self.content = .text(body)
    }

    public init(tool title: String, detail: String, trailing: String, content: Body) {
        self.kind = .tool
        self.title = title
        self.detail = detail
        self.trailing = trailing
        self.content = content
    }

    var body: String {
        get {
            switch content {
            case .text(let s), .terminal(let s): s
            case .diff(let lines): lines.map(\.text).joined(separator: "\n")
            case .cards(let cards): cards.map(\.title).joined(separator: "\n")
            }
        }
        set { content = .text(newValue) }
    }

    var isEmpty: Bool {
        switch content {
        case .text(let s), .terminal(let s): s.isEmpty
        case .diff(let lines): lines.isEmpty
        case .cards(let cards): cards.isEmpty
        }
    }

    /// The quiet line's height (activity, thinking).
    static let lineHeight: CGFloat = 26
    static let nestedSpacing: CGFloat = 6

    static let collapsedHeight: CGFloat = 34
    static let diffRowHeight: CGFloat = 17
    static let previewLines = 12

    /// Diff rows shown now, and how many are hidden behind "more lines".
    var visibleDiff: (lines: [DiffLine], hidden: Int) {
        guard case .diff(let lines) = content else { return ([], 0) }
        if showAll || lines.count <= Self.previewLines + 2 { return (lines, 0) }
        return (Array(lines.prefix(Self.previewLines)), lines.count - Self.previewLines)
    }

    func height(width: CGFloat) -> CGFloat {
        let header = kind == .tool ? Self.collapsedHeight : Self.lineHeight
        guard expanded, !isEmpty else { return header }
        if case .cards(let cards) = content {
            return header + cards.reduce(0) { $0 + $1.height(width: width) + Self.nestedSpacing } + 2
        }
        if case .diff = content {
            let (lines, hidden) = visibleDiff
            return Self.collapsedHeight + CGFloat(lines.count) * Self.diffRowHeight + (hidden > 0 ? 24 : 0) + 10
        }
        let font: NSFont = kind == .tool ? .monospacedSystemFont(ofSize: 11.5, weight: .regular) : .systemFont(ofSize: 12.5)
        let text = NSAttributedString(string: body, attributes: [.font: font])
        let h = text.boundingRect(with: NSSize(width: max(50, width - 28), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        // Long outputs scroll inside the card.
        return header + min(ceil(h) + 20, 360)
    }
}

/// One row of a unified diff.
public struct DiffLine: Sendable, Hashable {
    public enum Kind: Sendable { case added, removed, context, hunk }
    public var kind: Kind
    public var text: String

    /// Parses a unified patch (file headers dropped). Returns the rows and the added/removed counts.
    public static func parse(_ patch: String) -> (lines: [DiffLine], added: Int, removed: Int) {
        var lines: [DiffLine] = []
        var added = 0, removed = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("\\") || line.hasPrefix("diff ") || line.hasPrefix("index ") { continue }
            if line.hasPrefix("@@") {
                lines.append(DiffLine(kind: .hunk, text: line))
            } else if line.hasPrefix("+") {
                added += 1
                lines.append(DiffLine(kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                removed += 1
                lines.append(DiffLine(kind: .removed, text: String(line.dropFirst())))
            } else if line.hasPrefix("… ") {
                lines.append(DiffLine(kind: .hunk, text: line))
            } else if !line.isEmpty || !lines.isEmpty {
                lines.append(DiffLine(kind: .context, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line))
            }
        }
        while lines.last?.kind == .context && lines.last?.text.isEmpty == true { lines.removeLast() }
        return (lines, added, removed)
    }
}

final class DisclosureAttachment: NSTextAttachment, @unchecked Sendable {
    let card: DisclosureCard

    init(card: DisclosureCard) {
        self.card = card
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = Self.blank // otherwise TextKit also draws its generic document placeholder
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static let blank = NSImage(size: NSSize(width: 1, height: 1))

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = DisclosureViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class DisclosureViewProvider: NSTextAttachmentViewProvider {
    private var card: DisclosureCard { (textAttachment as! DisclosureAttachment).card }

    override func loadView() {
        let card = self.card
        view = MainActor.assumeIsolated { NSHostingView(rootView: DisclosureCardView(card: card)) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = textContainer?.size.width ?? proposedLineFragment.width
        return CGRect(x: 0, y: -6, width: width, height: card.height(width: width))
    }
}

/// Quiet collapsible card: chevron, verb, monospace detail, duration (docs/design 2a tool cards). Activity and thinking
/// are a single 12-pt line instead (docs/design v2), the activity opening to its tool cards.
struct DisclosureCardView: View {
    let card: DisclosureCard
    /// For nested cards: what relays a toggle to the line that holds them (it changes height).
    var relay: (@MainActor () -> Void)?

    var body: some View {
        if card.kind == .tool { toolCard } else { quietLine }
    }

    private func toggle() {
        card.expanded.toggle()
        card.toggledByReader = true
        if let relay { relay() } else { card.onToggle?(card) }
    }

    private var quietLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    if card.kind == .activity {
                        if card.working {
                            ProgressView().controlSize(.mini).frame(width: 12)
                        } else if card.failed {
                            Circle().fill(Color(nsColor: DS.red)).frame(width: 6, height: 6).frame(width: 12)
                        } else if card.waiting {
                            Circle().fill(Color(nsColor: DS.amber)).frame(width: 6, height: 6).frame(width: 12)
                        } else {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(nsColor: DS.green)).frame(width: 12)
                        }
                    } else {
                        Image(systemName: "sparkle").font(.system(size: 9.5)).foregroundStyle(Color(nsColor: DS.fg3)).frame(width: 12)
                    }
                    Text(card.title).font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3)).lineLimit(1).truncationMode(.tail)
                    if !card.detail.isEmpty { Text("· \(card.detail)").font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3)).lineLimit(1) }
                    Image(systemName: card.expanded ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Color(nsColor: DS.fg3))
                    Spacer(minLength: 0)
                }
                .frame(height: DisclosureCard.lineHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if card.expanded {
                switch card.content {
                case .cards(let cards):
                    VStack(alignment: .leading, spacing: DisclosureCard.nestedSpacing) {
                        ForEach(Array(cards.enumerated()), id: \.offset) { _, child in
                            DisclosureCardView(card: child, relay: { [card] in card.onToggle?(card) })
                                .frame(height: child.height(width: 600))
                                .onAppear { child.onAction = card.onAction }
                        }
                    }
                case .text(let text), .terminal(let text):
                    ScrollView {
                        Text(text).font(.system(size: 12.5)).foregroundStyle(Color(nsColor: DS.fg2)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 18).padding(.vertical, 6)
                    }
                case .diff: EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var toolCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: card.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(nsColor: DS.fg3))
                        .frame(width: 10)
                    if card.failed { Circle().fill(Color(nsColor: DS.red)).frame(width: 6, height: 6) }
                    if card.waiting { Circle().fill(Color(nsColor: DS.amber)).frame(width: 6, height: 6) }
                    Text(card.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(nsColor: DS.fg))
                    if !card.detail.isEmpty {
                        Text(card.detail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(nsColor: DS.fg3))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if card.added > 0 { Text("+\(card.added)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color(nsColor: DS.green)).monospacedDigit() }
                    if card.removed > 0 { Text("−\(card.removed)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color(nsColor: DS.red)).monospacedDigit() }
                    if !card.trailing.isEmpty {
                        Text(card.trailing).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: card.failed ? DS.red : card.waiting ? DS.amber : DS.fg3)).monospacedDigit()
                    }
                    if let action = card.action {
                        Button(action.title) { card.onAction?(action.action) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: DisclosureCard.collapsedHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if card.expanded && !card.isEmpty {
                Rectangle().fill(Color(nsColor: DS.line)).frame(height: 0.5)
                switch card.content {
                case .diff: diff
                case .terminal(let text): scrolling(text, terminal: true)
                case .text(let text): scrolling(text, terminal: false)
                case .cards: EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: DS.card), in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color(nsColor: DS.line), lineWidth: 0.5))
    }

    private func scrolling(_ text: String, terminal: Bool) -> some View {
        ScrollView {
            Text(text)
                .font(card.kind == .tool ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(Color(nsColor: DS.fg2))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background(terminal ? Color(nsColor: DS.chip) : .clear)
    }

    private var diff: some View {
        let (lines, hidden) = card.visibleDiff
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 0) {
                    Text(marker(line.kind)).frame(width: 18, alignment: .center).foregroundStyle(Color(nsColor: DS.fg3))
                    Text(line.text.isEmpty ? " " : line.text).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(Color(nsColor: line.kind == .hunk ? DS.fg3 : DS.fg))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .frame(height: DisclosureCard.diffRowHeight)
                .background(background(line.kind))
            }
            if hidden > 0 {
                Button {
                    card.showAll = true
                    if let relay { relay() } else { card.onToggle?(card) }
                } label: {
                    Text("… \(hidden) more lines").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color(nsColor: DS.fg3))
                        .padding(.leading, 18).frame(height: 24).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .textSelection(.enabled)
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Color(nsColor: DS.addbg)
        case .removed: Color(nsColor: DS.delbg)
        default: .clear
        }
    }
}
