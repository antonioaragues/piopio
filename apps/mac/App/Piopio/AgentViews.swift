import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Agents mode, local agents (docs/spec/06-agents, docs/design 2c, 6a): the sidebar list, the new agent sheet and the
// agent page: Chat (the owner's conversation, the in-app channel), Conversations (everyone the agent talks with,
// and the channel simulator), Memory (partitions as banks) and Definition (the form over agent.json, with history).

extension Notification.Name {
    static let newAgent = Notification.Name("piopio.newAgent")
}

/// agent.json v1, for the form editor. Fields the form doesn't edit pass through as JSON.
struct AgentDef: Codable, Equatable {
    struct Models: Codable, Equatable { var `default`: String; var utility: String? }
    struct Tools: Codable, Equatable { var builtin: [String]; var mcp: JSONValue?; var apple: [String]?; var shortcuts: [String]?; var agents: [String]? }
    struct Contact: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var role: String
        var channels: [String: String]?
        var preferred: String?
        var notes: String?
    }
    struct Schedule: Codable, Equatable, Identifiable { var id: String; var cron: String; var tz: String?; var prompt: String; var deliverTo: String? }
    struct Policies: Codable, Equatable { var quietHours: String?; var maxOutboundPerDay: Int?; var maxOutboundPerContactPerDay: Int?; var urgentBypassesQuiet: Bool?; var agentMessagesPerHour: Int?; var traceBudgetUsd: Double?; var budgetUsdPerMonth: Double?; var requireApproval: [String]?; var unknownSenders: String? }
    var version: Int
    var id: String
    var slug: String
    var name: String
    var avatar: String?
    var description: String?
    var models: Models
    var thinking: String?
    var timezone: String?
    var tools: Tools
    var contacts: [Contact]
    var channels: JSONValue?
    var schedules: [Schedule]?
    var heartbeat: JSONValue?
    var triggers: JSONValue?
    var policies: Policies?
    var memory: JSONValue?
    /// Agents that may write to this one (unset: every agent), and partitions shared with other agents (06-agents §7).
    var acceptFrom: [String]?
    var shareMemory: [String: [String]]?

    init?(_ json: JSONValue) {
        guard let data = try? JSONEncoder().encode(json), let def = try? JSONDecoder().decode(AgentDef.self, from: data) else { return nil }
        self = def
    }

    var json: JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))) ?? .null }
}

/// The circle with the agent's emoji (or initial).
struct AgentAvatar: View {
    let summary: SessionSummary
    var size: CGFloat = 24

    var body: some View {
        let avatar = summary.agent?.avatar
        ZStack {
            Circle().fill(Color.accentColor.opacity(avatar == nil ? 0.85 : 0.14))
            Text(avatar ?? String(summary.title.prefix(1)).uppercased())
                .font(.system(size: avatar == nil ? size * 0.45 : size * 0.55, weight: .semibold))
                .foregroundStyle(avatar == nil ? Color.white : Color.dsFg)
        }
        .frame(width: size, height: size)
    }
}

// MARK: Sidebar

// MARK: New agent

