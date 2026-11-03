import PiopioKit
import PiopioTranscript
import SwiftUI

// Start pages (docs/design/start-pages): each sidebar + opens a page for that kind in the main window, the way a new
// conversation starts in ChatGPT or Claude. Nothing is created until you start; what you type is kept as a draft.

// MARK: Drafts

/// What each start page holds while you write, saved under the engine home so it survives a relaunch.
@MainActor @Observable final class StartDrafts {
    static let shared = StartDrafts()

    struct Draft: Codable, Equatable {
        /// The message (chat), the goal (debate) or the first note or message (notebook, agent).
        var text = ""
        /// A notebook's or an agent's name.
        var name = ""
        var criteria = ""
        var instructions = ""
        var avatar = ""
        var template: String?
        /// Chats to bring into a new notebook as topics.
        var threads: [String] = []

        init() {}

        /// Missing fields keep their defaults, so a draft saved by another version still opens.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            criteria = try c.decodeIfPresent(String.self, forKey: .criteria) ?? ""
            instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
            avatar = try c.decodeIfPresent(String.self, forKey: .avatar) ?? ""
            template = try c.decodeIfPresent(String.self, forKey: .template)
            threads = try c.decodeIfPresent([String].self, forKey: .threads) ?? []
        }
    }

    private var drafts: [String: Draft] = [:]
    private let url: URL

    init(home: URL = EngineClient.defaultHome()) {
        url = home.appending(path: "drafts/start.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Draft].self, from: data) { drafts = saved }
    }

    subscript(kind: StartKind) -> Draft { drafts[kind.rawValue] ?? Draft() }

    func update(_ kind: StartKind, _ change: (inout Draft) -> Void) {
        var draft = self[kind]
        change(&draft)
        guard draft != self[kind] else { return }
        drafts[kind.rawValue] = draft == Draft() ? nil : draft
        save()
    }

    func binding(_ kind: StartKind, _ field: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(get: { self[kind][keyPath: field] }, set: { value in self.update(kind) { $0[keyPath: field] = value } })
    }

    func clear(_ kind: StartKind) {
        guard drafts[kind.rawValue] != nil else { return }
        drafts[kind.rawValue] = nil
        save()
    }

    /// Something typed, so the sidebar keeps a draft row for it.
    func hasContent(_ kind: StartKind) -> Bool {
        let d = self[kind]
        return !(d.text + d.name + d.criteria + d.instructions).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The draft row's title: the name typed so far, or "New notebook".
    func title(_ kind: StartKind) -> String {
        let name = self[kind].name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? kind.title : name
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(drafts).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {}
    }
}

extension StartKind {
    var title: String {
        switch self {
        case .chat: "New chat"
        case .debate: "New debate"
        case .notebook: "New notebook"
        case .agent: "New agent"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left"
        case .debate: "person.2"
        case .notebook: "book.closed"
        case .agent: "smallcircle.circle"
        }
    }
}

// MARK: Page

/// The start page for one kind: a heading, the composer, and only what that kind needs below it.
struct StartView: View {
    let engine: EngineController
    let kind: StartKind
    @Binding var item: SidebarItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch kind {
                case .chat: ChatStart(engine: engine, item: $item)
                case .debate: DebateStart(engine: engine, item: $item)
                case .notebook: NotebookStart(engine: engine, item: $item)
                case .agent: AgentStart(engine: engine, item: $item)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 96)
            .padding(.bottom, 48)
            .frame(maxWidth: 692)
            .frame(maxWidth: .infinity)
        }
        .id(kind)
    }
}

// MARK: Shared parts

private struct StartHeading: View {
    let title: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.6).foregroundStyle(Color.dsFg)
            StartHint(text: hint)
        }
    }
}

private struct StartHint: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true).padding(.bottom, 20)
    }
}

