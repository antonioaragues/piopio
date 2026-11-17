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

