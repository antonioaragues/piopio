import PiopioKit
import PiopioTranscript
import SwiftUI

/// One thing that waits for you (docs/design v2, "Needs you"): an agent's approval, message, failed run or budget
/// stop, or a Build session waiting on an approval or a question. Aggregated across the engine, oldest first.
struct NeedsYouEntry: Identifiable {
    enum Kind { case approval, message, runFailed, budget, buildPrompt }
    let id: String
    let kind: Kind
    let at: String
    var inbox: InboxItem?
    var agent: SessionSummary?
    var session: SessionSummary?

    var isApproval: Bool { kind == .approval || kind == .buildPrompt }

    /// Never hidden (docs/spec/15): an item from a hidden area still shows, marked with its area.
    @MainActor var hiddenArea: Area? {
        let area: Area = session.map { $0.profile == .chat ? .chat : .build } ?? .agents
        return Areas.shared.contains(area) ? nil : area
    }
    var isMessage: Bool { kind == .message || kind == .runFailed || kind == .budget }
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
        return out.sorted { $0.at < $1.at }
    }
}

/// Needs you (docs/design/grey 14b): one centered column. Each item is a block between hairlines: who it's from and
/// what happened in a grey line, the content in plain words, and its actions. One black button per item, the one that
/// resolves it; the rest are text. Newest first.
struct NeedsYouView: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @AppStorage("needsYouFilter") private var filter: Filter = .all

    enum Filter: String, CaseIterable { case all = "All", approvals = "Approvals", messages = "Messages", problems = "Problems" }

    private func entries(_ f: Filter) -> [NeedsYouEntry] {
        let all = Array(engine.needsYou.reversed())
        switch f {
        case .all: return all
        case .approvals: return all.filter(\.isApproval)
        case .messages: return all.filter { $0.kind == .message }
        case .problems: return all.filter { $0.kind == .runFailed || $0.kind == .budget }
        }
    }

    var body: some View {
        let shown = entries(filter)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Needs you").font(.system(size: 28, weight: .bold)).tracking(-0.6).foregroundStyle(Color.dsFg)
                        let n = engine.needsYou.count
                        Text(n == 0 ? "Nothing waiting" : "\(n) thing\(n == 1 ? "" : "s"), newest first").font(.system(size: 13.5)).foregroundStyle(Color.dsFg3)
                    }
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(Filter.allCases, id: \.self) { f in
                            Button(f.rawValue) { filter = f }.buttonStyle(SelectorStyle(active: filter == f))
                                .font(.system(size: 12.5)).foregroundStyle(filter == f ? Color.dsFg : Color.dsFg2)
                        }
                    }
                    .padding(.top, 6)
                }
                .padding(.bottom, 20)
                ForEach(shown) { entry in
                    Rectangle().fill(Color.dsLine).frame(height: 0.5)
                    NeedsYouCard(engine: engine, entry: entry, item: $item)
                        .padding(.vertical, 18)
                }
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                Text(shown.isEmpty && filter != .all ? "Nothing here." : "That's everything. You'll get a notification when something new comes in.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                    .padding(.top, 20)
            }
            .padding(.horizontal, 32)
            .padding(.top, 72)
            .padding(.bottom, 48)
            .frame(maxWidth: 704)
            .frame(maxWidth: .infinity)
        }
        .task { await engine.loadInbox() }
    }
}

/// What a Needs you item is called and where it's from, shared with Home.
enum NeedsYouText {
    @MainActor static func source(_ entry: NeedsYouEntry, engine: EngineController) -> String {
        let hidden = entry.hiddenArea.map { " (\($0.title) · hidden)" } ?? ""
        if let s = entry.session { return s.title + hidden }
        return (entry.agent?.title ?? entry.inbox?.agentName ?? "Agent") + hidden
    }

    @MainActor static func title(_ entry: NeedsYouEntry, engine: EngineController) -> String {
        switch entry.kind {
        case .approval: return entry.inbox?.approval?.title ?? "Asks before doing something"
        case .message: return entry.inbox.map { firstLine($0.body) } ?? "Wrote to you"
        case .runFailed: return "\(source(entry, engine: engine)) didn't run"
        case .budget: return entry.inbox?.title ?? "Budget"
        case .buildPrompt:
            guard let s = entry.session, let prompt = engine.thread(s.ref).prompts.first else { return "Waiting on you" }
            if prompt.kind == .approval, let detail = prompt.detail, !detail.isEmpty, !detail.contains("\n") { return "Run \(detail)?" }
            return prompt.title
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
        }
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    }
}

