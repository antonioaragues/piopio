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
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed) }
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

struct AgentPage: View {
    let engine: EngineController
    let summary: SessionSummary
    @Binding var selection: String?
    @AppStorage("agentTab") private var tab: Tab = .chat
    /// Whose conversation the Chat tab shows: the owner's (nil), a contact's (`person:<id>`), another agent's (`agent:<id>`).
    @State private var conversation: String?
    @State private var people: [AgentPerson] = []
    @State private var runs: AgentRunsResult?
    @State private var def: AgentDef?

    /// docs/design v2 (7c): Chat · Activity · Setup. Conversations moved into the "with …" picker, Runs became
    /// Activity, Memory moved into Setup.
    enum Tab: String, CaseIterable { case chat = "Chat", activity = "Activity", setup = "Setup" }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 20) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 6) {
                            Text(t.rawValue).font(.system(size: 13, weight: tab == t ? .semibold : .regular)).foregroundStyle(tab == t ? Color.dsFg : Color.dsFg2)
                            Rectangle().fill(tab == t ? Color.accentColor : .clear).frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            switch tab {
            case .chat:
                HStack(spacing: 0) {
                    chat
                    AgentSideCard(engine: engine, summary: summary, def: def, runs: runs, tab: $tab)
                        .frame(width: 300)
                        .glassPanel()
                        .padding([.top, .bottom, .trailing], 8)
                }
            case .activity: AgentRunsView(engine: engine, summary: summary)
            case .setup: AgentDefinitionView(engine: engine, summary: summary)
            }
        }
        .task(id: summary.updatedAt) { await load() }
    }

    private func load() async {
        people = await engine.agentPeople(summary.ref)
        runs = await engine.agentRuns(summary.ref)
        if let got = await engine.agentDefinition(summary.ref) { def = AgentDef(got.definition) }
    }

    @ViewBuilder private var chat: some View {
        let person = people.first { $0.conversationId == conversation }
        if let conversation, person?.role == "agent" {
            AgentRunTranscript(engine: engine, ref: ContainerRef(kind: .agent, id: summary.ref.id, conversationId: conversation))
        } else if let conversation, let person, person.role != "owner" {
            AgentChat(engine: engine, ref: ContainerRef(kind: .agent, id: summary.ref.id, conversationId: conversation), simulated: person.name)
        } else {
            AgentChat(engine: engine, ref: summary.ref, simulated: nil)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AgentAvatar(summary: summary, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.system(size: 17, weight: .bold)).foregroundStyle(Color.dsFg)
                HStack(spacing: 5) {
                    let paused = summary.agent?.status?.paused == true
                    Circle().fill(paused ? Color.dsFg3 : Color.dsGreen).frame(width: 6, height: 6)
                    Text(statusLine).font(.system(size: 12)).foregroundStyle(paused ? Color.dsAmber : Color.dsFg3)
                }
            }
            Spacer()
            if summary.agent?.invalid == true {
                Text("Setup has errors").font(.system(size: 11.5)).foregroundStyle(Color.dsRed)
            }
            if tab == .chat { personPicker }
            Button("Run now") { runNow() }.buttonStyle(PillStyle(kind: .toolbar))
            Menu {
                if let status = summary.agent?.status {
                    Button(status.paused ? "Resume" : "Pause") { Task { try? await engine.pause(summary.ref, paused: !status.paused) } }
                }
                Button("Reveal Definition in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.agent?.folder ?? "")]) }
            } label: { Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)) }
                .menuStyle(.button).buttonStyle(PillStyle(kind: .toolbar)).menuIndicator(.hidden).fixedSize()
        }
        .padding(.leading, 28)
        .padding(.trailing, 16)
        .frame(height: 64)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    /// "This Mac · every day 7:00", "This Mac · paused".
    private var statusLine: String {
        if summary.agent?.status?.paused == true { return "This Mac · paused" }
        if let cron = def?.schedules?.first?.cron { return "This Mac · \(CronText.short(cron))" }
        if let next = summary.agent?.status?.nextRun { return "This Mac · next \(MainSidebar.when(next))" }
        return "This Mac"
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
        .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.visible).fixedSize()
        .help("Whose conversation to show (contacts' are simulated here until channels arrive)")
    }

    private func runNow() {
        Task {
            let upcoming = runs?.upcoming.first { $0.kind == "schedule" }
            _ = try? await engine.agentRunNow(summary.ref, scheduleId: upcoming?.id, prompt: upcoming == nil ? "Run your usual check now." : nil)
            tab = .activity
        }
    }
}