/// A template (or from scratch), a name and an avatar (AD4). Channels, contacts and schedules come in the Definition tab.
struct NewAgentSheet: View {
    let engine: EngineController
    let created: (ContainerRef) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [AgentTemplate] = []
    @State private var template: String?
    @State private var name = ""
    @State private var avatar = ""
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New agent").font(.system(size: 17, weight: .bold))
            Text("Agents run on schedules, keep their own memory and talk with you and the people you choose. This one runs on this Mac.")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                tile(id: nil, avatar: "✳︎", name: "From scratch", description: "Instructions you write")
                ForEach(templates) { t in tile(id: t.id, avatar: t.avatar, name: t.name, description: t.description) }
            }
            HStack(spacing: 8) {
                AvatarPicker(avatar: $avatar)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create Agent") { create() }
                    .buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task { templates = await engine.agentTemplates() }
    }

    private func tile(id: String?, avatar: String, name: String, description: String) -> some View {
        Button {
            template = id
            if self.name.isEmpty || templates.contains(where: { $0.name == self.name }) || self.name == "From scratch" { self.name = id == nil ? "" : name }
            self.avatar = id == nil ? "" : avatar
        } label: {
            HStack(spacing: 10) {
                Text(avatar).font(.system(size: 20))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
                    Text(description).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(template == id ? Color.dsAccentSoft : Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(template == id ? Color.dsAccentLine : Color.dsLine, lineWidth: template == id ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func create() {
        creating = true
        error = nil
        Task {
            do {
                let ref = try await engine.createAgent(name: name.trimmingCharacters(in: .whitespaces), template: template, avatar: avatar.trimmingCharacters(in: .whitespaces))
                created(ref)
                dismiss()
            } catch {
                self.error = (error as? EngineError)?.message ?? String(describing: error)
                creating = false
            }
        }
    }
}

// MARK: Agent page

/// An agent (docs/design/grey 13a): one conversation, and an info panel like a contact card (what it does, when, what
/// it can do, where it reaches you, what it remembers, what it costs). Its runs and full setup open from the panel in
/// place of the conversation, with a breadcrumb back.
struct AgentPage: View {
    let engine: EngineController
    let summary: SessionSummary
    @Binding var selection: String?
    @AppStorage("agentTab") private var tab: Tab = .chat
    @AppStorage("agentInfo") private var showInfo = true
    /// Whose conversation shows: the owner's (nil), a contact's (`person:<id>`), another agent's (`agent:<id>`).
    @State private var conversation: String?
    @State private var people: [AgentPerson] = []
    @State private var runs: AgentRunsResult?
    @State private var def: AgentDef?
    @State private var instructions = ""

    /// What the main area shows: the conversation, or the runs or the setup opened from the info panel.
    enum Tab: String, CaseIterable { case chat = "Chat", activity = "Activity", setup = "Setup" }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch tab {
            case .chat:
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        chat
                        if showInfo && proxy.size.width >= 760 {
                            AgentInfoPanel(engine: engine, summary: summary, def: def, instructions: instructions, runs: runs, tab: $tab) { await load() }
                                .frame(width: 300).sidePanel()
                        }
                    }
                }
            case .activity: AgentRunsView(engine: engine, summary: summary)
            case .setup: AgentDefinitionView(engine: engine, summary: summary)
            }
        }
        .task(id: summary.updatedAt) { await load() }
        .onAppear { openSearchTarget() }
        .onChange(of: engine.searchTarget?.id) { _, _ in openSearchTarget() }
    }

    private func openSearchTarget() {
        guard let target = engine.searchTarget, target.ref.kind == .agent, target.ref.id == summary.ref.id else { return }
        conversation = target.ref.conversationId
        tab = .chat
    }

    private func load() async {
        people = await engine.agentPeople(summary.ref)
        runs = await engine.agentRuns(summary.ref)
        if let got = await engine.agentDefinition(summary.ref) {
            def = AgentDef(got.definition)
            instructions = got.instructions
        }
    }

    @ViewBuilder private var chat: some View {
        let person = people.first { $0.conversationId == conversation }
        if let conversation, conversation.hasPrefix("run:") || person?.role == "agent" {
            AgentRunTranscript(engine: engine, ref: ContainerRef(kind: .agent, id: summary.ref.id, conversationId: conversation))
        } else if let conversation, let person, person.role != "owner" {
            AgentChat(engine: engine, ref: ContainerRef(kind: .agent, id: summary.ref.id, conversationId: conversation), simulated: person.name)
        } else {
            AgentChat(engine: engine, ref: summary.ref, simulated: nil)
        }
    }

    /// "Daily briefing  Next run tomorrow at 8:00", then Run now and the info toggle. In Activity or Setup the title is
    /// a breadcrumb back to the conversation.
    private var header: some View {
        PageHeader {
            if tab == .chat {
                PageTitle(name: summary.title, subtitle: statusLine)
            } else {
                HStack(spacing: 6) {
                    Button(summary.title) { tab = .chat }.buttonStyle(.plain).font(.system(size: 13.5)).foregroundStyle(Color.dsFg2)
                    Text("/").font(.system(size: 13.5)).foregroundStyle(Color.dsFg3)
                    Text(tab == .activity ? "Activity" : "Setup").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg)
                }
            }
        } actions: {
            if summary.agent?.invalid == true {
                Button("Setup has errors") { tab = .setup }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            }
            if tab == .chat && people.count > 1 { personPicker }
            if tab == .chat {
                Button("Run now") { runNow() }.buttonStyle(PillStyle(kind: .toolbar))
                Menu {
                    if let status = summary.agent?.status {
                        Button(status.paused ? "Resume" : "Pause") { Task { try? await engine.pause(summary.ref, paused: !status.paused) } }
                    }
                    Button("Activity") { tab = .activity }
                    Button("Full Setup") { tab = .setup }
                    Divider()
                    Button("Reveal Definition in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.agent?.folder ?? "")]) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize()
                Button { withAnimation(.easeOut(duration: 0.15)) { showInfo.toggle() } } label: { Image(systemName: "info.circle") }
                    .buttonStyle(IconButtonStyle(on: showInfo))
                    .help(showInfo ? "Hide the info panel" : "What it does, when, and what it can do")
            } else {
                Button("Back to the conversation") { tab = .chat }.buttonStyle(PillStyle(kind: .toolbar))
            }
        }
    }

    /// "Next run tomorrow at 8:00", "Paused".
    private var statusLine: String {
        if summary.agent?.status?.paused == true { return "Paused" }
        if let next = summary.agent?.status?.nextRun { return "Next run \(HomeView.at(next).prefix(1).lowercased() + HomeView.at(next).dropFirst())" }
        return ""
    }

    private var personPicker: some View {
        let current = people.first { $0.conversationId == conversation }
        let ownerName = people.first { $0.role == "owner" }?.name ?? "you"
        return Menu {
            Button("\(ownerName) (you)") { conversation = nil }
            let others = people.filter { $0.role != "owner" }
            if !others.isEmpty {
                Divider()
                ForEach(others) { p in
                    Button(p.role == "agent" ? "\(p.name) (agent)" : p.name) { conversation = p.conversationId }
                }
            }
        } label: {
            Text(current.map { $0.role == "owner" ? "with \($0.name) (you)" : "with \($0.name)" } ?? "with \(ownerName) (you)")
        }
        .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.hidden).fixedSize()
        .help("Whose conversation to show (contacts' are simulated here until channels arrive)")
    }

    private func runNow() {
        Task {
            let upcoming = runs?.upcoming.first { $0.kind == "schedule" }
            _ = try? await engine.agentRunNow(summary.ref, scheduleId: upcoming?.id, prompt: upcoming == nil ? "Run your usual check now." : nil)
            await load()
        }
    }
}

