import PiopioKit
import PiopioTranscript
import SwiftUI

/// Home, the landing screen (docs/design v2, 1b): a greeting, one box to ask, start a session or message an agent,
/// then what needs you, what's running, what's coming up, and where to jump back in.
struct HomeView: View {
    let engine: EngineController
    @Binding var item: SidebarItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                greeting
                if Areas.shared.showsTip { tip.padding(.top, 20) }
                if askable { AskBox(engine: engine, item: $item).padding(.top, 22) }
                HStack(alignment: .top, spacing: 20) {
                    needsYou.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 18) {
                        running
                        comingUp
                    }
                    .frame(width: 330)
                }
                .padding(.top, 30)
                jumpBack.padding(.top, 30)
            }
            .padding(.horizontal, 32)
            .padding(.top, 56)
            .padding(.bottom, 40)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    /// The Ask box needs somewhere to send: Chat, a project with Build on, or an agent with Agents on.
    private var askable: Bool {
        let areas = Areas.shared.set
        return areas.contains(.chat) || (areas.contains(.build) && !engine.projects.isEmpty) || (areas.contains(.agents) && !engine.agents.isEmpty)
    }

    // MARK: Greeting

    private var greeting: some View {
        HStack(spacing: 16) {
            Chick(size: 52, ring: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Self.salutation()), \(Self.firstName)").font(.system(size: 26, weight: .bold)).tracking(-0.5)
                Text(dayLine).font(.system(size: 13.5)).foregroundStyle(Color.dsFg2)
            }
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

    private var dayLine: String {
        var parts = [Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))]
        let n = engine.needsYouCount
        parts.append(n == 0 ? "nothing needs you" : "\(n) thing\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") you")
        if let today = engine.usage?.todayUsd { parts.append("\(MainSidebar.money(today)) spent today") }
        return parts.joined(separator: " · ")
    }

    /// Once, for people who used Piopio before areas existed (docs/spec/15).
    private var tip: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(Area.allCases) { AreaTile(area: $0, size: 22) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Use only part of Piopio?").font(.system(size: 13, weight: .semibold))
                Text("Hide Build, Chat or Agents if you don't use them. Nothing is deleted.").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
            }
            Spacer()
            Button("Choose…") {
                UserDefaults.standard.set("General", forKey: "settingsSection")
                Areas.shared.showsTip = false
                WindowOpener.shared.openSettings?()
            }
            .buttonStyle(PillStyle(kind: .strong, compact: true))
            Button { withAnimation(.easeOut(duration: 0.2)) { Areas.shared.showsTip = false } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dsFg3).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Dismiss")
        }
        .padding(.horizontal, 14).frame(minHeight: 56)
        .background(Color.dsYolkSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Cards

    private func cardTitle(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
            if let count, count > 0 { Text("\(count)").font(.system(size: 13)).foregroundStyle(Color.dsFg3) }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder private var needsYou: some View {
        let entries = engine.needsYou
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("Needs you", count: entries.count)
            VStack(spacing: 0) {
                ForEach(Array(entries.prefix(4).enumerated()), id: \.element.id) { i, entry in
                    if i > 0 { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 30) }
                    HomeNeedsRow(engine: engine, entry: entry, item: $item)
                }
                if entries.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Color.dsGreen)
                        Text("Nothing waits for you.").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                        Spacer()
                    }
                    .padding(14)
                }
                if entries.count > 4 {
                    Rectangle().fill(Color.dsLine).frame(height: 0.5)
                    Button { item = .needsYou } label: {
                        Text("See all \(entries.count)").font(.system(size: 12.5)).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity).frame(height: 34)
                    }
                    .buttonStyle(.plain)
                }
            }
            .homeCard()
        }
    }

    @ViewBuilder private var running: some View {
        let live = (engine.buildSessions + engine.threads).filter { engine.liveStatus[$0.ref.id] == .running && Areas.shared.set.shows($0) }
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("Running now")
            VStack(spacing: 0) {
                ForEach(Array(live.prefix(3).enumerated()), id: \.element.ref.id) { i, s in
                    if i > 0 { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
                    Button { item = engine.item(for: s.ref.id) ?? .home } label: {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                                Text(engine.project(of: s)?.name ?? "Chat").font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                            }
                            Spacer()
                            Text(BuildSessionView.relative(s.updatedAt)).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                        }
                        .padding(.horizontal, 14).frame(height: 54).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if live.isEmpty {
                    Text("Nothing is running.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
            }
            .homeCard()
        }
    }

    @ViewBuilder private var comingUp: some View {
        let next = (Areas.shared.contains(.agents) ? engine.agents : []).filter { $0.agent?.status?.nextRun != nil }.sorted { ($0.agent?.status?.nextRun ?? "") < ($1.agent?.status?.nextRun ?? "") }
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                cardTitle("Coming up")
                VStack(spacing: 0) {
                    ForEach(Array(next.prefix(3).enumerated()), id: \.element.ref.id) { i, agent in
                        if i > 0 { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
                        HStack(spacing: 10) {
                            AgentAvatar(summary: agent, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
                                Text("\(MainSidebar.when(agent.agent?.status?.nextRun ?? "").capitalizedFirst) · this Mac").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                            }
                            Spacer()
                            Button("Run now") { runNow(agent) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                        }
                        .padding(.horizontal, 14).frame(height: 54)
                        .contentShape(Rectangle())
                        .onTapGesture { item = .agent(agent.ref.id) }
                    }
                }
                .homeCard()
            }
        }
    }

    private func runNow(_ agent: SessionSummary) {
        Task {
            let upcoming = await engine.agentRuns(agent.ref)?.upcoming.first { $0.kind == "schedule" }
            _ = try? await engine.agentRunNow(agent.ref, scheduleId: upcoming?.id, prompt: upcoming == nil ? "Run your usual check now." : nil)
            UserDefaults.standard.set("Activity", forKey: "agentTab")
            item = .agent(agent.ref.id)
        }
    }

    @ViewBuilder private var jumpBack: some View {
        let recent = Array((engine.spaces + engine.buildSessions.filter { $0.parent == nil } + engine.threads).filter { Areas.shared.set.shows($0) }.sorted { $0.updatedAt > $1.updatedAt }.prefix(3))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                cardTitle("Jump back in")
                HStack(spacing: 12) {
                    ForEach(recent, id: \.ref.id) { s in
                        Button { item = engine.item(for: s.ref.id) ?? .home } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(kind(s)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3).lineLimit(1)
                                Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                                Text(meta(s)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func kind(_ s: SessionSummary) -> String {
        switch s.ref.kind {
        case .space: "Notebook"
        case .build: "Session · \(engine.project(of: s)?.name ?? "")"
        default: "Chat"
        }
    }

    private func meta(_ s: SessionSummary) -> String {
        let when = BuildSessionView.relative(s.updatedAt)
        if s.ref.kind == .space { return "\(s.activeTopics.count) topics · \(when)" }
        return when
    }
}

/// A compact Needs you row for Home: a dot, the title, where it comes from, and one or two inline actions.
private struct HomeNeedsRow: View {
    let engine: EngineController
    let entry: NeedsYouEntry
    @Binding var item: SidebarItem

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(entry.isApproval ? Color.dsAmber : Color.accentColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                Text(source).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
    }

    private var title: String {
        switch entry.kind {
        case .approval: entry.inbox?.approval?.title ?? "Approval"
        case .message: entry.inbox?.body ?? "A message for you"
        case .runFailed: "A run failed"
        case .budget: entry.inbox?.title ?? "Budget"
        case .buildPrompt: buildTitle
        }
    }

    private var buildTitle: String {
        guard let s = entry.session, let prompt = engine.thread(s.ref).prompts.first else { return "Waiting on you" }
        if prompt.kind == .approval, let detail = prompt.detail, !detail.isEmpty, !detail.contains("\n") { return "Run \(detail)?" }
        return prompt.title
    }

    private var source: String {
        let hidden = entry.hiddenArea.map { "\($0.title) · hidden" }
        if let s = entry.session { return [s.title, engine.project(of: s)?.name, hidden].compactMap { $0 }.joined(separator: " · ") }
        return [entry.agent?.title ?? entry.inbox?.agentName ?? "", hidden].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        switch entry.kind {
        case .approval:
            HStack(spacing: 6) {
                Button("Deny") { decide(false) }.buttonStyle(PillStyle(compact: true))
                Button("Allow") { decide(true) }.buttonStyle(PillStyle(kind: .primary, compact: true))
            }
        case .buildPrompt:
            Button("Answer") { if let s = entry.session { item = .session(s.ref.id) } }.buttonStyle(PillStyle(compact: true))
        default:
            Button("Read") { item = .needsYou }.buttonStyle(PillStyle(compact: true))
        }
    }

    private func decide(_ approve: Bool) {
        guard let inbox = entry.inbox, let approval = inbox.approval else { return }
        Task { try? await engine.decide(inbox.agent, approvalId: approval.approvalId, approve: approve) }
    }
}

/// One box for everything (1b): a new chat by default; "@project" starts a Build session there, "@agent" messages it.
struct AskBox: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var text = ""
    @State private var target: Target = .chat
    @State private var showModels = false
    @State private var model: ModelRef?
    @FocusState private var focused: Bool

    enum Target: Hashable { case chat, project(String), agent(String) }

    private var areas: AreaSet { Areas.shared.set }

    /// "Ask anything, start a build session, or message an agent…", for the areas that are on.
    private var placeholder: String {
        var parts: [String] = []
        if areas.contains(.chat) { parts.append("Ask anything") }
        if areas.contains(.build) { parts.append(parts.isEmpty ? "Start a build session" : "start a build session") }
        if areas.contains(.agents) { parts.append(parts.isEmpty ? "Message an agent" : "message an agent") }
        return parts.count > 1 ? parts.dropLast().joined(separator: ", ") + ", or " + parts.last! + "…" : parts[0] + "…"
    }

    /// The first target the areas allow: a chat, a session in the first project, or the first agent.
    private var defaultTarget: Target? {
        if areas.contains(.chat) { return .chat }
        if areas.contains(.build), let p = engine.projects.first { return .project(p.id) }
        if areas.contains(.agents), let a = engine.agents.first { return .agent(a.ref.id) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
            HStack(spacing: 8) {
                Menu {
                    if areas.contains(.chat) { Button("New chat") { target = .chat } }
                    if areas.contains(.build), !engine.projects.isEmpty {
                        Section("Start a session in") {
                            ForEach(engine.projects) { p in Button(p.name) { target = .project(p.id) } }
                        }
                    }
                    if areas.contains(.agents), !engine.agents.isEmpty {
                        Section("Message") {
                            ForEach(engine.agents, id: \.ref.id) { a in Button(a.title) { target = .agent(a.ref.id) } }
                        }
                    }
                } label: { Text(targetLabel) }
                    .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.visible).fixedSize()
                if target == .chat {
                    Button { showModels = true } label: { Text(modelLabel) }
                        .buttonStyle(ChipStyle())
                        .popover(isPresented: $showModels, arrowEdge: .bottom) {
                            ModelPicker(engine: engine, selected: model ?? engine.preferredModel) { m in model = m; showModels = false }
                        }
                }
                Spacer()
                Text(hint).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.dsInvFg)
                        .frame(width: 28, height: 28).background(Color.dsInv, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? Color.dsAccentLine : Color.dsLine, lineWidth: focused ? 1 : 0.5))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
        .onChange(of: text) { _, t in mention(t) }
        .onAppear { if target == .chat, let first = defaultTarget { target = first } }
        .onChange(of: areas) { _, _ in if let first = defaultTarget { target = first } }
    }

    private var targetLabel: String {
        switch target {
        case .chat: "New chat"
        case .project(let id): "Session in \(engine.projects.first { $0.id == id }?.name ?? "project")"
        case .agent(let id): "Message \(engine.agents.first { $0.ref.id == id }?.title ?? "agent")"
        }
    }

    private var modelLabel: String {
        let ref = model ?? engine.preferredModel
        return engine.model(ref).map(ModelChip.short) ?? ref?.id ?? "Model"
    }

    private var hint: String {
        let p = areas.contains(.build) ? engine.projects.first?.name : nil
        let a = areas.contains(.agents) ? engine.agents.first?.title : nil
        return [p.map { "@\($0) starts a session" }, a.map { "@\($0) messages the agent" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// "@name " at the start picks a project or an agent.
    private func mention(_ t: String) {
        guard t.hasPrefix("@"), let space = t.firstIndex(of: " ") else { return }
        let name = String(t[t.index(after: t.startIndex)..<space]).lowercased()
        if areas.contains(.build), let p = engine.projects.first(where: { $0.name.lowercased() == name }) {
            target = .project(p.id)
            text = String(t[t.index(after: space)...])
        } else if areas.contains(.agents), let a = engine.agents.first(where: { $0.title.lowercased().replacingOccurrences(of: " ", with: "") == name.replacingOccurrences(of: " ", with: "") }) {
            target = .agent(a.ref.id)
            text = String(t[t.index(after: space)...])
        }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        text = ""
        switch target {
        case .chat:
            Task {
                guard let ref = await engine.createThread(model: model) else { return }
                try? await engine.refreshCatalog()
                item = .chat(ref.id)
                let thread = engine.thread(ref)
                await thread.open()
                await thread.send(message)
            }
        case .project(let id):
            guard let project = engine.projects.first(where: { $0.id == id }) else { return }
            NotificationCenter.default.post(name: .newBuildSession, object: project.id, userInfo: ["prompt": message])
        case .agent(let id):
            item = .agent(id)
            UserDefaults.standard.set("Chat", forKey: "agentTab")
            Task {
                let thread = engine.thread(ContainerRef(kind: .agent, id: id))
                await thread.open()
                await thread.send(message)
            }
        }
    }
}

private extension View {
    func homeCard() -> some View {
        self
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
