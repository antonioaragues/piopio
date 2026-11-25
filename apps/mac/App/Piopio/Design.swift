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
    /// Fields on the window (outside the content card).
    static let dsField = Color(nsColor: DS.field)
    static let dsCardField = Color(nsColor: DS.cardField)
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
    /// Temporary chats (docs/spec/14 M4): a muted ochre for its dashed bubble, the corner button and the strip, never for anything else.
    static let dsTemporary = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.85, green: 0.77, blue: 0.54, alpha: 1) : NSColor(srgbRed: 0.48, green: 0.42, blue: 0.23, alpha: 1)
    })
    static let dsTemporaryTint = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.85, green: 0.77, blue: 0.54, alpha: 0.12) : NSColor(srgbRed: 0.965, green: 0.937, blue: 0.851, alpha: 1)
    })
}

/// A temporary chat's mark (docs/spec/14 M4): the conversation bubble (SF Symbols' `bubble.left`) drawn dashed, as SF
/// Symbols has no dashed bubble. A template image the size `bubble.left` is at that point size, so it drops in where
/// the symbol goes, takes `foregroundStyle`, and shows in menus.
extension Image {
    @MainActor static func temporaryChat(size: CGFloat, weight: Font.Weight = .regular) -> Image {
        Image(nsImage: TemporaryBubble.image(size: size, weight: weight)).renderingMode(.template)
    }
}

enum TemporaryBubble {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(size: CGFloat, weight: Font.Weight) -> NSImage {
        let key = "\(size)-\(weight)"
        if let hit = cache[key] { return hit }
        // bubble.left's geometry at 200 pt (its image is 266 × 237), on the stroke's centre line.
        let s = size / 200
        let line = 20 * s * (weight == .light ? 0.78 : weight == .medium ? 1.15 : weight == .semibold ? 1.3 : 1)
        let image = NSImage(size: NSSize(width: 266 * s, height: 237 * s), flipped: true) { _ in
            let p = NSBezierPath()
            let (l, r, t, b, k): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (40, 228, 32, 150, 32)
            // From the tail's tip, so a dash always wraps it.
            p.move(to: NSPoint(x: 90, y: 198))
            p.line(to: NSPoint(x: 86, y: b))
            p.line(to: NSPoint(x: l + k, y: b))
            p.appendArc(withCenter: NSPoint(x: l + k, y: b - k), radius: k, startAngle: 90, endAngle: 180)
            p.line(to: NSPoint(x: l, y: t + k))
            p.appendArc(withCenter: NSPoint(x: l + k, y: t + k), radius: k, startAngle: 180, endAngle: 270)
            p.line(to: NSPoint(x: r - k, y: t))
            p.appendArc(withCenter: NSPoint(x: r - k, y: t + k), radius: k, startAngle: 270, endAngle: 0)
            p.line(to: NSPoint(x: r, y: b - k))
            p.appendArc(withCenter: NSPoint(x: r - k, y: b - k), radius: k, startAngle: 0, endAngle: 90)
            p.line(to: NSPoint(x: 128, y: b))
            p.close()
            p.transform(using: AffineTransform(scaleByX: s, byY: s))
            // Dashes like SF Symbols' own dashed shapes (rectangle.dashed): corners whole, short gaps mid-edge, and the
            // tail one V from where it leaves the bubble. Gaps' centres along the outline from the tip, at 200 pt.
            let gaps: [CGFloat] = [55, 139, 247, 309, 417, 510, 560].map { $0 * s }
            let gap = line * 0.9, total = Self.length(of: p)
            var dashes: [CGFloat] = [], from: CGFloat = -line / 2
            for g in gaps {
                dashes += [g - gap / 2 - from - line, gap + line]
                from = g + gap / 2
            }
            dashes.append(total - from)
            p.setLineDash(dashes, count: dashes.count, phase: 0)
            p.lineWidth = line
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Temporary chat"
        cache[key] = image
        return image
    }

