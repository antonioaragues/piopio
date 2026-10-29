import PiopioTranscript
import SwiftUI

// SwiftUI side of the design system (docs/design/grey: grey ink, one black action per view, hairlines, no decoration).

extension Color {
    static let dsWin = Color(nsColor: DS.win)
    static let dsSide = Color(nsColor: DS.side)
    static let dsTrack = Color(nsColor: DS.track)
    static let dsSeg = Color(nsColor: DS.seg)
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
    static let dsYolk = Color(nsColor: DS.yolk)
    static let dsYolkSoft = Color(nsColor: DS.yolkSoft)
}

/// The app icon's chick, cropped round (docs/design v2 · brand moments), with an optional yolkSoft ring.
struct Chick: View {
    var size: CGFloat = 52
    var ring: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let image = NSImage(named: scheme == .dark ? "ChickDark" : "Chick") ?? NSApp.applicationIconImage ?? NSImage()
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .background(Circle().fill(Color.dsYolkSoft).padding(-ring))
    }
}

/// A project's or notebook's mark in lists: a 16pt outline glyph in fg2 (no colored tiles in the grey design).
struct InitialTile: View {
    let name: String
    var size: CGFloat = 18
    var symbol = "folder"

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.78))
            .foregroundStyle(Color.dsFg2)
            .frame(width: size, height: size)
    }

    /// Letter tiles in Settings are grey too.
    static func color(for name: String) -> Color { .dsFg3 }
}

/// A floating surface (menus, the search box, suggestion lists): field fill, a hairline, a soft shadow, radius 12.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = DS.Radius.panel
    var material: Material = .regularMaterial

    func body(content: Content) -> some View {
        content
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
    }
}

/// A side panel flush to the window edge (inspectors, info panels, Settings' list): no float, a 0.5pt hairline on
/// the side that faces the content.
struct SidePanel: ViewModifier {
    var edge: HorizontalEdge = .leading
    var background: Color = .dsWin

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: .infinity, alignment: .top)
            .background(background)
            .overlay(alignment: edge == .leading ? .leading : .trailing) { Rectangle().fill(Color.dsLine).frame(width: 0.5) }
    }
}

extension View {
    func sidePanel(_ edge: HorizontalEdge = .leading, background: Color = .dsWin) -> some View {
        modifier(SidePanel(edge: edge, background: background))
    }

    func glassPanel(radius: CGFloat = DS.Radius.panel, material: Material = .regularMaterial) -> some View {
        modifier(GlassPanel(radius: radius, material: material))
    }
}

/// Buttons (docs/design/grey): one black action per view (`.primary` / `.strong`: inv, radius 8); everything else is
/// plain text in fg2 (`.secondary`) or a ghost button that gets a grey fill on hover (`.toolbar`, radius 6).
struct PillStyle: ButtonStyle {
    enum Kind { case toolbar, secondary, primary, strong }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12.5 : 13, weight: solid ? .medium : .regular))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, solid ? (compact ? 11 : 13) : (kind == .toolbar ? 7 : 4))
            .frame(height: solid ? (compact ? 26 : 28) : (compact ? 24 : 28))
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: solid ? DS.Radius.button : DS.Radius.selector, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var solid: Bool { kind == .primary || kind == .strong }

    private var foreground: Color {
        switch kind {
        case .primary, .strong: .dsInvFg
        case .toolbar: hovering ? .dsFg : .dsFg2
        case .secondary: hovering ? .dsFg : .dsFg2
        }
    }

    private var background: Color {
        switch kind {
        case .primary, .strong: .dsInv
        case .toolbar: hovering && isEnabled ? .dsChip : .clear
        case .secondary: .clear
        }
    }
}

/// A plain-text selector (docs/design/grey principle 6): no chevron; a grey fill on hover, radius 6, 3×6 padding.
struct SelectorStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View { SelectorBody(configuration: configuration, active: active) }
}

private struct SelectorBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @State private var hovering = false
    var body: some View {
        configuration.label
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(hovering || active || configuration.isPressed ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.selector, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A 28pt icon-only ghost button for toolbars (radius 6, grey fill on hover or while on).
struct IconButtonStyle: ButtonStyle {
    var on = false
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View { IconButtonBody(configuration: configuration, on: on, size: size) }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let on: Bool
    let size: CGFloat
    @State private var hovering = false
    var body: some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(on || hovering ? Color.dsFg : Color.dsFg2)
            .frame(width: size, height: size)
            .background(on || hovering || configuration.isPressed ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.selector, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// 12pt tertiary label, sentence case (section headings).
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
    }
}

/// Status (docs/design/grey): a 6pt blue dot = waiting on you, a 10pt grey ring = running; nothing else gets a color.
struct StatusDot: View {
    enum Status { case waiting, running, done, idle, failed }
    let status: Status
    var size: CGFloat = 7

    var body: some View {
        switch status {
        case .running:
            RunningRing(size: size + 3)
        case .waiting:
            Circle().fill(Color.accentColor).frame(width: min(size, 6), height: min(size, 6))
        case .failed:
            Circle().strokeBorder(Color.dsFg3, lineWidth: 1).frame(width: size, height: size)
        case .done, .idle:
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// The running mark: a 10pt grey ring with a turning gap.
struct RunningRing: View {
    var size: CGFloat = 10
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(Color.dsFg3, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: size - 1.4, height: size - 1.4)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .frame(width: size, height: size)
            .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turning = true } }
            .accessibilityLabel("Running")
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
            Text(label).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Color.dsFg)
            Text(message).font(.system(size: 13)).foregroundStyle(Color.dsFg2).multilineTextAlignment(.center).frame(maxWidth: 360)
            actions.padding(.top, 12)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A hairline box (radius 12) for the few things that need one.
struct CardTile<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }
}
