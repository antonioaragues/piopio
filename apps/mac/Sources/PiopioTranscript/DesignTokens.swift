import AppKit

/// Piopio design tokens (docs/design/README.md · "Design tokens"), light and dark.
/// AppKit colors so both the TextKit transcript and SwiftUI (`Color(nsColor:)`) share them.
public enum DS {
    // MARK: Surfaces and text (docs/design/grey: grey ink, hairlines, no decoration)
    public static let win = dynamic(rgb(0xFCFCFB), rgb(0x1E1E1D))
    /// The sidebar's background, flush to the window edge.
    public static let side = dynamic(rgb(0xF4F4F2), rgb(0x191918))
    /// Fields and the cards that need you (approvals, questions), and the composer.
    public static let card = dynamic(.white, rgb(0x252524))
    /// Hover and selected rows, hover selectors, quiet fills.
    public static let chip = dynamic(NSColor.black.withAlphaComponent(0.06), NSColor.white.withAlphaComponent(0.07))
    public static let bubble = dynamic(rgb(0xF0F0ED), rgb(0x2B2B29))
    /// A segmented control's track and its selected segment.
    public static let track = dynamic(NSColor.black.withAlphaComponent(0.05), NSColor.white.withAlphaComponent(0.06))
    public static let seg = dynamic(.white, rgb(0x3A3A38))
    public static let pill = dynamic(.white, rgb(0x3A3A38))
    public static let glassEdge = dynamic(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.09))
    public static let fg = dynamic(rgb(0x1F1F1E), rgb(0xECECEA))
    public static let fg2 = dynamic(rgb(0x6B6B67), rgb(0xA6A6A1))
    public static let fg3 = dynamic(rgb(0x9B9B96), rgb(0x77776F))
    public static let line = dynamic(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.09))
    public static let inv = dynamic(rgb(0x1F1F1E), rgb(0xECECEA))
    public static let invfg = dynamic(.white, rgb(0x1E1E1D))

    // MARK: Status. Chrome uses none of these: blue is the only status color (the "needs you" dot). Green and red are
    // for code (diff +/−) and the few places that must say "failed".
    public static let green = dynamic(rgb(0x3A8A55), rgb(0x6CC28A))
    public static let amber = dynamic(rgb(0xB7791F), rgb(0xE0A955))
    public static let red = dynamic(rgb(0xC2493F), rgb(0xEF7D72))
    public static let addbg = dynamic(rgb(0xEEF5EF), rgb(0x233026))
    public static let delbg = dynamic(rgb(0xFAEEEC), rgb(0x3A2624))

    // MARK: Debate speakers (docs/spec/16-debate): the author and the reviewer
    public static let debateAuthor = dynamic(rgb(0x6E56CF), rgb(0xA08CF0))
    public static let debateReviewer = dynamic(rgb(0x1A8F82), rgb(0x4CC7B6))

    // MARK: Brand: the grey design has no brand color; kept neutral for old call sites
    public static let yolk = fg3
    public static let yolkSoft = chip

    // MARK: Accent (follows the system accent)
    public static let accent = NSColor.controlAccentColor
    /// Selected rows: grey, not tinted (blue is only for links, the caret and the "needs you" dot).
    public static let accentSoft = chip
    public static let accentLine = NSColor(name: "piopio.accentLine") { a in
        NSColor.controlAccentColor.withAlphaComponent(isDark(a) ? 0.60 : 0.45)
    }

    // MARK: Type (SF Pro / SF Mono)
    public static let transcriptSize: CGFloat = 13.5
    public static let transcriptLineHeight: CGFloat = 1.45

    // MARK: Radii
    public enum Radius {
        public static let window: CGFloat = 12
        public static let composer: CGFloat = 16
        public static let quickChat: CGFloat = 14
        public static let panel: CGFloat = 12
        public static let card: CGFloat = 12
        public static let code: CGFloat = 10
        public static let button: CGFloat = 8
        public static let row: CGFloat = 7
        public static let selector: CGFloat = 6
        public static let badge: CGFloat = 5
    }

    // MARK: Helpers
    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { isDark($0) ? dark : light }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
