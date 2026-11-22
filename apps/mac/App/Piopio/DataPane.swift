import PiopioKit
import SwiftUI

struct DataPane: View {
    let engine: EngineController
    @State private var busy = false
    @State private var message: String?
    @State private var failure: String?
    @State private var result: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "Backup", summary: "A copy of Piopio you can restore, on this Mac or another one.")
            ListCard {
                SettingRow(title: "Back up Piopio", subtitle: "Conversations, projects, agents and their automations, Build history, drafts, memory and settings. Project folders and Keychain secrets stay where they are; agents in your cloud keep theirs there, and remote memory services need their own backup.", last: true) {
                    if busy { ProgressView().controlSize(.small) }
                    Button("Restore…", action: restore).buttonStyle(PillStyle(compact: true))
                    Button("Back Up…", action: backup).buttonStyle(PillStyle(kind: .primary, compact: true))
                }
                .disabled(busy || engine.isMaintaining)
            }
            VStack(alignment: .leading, spacing: 6) {
                FinePrint("The backup is an unencrypted folder with your conversations and any secrets you put in files or settings: keep it somewhere private. The engine stops briefly so its databases copy safely.")
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Color.dsFg2).textSelection(.enabled) }
                if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(Color.dsWarn).textSelection(.enabled) }
                if let result {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.top, 12)
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
        guard confirm("Create a Piopio backup?", "Current work will stop and pending Build questions will be cancelled. Piopio restarts afterward and automations carry on. External pi CLI sessions should be idle while backing up their history.") else { return }
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
