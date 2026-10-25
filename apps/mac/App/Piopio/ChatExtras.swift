import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Chat's cross-cutting pieces (milestone 3.4): moving threads into Spaces (04-chat S5, S11), the Thread → Space
// suggestion banner, and Settings › Chat (the "About me" memory, 07-shared §5).

/// "This looks like it belongs in Home › Kitchen layout" with Move to topic, Move as new topic and Dismiss (S11).
struct SpaceSuggestionBanner: View {
    let engine: EngineController
    let thread: SessionSummary
    let suggestion: SpaceSuggestion
    @State private var moving = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack").font(.system(size: 12)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                (Text("This looks like it belongs in ") + Text(suggestion.spaceTitle).bold() + (suggestion.topicTitle.map { Text(" › ") + Text($0).bold() } ?? Text("")))
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg)
                Text(suggestion.reason).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let topic = suggestion.topicId {
                Button("Move to topic") { move(topic: topic) }.buttonStyle(PillStyle(kind: .primary, compact: true)).disabled(moving)
                Button("Move as new topic") { move(topic: nil) }.buttonStyle(PillStyle(compact: true)).disabled(moving)
            } else {
                Button("Move as new topic") { move(topic: nil) }.buttonStyle(PillStyle(kind: .primary, compact: true)).disabled(moving)
            }
            Button("Dismiss") { Task { await engine.dismissSuggestion(thread.ref) } }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.dsAccentSoft, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
    }

    private func move(topic: String?) {
        moving = true
        let space = ContainerRef(kind: .space, id: suggestion.spaceId)
        run {
            defer { moving = false }
            let ids = try await engine.importThreads([thread.ref], into: space, topic: topic)
            if let id = ids.first { NotificationCenter.default.post(name: .openTopic, object: TopicTarget(spaceId: space.id, topicId: id, itemId: nil)) }
        }
    }
}

/// A thread's "Move to Space" submenu: each Space, as a new topic (S5).
struct MoveToSpaceMenu: View {
    let engine: EngineController
    let thread: SessionSummary

    var body: some View {
        Menu("Move to Notebook") {
            ForEach(engine.spaces, id: \.ref.id) { space in
                Menu(space.title) {
                    Button("As a New Topic") { move(space, topic: nil) }
                    let topics = space.activeTopics
                    if !topics.isEmpty {
                        Divider()
                        ForEach(topics) { topic in Button("Into “\(topic.title)”") { move(space, topic: topic.id) } }
                    }
                }
            }
            if !engine.spaces.isEmpty { Divider() }
            Button("New Notebook…") { NotificationCenter.default.post(name: .newSpace, object: thread.ref.id) }
        }
    }

    private func move(_ space: SessionSummary, topic: String?) {
        run {
            let ids = try await engine.importThreads([thread.ref], into: space.ref, topic: topic)
            if let id = ids.first { NotificationCenter.default.post(name: .openTopic, object: TopicTarget(spaceId: space.ref.id, topicId: id, itemId: nil)) }
        }
    }
}

/// Threads to bring into a new Space, each as a topic (S5): the New Space sheet's list.
struct ThreadPicker: View {
    let threads: [SessionSummary]
    @Binding var selected: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bring in threads (optional)").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(threads, id: \.ref.id) { thread in
                        Toggle(isOn: Binding(get: { selected.contains(thread.ref.id) }, set: { on in if on { selected.insert(thread.ref.id) } else { selected.remove(thread.ref.id) } })) {
                            Text(thread.title).font(.system(size: 12.5)).lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
            Text("Each becomes a topic with its whole conversation; the threads move into the Notebook.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
        }
    }
}

// MARK: Settings › Chat

/// Settings › Chat (design handoff h1): suggestions. About me and memory moved to Settings › Memory (docs/spec/14 M3).
struct ChatPane: View {
    let engine: EngineController
    private var settings: EngineSettings? { engine.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "Chat", summary: "Chats and notebooks")
            CardTitle("Suggestions")
            ListCard {
                ToggleRow(title: "Suggest follow-up messages", subtitle: "A few replies under each answer", isOn: Binding(get: { settings?.chat.followUps ?? true }, set: { v in
                    Task { await engine.updateSettings(SettingsPatch(chat: .init(followUps: v))) }
                }))
                ToggleRow(title: "Suggest moving a chat into a notebook", subtitle: "When a conversation grows into a subject", last: true, isOn: Binding(get: { settings?.chat.suggestSpaces ?? true }, set: { v in
                    Task { await engine.updateSettings(SettingsPatch(chat: .init(suggestSpaces: v))) }
                }))
            }
            .padding(.bottom, 22)
            CardTitle("About me")
            ListCard {
                HStack(spacing: 12) {
                    Image(systemName: "brain.head.profile").font(.system(size: 14)).foregroundStyle(Color.dsFg3).frame(width: 20)
                    Text("About me and memory search moved to Memory.").font(.system(size: 13))
                    Spacer()
                    Button("Open Memory") { NotificationCenter.default.post(name: .settingsSection, object: "Memory") }
                        .buttonStyle(PillStyle(compact: true))
                }
                .padding(.horizontal, 14).frame(minHeight: 50)
            }
        }
        .task { await engine.loadSettings() }
    }
}

