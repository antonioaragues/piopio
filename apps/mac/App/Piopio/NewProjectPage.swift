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
    /// A team for the project (docs/spec/19 §10): a template id, or nil for none.
    @State private var teamTemplate: String?
    @State private var templates: [TeamTemplate] = []
    @FocusState private var focus: StartField?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var folderName: String { trimmed.isEmpty ? "Name" : trimmed.replacingOccurrences(of: "/", with: "-") }

    /// The chosen team: one of yours ("def:<id>") or a template.
    private var chosenDefinition: TeamDefinition? {
        guard let id = teamTemplate, id.hasPrefix("def:") else { return nil }
        return engine.teamDefinitions.first { $0.id == String(id.dropFirst(4)) }
    }
    private var chosenName: String? { chosenDefinition?.name ?? templates.first { $0.id == teamTemplate }?.name }
    private var chosenRoles: [TeamRole]? { chosenDefinition?.roles ?? templates.first { $0.id == teamTemplate }?.roles }

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
                if continuing == nil && !templates.isEmpty {
                    HStack(spacing: 10) {
                        Text("Who works here").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg2)
                        Menu {
                            Button("Piopio") { teamTemplate = nil }
                            // Your teams first (docs/spec/20 P3), then a new one from a template.
                            if engine.teamDefinitions.contains(where: \.saved) {
                                Section("Your teams") { ForEach(engine.teamDefinitions.filter(\.saved)) { d in Button(d.name) { teamTemplate = "def:" + d.id } } }
                            }
                            Section("New, from a template") { ForEach(templates) { t in Button(t.name) { teamTemplate = t.id } } }
                        } label: {
                            Text(chosenName ?? "Piopio").foregroundStyle(Color.dsFg)
                        }
                        .menuStyle(.button).buttonStyle(PillStyle()).fixedSize()
                        Text(chosenRoles.map { "\($0.map(\.name).joined(separator: ", ")). Every conversation here is with its lead." } ?? "Or a team: a lead that plans and members that work in parallel. You can change it in the project's Settings.")
                            .font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                    }
                }
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
        .task { templates = await engine.teamTemplates() }
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
            do {
                let project = try await engine.createProject(name: projectName, instructions: text.isEmpty ? nil : text)
                // With a team: it works in the new folder, which becomes a git repo so tasks get their own branches.
                if let teamTemplate {
                    let def = chosenDefinition
                    do { _ = try await engine.createTeam(name: def?.name ?? "\(project.name) team", template: def?.template ?? teamTemplate, cwd: project.path, goal: nil, testCommand: nil, initGit: true, definition: def?.id) }
                    catch { self.error = "The project is made, but not its team: \((error as? EngineError)?.message ?? error.localizedDescription)" }
                }
                done(project)
            }
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
