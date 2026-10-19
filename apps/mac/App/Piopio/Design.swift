import PiopioTranscript
import SwiftUI

// SwiftUI side of the design system (docs/design/README.md · 8e Components & tokens).

extension Color {
    static let dsWin = Color(nsColor: DS.win)
    static let dsCard = Color(nsColor: DS.card)
    static let dsChip = Color(nsColor: DS.chip)
    static let dsBubble = Color(nsColor: DS.bubble)
    static let dsPill = Color(nsColor: DS.pill)
    static let dsGlassEdge = Color(nsColor: DS.glassEdge)
    static let dsFg = Color(nsColor: DS.fg)
    static let dsFg2 = Color(nsColor: DS.fg2)
    static let dsFg3 = Color(nsColor: DS.fg3)
    static let dsLine = Color(nsColor: DS.line)
    static let dsInv = Color(nsColor: DS.inv)
    static let dsInvFg = Color(nsColor: DS.invfg)
    static let dsGreen = Color(nsColor: DS.green)
    static let dsAmber = Color(nsColor: DS.amber)
    static let dsRed = Color(nsColor: DS.red)
    static let dsAccentSoft = Color(nsColor: DS.accentSoft)
    static let dsAccentLine = Color(nsColor: DS.accentLine)
}

/// Floating glass panel: sidebar, inspector, composer, popovers (radius 14, hairline edge, soft shadow).
struct GlassPanel: ViewModifier {
    var radius: CGFloat = DS.Radius.panel
    var material: Material = .regularMaterial

    func body(content: Content) -> some View {
        content
            .background(material, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.dsGlassEdge, lineWidth: 0.5))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5).padding(-0.5))
            .shadow(color: .black.opacity(0.08), radius: 15, y: 8)
    }
}

extension View {
    func glassPanel(radius: CGFloat = DS.Radius.panel, material: Material = .regularMaterial) -> some View {
        modifier(GlassPanel(radius: radius, material: material))
    }
}

/// Capsule buttons: toolbar pill (white, hairline), secondary chip, primary (accent), strong (inv).
struct PillStyle: ButtonStyle {
    enum Kind { case toolbar, secondary, primary, strong }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 24 : 28)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(kind == .toolbar ? Color.dsLine : .clear, lineWidth: 0.5))
            .shadow(color: kind == .toolbar ? .black.opacity(0.05) : .clear, radius: 2, y: 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .strong: .dsInvFg
        default: .dsFg
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .toolbar: AnyShapeStyle(Color.dsPill)
        case .secondary: AnyShapeStyle(Color.dsChip)
        case .primary: AnyShapeStyle(Color.accentColor)
        case .strong: AnyShapeStyle(Color.dsInv)
        }
    }
}

/// 11pt semibold tertiary label, sentence case (section headings).
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
    }
}

/// Status vocabulary: amber = waiting on you, accent ring = running, green = live/done, grey = idle, red = failed.
struct StatusDot: View {
    enum Status { case waiting, running, done, idle, failed }
    let status: Status
    var size: CGFloat = 7

    var body: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini).frame(width: size + 3, height: size + 3)
        default:
            Circle().fill(color).frame(width: size, height: size)
        }
    }

    private var color: Color {
        switch status {
        case .waiting: .dsAmber
        case .done: .dsGreen
        case .failed: .dsRed
        case .idle, .running: .dsFg3.opacity(0.5)
        }
    }
}

/// Build · Chat · Agents capsule segmented control.
struct ModeSwitcher: View {
    @Binding var mode: AppMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppMode.allCases) { m in
                Button { mode = m } label: {
                    Text(m.title)
                        .font(.system(size: 13, weight: mode == m ? .semibold : .regular))
                        .foregroundStyle(mode == m ? Color.dsFg : Color.dsFg2)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background {
                            if mode == m { Capsule().fill(Color.dsPill).shadow(color: .black.opacity(0.08), radius: 2, y: 1) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(m.shortcut, modifiers: .command)
                .help("\(m.title) (⌘\(m.index + 1))")
            }
        }
        .padding(3)
        .background(Color.dsChip, in: Capsule())
    }
}

enum AppMode: String, CaseIterable, Identifiable {
    case build, chat, agents
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var index: Int { AppMode.allCases.firstIndex(of: self)! }
    var shortcut: KeyEquivalent { KeyEquivalent(Character("\(index + 1)")) }
}

/// The 5c empty-state pattern: small label, one-line title, one sentence, one or two ways to start.
struct EmptyState<Actions: View>: View {
    let label: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(Color.dsFg3)
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Color.dsFg)
            Text(message).font(.system(size: 13)).foregroundStyle(Color.dsFg2).multilineTextAlignment(.center).frame(maxWidth: 360)
            actions.padding(.top, 12)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A card tile used in empty states and settings (card + hairline, radius 12).
struct CardTile<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }
}
