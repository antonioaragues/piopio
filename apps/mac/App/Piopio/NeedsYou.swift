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

/// The triage feed (6b): every item resolvable in place; the first one carries the decision halo.
struct NeedsYouView: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @AppStorage("needsYouFilter") private var filter: Filter = .all

    enum Filter: String, CaseIterable { case all = "All", approvals = "Approvals", messages = "Messages" }

    private var entries: [NeedsYouEntry] {
        let all = engine.needsYou
        switch filter {
        case .all: return all
        case .approvals: return all.filter(\.isApproval)
        case .messages: return all.filter(\.isMessage)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Needs you").font(.system(size: 26, weight: .bold)).tracking(-0.5)
                        let n = engine.needsYou.count
                        Text(n == 0 ? "Nothing waiting" : "\(n) item\(n == 1 ? "" : "s") · oldest first").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(Filter.allCases, id: \.self) { f in
                            Button { filter = f } label: { Text("\(f.rawValue) \(count(f))") }
                                .buttonStyle(FilterCapsule(active: filter == f))
                        }
                    }
                }
                .padding(.bottom, 4)
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    NeedsYouCard(engine: engine, entry: entry, item: $item, primary: index == 0)
                }
                VStack(spacing: 10) {
                    Chick(size: 44).opacity(0.9)
                    Text(entries.isEmpty && filter != .all ? "Nothing here." : "That's everything. Piopio will chirp when something new comes in.")
                        .font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
            }
            .padding(.horizontal, 32)
            .padding(.top, 48)
            .padding(.bottom, 40)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .task { await engine.loadInbox() }
    }

    private func count(_ f: Filter) -> Int {
        switch f {
        case .all: engine.needsYou.count
        case .approvals: engine.needsYou.filter(\.isApproval).count
        case .messages: engine.needsYou.filter(\.isMessage).count
        }
    }
}

/// "All 3" (inv when selected) / "Approvals 1" capsules.
struct FilterCapsule: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? Color.dsInvFg : Color.dsFg)
            .padding(.horizontal, 11).frame(height: 26)
            .background(active ? Color.dsInv : Color.dsChip, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// One feed card: what it is, where it comes from, and the actions that resolve it.
struct NeedsYouCard: View {
    let engine: EngineController
    let entry: NeedsYouEntry
    @Binding var item: SidebarItem
    var primary = false
    @State private var reply = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Group {
            if entry.kind == .buildPrompt, let s = entry.session {
                BuildPromptEntry(engine: engine, session: s, item: $item)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        if let agent = entry.agent, primary { AgentAvatar(summary: agent, size: 28) } else { Circle().fill(dot).frame(width: 7, height: 7).padding(.top, 6) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true)
                            Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if !primary || entry.kind != .message { inlineActions } else { openLink }
                    }
                    if entry.kind == .message, let body = entry.inbox?.body {
                        Text("“\(body)”").font(.system(size: 13.5)).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, primary ? 38 : 17)
                    }
                    if entry.kind == .message, primary { replyField.padding(.leading, 38) }
                    if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(Color.dsRed) }
                }
                .padding(14)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(primary ? Color.dsAccentLine : Color.dsLine, lineWidth: primary ? 1 : 0.5))
                .background(RoundedRectangle(cornerRadius: 18).fill(primary ? Color.dsAccentSoft : .clear).padding(-4))
                .disabled(busy)
            }
        }
    }

    private var agentName: String { (entry.agent?.title ?? entry.inbox?.agentName ?? "Agent") + (entry.hiddenArea != nil ? " (Agents · hidden)" : "") }

    private var title: String {
        switch entry.kind {
        case .approval: entry.inbox?.approval?.title ?? "\(agentName) asks first"
        case .message: "\(agentName) wrote to you"
        case .runFailed: "\(agentName): a run failed"
        case .budget: entry.inbox?.title == "Budget used up" ? "\(agentName) paused itself" : "\(agentName): \(entry.inbox?.title ?? "budget")"
        case .buildPrompt: ""
        }
    }

    private var subtitle: String {
        let at = BuildSessionView.relative(entry.at)
        switch entry.kind {
        case .approval: return "\(agentName) · asks first · \(at)"
        case .message: return entry.inbox?.conversationId?.hasPrefix("run:") == true ? "Automatic run · \(at)" : at
        case .runFailed, .budget: return "\(entry.inbox?.body ?? "") · \(at)"
        case .buildPrompt: return ""
        }
    }

    private var dot: Color { entry.kind == .message ? .accentColor : entry.kind == .runFailed ? .dsRed : .dsAmber }

    private var openLink: some View {
        Button { open() } label: {
            HStack(spacing: 3) { Text("Open"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                .font(.system(size: 12)).foregroundStyle(Color.dsFg2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var inlineActions: some View {
        HStack(spacing: 6) {
            switch entry.kind {
            case .approval:
                Button("Deny") { decide(false) }.buttonStyle(PillStyle(compact: true))
                Button("Allow once") { decide(true) }.buttonStyle(PillStyle(kind: .primary, compact: true)).keyboardShortcut(primary ? KeyboardShortcut(.return, modifiers: []) : nil)
            case .message:
                Button("Read") { open(); markRead() }.buttonStyle(PillStyle(compact: true))
            case .runFailed:
                Button("Dismiss") { markRead() }.buttonStyle(PillStyle(compact: true))
                Button("Open run") { open(); markRead() }.buttonStyle(PillStyle(kind: .strong, compact: true))
            case .budget:
                Button("Keep paused") { markRead() }.buttonStyle(PillStyle(compact: true))
                if let budget = entry.agent?.agent?.status?.budgetUsd {
                    Button("Raise to \(MainSidebar.money(max(1, budget * 2)))") { raise(to: max(1, budget * 2)) }.buttonStyle(PillStyle(kind: .strong, compact: true))
                }
            case .buildPrompt:
                EmptyView()
            }
        }
    }

    private var replyField: some View {
        HStack(spacing: 8) {
            TextField("Reply to \(agentName)…", text: $reply).textFieldStyle(.plain).font(.system(size: 13)).onSubmit(send)
            Button("Send ↩", action: send).buttonStyle(PillStyle(kind: .primary, compact: true)).disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 36)
        .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 10))
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

/// A Build session waiting on you: where it is, then its own approval or question card.
private struct BuildPromptEntry: View {
    let engine: EngineController
    let session: SessionSummary
    @Binding var item: SidebarItem

    var body: some View {
        let thread = engine.thread(session.ref)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.dsAmber).frame(width: 7, height: 7)
                Text(session.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.dsFg)
                Text(engine.project(of: session)?.name ?? "").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Spacer()
                Button { item = .session(session.ref.id) } label: {
                    HStack(spacing: 3) { Text("Open session"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(thread.prompts.enumerated()), id: \.element.id) { i, prompt in
                PromptCard(session: thread, prompt: prompt, primary: i == 0)
            }
            if thread.prompts.isEmpty {
                Text("Waiting on you…").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
            }
        }
        .task(id: session.ref.id) { await thread.open() }
    }
}