/// About me (Settings › Memory): a list of facts (the notebook memory component) with who it's shared with,
/// whether conversations add to it, and where it's stored.
struct AboutMeEditor: View {
    let engine: EngineController
    @State private var text = ""
    @State private var revisions: [MemoryRevision] = []
    @State private var limited = false
    @State private var editing: Int?
    @State private var draft = ""
    @State private var adding = ""
    @State private var hovered: Int?
    @State private var showingHistory = false
    @State private var editingProvider: McpMemoryProvider?
    @State private var tryingProvider: McpMemoryProvider?
    @State private var error: String?
    @FocusState private var addFocused: Bool

    enum Share: Hashable { case chats, agents, nobody }

    private var settings: EngineSettings? { engine.settings }
    private var facts: [MemoryEditorSheet.Fact] { MemoryEditorSheet.facts(in: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: "Facts", detail: limited ? nil : "\(facts.count) fact\(facts.count == 1 ? "" : "s")") {
                if !revisions.isEmpty {
                    Button("History") { showingHistory = true }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                }
            }
            factList.padding(.bottom, 12)
            ListCard {
                VStack(spacing: 0) {
                    HStack {
                        Text("Share with").font(.system(size: 13))
                        Spacer()
                        Picker("", selection: Binding(get: { share }, set: { setShare($0) })) {
                            Text("Chats & notebooks").tag(Share.chats)
                            Text("+ Agents").tag(Share.agents)
                            Text("Nobody").tag(Share.nobody)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    .padding(.horizontal, 14).frame(minHeight: 46)
                    RowDivider(inset: 14)
                }
                ToggleRow(title: "Learn from conversations", subtitle: "New facts show in the chat with Undo", isOn: Binding(get: { settings?.aboutMe.capture ?? false }, set: { v in
                    Task { await engine.updateSettings(SettingsPatch(aboutMe: .init(capture: v))) }
                }))
                HStack {
                    Text("Stored in").font(.system(size: 13))
                    Spacer()
                    storedIn
                }
                .padding(.horizontal, 14).frame(minHeight: 46)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed).padding(.top, 8) }
            FinePrint("Never shared with Build sessions.").padding(.top, 10)
        }
        .task {
            await engine.loadSettings()
            await load()
            // Captures: PIOPIO_DEMO_ABOUT_ME seeds About me ("|" between lines) and shares it with chats.
            if let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_ABOUT_ME"], text.isEmpty {
                setShare(.chats)
                save(demo.replacingOccurrences(of: "|", with: "\n"))
            }
        }
        .sheet(item: $tryingProvider) { p in MemoryTrySheet(engine: engine, provider: p) }
        .sheet(isPresented: $showingHistory) { AboutMeHistorySheet(engine: engine, revisions: revisions) { Task { await load() } } }
        .sheet(item: $editingProvider) { p in
            McpMemoryEditor(engine: engine, provider: p) { saved in
                let providers = settings?.memory.providers ?? []
                let next = providers.contains { $0.id == saved.id } ? providers.map { $0.id == saved.id ? saved : $0 } : providers + [saved]
                Task { await engine.updateSettings(SettingsPatch(memory: .init(providers: next))) }
            }
        }
    }

    // MARK: Facts

    @ViewBuilder private var factList: some View {
        ListCard {
            if limited {
                Text("This memory provider can't list what it stores. Chats and agents recall from it instead.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(facts.enumerated()), id: \.element.line) { _, fact in
                    factRow(fact)
                    RowDivider(inset: 14)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
                    TextField("Add something about you…", text: $adding).textFieldStyle(.plain).font(.system(size: 13)).focused($addFocused).onSubmit(add)
                }
                .padding(.horizontal, 14).frame(minHeight: 40)
            }
        }
    }

    private func factRow(_ fact: MemoryEditorSheet.Fact) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(fact.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3).frame(width: 80, alignment: .leading).lineLimit(1)
            if editing == fact.line {
                TextField("", text: $draft).textFieldStyle(.roundedBorder).font(.system(size: 13)).onSubmit { replace(fact, with: draft) }
                Button("Save") { replace(fact, with: draft) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                Button("Cancel") { editing = nil }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            } else {
                Text(fact.text).font(.system(size: 13)).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if hovered == fact.line {
                    Button("Edit") { draft = fact.raw; editing = fact.line }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                    Button("Forget") { forget(fact) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsRed)
                } else {
                    Text(source(fact)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 40)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? fact.line : (hovered == fact.line ? nil : hovered) }
        .contextMenu {
            Button("Edit") { draft = fact.raw; editing = fact.line }
            Button("Forget", role: .destructive) { forget(fact) }
        }
    }

    /// "You", or "Learned · 2 d ago" when a conversation added it.
    private func source(_ fact: MemoryEditorSheet.Fact) -> String {
        guard let r = revisions.first(where: { r in r.undone != true && r.added.contains { $0 == fact.raw || $0.contains(fact.text) } }) else { return "You" }
        return r.by.kind == "user" ? "You" : "Learned · \(BuildSessionView.relative(r.at))"
    }

    private var lines: [String] { text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

    private func replace(_ fact: MemoryEditorSheet.Fact, with value: String) {
        let v = value.trimmingCharacters(in: .whitespaces)
        editing = nil
        guard !v.isEmpty, v != fact.raw else { return }
        var l = lines
        l[fact.line] = "- \(v)"
        save(l.joined(separator: "\n"))
    }

    private func forget(_ fact: MemoryEditorSheet.Fact) {
        var l = lines
        l.remove(at: fact.line)
        save(l.joined(separator: "\n"))
    }

    /// New facts go under Notes (a heading is added when the last section is another one).
    private func add() {
        let v = adding.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        adding = ""
        let lastHeading = lines.last { $0.hasPrefix("## ") }
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if lastHeading != nil, lastHeading != "## Notes" { t += "\n\n## Notes" }
        t += (t.isEmpty ? "" : "\n") + "- \(v)"
        save(t)
        addFocused = true
    }

    private func save(_ next: String) {
        text = next
        Task {
            do { try await engine.spaceCall("aboutMe.set", TextParams(text: next)) } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
            await load()
        }
    }

    // MARK: Settings

    private var share: Share {
        guard let a = settings?.aboutMe, a.enabled else { return .nobody }
        return a.inAgents == true ? .agents : .chats
    }

    private func setShare(_ value: Share) {
        let patch: SettingsPatch.AboutMe = switch value {
        case .nobody: .init(enabled: false)
        case .chats: .init(enabled: true, inThreads: true, inSpaces: true, inAgents: false)
        case .agents: .init(enabled: true, inThreads: true, inSpaces: true, inAgents: true)
        }
        Task { await engine.updateSettings(SettingsPatch(aboutMe: patch)) }
    }

    private var storedIn: some View {
        let providers = settings?.memory.providers ?? []
        let current = settings?.aboutMe.provider ?? "builtin"
        return Menu {
            Button { pick("builtin") } label: { if current == "builtin" { Label("Piopio", systemImage: "checkmark") } else { Text("Piopio") } }
            ForEach(providers) { p in
                Button { pick(p.id) } label: { if current == p.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) } }
            }
            Divider()
            if let p = providers.first(where: { $0.id == current }) {
                Button("Edit \(p.name)…") { editingProvider = p }
                Button("Try \(p.name)…") { tryingProvider = p }
                Button("Remove \(p.name)", role: .destructive) {
                    Task { await engine.updateSettings(SettingsPatch(aboutMe: .init(provider: "builtin"), memory: .init(providers: providers.filter { $0.id != p.id })) ); await load() }
                }
            }
            Button("Add MCP memory…") { editingProvider = McpMemoryProvider(id: UUID().uuidString.lowercased(), name: "", tools: .init(recall: .init(tool: "", args: [:]))) }
        } label: {
            Text(providers.first { $0.id == current }?.name ?? "Piopio").font(.system(size: 12.5, weight: .medium))
        }
        .menuStyle(.button).buttonStyle(ChipStyle()).fixedSize()
    }

    private func pick(_ id: String) {
        Task {
            await engine.updateSettings(SettingsPatch(aboutMe: .init(provider: id)))
            await load()
        }
    }

    private func load() async {
        guard let memory = await engine.aboutMe() else { return }
        text = memory.text
        revisions = memory.revisions
        limited = memory.limited ?? false
    }
}