/// A notebook's or an agent's name, typed in place as the page's heading.
private struct NameField: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<StartField?>.Binding
    let onSubmit: () -> Void

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.dsFg3))
            .textFieldStyle(.plain)
            .font(.system(size: 26, weight: .bold))
            .tracking(-0.6)
            .foregroundStyle(Color.dsFg)
            .focused(focused, equals: .name)
            .onSubmit(onSubmit)
            .accessibilityLabel(placeholder)
    }
}

enum StartField: Hashable { case name, text, criteria }

/// The composer's text: 14pt, growing to eight lines.
private struct StartText: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<StartField?>.Binding
    var field: StartField = .text
    let onSubmit: () -> Void

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.dsFg3), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(2...8)
            .focused(focused, equals: field)
            .onSubmit(onSubmit)
            .accessibilityLabel(placeholder)
    }
}

/// The page's one black action ("Start ⌘↩", "Create ↩"), with a spinner while it works.
private struct StartButton: View {
    let title: String
    let busy: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini) }
                Text(title)
            }
        }
        .buttonStyle(PillStyle(kind: .primary, compact: true))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!enabled || busy)
    }
}

/// What went wrong, that nothing was lost, under the box.
private struct StartError: View {
    let text: String?
    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.circle").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
    }
}

/// A plain row to pick: a check box or a radio, the name, and a grey note.
private struct PickRow: View {
    enum Mark { case check, radio }
    let mark: Mark
    let on: Bool
    let title: String
    var note = ""
    var trailing = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                indicator
                Text(title).font(.system(size: 13.5)).foregroundStyle(Color.dsFg).lineLimit(1)
                if !note.isEmpty { Text(note).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).lineLimit(1) }
                Spacer(minLength: 12)
                if !trailing.isEmpty { Text(trailing).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1) }
            }
            .frame(height: 34)
            .padding(.horizontal, 8)
            .background(hovering ? Color.dsChip.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .padding(.horizontal, -8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var indicator: some View {
        switch mark {
        case .check:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(on ? Color.dsInv : .clear)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(on ? Color.dsInv : Color.dsFg3, lineWidth: 1))
                .overlay { if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.dsInvFg) } }
                .frame(width: 14, height: 14)
        case .radio:
            Circle().strokeBorder(on ? Color.dsInv : Color.dsFg3, lineWidth: on ? 4 : 1).frame(width: 14, height: 14)
        }
    }
}

private struct SectionCaption: View {
    let title: String
    var trailing = ""
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            Spacer()
            if !trailing.isEmpty { Text(trailing).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
        }
        .padding(.top, 28)
        .padding(.bottom, 4)
    }
}

private struct LinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action).buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.accentColor)
    }
}

// MARK: Chat

