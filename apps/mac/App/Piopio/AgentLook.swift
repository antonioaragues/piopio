import PiopioKit
import PiopioTranscript
import SwiftUI

// One visual language for agents and projects (docs/spec/21, design 1a): a colour, an avatar and a role verb. An
// agent's colour comes from its id for now (D4 lets you choose it).

enum AgentHue {
    /// The design's five hues (amber, green, teal, blue, violet), shared with the transcript (AgentPalette).
    static let palette: [Color] = AgentPalette.rgb.map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    /// System rows.
    static let system = Color(white: 0.4)

    /// A stable colour for an agent's id.
    static func color(_ id: String) -> Color { palette[AgentPalette.index(id)] }
}

/// An agent's small avatar (design 1a): a rounded square in its colour with its initial, or its glyph.
struct SidebarAvatar: View {
    let id: String
    let name: String
    var glyph: String?
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(AgentHue.color(id))
            .frame(width: size, height: size)
            .overlay {
                if let glyph {
                    AvatarGlyph(avatar: glyph, size: size * 0.6, color: Color(white: 0.08))
                } else {
                    Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(Color(white: 0.08))
                }
            }
    }
}


/// An agent's tile (docs/design/automations, agents and automations handoff): its initial, or its glyph, in its hue's
/// ink on a soft tint of it. Rounded square; the radius grows with the size (40 → 13, 64 → 20).
struct AgentTile: View {
    let id: String
    let name: String
    var glyph: String?
    var size: CGFloat = 40

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * (size >= 30 ? 0.32 : 0.3), style: .continuous)
        shape.fill(AgentHue.soft(id))
            .frame(width: size, height: size)
            .overlay {
                if let glyph, !glyph.isEmpty {
                    AvatarGlyph(avatar: glyph, size: size * 0.5, color: AgentHue.ink(id))
                } else {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * (size < 30 ? 0.48 : 0.4), weight: .semibold))
                        .foregroundStyle(AgentHue.ink(id))
                }
            }
            .accessibilityHidden(true)
    }
}

/// Who runs an automation: Piopio's chick on its yolk, or the agent's tile.
struct RunnerTile: View {
    let engine: EngineController
    let runsAs: String
    var size: CGFloat = 22

    var body: some View {
        if let agent = engine.agents.first(where: { $0.ref.id == runsAs }) {
            AgentTile(id: agent.ref.id, name: agent.title, glyph: agent.agent?.avatar, size: size)
        } else if runsAs == "piopio" {
            Chick(size: size)
        } else {
            AgentTile(id: runsAs, name: "?", size: size)
        }
    }
}

extension AgentHue {
    /// The tile's fill: a pale tint of the hue (oklch 0.91 0.06 h in the handoff), darker in dark mode.
    static func soft(_ id: String) -> Color { Color(nsColor: mix(id, light: (NSColor.white, 0.6), dark: (NSColor(srgbRed: 0.145, green: 0.145, blue: 0.141, alpha: 1), 0.6))) }
    /// The tile's initial: the hue, deep (oklch 0.45 0.13 h), lighter in dark mode.
    static func ink(_ id: String) -> Color { Color(nsColor: mix(id, light: (NSColor.black, 0.42), dark: (NSColor.white, 0.30))) }

    private static func mix(_ id: String, light: (NSColor, CGFloat), dark: (NSColor, CGFloat)) -> NSColor {
        let (r, g, b) = AgentPalette.rgb[AgentPalette.index(id)]
        let hue = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        return NSColor(name: nil) { a in
            let isDark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (with, amount) = isDark ? dark : light
            return hue.blended(withFraction: amount, of: with) ?? hue
        }
    }
}
