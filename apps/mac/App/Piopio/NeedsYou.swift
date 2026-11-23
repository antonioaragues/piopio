import PiopioKit
import PiopioTranscript
import SwiftUI

/// One thing that waits for you (docs/design v2, "Needs you"): an agent's approval, message, failed run or budget
/// stop, or a Build session waiting on an approval or a question. Aggregated across the engine, oldest first.
struct NeedsYouEntry: Identifiable {
    enum Kind { case approval, message, runFailed, budget, buildPrompt, watchdog }
    let id: String
    let kind: Kind
    let at: String
    var inbox: InboxItem?
    var agent: SessionSummary?
    var session: SessionSummary?
    /// The Watchdog's note (docs/spec/17 §4): a conversation that looks stuck or repeats itself.
    var watchdog: WatchdogNote?
    /// An automation run Piopio's monthly budget holds (docs/spec/34 OV3), with the budget it's past.
    var held: PiopioBudget.Held?
    var budget: PiopioBudget?

    var isApproval: Bool { kind == .approval || kind == .buildPrompt }

    /// Never hidden (docs/spec/15): an item from a hidden area still shows, marked with its area.
    @MainActor var hiddenArea: Area? {
        if held != nil { return nil }
        let area: Area = session.map { $0.profile == .chat ? .chat : .build } ?? .agents
        return Areas.shared.contains(area) ? nil : area
    }
    var isMessage: Bool { kind == .message || kind == .runFailed || kind == .budget || kind == .watchdog }
}

extension EngineController {
    /// Everything waiting for you, oldest first.
    var needsYou: [NeedsYouEntry] {
        var out: [NeedsYouEntry] = []
        for i in inbox where i.needsYou {
            let kind: NeedsYouEntry.Kind = switch i.kind {
            case "approval": .approval
            case "run_failed": .runFailed
            case "budget": .budget
            default: .message
            }
            out.append(NeedsYouEntry(id: "inbox:\(i.id)", kind: kind, at: i.at, inbox: i, agent: agents.first { $0.ref.id == i.agent.id }))
        }
        for s in buildSessions where liveStatus[s.ref.id] == .waitingApproval {
            out.append(NeedsYouEntry(id: "session:\(s.ref.id)", kind: .buildPrompt, at: s.updatedAt, session: s))
        }
        if let budget = piopioBudget {
            for h in budget.held {
                out.append(NeedsYouEntry(id: "held:\(h.run)", kind: .budget, at: h.at, held: h, budget: budget))
            }
        }
        for n in watchdogNotes {
            out.append(NeedsYouEntry(id: "watchdog:\(n.id)", kind: .watchdog, at: n.at, session: (buildSessions + threads).first { $0.ref.id == n.ref.id }, watchdog: n))
        }
        return out.sorted { $0.at < $1.at }
    }
}


/// What a Needs you item is called and where it's from, shared with Home.
enum NeedsYouText {
    @MainActor static func source(_ entry: NeedsYouEntry, engine: EngineController) -> String {
        let hidden = entry.hiddenArea.map { " (\($0.title) · hidden)" } ?? ""
        if let h = entry.held { return h.name }
        if let s = entry.session { return s.title + hidden }
        if let n = entry.watchdog { return n.title + hidden }
        return (entry.agent?.title ?? entry.inbox?.agentName ?? "Agent") + hidden
    }

    @MainActor static func title(_ entry: NeedsYouEntry, engine: EngineController) -> String {
        switch entry.kind {
        case .approval: return entry.inbox?.approval?.title ?? "Asks before doing something"
        case .message: return entry.inbox.map { firstLine($0.body) } ?? "Wrote to you"
        case .runFailed: return "\(source(entry, engine: engine)) didn't run"
        case .budget:
            if entry.held != nil, let b = entry.budget { return heldLine(b) }
            return entry.inbox?.title ?? "Budget"
        case .watchdog: return entry.watchdog?.text ?? "Looks stuck"
        case .buildPrompt:
            guard let s = entry.session, let prompt = engine.thread(s.ref).prompts.first else { return "Waiting on you" }
            if prompt.kind == .approval, prompt.tool == "bash", let detail = prompt.detail, !detail.isEmpty, !detail.contains("\n") { return "Run \(detail)?" }
            return prompt.question
        }
    }

    /// "wrote to you", "didn't run", "asks first", "paused itself".
    static func what(_ entry: NeedsYouEntry) -> String {
        switch entry.kind {
        case .approval: "asks first"
        case .message: entry.inbox?.conversationId?.hasPrefix("run:") == true ? "wrote after a run" : "wrote to you"
        case .runFailed: "didn't run"
        case .budget: entry.held != nil ? "waits for your OK" : entry.inbox?.title == "Budget used up" ? "paused itself" : "budget"
        case .buildPrompt: "is waiting on you"
        case .watchdog: entry.watchdog?.rule == "looping" ? "is repeating itself" : "looks stuck"
        }
    }

    /// "held: Piopio is past its $20 budget for November" (the row's second line already says it waits for your OK).
    static func heldLine(_ b: PiopioBudget) -> String {
        "held: Piopio is past its \(MainSidebar.money(b.limitUsd ?? b.spentUsd)) budget for \(monthName(b.month))"
    }

