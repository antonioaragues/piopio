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
        Menu("Move to Space") {
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
            Button("New Space…") { NotificationCenter.default.post(name: .newSpace, object: thread.ref.id) }
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
            Text("Each becomes a topic with its whole conversation; the threads move into the Space.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
        }
    }
}

// MARK: Settings › Chat

struct ChatPane: View {
    let engine: EngineController
    @State private var text = ""
    @State private var saved = ""
    @State private var revisions: [MemoryRevision] = []

    private var settings: EngineSettings? { engine.settings }

    var body: some View {
        PaneTitle(title: "Chat", subtitle: "Threads and Spaces: suggestions and what they know about you.")
        ListCard {
            Row(title: "Suggestions", last: true) {
                Toggle("Suggest moving a thread into a Space when it fits one", isOn: binding(\.chat.suggestSpaces) { SettingsPatch(chat: .init(suggestSpaces: $0)) })
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
                Spacer()
            }
        }
        .padding(.bottom, 18)
        HStack {
            SectionLabel("About me")
            Spacer()
        }
        .padding(.bottom, 6)
        ListCard {
            Row(title: "Use it") {
                Toggle("Show it to the agents", isOn: binding(\.aboutMe.enabled) { SettingsPatch(aboutMe: .init(enabled: $0)) })
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
                Spacer()
            }
            Row(title: "Where") {
                Toggle("Threads", isOn: binding(\.aboutMe.inThreads) { SettingsPatch(aboutMe: .init(inThreads: $0)) }).toggleStyle(.checkbox)
                Toggle("Spaces", isOn: binding(\.aboutMe.inSpaces) { SettingsPatch(aboutMe: .init(inSpaces: $0)) }).toggleStyle(.checkbox)
                Text("Never in Build").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Spacer()
            }
            Row(title: "Learning", last: true) {
                Toggle("Let the agents add facts they learn (each one shows in the conversation)", isOn: binding(\.aboutMe.capture) { SettingsPatch(aboutMe: .init(capture: $0)) })
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
                Spacer()
            }
        }
        .padding(.bottom, 12)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: $text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 200)
                    .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
                Button("Save") {
                    run {
                        try await engine.spaceCall("aboutMe.set", TextParams(text: text))
                        await load()
                    }
                }
                .buttonStyle(PillStyle(kind: .primary, compact: true))
                .disabled(text == saved)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("History")
                if revisions.isEmpty { Text("No changes yet.").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                ForEach(revisions.prefix(8)) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.summary).font(.system(size: 12)).lineLimit(2)
                        HStack(spacing: 6) {
                            Text("\(r.by.kind == "user" ? "You" : "An agent") · \(BuildSessionView.relative(r.at))").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                            Button("Restore") {
                                run {
                                    try await engine.spaceCall("aboutMe.restore", RevisionIdParams(revisionId: r.id))
                                    await load()
                                }
                            }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .frame(width: 200, alignment: .leading)
        }
        .task {
            await engine.loadSettings()
            await load()
        }
    }

    private func binding(_ path: KeyPath<EngineSettings, Bool>, patch: @escaping (Bool) -> SettingsPatch) -> Binding<Bool> {
        Binding(get: { settings?[keyPath: path] ?? false }, set: { on in Task { await engine.updateSettings(patch(on)) } })
    }

    private func load() async {
        guard let memory = await engine.aboutMe() else { return }
        text = memory.text
        saved = memory.text
        revisions = memory.revisions
    }
}
