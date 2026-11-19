import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Export (docs/spec/04 T11, docs/design/export): any conversation, the same rows wherever it's offered: a chat's, a
// Build session's and an agent's ⋯ menu, a sidebar row's right-click, and the command palette. It works without the
// conversation open: the engine sends the visuals the export shows along with it.

@MainActor enum ConversationExport {
    /// Asks where to save, then writes the export. Visuals (docs/spec/25 §8) are drawn here: a frame in HTML, a picture
    /// in Markdown.
    static func save(_ engine: EngineController, _ ref: ContainerRef, _ format: ExportParams.Format) async throws {
        let result = try await fetch(engine, ref, format)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = result.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var content = result.content
        if format != .jsonl {
            var visuals: [String: (title: String, html: String)] = [:]
            for v in result.visuals ?? [] { visuals[v.callId] = (v.title, v.html) }
            content = await VisualExport.fill(content, html: format == .html) { visuals[$0] }
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Copy as Markdown: a visual keeps its title line, without a picture.
    static func copy(_ engine: EngineController, _ ref: ContainerRef) async throws {
        let result = try await fetch(engine, ref, .markdown)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(VisualExport.strip(result.content), forType: .string)
    }

    private static func fetch(_ engine: EngineController, _ ref: ContainerRef, _ format: ExportParams.Format) async throws -> ExportResult {
        guard let client = engine.client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine isn't running.") }
        return try await client.call("sessions.export", ExportParams(ref: ref, format: format), as: ExportResult.self)
    }
}

/// Copy as Markdown and Export ▸ Markdown… / HTML… / JSONL…, for a menu. `noun` names what's exported when the place
/// holds more than one conversation (an agent's run: "Export This Run").
struct ExportMenuItems: View {
    let engine: EngineController
    let ref: ContainerRef
    var noun: String?

    var body: some View {
        Button("Copy as Markdown") { run { try await ConversationExport.copy(engine, ref) } }
        Menu(noun.map { "Export \($0)" } ?? "Export") {
            Button("Markdown…") { run { try await ConversationExport.save(engine, ref, .markdown) } }
            Button("HTML…") { run { try await ConversationExport.save(engine, ref, .html) } }
            Button("JSONL…") { run { try await ConversationExport.save(engine, ref, .jsonl) } }
        }
    }
}