/// About me's history (h1 "History"): each change, who made it, and Undo.
private struct AboutMeHistorySheet: View {
    let engine: EngineController
    let revisions: [MemoryRevision]
    let changed: () -> Void
    @State private var undone: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About me · history").font(.system(size: 17, weight: .bold))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(revisions.prefix(100).enumerated()), id: \.element.id) { i, r in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.summary).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                Text("\(r.by.kind == "user" ? "You" : "Learned in a conversation") · \(BuildSessionView.relative(r.at))").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                            }
                            Spacer()
                            if r.undone == true || undone.contains(r.id) {
                                Text("Undone").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                            } else {
                                Button("Undo") {
                                    Task {
                                        try? await engine.spaceCall("aboutMe.undo", RevisionIdParams(revisionId: r.id))
                                        undone.insert(r.id)
                                        changed()
                                    }
                                }
                                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        if i < min(revisions.count, 100) - 1 { RowDivider(inset: 14) }
                    }
                }
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.dsLine, lineWidth: 0.5))
            }
            .frame(height: 360)
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 560)
    }
}

/// How memory is searched (docs/spec/14-memory M1, §7): by words on this Mac (the default), or by meaning through
/// OpenRouter, each explained with the same example and what it costs.
struct MemorySearchCard: View {
    let engine: EngineController
    /// Bumped by Rebuild index, so the counts refresh.
    var tick = 0
    @State private var status: MemoryStatus?
    private var settings: EngineSettings? { engine.settings }
    private var byMeaning: Bool { settings?.memory.searchesByMeaning ?? false }
    /// OpenRouter or an OpenAI API key is connected.
    private var canUseMeaning: Bool { engine.hasKey || engine.providers.contains { ($0.id == "openrouter" || $0.id == "openai-api") && $0.isConnected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("How memory is searched")
            ListCard {
                option(meaning: false, title: "By words", badge: "On this Mac",
                       text: "Finds memories that use the words of the question. Asking where you live finds “I live in Madrid”, but not “First night in the new flat in Chamberí”. Nothing leaves your Mac.")
                RowDivider(inset: 44)
                option(meaning: true, title: "By meaning", badge: "OpenRouter",
                       text: "Also finds memories that say the same thing in other words, like the Chamberí message. Each memory's text is sent once to OpenRouter, which turns it into numbers that capture what it means (an “embedding”); those stay on this Mac. About $0.002 per 1,000 messages.")
            }
            FinePrint("For About me and agents' memory. In Piopio's own test of 40 questions over six months of messages, right answers went from 25 by words to 38 by meaning. Turning it off goes back to words; nothing is lost.")
                .padding(.top, 8)
        }
        .task(id: tick) { await refresh() }
    }