/// New chat: a heading and the composer. The chat is created with the first message.
private struct ChatStart: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    private var drafts: StartDrafts { .shared }
    @State private var attachments: [PendingAttachment] = []
    @State private var model: ModelRef?
    @State private var showModels = false
    @State private var sending = false
    @State private var error: String?
    /// The chat made for a message that then failed to send, so Retry doesn't make another.
    @State private var pending: ContainerRef?
    @FocusState private var focus: StartField?

    private var text: String { drafts[.chat].text }
    private var canSend: Bool { !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        StartHeading(title: "What's on your mind?", hint: "A chat keeps its own history. You can move it into a notebook later.")
        VStack(alignment: .leading, spacing: 10) {
            StartText(placeholder: "Ask anything…", text: drafts.binding(.chat, \.text), focused: $focus, onSubmit: send)
            if !attachments.isEmpty { attachmentTiles }
            HStack(spacing: 4) {
                Button(action: attach) { Image(systemName: "plus").font(.system(size: 13)) }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .help("Attach images, PDFs or text files").accessibilityLabel("Attach files")
                Spacer()
                Button { showModels = true } label: { Text(modelLabel) }
                    .buttonStyle(ChipStyle())
                    .popover(isPresented: $showModels, arrowEdge: .bottom) {
                        ModelPicker(engine: engine, selected: model ?? engine.preferredModel) { m in model = m; showModels = false }
                    }
                SendButton(enabled: canSend, action: send)
                    .accessibilityLabel("Send")
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, -6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .composerBox()
        StartError(text: error)
        HStack(spacing: 4) {
            Text("Want two models to work on it until they agree?").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
            LinkButton(title: "Start a debate") { toDebate(drafts[.chat].text) }
        }
        .padding(.top, 18)
        Text("Tip: \(QuickChatShortcut.current.label) opens Quick Chat from any app.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 8)
            .onAppear { focus = .text }
            .onChange(of: text) { _, t in
                // "/debate" turns the page into a debate, with what follows as the goal.
                if t.hasPrefix("/debate") { toDebate(String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces)) }
            }
    }

    private var modelLabel: String {
        let ref = model ?? engine.preferredModel
        return engine.model(ref).map(ModelChip.short) ?? ref?.id ?? "Model"
    }

    private var attachmentTiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { a in
                    HStack(spacing: 6) {
                        Text(a.name).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).lineLimit(1)
                        Button { attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.dsFg3) }
                            .buttonStyle(.plain).accessibilityLabel("Remove attachment \(a.name)")
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
                }
            }
        }
    }

    private func toDebate(_ goal: String) {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        drafts.update(.chat) { $0.text = "" }
        if !goal.isEmpty { drafts.update(.debate) { $0.text = goal } }
        item = .start(.debate)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { attachments.append(try AttachmentLoader.load(url)) } catch { self.error = error.localizedDescription }
        }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !message.isEmpty else { return }
        error = nil
        sending = true
        Task {
            defer { sending = false }
            let created: ContainerRef?
            if let pending { created = pending } else { created = await engine.createThread(model: model) }
            guard let ref = created else {
                error = "Couldn't start the chat because the engine isn't connected. Nothing was created, and your message is kept."
                return
            }
            pending = ref
            let thread = engine.thread(ref)
            await thread.open()
            if await thread.send(message, attachments: attachments.map(\.attachment)) {
                drafts.clear(.chat)
                attachments = []
                pending = nil
                try? await engine.refreshCatalog()
                item = .chat(ref.id)
            } else {
                error = (thread.error ?? "Couldn't send.") + " Your message is kept; try again."
            }
        }
    }
}

// MARK: Debate

