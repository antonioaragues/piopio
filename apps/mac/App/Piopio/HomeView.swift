import PiopioKit
import PiopioTranscript
import SwiftUI

/// Home, the landing screen and the one start (docs/spec/18 §4): a greeting, the box where you write and choose where it
/// goes, then three short lists as plain rows: Needs you, Coming up and Recent. Empty lists are hidden.
struct HomeView: View {
    let engine: EngineController
    @Binding var item: SidebarItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                greeting
                AskBox(engine: engine, item: $item).padding(.top, 24)
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

/// The one start (docs/spec/18 §4): write, and choose where it goes in the box itself. No project is a chat; a project
/// with a folder is a conversation there, with permissions (Read only, Ask, Auto-edit, Full auto) said in a chip and in
/// a line under the box; an agent gets the message. One Return sends it, whatever the target.
struct AskBox: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var text = ""
    /// "chat", "project:<id>" or "agent:<id>"; routes that open Home with a project chosen set it (⌘O, a project's +).
    @AppStorage("homeTarget") private var targetRaw = "chat"
    @State private var pendingChat: ContainerRef?
    @State private var sending = false
    @State private var sendError: String?
    @State private var mode: ApprovalMode?
    @State private var workOn: WorkOnChoice = .folder
    @State private var recent: [RecentFolder] = []
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
    @State private var attachments: [PendingAttachment] = []
    @State private var model: ModelRef?
    @FocusState private var focused: Bool

    enum Target: Hashable { case chat, project(String), agent(String) }

    private var areas: AreaSet { Areas.shared.set }

    private var project: ProjectInfo? {
        if case .project(let id) = target { return engine.projects.first { $0.id == id && $0.missing != true } }
        return nil
    }

    private var agent: SessionSummary? {
        if case .agent(let id) = target { return engine.agents.first { $0.ref.id == id } }
        return nil
    }

    /// The permissions this conversation starts with: chosen here, else the project's own. Without Build (the area is
    /// off), folders are Read only (18 §7).
    private var buildOn: Bool { areas.contains(.build) }
    private var effectiveMode: ApprovalMode { buildOn ? (mode ?? project?.approvalMode ?? .autoEdit) : .readOnly }

