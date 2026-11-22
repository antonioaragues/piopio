import SwiftUI

// Shared by the right-hand panels' blocks (Inspector.swift: Tools, Skills; ChatSummary.swift: Read). The older
// summary card (verbs in a grey column, docs/design/summary) gave way to Build's blocks in chats too on 2026-11-22
// (docs/design/chat-summary).

/// A blue text action (links are the only blue in the chrome).
struct SummaryLink: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(title, action: action).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
            .lineLimit(1).fixedSize()
    }
}
