import AppKit

/// Piopio design tokens (docs/design/README.md · "Design tokens"), light and dark.
/// AppKit colors so both the TextKit transcript and SwiftUI (`Color(nsColor:)`) share them.
public enum DS {
    // MARK: Surfaces and text
    public static let win = dynamic(rgb(0xFDFDFC), rgb(0x1A1A1C))
    public static let card = dynamic(.white, rgb(0x242426))
    public static let chip = dynamic(NSColor.black.withAlphaComponent(0.045), NSColor.white.withAlphaComponent(0.08))
    public static let bubble = dynamic(rgb(0xF1F1F3), rgb(0x2E2E31))
    public static let pill = dynamic(NSColor.white.withAlphaComponent(0.9), NSColor(srgbRed: 74 / 255, green: 74 / 255, blue: 78 / 255, alpha: 0.95))
    public static let glassEdge = dynamic(NSColor.white.withAlphaComponent(0.85), NSColor.white.withAlphaComponent(0.13))
    public static let fg = dynamic(rgb(0x1D1D1F), rgb(0xF5F5F7))
    public static let fg2 = dynamic(rgb(0x5B5B61), rgb(0xB8B8BD))
    public static let fg3 = rgb(0x8E8E93)
    public static let line = dynamic(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.12))
    public static let inv = dynamic(rgb(0x1D1D1F), rgb(0xF5F5F7))
    public static let invfg = dynamic(.white, rgb(0x1D1D1F))

    // MARK: Status (amber = waiting on you / limits, green = live / done, red = failed)
    public static let green = rgb(0x2FA760)
    public static let amber = rgb(0xE0A02A)
    public static let red = rgb(0xD9493F)
    public static let addbg = dynamic(rgb(0xE3F4E6), rgb(0x1F3B28))
    public static let delbg = dynamic(rgb(0xFBE7E3), rgb(0x47231F))

    // MARK: Brand (v2): the chick's yolk, only at brand moments (Home, empty states, onboarding, suggestions)
    public static let yolk = rgb(0xF7CE3E)
    public static let yolkSoft = dynamic(rgb(0xFDF7E1), rgb(0x3A3420))

    // MARK: Accent (follows the system accent)
    public static let accent = NSColor.controlAccentColor
    public static let accentSoft = NSColor(name: "piopio.accentSoft") { a in
        NSColor.controlAccentColor.withAlphaComponent(isDark(a) ? 0.26 : 0.14)
    }
    public static let accentLine = NSColor(name: "piopio.accentLine") { a in
        NSColor.controlAccentColor.withAlphaComponent(isDark(a) ? 0.60 : 0.45)
    }

    // MARK: Type (SF Pro / SF Mono)
    public static let transcriptSize: CGFloat = 13.5
    public static let transcriptLineHeight: CGFloat = 1.6

    // MARK: Radii
    public enum Radius {
        public static let window: CGFloat = 18
        public static let composer: CGFloat = 20
        public static let quickChat: CGFloat = 22
        public static let panel: CGFloat = 14
        public static let card: CGFloat = 12
        public static let row: CGFloat = 8
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