/// New debate (docs/spec/16 §5): the goal is the message, what a good result needs is a second line in the box, and
/// the setup is one line of selectors under it: who writes, who reviews, how many rounds, and what it may cost.
private struct DebateStart: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    private var drafts: StartDrafts { .shared }
    @State private var author: ModelRef?
    @State private var reviewer: ModelRef?
    @AppStorage("debate.rounds") private var rounds = 6
    @State private var picking: DebateRole?
    @State private var starting = false
    @State private var error: String?
    @AppStorage("debate.reviewer") private var lastReviewer = ""
    @FocusState private var focus: StartField?

    private var goal: String { drafts[.debate].text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canStart: Bool { !goal.isEmpty && author != nil && reviewer != nil }

    var body: some View {
        StartHeading(title: "What should they work on?", hint: "One model writes, the other reviews it against your goal, round after round, until the reviewer approves or the rounds run out.")
        VStack(alignment: .leading, spacing: 10) {
            StartText(placeholder: "The goal: what should come out of it, and for whom", text: drafts.binding(.debate, \.text), focused: $focus, onSubmit: {})
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text("A good result must… (optional)").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                StartText(placeholder: "Cover rollback. Stay under 600 words. No vendor marketing.", text: drafts.binding(.debate, \.criteria), focused: $focus, field: .criteria, onSubmit: {})
                    .lineLimit(1...4)
                    .help("The reviewer checks every draft against this.")
            }
            HStack {
                Spacer()
                StartButton(title: "Start ⌘↩", busy: starting, enabled: canStart) { Task { await start() } }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .composerBox()
        HStack(spacing: 6) {
            participant(.author, "writes", $author)
            Text("·").foregroundStyle(Color.dsFg3)
            participant(.reviewer, "reviews", $reviewer)
            Text("·").foregroundStyle(Color.dsFg3)
            Menu {
                ForEach(2...12, id: \.self) { n in Button("\(n) rounds") { rounds = n } }
            } label: { Text("up to \(rounds) rounds") }
                .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.hidden).fixedSize()
                .help("It stops sooner when the reviewer approves.")
            Spacer(minLength: 8)
            if let estimate {
                Text("about \(estimate) at most").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    .help("A rough estimate for a one-page draft; it stops sooner when the reviewer approves.")
            }
        }
        .font(.system(size: 12.5))
        .padding(.top, 12)
        if let author, let reviewer, family(author) == family(reviewer) {
            Label("Models from different makers catch more of each other's blind spots.", systemImage: "lightbulb")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 8)
        }
        StartError(text: error)
        HStack(spacing: 4) {
            Text("Just want an answer?").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
            LinkButton(title: "Chat instead") {
                // The goal becomes the message; the debate draft (criteria too) goes, so no stray draft row is left.
                let text = drafts[.debate].text
                drafts.clear(.debate)
                if !text.isEmpty { drafts.update(.chat) { $0.text = text } }
                item = .start(.chat)
            }
        }
        .padding(.top, 18)
        .onAppear {
            defaults()
            focus = .text
        }
    }

    private func participant(_ role: DebateRole, _ verb: String, _ model: Binding<ModelRef?>) -> some View {
        Button { picking = role } label: {
            HStack(spacing: 4) {
                Text(engine.model(model.wrappedValue).map(ModelChip.short) ?? model.wrappedValue?.id ?? "Choose a model").foregroundStyle(Color.dsFg)
                Text(verb)
            }
        }
        .buttonStyle(ChipStyle())
        .help(role == .author ? "The model that writes each draft" : "The model that reviews each draft against your goal")
        .popover(isPresented: Binding(get: { picking == role }, set: { if !$0 { picking = nil } }), arrowEdge: .bottom) {
            ModelPicker(engine: engine, selected: model.wrappedValue) { m in model.wrappedValue = m; picking = nil }
        }
    }

    /// The maker: "anthropic" in "anthropic/claude-…", else the provider.
    private func family(_ m: ModelRef) -> String {
        m.id.contains("/") ? String(m.id.split(separator: "/")[0]) : m.provider
    }

    /// The Chat model writes; the last reviewer reviews, or a model from another maker.
    private func defaults() {
        author = author ?? engine.preferredModel
        guard reviewer == nil else { return }
        let parts = lastReviewer.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2, engine.model(ModelRef(provider: parts[0], id: parts[1])) != nil {
            reviewer = ModelRef(provider: parts[0], id: parts[1])
        } else if let author {
            let other = engine.models.first { family(ModelRef(provider: $0.provider, id: $0.id)) != family(author) && $0.provider != "faux" }
            reviewer = other.map { ModelRef(provider: $0.provider, id: $0.id) } ?? author
        }
    }

    /// Up to `rounds` rounds of a one-page draft: each side's context grows by one exchange a round.
    private var estimate: String? {
        guard let a = engine.model(author), let r = engine.model(reviewer) else { return nil }
        var usd = 0.0
        for round in 1...rounds {
            let n = Double(round)
            usd += (2_000 + n * 2_200) * a.pricing.input / 1e6 + 1_400 * a.pricing.output / 1e6
            usd += (3_000 + n * 1_200) * r.pricing.input / 1e6 + 600 * r.pricing.output / 1e6
        }
        guard usd > 0 else { return nil }
        return usd < 0.01 ? "<$0.01" : String(format: "$%.2f", usd)
    }

    private func start() async {
        guard canStart, let author, let reviewer, !starting else { return }
        starting = true
        error = nil
        defer { starting = false }
        let criteria = drafts[.debate].criteria.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = DebateConfig(
            goal: goal,
            criteria: criteria.isEmpty ? nil : criteria,
            participants: [.init(role: .author, model: author), .init(role: .reviewer, model: reviewer)],
            maxRounds: rounds
        )
        do {
            let ref = try await engine.createDebate(config)
            lastReviewer = "\(reviewer.provider)|\(reviewer.id)"
            drafts.clear(.debate)
            item = .chat(ref.id)
        } catch {
            self.error = ((error as? EngineError)?.message ?? error.localizedDescription) + " Nothing was started, and your goal is kept."
        }
    }
}

