import PiopioTranscript
import SwiftUI

/// Something the composer needs you to know before you send (docs/design/grey "Composer notice"): what happened,
/// what's safe, and at most two actions. One at a time, glued to the top of the box like the tray, and never red:
/// a warning has an amber icon, information a grey one.
struct ComposerNotice: Identifiable {
    enum Tone { case warning, info }
    struct Action {
        let title: String
        let run: () -> Void
    }

    let id: String
    var tone: Tone = .warning
    let symbol: String
    let title: String
    /// What's safe or what happens next, after the title in grey ("your message is kept").
    var detail: String?
    var primary: Action?
    var secondary: Action?
    /// Shown as ✕; nil when the notice goes away by itself.
    var dismiss: (() -> Void)?
}

struct ComposerNoticeStrip<Accessory: View>: View {
    let notice: ComposerNotice
    /// Next to the secondary action (Composer anchors the context popover here).
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(notice.tone == .warning ? Color.dsWarn : Color.dsFg3)
                .frame(width: 16)
                .accessibilityHidden(true)
            (Text(notice.title).foregroundStyle(Color.dsFg)
                + Text(notice.detail.map { " · \($0)" } ?? "").foregroundStyle(Color.dsFg3))
                .font(.system(size: 13))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let primary = notice.primary {
                Button(primary.title, action: primary.run).buttonStyle(PillStyle(kind: .primary, compact: true)).fixedSize()
            }
            if let secondary = notice.secondary {
                Button(secondary.title, action: secondary.run).buttonStyle(PillStyle(compact: true)).fixedSize()
            }
            accessory()
            if let dismiss = notice.dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dsFg3)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
        .background(Color.dsWin, in: UnevenRoundedRectangle(topLeadingRadius: DS.Radius.composer, topTrailingRadius: DS.Radius.composer, style: .continuous))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.title)
        .transition(.opacity)
    }
}

extension ComposerNoticeStrip where Accessory == EmptyView {
    init(notice: ComposerNotice) { self.init(notice: notice) { EmptyView() } }
}
