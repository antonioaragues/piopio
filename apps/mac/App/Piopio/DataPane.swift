import PiopioKit
import SwiftUI

struct DataPane: View {
    let engine: EngineController
    @State private var busy = false
    @State private var message: String?
    @State private var failure: String?
    @State private var result: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneTitle(title: "Backup & costs", subtitle: "Keep a recoverable copy of Piopio and understand what its requests cost.")
            VStack(alignment: .leading, spacing: 10) {
                Text("Back up Piopio").font(.headline)
                Text("Includes chats, notebooks, local agent data and definitions, Build conversation history, drafts, memory, and settings. External project folders and Keychain secrets stay where they are. Remote memory services need their own backup.")
                Text("The backup is an unencrypted folder containing personal conversations and any secrets you put in files or settings. Keep it somewhere private. The engine stops briefly so its databases can be copied safely.")
                    .foregroundStyle(Color.dsFg2)
                HStack {
                    Button("Create backup…", action: backup).buttonStyle(PillStyle(kind: .primary))
                    Button("Restore backup…", action: restore).buttonStyle(PillStyle())
                    if busy { ProgressView().controlSize(.small) }
                }.disabled(busy || engine.isMaintaining)
                if let message { Text(message).foregroundStyle(Color.dsFg2).textSelection(.enabled) }
                if let failure { Text(failure).foregroundStyle(Color.dsRed).textSelection(.enabled) }
                if let result { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result]) }.buttonStyle(.link) }
            }
            .font(.system(size: 12)).padding(16)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12))
            CostDetails(engine: engine)
        }
    }
    private func confirm(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func backup() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Choose backup location"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        guard confirm("Create a Piopio backup?", "Current work will stop and pending Build questions will be cancelled. Piopio restarts afterward and agents resume their schedules. External pi CLI sessions should be idle while backing up their history.") else { return }
        let stamp = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let destination = parent.appending(path: "Piopio-\(stamp).piopiobackup")
        busy = true; failure = nil; message = nil
        Task {
            defer { busy = false }
            do { try await engine.createBackup(at: destination); result = destination; message = "Backup verified and saved." }
            catch { failure = error.localizedDescription }
        }
    }
    private func restore() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Choose backup folder"
        guard panel.runModal() == .OK, let archive = panel.url else { return }
        guard confirm("Restore Piopio from this backup?", "This replaces Piopio's data after verifying every file. Current work will stop. The previous data folder is kept for recovery, external project files and Keychain secrets stay unchanged, and agent schedules resume after restart. Backups from another Mac may need providers and project folders reconnected.") else { return }
        busy = true; failure = nil; message = nil
        Task {
            defer { busy = false }
            do {
                result = try await engine.restoreBackup(from: archive)
                message = "Restored. Your previous data folder is available in Finder. Reopen Piopio to reload all interface preferences."
            } catch { failure = error.localizedDescription }
        }
    }
}
