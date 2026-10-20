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
                ForEach(space.topics ?? []) { topic in
                    topicRow(space, topic)
                }
            }
        }
    }

    private func spaceRow(_ space: SessionSummary, open: Bool) -> some View {
        let selected = selection == space.ref.id
        let unread = space.topics?.contains { $0.unread == true } ?? false
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
    }
}

/// Rename, instructions and delete, for the sidebar row and the Space header.
struct SpaceMenu: View {
    let engine: EngineController
    let space: SessionSummary
    @Binding var selection: String?

    var body: some View {
        Button("Rename…") { rename() }
        Button("Edit Instructions…") { NotificationCenter.default.post(name: .editSpaceInstructions, object: space.ref.id) }
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

struct SpaceInstructionsSheet: View {
    let engine: EngineController
    let space: SessionSummary
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(space.title): instructions").font(.system(size: 15, weight: .semibold))
            InstructionsField(text: $text)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { await engine.setInstructions(text, for: space.ref); dismiss() }
                }
                .buttonStyle(PillStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { text = space.instructions ?? "" }
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

    private var topics: [TopicInfo] { space.topics ?? [] }
    private var topic: TopicInfo? { topics.first { $0.id == topicId } }

    var body: some View {
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
