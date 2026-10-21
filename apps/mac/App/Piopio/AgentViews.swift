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
    struct Policies: Codable, Equatable { var quietHours: String?; var maxOutboundPerDay: Int?; var maxOutboundPerContactPerDay: Int?; var urgentBypassesQuiet: Bool?; var budgetUsdPerMonth: Double?; var requireApproval: [String]?; var unknownSenders: String? }
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

struct AgentsSection: View {
    let engine: EngineController
    @Binding var selection: String?

    var body: some View {
        Button { selection = "inbox" } label: {
            HStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 12)).foregroundStyle(selection == "inbox" ? Color.dsFg : Color.dsFg2)
                Text("Inbox").font(.system(size: 13, weight: selection == "inbox" ? .semibold : .regular)).foregroundStyle(Color.dsFg)
                Spacer()
                if engine.inboxCount > 0 {
                    Text("\(engine.inboxCount)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(selection == "inbox" ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Approvals, messages for you and failed runs, across agents")
        HStack {
            SectionLabel("Agents")
            Spacer()
            Button { NotificationCenter.default.post(name: .newAgent, object: nil) } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            .buttonStyle(.plain)
            .help("New agent")
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        if engine.agents.isEmpty {
            Text("Agents you create appear here.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.horizontal, 8)
        }
        ForEach(engine.agents, id: \.ref.id) { agent in
            let selected = selection == agent.ref.id
            Button { selection = agent.ref.id } label: {
                HStack(spacing: 9) {
                    ZStack(alignment: .bottomTrailing) {
                        AgentAvatar(summary: agent, size: 28)
                        if engine.liveStatus[agent.ref.key] == .running { StatusDot(status: .running, size: 8) }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg).lineLimit(1)
                        if agent.agent?.status?.paused == true {
                            Text("Paused").font(.system(size: 11.5)).foregroundStyle(Color.dsAmber).lineLimit(1)
                        } else {
                            Text(agent.agent?.description ?? "Local agent").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(agent.agent?.location == "cloud" ? "CLOUD" : "LOCAL")
                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.dsFg3)
                        .padding(.horizontal, 5).frame(height: 16)
                        .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 8)
                .frame(height: 42)
                .background(selected ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Reveal Definition in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agent.agent?.folder ?? "")]) }
                Divider()
                Button("Delete Agent…", role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "Delete “\(agent.title)”?"
                    alert.informativeText = "Its conversations and memory are deleted. Its definition folder goes to the Trash."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    if selection == agent.ref.id { selection = nil }
                    Task { await engine.delete(agent.ref) }
                }
            }
        }
    }
}

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
                TextField("🙂", text: $avatar).textFieldStyle(.roundedBorder).frame(width: 52)
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

    enum Tab: String, CaseIterable { case chat = "Chat", conversations = "Conversations", runs = "Runs", memory = "Memory", definition = "Definition" }

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
            .padding(.horizontal, 24)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            switch tab {
            case .chat: AgentChat(engine: engine, ref: summary.ref, simulated: nil)
            case .conversations: AgentConversations(engine: engine, summary: summary)
            case .runs: AgentRunsView(engine: engine, summary: summary)
            case .memory: AgentMemoryView(engine: engine, summary: summary)
            case .definition: AgentDefinitionView(engine: engine, summary: summary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentAvatar(summary: summary, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dsFg)
                HStack(spacing: 5) {
                    Circle().fill(Color.dsGreen).frame(width: 6, height: 6)
                    Text("This Mac · \(engine.model(modelRef(summary.agent?.model))?.name ?? summary.agent?.model ?? "")").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                }
            }
            // UI1: the approval mode as a badge.
            Text(summary.agent?.asksFirst == true ? "Asks first" : "Auto")
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.dsFg2)
                .padding(.horizontal, 7).frame(height: 18)
                .background(Color.dsChip, in: Capsule())
                .help(summary.agent?.asksFirst == true ? "Some actions wait for your approval (Definition › Policies)" : "Acts without asking; every change can be undone for 24 hours")
            Spacer()
            if summary.agent?.invalid == true {
                Text("Definition has errors").font(.system(size: 11.5)).foregroundStyle(Color.dsRed)
            }
            if let status = summary.agent?.status {
                Text(status.budgetUsd.map { String(format: "$%.2f of $%.0f this month", status.spendUsd, $0) } ?? String(format: "$%.2f this month", status.spendUsd))
                    .font(.system(size: 11.5)).foregroundStyle(status.budgetUsd.map { status.spendUsd >= $0 } == true ? Color.dsRed : Color.dsFg3)
                Button {
                    Task { try? await engine.pause(summary.ref, paused: !status.paused) }
                } label: {
                    Label(status.paused ? "Resume" : "Pause", systemImage: status.paused ? "play.fill" : "pause.fill").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(PillStyle(kind: status.paused ? .primary : .secondary, compact: true))
                .help(status.paused ? "Runs and messages start again" : "Stop all runs and messages now (the owner can also write /pause)")
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 60)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
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

/// Everyone the agent talks with (§12): pick a person to read the conversation; contacts can be simulated.
struct AgentConversations: View {
    let engine: EngineController
    let summary: SessionSummary
    @State private var people: [AgentPerson] = []
    @State private var selected: String?

    var body: some View {
        HStack(spacing: 0) {
            List(people, selection: $selected) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(p.name).font(.system(size: 13, weight: .medium))
                        if p.role == "owner" { Text("owner").font(.system(size: 10.5)).foregroundStyle(Color.dsFg3) }
                        Spacer()
                        if let at = p.lastAt { Text(BuildSessionView.relative(at)).font(.system(size: 11)).foregroundStyle(Color.dsFg3) }
                    }
                    Text(p.preview ?? (p.started ? "" : "No messages yet")).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(2)
                }
                .padding(.vertical, 3)
                .tag(p.contactId)
            }
            .listStyle(.sidebar)
            .frame(width: 240)
            Rectangle().fill(Color.dsLine).frame(width: 0.5)
            if let person = people.first(where: { $0.contactId == selected }) {
                AgentChat(engine: engine, ref: ContainerRef(kind: .agent, id: summary.ref.id, conversationId: person.conversationId), simulated: person.role == "owner" ? nil : person.name)
            } else {
                Text("Pick someone to see their conversation.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: summary.updatedAt) {
            people = await engine.agentPeople(summary.ref)
            if selected == nil { selected = people.first(where: { $0.role != "owner" })?.contactId ?? people.first?.contactId }
        }
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