    private func option(meaning: Bool, title: String, badge: String, text: String) -> some View {
        let selected = byMeaning == meaning
        let unavailable = meaning && !canUseMeaning && !selected
        return Button { choose(meaning) } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(selected ? Color.accentColor : Color.dsFg3.opacity(0.5), lineWidth: selected ? 5 : 1.2)
                }
                .frame(width: 16, height: 16).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(unavailable ? Color.dsFg3 : Color.dsFg)
                        SettingsBadge(badge, tint: meaning ? nil : .green)
                    }
                    Text(text).font(.system(size: 12)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                    if unavailable {
                        Text("Connect OpenRouter (or an OpenAI API key) in Models first.").font(.system(size: 11.5)).foregroundStyle(Color.dsAmber)
                    } else if selected, meaning, let line = statusLine {
                        Text(line).font(.system(size: 11.5)).foregroundStyle(status?.reason == "failing" || status?.reason == "no_key" ? Color.dsAmber : Color.dsFg3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
    }

    private func choose(_ meaning: Bool) {
        guard meaning != byMeaning else { return }
        Task {
            await engine.updateSettings(SettingsPatch(memory: .init(semantic: meaning, localOnly: false)))
            await refresh()
        }
    }

    private func refresh() async {
        status = try? await engine.client?.call("memory.status", Empty(), as: MemoryStatus.self)
    }

    /// "1,203 of 1,240 memories indexed · OpenAI small embeddings", or why it's paused.
    private var statusLine: String? {
        guard let s = status else { return nil }
        if s.semantic {
            let count = s.indexed < s.records ? "\(s.indexed.formatted()) of \(s.records.formatted()) memories indexed, the rest in the background" : "\(s.records.formatted()) memories indexed"
            return [count, s.via.map { "via \($0)" }].compactMap { $0 }.joined(separator: " · ")
        }
        switch s.reason {
        case "no_key": return "Needs an OpenRouter or OpenAI API key (Models). Searching by words until then."
        case "failing": return "Paused: \(s.error ?? "OpenRouter didn't answer"). Searching by words; trying again in a minute."
        default: return nil
        }
    }
}
