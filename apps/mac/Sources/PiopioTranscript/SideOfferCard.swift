import AppKit
import PiopioKit
import SwiftUI

// Piopio's offer of a side conversation (docs/spec/24 §1, docs/design/side-conversations option 1a): what it noticed,
// the task's title and its brief in two lines, and a footer with the choices: Do it here as text, New conversation as
// the black button. Once New conversation started it, a compact row in its place: the side's title, where it stands
// and Open. Built from the grey tokens, as the plan card is: field fill, 0.5pt hairline, radius 12.

/// What one offer card shows, and somewhere to send its choices (the document wires it, as it does file cards).
public final class SideOfferModel: @unchecked Sendable {
    enum Content {
        /// Waiting for your choice.
        case offer(callId: String, title: String, brief: String, project: String?)
        /// Started: the side's row.
        case side(SideInfo)
    }

    let content: Content
    var onAction: (@MainActor (TranscriptAction) -> Void)?

    init(_ content: Content) { self.content = content }

    // Layout, shared by the view and the height the text view reserves for it.
    static let padding: CGFloat = 16
    static let top: CGFloat = 14
    static let eyebrow: CGFloat = 18
    static let footerHeight: CGFloat = 46
    static let rowHeight: CGFloat = 52
    nonisolated(unsafe) static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    nonisolated(unsafe) static let briefFont = NSFont.systemFont(ofSize: 13)
    static let briefSpacing: CGFloat = 2

    func height(width: CGFloat) -> CGFloat {
        guard case .offer(_, let title, let brief, _) = content else { return Self.rowHeight }
        let inner = max(120, width - Self.padding * 2)
        var total = Self.top + Self.eyebrow + 8 + Self.measure(title, Self.titleFont, inner, spacing: 0)
        if !brief.isEmpty { total += 4 + Self.measure(brief, Self.briefFont, inner, spacing: Self.briefSpacing) }
        return ceil(total + 14 + 0.5 + Self.footerHeight)
    }

    /// The text's height at this width, two lines at most (the view clamps it the same way).
    private static func measure(_ text: String, _ font: NSFont, _ width: CGFloat, spacing: CGFloat) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = spacing
        func h(_ s: String) -> CGFloat {
            ceil(NSAttributedString(string: s, attributes: [.font: font, .paragraphStyle: p])
                .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        return min(h(text), h("A\nA"))
    }

    /// "running tests", "needs you", "merged"… as the side's grey line says it.
    static func state(_ s: SideInfo) -> String {
        switch s.state {
        case "queued": "queued"
        case "working": s.line.map { $0.isEmpty ? "working" : $0 } ?? "working"
        case "needs_you": "needs you"
        case "done": s.finished ?? "done"
        case "failed": "failed"
        default: "stopped"
        }
    }
}

final class SideOfferAttachment: NSTextAttachment, @unchecked Sendable {
    let model: SideOfferModel

    init(model: SideOfferModel) {
        self.model = model
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = SideOfferViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class SideOfferViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let model = (textAttachment as! SideOfferAttachment).model
        view = MainActor.assumeIsolated { ArrowHostingView(rootView: SideOfferView(model: model)) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let model = (textAttachment as! SideOfferAttachment).model
        let width = textContainer?.size.width ?? proposedLineFragment.width
        return CGRect(x: 0, y: -6, width: width, height: model.height(width: width))
    }
}

struct SideOfferView: View {
    let model: SideOfferModel

    var body: some View {
        switch model.content {
        case .offer(let callId, let title, let brief, let project): offer(callId, title, brief, project)
        case .side(let s): row(s)
        }
    }

    // MARK: The offer