/// The agent's overview beside its chat (7c): next and last run, what to teach it, what it can do, what it costs.
private struct AgentSideCard: View {
    let engine: EngineController
    let summary: SessionSummary
    let def: AgentDef?
    let runs: AgentRunsResult?
    @Binding var tab: AgentPage.Tab
    @State private var knowsYou = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Next run").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
                Text(summary.agent?.status?.nextRun.map { MainSidebar.when($0).capitalizedFirst } ?? "Nothing scheduled")
                    .font(.system(size: 22, weight: .bold)).tracking(-0.3)
                if let last = runs?.runs.first {
                    Text("Last: \(MainSidebar.when(last.firedAt)) · \(last.status == "done" ? "✓" : last.status)").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
            }
            if !checklist.allSatisfy(\.done) { teach }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            VStack(spacing: 9) {
                fact("Can", can)
                fact("Reaches you via", "Piopio")
                fact("Model", engine.model(modelRef(def?.models.default ?? summary.agent?.model)).map(ModelChip.short) ?? def?.models.default ?? "—")
                fact("This month", month)
            }
            Spacer()
            Button { tab = .setup } label: {
                HStack(spacing: 3) { Text("Edit in Setup"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                    .font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .task(id: summary.updatedAt) { await checkMemory() }
    }

    private struct Item { let title: String; let done: Bool; let action: String; let run: () -> Void }

    /// Three things that make an agent useful: something about you, a schedule, a Mac app.
    private var checklist: [Item] {
        [
            Item(title: "Tell it about you", done: knowsYou, action: "Tell") {
                engine.thread(summary.ref).draft = "A few things about me: "
            },
            Item(title: "Give it a schedule", done: !(def?.schedules ?? []).isEmpty, action: "Add") { tab = .setup },
            Item(title: "Connect a Mac app", done: !(def?.tools.apple ?? []).isEmpty, action: "Allow") { tab = .setup },
        ]
    }

    private var teach: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Chick(size: 24)
                Text("Teach it \(checklist.count) things").font(.system(size: 13, weight: .semibold))
                Text("\(checklist.filter(\.done).count) / \(checklist.count)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            ForEach(checklist, id: \.title) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle").font(.system(size: 13)).foregroundStyle(item.done ? Color.dsGreen : Color.dsFg3)
                    Text(item.title).font(.system(size: 13)).strikethrough(item.done).foregroundStyle(item.done ? Color.dsFg3 : Color.dsFg)
                    Spacer()
                    if !item.done { Button(item.action, action: item.run).buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor) }
                }
            }
        }
        .padding(12)
        .background(Color.dsYolkSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func fact(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            Spacer(minLength: 10)
            Text(value).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).multilineTextAlignment(.trailing)
        }
    }

    private var can: String {
        let tools = def?.tools.builtin ?? []
        var parts: [String] = []
        if tools.contains("web_search") || tools.contains("web_fetch") { parts.append("Web") }
        if tools.contains("memory") { parts.append("memory") }
        if tools.contains("send_message") { parts.append("message you") }
        if tools.contains("schedule") { parts.append("reminders") }
        if !(def?.tools.apple ?? []).isEmpty { parts.append("Mac apps") }
        return parts.isEmpty ? "Just chat" : parts.joined(separator: " · ")
    }

    private var month: String {
        guard let s = summary.agent?.status else { return "—" }
        let spent = s.spendUsd < 0.01 && s.spendUsd > 0 ? String(format: "$%.4f", s.spendUsd) : String(format: "$%.2f", s.spendUsd)
        return s.budgetUsd.map { "\(spent) of \(MainSidebar.money($0))" } ?? spent
    }

    private func checkMemory() async {
        guard let memory = await engine.agentMemory(summary.ref), let owner = memory.partitions.first(where: { $0.id == "owner" }) else { return }
        knowsYou = await engine.memoryList(provider: memory.provider, bank: owner.bank)?.records.contains { $0.kind != "message" } ?? false
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
                        .font(.system(size: 11.5)).foregroundStyle(Color.dsAmber)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.dsChip, in: Capsule())
                }
                Composer(engine: engine, thread: thread)
                    .frame(maxWidth: 636)
                    .padding(.horizontal, 24)
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
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(Color.dsRed) }
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
                    Circle().fill(r.status == "done" ? Color.dsGreen : r.status == "failed" ? Color.dsRed : Color.dsAmber).frame(width: 6, height: 6)
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