/// The info panel (docs/design/grey 13a), like a contact card: Does, When, Can (switches), Reaches you in, Remembers,
/// Activity, and a footer with the model, where it runs and what it cost this month.
private struct AgentInfoPanel: View {
    let engine: EngineController
    let summary: SessionSummary
    let def: AgentDef?
    let instructions: String
    let runs: AgentRunsResult?
    @Binding var tab: AgentPage.Tab
    let reload: () async -> Void
    @State private var facts: [MemoryRecordInfo] = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dsFg)
                        if let line = def?.description ?? summary.agent?.description, !line.isEmpty {
                            Text(line).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section("Does", action: ("Edit", { tab = .setup })) {
                        Text(does).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineSpacing(2).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    }
                    section("When", action: ("Change", { tab = .setup })) {
                        let schedules = def?.schedules ?? []
                        if schedules.isEmpty {
                            Text("Only when you write to it").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                        }
                        ForEach(schedules) { s in Text(CronText.describe(s.cron)).font(.system(size: 13)).foregroundStyle(Color.dsFg) }
                    }
                    section("Can") {
                        ability("Search the web", ["web_search", "web_fetch"])
                        ability("Remember things", ["memory"])
                        ability("Message you", ["send_message"])
                        ability("Set reminders", ["schedule"])
                        if !(def?.tools.apple ?? []).isEmpty {
                            row("Use Mac apps") { Text("\(def?.tools.apple?.count ?? 0)").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3) }
                        }
                    }
                    section("Reaches you in") {
                        row("Piopio") { Text("On").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3) }
                    }
                    if !facts.isEmpty {
                        section("Remembers", action: ("See all", { tab = .setup })) {
                            ForEach(facts.prefix(3)) { f in Text(f.text).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(2) }
                        }
                    }
                    if let last = runs?.runs.first {
                        section("Activity", action: ("See all", { tab = .activity })) {
                            Text("Last run \(BuildSessionView.relative(last.firedAt)) · \(last.status == "done" ? (last.sent > 0 ? "sent \(last.sent)" : "nothing sent") : last.status)")
                                .font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                        }
                    }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
                }
                .padding(20)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(model + " · This Mac").font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(1)
                    Spacer()
                    Text(month).font(.system(size: 12)).foregroundStyle(Color.dsFg3).monospacedDigit()
                }
                AgentAvailability(engine: engine, summary: summary, hasMacTools: !(def?.tools.apple ?? []).isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .task(id: summary.updatedAt) { await loadFacts() }
    }

    private func section<Content: View>(_ title: String, action: (String, () -> Void)? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionLabel(title)
                Spacer()
                if let action { Button(action.0, action: action.1).buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2) }
            }
            content()
        }
    }

    private func row<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(Color.dsFg)
            Spacer()
            trailing()
        }
        .frame(minHeight: 22)
    }

    /// A switch for built-in tools; it saves the agent's definition (a commit in its history).
    private func ability(_ title: String, _ tools: [String]) -> some View {
        let on = !(def?.tools.builtin ?? []).filter(tools.contains).isEmpty
        return row(title) {
            Toggle("", isOn: Binding(get: { on }, set: { set(tools, $0, title) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Color.dsInv).disabled(def == nil || saving)
        }
    }

    private func set(_ tools: [String], _ on: Bool, _ title: String) {
        guard var d = def else { return }
        var builtin = d.tools.builtin.filter { !tools.contains($0) }
        if on { builtin += tools }
        d.tools.builtin = builtin
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                _ = try await engine.saveAgent(summary.ref, definition: d.json, instructions: instructions, message: "\(on ? "Allow" : "Stop"): \(title.lowercased())")
                await reload()
            } catch {
                self.error = (error as? EngineError)?.message ?? String(describing: error)
            }
        }
    }

    /// The instructions' first paragraph, without Markdown headings.
    private var does: String {
        let paragraphs = instructions.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let first = paragraphs.first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        return first.isEmpty ? "No instructions yet." : first.replacingOccurrences(of: "\n", with: " ")
    }

    private var model: String {
        engine.model(modelRef(def?.models.default ?? summary.agent?.model)).map(ModelChip.short) ?? def?.models.default ?? "No model"
    }

    private var month: String {
        guard let s = summary.agent?.status else { return "" }
        let spent = s.spendUsd < 0.01 && s.spendUsd > 0 ? String(format: "$%.4f", s.spendUsd) : String(format: "$%.2f", s.spendUsd)
        return (s.budgetUsd.map { "\(spent) of \(MainSidebar.money($0))" } ?? spent) + " this month"
    }

    private func loadFacts() async {
        guard let memory = await engine.agentMemory(summary.ref), let owner = memory.partitions.first(where: { $0.id == "owner" }) else { return }
        facts = (await engine.memoryList(provider: memory.provider, bank: owner.bank)?.records ?? []).filter { $0.kind != "message" }
    }
}