/// One Needs you item: "● Source  what happened · age", the content, then the actions.
struct NeedsYouCard: View {
    let engine: EngineController
    let entry: NeedsYouEntry
    @Binding var item: SidebarItem
    @State private var reply = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        if entry.kind == .buildPrompt, let s = entry.session {
            BuildPromptEntry(engine: engine, entry: entry, session: s, item: $item)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                NeedsYouHeadline(source: NeedsYouText.source(entry, engine: engine), what: NeedsYouText.what(entry), at: entry.at) {
                    if entry.kind == .message || entry.kind == .approval {
                        Button("Open conversation") { open(); if entry.kind == .message { markRead() } }
                            .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    }
                }
                if entry.kind == .approval {
                    approvalCard.padding(.leading, 16)
                } else {
                    content.padding(.leading, 16)
                    if entry.kind == .message { replyField.padding(.leading, 16) } else { actions.padding(.leading, 16) }
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2).padding(.leading, 16) }
            }
            .disabled(busy)
        }
    }

    /// The same card as in a conversation (11c).
    private var approvalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                let title = entry.inbox?.approval?.title ?? "Allow this"
                Text(title.hasSuffix("?") ? title : title + "?").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
            }
            if let body = entry.inbox?.body, !body.isEmpty {
                Text(body).font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Button("Deny") { decide(false) }.buttonStyle(PillStyle(compact: true))
                Spacer()
                Button("Allow") { decide(true) }.buttonStyle(PillStyle(kind: .primary, compact: true))
            }
        }
        .askCard()
    }

    private var content: some View {
        Text(entry.inbox?.body ?? entry.inbox?.title ?? "").font(.system(size: 13.5)).foregroundStyle(Color.dsFg)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 14) {
            switch entry.kind {
            case .approval:
                EmptyView()
            case .runFailed:
                // The one black button is the one that fixes it.
                if engine.needsKey {
                    Button("Set up a provider") {
                        UserDefaults.standard.set("Models", forKey: "settingsSection")
                        WindowOpener.shared.openSettings?()
                    }
                    .buttonStyle(PillStyle(kind: .primary, compact: true))
                    Button("Run again") { runAgain() }.buttonStyle(PillStyle(compact: true))
                } else {
                    Button("Run again") { runAgain() }.buttonStyle(PillStyle(kind: .primary, compact: true))
                }
                Button("Open run") { open(); markRead() }.buttonStyle(PillStyle(compact: true))
                Button("Dismiss") { markRead() }.buttonStyle(PillStyle(compact: true))
            case .budget:
                if let budget = entry.agent?.agent?.status?.budgetUsd {
                    Button("Raise to \(MainSidebar.money(max(1, budget * 2)))") { raise(to: max(1, budget * 2)) }.buttonStyle(PillStyle(kind: .primary, compact: true))
                }
                Button("Keep paused") { markRead() }.buttonStyle(PillStyle(compact: true))
            case .message, .buildPrompt:
                EmptyView()
            }
        }
    }

    /// The reply field; its send button appears once you type.
    private var replyField: some View {
        HStack(spacing: 8) {
            TextField("", text: $reply, prompt: Text("Reply to \(NeedsYouText.source(entry, engine: engine))…").foregroundStyle(Color.dsFg3)).textFieldStyle(.plain).font(.system(size: 13)).onSubmit(send)
            if !reply.trimmingCharacters(in: .whitespaces).isEmpty {
                SendButton(enabled: true, action: send).scaleEffect(0.85)
            } else {
                Text("↩").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 36)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }

    private func runAgain() {
        guard let agent = entry.agent else { return }
        perform {
            let upcoming = await engine.agentRuns(agent.ref)?.upcoming.first { $0.kind == "schedule" }
            _ = try await engine.agentRunNow(agent.ref, scheduleId: upcoming?.id, prompt: upcoming == nil ? "Run your usual check now." : nil)
            if let inbox = entry.inbox { await engine.markInboxRead([inbox]) }
        }
    }

    // MARK: Actions

    private func open() {
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

/// "● Source  what happened · age", with something on the right.
struct NeedsYouHeadline<Trailing: View>: View {
    let source: String
    let what: String
    let at: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            Text(source).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
            Text("\(what) · \(BuildSessionView.relative(at))").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// A Build session waiting on you: where it is, then its own approval or question card.
private struct BuildPromptEntry: View {
    let engine: EngineController
    let entry: NeedsYouEntry
    let session: SessionSummary
    @Binding var item: SidebarItem

    var body: some View {
        let thread = engine.thread(session.ref)
        VStack(alignment: .leading, spacing: 10) {
            NeedsYouHeadline(source: session.title, what: engine.project(of: session).map { "in \($0.name)" } ?? "is waiting on you", at: entry.at) {
                Button("Open session") { item = .session(session.ref.id) }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(thread.prompts.enumerated()), id: \.element.id) { i, prompt in
                    PromptCard(session: thread, prompt: prompt, primary: i == 0)
                }
                if thread.prompts.isEmpty {
                    Text("Waiting on you…").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                }
            }
            .padding(.leading, 16)
        }
        .task(id: session.ref.id) { await thread.open() }
    }
}