    /// "2026-11" → "November".
    static func monthName(_ month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]) else { return "this month" }
        return DateFormatter().standaloneMonthSymbols[parts[1] - 1]
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    }
}

/// One thing waiting on you, on Home (docs/spec/21 D2): a row with the action that resolves it on the right; a click
/// opens its full card under it (what came in, a Build session's own prompt cards, where to look). The Needs you page
/// is gone: everything waiting is here, and a notification opens Home with its row open.
struct WaitingItem: View {
    let engine: EngineController
    let entry: NeedsYouEntry
    @Binding var item: SidebarItem
    @Binding var expanded: String?
    @State private var reply = ""
    @State private var busy = false
    @State private var error: String?

    @State private var hovering = false

    private var isOpen: Bool { expanded == entry.id }
    private var thread: ThreadModel? { entry.kind == .buildPrompt ? entry.session.map { engine.thread($0.ref) } : nil }

    /// Its tile (docs/design/home 3a): orange asks first, red failed, the accent for the rest.
    private var tone: StatusTone {
        if entry.isApproval { return .approval }
        return entry.kind == .runFailed ? .failed : .other
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                StatusTile(tone: tone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line).font(.system(size: 13.5)).foregroundStyle(Color.dsFg).lineLimit(1).truncationMode(.tail)
                    Text("\(origin) · \(BuildSessionView.relative(entry.at))").font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                Spacer(minLength: 12)
                quick
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.18)) { expanded = isOpen ? nil : entry.id } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isOpen ? "Hides the details" : "Shows the details")
            if isOpen { detail.padding(.leading, 52).padding(.trailing, 12).padding(.bottom, 12).transition(.opacity) }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn).padding(.leading, 52).padding(.bottom, 8) }
        }
        .background(hovering ? Color.dsChip.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .disabled(busy)
        .task(id: entry.session?.ref.id) { if let thread { await thread.open() } }
    }

    /// "Morning briefing asks: read Calendar", "Family helper: “Which supermarket?”".
    private var line: String {
        let source = NeedsYouText.source(entry, engine: engine)
        let title = NeedsYouText.title(entry, engine: engine)
        switch entry.kind {
        case .approval: return "\(source) asks: \(title)"
        case .message: return "\(source): “\(title)”"
        case .buildPrompt: return "\(source) · \(title)"
        case .budget: return "\(source): \(title)"
        case .watchdog: return "\(source) \(NeedsYouText.what(entry))"
        case .runFailed: return title
        }
    }

    /// Where it's from: an agent, a project's session, the Watchdog.
    private var origin: String {
        switch entry.kind {
        case .buildPrompt: entry.session.flatMap { engine.project(of: $0)?.name } ?? "Build"
        case .watchdog: "Watchdog"
        case .budget where entry.held != nil: "Automation · \(NeedsYouText.what(entry))"
        default: "Agent · \(NeedsYouText.what(entry))"
        }
    }

    // MARK: The row's actions

    /// The one that resolves it, black; the others with a hairline.
    @ViewBuilder private var quick: some View {
        HStack(spacing: 6) {
            switch entry.kind {
            case .approval:
                Button("Not now") { decide(false) }.buttonStyle(HomePillStyle())
                Button("Allow") { decide(true) }.buttonStyle(HomePillStyle(primary: true))
            case .message:
                TextField("", text: $reply, prompt: Text("Answer here…").foregroundStyle(Color.dsFg3))
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .padding(.horizontal, 10).padding(.vertical, 6).frame(width: 170)
                    .background(Color.dsWin, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 1))
                    .onSubmit(send)
            case .buildPrompt:
                if let thread, let prompt = thread.prompts.first, prompt.kind == .approval {
                    Button("Deny") { respond(thread, prompt, .deny) }.buttonStyle(HomePillStyle())
                    Button("Allow") { respond(thread, prompt, .allow) }.buttonStyle(HomePillStyle(primary: true))
                } else {
                    Button("Answer") { withAnimation(.snappy(duration: 0.18)) { expanded = entry.id } }.buttonStyle(HomePillStyle())
                }
            case .runFailed:
                Button("Dismiss") { markRead() }.buttonStyle(HomePillStyle())
                if engine.needsKey {
                    Button("Set up a provider") { setUpProvider() }.buttonStyle(HomePillStyle(primary: true))
                } else {
                    Button("Run again") { runAgain() }.buttonStyle(HomePillStyle(primary: true))
                }
            case .budget where entry.held != nil:
                Button("Continue this month") { release(month: true) }.buttonStyle(HomePillStyle())
                Button("Run it") { release(month: false) }.buttonStyle(HomePillStyle(primary: true))
            case .budget:
                Button("Keep paused") { markRead() }.buttonStyle(HomePillStyle())
                if let budget = entry.agent?.agent?.status?.budgetUsd {
                    Button("Raise to \(MainSidebar.money(max(1, budget * 2)))") { raise(to: max(1, budget * 2)) }.buttonStyle(HomePillStyle(primary: true))
                }
            case .watchdog:
                // The Watchdog never stops anything itself (docs/spec/17 §4): you look, and decide.
                if let note = entry.watchdog {
                    Button("Dismiss") { Task { await engine.dismissWatchdog(note) } }.buttonStyle(HomePillStyle())
                }
                Button("Open") { open() }.buttonStyle(HomePillStyle(primary: true))
            }
        }
    }

    // MARK: The full card

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thread {
                ForEach(thread.prompts) { prompt in PromptCard(session: thread, prompt: prompt, primary: false) }
                if thread.prompts.isEmpty { Text("Waiting on you…").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3) }
            } else if let body = content, !body.isEmpty {
                // What came in, in an inset box; a failed run's log in mono.
                Text(body).font(entry.kind == .runFailed ? .system(size: 12.5, design: .monospaced) : .system(size: 13)).foregroundStyle(Color.dsFg)
                    .lineSpacing(5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: DS.bubble), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            // The Watchdog's row already has Open.
            if entry.kind != .watchdog {
                HStack(spacing: 14) {
                    if entry.kind == .runFailed, engine.needsKey {
                        Button("Run again") { runAgain() }.buttonStyle(HomePillStyle())
                    }
                    Button("\(openLabel) →") { open(); if entry.kind == .message || entry.kind == .runFailed { markRead() } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private var content: String? {
        if let note = entry.watchdog { return note.text }
        if entry.held != nil, let b = entry.budget {
            return "Piopio has spent \(MainSidebar.money(b.spentUsd)) of its \(MainSidebar.money(b.limitUsd ?? b.spentUsd)) budget for \(NeedsYouText.monthName(b.month)), so this automation waits. Run it now, or let background work continue until the budget resets."
        }
        guard let inbox = entry.inbox else { return nil }
        if entry.kind == .approval, let title = inbox.approval?.title, inbox.body.isEmpty { return title }
        return inbox.body.isEmpty ? inbox.title : inbox.body
    }

    private var openLabel: String {
        switch entry.kind {
        case .buildPrompt: "Open session"
        case .runFailed: "Open run"
        case .budget: entry.held != nil ? "Open Overview" : "Open agent"
        default: "Open conversation"
        }
    }

    // MARK: Actions

    private func open() {
        if entry.held != nil {
            item = .overview(nil)
            return
        }
        if let s = entry.session {
            item = engine.item(for: s.ref.id) ?? .session(s.ref.id)
            return
        }
        if let note = entry.watchdog {
            if let target = engine.item(for: note.ref.id) { item = target }
            return
        }
        guard let inbox = entry.inbox else { return }
        let conversation = inbox.conversationId ?? "person:owner"
        UserDefaults.standard.set(conversation.hasPrefix("run:") ? "Activity" : "Chat", forKey: "agentTab")
        item = .agent(inbox.agent.id)
    }

    private func markRead() {
        guard let inbox = entry.inbox else { return }
        Task { await engine.markInboxRead([inbox]) }
    }

    private func decide(_ approve: Bool) {
        guard let inbox = entry.inbox, let approval = inbox.approval else { return }
        perform { try await engine.decide(inbox.agent, approvalId: approval.approvalId, approve: approve) }
    }

    private func respond(_ thread: ThreadModel, _ prompt: PendingPrompt, _ decision: PromptResponse.Decision) {
        Task { await thread.respond(prompt, PromptResponse(decision: decision)) }
    }

    /// The answer goes to the agent's chat with you, as your next message.
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

    private func setUpProvider() {
        UserDefaults.standard.set("Models", forKey: "settingsSection")
        WindowOpener.shared.openSettings?()
    }

    private func runAgain() {
        guard let agent = entry.agent else { return }
        perform {
            let upcoming = await engine.agentRuns(agent.ref)?.upcoming.first { $0.kind == "schedule" }
            _ = try await engine.agentRunNow(agent.ref, scheduleId: upcoming?.id, prompt: upcoming == nil ? "Run your usual check now." : nil)
            if let inbox = entry.inbox { await engine.markInboxRead([inbox]) }
        }
    }

    /// Your yes at 100% (docs/spec/34 OV3): this run, or background work for the rest of the month.
    private func release(month: Bool) {
        guard let h = entry.held else { return }
        perform { try await engine.releaseBudget(run: month ? nil : h.run, month: month) }
    }

    private func raise(to budget: Double) {
        guard let agent = entry.agent, let inbox = entry.inbox else { return }
        perform {
            guard let got = await engine.agentDefinition(agent.ref), var def = AgentDef(got.definition) else { return }
            var p = def.policies ?? .init()
            p.budgetUsdPerMonth = budget
            def.policies = p
            _ = try await engine.saveAgent(agent.ref, definition: def.json, instructions: got.instructions, message: "Raise the budget to \(MainSidebar.money(budget))")
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

extension NeedsYouEntry {
    /// Whether a notification or the menu bar's Inbox pointed at this one (an inbox item, an approval, a session, a note).
    func matches(_ focus: String) -> Bool {
        id == focus || inbox?.id == focus || inbox?.approval?.approvalId == focus || session?.ref.id == focus || watchdog?.id == focus
    }
}
