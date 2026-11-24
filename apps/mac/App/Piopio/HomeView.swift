import PiopioKit
import PiopioTranscript
import SwiftUI

/// Home, the landing screen and the one start (docs/spec/18 §4, design docs/design/home 3a): the date and a greeting,
/// the box where you write with piopio perched on it, then one panel with three tabs: what's waiting on you (with its
/// action in the row), what happened while you were away, and today, as a timeline of every routine, agents' and
/// projects'. A tab shows only with something in it. With nothing in any of them (3b), the box moves to the middle of
/// the page and one quiet line says so.
struct HomeView: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var agenda: HomeAgenda? = HomeView.lastAgenda
    /// The agenda from the last visit: coming back to Home doesn't flash the empty state while it loads.
    @MainActor private static var lastAgenda: HomeAgenda?
    /// Your last visit: "While you were away" starts there.
    @AppStorage("homeLastVisit") private var lastVisit = ""
    /// The tab you picked; the first one with something in it until then.
    @State private var tab: Tab?
    /// The waiting row that's open (its full card), and whether all of them show.
    @State private var expanded: String?
    @State private var showAll = false
    /// What a notification or the menu bar's Inbox pointed at: Home opens that row.
    @AppStorage("inboxFocus") private var focus = ""
    @State private var height: CGFloat = 0
    private let piopio = Piopio.shared

    enum Tab: Hashable, CaseIterable {
        case waiting, away, today
        var title: String {
            switch self {
            case .waiting: "Waiting on you"
            case .away: "While you were away"
            case .today: "Today"
            }
        }
    }

    /// Home's coordinate space: where the pointer is, for piopio's eyes.
    static let space = "home"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if isEmpty { empty } else { normal }
            }
            .coordinateSpace(.named(Self.space))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                if case .active(let point) = phase { piopio.pointer(point) }
            }
            .task {
                let since = lastVisit.isEmpty ? nil : lastVisit
                agenda = await engine.homeAgenda(since: since)
                Self.lastAgenda = agenda
            }
            .task {
                // Re-read the clock each minute: piopio's mood and the greeting follow it.
                while !Task.isCancelled {
                    piopio.refreshMood()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in piopio.refreshMood() }
            .task(id: focus) { reveal(proxy) }
            .onChange(of: engine.needsYouCount) { reveal(proxy) }
        }
        .onDisappear { lastVisit = ISO8601DateFormatter().string(from: .now) }
    }

    /// Opens and scrolls to the row a notification pointed at, once it's there.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard !focus.isEmpty else { return }
        let entries = Array(engine.needsYou.reversed())
        guard let i = entries.firstIndex(where: { $0.matches(focus) }) else { return }
        focus = ""
        tab = .waiting
        if i >= Self.shown { showAll = true }
        expanded = entries[i].id
        withAnimation { proxy.scrollTo(entries[i].id, anchor: .center) }
    }

    /// Rows before "Show N more".
    static let shown = 5

    // MARK: Layout

    /// 3a: the greeting and the box, then the tabs.
    private var normal: some View {
        VStack(alignment: .leading, spacing: 36) {
            top(AskBox.Perch(model: piopio, size: 47, trailing: 28, top: 40))
            if !tabs.isEmpty { panel }
        }
        .frame(maxWidth: 660)
        .padding(.horizontal, 32)
        .padding(.top, 72)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity)
    }

    /// 3b: only the prompt, in the middle (nudged up), and one line that all is quiet.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            top(AskBox.Perch(model: piopio, size: 56, trailing: 26, top: 44))
            HStack(spacing: 8) {
                Circle().fill(StatusTone.ready.dot).frame(width: 6, height: 6)
                Text("All quiet. When something needs you, it'll show up here.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
            }
            .padding(.top, 18)
            .padding(.leading, 6)
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, minHeight: height)
        .offset(y: -60)
    }

    private func top(_ perch: AskBox.Perch) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                Text(piopio.mood.greeting(name: Self.firstName, date: .now)).font(.system(size: 32, weight: .semibold)).tracking(-0.8).foregroundStyle(Color.dsFg)
            }
            AskBox(engine: engine, item: $item, perch: perch)
        }
    }

    static func salutation(_ date: Date = .now) -> String { PiopioMood.salutation(date) }

    static var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    // MARK: Tabs

    private var hasAway: Bool { !(agenda?.away ?? []).isEmpty }
    private var hasToday: Bool { !(agenda?.today ?? []).isEmpty || (agenda?.held ?? 0) > 0 }
    private var waitingCount: Int { engine.needsYou.count + readyToMerge.count }

    /// The tabs with something in them.
    private var tabs: [Tab] {
        Tab.allCases.filter { t in
            switch t {
            case .waiting: waitingCount > 0
            case .away: hasAway
            case .today: hasToday
            }
        }
    }

    /// Nothing waiting, nothing while you were away, nothing today (once the agenda is in).
    private var isEmpty: Bool { agenda != nil && tabs.isEmpty }

    private var current: Tab { tab.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first ?? .waiting }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeTabs(tabs: tabs, selected: current, count: waitingCount) { t in tab = t }
            VStack(alignment: .leading, spacing: 0) {
                switch current {
                case .waiting: waiting
                case .away: away
                case .today: today
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.composer, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.composer, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        }
    }

    // MARK: Waiting on you

    /// Projects whose finished board work waits to be merged (open the project's Board).
    private var readyToMerge: [(work: ProjectWork, project: ProjectInfo, tasks: Int)] {
        engine.work.compactMap { w in
            guard w.git != nil, !w.tasks.contains(where: { ["todo", "doing", "review", "integrating"].contains($0.state) }),
                  let p = engine.projects.first(where: { $0.id == w.project }) else { return nil }
            let n = w.tasks.filter { $0.state == "done" && $0.branch != nil && $0.landed == nil }.count
            return n > 0 ? (w, p, n) : nil
        }
    }

    @ViewBuilder private var waiting: some View {
        let entries = Array(engine.needsYou.reversed())
        let ready = readyToMerge
        ForEach(showAll ? entries : Array(entries.prefix(Self.shown))) { entry in
            WaitingItem(engine: engine, entry: entry, item: $item, expanded: $expanded).id(entry.id)
        }
        if entries.count > Self.shown {
            Button(showAll ? "Show fewer" : "Show \(entries.count - Self.shown) more") { withAnimation(.snappy(duration: 0.18)) { showAll.toggle() } }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .contentShape(Rectangle())
        }
        if !ready.isEmpty {
            if !entries.isEmpty { Rectangle().fill(Color.dsTrack).frame(height: 1).padding(.top, 2) }
            ForEach(ready, id: \.work.id) { r in
                HStack(spacing: 12) {
                    StatusTile(tone: .ready)
                    Text("\(r.project.name) · \(r.tasks) task\(r.tasks == 1 ? "" : "s") ready for \(r.work.git?.base ?? "main")")
                        .font(.system(size: 13.5)).foregroundStyle(Color.dsFg).lineLimit(1)
                    Spacer(minLength: 12)
                    Button("Review") { item = .board(r.project.id) }.buttonStyle(HomePillStyle())
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
            }
        }
    }

    // MARK: While you were away

    @ViewBuilder private var away: some View {
        ForEach(Array((agenda?.away ?? []).prefix(6).enumerated()), id: \.offset) { _, line in
            Button { open(line.source, automation: line.automation) } label: {
                HStack(spacing: 12) {
                    Text(String(line.source.name.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsFg2)
                        .frame(width: 28, height: 28)
                        .background(Color.dsChip, in: Circle())
                    (Text(line.source.name).fontWeight(.medium) + Text(line.automation == nil ? " \(line.text)" : " · \(line.text)"))
                        .font(.system(size: 13.5)).foregroundStyle(line.quiet ? Color.dsFg3 : Color.dsFg)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Circle().fill(line.failed == true ? StatusTone.approval.dot : line.quiet ? Color.dsFg3.opacity(0.55) : StatusTone.ready.dot)
                        .frame(width: 6, height: 6)
                    Text(Self.clock(line.at)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
                        .frame(minWidth: 38, alignment: .trailing)
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(HomeRowStyle())
        }
    }

    // MARK: Today

    @ViewBuilder private var today: some View {
        let rows = agenda?.today ?? []
        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
            // Past midnight: what's next tomorrow, under a divider.
            if row.tomorrow == true, i == 0 || rows[i - 1].tomorrow != true {
                Text("Tomorrow").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsFg3).padding(.leading, 12).padding(.top, 10).padding(.bottom, 2)
            }
            timelineRow(row)
        }
        if let held = agenda?.held, held > 0 {
            Text("\(held) message\(held == 1 ? "" : "s") held until quiet hours end").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
        }
    }

    /// A timeline row: the time ("now" while it runs, "any" for an event), what, and whose on the right. Past rows are
    /// grey with ✓ or ⚠; the running one is highlighted.
    private func timelineRow(_ row: HomeAgenda.Today) -> some View {
        let past = ["done", "failed", "skipped"].contains(row.state)
        let now = row.state == "running"
        // An agent's own schedule has no label: the row is the agent.
        let label = row.label.isEmpty ? row.source.name : row.label.capitalizedFirst
        let origin = row.label.isEmpty ? row.source.kind : row.source.name + (now && row.source.kind == "project" ? " · board" : "")
        let mark = row.state == "done" ? " ✓" : row.state == "failed" ? " ⚠" : ""
        return Button { open(row.source, automation: row.automation) } label: {
            HStack(spacing: 12) {
                Text(now ? "now" : row.at.map(Self.clock) ?? "any")
                    .font(.system(size: 12.5, weight: now ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(now ? Color.accentColor : past ? Color.dsFg3.opacity(0.8) : Color.dsFg2)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: 48, alignment: .leading)
                (Text(label).foregroundStyle(past ? Color.dsFg3 : Color.dsFg).fontWeight(now ? .semibold : .regular) + Text(mark).foregroundStyle(Color.dsFg3))
                    .font(.system(size: 13.5)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(origin).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(now ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeRowStyle())
    }

    /// A line that belongs to an automation opens it (docs/spec/27 AU10); a board's opens the project.
    private func open(_ source: HomeAgenda.Source, automation: String? = nil) {
        if let automation { item = .automation(automation); return }
        switch source.kind {
        case "agent": item = .agent(source.id)
        case "piopio": item = .automations("piopio")
        default: item = .project(source.id)
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

/// Home's tabs (design 3a): a segmented control on the left, the selected tab white with a soft shadow; "Waiting on
/// you" carries its count.
private struct HomeTabs: View {
    let tabs: [HomeView.Tab]
    let selected: HomeView.Tab
    let count: Int
    let select: (HomeView.Tab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { t in
                let on = t == selected
                Button { withAnimation(.snappy(duration: 0.18)) { select(t) } } label: {
                    HStack(spacing: 6) {
                        Text(t.title)
                        if t == .waiting {
                            Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(StatusTone.badge, in: Capsule())
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dsFg)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dsSeg)
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.dsTrack, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// A status tile (design 3a): 28pt, tinted, with an 8pt dot.
struct StatusTile: View {
    let tone: StatusTone

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tone.tint)
            .frame(width: 28, height: 28)
            .overlay(Circle().fill(tone.dot).frame(width: 8, height: 8))
    }
}

/// A row action on Home (design 3a): a pill, 12.5pt. Primary is black; secondary has a hairline.
struct HomePillStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View { HomePillBody(configuration: configuration, primary: primary) }
}

private struct HomePillBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: primary ? .medium : .regular))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, primary ? 12 : 11).padding(.vertical, 5)
            .foregroundStyle(primary ? Color.dsInvFg : Color.dsFg)
            .background(primary ? Color.dsInv : hovering ? Color.dsChip : .clear, in: Capsule())
            .overlay { if !primary { Capsule().strokeBorder(Color.dsLine, lineWidth: 1) } }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// A clickable row on Home: a faint fill on hover, radius 10.
struct HomeRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HomeRowBody(configuration: configuration) }
}

private struct HomeRowBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Color.dsChip.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
    }
}

/// The one start (docs/spec/18 §4): write, and choose where it goes in the box itself. No project is a chat; a project
/// with a folder is a conversation there, with permissions (Read only, Ask, Auto-edit, Full auto) said in a chip and in
/// a line under the box; an agent gets the message. One Return sends it, whatever the target.
struct AskBox: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    /// On a project's page (18 §18): the box starts in that project, with its own target and draft, apart from Home's.
    var projectId: String?
    /// The line under the box (where it goes, what it may do). The New conversation page puts it in the permissions'
    /// tooltip instead (18 §20).
    var showsWhere = true
    /// The New conversation page's box: a little larger, and a placeholder that doesn't repeat the title.
    var prominent = false
    /// Home's box: piopio sits on its top edge, looks down while you type and hops when you send.
    var perch: Perch?
    @State private var text = ""
    /// A restored draft isn't typing.
    @State private var restoring = false
    /// "chat", "project:<id>" or "agent:<id>"; the start routes set it (⌘N, ⌘O, a project's +).
    /// Back to "chat" (no project) after each send, so a loose question never lands in the last project.
    @AppStorage private var targetRaw: String

    /// Where piopio sits: `trailing` from the box's right edge, its top `top` above the box's.
    struct Perch {
        let model: Piopio
        var size: CGFloat
        var trailing: CGFloat
        var top: CGFloat
    }

    init(engine: EngineController, item: Binding<SidebarItem>, projectId: String? = nil, showsWhere: Bool = true, prominent: Bool = false, perch: Perch? = nil) {
        self.engine = engine
        _item = item
        self.projectId = projectId
        self.showsWhere = showsWhere
        self.prominent = prominent
        self.perch = perch
        _targetRaw = AppStorage(wrappedValue: projectId.map { "project:" + $0 } ?? "chat", projectId.map { "projectBoxTarget:" + $0 } ?? "homeTarget")
    }

    /// Where the draft is kept: Home's box and the start pages share "home"; a project page has its own.
    private var draftKey: String { projectId.map { "project:" + $0 } ?? "home" }
    @State private var pendingChat: ContainerRef?
    @State private var sending = false
    @State private var sendError: String?
    @State private var mode: ApprovalMode?
    @State private var workOn: WorkOnChoice = .folder
    @State private var recent: [RecentFolder] = []
    @State private var picking = false
    /// Start in Plan: the agent proposes a plan before it changes anything (folder projects).
    @State private var plan = false
    /// A temporary chat (docs/spec/14 M4): no project only, for this one chat; New Temporary Chat (⌃⌘N) turns it on.
    @State private var temporary = false
    /// Set by New Temporary Chat before the start page shows, so the box it opens starts temporary.
    @MainActor static var nextIsTemporary = false
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
        do { try DraftStore(home: engine.home).save(ComposerDraft(text: text, destination: pendingChat), for: draftKey) }
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
        if prominent, project != nil { return "Ask, or describe a task…" }
        if let project { return "What should we do in \(project.name)?" }
        if let agent { return "Message \(agent.title)…" }
        return "Ask anything, or @ a project or an agent…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
            // What went wrong, glued to the top of the box (docs/design/grey "Composer notice").
            if let sendError {
                ComposerNoticeStrip(notice: ComposerNotice(id: "send", symbol: "exclamationmark.triangle", title: sendError, dismiss: { self.sendError = nil }))
            }
            VStack(alignment: .leading, spacing: 14) {
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.dsFg3), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.horizontal, 4)
                if !attachments.isEmpty { attachmentTiles }
                // Attach, where it goes (18 §16) as a pill and permissions on the left; the model, muted, and send on
                // the right (docs/design/home 3a).
                HStack(spacing: 8) {
                    if agent == nil { AttachButton(pick: attach, help: "Add files, photos or PDFs (⌘U)", size: 28) }
                    targetMenu
                    if target == .chat, agent == nil { temporaryChip }
                    if project != nil {
                        if buildOn { permissionsMenu } else { Text(ApprovalMode.readOnly.title).font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(.horizontal, 6) }
                    }
                    Spacer(minLength: 6)
                    if agent == nil {
                        Button { showModels = true } label: {
                            if let m = engine.model(model ?? defaultModel) { ModelLabel(model: m, engine: engine) } else { Text(modelLabel) }
                        }
                            .buttonStyle(ComposerChipStyle(muted: true))
                            .popover(isPresented: $showModels, arrowEdge: .bottom) {
                                ModelPicker(engine: engine, selected: model ?? defaultModel, role: project != nil ? .build : .chat, agents: true) { m in model = m; showModels = false }
                            }
                    }
                    SendButton(enabled: !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, size: 30, action: send)
                        .accessibilityLabel(sendLabel)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .font(.system(size: 13))
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            }
            .askBoxCard()
            // Sending moves this box into the conversation's composer (the same morph the start pages used).
            .composerMorph()
            .overlay(alignment: .topTrailing) {
                if let perch {
                    PiopioPerch(model: perch.model, size: perch.size)
                        .padding(.trailing, perch.trailing)
                        .offset(y: -perch.top)
                }
            }
            // Before Return: where it goes, and whether Piopio may change anything (18 §4). Nothing without a folder.
            if temporary, target == .chat {
                Label { Text("Temporary · ").foregroundStyle(Color.dsFg) + Text(temporaryLine) } icon: { Image(systemName: "timer").foregroundStyle(Color.dsTemporary) }
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                    .padding(.top, 10).padding(.leading, 6)
                    .fixedSize(horizontal: false, vertical: true)
            } else if showsWhere, let line = whereLine {
                Text(line).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    .padding(.top, 10).padding(.leading, 6)
                    .accessibilityLabel(line)
            }
        }
        .onChange(of: text) { _, t in
            mention(t); saveHomeDraft()
            if restoring { restoring = false } else { perch?.model.typed(t) }
        }
        .onChange(of: targetRaw) { _, _ in mode = nil; workOn = .folder; plan = false; if target != .chat { temporary = false } }
        .onChange(of: temporary) { _, on in if projectId == nil { StartDrafts.shared.temporaryChat = on } }
        // Only the box that made it temporary clears it: Home's box disappears after the New conversation page appears.
        .onDisappear { if projectId == nil, temporary { StartDrafts.shared.temporaryChat = false } }
        // New Temporary Chat while the New conversation page is already open (it opens there otherwise: onAppear).
        // Home's box only answers when asked by name (captures), so it can't take the flag the page is waiting for.
        .onReceive(NotificationCenter.default.publisher(for: .newTemporaryChat)) { note in
            guard projectId == nil, prominent || note.object as? String == "home" else { return }
            target = .chat; temporary = true; Self.nextIsTemporary = false; focused = true
        }
        .onAppear {
            // A project page's box starts in its project each time it opens.
            if let projectId { targetRaw = "project:" + projectId }
            if let saved = DraftStore(home: engine.home).load(draftKey) {
                if saved.text != text { restoring = true; text = saved.text }
                pendingChat = saved.destination
            }
            if case .project = target, project == nil { target = .chat }
            if case .agent = target, agent == nil { target = .chat }
            if Self.nextIsTemporary, projectId == nil { target = .chat; temporary = true; Self.nextIsTemporary = false }
            focused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusHome)) { _ in focused = true }
        .task {
            let known = Set(engine.projects.map(\.path))
            recent = await Task.detached { RecentFolder.scan().filter { !known.contains($0.url.path) } }.value
        }
    }

    // MARK: Temporary (docs/spec/14 M4)

    private var temporaryChip: some View {
        Button { temporary.toggle(); focused = true } label: {
            Label("Temporary", systemImage: "timer")
        }
        .buttonStyle(TemporaryChipStyle(on: temporary))
        .help(temporary ? "Temporary: deleted 24 hours after your last message unless you keep it" : "Make this a temporary chat (⌃⌘N)")
        .accessibilityLabel("Temporary chat")
        .accessibilityValue(temporary ? "On" : "Off")
    }

    private var temporaryLine: String {
        "deleted 24 hours after your last message unless you keep it. Not searched by other conversations, and nothing goes to About me. \(modelLabel)'s provider still receives what you send."
    }

    // MARK: Where it goes

    /// Where this goes (docs/spec/18 §4, §16): in the bottom row, plain text with its icon and no chevron (grey ink,
    /// principle 6); a popover with search over projects, folders on this Mac and agents.
    private var targetMenu: some View {
        Button { picking = true } label: { Text(targetLabel).lineLimit(1) }
        .buttonStyle(TargetPillStyle()).fixedSize()
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
                let locked = m == .fullAuto && project?.allowsFullAccess == false
                Button { mode = m; plan = false } label: {
                    if !plan && m == effectiveMode { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    Text(locked ? ProjectInfo.fullAccessNeedsTrust : m.summary)
                }
                .disabled(locked)
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
            .help(whereLine ?? effectiveMode.summary)
            .accessibilityLabel("Permissions: \(effectiveMode.title)")
    }

    /// "In piopio · can edit files; asks before commands"; with no project, that it can't touch files (18 §16).
    private var whereLine: String? {
        if target == .chat { return "Not in a project · it can't see or change your files" }
        guard let project else { return nil }
        let place = switch workOn {
        case .folder: ""
        case .branch: " · on a new branch"
        case .worktree: " · in its own worktree"
        }
        // Linked folders (18 §18): counted, so you see what a new conversation is given before you send.
        let linked = (project.folders ?? []).filter { $0.missing != true }.count
        let also = linked == 0 ? "" : " and \(linked) linked folder\(linked == 1 ? "" : "s")"
        return "In \(project.name)\(also)\(place) · \(plan ? "plans first; changes only after you approve the plan" : effectiveMode.line)"
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
        perch?.model.sent()
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
            if let pendingChat { destination = pendingChat } else { destination = await engine.createThread(model: model, temporary: temporary) }
            guard let ref = destination else {
                sendError = "Couldn't start a conversation. Your draft is saved; try again when the engine is connected."
                return
            }
            pendingChat = ref; saveHomeDraft()
            if temporary { ThreadView.justStarted.insert(ref.id) }
            let thread = engine.thread(ref)
            await thread.open()
            if await thread.send(message, attachments: attachments.map(\.attachment)) {
                text = ""; attachments = []; temporary = false
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
        // Recent first, each with the permissions its new conversations start with (docs/spec/18 §16).
        let projects = engine.projects.filter { $0.missing != true && matches($0.name) }
            .sorted { (engine.sessions(in: $0).map(\.updatedAt).max() ?? $0.addedAt) > (engine.sessions(in: $1).map(\.updatedAt).max() ?? $1.addedAt) }
        let buildOn = Areas.shared.contains(.build)
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
                            row(p.name, trailing: (buildOn ? p.approvalMode ?? .autoEdit : .readOnly).title, symbol: "folder", on: current == .project(p.id)) { choose(.target(.project(p.id))) }
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

    private func row(_ title: String, detail: String? = nil, trailing: String? = nil, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle) }
                }
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
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
        // docs/design/card-layout: pure white over the card, a 1pt ring and a soft shadow below (0 4 14 · 5%).
        self
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.composer, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.composer, style: .continuous).strokeBorder(Color(nsColor: DS.composerEdge), lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 7, y: 4)
    }

    /// The start box (docs/design/home 3a): card fill, a 1pt line, radius 16, a hairline shadow and a soft one below.
    func askBoxCard() -> some View {
        self
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.composer, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.composer, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.06), radius: 12, y: 8)
    }
}

/// Where the start box sends (docs/design/home 3a): a grey pill, 13pt.
private struct TargetPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TargetPillBody(configuration: configuration) }
}

private struct TargetPillBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Color.dsFg)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.dsChip, in: Capsule())
            .overlay { if hovering || configuration.isPressed { Capsule().fill(Color.dsChip) } }
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// The round send button (28pt; 30 on the start box): grey while there's nothing to send, black once there is.
struct SendButton: View {
    let enabled: Bool
    var symbol = "arrow.up"
    var size: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size > 28 ? 13 : 12, weight: .semibold))
                .foregroundStyle(enabled ? Color.dsInvFg : Color.dsFg3)
                .frame(width: size, height: size)
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


/// The Temporary chip in the box (docs/spec/14 M4): plain like the other chips when off, tinted when on.
struct TemporaryChipStyle: ButtonStyle {
    var on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12.5, weight: on ? .medium : .regular))
            .foregroundStyle(on ? Color.dsTemporary : Color.dsFg2)
            .padding(.horizontal, 9).frame(height: 26)
            .background(Capsule().fill(on ? Color.dsTemporaryTint : (configuration.isPressed ? Color.dsChip : Color.clear)))
            .contentShape(Capsule())
    }
}
