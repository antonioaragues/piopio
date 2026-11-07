import PiopioKit
import SwiftUI

// What a conversation in a folder may do (docs/spec/18 §4), said the same way everywhere: the composer's chip, the
// session toolbar and Home's line under the box ("In piopio · can edit files; asks before commands").

extension ApprovalMode {
    var title: String {
        switch self {
        case .readOnly: "Read only"
        case .ask: "Ask"
        case .autoEdit: "Auto-edit"
        case .fullAuto: "Full auto"
        }
    }

    /// One line for menus.
    var summary: String {
        switch self {
        case .readOnly: "Reads files and the web; doesn't edit or run commands"
        case .ask: "Asks before each change or command"
        case .autoEdit: "Edits files; asks before commands"
        case .fullAuto: "Edits and runs commands; asks only for risky ones"
        }
    }

    /// What Piopio may do, after "In <project> · ".
    var line: String {
        switch self {
        case .readOnly: "reads files and the web; can't change anything"
        case .ask: "asks before any change or command"
        case .autoEdit: "can edit files; asks before commands"
        case .fullAuto: "can edit files and run commands"
        }
    }

    var tint: Color {
        switch self {
        case .readOnly, .autoEdit: .dsFg3
        case .ask: .dsAmber
        case .fullAuto: .accentColor
        }
    }
}
