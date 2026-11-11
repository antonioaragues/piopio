import PiopioKit
import PiopioTranscript
import SwiftUI

/// Home, the landing screen and the one start (docs/spec/18 §4), and the agenda of everyone who works for you
/// (docs/spec/21 D2, design 5e): a greeting and the box where you write, then two columns. Left: what's waiting on you
/// (with its action in the row) and what happened while you were away. Right: today, as a timeline of every routine,
/// agents' and projects', with what's running now.
struct HomeView: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var agenda: HomeAgenda?
    /// Your last visit: "While you were away" starts there.
    @AppStorage("homeLastVisit") private var lastVisit = ""
    /// Two columns when there's room for them.
    @State private var wide = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    greeting
                    AskBox(engine: engine, item: $item).padding(.top, 24)
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 40) {
                            VStack(alignment: .leading, spacing: 0) { waiting; away }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 0) { today }.frame(width: 300, alignment: .leading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) { waiting; away; today }
                    }
                }
                .padding(.top, 12)
                .onGeometryChange(for: Bool.self) { $0.size.width >= 760 } action: { wide = $0 }
            }
            .padding(.horizontal, 32)
            .padding(.top, 72)
            .padding(.bottom, 48)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .task {
            let since = lastVisit.isEmpty ? nil : lastVisit
            agenda = await engine.homeAgenda(since: since)
        }
        .onDisappear { lastVisit = ISO8601DateFormatter().string(from: .now) }
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

    // MARK: Agenda

    private func sectionTitle(_ title: String, see: (String, () -> Void)? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dsFg)
            Spacer()
            if let see { Button(see.0, action: see.1).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
        }
        .padding(.top, 32)
        .padding(.bottom, 8)
    }

    /// Teams whose finished work waits to be merged (open the project's Board).
    private var readyToMerge: [(team: TeamInfo, project: ProjectInfo, tasks: Int)] {
        engine.teams.compactMap { t in
            guard t.git != nil, !t.tasks.contains(where: { ["todo", "doing", "review", "integrating"].contains($0.state) }),
                  let p = engine.projects.first(where: { $0.path == t.cwd }) else { return nil }
            let n = t.tasks.filter { $0.state == "done" && $0.branch != nil && $0.landed == nil }.count
            return n > 0 ? (t, p, n) : nil
        }
    }

    @ViewBuilder private var waiting: some View {
        let entries = Array(engine.needsYou.reversed())
        let ready = readyToMerge
        let count = entries.count + ready.count
        if count > 0 {
            sectionTitle("Waiting on you · \(count)", see: entries.count > 4 ? ("See all", { item = .needsYou }) : nil)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries.prefix(4)) { WaitingRow(engine: engine, entry: $0, item: $item) }
                ForEach(ready, id: \.team.id) { r in
                    AgendaLine(dot: .accentColor) {
                        Text("\(r.project.name) · \(r.tasks) task\(r.tasks == 1 ? "" : "s") ready for \(r.team.git?.base ?? "main")").font(.system(size: 13.5))
                    } trailing: {
                        Button("Review") { UserDefaults.standard.set("board", forKey: "projectTab"); item = .project(r.project.id) }.buttonStyle(PillStyle(compact: true))
                    }
                }
            }
        }
    }

    @ViewBuilder private var away: some View {
        if let lines = agenda?.away, !lines.isEmpty {
            sectionTitle("While you were away")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(6).enumerated()), id: \.offset) { _, line in
                    AgendaLine(dot: line.failed == true ? .dsWarn : line.quiet ? Color(white: 0.4) : .green) {
                        (Text(line.source.name).foregroundStyle(line.quiet ? Color.dsFg3 : Color.dsFg) + Text(" \(line.text)").foregroundStyle(line.quiet ? Color.dsFg3 : Color.dsFg2))
                            .font(.system(size: 13.5)).lineLimit(2)
                    } trailing: {
                        Text(Self.clock(line.at)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { open(line.source) }
                }
            }
        }
    }

    @ViewBuilder private var today: some View {
        sectionTitle("Today")
        let rows = agenda?.today ?? []
        if rows.isEmpty {
            Text(agenda == nil ? "" : "Nothing planned today. Ask an agent to do something every morning, or give a project a routine.")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    // Past midnight: what's next tomorrow, under a divider.
                    if row.tomorrow == true, i == 0 || rows[i - 1].tomorrow != true {
                        Text("Tomorrow").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsFg3).padding(.leading, 12).padding(.top, 10).padding(.bottom, 2)
                    }
                    timelineRow(row)
                }
            }
            .overlay(alignment: .leading) { Rectangle().fill(Color.dsLine).frame(width: 1).padding(.vertical, 6) }
        }
        if let held = agenda?.held, held > 0 {
            Text("\(held) message\(held == 1 ? "" : "s") held until quiet hours end").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 12)
        }
    }

    /// A timeline row (design 5e): the time (or "any" for an event), who and what; past rows grey, "now" highlighted.
    private func timelineRow(_ row: HomeAgenda.Today) -> some View {
        let past = ["done", "failed", "skipped"].contains(row.state)
        let now = row.state == "running"
        return Button { open(row.source) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(now ? "now" : row.at.map(Self.clock) ?? "any").font(.system(size: 12, weight: now ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(now ? Color.accentColor : Color.dsFg3).frame(width: 40, alignment: .leading)
                (Text(row.source.name).foregroundStyle(past ? Color.dsFg3 : Color.dsFg) + Text(row.label.isEmpty ? "" : " · \(row.label)").foregroundStyle(past ? Color.dsFg3 : Color.dsFg2))
                    .font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if row.state == "done" { Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(Color.dsFg3) }
                if row.state == "failed" { Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(Color.dsWarn) }
            }
            .padding(.leading, 12).padding(.vertical, 6).padding(.trailing, 6)
            .background(now ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ source: HomeAgenda.Source) {
        switch source.kind {
        case "agent": item = .agent(source.id)
        case "project": item = .project(source.id)
        default:
            if let t = engine.teams.first(where: { $0.id == source.id }), let p = engine.projects.first(where: { $0.path == t.cwd }) {
                UserDefaults.standard.set("board", forKey: "projectTab")
                item = .project(p.id)
            }
        }
    }

    /// "8:00" in your time.
    static func clock(_ iso: String) -> String {
        let date = MainSidebar.date(iso)
        return date.formatted(date: .omitted, time: .shortened)
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

/// A line on Home's agenda: a dot, the text, and something on the right.
private struct AgendaLine<Content: View, Trailing: View>: View {
    var dot: Color = .accentColor
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(dot).frame(width: 7, height: 7)
            content
            Spacer(minLength: 12)
            trailing
        }
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }
}

/// Something waiting on you, with its action in the row (design 5e): Allow, an answer, or Open.
private struct WaitingRow: View {
    let engine: EngineController
    let entry: NeedsYouEntry
    @Binding var item: SidebarItem
    @State private var reply = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        AgendaLine(dot: entry.isApproval ? .dsWarn : .accentColor) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line).font(.system(size: 13.5)).foregroundStyle(Color.dsFg).lineLimit(2)
                if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(Color.dsWarn) }
            }
        } trailing: {
            switch entry.kind {
            case .approval:
                Button("Not now") { decide(false) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                Button("Allow") { decide(true) }.buttonStyle(PillStyle(kind: .primary, compact: true))
            case .message:
                TextField("", text: $reply, prompt: Text("Answer here…").foregroundStyle(Color.dsFg3))
                    .textFieldStyle(.plain).font(.system(size: 12.5)).frame(width: 160)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
                    .onSubmit(send)
            default:
                Button("Open") { open() }.buttonStyle(PillStyle(compact: true))
            }
        }
        .disabled(busy)
    }

    /// "Morning briefing wants to read Calendar", "Family helper: “Which supermarket?”".
    private var line: String {
        let source = NeedsYouText.source(entry, engine: engine)
        let title = NeedsYouText.title(entry, engine: engine)
        switch entry.kind {
        case .approval: return "\(source) asks: \(title)"
        case .message: return "\(source): “\(title)”"
        case .buildPrompt: return "\(source) · \(title)"
        default: return title
        }
    }

    private func open() {
        if let s = entry.session { item = engine.item(for: s.ref.id) ?? .needsYou }
        else if let inbox = entry.inbox { item = .agent(inbox.agent.id) }
        else { item = .needsYou }
    }

    private func decide(_ approve: Bool) {
        guard let inbox = entry.inbox, let approval = inbox.approval else { return }
        perform { try await engine.decide(inbox.agent, approvalId: approval.approvalId, approve: approve) }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let inbox = entry.inbox else { return }
        reply = ""
        let thread = engine.thread(ContainerRef(kind: .agent, id: inbox.agent.id))
        perform {
            await thread.open()
            await thread.send(text)
            await engine.markInboxRead([inbox])
        }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await work() } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
            busy = false
        }
    }
}