// MARK: Notebook

/// New notebook (docs/spec/04 S5): the name as the heading, an optional first note for Main, instructions, and chats
/// to bring in as topics. The name is required.
private struct NotebookStart: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    private var drafts: StartDrafts { .shared }
    @State private var showInstructions = false
    @State private var showAllChats = false
    @State private var creating = false
    @State private var error: String?
    @FocusState private var focus: StartField?

    private var draft: StartDrafts.Draft { drafts[.notebook] }
    private var name: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NameField(placeholder: "Name this notebook", text: drafts.binding(.notebook, \.name), focused: $focus) { focus = .text }
            .padding(.bottom, 6)
        StartHint(text: "A notebook keeps one subject together. You write in Main, and the organizer files each message under the right topic, or starts one.")
        VStack(alignment: .leading, spacing: 10) {
            StartText(placeholder: "First note for Main (optional)…", text: drafts.binding(.notebook, \.text), focused: $focus, onSubmit: create)
            HStack {
                Spacer()
                StartButton(title: "Create ⌘↩", busy: creating, enabled: !name.isEmpty, action: create)
                    .help(name.isEmpty ? "Name the notebook first" : "Create the notebook")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .composerBox()
        StartError(text: error)
        instructions
        chats
            .onAppear {
                focus = name.isEmpty ? .name : .text
                showInstructions = !draft.instructions.isEmpty
            }
    }

    @ViewBuilder private var instructions: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { showInstructions.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(showInstructions ? 90 : 0))
                Text("Instructions for every agent in this notebook").foregroundStyle(Color.dsFg2)
                Text("· optional").foregroundStyle(Color.dsFg3)
            }
            .font(.system(size: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 20)
        if showInstructions {
            InstructionsField(text: drafts.binding(.notebook, \.instructions), title: nil).padding(.top, 8)
        }
    }

    @ViewBuilder private var chats: some View {
        let selected = Set(draft.threads)
        let recent = engine.threads.sorted { $0.updatedAt > $1.updatedAt }
        if !recent.isEmpty {
            // The five most recent, plus any already ticked.
            let shown = showAllChats ? recent : recent.enumerated().filter { $0.offset < 5 || selected.contains($0.element.ref.id) }.map(\.element)
            SectionCaption(title: "Bring in chats as topics", trailing: selected.isEmpty ? "" : "\(selected.count) selected")
            ForEach(shown, id: \.ref.id) { thread in
                PickRow(mark: .check, on: selected.contains(thread.ref.id), title: thread.title, trailing: "\(thread.debate != nil ? "Debate" : "Chat") · \(HomeView.age(thread.updatedAt))") {
                    drafts.update(.notebook) { d in
                        if let i = d.threads.firstIndex(of: thread.ref.id) { d.threads.remove(at: i) } else { d.threads.append(thread.ref.id) }
                    }
                }
            }
            if shown.count < recent.count {
                LinkButton(title: "Show all \(recent.count) chats") { showAllChats = true }.padding(.top, 6)
            }
            Text("Each becomes a topic with its whole conversation, and the chat moves into the notebook.")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 8)
        }
    }

    private func create() {
        guard !name.isEmpty, !creating else { return }
        creating = true
        error = nil
        let note = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = draft.threads
        Task {
            defer { creating = false }
            guard let ref = await engine.createSpace(name: name, instructions: draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                error = "Couldn't create the notebook because the engine isn't connected. Nothing was created, and what you typed is kept."
                return
            }
            let moving = engine.threads.filter { picked.contains($0.ref.id) }.map(\.ref)
            let topics = moving.isEmpty ? [] : ((try? await engine.importThreads(moving, into: ref)) ?? [])
            if !note.isEmpty {
                let main = engine.thread(ContainerRef(kind: .space, id: ref.id))
                await main.open()
                _ = await main.send(note)
            }
            // Cleared only now, so the page doesn't flash empty while chats move in.
            drafts.clear(.notebook)
            item = .notebook(note.isEmpty ? topics.first.map { ContainerRef(kind: .space, id: ref.id, conversationId: $0).key } ?? ref.id : ref.id)
        }
    }
}

