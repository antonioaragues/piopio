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

    var isApproval: Bool { kind == .approval || kind == .buildPrompt }

    /// Never hidden (docs/spec/15): an item from a hidden area still shows, marked with its area.
    @MainActor var hiddenArea: Area? {
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
        if let s = entry.session { return s.title + hidden }
        if let n = entry.watchdog { return n.title + hidden }
        return (entry.agent?.title ?? entry.inbox?.agentName ?? "Agent") + hidden
    }

    @MainActor static func title(_ entry: NeedsYouEntry, engine: EngineController) -> String {
        switch entry.kind {
        case .approval: return entry.inbox?.approval?.title ?? "Asks before doing something"
        case .message: return entry.inbox.map { firstLine($0.body) } ?? "Wrote to you"
        case .runFailed: return "\(source(entry, engine: engine)) didn't run"
        case .budget: return entry.inbox?.title ?? "Budget"
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
        case .budget: entry.inbox?.title == "Budget used up" ? "paused itself" : "budget"
        case .buildPrompt: "is waiting on you"
        case .watchdog: entry.watchdog?.rule == "looping" ? "is repeating itself" : "looks stuck"
        }
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

    private var isOpen: Bool { expanded == entry.id }
    private var thread: ThreadModel? { entry.kind == .buildPrompt ? entry.session.map { engine.thread($0.ref) } : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.dsFg3)
                    .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 10)
                Circle().fill(entry.isApproval ? Color.dsWarn : .accentColor).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line).font(.system(size: 13.5)).foregroundStyle(Color.dsFg).lineLimit(2)
                    Text("\(origin) · \(BuildSessionView.relative(entry.at))").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                Spacer(minLength: 12)
                quick
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.18)) { expanded = isOpen ? nil : entry.id } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isOpen ? "Hides the details" : "Shows the details")
            if isOpen { detail.padding(.leading, 37).padding(.bottom, 14).transition(.opacity) }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn).padding(.leading, 37).padding(.bottom, 8) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
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
        default: "Agent · \(NeedsYouText.what(entry))"
        }
    }

    // MARK: The row's actions

    /// The one that resolves it, black; the others as text.
    @ViewBuilder private var quick: some View {
        HStack(spacing: 8) {
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
            case .buildPrompt:
                if let thread, let prompt = thread.prompts.first, prompt.kind == .approval {
                    Button("Deny") { respond(thread, prompt, .deny) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    Button("Allow") { respond(thread, prompt, .allow) }.buttonStyle(PillStyle(kind: .primary, compact: true))
                } else {
                    Button("Answer") { withAnimation(.snappy(duration: 0.18)) { expanded = entry.id } }.buttonStyle(PillStyle(compact: true))
                }
            case .runFailed:
                Button("Dismiss") { markRead() }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                if engine.needsKey {
                    Button("Set up a provider") { setUpProvider() }.buttonStyle(PillStyle(kind: .primary, compact: true))
                } else {
                    Button("Run again") { runAgain() }.buttonStyle(PillStyle(kind: .primary, compact: true))
                }
            case .budget:
                Button("Keep paused") { markRead() }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                if let budget = entry.agent?.agent?.status?.budgetUsd {
                    Button("Raise to \(MainSidebar.money(max(1, budget * 2)))") { raise(to: max(1, budget * 2)) }.buttonStyle(PillStyle(kind: .primary, compact: true))
                }
            case .watchdog:
                // The Watchdog never stops anything itself (docs/spec/17 §4): you look, and decide.
                if let note = entry.watchdog {
                    Button("Dismiss") { Task { await engine.dismissWatchdog(note) } }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                }
                Button("Open") { open() }.buttonStyle(PillStyle(compact: true))
            }
        }
    }

    // MARK: The full card

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let thread {
                ForEach(thread.prompts) { prompt in PromptCard(session: thread, prompt: prompt, primary: false) }
                if thread.prompts.isEmpty { Text("Waiting on you…").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3) }
            } else if let body = content, !body.isEmpty {
                Text(body).font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            // The Watchdog's row already has Open.
            if entry.kind != .watchdog {
                HStack(spacing: 14) {
                    if entry.kind == .runFailed, engine.needsKey {
                        Button("Run again") { runAgain() }.buttonStyle(PillStyle(compact: true))
                    }
                    Button(openLabel) { open(); if entry.kind == .message || entry.kind == .runFailed { markRead() } }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                }
            }
        }
    }

    private var content: String? {
        if let note = entry.watchdog { return note.text }
        guard let inbox = entry.inbox else { return nil }
        if entry.kind == .approval, let title = inbox.approval?.title, inbox.body.isEmpty { return title }
        return inbox.body.isEmpty ? inbox.title : inbox.body
    }

    private var openLabel: String {
        switch entry.kind {
        case .buildPrompt: "Open session"
        case .runFailed: "Open run"
        case .budget: "Open agent"
        default: "Open conversation"
        }
    }

    // MARK: Actions

    private func open() {
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
