import PiopioKit
import PiopioTranscript
import SwiftUI

// One visual language for agents, teams and projects (docs/spec/21, design 1a): a colour, an avatar and a role verb.
// An agent's colour comes from its id for now (D4 lets you choose it); a team shows its members as a small stack.

enum AgentHue {
    /// The design's five hues (amber, green, teal, blue, violet), shared with the transcript (AgentPalette).
    static let palette: [Color] = AgentPalette.rgb.map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    /// Members with no model (CI) and system rows.
    static let system = Color(white: 0.4)

    /// A stable colour for an id (an agent's, or a team-only member's).
    static func color(_ id: String) -> Color { palette[AgentPalette.index(id)] }

    /// A team member's colour: its agent's when it is one of yours, else its own; grey for the one that merges.
    static func color(_ role: TeamRole, team: String) -> Color {
        if role.kind == "integrate" { return system }
        return color(role.agent ?? "\(team)/\(role.id)")
    }
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

/// A team as three overlapping circles in its members' colours (design 1a), each ringed in the background colour.
struct TeamStack: View {
    let colors: [Color]
    var size: CGFloat = 10
    var ring: Color = .dsSide

    var body: some View {
        HStack(spacing: -size * 0.4) {
            ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, c in
                Circle().fill(c).frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(ring, lineWidth: 1.5).padding(-1.5))
            }
        }
        .padding(.horizontal, 1.5)
        .accessibilityHidden(true)
    }

    static func colors(_ roles: [TeamRole], team: String) -> [Color] {
        roles.map { AgentHue.color($0, team: team) }
    }
}
