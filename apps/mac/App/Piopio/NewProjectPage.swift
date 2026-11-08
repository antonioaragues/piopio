import AppKit
import PiopioKit
import SwiftUI

// New project (docs/spec/18 CF4): a project is always a folder. Given a name, Piopio makes one in ~/Piopio with an
// AGENTS.md (what every conversation there is told) and a NOTES.md (what they keep for each other); or you open a
// folder you already have. A centered start page in the main window, like the conversation's.

extension Notification.Name {
    /// Opens the New project page. Object: the conversation to continue in the new folder (Continue in › New Project…).
    static let newProject = Notification.Name("piopio.newProject")
    /// File › Turn Conversation into Agent… (the open conversation).
    static let turnIntoAgent = Notification.Name("piopio.turnIntoAgent")
}

/// New project: a name and, optionally, instructions; or a folder on this Mac instead. `done` gets the project, or nil
/// for Back (Esc).
struct NewProjectPage: View {
    let engine: EngineController
    /// The conversation that asked, to continue in the new folder.
    let continuing: ContainerRef?
    let done: (ProjectInfo?) -> Void
    @State private var name = ""
    @State private var instructions = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focus: StartField?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var folderName: String { trimmed.isEmpty ? "Name" : trimmed.replacingOccurrences(of: "/", with: "-") }

    private var description: String {
        if let continuing, let title = engine.threads.first(where: { $0.ref == continuing })?.title ?? engine.buildSessions.first(where: { $0.ref == continuing })?.title {
            return "A folder for a subject. “\(title)” continues there once it's made."
        }
        return "A folder for a subject: its files, and conversations that work on them and keep shared notes."
    }

    var body: some View {
        StartColumn(top: 112) {
            StartHeader(kind: .project, description: description) {
                TitleField(placeholder: "Project name", text: $name, focused: $focus) { focus = .text }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Instructions (optional)").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg2)
                TextEditor(text: $instructions)
                    .focused($focus, equals: .text)
                    .accessibilityLabel("Project instructions")
                    .font(.system(size: 14)).scrollContentBackground(.hidden).padding(12).frame(height: 102)
                    .composerBox()
                FinePrint("Makes the folder ~/Piopio/\(folderName), with the instructions in AGENTS.md and the shared notes in NOTES.md. Edit them there any time.")
                StartError(text: error)
                HStack {
                    Button("Open a folder instead…", action: chooseFolder).buttonStyle(PillStyle())
                        .help("A folder you already have: its conversations read and change its files")
                    Spacer()
                    Button("Back") { done(nil) }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                    MainAction(title: "Create project ⌘↩", busy: saving, enabled: !trimmed.isEmpty, action: create)
                }
            }
        }
        .disabled(saving)
        .onAppear { focus = .name }
        .onExitCommand { done(nil) }
    }

    private func create() {
        guard !trimmed.isEmpty, !saving else { return }
        let projectName = trimmed
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do { done(try await engine.createProject(name: projectName, instructions: text.isEmpty ? nil : text)) }
            catch { self.error = ((error as? EngineError)?.message ?? error.localizedDescription) + " Nothing was made." }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saving = true
        Task {
            defer { saving = false }
            if let project = await engine.addProject(url) { done(project) } else { error = "Couldn't open that folder." }
        }
    }
}
