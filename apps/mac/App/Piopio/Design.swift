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
    static let dsPill = Color(nsColor: DS.pill)
    static let dsFg = Color(nsColor: DS.fg)
    static let dsFg2 = Color(nsColor: DS.fg2)
    static let dsFg3 = Color(nsColor: DS.fg3)
    static let dsLine = Color(nsColor: DS.line)
    static let dsInv = Color(nsColor: DS.inv)
    static let dsInvFg = Color(nsColor: DS.invfg)
    static let dsGreen = Color(nsColor: DS.green)
    /// Warnings read in ink, not amber (docs/design/grey principle 3).
    static let dsAmber = Color(nsColor: DS.fg2)
    static let dsRed = Color(nsColor: DS.red)
    /// Changed or not saved yet (the Inspector's timeline and Files' "M").
    static let dsWarn = Color(nsColor: DS.amber)
    /// Read by the agent (Files' "R").
    static let dsRead = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.48, green: 0.65, blue: 0.90, alpha: 1) : NSColor(srgbRed: 0.25, green: 0.44, blue: 0.72, alpha: 1)
    })
    static let dsAccentSoft = Color(nsColor: DS.accentSoft)
    static let dsAccentLine = Color(nsColor: DS.accentLine)
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

/// A project's mark in lists: a 16pt outline glyph in fg2 (no colored tiles in the grey design).
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
    /// A group of Settings rows (docs/design/grey 10e): hairlines above and below instead of a box; rows line up with the
    /// page's title.
    func settingsRows() -> some View {
        self
            .padding(.horizontal, -14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }

    func sidePanel(_ edge: HorizontalEdge = .leading, background: Color = .dsWin) -> some View {
        modifier(SidePanel(edge: edge, background: background))
    }

    func glassPanel(radius: CGFloat = DS.Radius.panel, material: Material = .regularMaterial) -> some View {
        modifier(GlassPanel(radius: radius, material: material))
    }
}

/// Buttons (docs/design/grey): one black action per view (`.primary` / `.strong`: inv, radius 8); everything else is
/// plain text in fg2 (`.secondary`) or a ghost button that gets a grey fill on hover (`.toolbar`, radius 6).
/// "Jump to latest" over the thread: an opaque pill with a hairline and a soft shadow, so it reads over the text
/// scrolling under it.
struct JumpToLatestButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label("Jump to latest", systemImage: "arrow.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Color.dsFg : Color.dsFg2)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color.dsPill, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: DS.glassEdge), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Scroll to the newest message")
    }
}

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

/// A toolbar view icon (docs/design/session-panel): it shows or hides a view, and is lit while that view shows.
/// Build sessions, chats and agents all put their views first, then a divider and ···.
struct ToolbarIcon: View {
    let symbol: String
    let label: String
    var on = false
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(IconButtonStyle(on: on))
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? .isSelected : [])
            .help(help ?? label)
    }
}

/// The hairline between a toolbar's views and its actions.
struct ToolbarDivider: View {
    var body: some View { Rectangle().fill(Color.dsLine).frame(width: 0.5, height: 18).padding(.horizontal, 4).accessibilityHidden(true) }
}

/// The neutral segmented control (docs/design/grey): a `track` fill, the selected segment on `seg` with a hairline.
struct NeutralSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Text(option.title).font(.system(size: 12, weight: selection == option.value ? .medium : .regular))
                        .foregroundStyle(selection == option.value ? Color.dsFg : Color.dsFg2)
                        .frame(maxWidth: .infinity).frame(height: 22)
                        .background(selection == option.value ? Color.dsSeg : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selection == option.value ? Color.dsLine : .clear, lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.dsTrack, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

/// Home's status tiles (docs/design/home): a tinted 28pt tile with an 8pt dot. Orange asks first, red failed, green is
/// ready; everything else follows the system accent. Tints are the dot at low strength in dark mode.
enum StatusTone {
    case approval, failed, ready, other

    var dot: Color {
        switch self {
        case .approval: Color(nsColor: Self.dynamic(0xE87F25, 0xF0954A))
        case .failed: Color(nsColor: Self.dynamic(0xDA534F, 0xEF7D72))
        case .ready: Color(nsColor: Self.dynamic(0x4FA866, 0x6CC28A))
        case .other: .accentColor
        }
    }

    var tint: Color {
        switch self {
        case .approval: Color(nsColor: Self.dynamic(0xFFE8D6, 0xF0954A, darkAlpha: 0.18))
        case .failed: Color(nsColor: Self.dynamic(0xFFE7E4, 0xEF7D72, darkAlpha: 0.18))
        case .ready: Color(nsColor: Self.dynamic(0xDCF7E1, 0x6CC28A, darkAlpha: 0.18))
        case .other: Color(nsColor: NSColor(name: nil) { a in NSColor.controlAccentColor.withAlphaComponent(a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.22 : 0.12) })
        }
    }

    /// The "Waiting on you" count: white on orange.
    static let badge = Color(nsColor: dynamic(0xEE8A3C, 0xEE8A3C))

    private static func dynamic(_ light: UInt32, _ dark: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
        func rgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark, darkAlpha) : rgb(light, 1) }
    }
}
