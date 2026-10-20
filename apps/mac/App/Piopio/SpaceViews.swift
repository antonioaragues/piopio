import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Spaces (docs/spec/04-chat §3, docs/design 2b): you write in Main and the organizer routes each message to a
// topic, or creates one. Main shows routing cards; the replies live in the topics. The Chat selection is the
// conversation's `ContainerRef.key`: the Space's id for Main, "<space>/<topic>" for a topic.

/// Where Open on a routing card goes.
struct TopicTarget {
    let spaceId: String
    let topicId: String
    let itemId: String?
}

extension Notification.Name {
    /// Object: a `TopicTarget`.
    static let openTopic = Notification.Name("piopio.openTopic")
    static let newSpace = Notification.Name("piopio.newSpace")
}

/// An NSMenuItem that runs a closure (menus built in code, like Wrong topic).
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

extension SessionSummary {
    /// A Space's conversation (Main when `topicId` is nil).
    func ref(topic topicId: String?) -> ContainerRef {
        ContainerRef(kind: .space, id: ref.id, conversationId: topicId)
    }

    /// The Space's topics that aren't archived, newest activity first.
    var activeTopics: [TopicInfo] { (topics ?? []).filter { $0.archived != true } }
}

/// Rename, merge, archive and export a topic (S9): the sidebar row's and the capsule's menu.
struct TopicMenu: View {
    let engine: EngineController
    let space: SessionSummary
    let topic: TopicInfo
    @Binding var selection: String?

    private var ref: ContainerRef { space.ref(topic: topic.id) }

    var body: some View {
        Button("Rename…") {
            guard let title = ask("Rename topic", value: topic.title, button: "Rename") else { return }
            run { try await engine.spaceCall("spaces.topics.rename", TopicRenameParams(ref: ref, title: title)) }
        }
        let others = space.activeTopics.filter { $0.id != topic.id }
        if !others.isEmpty {
            Menu("Merge Into") {
                ForEach(others) { other in
                    Button(other.title) {
                        run {
                            _ = try await engine.merge(ref, into: other.id)
                            selection = space.ref(topic: other.id).key
                        }
                    }
                }
            }
        }
        Button("Export as Markdown…") { Task { await engine.thread(ref).export(.markdown) } }
        Divider()
        Button("Archive") {
            if selection == ref.key { selection = space.ref.id }
            run { try await engine.spaceCall("spaces.topics.archive", TopicArchiveParams(ref: ref, archived: true)) }
        }
    }
}

/// Runs a Space call, showing its error.
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

// MARK: Sidebar

/// Spaces with their topics nested (S6): newest activity first, an unread dot until you look at a reply.
struct SpacesSection: View {
    let engine: EngineController
    @Binding var selection: String?

