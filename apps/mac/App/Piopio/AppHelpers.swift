import AppKit
import PiopioKit
import SwiftUI

// Small helpers several views share (they lived with the notebooks until docs/spec/18 phase 2).

/// An NSMenuItem that runs a closure (menus built in code).
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

/// Runs `work`, and says what went wrong in an alert.
@MainActor func run(_ work: @escaping () async throws -> Void) {
    Task {
        do { try await work() } catch {
            let alert = NSAlert()
            alert.messageText = "That didn't work"
            alert.informativeText = (error as? EngineError)?.message ?? String(describing: error)
            alert.runModal()
        }
    }
}

/// A one-field prompt; nil when cancelled or empty.
@MainActor func ask(_ title: String, value: String = "", placeholder: String = "", button: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(string: value)
    field.placeholderString = placeholder
    field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let text = field.stringValue.trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
}

/// The `- fact` lines of a Markdown memory text (About me), labelled by a short "Label:" prefix or their section.
enum MemoryText {
    struct Fact { let line: Int; let label: String; let text: String; let raw: String }

    static func facts(in text: String) -> [Fact] {
        var section = "Notes"
        var out: [Fact] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") { section = String(l.dropFirst(3)); continue }
            guard l.hasPrefix("- ") || l.hasPrefix("* ") else { continue }
            let body = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if let colon = body.firstIndex(of: ":"), body.distance(from: body.startIndex, to: colon) <= 18, !body[..<colon].contains(" ") || body[..<colon].split(separator: " ").count <= 2 {
                out.append(Fact(line: i, label: String(body[..<colon]), text: String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces), raw: body))
            } else {
                out.append(Fact(line: i, label: section, text: body, raw: body))
            }
        }
        return out
    }
}