    private func offer(_ callId: String, _ title: String, _ brief: String, _ project: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    chip(size: SideOfferModel.eyebrow, radius: DS.Radius.badge, glyph: 10)
                    Text(["This looks like its own task", project.map { "in \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color(nsColor: DS.fg3)).lineLimit(1)
                }
                .frame(height: SideOfferModel.eyebrow)
                .padding(.bottom, 8)
                Text(title).font(Font(SideOfferModel.titleFont)).foregroundStyle(Color(nsColor: DS.fg))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !brief.isEmpty {
                    Text(brief).font(Font(SideOfferModel.briefFont)).foregroundStyle(Color(nsColor: DS.fg2))
                        .lineSpacing(SideOfferModel.briefSpacing).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .help(brief)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SideOfferModel.padding)
            .padding(.top, SideOfferModel.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(Color(nsColor: DS.line)).frame(height: 0.5)
            HStack(spacing: 6) {
                Text("Takes the brief with it").font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3)).lineLimit(1)
                Spacer(minLength: 8)
                TextButton(title: "Do it here", help: "Keep it in this conversation") { act(.offer(kind: "side-here", callId: callId)) }
                DarkButton(title: "New conversation", symbol: "arrow.up.right", help: "Start it as its own conversation; you stay here") {
                    act(.offer(kind: "side-new", callId: callId))
                }
            }
            .padding(.leading, SideOfferModel.padding).padding(.trailing, 12)
            .frame(height: SideOfferModel.footerHeight)
            .background(Color(nsColor: DS.win))
        }
        .background(Color(nsColor: DS.card))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color(nsColor: DS.line), lineWidth: 0.5))
    }

    // MARK: Started

    private func row(_ s: SideInfo) -> some View {
        HStack(spacing: 12) {
            Button { act(.offer(kind: SideActionKind.open, callId: s.id)) } label: {
                HStack(spacing: 12) {
                    chip(size: 28, radius: DS.Radius.button, glyph: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color(nsColor: DS.fg)).lineLimit(1)
                        HStack(spacing: 6) {
                            if s.state == "needs_you" { Circle().fill(Color(nsColor: DS.accent)).frame(width: 6, height: 6) }
                            Text("Side conversation · \(SideOfferModel.state(s))").font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open it")
            if s.unmerged {
                TextButton(title: "Discard", help: "Discard its branch") { act(.offer(kind: SideActionKind.discard, callId: s.id)) }
                TextButton(title: "Merge", strong: true, help: "Merge its branch") { act(.offer(kind: SideActionKind.merge, callId: s.id)) }
            }
            QuietButton(title: "Open", symbol: "arrow.up.right", help: "Open the side conversation") { act(.offer(kind: SideActionKind.open, callId: s.id)) }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: DS.card), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color(nsColor: DS.line), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side conversation \(s.title), \(SideOfferModel.state(s))")
    }

    // MARK: Parts

    /// The side-conversation glyph on a quiet chip (grey: blue is only for links and the needs-you dot).
    private func chip(size: CGFloat, radius: CGFloat, glyph: CGFloat) -> some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: glyph, weight: .medium))
            .foregroundStyle(Color(nsColor: DS.fg2))
            .frame(width: size, height: size)
            .background(Color(nsColor: DS.chip), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private func act(_ action: TranscriptAction) {
        MainActor.assumeIsolated { model.onAction?(action) }
    }
}

/// A choice as text (the cards' secondary answers), with a quiet fill on hover.
struct TextButton: View {
    let title: String
    var strong = false
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color(nsColor: strong ? DS.fg : DS.fg2))
                .padding(.horizontal, 10).frame(height: 26)
                .background(hovering ? Color(nsColor: DS.chip) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.selector, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

/// The view's one black action (docs/design/grey), as the transcript's other cards draw it.
struct DarkButton: View {
    let title: String
    var symbol: String?
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            }
            .foregroundStyle(Color(nsColor: DS.invfg))
            .padding(.horizontal, 11).frame(height: 26)
            .background(Color(nsColor: DS.inv).opacity(hovering ? 0.85 : 1), in: RoundedRectangle(cornerRadius: DS.Radius.selector, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

/// A small chip-filled button (a row's Open).
struct QuietButton: View {
    let title: String
    var symbol: String?
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            }
            .foregroundStyle(Color(nsColor: DS.fg))
            .padding(.horizontal, 10).frame(height: 26)
            .background(Color(nsColor: hovering ? DS.bubble : DS.chip), in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}
