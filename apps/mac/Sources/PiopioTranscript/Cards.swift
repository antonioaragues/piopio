import AppKit
import Observation
import SwiftUI

// Card chrome for the TextKit 2 transcript (docs/spikes/s2):
// - Static cards (code, quote, table, user bubble) are single paragraphs, lines joined with U+2028,
//   tagged `.piopioCard`; `CardLayoutFragment` draws their background behind the text.
// - Interactive cards (tool calls, thinking) are attachments whose view expands in place.

extension NSAttributedString.Key {
    public static let piopioCard = NSAttributedString.Key("piopio.card")
}

public enum CardStyle: String, Sendable { case code, quote, table, user, error }

let lineSeparator = "\u{2028}"

/// Draws a card background behind paragraphs tagged with `.piopioCard`.
final class CardLayoutFragment: NSTextLayoutFragment {
    static let padding: CGFloat = 10
    static let userIndent: CGFloat = 120
    var card: CardStyle = .code

    /// Background rect in fragment coordinates. Fragment frames start at the paragraph indent and only span
    /// the used width, so the card is measured against the text container instead.
    private var cardRect: CGRect {
        // Skip the empty "extra line" TextKit appends after the document's final paragraph break.
        let lines = textLineFragments.filter { $0.characterRange.length > 0 }
        guard let first = lines.first else { return .zero }
        var text = first.typographicBounds
        for l in lines.dropFirst() { text = text.union(l.typographicBounds) }
        let p = Self.padding
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let originX = layoutFragmentFrame.minX
        let leftInContainer: CGFloat = card == .user ? Self.userIndent - p : 4
        return CGRect(x: leftInContainer - originX, y: text.minY - p, width: containerWidth - 4 - leftInContainer, height: text.height + 2 * p)
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(cardRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = cardRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        switch card {
        case .quote:
            context.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height))
        case .code, .table, .user, .error:
            let color: NSColor = switch card {
            case .user: .controlAccentColor.withAlphaComponent(0.12)
            case .error: .systemRed.withAlphaComponent(0.10)
            default: .quaternaryLabelColor.withAlphaComponent(0.18)
            }
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

// MARK: Disclosure cards (tool calls, thinking)

/// Model behind an expandable card. Built on any thread; mutated on the main thread.
@Observable
public final class DisclosureCard: @unchecked Sendable {
    public enum Kind: Sendable { case tool, thinking }
    public let kind: Kind
    public var title: String
    public var detail: String
    public var body: String
    public var expanded = false
    @ObservationIgnored var onToggle: (@MainActor (DisclosureCard) -> Void)?

    public init(kind: Kind, title: String, detail: String = "", body: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.body = body
    }

    static let collapsedHeight: CGFloat = 28

    func height(width: CGFloat) -> CGFloat {
        guard expanded, !body.isEmpty else { return Self.collapsedHeight }
        let font: NSFont = kind == .tool ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
        let text = NSAttributedString(string: body, attributes: [.font: font])
        let h = text.boundingRect(with: NSSize(width: max(50, width - 24), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return Self.collapsedHeight + ceil(h) + 12
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
        let width = proposedLineFragment.width - 8
        return CGRect(x: 0, y: 0, width: width, height: card.height(width: width))
    }
}

struct DisclosureCardView: View {
    let card: DisclosureCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                card.expanded.toggle()
                card.onToggle?(card)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: card.expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    Image(systemName: card.kind == .tool ? "gearshape" : "brain")
                    Text(card.title).fontWeight(.medium)
                    if !card.detail.isEmpty { Text(card.detail).foregroundStyle(.tertiary) }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: DisclosureCard.collapsedHeight - 4, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if card.expanded {
                Text(card.body)
                    .font(card.kind == .tool ? .system(size: 11, design: .monospaced) : .system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