    var body: some View {
        HStack {
            SectionLabel("Spaces")
            Spacer()
            Button { NotificationCenter.default.post(name: .newSpace, object: nil) } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            .buttonStyle(.plain)
            .help("New Space (⌘⇧N)")
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        if engine.spaces.isEmpty {
            Text("A Space keeps a long-running subject organized into topics.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.horizontal, 8)
        }
        ForEach(engine.spaces, id: \.ref.id) { space in
            let inside = selection == space.ref.id || selection?.hasPrefix(space.ref.id + "/") == true
            spaceRow(space, open: inside)
            if inside {
                ForEach(space.activeTopics) { topic in
                    topicRow(space, topic)
                }
            }
        }
    }

    private func spaceRow(_ space: SessionSummary, open: Bool) -> some View {
        let selected = selection == space.ref.id
        let unread = space.activeTopics.contains { $0.unread == true }
        return Button { selection = space.ref.id } label: {
            HStack(spacing: 8) {
                Text(String(space.title.prefix(1)).uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(open ? Color.accentColor : Color.dsFg3.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                Text(space.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                if !open, unread { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { SpaceMenu(engine: engine, space: space, selection: $selection) }
    }

    private func topicRow(_ space: SessionSummary, _ topic: TopicInfo) -> some View {
        let key = space.ref(topic: topic.id).key
        let selected = selection == key
        return Button { selection = key } label: {
            HStack(spacing: 8) {
                Text(topic.title).font(.system(size: 13, weight: selected ? .medium : .regular)).foregroundStyle(Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                if topic.running == true {
                    StatusDot(status: .running)
                } else if topic.unread == true {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("New reply")
                }
            }
            .padding(.leading, 32)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(selected ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { TopicMenu(engine: engine, space: space, topic: topic, selection: $selection) }
    }
}

/// Rename, settings, archived topics and delete, for the sidebar row and the Space header.
struct SpaceMenu: View {
    let engine: EngineController
    let space: SessionSummary
    @Binding var selection: String?

    var body: some View {
        Button("Rename…") { rename() }
        Button("Space Settings…") { NotificationCenter.default.post(name: .editSpaceInstructions, object: space.ref.id) }
        let archived = (space.topics ?? []).filter { $0.archived == true }
        if !archived.isEmpty {
            Menu("Archived Topics") {
                ForEach(archived) { topic in
                    Button("Unarchive “\(topic.title)”") {
                        run { try await engine.spaceCall("spaces.topics.archive", TopicArchiveParams(ref: space.ref(topic: topic.id), archived: false)) }
                    }
                }
            }
        }
        Divider()
        Button("Delete Space…", role: .destructive) {
            let alert = NSAlert()
            alert.messageText = "Delete “\(space.title)”?"
            alert.informativeText = "Main and all \(space.topics?.count ?? 0) topics are deleted. This can't be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if selection == space.ref.id || selection?.hasPrefix(space.ref.id + "/") == true { selection = nil }
            Task { await engine.delete(space.ref) }
        }
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename Space"
        let field = NSTextField(string: space.title)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await engine.rename(space.ref, to: field.stringValue) }
    }
}

extension Notification.Name {
    /// Object: the Space's id.
    static let editSpaceInstructions = Notification.Name("piopio.editSpaceInstructions")
}

// MARK: New Space

/// Name and instructions (S5). Topics come later, as you write in Main.
struct NewSpaceSheet: View {
    let engine: EngineController
    let created: (ContainerRef) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Space").font(.system(size: 17, weight: .bold))
            Text("A Space is a long-running area of your life or work. You write in Main; the organizer sends each message to the right topic, or starts one.")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
                TextField("Home renovation", text: $name).textFieldStyle(.roundedBorder)
            }
            InstructionsField(text: $instructions)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create Space") {
                    creating = true
                    Task {
                        if let ref = await engine.createSpace(name: name.trimmingCharacters(in: .whitespaces), instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)) { created(ref) }
                        dismiss()
                    }
                }
                .buttonStyle(PillStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

private struct InstructionsField: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instructions (optional)").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 96)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
            Text("Every agent in the Space is told this: who you are, what matters, how to answer.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
        }
    }
}

/// Name-independent settings (§3.6): instructions, models, memory and auto-tidy.
struct SpaceSettingsSheet: View {
    let engine: EngineController
    let space: SessionSummary
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var memory = true
    @State private var autoTidy = false
    @State private var organizer: ModelRef?
    @State private var topics: ModelRef?
    @State private var picking: Picking?

    private enum Picking: Identifiable { case organizer, topics; var id: Self { self } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(space.title): settings").font(.system(size: 15, weight: .semibold))
            InstructionsField(text: $text)
            VStack(alignment: .leading, spacing: 8) {
                modelRow("Organizer model", detail: "Decides where each message goes. A fast, cheap model is enough.", model: organizer) { picking = .organizer }
                modelRow("Topic model", detail: "Answers in the topics: new ones, and every existing one.", model: topics) { picking = .topics }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Memory", isOn: $memory)
                Text("Shared facts every topic reads. The organizer saves them; topics propose them.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                Toggle("Auto-tidy", isOn: $autoTidy).padding(.top, 6)
                Text("Let the organizer rename, archive and merge topics itself. Off: it only suggests.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            .toggleStyle(.switch)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            text = space.instructions ?? ""
            memory = space.space?.memory ?? true
            autoTidy = space.space?.autoTidy ?? false
            organizer = space.space?.organizerModel ?? space.model
            topics = space.model
        }
        .popover(item: $picking) { which in
            ModelPicker(engine: engine, selected: which == .organizer ? organizer : topics) { ref in
                if which == .organizer { organizer = ref } else { topics = ref }
                picking = nil
            }
            .frame(width: 420, height: 380)
        }
    }

    private func modelRow(_ title: String, detail: String, model: ModelRef?, pick: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            Spacer()
            Button(engine.model(model)?.name ?? model?.id ?? "Default") { pick() }.buttonStyle(PillStyle(compact: true))
        }
    }

    private func save() {
        let original = space
        let params = SpaceConfigureParams(
            ref: space.ref,
            instructions: text == (original.instructions ?? "") ? nil : text,
            organizerModel: organizer == (original.space?.organizerModel ?? original.model) ? nil : organizer,
            topicModel: topics == original.model ? nil : topics,
            memory: memory == (original.space?.memory ?? true) ? nil : memory,
            autoTidy: autoTidy == (original.space?.autoTidy ?? false) ? nil : autoTidy
        )
        run {
            try await engine.spaceCall("spaces.configure", params)
            dismiss()
        }
    }
}

/// The Space's memory (S8): a markdown editor, and the history of changes with who made them.
struct MemoryEditorSheet: View {
    let engine: EngineController
    let space: SessionSummary
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saved = ""
    @State private var revisions: [MemoryRevision] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(space.title): memory").font(.system(size: 15, weight: .semibold))
                    Text("Facts every topic reads. `## Heading` for sections, `- ` for each fact.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut("s").disabled(text == saved)
            }
            .padding(16)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                Rectangle().fill(Color.dsLine).frame(width: 0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("History")
                        if revisions.isEmpty { Text("No changes yet.").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                        ForEach(revisions) { r in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.summary).font(.system(size: 12.5)).foregroundStyle(r.undone == true ? Color.dsFg3 : Color.dsFg).strikethrough(r.undone == true)
                                HStack(spacing: 6) {
                                    Text("\(author(r)) · \(BuildSessionView.relative(r.at))").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                                    Button("Restore") { restore(r) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                                        .help("Put the memory back as it was after this change")
                                }
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 260)
            }
        }
        .frame(width: 820, height: 560)
        .background(Color.dsWin)
        .task { await load() }
    }

    private func author(_ r: MemoryRevision) -> String {
        switch r.by.kind {
        case "organizer": "Organizer"
        case "topic": r.by.title ?? "A topic"
        default: "You"
        }
    }

    private func load() async {
        guard let memory = await engine.memory(of: space.ref) else { return }
        text = memory.text
        saved = memory.text
        revisions = memory.revisions
    }

    private func save() {
        run {
            try await engine.spaceCall("spaces.memory.set", MemorySetParams(ref: space.ref, text: text))
            await load()
        }
    }

    private func restore(_ r: MemoryRevision) {
        run {
            try await engine.spaceCall("spaces.memory.restore", RevisionParams(ref: space.ref, revisionId: r.id))
            await load()
        }
    }
}

/// Space files: documents every topic can read (PDFs are read as text when added).
struct SpaceFilesSheet: View {
    let engine: EngineController
    let space: SessionSummary
    @Environment(\.dismiss) private var dismiss
    @State private var files: [SpaceFile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(space.title): files").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Add Files…") { add() }.buttonStyle(PillStyle(compact: true))
                Button("Done") { dismiss() }.buttonStyle(PillStyle(kind: .primary, compact: true)).keyboardShortcut(.defaultAction)
            }
            Text("Every topic and the organizer can list, read and search these.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            if files.isEmpty {
                Text("No files yet.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(files) { file in
                    HStack {
                        Image(systemName: file.name.hasSuffix(".pdf") ? "doc.richtext" : "doc.text").foregroundStyle(Color.dsFg3)
                        Text(file.name).font(.system(size: 13))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                        Button { remove(file) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Remove")
                    }
                }
                .frame(minHeight: 200)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { files = await engine.spaceFiles(space.ref) }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        run {
            for url in urls {
                // Documents the engine can't read itself (PDFs) go with their text.
                let extracted: String? = if url.pathExtension.lowercased() == "pdf", let loaded = try? AttachmentLoader.load(url), case .text(_, _, let text) = loaded.attachment { text } else { nil }
                try await engine.spaceCall("spaces.files.add", SpaceFileAddParams(ref: space.ref, name: url.lastPathComponent, path: url.path, extracted: extracted))
            }
            files = await engine.spaceFiles(space.ref)
        }
    }

    private func remove(_ file: SpaceFile) {
        run {
            try await engine.spaceCall("spaces.files.remove", SpaceFileParams(ref: space.ref, name: file.name))
            files = await engine.spaceFiles(space.ref)
        }
    }
}

// MARK: Space view

/// A Space (docs/design 2b): header, the topic capsules (Main first), the selected conversation and the composer.
struct SpaceView: View {
    let engine: EngineController
    let space: SessionSummary
    let topicId: String?
    let thread: ThreadModel
    @Binding var selection: String?
    @State private var showMemory = false
    @State private var showFiles = false
    @AppStorage("spaceInspector") private var showInspector = true

    private var topics: [TopicInfo] { space.activeTopics }
    private var topic: TopicInfo? { topics.first { $0.id == topicId } }

    var body: some View {
        HStack(spacing: 0) {
            conversation
            if showInspector {
                SpaceInspector(engine: engine, space: space, selection: $selection, showMemory: $showMemory)
                    .frame(width: 270)
                    .glassPanel()
                    .padding(8)
            }
        }
        .sheet(isPresented: $showMemory) { MemoryEditorSheet(engine: engine, space: space) }
        .sheet(isPresented: $showFiles) { SpaceFilesSheet(engine: engine, space: space) }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            header
            capsules
            ZStack(alignment: .bottom) {
                TranscriptView(document: thread.document)
                VStack(spacing: 8) {
                    if !thread.isFollowing {
                        Button { thread.scrollToLatest() } label: {
                            Label("Jump to latest", systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(PillStyle(kind: .toolbar, compact: true))
                    }
                    Composer(engine: engine, thread: thread)
                        .frame(maxWidth: 636)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }
            }
        }
        .task { await thread.open() }
        // Looking at a topic reads its replies.
        .onAppear { engine.markRead(thread.ref) }
        .onChange(of: topic?.unread) { _, unread in if unread == true { engine.markRead(thread.ref) } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(space.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            Spacer(minLength: 12)
            if space.space?.memory != false {
                Button("Memory") { showMemory = true }.buttonStyle(PillStyle(kind: .toolbar)).help("Facts every topic reads, and their history")
            }
            Button("Files") { showFiles = true }.buttonStyle(PillStyle(kind: .toolbar)).help("Documents every topic can read")
            Button { withAnimation(.easeOut(duration: 0.15)) { showInspector.toggle() } } label: {
                Image(systemName: "sidebar.right").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(PillStyle(kind: .toolbar))
            .help(showInspector ? "Hide topics and memory" : "Show topics and memory")
            Menu {
                SpaceMenu(engine: engine, space: space, selection: $selection)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(PillStyle(kind: .toolbar))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Rename, instructions, delete")
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 60)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var subtitle: String {
        var parts = ["Space", topics.count == 1 ? "1 topic" : "\(topics.count) topics"]
        if let info = space.space {
            if info.memory, info.memoryLines > 0 { parts.append(info.memoryLines == 1 ? "1 memory" : "\(info.memoryLines) memories") }
            if info.files > 0 { parts.append(info.files == 1 ? "1 file" : "\(info.files) files") }
            if info.costUsd > 0 { parts.append(info.costUsd < 0.01 ? String(format: "$%.4f", info.costUsd) : String(format: "$%.2f", info.costUsd)) }
        }
        if let topic { parts.append(topic.title) }
        if thread.state?.status == .running { parts.append(topicId == nil ? "organizing…" : "answering…") }
        return parts.joined(separator: " · ")
    }

    /// Main, then the topics; + Topic starts one (/new in Main).
    private var capsules: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                capsule("Main", selected: topicId == nil, unread: false) { selection = space.ref.id }
                ForEach(topics) { t in
                    capsule(t.title, selected: topicId == t.id, unread: t.unread == true) { selection = space.ref(topic: t.id).key }
                        .contextMenu { TopicMenu(engine: engine, space: space, topic: t, selection: $selection) }
                }
                Button { newTopic() } label: {
                    Text("+ Topic").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).padding(.horizontal, 10).frame(height: 26)
                }
                .buttonStyle(.plain)
                .help("Start a topic yourself")
            }
            .padding(.horizontal, 24)
        }
        .frame(height: 34)
        .padding(.bottom, 4)
    }

    private func capsule(_ title: String, selected: Bool, unread: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if unread { Circle().fill(Color.accentColor).frame(width: 5, height: 5) }
            }
            .foregroundStyle(selected ? Color.dsWin : Color.dsFg)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(selected ? Color.dsFg : Color.dsChip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func newTopic() {
        let alert = NSAlert()
        alert.messageText = "New topic in \(space.title)"
        alert.informativeText = "Your first message there is optional; you can also write to it later."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Topic title"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let main = engine.thread(space.ref)
        Task {
            await main.send("/new \(title)")
            try? await Task.sleep(for: .milliseconds(400))
            if let created = engine.space(space.ref.id)?.topics?.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                selection = space.ref(topic: created.id).key
            }
        }
    }
}

/// The Space's inspector (docs/design 2b): topics with where they stand, then the latest memory changes.
struct SpaceInspector: View {
    let engine: EngineController
    let space: SessionSummary
    @Binding var selection: String?
    @Binding var showMemory: Bool
    @State private var recent: [MemoryRevision] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Topics").font(.system(size: 13, weight: .semibold))
                ForEach(space.activeTopics) { topic in
                    Button { selection = space.ref(topic: topic.id).key } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(topic.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg).lineLimit(1)
                                Spacer()
                                Text(BuildSessionView.relative(topic.lastActiveAt)).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                            }
                            if let line = topic.summary ?? topic.brief {
                                Text(line).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { selection = space.ref.id } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Main").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg)
                        Text("Front door; routes to topics").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if space.space?.memory != false {
                    HStack {
                        Text("Recent memory").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("All \(space.space?.memoryLines ?? 0)") { showMemory = true }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    }
                    .padding(.top, 10)
                    if recent.isEmpty { Text("Nothing remembered yet.").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                    ForEach(recent.prefix(4)) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.summary).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).lineLimit(3)
                            Text("\(r.by.kind == "organizer" ? "Main" : r.by.title ?? "You") · \(BuildSessionView.relative(r.at))").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: space.space?.memoryLines) { recent = (await engine.memory(of: space.ref))?.revisions.filter { $0.undone != true } ?? [] }
    }
}
