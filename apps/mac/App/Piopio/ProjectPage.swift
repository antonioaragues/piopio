import AppKit
import PiopioKit
import SwiftUI

// Projects without a folder (docs/spec/18 §3): a group of conversations with shared instructions, files and memory.
// Their page has all of it; the sheet makes one (or, given a folder, adds that folder as a project).

extension Notification.Name {
    /// Opens the New project sheet.
    static let newProject = Notification.Name("piopio.newProject")
    /// File › Turn Conversation into Agent… (the open conversation).
    static let turnIntoAgent = Notification.Name("piopio.turnIntoAgent")
}

/// A project without a folder: what its conversations are told, its files, what it remembers, its conversations.
struct ProjectPage: View {
    let engine: EngineController
    let project: ProjectInfo
    @Binding var item: SidebarItem
    @State private var instructions = ""
    @State private var files: [DirEntry] = []
    @State private var facts: [MemoryRecordInfo] = []
    @State private var newFact = ""
    @State private var tick = 0

    private var bank: String { "project:\(project.id)" }
    private var conversations: [SessionSummary] { engine.conversations(in: project).sorted { $0.updatedAt > $1.updatedAt } }
    private var edited: Bool { instructions.trimmingCharacters(in: .whitespacesAndNewlines) != (project.instructions ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(project.name, subtitle: subtitle) {
                Button("New conversation") { NotificationCenter.default.post(name: .newBuildSession, object: project.id) }
                    .buttonStyle(PillStyle(kind: .toolbar))
                Menu {
                    Button("Rename…") { rename() }
                    Divider()
                    Button("Remove Project…", role: .destructive) { remove() }
                } label: { Image(systemName: "ellipsis").accessibilityLabel("More") }
                    .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    instructionsCard
                    filesCard
                    memoryCard
                    conversationsCard
                }
                .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 48)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: "\(project.id)|\(tick)") {
            instructions = project.instructions ?? ""
            files = await engine.listDir(project.path, "").filter { $0.kind == .file }
            facts = (try? await engine.client?.call("memory.list", MemoryListParams(provider: "builtin", bank: bank, kinds: ["fact"]), as: MemoryListResult.self))?.records ?? []
        }
    }

    private var subtitle: String {
        let c = conversations.count
        return "Project · \(c) conversation\(c == 1 ? "" : "s") · \(files.count) file\(files.count == 1 ? "" : "s")"
    }

    // MARK: Instructions

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: "Instructions") {
                if edited {
                    Button("Save") { run { try await engine.configureProject(project, instructions: instructions) } }
                        .buttonStyle(PillStyle(kind: .primary, compact: true))
                }
            }
            TextEditor(text: $instructions)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 90)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.dsLine, lineWidth: 0.5))
            FinePrint("Every conversation in the project is told this: what it's about, what matters, how to answer.").padding(.top, 6)
        }
        .padding(.bottom, 22)
    }

    // MARK: Files

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: "Files") { AddButton(title: "Add files…", action: addFiles) }
            ListCard {
                if files.isEmpty {
                    Text("No files yet. Its conversations can read the files you add here: notes, PDFs, quotes, plans.")
                        .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).padding(14)
                }
                ForEach(Array(files.enumerated()), id: \.element.path) { i, f in
                    HStack(spacing: 10) {
                        Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                        Button(f.name) { NotificationCenter.default.post(name: .viewFile, object: URL(fileURLWithPath: project.path).appending(path: f.path)) }
                            .buttonStyle(.plain).font(.system(size: 13))
                        Spacer()
                        Button { run { try await engine.removeProjectFile(project, name: f.name); tick += 1 } } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dsFg3) }
                            .buttonStyle(.plain).help("Remove from the project").accessibilityLabel("Remove \(f.name)")
                    }
                    .padding(.horizontal, 14).frame(minHeight: 40)
                    if i < files.count - 1 { RowDivider(inset: 14) }
                }
            }
        }
        .padding(.bottom, 22)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        run {
            for url in urls { try await engine.addProjectFile(project, url: url) }
            tick += 1
        }
    }

    // MARK: Memory

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("What it remembers", detail: "shared by its conversations")
            ListCard {
                ForEach(facts) { f in
                    HStack(spacing: 10) {
                        Text(f.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { forget(f) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dsFg3) }
                            .buttonStyle(.plain).help("Forget").accessibilityLabel("Forget \(f.text)")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    RowDivider(inset: 14)
                }
                TextField("Add something it should remember…", text: $newFact)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 14).frame(minHeight: 40)
                    .onSubmit(addFact)
            }
            FinePrint("Its conversations save facts here too (a decision, a measurement, a date). Each one reads all of it.").padding(.top, 6)
        }
        .padding(.bottom, 22)
    }

    private func addFact() {
        let text = newFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        run {
            try await engine.spaceCall("memory.add", MemoryAddParams(provider: "builtin", bank: bank, text: text))
            newFact = ""
            tick += 1
        }
    }

    private func forget(_ fact: MemoryRecordInfo) {
        run {
            try await engine.spaceCall("memory.forget", MemoryIdParams(provider: "builtin", bank: bank, id: fact.id))
            tick += 1
        }
    }

    // MARK: Conversations

    private var conversationsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: "Conversations") { AddButton(title: "New conversation") { NotificationCenter.default.post(name: .newBuildSession, object: project.id) } }
            ListCard {
                if conversations.isEmpty {
                    Text("None yet. Start one here, choose this project on Home, or move a conversation in from its folder menu.")
                        .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).padding(14)
                }
                ForEach(Array(conversations.enumerated()), id: \.element.ref.id) { i, c in
                    Button { item = .chat(c.ref.id) } label: {
                        HStack {
                            Text(c.title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                            Spacer()
                            Text(BuildSessionView.relative(c.updatedAt)).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < conversations.count - 1 { RowDivider(inset: 14) }
                }
            }
        }
    }

    // MARK: Actions

    private func rename() {
        guard let name = ask("Rename the project", value: project.name, button: "Rename") else { return }
        run { try await engine.configureProject(project, name: name) }
    }

    private func remove() {
        let alert = NSAlert()
        alert.messageText = "Remove “\(project.name)”?"
        alert.informativeText = "Its files and what it remembers are deleted. Its conversations stay, with no project."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await engine.removeProject(project)
            try? await engine.refreshCatalog()
            item = .home
        }
    }
}

/// New project (docs/spec/18 §3): a name and, optionally, instructions; or a folder on this Mac instead.
struct NewProjectSheet: View {
    let engine: EngineController
    let done: (ProjectInfo?) -> Void
    @State private var name = ""
    @State private var instructions = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New project").font(.system(size: 15, weight: .semibold))
            Text("A project keeps a subject's conversations together, with files and memory they share.")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            TextField("Name, like Kitchen renovation", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions (optional)").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
                TextEditor(text: $instructions)
                    .font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(height: 80)
                    .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            HStack {
                Button("Use a Folder Instead…", action: chooseFolder).help("A folder on this Mac: its conversations read and change its files")
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
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
