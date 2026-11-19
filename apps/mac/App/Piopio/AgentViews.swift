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

/// The circle with the agent's icon, emoji or initial.
struct AgentAvatar: View {
    let summary: SessionSummary
    var size: CGFloat = 24

    var body: some View {
        let avatar = summary.agent?.avatar
        ZStack {
            Circle().fill(Color.accentColor.opacity(avatar == nil ? 0.85 : 0.14))
            if let avatar {
                AvatarGlyph(avatar: avatar, size: size * 0.55, color: .dsFg)
            } else {
                Text(String(summary.title.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// An agent's avatar: "symbol:<SF Symbol>" draws a line icon (templates use these); anything else is shown as text,
/// an emoji someone picked.
struct AvatarGlyph: View {
    let avatar: String
    var size: CGFloat
    var color: Color = .dsFg2

    var body: some View {
        if let symbol = Self.symbol(avatar) {
            Image(systemName: symbol).font(.system(size: size * 0.85, weight: .regular)).foregroundStyle(color)
        } else {
            Text(avatar).font(.system(size: size))
        }
    }

    static func symbol(_ avatar: String) -> String? {
        avatar.hasPrefix("symbol:") ? String(avatar.dropFirst(7)) : nil
    }
}

// MARK: Sidebar

// MARK: Agent page

/// An agent (docs/design/grey 13a): one conversation, and an info panel like a contact card (what it does, when, what
/// it can do, where it reaches you, what it remembers, what it costs). Its runs and full setup open from the panel in
/// place of the conversation, with a breadcrumb back.
struct AgentPage: View {
    let engine: EngineController
    let summary: SessionSummary
    @Binding var selection: String?
    @AppStorage("agentTab") private var tab: Tab = .chat
    /// Whose conversation shows: the owner's (nil), a contact's (`person:<id>`), another agent's (`agent:<id>`), or a
    /// run's (`run:<id>`, from its line in the chat).
    @State private var conversation: String?
    @State private var people: [AgentPerson] = []
    @State private var runs: AgentRunsResult?
    @State private var def: AgentDef?
    @State private var instructions = ""
    /// The Setup section to open at.
    @State private var setupSection: String?
    /// Agents whose identity card you've answered (ids, comma-separated).
    @AppStorage("agentIntroSeen") private var introSeen = ""
    /// It just set itself up: its avatar animates in (design 5a-3).
    @State private var alive = false
    /// Moving it to your cloud or back (docs/spec/30 §3.2): the question, the move under way, and what moved.
    @State private var confirmingMove = false
    @State private var moving = false
    @State private var moved: [String]?
    @State private var noCloud = false
    /// Run now failed: why.
    @State private var problem: String?

    /// Chat first, Setup for later (docs/spec/21 D3, design 2a). "Activity" is gone: runs are lines in the chat.
    enum Tab: String, CaseIterable { case chat = "Chat", activity = "Activity", setup = "Setup" }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch tab {
            case .setup:
                AgentDefinitionView(engine: engine, summary: summary, section: $setupSection) { text in
                    // An event routine is set by asking (it has no form yet): the chat, with the request started.
                    engine.thread(summary.ref).composerText = text
                    conversation = nil
                    tab = .chat
                }
            default:
                if let conversation { backBar(conversation) }
                chat
            }
        }
        .task(id: summary.updatedAt) { await load() }
        .onAppear {
            if tab == .activity { tab = .chat }
            openSearchTarget()
            // PIOPIO_DEMO_SETUP_SECTION=<section>: captures open Setup there.
            if let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_SETUP_SECTION"] { setupSection = demo; tab = .setup }
        }
        .onChange(of: engine.searchTarget?.id) { _, _ in openSearchTarget() }
        // It comes alive (design 5a-3): its avatar and colour arrive with a soft ring, here and in the sidebar at once.
        .onChange(of: summary.agent?.draft == true) { was, isDraft in
            guard was, !isDraft else { return }
            withAnimation(.spring(duration: 0.5, bounce: 0.35)) { alive = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(.easeOut(duration: 0.6)) { alive = false } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAgentRun)) { note in
            guard let id = note.object as? String else { return }
            conversation = id
            tab = .chat
        }
        .task { await engine.loadCloud() }
        .confirmationDialog(inCloud ? "Move \(summary.title) to this Mac?" : "Keep \(summary.title) always on?", isPresented: $confirmingMove) {
            Button(inCloud ? "Move to This Mac" : "Move to Cloud") { move() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(inCloud
                ? "It stops while your Mac sleeps or is off. Its memory and automations come back; its conversations in the cloud are saved as text in its folder."
                : "It moves to your cloud and keeps going with your Mac off: its instructions, memory, automations at a time, and Telegram. Automations that watch a folder or your email stay on this Mac, off, until it comes back.")
        }
        .alert(inCloud ? "In your cloud" : "On this Mac", isPresented: Binding(get: { moved != nil }, set: { if !$0 { moved = nil } })) {
            Button("OK") { moved = nil }
        } message: { Text((moved ?? []).joined(separator: "\n\n")) }
        .alert("Couldn't run it now", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .alert("Keep it always on", isPresented: $noCloud) {
            Button("Open Settings") { ToolChoices.openSettings("This Mac & cloud") }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("An agent in your cloud answers and runs its automations with your Mac off. Connect your cloud first, in Settings › This Mac & cloud.")
        }
    }

    private var inCloud: Bool { summary.agent?.location == "cloud" }

    private func move() {
        moving = true
        Task {
            defer { moving = false }
            do {
                moved = try await engine.moveAgent(summary.ref, to: inCloud ? "local" : "cloud")
                conversation = nil
                await load()
            } catch {
                moved = [(error as? EngineError)?.message ?? error.localizedDescription]
            }
        }
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
            AgentChat(engine: engine, ref: summary.ref, simulated: nil, accessory: identityCard)
        }
    }

    /// Its card once it has set itself up by talking (design 5a-3), until you answer it.
    private var identityCard: AnyView? {
        guard summary.agent?.draft != true, let def, !introSeen.split(separator: ",").contains(Substring(summary.ref.id)) else { return nil }
        let thread = engine.thread(summary.ref)
        _ = thread.revision
        let setUpHere = thread.document.items.contains { if case .result(let r) = $0 { r.card.kind == "setup" } else { false } }
        guard setUpHere, (runs?.runs ?? []).isEmpty else { return nil }
        return AnyView(AgentIdentityCard(engine: engine, summary: summary, def: def, runs: runs, rename: {
            setupSection = "What it does"
            tab = .setup
        }, looksGood: {
            introSeen += (introSeen.isEmpty ? "" : ",") + summary.ref.id
            trialRun()
        }, change: {
            introSeen += (introSeen.isEmpty ? "" : ",") + summary.ref.id
        }))
    }

    /// A first run now, so you see how it looks (design 5a-4).
    private func trialRun() {
        Task {
            let schedule = def?.schedules?.first
            _ = try? await engine.agentRunNow(summary.ref, scheduleId: schedule?.id, prompt: schedule == nil ? "Do what you're set up for once, now, so I can see how it looks." : nil, trial: true)
            await load()
        }
    }

    /// Back to your chat from a run, a contact's or another agent's conversation.
    private func backBar(_ conversation: String) -> some View {
        let person = people.first { $0.conversationId == conversation }
        let what = conversation.hasPrefix("run:") ? (runs?.runs.first { "run:\($0.id)" == conversation }.map { "Run · \(HomeView.at($0.firedAt))" } ?? "A run")
            : person.map { $0.role == "agent" ? "With \($0.name) (agent)" : "With \($0.name)" } ?? ""
        return HStack(spacing: 8) {
            Button { self.conversation = nil } label: { Label("Your chat", systemImage: "chevron.left").font(.system(size: 12.5)) }
                .buttonStyle(.plain).foregroundStyle(Color.dsFg2)
            Text(what).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
            Spacer()
        }
        .padding(.horizontal, 20).frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }

    /// Who it is, at the top of its page (the agents and automations handoff, screen 1): its tile, its name, "what it's
    /// for · its model", a link to its automations, and Chat · Setup. Run now, pause and the rest are in ⋯.
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                if summary.agent?.draft == true {
                    // Not anyone yet: a dashed outline until it sets itself up.
                    RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.dsFg3, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(width: 64, height: 64)
                } else {
                    AgentTile(id: summary.ref.id, name: summary.title, glyph: summary.agent?.avatar, size: 64)
                        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(AgentHue.color(summary.ref.id).opacity(alive ? 0.22 : 0)).padding(-8))
                        .scaleEffect(alive ? 1.08 : 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(summary.title).font(.system(size: 24, weight: .bold)).tracking(-0.5).foregroundStyle(Color.dsFg).lineLimit(1)
                        if inCloud {
                            Image(systemName: "cloud").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.dsFg2)
                                .help("Cloud · keeps going with your Mac off").accessibilityLabel("In your cloud")
                        }
                        if moving { ProgressView().controlSize(.small) }
                        if summary.agent?.status?.paused == true {
                            Text("Paused").font(.system(size: 11.5)).foregroundStyle(Color.dsFg2).padding(.horizontal, 6).padding(.vertical, 1).background(Color.dsChip, in: Capsule())
                        }
                    }
                    Text(identityLine).font(.system(size: 13)).foregroundStyle(Color.dsFg2).lineLimit(1)
                }
                Spacer(minLength: 12)
                if summary.agent?.invalid == true {
                    Button("Setup has errors") { tab = .setup }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                }
                // Its automations (docs/spec/27 AU3): they live in Automations; the header leads there.
                let count = engine.automations.filter { $0.runsAs == summary.ref.id }.count
                if count > 0 {
                    Button { NotificationCenter.default.post(name: .selectItem, object: SidebarItem.automations(summary.ref.id).raw) } label: {
                        Text("\(count) automation\(count == 1 ? "" : "s") ›").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open Automations, showing \(summary.title)'s")
                }
                placeButton
                moreMenu
            }
            HStack(spacing: 22) {
                tabButton(.chat)
                tabButton(.setup)
            }
        }
        .padding(.top, 24)
        .padding(.leading, 40).padding(.trailing, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }

    /// Where it runs, in the header (docs/spec/30 §3.3): "Keep it always on" sends it to your cloud; once there, "Always
    /// on" says so and offers the way back.
    @ViewBuilder private var placeButton: some View {
        if inCloud {
            Menu {
                Button("Move to This Mac…") { confirmingMove = true }
            } label: {
                Label("Always on", systemImage: "cloud.fill").font(.system(size: 12.5, weight: .medium))
            }
            .menuStyle(.button).buttonStyle(PillStyle(compact: true)).menuIndicator(.hidden).fixedSize()
            .disabled(moving)
            .help("In your cloud: it answers and runs its automations with your Mac off")
        } else if summary.agent?.draft != true {
            Button { if engine.cloudConnected { confirmingMove = true } else { noCloud = true } } label: {
                Label("Keep it always on", systemImage: "cloud").font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(PillStyle(compact: true)).disabled(moving)
            .help("Move it to your cloud, so it keeps going with your Mac off")
        }
    }

    /// "Watches Acme, Brightly and Northwind · Claude Sonnet", or a new agent's question while it learns its job.
    private var identityLine: String {
        if summary.agent?.draft == true { return AgentQuickReplies.question(engine.thread(summary.ref).document.items) ?? "Learning its job" }
        let model = engine.model(modelRef(summary.agent?.model)).map(ModelChip.short) ?? summary.agent?.model
        return [summary.agent?.description ?? def?.description, model, inCloud ? "Cloud" : nil].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    private func tabButton(_ t: Tab) -> some View {
        let on = tab == t || (t == .chat && tab == .activity)
        return Button { tab = t } label: {
            Text(t.rawValue).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(on ? Color.dsFg : Color.dsFg2)
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) { if on { Rectangle().fill(Color.dsFg).frame(height: 2) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(t == .chat ? "1" : "2", modifiers: [.command, .option])
    }

    /// Run now, pause, its other conversations, Finder.
    private var moreMenu: some View {
        Menu {
            // Not while it's working: a run now would queue behind what it's doing.
            Button("Run Now", action: runNow).disabled(engine.liveStatus[summary.ref.key] == .running)
            if let status = summary.agent?.status {
                Button(status.paused ? "Resume" : "Pause") { Task { try? await engine.pause(summary.ref, paused: !status.paused) } }
            }
            Divider()
            let others = people.filter { $0.role != "owner" }
            if !others.isEmpty {
                Menu("Conversations") {
                    Button("Yours") { conversation = nil; tab = .chat }
                    ForEach(others) { p in Button(p.role == "agent" ? "\(p.name) (agent)" : p.name) { conversation = p.conversationId; tab = .chat } }
                }
                Divider()
            }
            ExportMenuItems(engine: engine, ref: shownRef, noun: shownNoun)
            Divider()
            Button("Reveal Definition in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.agent?.folder ?? "")]) }
        } label: { Image(systemName: "ellipsis").accessibilityLabel("More") }
            .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize()
            .help("Run now, pause, conversations, export, Finder")
    }

    /// The conversation on screen, which Export takes (docs/design/export 2A): yours, a contact's, another agent's, a run.
    private var shownRef: ContainerRef {
        guard let conversation else { return summary.ref }
        return ContainerRef(kind: .agent, id: summary.ref.id, conversationId: conversation)
    }

    private var shownNoun: String {
        guard let conversation else { return "Chat" }
        if conversation.hasPrefix("run:") { return "This Run" }
        return people.first { $0.conversationId == conversation }.map { "Conversation with \($0.name)" } ?? "Conversation"
    }

    private func runNow() {
        Task {
            // Its next automation (docs/spec/27), else its usual check. What goes wrong is said, not swallowed.
            let mine = engine.automations.filter { $0.runsAs == summary.ref.id }
            do {
                if let first = mine.filter({ $0.next != nil }).min(by: { ($0.next ?? 0) < ($1.next ?? 0) }) ?? mine.first {
                    _ = try await engine.runAutomation(first.id)
                } else {
                    _ = try await engine.agentRunNow(summary.ref, scheduleId: nil, prompt: "Run your usual check now.")
                }
            } catch {
                problem = (error as? EngineError)?.message ?? error.localizedDescription
            }
            conversation = nil
            tab = .chat
            await load()
        }
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
    /// Shown above the composer (a new agent's identity card).
    var accessory: AnyView?

    var body: some View {
        let thread = engine.thread(ref)
        ZStack(alignment: .bottom) {
            TranscriptView(document: thread.document)
            VStack(spacing: 6) {
                if let simulated {
                    Text("Simulator: you are writing as \(simulated). The agent treats it as their message.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                if let accessory { accessory.padding(.horizontal, 40) }
                // Answers to tap while a new agent learns its job (docs/spec/21 D4).
                if simulated == nil, ref.conversationId == nil { AgentQuickReplies(thread: thread).padding(.horizontal, 40) }
                Composer(engine: engine, thread: thread)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)
            }
        }
        // Keyed by the model too: after a move to or from the cloud the app makes a new one, which must open.
        .task(id: "\(ref.key)#\(ObjectIdentifier(thread).hashValue)") { await thread.open() }
        .id(ref.key)
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
    /// The button's size: 32 × 28 in forms, 44 × 44 on the start page.
    var size = CGSize(width: 32, height: 28)
    @State private var open = false
    @State private var typed = ""

    /// Line icons (SF Symbols), stored as "symbol:<name>". An emoji can still be typed.
    private static let choices = ["sun.max", "calendar", "envelope", "figure.run", "house", "binoculars", "books.vertical", "brain",
                                  "lightbulb", "note.text", "cart", "banknote", "fork.knife", "leaf", "headphones", "airplane",
                                  "suitcase", "bird", "cpu", "moon.stars", "pawprint", "bolt", "bell", "heart"].map { "symbol:" + $0 }

    var body: some View {
        Button { open = true } label: {
            Group {
                if avatar.isEmpty { Image(systemName: "face.smiling").font(.system(size: size.height * 0.5)).foregroundStyle(Color.dsFg3) }
                else { AvatarGlyph(avatar: avatar, size: size.height * 0.55, color: .dsFg) }
            }
            .frame(width: size.width, height: size.height)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: size.height > 40 ? 12 : 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size.height > 40 ? 12 : 7, style: .continuous).strokeBorder(open ? Color.dsAccentLine : Color.dsLine, lineWidth: open ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose an icon")
        .accessibilityLabel("Choose an icon")
        .task {
            // PIOPIO_DEMO_AVATAR_PICKER=1: open the grid (captures).
            if ProcessInfo.processInfo.environment["PIOPIO_DEMO_AVATAR_PICKER"] == "1" { try? await Task.sleep(for: .seconds(2)); open = true }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 6), spacing: 4) {
                    ForEach(Self.choices, id: \.self) { choice in
                        Button { pick(choice) } label: {
                            AvatarGlyph(avatar: choice, size: 18, color: .dsFg).frame(width: 32, height: 32)
                                .background(choice == avatar ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AvatarGlyph.symbol(choice) ?? choice)
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
