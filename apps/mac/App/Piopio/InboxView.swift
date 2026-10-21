import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

private extension JSONValue {
    /// Indented JSON, keys sorted (for editing an approval's arguments).
    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// The menu bar's Inbox: what needs you, newest first; picking one opens it.
struct InboxMenu: View {
    let engine: EngineController

    var body: some View {
        let waiting = engine.inbox.filter(\.needsYou)
        if waiting.isEmpty { Text("Nothing needs you") }
        ForEach(waiting.prefix(8)) { item in
            Button("\(item.agentName): \(item.approval?.title ?? item.body)".prefix(80)) { show(item.approval?.approvalId ?? item.id) }
        }
        Divider()
        Button("Open Inbox") { show(nil) }
    }

    private func show(_ id: String?) {
        WindowOpener.shared.showMain()
        NotificationCenter.default.post(name: .openInbox, object: id)
    }
}