    private static func length(of path: NSBezierPath) -> CGFloat {
        let flat = path.flattened
        var total: CGFloat = 0, start = NSPoint.zero, last = NSPoint.zero
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<flat.elementCount {
            switch flat.element(at: i, associatedPoints: &pts) {
            case .moveTo: start = pts[0]; last = pts[0]
            case .lineTo: total += hypot(pts[0].x - last.x, pts[0].y - last.y); last = pts[0]
            case .closePath: total += hypot(start.x - last.x, start.y - last.y); last = start
            default: break
            }
        }
        return total
    }
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

/// A content card (docs/design/card-layout): the chat, the Browser and every page float over the window in a card,
/// radius 10, fill `win`, a 1pt ring and a hairline shadow. `enabled: false` keeps the same view tree with no card
/// (pages that lay out their own cards, beside flat panels).
struct ContentCard: ViewModifier {
    var enabled = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: enabled ? DS.Radius.contentCard : 0, style: .continuous)
        content
            .clipShape(shape)
            .background {
                shape.fill(enabled ? Color.dsWin : .clear)
                    .shadow(color: .black.opacity(enabled ? 0.05 : 0), radius: 1.5, y: 1)
            }
            .overlay { shape.inset(by: -0.5).stroke(enabled ? Color(nsColor: DS.cardEdge) : .clear, lineWidth: 1).allowsHitTesting(false) }
    }
}

/// Pages that put their own content cards on the window (a conversation and its side panel, the agents' column):
/// the root view then doesn't wrap them in one.
struct OwnsContentCardKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The gap between the window's edge and its cards, and between two cards.
enum CardLayout {
    static let margin: CGFloat = 8
}

extension View {
    func contentCard(_ enabled: Bool = true) -> some View { modifier(ContentCard(enabled: enabled)) }

    /// Says this page lays out its own content cards.
    func ownsContentCard() -> some View { preference(key: OwnsContentCardKey.self, value: true) }

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

/// Overview's colours (docs/design/overview/Redesign.html, options A·A·A; spec 34 §16): colour carries data there and
/// nowhere else. A five-hue data palette (validated for colour blindness on the light and dark surfaces; always shown
/// with its label), one blue scale for amounts, and yolk for Piopio's own (its budget, its one remark). State stays
/// `StatusTone`: never a data colour for state, never a status colour for data.
enum DataColor {
    /// The data palette in its fixed order (identity follows the thing, not its rank).
    static let series: [Color] = [
        dynamic(0x2A78D6, 0x3987E5), dynamic(0x1BAF7A, 0x199E70), dynamic(0x6250D6, 0x9085E9),
        dynamic(0xEDA100, 0xC98500), dynamic(0xE87BA4, 0xD55181),
    ]
    /// Each hue's soft tint, for tiles behind a glyph.
    static let tints: [Color] = [
        dynamic(0xE3EEFB, 0x3987E5, darkAlpha: 0.2), dynamic(0xDCF4EA, 0x199E70, darkAlpha: 0.22), dynamic(0xE9E6FA, 0x9085E9, darkAlpha: 0.2),
        dynamic(0xFCEFD2, 0xC98500, darkAlpha: 0.22), dynamic(0xFBE7EF, 0xD55181, darkAlpha: 0.2),
    ]
    static func series(_ i: Int) -> Color { series[i % series.count] }
    static func tint(_ i: Int) -> Color { tints[i % tints.count] }
    /// Amounts, light to dark: 0 is the track (nothing), then four steps.
    static let seq: [Color] = [Color.dsTrack, dynamic(0xB7D3F6, 0x1C3F6B), dynamic(0x6DA7EC, 0x256ABF), dynamic(0x2A78D6, 0x3987E5), dynamic(0x184F95, 0x86B6EF)]
    /// Piopio's own: its budget, its one remark per page.
    static let yolk = dynamic(0xF5C542, 0xF5C542)
    static let yolkSoft = dynamic(0xFFF4CF, 0xF5C542, darkAlpha: 0.16)

    /// The amount scale for a share of the peak (bars): the three darker steps, so a small bar still reads.
    static func amount(_ share: Double) -> Color { share > 0.66 ? seq[4] : share > 0.33 ? seq[3] : seq[2] }

    private static func dynamic(_ light: UInt32, _ dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        func rgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark, darkAlpha) : rgb(light, 1) })
    }
}

/// A small "ⓘ" whose tooltip says what the line beside it doesn't (Overview moves its explanations here).
struct InfoMark: View {
    let text: String
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Color.dsFg3).help(text).accessibilityLabel(text)
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
