import AppKit
import PiopioKit
import SwiftUI

// The moment an automation is born in a conversation (docs/spec/27 §4, the agents and automations handoff, screen 2):
// a card with its name, When · Runs as · Does · Tells you, where it runs and its first run, Open in Automations and
// Undo. Undone (or removed in Automations), it becomes one line with Redo.

public final class AutomationCardModel: @unchecked Sendable {
    public enum State: Sendable { case live, undone, removed }
    let summary: AutomationSummary
    let changed: Bool
    let state: State
    /// The card's own undo record (an agent's), else Undo removes it.
    let undoId: String?
    var onAction: (@MainActor (TranscriptAction) -> Void)?

    init(summary: AutomationSummary, changed: Bool, state: State, undoId: String?) {
        self.summary = summary
        self.changed = changed
        self.state = state
        self.undoId = undoId
    }

    static let width: CGFloat = 440
    private var cachedHeight: (width: CGFloat, height: CGFloat)?

    /// Measured once per width: the rows wrap (a long "Does").
    @MainActor func height(for width: CGFloat) -> CGFloat {
        if let c = cachedHeight, c.width == width { return c.height }
        let host = NSHostingController(rootView: AutomationCardView(model: self))
        let h = ceil(host.sizeThatFits(in: CGSize(width: width, height: 2000)).height)
        cachedHeight = (width, h)
        return h
    }

    /// "Mon 23 Nov".
    var firstRun: String? {
        summary.next.map { Date(timeIntervalSince1970: $0 / 1000).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
    }
}

final class AutomationCardAttachment: NSTextAttachment, @unchecked Sendable {
    let model: AutomationCardModel

    init(model: AutomationCardModel) {
        self.model = model
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = AutomationCardViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class AutomationCardViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let model = (textAttachment as! AutomationCardAttachment).model
        view = MainActor.assumeIsolated { ArrowHostingView(rootView: AutomationCardView(model: model)) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let model = (textAttachment as! AutomationCardAttachment).model
        let width = min(model.state == .live ? AutomationCardModel.width : 560, textContainer?.size.width ?? proposedLineFragment.width)
        let height = MainActor.assumeIsolated { model.height(for: width) }
        return CGRect(x: 0, y: -4, width: width, height: height)
    }
}

struct AutomationCardView: View {
    let model: AutomationCardModel
    private var s: AutomationSummary { model.summary }

    var body: some View {
        switch model.state {
        case .live: card
        case .undone, .removed: gone
        }
    }

    private func color(_ c: NSColor) -> Color { Color(nsColor: c) }

    /// "Undone. Weekly competitor brief won't run. Redo".
    private var gone: some View {
        HStack(spacing: 0) {
            (Text(model.state == .undone ? "Undone. " : "Removed. ") + Text("\(s.name) won't run.").foregroundColor(color(DS.fg2)))
                .font(.system(size: 12.5)).foregroundStyle(color(DS.fg)).lineLimit(1)
            Text(" ")
            Button("Redo") { act(.restoreAutomation(id: s.id)) }
                .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(color(DS.accent))
                .help("Bring it back as it was")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(color(DS.bubble), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.changed ? "Changed automation" : "New automation").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(color(DS.accent))
                Text(s.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(color(DS.fg)).lineLimit(2)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(color(DS.line)).frame(height: 0.5) }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                line("When", s.when)
                line("Runs as", s.runsAs)
                if !s.does.isEmpty { line("Does", s.does) }
                line("Tells you", s.tellsYou)
                if let url = s.url { line("Its address", url, mono: true) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            HStack(spacing: 7) {
                Circle().fill(Color(nsColor: NSColor(srgbRed: 0.36, green: 0.73, blue: 0.45, alpha: 1))).frame(width: 6, height: 6)
                Text([s.runsOn.isEmpty ? "Runs on this Mac, only while it's awake" : "Runs on \(Self.lowerFirst(s.runsOn))", model.firstRun.map { "first run \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(color(DS.fg2)).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color(Self.strip))
            HStack(spacing: 8) {
                Button { act(.openAutomation(id: s.id)) } label: {
                    Text("Open in Automations").font(.system(size: 12.5, weight: .medium)).foregroundStyle(color(DS.invfg))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(color(DS.inv), in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !model.changed {
                    Button { act(.undoAutomation(id: s.id, undoId: model.undoId)) } label: {
                        Text("Undo").font(.system(size: 12.5, weight: .medium)).foregroundStyle(color(DS.fg))
                            .padding(.horizontal, 12).frame(height: 28)
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous).strokeBorder(color(DS.fg).opacity(0.14)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("It won't run; you can bring it back")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(color(DS.line)).frame(height: 0.5) }
        }
        .background(color(DS.card), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        .padding(.bottom, 1)
    }

    @ViewBuilder private func line(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).font(.system(size: 13)).foregroundStyle(color(DS.fg3)).frame(width: 84, alignment: .leading)
            Text(value).font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 13)).foregroundStyle(color(DS.fg))
                .lineLimit(mono ? 1 : 3).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func act(_ action: TranscriptAction) {
        MainActor.assumeIsolated { model.onAction?(action) }
    }

    static func lowerFirst(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).lowercased() + s.dropFirst() }

    /// #F7F7F5 · #222221: the card's footer strip.
    static let strip = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.133, green: 0.133, blue: 0.129, alpha: 1) : NSColor(srgbRed: 0.969, green: 0.969, blue: 0.961, alpha: 1)
    }
}
