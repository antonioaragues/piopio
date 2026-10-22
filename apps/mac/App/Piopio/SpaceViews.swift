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
        Button("Promote to Thread") {
            run {
                if let thread = try await engine.promote(ref) { NotificationCenter.default.post(name: .selectThread, object: thread.id) }
            }
        }
        .help("Copies this topic out into a new thread; the topic stays")
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

/// Rename, settings, archived topics and delete, for the sidebar row and the Space header.
struct SpaceMenu: View {
    let engine: EngineController
    let space: SessionSummary
    @Binding var selection: String?

    var body: some View {
        Button("Rename…") { rename() }
        Button("Notebook Settings…") { NotificationCenter.default.post(name: .editSpaceInstructions, object: space.ref.id) }
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
        Button("Delete Notebook…", role: .destructive) {
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
        alert.messageText = "Rename Notebook"
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
    var preselected: Set<String> = []
    /// The selection to show: Main, or the first topic made from a thread.
    let created: (String) -> Void
    @State private var threads: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Notebook").font(.system(size: 17, weight: .bold))
            Text("A Notebook is a long-running area of your life or work. You write in Main; the organizer sends each message to the right topic, or starts one.")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
                TextField("Home renovation", text: $name).textFieldStyle(.roundedBorder)
            }
            InstructionsField(text: $instructions)
            if !engine.threads.isEmpty { ThreadPicker(threads: engine.threads, selected: $threads) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create Notebook") {
                    creating = true
                    Task {
                        if let ref = await engine.createSpace(name: name.trimmingCharacters(in: .whitespaces), instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            let moving = engine.threads.filter { threads.contains($0.ref.id) }.map(\.ref)
                            let topics = moving.isEmpty ? [] : ((try? await engine.importThreads(moving, into: ref)) ?? [])
                            created(topics.first.map { ContainerRef(kind: .space, id: ref.id, conversationId: $0).key } ?? ref.id)
                        }
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
        .onAppear { threads = preselected }
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
            Text("Every agent in the Notebook is told this: who you are, what matters, how to answer.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
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
            if ProcessInfo.processInfo.environment["PIOPIO_DEMO_SPACE_SETTINGS"] == "picker" {
                Task { try? await Task.sleep(for: .seconds(1)); picking = .topics }
            }
        }
        .popover(item: $picking) { which in
            ModelPicker(engine: engine, selected: which == .organizer ? organizer : topics) { ref in
                if which == .organizer { organizer = ref } else { topics = ref }
                picking = nil
            }
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
    @State private var proposals: [MemoryResult.Proposal] = []
    @AppStorage("memoryMode") private var mode: Mode = .facts
    @State private var selected: Int?
    @State private var editing: Int?
    @State private var draft = ""
    @State private var adding = ""

    enum Mode: String, CaseIterable { case facts = "Facts", markdown = "Markdown" }

    /// One `- fact` line: its label (a "Label: …" prefix, or its section), the text, and where it sits.
    struct Fact { let line: Int; let label: String; let text: String; let raw: String }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory").font(.system(size: 20, weight: .bold))
                    Text("\(space.title) · every topic reads these facts").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                if mode == .markdown, text != saved {
                    Button("Save") { save(text) }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut("s")
                }
                Button("Done") { dismiss() }.buttonStyle(PillStyle(kind: .strong)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack(spacing: 0) {
                if mode == .markdown {
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(14)
                } else {
                    factsList
                }
                Rectangle().fill(Color.dsLine).frame(width: 0.5)
                history.frame(width: 250)
            }
        }
        .frame(width: 880, height: 620)
        .background(Color.dsWin)
        .task { await load() }
    }

    // MARK: Facts

    private var facts: [Fact] {
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

    private var factsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { i, fact in
                        if i > 0 { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
                        factRow(fact)
                    }
                    if facts.isEmpty {
                        Text("Nothing remembered yet. Topics add facts as you talk; you can add your own below.")
                            .font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                    TextField("Add a fact every topic should know…", text: $adding).textFieldStyle(.plain).font(.system(size: 13)).onSubmit(add)
                }
                .padding(.horizontal, 14).frame(height: 38)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
                if !proposals.isEmpty {
                    Text("Suggested by topics").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3).padding(.top, 8)
                    ForEach(proposals) { p in suggestion(p) }
                }
            }
            .padding(22)
        }
    }

    private func factRow(_ fact: Fact) -> some View {
        let isSelected = selected == fact.line
        return HStack(alignment: .top, spacing: 12) {
            Text(fact.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3).frame(width: 64, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                if editing == fact.line {
                    TextField("", text: $draft).textFieldStyle(.roundedBorder).font(.system(size: 13.5)).onSubmit { replace(fact, with: draft) }
                } else {
                    Text(fact.text).font(.system(size: 13.5)).lineSpacing(3).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true)
                }
                Text(provenance(fact)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            Spacer(minLength: 8)
            if isSelected {
                if editing == fact.line {
                    Button("Save") { replace(fact, with: draft) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                } else {
                    Button("Edit") { draft = fact.raw; editing = fact.line }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                }
                Button("Forget") { forget(fact) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsRed)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(isSelected ? Color.dsAccentSoft : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if selected != fact.line { selected = fact.line; editing = nil } }
    }

    /// "From Main · Organizer · 20 h ago": the newest change that added it.
    private func provenance(_ fact: Fact) -> String {
        guard let r = revisions.first(where: { r in r.undone != true && r.added.contains { $0.contains(fact.text) || fact.raw.contains($0) } }) else { return "Added by you" }
        let who = switch r.by.kind {
        case "organizer": "From Main · Organizer"
        case "topic": "From \(r.by.title ?? "a topic")"
        default: "Added by you"
        }
        return "\(who) · \(BuildSessionView.relative(r.at))"
    }

    private func suggestion(_ p: MemoryResult.Proposal) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(p.added, id: \.self) { Text($0).font(.system(size: 13.5)).foregroundStyle(Color.dsFg) }
                ForEach(p.removed, id: \.self) { Text("Forget: \($0)").font(.system(size: 13.5)).foregroundStyle(Color.dsFg2) }
                Text("\(p.title) wants to remember this · \(BuildSessionView.relative(p.at))").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            Spacer()
            Button("Dismiss") { decide(p, false) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            Button("Save fact") { decide(p, true) }.buttonStyle(PillStyle(kind: .strong, compact: true))
        }
        .padding(14)
        .background(Color.dsYolkSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("History").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
                if revisions.isEmpty { Text("No changes yet.").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                ForEach(revisions) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.summary).font(.system(size: 12.5)).foregroundStyle(r.undone == true ? Color.dsFg3 : Color.dsFg).strikethrough(r.undone == true).lineLimit(3)
                        HStack(spacing: 4) {
                            Text("\(author(r)) · \(BuildSessionView.relative(r.at)) ·").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                            Button("Restore") { restore(r) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                                .help("Put the memory back as it was after this change")
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Changes

    private func lines() -> [String] { text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

    private func replace(_ fact: Fact, with value: String) {
        var l = lines()
        let v = value.trimmingCharacters(in: .whitespaces)
        guard l.indices.contains(fact.line), !v.isEmpty else { return }
        l[fact.line] = "- \(v)"
        editing = nil
        save(l.joined(separator: "\n"))
    }

    private func forget(_ fact: Fact) {
        var l = lines()
        guard l.indices.contains(fact.line) else { return }
        l.remove(at: fact.line)
        selected = nil
        save(l.joined(separator: "\n"))
    }

    private func add() {
        let fact = adding.trimmingCharacters(in: .whitespaces)
        guard !fact.isEmpty else { return }
        adding = ""
        var l = lines()
        if !l.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## notes" }) {
            if !(l.last ?? "").isEmpty, !text.isEmpty { l.append("") }
            l.append("## Notes")
        }
        let heading = l.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## notes" }!
        var at = heading + 1
        while at < l.count, !l[at].hasPrefix("## ") { at += 1 }
        while at > heading + 1, l[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
        l.insert("- \(fact)", at: at)
        save(l.joined(separator: "\n"))
    }

    private func decide(_ p: MemoryResult.Proposal, _ accept: Bool) {
        run {
            try await engine.spaceCall("spaces.memory.decide", DecideParams(ref: space.ref, proposalId: p.id, accept: accept))
            await load()
        }
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
        proposals = memory.proposals ?? []
    }

    private func save(_ next: String) {
        text = next
        run {
            try await engine.spaceCall("spaces.memory.set", MemorySetParams(ref: space.ref, text: next))
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
            Button("Files") { showFiles = true }.buttonStyle(PillStyle(kind: .toolbar)).help("Documents every topic can read")
            Button { withAnimation(.easeOut(duration: 0.15)) { showInspector.toggle() } } label: {
                Image(systemName: "sidebar.right").font(.system(size: 12, weight: .medium)).foregroundStyle(showInspector ? Color.accentColor : Color.dsFg)
                    .frame(width: 28, height: 28)
                    .background(showInspector ? Color.dsAccentSoft : Color.dsPill, in: Circle())
                    .overlay(Circle().strokeBorder(showInspector ? .clear : Color.dsLine, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(showInspector ? "Hide progress and memory" : "Show progress and memory")
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
        var parts = ["Notebook"]
        if let info = space.space {
            if info.costUsd > 0 { parts.append(info.costUsd < 0.01 ? String(format: "$%.4f", info.costUsd) : String(format: "$%.2f", info.costUsd)) }
            if info.files > 0 { parts.append(info.files == 1 ? "1 file" : "\(info.files) files") }
        }
        if thread.state?.status == .running { parts.append(topicId == nil ? "organizing…" : "answering…") }
        return parts.joined(separator: " · ")
    }

    /// Main, then the topics, as underlined tabs (docs/design v2, 4a); + Topic starts one (/new in Main).
    private var capsules: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    tab("Main", selected: topicId == nil, dot: nil) { selection = space.ref.id }
                    ForEach(topics) { t in
                        tab(t.title, selected: topicId == t.id, dot: t.running == true ? .accentColor : t.unread == true ? .accentColor : nil) { selection = space.ref(topic: t.id).key }
                            .contextMenu { TopicMenu(engine: engine, space: space, topic: t, selection: $selection) }
                    }
                    Button { newTopic() } label: {
                        Text("+ Topic").font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(.bottom, 8)
                    }
                    .buttonStyle(.plain)
                    .help("Start a topic yourself")
                }
                .padding(.horizontal, 24)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
        }
    }

    private func tab(_ title: String, selected: Bool, dot: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? Color.dsFg : Color.dsFg2).lineLimit(1)
                    if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                }
                Rectangle().fill(selected ? Color.accentColor : .clear).frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
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

/// The notebook's inspector (docs/design v2, 4a): progress across its topics, then a preview of its memory.
struct SpaceInspector: View {
    let engine: EngineController
    let space: SessionSummary
    @Binding var selection: String?
    @Binding var showMemory: Bool
    @State private var memoryText = ""

    private var topics: [TopicInfo] { space.activeTopics }
    /// A topic is settled when it has answered and nothing new waits to be read.
    private func settled(_ t: TopicInfo) -> Bool { t.running != true && t.unread != true && t.summary != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Progress").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !topics.isEmpty {
                        Text("\(topics.filter(settled).count) of \(topics.count) settled").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                }
                if !topics.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(topics) { t in
                            Capsule().fill(settled(t) ? Color.dsGreen : t.running == true || t.unread == true ? Color.dsAmber : Color.dsLine).frame(height: 4)
                        }
                    }
                }
                ForEach(Array(topics.enumerated()), id: \.element.id) { i, topic in
                    let selected = selection == space.ref(topic: topic.id).key
                    Button { selection = space.ref(topic: topic.id).key } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(i + 1) · \(topic.title)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                                Spacer()
                                Text(state(topic)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(topic.unread == true ? Color.dsAmber : Color.dsFg3)
                            }
                            if let line = topic.summary ?? topic.brief {
                                Text(line).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(2)
                            }
                        }
                        .padding(10)
                        .background(selected ? Color.dsCard : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(selected ? Color.dsLine : .clear, lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if topics.isEmpty {
                    Text("Write in Main: the organizer starts topics as subjects come up.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                if space.space?.memory != false {
                    Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.vertical, 6)
                    HStack {
                        Text("Memory").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("Open") { showMemory = true }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                    }
                    let facts = Self.preview(memoryText)
                    if facts.isEmpty { Text("Nothing remembered yet.").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                        HStack(alignment: .top) {
                            Text(f.0).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                            Spacer(minLength: 8)
                            Text(f.1).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsFg).multilineTextAlignment(.trailing).lineLimit(2)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: space.space?.memoryLines) { memoryText = (await engine.memory(of: space.ref))?.text ?? "" }
    }

    private func state(_ t: TopicInfo) -> String {
        if t.running == true { return "Working" }
        if t.unread == true { return "New reply" }
        return t.summary == nil ? "Waiting" : "Settled"
    }

    /// The first few facts as key/value pairs ("Size · 4 × 3 m"): a "Label: value" fact, or its first words.
    static func preview(_ text: String) -> [(String, String)] {
        text.split(separator: "\n").compactMap { line -> (String, String)? in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("- ") else { return nil }
            let body = l.dropFirst(2)
            if let colon = body.firstIndex(of: ":"), body.distance(from: body.startIndex, to: colon) <= 18 {
                return (String(body[..<colon]), String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
            let words = body.split(separator: " ")
            return (words.prefix(2).joined(separator: " "), words.dropFirst(2).joined(separator: " "))
        }
        .prefix(4)
        .map { $0 }
    }
}