/// The one start (docs/spec/18 §4): write, and choose where it goes in the box itself. No project is a chat; a project
/// with a folder is a conversation there, with permissions (Read only, Ask, Auto-edit, Full auto) said in a chip and in
/// a line under the box; an agent gets the message. One Return sends it, whatever the target.
struct AskBox: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var text = ""
    /// "chat", "project:<id>" or "agent:<id>"; the start routes set it (⌘N, ⌘O, a project's +).
    /// Back to "chat" (no project) after each send, so a loose question never lands in the last project.
    @AppStorage("homeTarget") private var targetRaw = "chat"
    @State private var pendingChat: ContainerRef?
    @State private var sending = false
    @State private var sendError: String?
    @State private var mode: ApprovalMode?
    @State private var workOn: WorkOnChoice = .folder
    @State private var recent: [RecentFolder] = []
    @State private var picking = false
    /// Start in Plan: the agent proposes a plan before it changes anything (folder projects).
    @State private var plan = false
    private var target: Target {
        get {
            if targetRaw.hasPrefix("project:") { return .project(String(targetRaw.dropFirst(8))) }
            if targetRaw.hasPrefix("agent:") { return .agent(String(targetRaw.dropFirst(6))) }
            if targetRaw.hasPrefix("team:") { return .team(String(targetRaw.dropFirst(5))) }
            return .chat
        }
        nonmutating set {
            switch newValue { case .chat: targetRaw = "chat"; case .project(let id): targetRaw = "project:" + id; case .agent(let id): targetRaw = "agent:" + id; case .team(let id): targetRaw = "team:" + id }
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

    enum Target: Hashable { case chat, project(String), agent(String), team(String) }

    private var areas: AreaSet { Areas.shared.set }

    /// A team (docs/spec/19): the message goes to its lead, who plans it and hands out the tasks.
    private var team: TeamInfo? {
        if case .team(let id) = target { return engine.teams.first { $0.id == id } }
        return nil
    }

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
        if let team { return "What should \(team.name) do?" }
        return "Ask anything, or @ a project or an agent…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
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
                // The same footer as a conversation's composer (Composer.box): attach and permissions on the left,
                // the model and send on the right, so the box reads the same before and after it starts.
                HStack(spacing: 2) {
                    if agent == nil { AttachButton(pick: attach, help: "Add files, photos or PDFs (⌘U)") }
                    if project != nil {
                        if buildOn { permissionsMenu } else { Text(ApprovalMode.readOnly.title).font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(.horizontal, 6) }
                    }
                    Spacer(minLength: 6)
                    if agent == nil {
                        Button { showModels = true } label: { Text(modelLabel) }
                            .buttonStyle(ComposerChipStyle())
                            .popover(isPresented: $showModels, arrowEdge: .bottom) {
                                ModelPicker(engine: engine, selected: model ?? defaultModel, role: project != nil ? .build : .chat) { m in model = m; showModels = false }
                            }
                    }
                    SendButton(enabled: !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: send)
                        .accessibilityLabel(sendLabel)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.top, 12)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.bottom, 10)
            .composerBox()
            // Sending moves this box into the conversation's composer (the same morph the start pages used).
            .composerMorph()
            // Before Return: where it goes, and whether Piopio may change anything (18 §4). Nothing without a folder.
            if let line = whereLine {
                Text(line).font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.leading, 14)
                    .accessibilityLabel(line)
            }
        }
        .onChange(of: text) { _, t in mention(t); saveHomeDraft() }
        .onChange(of: targetRaw) { _, _ in mode = nil; workOn = .folder; plan = false }
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

    /// Where this goes (docs/spec/18 §4): a popover with search over projects, folders on this Mac and agents.
    private var targetMenu: some View {
        Button { picking = true } label: {
            HStack(spacing: 5) {
                Image(systemName: project != nil ? "folder" : agent != nil ? "person.crop.circle" : team != nil ? "person.3" : "bubble.left").font(.system(size: 11))
                Text(targetLabel)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
        }
        .buttonStyle(ChipStyle()).fixedSize()
        .help("Where this goes: no project, a project, or an agent")
        .accessibilityLabel("Where this goes: \(targetLabel)")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            TargetPicker(engine: engine, recent: recent, current: target, workOn: project?.branch != nil ? $workOn : nil) { choice in
                picking = false
                switch choice {
                case .target(let t): target = t
                case .folder(let url): Task { await use(url) }
                case .openFolder: openFolder()
                case .newProject: NotificationCenter.default.post(name: .newProject, object: nil)
                }
                focused = true
            }
        }
    }

    private var permissionsMenu: some View {
        Menu {
            ForEach(ApprovalMode.allCases) { m in
                if m == .fullAuto { Divider() }
                Button { mode = m; plan = false } label: {
                    if !plan && m == effectiveMode { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    Text(m.summary)
                }
            }
            Divider()
            Button { plan = true } label: {
                if plan { Label("Plan", systemImage: "checkmark") } else { Text("Plan") }
                Text("Looks around and writes a plan for you to approve first")
            }
            if let project, !plan, effectiveMode != project.approvalMode {
                Divider()
                Button("Use “\(effectiveMode.title)” for new conversations in \(project.name)") {
                    Task { await engine.setApprovalMode(effectiveMode, for: project); mode = nil }
                }
            }
        } label: { Text(plan ? "Plan" : effectiveMode.title).foregroundStyle(!plan && effectiveMode == .fullAuto ? Color.accentColor : Color.dsFg2) }
            .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.hidden).fixedSize()
            .help(effectiveMode.summary)
            .accessibilityLabel("Permissions: \(effectiveMode.title)")
    }

    /// "In piopio · can edit files; asks before commands"; nothing with no project (it can't touch files).
    private var whereLine: String? {
        if let team { return "A new conversation with \(team.name)'s lead in \(URL(fileURLWithPath: team.cwd).lastPathComponent) · it does small things itself and puts bigger work on the board" }
        guard let project else { return nil }
        let place = switch workOn {
        case .folder: ""
        case .branch: " · on a new branch"
        case .worktree: " · in its own worktree"
        }
        return "In \(project.name)\(place) · \(plan ? "plans first; changes only after you approve the plan" : effectiveMode.line)"
    }

    private var targetLabel: String {
        if let project { return project.name }
        if let agent { return agent.title }
        if let team { return team.name }
        return "No project"
    }

    private var sendLabel: String {
        if let project { return "Start in \(project.name)" }
        if let agent { return "Send to \(agent.title)" }
        if let team { return "Send to \(team.name)" }
        return "Send"
    }

    private var defaultModel: ModelRef? { project != nil ? engine.model(for: .build) : engine.preferredModel }

    /// As the conversation's model chip says it (ModelChip.label).
    private var modelLabel: String {
        let ref = model ?? defaultModel
        return engine.model(ref).map { ModelChip.label($0, engine: engine) } ?? ref?.id ?? "Model"
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

    /// "@name " at the start picks a project or an agent; names with spaces too ("@Kitchen renovation ").
    private func mention(_ t: String) {
        guard t.hasPrefix("@") else { return }
        let rest = t.dropFirst().lowercased()
        if let p = engine.projects.sorted(by: { $0.name.count > $1.name.count }).first(where: { rest.hasPrefix($0.name.lowercased() + " ") }) {
            target = .project(p.id)
            text = String(t.dropFirst(p.name.count + 2))
            return
        }
        if areas.contains(.agents), let a = engine.agents.sorted(by: { $0.title.count > $1.title.count }).first(where: { rest.hasPrefix($0.title.lowercased() + " ") }) {
            target = .agent(a.ref.id)
            text = String(t.dropFirst(a.title.count + 2))
            return
        }
        guard let space = t.firstIndex(of: " ") else { return }
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
            sendConversation(message)
        case .project:
            guard let project else { sendError = "Choose an available project folder."; return }
            sending = true
            let choice = workOn
            let chosenMode = effectiveMode
            let startInPlan = plan
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
                    let ref = try await engine.createBuildSession(in: project, workOn: place, mode: chosenMode, model: model, planMode: startInPlan)
                    let session = engine.thread(ref)
                    await session.open()
                    if await session.send(message, attachments: attachments.map(\.attachment)) {
                        text = ""; attachments = []; saveHomeDraft()
                    }
                    // Either way the conversation exists (on failure its composer keeps the draft for a retry). Home
                    // starts clean next time: no project (docs/spec/18 §4); a project's + preselects it again.
                    target = .chat
                    withAnimation(StartMotion.morph) { item = .session(ref.id) }
                } catch {
                    sendError = ((error as? EngineError)?.message ?? String(describing: error)) + " Nothing was started, and your message is kept."
                }
            }
        case .team:
            // A new conversation with the lead, in the team's project (docs/spec/20 PT4); it shows with the project's.
            guard let team else { sendError = "That team isn't there any more."; return }
            sending = true
            let chosenMode = effectiveMode
            Task {
                defer { sending = false }
                do {
                    let ref = try await engine.createTeamConversation(team, mode: chosenMode, model: model)
                    let session = engine.thread(ref)
                    await session.open()
                    if await session.send(message, attachments: attachments.map(\.attachment)) {
                        text = ""; attachments = []; saveHomeDraft()
                    }
                    target = .chat
                    withAnimation(StartMotion.morph) { item = .session(ref.id) }
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
                    target = .chat
                    UserDefaults.standard.set("Chat", forKey: "agentTab")
                    withAnimation(StartMotion.morph) { item = .agent(id) }
                } else { sendError = thread.error ?? "Couldn't send. Your draft is saved; retry when connected." }
            }
        }
    }

    /// A conversation with no project.
    private func sendConversation(_ message: String) {
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
                text = ""; attachments = []
                target = .chat // Home starts clean next time (docs/spec/18 §4); this also forgets the pending chat
                saveHomeDraft()
                try? await engine.refreshCatalog()
                withAnimation(StartMotion.morph) { item = .chat(ref.id) }
            } else { sendError = thread.error ?? "Couldn't send. Your draft is saved; retry when connected." }
        }
    }
}