    private var placeholder: String {
        if let project { return "What should we do in \(project.name)?" }
        if let agent { return "Message \(agent.title)…" }
        return "Ask anything, or @ a project or an agent…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 10) {
                if let sendError { Text(sendError).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
                HStack(spacing: 4) {
                    targetMenu
                    Spacer()
                }
                .padding(.leading, -6)
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.dsFg3), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(send)
                if !attachments.isEmpty { attachmentTiles }
                HStack(spacing: 4) {
                    if agent == nil {
                        Button(action: attach) { Image(systemName: "plus").font(.system(size: 13)) }
                            .buttonStyle(IconButtonStyle(size: 26))
                            .help("Attach images, PDFs or text files").accessibilityLabel("Attach files")
                        Button { showModels = true } label: { Text(modelLabel) }
                            .buttonStyle(ChipStyle())
                            .popover(isPresented: $showModels, arrowEdge: .bottom) {
                                ModelPicker(engine: engine, selected: model ?? defaultModel, role: project == nil ? .chat : .build) { m in model = m; showModels = false }
                            }
                    }
                    Spacer()
                    if project != nil {
                        if buildOn { permissionsMenu } else { Text(ApprovalMode.readOnly.title).font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(.horizontal, 6) }
                    }
                    SendButton(enabled: !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: send)
                        .accessibilityLabel(sendLabel)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.leading, -6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .composerBox()
            // Before Return: where it goes, and whether Piopio may change anything (18 §4). Nothing without a folder.
            if let line = whereLine {
                Text(line).font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.leading, 14)
                    .accessibilityLabel(line)
            }
        }
        .onChange(of: text) { _, t in mention(t); saveHomeDraft() }
        .onChange(of: targetRaw) { _, _ in mode = nil; workOn = .folder }
        .onAppear {
            if let saved = DraftStore(home: engine.home).load("home") { text = saved.text; pendingChat = saved.destination }
            if case .project = target, project == nil { target = .chat }
            if case .agent = target, agent == nil { target = .chat }
            focused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusHome)) { _ in focused = true }
        .task {
            let known = Set(engine.projects.map(\.path))
            recent = await Task.detached { RecentFolder.scan().filter { !known.contains($0.url.path) } }.value
        }
    }

    // MARK: Where it goes

    private var targetMenu: some View {
        Menu {
            Button { target = .chat } label: {
                if target == .chat { Label("No project", systemImage: "checkmark") } else { Label("No project", systemImage: "bubble.left") }
            }
            if !engine.projects.isEmpty {
                Section("Projects") {
                    ForEach(engine.projects.filter { $0.missing != true }) { p in
                        Button { target = .project(p.id) } label: {
                            if project?.id == p.id { Label(p.name, systemImage: "checkmark") } else { Label(p.name, systemImage: "folder") }
                        }
                    }
                }
            }
            if !recent.isEmpty {
                Menu("Folders on this Mac") {
                    ForEach(recent.prefix(12)) { folder in
                        Button(folder.path) { Task { await use(folder.url) } }
                    }
                }
            }
            Button("Open folder…") { openFolder() }
            if let project, project.branch != nil {
                Section("Work on") {
                    ForEach(WorkOnChoice.allCases, id: \.self) { choice in
                        Button { workOn = choice } label: {
                            if workOn == choice { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                            Text(choice.summary)
                        }
                    }
                }
            }
            if areas.contains(.agents), !engine.agents.isEmpty {
                Section("Message an agent") {
                    ForEach(engine.agents, id: \.ref.id) { a in
                        Button { target = .agent(a.ref.id) } label: {
                            if agent?.ref.id == a.ref.id { Label(a.title, systemImage: "checkmark") } else { Label(a.title, systemImage: "person.crop.circle") }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: project != nil ? "folder" : agent != nil ? "person.crop.circle" : "bubble.left").font(.system(size: 11))
                Text(targetLabel)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
        }
        .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.hidden).fixedSize()
        .help("Where this goes: no project, a project folder, or an agent")
        .accessibilityLabel("Where this goes: \(targetLabel)")
    }

    private var permissionsMenu: some View {
        Menu {
            ForEach(ApprovalMode.allCases) { m in
                if m == .fullAuto { Divider() }
                Button { mode = m } label: {
                    if m == effectiveMode { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    Text(m.summary)
                }
            }
            if let project, effectiveMode != project.approvalMode {
                Divider()
                Button("Use “\(effectiveMode.title)” for new conversations in \(project.name)") {
                    Task { await engine.setApprovalMode(effectiveMode, for: project); mode = nil }
                }
            }
        } label: { Text(effectiveMode.title).foregroundStyle(effectiveMode == .fullAuto ? Color.accentColor : Color.dsFg2) }
            .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.hidden).fixedSize()
            .help(effectiveMode.summary)
            .accessibilityLabel("Permissions: \(effectiveMode.title)")
    }

    /// "In piopio · can edit files; asks before commands"; nothing with no project (it can't touch files).
    private var whereLine: String? {
        guard let project else { return nil }
        let place = switch workOn {
        case .folder: ""
        case .branch: " · on a new branch"
        case .worktree: " · in its own worktree"
        }
        return "In \(project.name)\(place) · \(effectiveMode.line)"
    }

    private var targetLabel: String {
        if let project { return project.name }
        if let agent { return agent.title }
        return "No project"
    }

    private var sendLabel: String {
        if let project { return "Start in \(project.name)" }
        if let agent { return "Send to \(agent.title)" }
        return "Send"
    }

    private var defaultModel: ModelRef? { project == nil ? engine.preferredModel : engine.model(for: .build) }

    private var modelLabel: String {
        let ref = model ?? defaultModel
        return engine.model(ref).map(ModelChip.short) ?? ref?.id ?? "Model"
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await use(url) }
    }

    /// Adds a folder as a project (once) and chooses it. A folder of documents starts in Read only.
    private func use(_ url: URL) async {
        guard let added = await engine.addProject(url) else { sendError = "Couldn't open that folder."; return }
        target = .project(added.id)
        focused = true
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

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { attachments.append(try AttachmentLoader.load(url)) } catch { sendError = error.localizedDescription }
        }
    }

    /// "@name " at the start picks a project or an agent.
    private func mention(_ t: String) {
        guard t.hasPrefix("@"), let space = t.firstIndex(of: " ") else { return }
        let name = String(t[t.index(after: t.startIndex)..<space]).lowercased()
        if let p = engine.projects.first(where: { $0.name.lowercased() == name }) {
            target = .project(p.id)
            text = String(t[t.index(after: space)...])
        } else if areas.contains(.agents), let a = engine.agents.first(where: { $0.title.lowercased().replacingOccurrences(of: " ", with: "") == name.replacingOccurrences(of: " ", with: "") }) {
            target = .agent(a.ref.id)
            text = String(t[t.index(after: space)...])
        }
    }

    // MARK: Send

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
                    sendError = "Couldn't start a conversation. Your draft is saved; try again when the engine is connected."
                    return
                }
                pendingChat = ref; saveHomeDraft()
                let thread = engine.thread(ref)
                await thread.open()
                if await thread.send(message, attachments: attachments.map(\.attachment)) {
                    text = ""; pendingChat = nil; attachments = []; saveHomeDraft()
                    try? await engine.refreshCatalog()
                    item = .chat(ref.id)
                } else { sendError = thread.error ?? "Couldn't send. Your draft is saved; retry when connected." }
            }
        case .project:
            guard let project else { sendError = "Choose an available project folder."; return }
            sending = true
            let choice = workOn
            let chosenMode = effectiveMode
            Task {
                defer { sending = false }
                let place: WorkOn
                switch choice {
                case .folder: place = .current
                case .branch, .worktree:
                    let suggested = try? await engine.client?.call("git.suggestBranch", SuggestBranchParams(prompt: message), as: SuggestBranchResult.self).branch
                    let name = suggested?.isEmpty == false ? suggested! : "piopio/session-\(Int(Date().timeIntervalSince1970))"
                    place = choice == .branch ? .branch(name, base: nil) : .worktree(name, base: nil)
                }
                do {
                    let ref = try await engine.createBuildSession(in: project, workOn: place, mode: chosenMode, model: model)
                    let session = engine.thread(ref)
                    await session.open()
                    if await session.send(message, attachments: attachments.map(\.attachment)) {
                        text = ""; attachments = []; mode = nil; workOn = .folder; saveHomeDraft()
                        item = .session(ref.id)
                    } else {
                        item = .session(ref.id) // the conversation exists; its composer keeps the draft for a retry
                    }
                } catch {
                    sendError = ((error as? EngineError)?.message ?? String(describing: error)) + " Nothing was started, and your message is kept."
                }
            }
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

/// Where a conversation in a git project works (the old new-session page's choice, kept in Home's project menu).
enum WorkOnChoice: String, CaseIterable {
    case folder, branch, worktree
    var title: String {
        switch self {
        case .folder: "In the folder"
        case .branch: "New branch"
        case .worktree: "Worktree"
        }
    }
    var summary: String {
        switch self {
        case .folder: "Works on the folder as it is, on its current branch"
        case .branch: "Switches the folder to a new branch first"
        case .worktree: "A separate checkout, so your working copy isn't touched"
        }
    }
}

extension Notification.Name {
    /// Puts the cursor in Home's box (⌘N, a project's +).
    static let focusHome = Notification.Name("piopio.focusHome")
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