// MARK: Agent

/// New agent: avatar and name as the heading, a template to start from, and an optional first message sent once it
/// exists. The name is required.
private struct AgentStart: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    private var drafts: StartDrafts { .shared }
    @State private var templates: [AgentTemplate] = []
    @State private var creating = false
    @State private var error: String?
    @FocusState private var focus: StartField?

    private var draft: StartDrafts.Draft { drafts[.agent] }
    private var name: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 12) {
            AvatarPicker(avatar: drafts.binding(.agent, \.avatar))
            NameField(placeholder: "Name your agent", text: drafts.binding(.agent, \.name), focused: $focus) { focus = .text }
        }
        .padding(.bottom, 6)
        StartHint(text: "Agents run on a schedule, remember what you teach them and reach you when something matters. This one runs on this Mac.")
        VStack(alignment: .leading, spacing: 10) {
            StartText(placeholder: "First message (optional): what you want from it, in your words…", text: drafts.binding(.agent, \.text), focused: $focus, onSubmit: create)
            HStack {
                Spacer()
                StartButton(title: "Create ⌘↩", busy: creating, enabled: !name.isEmpty, action: create)
                    .help(name.isEmpty ? "Name the agent first" : "Create the agent")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .composerBox()
        StartError(text: error)
        SectionCaption(title: "Start from")
        ForEach(ordered) { t in
            PickRow(mark: .radio, on: draft.template == t.id, title: "\(t.avatar)  \(t.name)", note: t.description) { pick(t) }
        }
        PickRow(mark: .radio, on: draft.template == nil, title: "From scratch", note: "Instructions you write") { pick(nil) }
            .task {
                templates = await engine.agentTemplates()
                focus = name.isEmpty ? .name : .text
            }
    }

    /// A briefing, a coach and a watcher first (as in Agents' first run).
    private var ordered: [AgentTemplate] {
        let order = ["daily-briefing", "habit-coach", "research-watcher"]
        return templates.sorted { (order.firstIndex(of: $0.id) ?? 9) < (order.firstIndex(of: $1.id) ?? 9) }
    }

    /// A template fills the name and avatar, unless you typed your own.
    private func pick(_ t: AgentTemplate?) {
        drafts.update(.agent) { d in
            let typedOwn = !d.name.isEmpty && !templates.contains { $0.name == d.name }
            d.template = t?.id
            if !typedOwn { d.name = t?.name ?? "" }
            if d.avatar.isEmpty || templates.contains(where: { $0.avatar == d.avatar }) { d.avatar = t?.avatar ?? "" }
        }
    }

    private func create() {
        guard !name.isEmpty, !creating else { return }
        creating = true
        error = nil
        let message = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { creating = false }
            do {
                let ref = try await engine.createAgent(name: name, template: draft.template, avatar: draft.avatar.trimmingCharacters(in: .whitespaces))
                if !message.isEmpty {
                    let thread = engine.thread(ContainerRef(kind: .agent, id: ref.id))
                    await thread.open()
                    _ = await thread.send(message)
                }
                UserDefaults.standard.set("Chat", forKey: "agentTab")
                drafts.clear(.agent)
                item = .agent(ref.id)
            } catch {
                self.error = ((error as? EngineError)?.message ?? String(describing: error)) + " Nothing was created, and what you typed is kept."
            }
        }
    }
}
