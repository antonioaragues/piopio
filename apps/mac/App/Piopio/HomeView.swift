import PiopioKit
import PiopioTranscript
import SwiftUI

/// Home, the landing screen (docs/design/grey 14a): a greeting and the date, one box to ask, start a session or
/// message an agent, then three short lists as plain rows: Needs you, Coming up and Recent. Empty lists are hidden.
struct HomeView: View {
    let engine: EngineController
    @Binding var item: SidebarItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                greeting
                if askable { AskBox(engine: engine, item: $item).padding(.top, 24) }
                needsYou
                comingUp
                recent
            }
            .padding(.horizontal, 32)
            .padding(.top, 72)
            .padding(.bottom, 48)
            .frame(maxWidth: 704)
            .frame(maxWidth: .infinity)
        }
    }

    /// The Ask box needs somewhere to send: Chat, a project with Build on, or an agent with Agents on.
    private var askable: Bool {
        let areas = Areas.shared.set
        return areas.contains(.chat) || (areas.contains(.build) && !engine.projects.isEmpty) || (areas.contains(.agents) && !engine.agents.isEmpty)
    }

    // MARK: Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Self.salutation()), \(Self.firstName)").font(.system(size: 28, weight: .bold)).tracking(-0.6).foregroundStyle(Color.dsFg)
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 13.5)).foregroundStyle(Color.dsFg3)
        }
    }

    static func salutation(_ date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<20: "Good afternoon"
        default: "Good evening"
        }
    }

    static var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    // MARK: Lists

    private func sectionTitle(_ title: String, see: (String, () -> Void)? = nil) -> some View {
        HStack {
            SectionLabel(title)
            Spacer()
            if let see { Button(see.0, action: see.1).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
        }
        .padding(.top, 36)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var needsYou: some View {
        let entries = Array(engine.needsYou.reversed())
        if !entries.isEmpty {
            sectionTitle("Needs you", see: ("See all", { item = .needsYou }))
            ForEach(entries.prefix(4)) { entry in
                HomeRow(title: NeedsYouText.title(entry, engine: engine), meta: NeedsYouText.source(entry, engine: engine) + " · " + Self.age(entry.at), dot: true) {
                    if let s = entry.session { item = engine.item(for: s.ref.id) ?? .needsYou } else { item = .needsYou }
                }
            }
        }
    }

    @ViewBuilder private var comingUp: some View {
        let next = (Areas.shared.contains(.agents) ? engine.agents : []).filter { $0.agent?.status?.nextRun != nil && $0.agent?.status?.paused != true }.sorted { ($0.agent?.status?.nextRun ?? "") < ($1.agent?.status?.nextRun ?? "") }
        if !next.isEmpty {
            sectionTitle("Coming up")
            ForEach(next.prefix(3), id: \.ref.id) { agent in
                HomeRow(title: agent.title, meta: Self.at(agent.agent?.status?.nextRun ?? "")) { item = .agent(agent.ref.id) }
            }
        }
    }

    @ViewBuilder private var recent: some View {
        let all = (engine.spaces + engine.buildSessions.filter { $0.parent == nil } + engine.threads).filter { Areas.shared.set.shows($0) }
        let items = Array(all.sorted { $0.updatedAt > $1.updatedAt }.prefix(4))
        if !items.isEmpty {
            sectionTitle("Recent")
            ForEach(items, id: \.ref.id) { s in
                HomeRow(title: s.title, meta: "\(kind(s)) · \(BuildSessionView.relative(s.updatedAt))") { item = engine.item(for: s.ref.id) ?? .home }
            }
        }
    }

    private func kind(_ s: SessionSummary) -> String {
        switch s.ref.kind {
        case .space: "Notebook"
        case .build: engine.project(of: s)?.name ?? "Session"
        default: s.debate != nil ? "Debate" : "Chat"
        }
    }

    /// "11h", "6d", "now".
    static func age(_ iso: String) -> String {
        let seconds = Date().timeIntervalSince(MainSidebar.date(iso))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// "Tomorrow at 8:00", "Today at 21:00", "Tue at 8:00".
    static func at(_ iso: String) -> String {
        let when = MainSidebar.when(iso)
        guard let space = when.firstIndex(of: " ") else { return when.capitalizedFirst }
        let day = when[..<space], time = when[when.index(after: space)...]
        return time.contains(":") ? "\(day.capitalized) at \(time)" : when.capitalizedFirst
    }
}

/// A Home row: an optional blue dot, the title, and where it's from with when, in fg3 on the right.
private struct HomeRow: View {
    let title: String
    let meta: String
    var dot = false
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                if dot { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                Text(title).font(.system(size: 13.5)).foregroundStyle(Color.dsFg).lineLimit(1)
                Spacer(minLength: 16)
                Text(meta).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            .frame(height: 36)
            .padding(.horizontal, 8)
            .background(hovering ? Color.dsChip.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .padding(.horizontal, -8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One box for everything (1b): a new chat by default; "@project" starts a Build session there, "@agent" messages it.
struct AskBox: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var text = ""
    @AppStorage("homeTarget") private var targetRaw = "chat"
    @State private var pendingChat: ContainerRef?
    @State private var sending = false
    @State private var sendError: String?
    private var target: Target {
        get {
            if targetRaw.hasPrefix("project:") { return .project(String(targetRaw.dropFirst(8))) }
            if targetRaw.hasPrefix("agent:") { return .agent(String(targetRaw.dropFirst(6))) }
            return .chat
        }
        nonmutating set {
            switch newValue { case .chat: targetRaw = "chat"; case .project(let id): targetRaw = "project:" + id; case .agent(let id): targetRaw = "agent:" + id }
            pendingChat = nil
        }
    }
    private func saveHomeDraft() {
        do { try DraftStore(home: engine.home).save(ComposerDraft(text: text, destination: pendingChat), for: "home") }
        catch { sendError = "Couldn't save this draft: \(error.localizedDescription)" }
    }
    @State private var showModels = false
    @State private var model: ModelRef?
    @FocusState private var focused: Bool

    enum Target: Hashable { case chat, project(String), agent(String) }

    private var areas: AreaSet { Areas.shared.set }

    /// "Ask anything, start a build session, or message an agent…", for the areas that are on.
    private var placeholder: String {
        var parts: [String] = []
        if areas.contains(.chat) { parts.append("Ask anything") }
        if areas.contains(.build) { parts.append(parts.isEmpty ? "Start a session" : "start a session") }
        if areas.contains(.agents) { parts.append(parts.isEmpty ? "Message an agent" : "message an agent") }
        return parts.count > 1 ? parts.dropLast().joined(separator: ", ") + ", or " + parts.last! + "…" : parts[0] + "…"
    }

    /// The first target the areas allow: a chat, a session in the first project, or the first agent.
    private var defaultTarget: Target? {
        if areas.contains(.chat) { return .chat }
        if areas.contains(.build), let p = engine.projects.first { return .project(p.id) }
        if areas.contains(.agents), let a = engine.agents.first { return .agent(a.ref.id) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sendError { Text(sendError).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.dsFg3), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
            HStack(spacing: 4) {
                Menu {
                    if areas.contains(.chat) { Button("New chat") { target = .chat } }
                    if areas.contains(.build), !engine.projects.isEmpty {
                        Section("Start a session in") {
                            ForEach(engine.projects) { p in Button(p.name) { target = .project(p.id) } }
                        }
                    }
                    if areas.contains(.agents), !engine.agents.isEmpty {
                        Section("Message") {
                            ForEach(engine.agents, id: \.ref.id) { a in Button(a.title) { target = .agent(a.ref.id) } }
                        }
                    }
                } label: { Text(targetLabel) }
                    .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.hidden).fixedSize()
                    .help("Where this goes: a new chat, a session in a project, or an agent")
                Spacer()
                if target == .chat {
                    Button { showModels = true } label: { Text(modelLabel) }
                        .buttonStyle(ChipStyle())
                        .popover(isPresented: $showModels, arrowEdge: .bottom) {
                            ModelPicker(engine: engine, selected: model ?? engine.preferredModel) { m in model = m; showModels = false }
                        }
                }
                SendButton(enabled: !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: send)
                    .accessibilityLabel("Send to \(targetLabel)")
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, -6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .composerBox()
        .onChange(of: text) { _, t in mention(t); saveHomeDraft() }
         .onAppear {
            if target == .chat, let first = defaultTarget, first != .chat { target = first }
            if let saved = DraftStore(home: engine.home).load("home") { text = saved.text; pendingChat = saved.destination }
        }
        .onChange(of: areas) { _, _ in if let first = defaultTarget { target = first } }
    }

    private var targetLabel: String {
        switch target {
        case .chat: "New chat"
        case .project(let id): "Session in \(engine.projects.first { $0.id == id }?.name ?? "project")"
        case .agent(let id): "Message \(engine.agents.first { $0.ref.id == id }?.title ?? "agent")"
        }
    }

    private var modelLabel: String {
        let ref = model ?? engine.preferredModel
        return engine.model(ref).map(ModelChip.short) ?? ref?.id ?? "Model"
    }

    private var hint: String {
        let p = areas.contains(.build) ? engine.projects.first?.name : nil
        let a = areas.contains(.agents) ? engine.agents.first?.title : nil
        return [p.map { "@\($0) starts a session" }, a.map { "@\($0) messages the agent" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// "@name " at the start picks a project or an agent.
    private func mention(_ t: String) {
        guard t.hasPrefix("@"), let space = t.firstIndex(of: " ") else { return }
        let name = String(t[t.index(after: t.startIndex)..<space]).lowercased()
        if areas.contains(.build), let p = engine.projects.first(where: { $0.name.lowercased() == name }) {
            target = .project(p.id)
            text = String(t[t.index(after: space)...])
        } else if areas.contains(.agents), let a = engine.agents.first(where: { $0.title.lowercased().replacingOccurrences(of: " ", with: "") == name.replacingOccurrences(of: " ", with: "") }) {
            target = .agent(a.ref.id)
            text = String(t[t.index(after: space)...])
        }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !sending else { return }
        sendError = nil
        switch target {
        case .chat:
            sending = true
            Task {
                defer { sending = false }
                let destination: ContainerRef?
                if let pendingChat { destination = pendingChat } else { destination = await engine.createThread(model: model) }
                guard let ref = destination else {
                    sendError = "Couldn't start a chat. Your draft is saved; try again when the engine is connected."
                    return
                }
                pendingChat = ref; saveHomeDraft()
                let thread = engine.thread(ref)
                await thread.open()
                if await thread.send(message) {
                    text = ""; pendingChat = nil; saveHomeDraft()
                    try? await engine.refreshCatalog()
                    item = .chat(ref.id)
                } else { sendError = thread.error ?? "Couldn't send. Your draft is saved; retry when connected." }
            }
        case .project(let id):
            guard let project = engine.projects.first(where: { $0.id == id }) else { sendError = "Choose an available project folder."; return }
            NotificationCenter.default.post(name: .newBuildSession, object: project.id, userInfo: ["prompt": message])
        case .agent(let id):
            sending = true
            Task {
                defer { sending = false }
                let thread = engine.thread(ContainerRef(kind: .agent, id: id))
                await thread.open()
                if await thread.send(message) {
                    text = ""; saveHomeDraft()
                    UserDefaults.standard.set("Chat", forKey: "agentTab")
                    item = .agent(id)
                } else { sendError = thread.error ?? "Couldn't send. Your draft is saved; retry when connected." }
            }
        }
    }

}

extension View {
    /// The composer's box (docs/design/grey): field fill, a 0.5pt hairline, radius 16, a faint shadow.
    func composerBox() -> some View {
        self
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.composer, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.composer, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 5, y: 2)
    }
}

/// The 28pt round send button: grey while there's nothing to send, black once there is.
struct SendButton: View {
    let enabled: Bool
    var symbol = "arrow.up"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Color.dsInvFg : Color.dsFg3)
                .frame(width: 28, height: 28)
                .background(enabled ? Color.dsInv : Color.dsChip, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
