import AppKit
import PiopioKit
import SwiftUI

// New project (docs/spec/18 CF4): a project is always a folder. Given a name, Piopio makes one in ~/Piopio with an
// AGENTS.md (what every conversation there is told) and a NOTES.md (what they keep for each other); or you open a
// folder you already have.

extension Notification.Name {
    /// Opens the New project sheet.
    static let newProject = Notification.Name("piopio.newProject")
    /// File › Turn Conversation into Agent… (the open conversation).
    static let turnIntoAgent = Notification.Name("piopio.turnIntoAgent")
}

/// New project: a name and, optionally, instructions; or a folder on this Mac instead.
struct NewProjectSheet: View {
    let engine: EngineController
    let done: (ProjectInfo?) -> Void
    @State private var name = ""
    @State private var instructions = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New project").font(.system(size: 15, weight: .semibold))
            Text("A folder for a subject: its files, and conversations that work on them and keep shared notes.")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            TextField("Name, like Kitchen renovation", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions (optional)").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
                TextEditor(text: $instructions)
                    .font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(height: 80)
                    .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
            }
            FinePrint("Makes the folder ~/Piopio/\(trimmed.isEmpty ? "Name" : trimmed.replacingOccurrences(of: "/", with: "-")), with the instructions in AGENTS.md and the shared notes in NOTES.md. Edit them there any time.")
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            HStack {
                Button("Open a Folder Instead…", action: chooseFolder).help("A folder you already have: its conversations read and change its files")
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        Task {
            do { done(try await engine.createProject(name: trimmed, instructions: instructions.isEmpty ? nil : instructions)) }
            catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { done(await engine.addProject(url)) }
    }
}