/// "anthropic/claude-…" is an OpenRouter id; other providers are written "provider:model".
func modelRef(_ id: String?) -> ModelRef? {
    guard let id else { return nil }
    if let colon = id.firstIndex(of: ":") { return ModelRef(provider: String(id[..<colon]), id: String(id[id.index(after: colon)...])) }
    return ModelRef(provider: "openrouter", id: id)
}

func modelString(_ ref: ModelRef) -> String { ref.provider == "openrouter" ? ref.id : "\(ref.provider):\(ref.id)" }

/// A person's conversation with its composer: the owner's chat, or the simulator talking as a contact.
struct AgentChat: View {
    let engine: EngineController
    let ref: ContainerRef
    /// Set when you talk as a contact through the channel simulator.
    let simulated: String?

    var body: some View {
        let thread = engine.thread(ref)
        ZStack(alignment: .bottom) {
            TranscriptView(document: thread.document)
            VStack(spacing: 6) {
                if let simulated {
                    Text("Simulator: you are writing as \(simulated). The agent treats it as their message.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Composer(engine: engine, thread: thread)
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 20)
            }
        }
        .task(id: ref.key) { await thread.open() }
        .id(ref.key)
    }
}

/// Runs (06-agents §6, §12): what fires next, messages held by quiet hours or the daily limit, the webhook URLs, and
/// every run with its outcome and cost. A run opens its own conversation, read-only.
struct AgentRunsView: View {
    let engine: EngineController
    let summary: SessionSummary
    @State private var result: AgentRunsResult?
    @State private var triggers: [AgentTriggersResult.Trigger] = []
    @State private var selected: String?
    @State private var prompt = ""
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            List {
                if let result, !result.upcoming.isEmpty {
                    Section("Next") { ForEach(result.upcoming) { upcoming($0) } }
                }
                if let result, !result.outbox.isEmpty {
                    Section("Held") { ForEach(result.outbox) { held($0) } }
                }
                if !triggers.isEmpty {
                    Section("Webhooks") { ForEach(triggers) { trigger($0) } }
                }
                Section("Runs") {
                    if result?.runs.isEmpty ?? true {
                        Text("No runs yet. Schedules, the heartbeat, reminders and webhooks start them.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    ForEach(result?.runs ?? []) { run in
                        row(run)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = run.id }
                            .listRowBackground(RoundedRectangle(cornerRadius: 6).fill(selected == run.id ? Color.dsAccentSoft : .clear).padding(.horizontal, 6))
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { runBar }
            .frame(width: 320)
            Rectangle().fill(Color.dsLine).frame(width: 0.5)
            if let id = selected, result?.runs.contains(where: { $0.id == id }) == true {
                AgentRunTranscript(engine: engine, ref: ContainerRef(kind: .agent, id: summary.ref.id, conversationId: "run:\(id)"))
            } else {
                Text("Pick a run to see what the agent did.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: summary.updatedAt) { await load() }
    }

    private func load() async {
        result = await engine.agentRuns(summary.ref)
        triggers = await engine.agentTriggers(summary.ref)
        if selected == nil { selected = result?.runs.first?.id }
    }

    private var runBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(Color.dsFg2) }
            HStack {
                TextField("Run a prompt now", text: $prompt).textFieldStyle(.roundedBorder).onSubmit { runNow(prompt: prompt) }
                Button("Run") { runNow(prompt: prompt) }.buttonStyle(PillStyle(compact: true)).disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func runNow(scheduleId: String? = nil, prompt: String? = nil) {
        error = nil
        Task {
            do {
                let id = try await engine.agentRunNow(summary.ref, scheduleId: scheduleId, prompt: prompt?.trimmingCharacters(in: .whitespacesAndNewlines))
                if prompt != nil { self.prompt = "" }
                await load()
                selected = id
            } catch {
                self.error = (error as? EngineError)?.message ?? String(describing: error)
            }
        }
    }

    private static let kindIcon = ["schedule": "calendar", "heartbeat": "waveform.path.ecg", "reminder": "bell", "trigger": "bolt", "manual": "play"]

    private func upcoming(_ u: AgentRunsResult.Upcoming) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.kindIcon[u.kind] ?? "clock").font(.system(size: 11)).foregroundStyle(Color.dsFg3).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(u.label).font(.system(size: 12.5)).lineLimit(2)
                if let next = u.next { Text("Next: \(Self.when(next))").font(.system(size: 11)).foregroundStyle(Color.dsFg3) }
            }
            Spacer(minLength: 4)
            if u.kind == "schedule" {
                Button("Run now") { runNow(scheduleId: u.id) }.buttonStyle(PillStyle(compact: true))
            }
        }
    }