/// The target popover (docs/spec/18 §4): search, then No project, projects, folders on
/// this Mac, Open folder…, New project…, where a git project works, and agents to message.
struct TargetPicker: View {
    enum Choice { case target(AskBox.Target), folder(URL), openFolder, newProject }
    let engine: EngineController
    let recent: [RecentFolder]
    let current: AskBox.Target
    var workOn: Binding<WorkOnChoice>?
    let choose: (Choice) -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    private func matches(_ name: String) -> Bool { query.isEmpty || name.localizedCaseInsensitiveContains(query) }

    var body: some View {
        let projects = engine.projects.filter { $0.missing != true && matches($0.name) }
        let folders = recent.filter { matches($0.url.lastPathComponent) || matches($0.path) }.prefix(query.isEmpty ? 5 : 12)
        let agents = Areas.shared.contains(.agents) ? engine.agents.filter { matches($0.title) } : []
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                TextField("Search projects and agents", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
                    .onSubmit { if let first = projects.first { choose(.target(.project(first.id))) } else if let a = agents.first { choose(.target(.agent(a.ref.id))) } }
            }
            .padding(.horizontal, 12).frame(height: 38)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty { row("No project", symbol: "bubble.left", on: current == .chat) { choose(.target(.chat)) } }
                    if !projects.isEmpty {
                        header("Projects")
                        ForEach(projects) { p in
                            row(p.name, symbol: "folder", on: current == .project(p.id)) { choose(.target(.project(p.id))) }
                        }
                    }
                    if !folders.isEmpty {
                        header("Folders on this Mac")
                        ForEach(Array(folders)) { f in row(f.url.lastPathComponent, detail: f.path, symbol: "folder.badge.plus", on: false) { choose(.folder(f.url)) } }
                    }
                    if !agents.isEmpty {
                        header("Message an agent")
                        ForEach(agents, id: \.ref.id) { a in row(a.title, symbol: "person.crop.circle", on: current == .agent(a.ref.id)) { choose(.target(.agent(a.ref.id))) } }
                    }
                    if let workOn, query.isEmpty {
                        header("Work on")
                        ForEach(WorkOnChoice.allCases, id: \.self) { c in row(c.title, detail: c.summary, symbol: "arrow.triangle.branch", on: workOn.wrappedValue == c) { workOn.wrappedValue = c } }
                    }
                    Divider().padding(.vertical, 4)
                    row("Open folder…", symbol: "folder", on: false) { choose(.openFolder) }
                    row("New project…", symbol: "plus", on: false) { choose(.newProject) }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 320)
        .onAppear { searching = true }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsFg3).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }

    private func row(_ title: String, detail: String? = nil, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle) }
                }
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg2) }
            }
            .padding(.horizontal, 12).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    /// Puts the cursor in the box (⌘N, a project's +).
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