    private func held(_ h: AgentRunsResult.Held) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(h.text).font(.system(size: 12.5)).lineLimit(2)
            Text("To \(h.to) · \(h.reason == "quiet" ? "quiet hours" : "daily limit") · goes \(Self.when(h.notBefore))").font(.system(size: 11)).foregroundStyle(Color.dsAmber)
        }
    }

    private func trigger(_ t: AgentTriggersResult.Trigger) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt").font(.system(size: 11)).foregroundStyle(Color.dsFg3).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.id).font(.system(size: 12.5, weight: .medium))
                Text(t.url).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.url, forType: .string)
            } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Copy the URL (POST to it; the body goes into the prompt)")
        }
    }

    private func row(_ r: AgentRunsResult.Run) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.kindIcon[r.kind] ?? "clock").font(.system(size: 11)).foregroundStyle(Color.dsFg3).frame(width: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(r.kind == "heartbeat" ? "Heartbeat" : r.source == "manual" ? "Manual" : r.source).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(BuildSessionView.relative(r.firedAt)).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                }
                Text(r.summary ?? (r.status == "running" ? "Running…" : r.prompt)).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(2)
                HStack(spacing: 6) {
                    Circle().fill(r.status == "done" ? Color.dsFg3 : r.status == "failed" ? Color.dsFg2 : Color.dsAmber).frame(width: 6, height: 6)
                    Text([r.status == "done" ? (r.sent > 0 ? "Sent \(r.sent)" : "Nothing sent") : r.status == "failed" ? "Failed" : "Running", r.costUsd.map { $0 < 0.01 ? String(format: "$%.4f", $0) : String(format: "$%.2f", $0) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// "Today 21:00", "Tue 08:00", "23 Oct 09:00".
    static func when(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let out = DateFormatter()
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: date).day ?? 0
        out.dateFormat = days == 0 ? "'today' HH:mm" : days == 1 ? "'tomorrow' HH:mm" : days < 7 ? "EEE HH:mm" : "d MMM HH:mm"
        return out.string(from: date)
    }
}

/// A run's conversation: the prompt, its steps and answer. Runs can't be written to.
struct AgentRunTranscript: View {
    let engine: EngineController
    let ref: ContainerRef

    var body: some View {
        let thread = engine.thread(ref)
        TranscriptView(document: thread.document)
            .task(id: ref.key) { await thread.open() }
            .id(ref.key)
    }
}

/// The agent's memory by partition (ME3): facts and messages with where they came from; pin, delete, add.
struct AgentMemoryView: View {
    let engine: EngineController
    let summary: SessionSummary
    @State private var info: AgentMemoryResult?
    @State private var partition: String = "owner"
    @State private var records: [MemoryRecordInfo] = []
    @State private var limited = false
    @State private var newFact = ""
    @State private var factsOnly = true

    private var bank: String? { info?.partitions.first { $0.id == partition }?.bank }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $partition) {
                    ForEach(info?.partitions ?? []) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle("Facts only", isOn: $factsOnly).toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
                Text(info?.provider == "builtin" ? "Built-in memory" : "Provider: \(info?.provider ?? "")").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            HStack {
                TextField("Add a fact to this partition", text: $newFact).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add") { add() }.buttonStyle(PillStyle(compact: true)).disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if limited { Text("This provider can't list what it stores.").font(.system(size: 12)).foregroundStyle(Color.dsAmber) }
            List(records.filter { !factsOnly || $0.kind != "message" }) { r in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.text).font(.system(size: 13)).textSelection(.enabled)
                        Text([r.kind, r.createdBy == "agent" ? "by the agent" : r.createdBy == "user" ? "by you" : "learned", r.source?.title, BuildSessionView.relative(r.at)].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                    }
                    Spacer()
                    Button { pin(r) } label: { Image(systemName: r.pinned == true ? "pin.fill" : "pin").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(r.pinned == true ? Color.accentColor : Color.dsFg3).help("Pinned facts are always in the agent's notes")
                    Button { forget(r) } label: { Image(systemName: "trash").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(Color.dsFg3)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .task(id: summary.updatedAt) {
            info = await engine.agentMemory(summary.ref)
            await load()
        }
        .onChange(of: partition) { _, _ in Task { await load() } }
    }

    private func load() async {
        guard let info, let bank else { return }
        let result = await engine.memoryList(provider: info.provider, bank: bank)
        records = result?.records ?? []
        limited = result?.limited ?? false
    }

    private func add() {
        guard let info, let bank else { return }
        let text = newFact.trimmingCharacters(in: .whitespaces)
        newFact = ""
        run {
            try await engine.spaceCall("memory.add", MemoryAddParams(provider: info.provider, bank: bank, text: text))
            await load()
        }
    }

    private func pin(_ r: MemoryRecordInfo) {
        guard let info, let bank else { return }
        run {
            try await engine.spaceCall("memory.update", MemoryIdParams(provider: info.provider, bank: bank, id: r.id, pinned: !(r.pinned ?? false)))
            await load()
        }
    }

    private func forget(_ r: MemoryRecordInfo) {
        guard let info, let bank else { return }
        run {
            try await engine.spaceCall("memory.forget", MemoryIdParams(provider: info.provider, bank: bank, id: r.id))
            await load()
        }
    }
}

/// An agent's icon: its emoji in a tile; click for a grid of common ones, or type any emoji.
struct AvatarPicker: View {
    @Binding var avatar: String
    @State private var open = false
    @State private var typed = ""

    private static let choices = ["☀️", "🗓️", "📬", "🏃", "🏡", "🔭", "📚", "🧠", "💡", "📝", "🛒", "💰",
                                  "🍳", "🌱", "🎧", "✈️", "🧳", "🐣", "🤖", "🦉", "🐝", "⚡️", "🔔", "❤️"]

    var body: some View {
        Button { open = true } label: {
            Text(avatar.isEmpty ? "🙂" : avatar)
                .font(.system(size: 17))
                .opacity(avatar.isEmpty ? 0.45 : 1)
                .frame(width: 32, height: 28)
                .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(open ? Color.dsAccentLine : Color.dsLine, lineWidth: open ? 1 : 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose an icon")
        .task {
            // PIOPIO_DEMO_AVATAR_PICKER=1: open the grid (captures).
            if ProcessInfo.processInfo.environment["PIOPIO_DEMO_AVATAR_PICKER"] == "1" { try? await Task.sleep(for: .seconds(2)); open = true }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 6), spacing: 4) {
                    ForEach(Self.choices, id: \.self) { emoji in
                        Button { pick(emoji) } label: {
                            Text(emoji).font(.system(size: 18)).frame(width: 32, height: 32)
                                .background(emoji == avatar ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 6) {
                    TextField("Or type any emoji", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                        .onSubmit { if let first = typed.first { pick(String(first)) } }
                    if !avatar.isEmpty {
                        Button("None") { pick("") }.buttonStyle(PillStyle(compact: true))
                    }
                }
            }
            .padding(12)
            .frame(width: 236)
        }
    }

    private func pick(_ emoji: String) {
        avatar = emoji
        typed = ""
        open = false
    }
}
