import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Automations (docs/spec/27 §4): work that starts when nobody started it. One list for Piopio and every agent; each
// one's page reads as a sentence ("Every Monday at 09:00, ask Rita to …, and tell me on Telegram"), with what it's
// told, what it may do while you're away, and its runs. You make them by asking; New Automation is for when you'd
// rather not.

/// The list (the agents and automations handoff, screen 4): a title and line, New automation, chips by who runs it,
/// and the automations in three groups, Needs you · On · Paused, each group's header naming the columns.
///
/// You make one by asking (AU4), so asking is here too (docs/design/automations/prototype): with nothing yet, the page
/// is a box to ask in; New automation asks in a popover, or sets one up by hand on a draft of its page.
struct AutomationsPage: View {
    let engine: EngineController
    /// "piopio", an agent's id or a project's id: only those.
    let filter: String?
    @Binding var item: SidebarItem
    /// New automation by hand: a draft of its page, nothing saved until Turn on.
    @State private var draft: AutomationDraft?
    @State private var showNew = false
    @State private var askText = ""
    @State private var askRunner = "piopio"
    /// Who's setting one up right now.
    @State private var asking: String?
    @State private var askError: String?
    @State private var toast: AutomationToast?
    /// New automation with nothing yet: the box on the page lights up instead of a second box in a popover.
    @State private var nudge = false
    @FocusState private var composerFocused: Bool

    private var shown: [Automation] {
        guard let filter else { return engine.automations }
        return engine.automations.filter { $0.runsAs == filter || $0.project == filter }
    }

    private var project: ProjectInfo? { filter.flatMap { f in engine.projects.first { $0.id == f } } }

    /// The list filtered to an agent asks that agent; otherwise you choose.
    private var fixedRunner: String? { filter.flatMap { f in project == nil ? f : nil } }
    private var runner: String { fixedRunner ?? askRunner }

    /// All, Piopio, then each agent that runs one (and the one filtered on, even with none).
    private var runners: [String] {
        var ids = Set(engine.automations.map(\.runsAs)).subtracting(["piopio"])
        if let filter, project == nil, filter != "piopio" { ids.insert(filter) }
        return ["piopio"] + ids.sorted { engine.runnerName($0) < engine.runnerName($1) }
    }

    var body: some View {
        Group {
            if let draft {
                AutomationPage(engine: engine, id: nil, item: $item, draft: draft) { self.draft = nil }
            } else {
                list
            }
        }
        .onChange(of: filter) { draft = nil; showNew = false }
        .onReceive(NotificationCenter.default.publisher(for: .automationsDemo)) { note in
            guard let what = note.object as? String else { return }
            if what == "new" { newAutomation() }
            else if what == "draft" { startDraft() }
            else if what.hasPrefix("ask:") { askText = String(what.dropFirst(4)); send() }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Automations").font(.system(size: 28, weight: .bold)).tracking(-0.6).foregroundStyle(Color.dsFg)
                        Text("Work that runs when nobody started it. Ask Piopio or any agent to set one up, or make one here.")
                            .font(.system(size: 14)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("New automation", action: newAutomation).buttonStyle(OutlineButtonStyle())
                        .popover(isPresented: $showNew, arrowEdge: .bottom) { askPopover }
                }
                if !engine.automations.isEmpty || filter != nil {
                    HStack(spacing: 6) {
                        chip(nil, "All")
                        ForEach(runners, id: \.self) { id in chip(id, engine.runnerName(id), tile: id) }
                        if let project {
                            Button { item = .automations(nil) } label: {
                                HStack(spacing: 5) {
                                    Text("In \(project.name)")
                                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                                }
                                .font(.system(size: 12)).foregroundStyle(Color.dsInvFg)
                                .padding(.horizontal, 11).frame(height: 26)
                                .background(Capsule().fill(Color.dsInv))
                            }
                            .buttonStyle(.plain)
                            .help("Show every project's")
                        }
                        Spacer(minLength: 12)
                        RunsOnNote()
                    }
                }
                if shown.isEmpty {
                    empty
                } else {
                    VStack(alignment: .leading, spacing: 26) {
                        group("Needs you", tone: .dsWarn, shown.filter { $0.lastStatus == "waiting" })
                        group("On", tone: .dsFg, shown.filter { $0.enabled && $0.lastStatus != "waiting" })
                        group("Paused", tone: .dsFg3, shown.filter { !$0.enabled && $0.lastStatus != "waiting" })
                    }
                }
            }
            .padding(.horizontal, 56)
            .padding(.top, 44)
            .padding(.bottom, 90)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(Color.dsWin)
        .overlay(alignment: .bottom) {
            if let toast {
                AutomationToastView(toast: toast) { self.toast = nil }
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast?.id)
    }

    /// A filter chip: inverse when chosen, the field grey otherwise; an agent's has its tile.
    private func chip(_ id: String?, _ title: String, tile: String? = nil) -> some View {
        let on = id == filter
        return Button { item = .automations(id) } label: {
            HStack(spacing: 6) {
                if let tile { RunnerTile(engine: engine, runsAs: tile, size: 18) }
                Text(title)
            }
            .font(.system(size: 12.5)).foregroundStyle(on ? Color.dsInvFg : Color.dsFg)
            .padding(.leading, tile == nil ? 11 : 4).padding(.trailing, 11).frame(height: 26)
            .background(Capsule().fill(on ? Color.dsInv : Color.dsChip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func group(_ title: String, tone: Color, _ list: [Automation]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                AutomationColumns {
                    Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tone)
                    Text("Runs as")
                    Text("Tells you")
                    Text("Last or next run")
                    Color.clear.frame(height: 1)
                }
                .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                .padding(.horizontal, 14).padding(.bottom, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
                ForEach(list) { a in
                    AutomationRow(engine: engine, automation: a) { item = .automation(a.id) }
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
                }
            }
        }
    }

    // MARK: Nothing yet

    /// Nothing yet: the sidebar's Automations glyph (piopio stays on Home), a box to ask in, four ideas that fill it,
    /// and setting one up by hand.
    private var empty: some View {
        let name = engine.runnerName(runner)
        return VStack(spacing: 0) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 22, weight: .regular)).foregroundStyle(Color.dsFg2)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.dsChip))
                .accessibilityHidden(true)
            Text(fixedRunner.map { "\(engine.runnerName($0)) doesn't run anything on its own yet" } ?? "What should happen without you?")
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.dsFg)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
            Text("Say when and what, in plain words. \(name) sets it up and it shows here.")
                .font(.system(size: 13.5)).foregroundStyle(Color.dsFg2).multilineTextAlignment(.center)
                .padding(.top, 6)
            composer(size: 14)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).opacity(nudge ? 1 : 0))
                .animation(.easeOut(duration: 0.25), value: nudge)
                .padding(.top, 18)
            if let askError {
                Text(askError).font(.system(size: 12.5)).foregroundStyle(Color.dsRed).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { suggestions(Self.ideas) }
                VStack(spacing: 6) {
                    HStack(spacing: 6) { suggestions(Array(Self.ideas.prefix(2))) }
                    HStack(spacing: 6) { suggestions(Array(Self.ideas.suffix(2))) }
                }
            }
            .padding(.top, 12)
            HStack(spacing: 8) {
                RunsOnNote()
                Text("·").foregroundStyle(Color.dsFg3)
                Button("Set one up yourself") { startDraft() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: 580)
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    /// What to ask, in plain words: the chip's title, and what it fills the box with.
    static let ideas: [(String, String)] = [
        ("Morning brief", "Every weekday at 8, send me today's calendar and anything urgent in my inbox."),
        ("File invoices from email", "When an invoice arrives by email, file it and tell me the total."),
        ("Tidy Downloads", "When a file appears in Downloads, rename it sensibly and tell me what it is."),
        ("Weekly recap", "Every Friday at 17:00, recap what I worked on this week."),
    ]

    private func suggestions(_ list: [(String, String)]) -> some View {
        ForEach(list, id: \.0) { title, text in
            Button { askText = text; askError = nil; composerFocused = true } label: {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Color.dsFg)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(Color.dsChip))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(text)
        }
    }

    // MARK: Asking

    /// The box: what to set up, who sets it up (fixed when the list is filtered to an agent), and send. While the runner
    /// works, the send button says so.
    private func composer(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $askText, prompt: Text("Every weekday at 8, send me today's calendar and anything urgent in my inbox").foregroundStyle(Color.dsFg3), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: size)).lineLimit(2...6)
                .focused($composerFocused)
                .disabled(asking != nil)
                .onSubmit(send)
                .onChange(of: askText) { if askError != nil { askError = nil } }
            HStack(spacing: 8) {
                runnerMenu
                if let project {
                    Text("Piopio can set it up in \(project.name)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                Spacer()
                if let asking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("\(engine.runnerName(asking)) is setting it up…").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                    }
                } else {
                    SendButton(enabled: !askText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: send)
                        .accessibilityLabel("Set it up")
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.top, 12).padding(.bottom, 10)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.dsFg.opacity(0.14)))
        .contentShape(Rectangle())
        .onTapGesture { composerFocused = true }
    }

    @ViewBuilder private var runnerMenu: some View {
        let label = HStack(spacing: 6) {
            RunnerTile(engine: engine, runsAs: runner, size: 18)
            Text(engine.runnerName(runner)).font(.system(size: 12.5)).foregroundStyle(Color.dsFg)
            if fixedRunner == nil { Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Color.dsFg3) }
        }
        .padding(.leading, 4).padding(.trailing, 10).frame(height: 26)
        .background(Capsule().fill(Color.dsChip))
        if fixedRunner != nil || engine.agents.isEmpty || project != nil {
            label.help("\(engine.runnerName(runner)) sets it up")
        } else {
            Menu {
                Button("Piopio") { askRunner = "piopio" }
                ForEach(engine.agents.filter { $0.agent?.draft != true }, id: \.ref.id) { agent in
                    Button(agent.title) { askRunner = agent.ref.id }
                }
            } label: { label }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Who sets it up, and runs it")
        }
    }

    /// New automation with automations: ask in a popover, or set one up by hand.
    private var askPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should run on its own?").font(.system(size: 13.5, weight: .semibold))
            composer(size: 13)
            if let askError { Text(askError).font(.system(size: 12)).foregroundStyle(Color.dsRed).fixedSize(horizontal: false, vertical: true) }
            Flow(spacing: 6, lineSpacing: 6) { suggestions(Array(Self.ideas.prefix(3))) }
            Divider().padding(.top, 2)
            Button { startDraft() } label: {
                HStack { Text("Set it up yourself"); Spacer(); Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)) }
                    .font(.system(size: 12.5)).foregroundStyle(Color.accentColor).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { composerFocused = true }
    }

    private func newAutomation() {
        if shown.isEmpty {
            // The box is right there: light it up rather than open a second one.
            composerFocused = true
            nudge = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { nudge = false }
        } else {
            askError = nil
            showNew.toggle()
        }
    }

    private func startDraft() {
        showNew = false
        draft = AutomationDraft(preset: filter, runsAs: runner, prompt: askText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Sends what you wrote to the runner (a new conversation with Piopio, or the agent's chat) and stays here. When it
    /// has answered: what it set up, with Open and Undo; or, when it asked you something instead, a way to that answer.
    private func send() {
        let message = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, asking == nil else { return }
        let who = runner
        let name = engine.runnerName(who)
        let before = Set(engine.automations.map(\.id))
        asking = who
        askError = nil
        toast = nil
        Task {
            defer { asking = nil }
            let ref: ContainerRef
            if who == "piopio" {
                guard let made = await engine.createThread() else {
                    askError = "Couldn't start a conversation with Piopio. Try again when the engine is connected."
                    return
                }
                ref = made
            } else {
                ref = ContainerRef(kind: .agent, id: who)
            }
            let thread = engine.thread(ref)
            await thread.open()
            guard await thread.send(message) else {
                askError = thread.error ?? "Couldn't send. What you wrote is still here."
                return
            }
            askText = ""
            showNew = false
            // Its answer: it sets one up, asks you something, or waits for your OK (two minutes at most).
            var started = false
            for tick in 0..<600 {
                try? await Task.sleep(for: .milliseconds(200))
                let status = thread.state?.status
                if status == .running { started = true; continue }
                if started || tick > 15 { break }
            }
            await engine.loadAutomations()
            try? await engine.refreshCatalog()
            let open: () -> Void = {
                if who == "piopio" { item = .chat(ref.id) } else { UserDefaults.standard.set("Chat", forKey: "agentTab"); item = .agent(who) }
            }
            if let made = engine.automations.first(where: { !before.contains($0.id) }) {
                let first = made.next.map { " · first run \(MainSidebar.when(AutomationText.date($0)))" } ?? ""
                show(AutomationToast(title: "\(name) set up “\(made.name)”", line: made.label + first, actions: [
                    .init(title: "Open") { item = .automation(made.id) },
                    .init(title: "Undo") { Task { try? await engine.removeAutomation(made.id) } },
                ]))
            } else if thread.state?.status == .waitingApproval {
                show(AutomationToast(title: "\(name) needs your OK to set it up", line: nil, actions: [.init(title: "Open conversation", action: open)]))
            } else {
                show(AutomationToast(title: "\(name) answered instead of setting it up", line: "It may need a detail from you.", actions: [.init(title: "Open conversation", action: open)]))
            }
        }
    }

    private func show(_ next: AutomationToast) {
        toast = next
        let id = next.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if toast?.id == id { toast = nil } }
    }
}

extension Notification.Name {
    /// Captures (DebugAutomation): "new", "draft" or "ask:<what to ask>" on the Automations list.
    static let automationsDemo = Notification.Name("piopio.automationsDemo")
}

/// New automation by hand: what the draft starts from (the list's filter, who you'd picked, what you'd typed).
struct AutomationDraft: Equatable {
    var preset: String?
    var runsAs: String
    var prompt: String
}

/// What just happened, at the foot of the list: a line, and what to do about it.
struct AutomationToast: Identifiable {
    struct Action { let title: String; let action: () -> Void }
    let id = UUID()
    let title: String
    let line: String?
    let actions: [Action]
}

struct AutomationToastView: View {
    let toast: AutomationToast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 13, weight: .medium))
                if let line = toast.line { Text(line).font(.system(size: 12)).opacity(0.65).lineLimit(1) }
            }
            ForEach(Array(toast.actions.enumerated()), id: \.offset) { _, a in
                Button { a.action(); dismiss() } label: {
                    Text(a.title).font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 11).frame(height: 28)
                        .background(Color.dsInvFg.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(Color.dsInvFg)
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
        .background(Color.dsInv, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .frame(maxWidth: 640)
    }
}

/// The list's columns (1.7fr 1fr 1fr 1.25fr 40, gap 16): name and when, runs as, tells you, last or next run, switch.
struct AutomationColumns: Layout {
    var fractions: [CGFloat] = [1.7, 1, 1, 1.25]
    var fixed: CGFloat = 40
    var spacing: CGFloat = 16

    private func widths(_ total: CGFloat) -> [CGFloat] {
        let flexible = max(0, total - fixed - spacing * CGFloat(fractions.count))
        let sum = fractions.reduce(0, +)
        return fractions.map { flexible * $0 / sum } + [fixed]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let w = widths(width)
        let height = zip(subviews, w).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        let w = widths(bounds.width)
        for (i, v) in subviews.enumerated() where i < w.count {
            let w = w[i]
            let h = v.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            let trailing = i == fractions.count
            v.place(at: CGPoint(x: trailing ? x + w : x, y: bounds.midY - h / 2), anchor: trailing ? .topTrailing : .topLeading, proposal: ProposedViewSize(width: w, height: h))
            x += w + spacing
        }
    }
}

/// A secondary button with a border (the handoff's New automation): white, a 1pt line, radius 8.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg)
            .padding(.horizontal, 14).frame(height: 32)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous).strokeBorder(Color.dsFg.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// "Runs on this Mac, only while it's awake" (AU9), with a green dot: said plainly, never as a warning.
struct RunsOnNote: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(nsColor: Self.green)).frame(width: 6, height: 6)
            Text("Runs on this Mac, only while it's awake").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
        }
        .help("Automations run in Piopio's engine on this Mac. A run missed while it sleeps happens when it wakes. The cloud comes later.")
    }

    /// The live dot (oklch 0.72 0.14 150).
    static let green = NSColor(srgbRed: 0.36, green: 0.73, blue: 0.45, alpha: 1)
}

/// One row: name (and New) over its when, who runs it, where it tells you, its last or next run (amber while it waits
/// for you), and its switch. A paused row is dimmed, its switch isn't; the switch doesn't open the row.
struct AutomationRow: View {
    let engine: EngineController
    let automation: Automation
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let a = automation
        let dim = a.enabled ? 1 : 0.45
        AutomationColumns {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(a.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                    if a.fresh == true {
                        Text("New").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous))
                    }
                }
                Text(a.label).font(.system(size: 13)).foregroundStyle(Color.dsFg2).lineLimit(1).truncationMode(.middle)
            }
            .opacity(dim)
            HStack(spacing: 8) {
                RunnerTile(engine: engine, runsAs: a.runsAs, size: 22)
                Text(a.runnerName).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
            }
            .opacity(dim)
            Text(a.resultLabel).font(.system(size: 13)).foregroundStyle(Color.dsFg2).lineLimit(1).opacity(dim)
            Text(AutomationText.status(a)).font(.system(size: 13))
                .foregroundStyle(a.lastStatus == "waiting" ? Color.dsWarn : a.lastStatus == "failed" && a.enabled ? Color.dsRed : Color.dsFg2)
                .lineLimit(1).opacity(dim)
            EnabledSwitch(engine: engine, automation: a)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(hovering ? Color.dsSide : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open", open)
    }
}

/// On or paused.
struct EnabledSwitch: View {
    let engine: EngineController
    let automation: Automation
    var size: ControlSize = .mini
    var body: some View {
        Toggle("", isOn: Binding(get: { automation.enabled }, set: { on in Task { try? await engine.updateAutomation(automation.id, AutomationChange(enabled: on)) } }))
            .toggleStyle(.switch).controlSize(size).labelsHidden()
            .help(automation.enabled ? "Pause \(automation.name)" : "Turn on \(automation.name)")
    }
}

@MainActor enum AutomationText {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ ms: Double) -> String { iso.string(from: Date(timeIntervalSince1970: ms / 1000)) }

    /// "Next tomorrow 9:00", "Last today 8:00 · nothing new", "Waiting for your OK", "Paused".
    static func status(_ a: Automation) -> String {
        if !a.enabled { return "Paused" }
        switch a.lastStatus {
        case "running": return "Running now"
        case "waiting": return a.lastRun.map { "\(MainSidebar.when($0).capitalizedFirst) · waiting for your OK" } ?? "Waiting for your OK"
        default: break
        }
        if let next = a.next { return "Next: \(MainSidebar.when(date(next)))" }
        if let last = a.lastRun { return "Last \(MainSidebar.when(last))\(a.lastStatus.map { " · \(word($0))" } ?? "")" }
        return a.on == "time" ? "Not scheduled" : "Waits for its event"
    }

    /// A run's outcome in a word or two.
    static func word(_ status: String) -> String {
        switch status {
        case "done": "done"
        case "quiet": "nothing new"
        case "failed": "failed"
        case "skipped": "skipped"
        case "waiting": "waiting for your OK"
        case "running": "running"
        default: status
        }
    }
}

// MARK: One automation

/// One automation (27 §4, the handoff's screen 5): its name and switch; the sentence, whose blue words change who runs
/// it, where and where the result goes (and whose time opens its trigger); what it's told; what it may do while you're
/// away; and its runs, in a column of their own.
struct AutomationPage: View {
    let engine: EngineController
    /// nil: a draft (New automation by hand), held here until Turn on.
    let id: String?
    @Binding var item: SidebarItem
    var draft: AutomationDraft? = nil
    /// Discard, or back, on a draft.
    var leaveDraft: () -> Void = {}
    /// The draft's record, as the engine will get it; and the draft as an automation, worded here.
    @State private var pending = AutomationChange()
    @State private var drafted: Automation?
    @State private var turningOn = false
    @State private var promptError: String?
    @FocusState private var promptFocused: Bool
    @State private var detail: AutomationDetail?
    @State private var missing = false
    @State private var name = ""
    @State private var prompt = ""
    @State private var trigger = TriggerChoice()
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var running = false
    /// The open choice under a word of the sentence.
    @State private var pop: Pop?
    /// The runner's definition, when an agent runs it: its tools and channels.
    @State private var runnerDef: AgentDef?
    @State private var otherBudget = false
    @State private var budgetText = ""

    enum Pop: String, Identifiable { case when, who, whereTo, result; var id: String { rawValue } }

    private var a: Automation? { id == nil ? drafted : detail?.automation }
    private var isDraft: Bool { id == nil }

    var body: some View {
        Group {
            if let a {
                HStack(spacing: 0) {
                    ScrollView {
                        content(a).padding(.horizontal, 52).padding(.top, 22).padding(.bottom, 40)
                            .frame(maxWidth: 860).frame(maxWidth: .infinity)
                    }
                    runs(a)
                        .frame(width: 300)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Color(nsColor: Self.runsFill))
                        .overlay(alignment: .leading) { Rectangle().fill(Color.dsLine).frame(width: 0.5) }
                }
            } else if missing {
                VStack(spacing: 10) {
                    Text("This automation is gone.").font(.system(size: 14, weight: .medium))
                    Button("All Automations") { item = .automations(nil) }.buttonStyle(PillStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.dsWin)
        .task(id: engine.automationsGeneration) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .automationsDemo)) { note in
            // Captures: "turn-on:<what it's told>" on a draft.
            guard isDraft, let what = note.object as? String, what.hasPrefix("turn-on:") else { return }
            prompt = String(what.dropFirst(8))
            turnOn()
        }
        .confirmationDialog("Delete “\(a?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                guard let id else { return }
                Task {
                    do {
                        try await engine.removeAutomation(id)
                        item = .automations(nil)
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("It stops running. Its runs stay in their conversations.")
        }
    }

    /// #F7F7F5 · #222221, the runs column and the card's footer strip.
    static let runsFill = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.133, green: 0.133, blue: 0.129, alpha: 1) : NSColor(srgbRed: 0.969, green: 0.969, blue: 0.961, alpha: 1)
    }

    private func load() async {
        guard let id else { await loadDraft(); return }
        guard let got = await engine.automation(id) else { missing = true; return }
        let first = detail == nil
        let before = detail?.automation
        detail = got
        // What you're typing stays; what changed elsewhere comes in.
        if first || name == before?.name { name = got.automation.name }
        if first || prompt == before?.prompt { prompt = got.automation.prompt }
        if first || before.map(TriggerChoice.init) == trigger { trigger = TriggerChoice(got.automation) }
        await loadRunner(got.automation.runsAs)
    }

    private func loadRunner(_ runsAs: String) async {
        if let agent = engine.agents.first(where: { $0.ref.id == runsAs }), let def = await engine.agentDefinition(agent.ref) {
            runnerDef = AgentDef(def.definition)
        } else {
            runnerDef = nil
        }
    }

    @ViewBuilder private func content(_ a: Automation) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { if isDraft { leaveDraft() } else { item = .automations(nil) } } label: {
                        HStack(spacing: 3) { Image(systemName: "chevron.left").font(.system(size: 10.5, weight: .semibold)); Text("Automations") }
                            .font(.system(size: 13)).foregroundStyle(Color.dsFg2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if isDraft {
                        Button("Discard", action: leaveDraft).buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                        Button(turningOn ? "Turning on…" : "Turn on") { turnOn() }.buttonStyle(PillStyle(kind: .primary)).disabled(turningOn)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("Save it and turn it on (⌘↩)")
                    } else {
                        Button(running ? "Running…" : "Run now") { run() }.buttonStyle(PillStyle(kind: .primary)).disabled(running)
                            .help("Run it once now, even while it's paused")
                    }
                }
                HStack(spacing: 12) {
                    TextField("", text: $name, prompt: Text(isDraft ? "New automation" : "Name").foregroundStyle(Color.dsFg3))
                        .textFieldStyle(.plain).font(.system(size: 28, weight: .bold)).tracking(-0.6)
                        .opacity(a.enabled || isDraft ? 1 : 0.5)
                        .onSubmit { if !isDraft { save(AutomationChange(name: name)) } }
                    Spacer()
                    if !isDraft {
                        Text(a.enabled ? "On" : "Paused").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                        EnabledSwitch(engine: engine, automation: a, size: .regular)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                sentence(a)
                Text(isDraft ? "Blue words are choices. Click the time to change when, and say below what it should do."
                             : "Blue words are choices. Click the time to change when; to change what it does, edit the prompt below or ask \(a.isPiopio ? "Piopio" : engine.runnerName(a.runsAs)).")
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                if let url = a.url {
                    HStack(spacing: 8) {
                        Text("Its address").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                        Text(url).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg2).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    }
                    .help("Other apps call this address with a POST; what they send comes with the run.")
                }
                if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Color.dsRed).fixedSize(horizontal: false, vertical: true) }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("What it's told").font(.system(size: 13, weight: .semibold))
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $prompt)
                        .font(.system(size: 13)).lineSpacing(2).scrollContentBackground(.hidden)
                        .frame(minHeight: isDraft ? 96 : 70)
                        .padding(.horizontal, 9).padding(.vertical, 8)
                        .focused($promptFocused)
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text("Summarise what competitors shipped last week, with links.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                                    .padding(.horizontal, 14).padding(.vertical, 8).allowsHitTesting(false)
                            }
                        }
                        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(promptFocused && isDraft ? Color.accentColor : Color.dsLine, lineWidth: promptFocused && isDraft ? 1.5 : 1))
                        .onChange(of: prompt) { promptError = nil }
                    if let promptError {
                        Text(promptError).font(.system(size: 12.5)).foregroundStyle(Color.dsRed).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !isDraft, prompt != a.prompt {
                        HStack {
                            Button("Cancel") { prompt = a.prompt }.buttonStyle(PillStyle(compact: true))
                            Button("Save") { save(AutomationChange(prompt: prompt)) }.buttonStyle(PillStyle(kind: .strong, compact: true))
                                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            away(a)
            if !isDraft {
                Button("Delete automation") { confirmDelete = true }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.dsRed)
            }
        }
    }

    // MARK: The sentence

    // "Every Monday at 09:00, ask Rita to summarise …, without a project, and tell me on Telegram." (27 §3): when and
    // what in bold; who, where and the result in blue, each opening its choices under it.
    private func sentence(_ a: Automation) -> some View {
        let piopio = a.isPiopio
        let runner = piopio ? "Piopio" : engine.runnerName(a.runsAs)
        let project = a.project.flatMap { p in engine.projects.first { $0.id == p }?.name }
        let told = Self.gist(isDraft ? prompt : a.prompt)
        let words = told.isEmpty ? ["…"] : Self.lowerFirst(told).split(separator: " ").map(String.init)
        return Flow(spacing: 6, lineSpacing: 8) {
            HStack(spacing: 0) {
                choice(.when, a.label, bold: true) { triggerChoices(a) }
                glue(",")
            }
            glue("ask")
            choice(.who, runner) { whoChoices(a) }
            glue("to")
            // What it does, word by word so it wraps; the comma rides on the last word.
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                Text(i == words.count - 1 ? "\(w)," : w).font(.system(size: 23, weight: told.isEmpty ? .regular : .semibold)).tracking(-0.2).foregroundStyle(told.isEmpty ? Color.dsFg3 : Color.dsFg)
            }
            HStack(spacing: 0) {
                choice(.whereTo, project.map { "in \($0)" } ?? "without a project", grey: !piopio) { whereChoices(a, runner: runner) }
                glue(",")
            }
            glue("and")
            HStack(spacing: 0) {
                choice(.result, resultWords(a, runner: runner)) { resultChoices(a, runner: runner) }
                glue(".")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.dsLine))
    }

    /// A word that opens its choices: blue with a dotted underline (grey when there's nothing to choose, bold for the
    /// time), tinted while its popover is open. Clicking it again closes it.
    private func choice<Choices: View>(_ which: Pop, _ text: String, bold: Bool = false, grey: Bool = false, @ViewBuilder choices: @escaping () -> Choices) -> some View {
        let open = pop == which
        let color: Color = bold ? .dsFg : grey ? .dsFg3 : .accentColor
        return Button { pop = open ? nil : which } label: {
            Text(text)
                .font(.system(size: 23, weight: bold ? .semibold : .regular)).tracking(-0.2)
                .foregroundStyle(color)
                .underline(true, pattern: .dot, color: bold ? Color.dsFg3.opacity(0.7) : color.opacity(0.5))
                .padding(.horizontal, 2)
                .background(open ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { pop == which }, set: { if !$0, pop == which { pop = nil } }), arrowEdge: .bottom) {
            choices().padding(6).frame(width: which == .when ? 400 : 306)
        }
    }

    private func glue(_ text: String) -> some View {
        Text(text).font(.system(size: 23)).tracking(-0.2).foregroundStyle(Color.dsFg2)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
    }

    private func row(_ title: String, line: String? = nil, picked: Bool, disabled: Bool = false, @ViewBuilder leading: () -> some View = { EmptyView() }, action: @escaping () -> Void) -> some View {
        PopoverRow(picked: picked, disabled: disabled, action: { action(); pop = nil }) {
            HStack(spacing: 10) {
                leading()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(disabled ? Color.dsFg3 : Color.dsFg)
                    if let line, !line.isEmpty { Text(line).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(2) }
                }
            }
        }
    }

    @ViewBuilder private func whoChoices(_ a: Automation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("Who runs it")
            row("Piopio", line: "Works without a project, or in one", picked: a.isPiopio, leading: { Chick(size: 26) }) { changeRunner(a, to: "piopio") }
            ForEach(engine.agents.filter { $0.agent?.draft != true }, id: \.ref.id) { agent in
                row(agent.title, line: agent.agent?.description, picked: a.runsAs == agent.ref.id, leading: { AgentTile(id: agent.ref.id, name: agent.title, glyph: agent.agent?.avatar, size: 26) }) { changeRunner(a, to: agent.ref.id) }
            }
        }
    }

    @ViewBuilder private func whereChoices(_ a: Automation, runner: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if a.isPiopio {
                caption("Where it works")
                row("Without a project", line: "A conversation of its own", picked: a.project == nil) { save(AutomationChange(project: .clear)) }
                ForEach(engine.projects) { p in
                    row("In \(p.name)…", line: "With the project's files and permissions", picked: a.project == p.id) { save(AutomationChange(project: .set(p.id))) }
                }
            } else {
                // AU6: only Piopio works in a project.
                Text("Only Piopio works in a project. \(runner) always works without one. To use a project, have Piopio run this.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
        }
    }

    @ViewBuilder private func resultChoices(_ a: Automation, runner: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("Where the result goes")
            if a.isPiopio {
                let project = a.project.flatMap { p in engine.projects.first { $0.id == p }?.name }
                row(project.map { "Start a conversation in \($0)" } ?? "Start a conversation", line: "With what it did, in the sidebar", picked: a.result == "conversation") { save(AutomationChange(result: "conversation")) }
                row("Stay quiet unless it needs me", line: "Every run is still recorded", picked: a.result == "quiet") { save(AutomationChange(result: "quiet")) }
                Text("Piopio has no channels. To get results on Telegram, have one of your agents run this.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 6)
            } else {
                let telegram = runnerDef?.channels?["telegram"] != nil
                row("Post in \(runner)’s chat", line: "The usual place", picked: a.result == "chat") { save(AutomationChange(result: "chat")) }
                row("Tell me on Telegram", line: telegram ? "One of \(runner)’s channels" : "Connect Telegram in \(runner)’s Setup first", picked: a.result == "telegram", disabled: !telegram) { save(AutomationChange(result: "telegram")) }
                row("Stay quiet unless it needs me", line: "Every run is still recorded", picked: a.result == "quiet") { save(AutomationChange(result: "quiet")) }
            }
        }
    }

    /// The time or event, as the trigger editor (a time picker the handoff leaves for later; Piopio already had one).
    @ViewBuilder private func triggerChoices(_ a: Automation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption("When it runs")
            VStack(spacing: 0) { TriggerEditor(choice: $trigger) }
            HStack {
                Spacer()
                Button("Cancel") { trigger = TriggerChoice(a); pop = nil }.buttonStyle(PillStyle(compact: true))
                Button("Save") { save(trigger.change); pop = nil }.buttonStyle(PillStyle(kind: .strong, compact: true))
                    .disabled(!trigger.isComplete || trigger == TriggerChoice(a))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    private func resultWords(_ a: Automation, runner: String) -> String {
        switch a.result {
        case "quiet": "stay quiet unless it needs me"
        case "telegram": "tell me on Telegram"
        case "conversation": "start a conversation"
        default: "post in \(runner)’s chat"
        }
    }

    static func lowerFirst(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).lowercased() + s.dropFirst() }

    /// What it does, for the sentence: the prompt's first sentence (up to a colon or a full stop), at most 90 characters.
    static func gist(_ prompt: String) -> String {
        var s = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        for stop in [": ", ". "] {
            if let r = s.range(of: stop), s.distance(from: s.startIndex, to: r.lowerBound) >= 20 { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .:;,"))
        return s.count > 90 ? "\(s.prefix(89))…" : s
    }

    // MARK: While you're away

    private static let budgets: [Double] = [0.10, 0.25, 0.50, 1.00]

    @ViewBuilder private func away(_ a: Automation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("While you're away").font(.system(size: 13, weight: .semibold))
            awayRow("If it needs your OK") {
                HStack(alignment: .top, spacing: 10) {
                    approvalCard("Wait for me", "Shows in Home, under Waiting on you", picked: a.approval != "skip") { save(AutomationChange(approval: "wait")) }
                    approvalCard("Skip this run", "Tries again next time", picked: a.approval == "skip") { save(AutomationChange(approval: "skip")) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            awayRow("Budget per run") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(Self.budgets, id: \.self) { v in
                            budgetChip(String(format: "$%.2f", v), picked: a.budgetPerRunUsd.map { abs($0 - v) < 0.001 } ?? false) { save(AutomationChange(budgetPerRunUsd: .set(v))) }
                        }
                        let custom = a.budgetPerRunUsd.flatMap { v in Self.budgets.contains { abs($0 - v) < 0.001 } ? nil : v }
                        if otherBudget {
                            TextField("0.75", text: $budgetText).textFieldStyle(.roundedBorder).frame(width: 64).font(.system(size: 12.5))
                                .onSubmit {
                                    if let v = Double(budgetText.replacingOccurrences(of: "$", with: "")), v > 0 { save(AutomationChange(budgetPerRunUsd: .set(v))) }
                                    otherBudget = false
                                }
                        } else {
                            budgetChip(custom.map { String(format: "$%.2f", $0) } ?? "Other…", picked: custom != nil) { budgetText = custom.map { String(format: "%.2f", $0) } ?? ""; otherBudget = true }
                        }
                    }
                    Text(a.budgetPerRunUsd == nil ? "No budget per run: the runner's own limits apply." : "It stops and tells you before going over.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
            }
            awayRow("It may use") {
                VStack(alignment: .leading, spacing: 4) {
                    mayUse(a)
                }
            }
            awayRow("Runs on") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("This Mac, only while it's awake.").font(.system(size: 13)).foregroundStyle(Color.dsFg)
                    Text("If your Mac is asleep at run time, it runs as soon as it wakes.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
            }
        }
    }

    private func awayRow<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label).font(.system(size: 13)).foregroundStyle(Color.dsFg2).frame(width: 160, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func approvalCard(_ title: String, _ line: String, picked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
                Text(line).font(.system(size: 12)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: 220, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(picked ? Color.accentColor : Color.dsFg.opacity(0.12), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxHeight: .infinity)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func budgetChip(_ title: String, picked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(picked ? Color.dsInvFg : Color.dsFg)
                .padding(.horizontal, 11).frame(height: 26)
                .background(Capsule().fill(picked ? Color.dsInv : Color.dsChip))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The runner's tools, and where they're set: the agent's Setup, or the project's settings.
    @ViewBuilder private func mayUse(_ a: Automation) -> some View {
        if let agent = engine.agents.first(where: { $0.ref.id == a.runsAs }) {
            (Text(Self.toolWords(runnerDef).map { "\(agent.title)'s tools: \($0). " } ?? "\(agent.title)'s tools. ") + Text("\(agent.title)'s Setup ›").foregroundStyle(Color.accentColor))
                .font(.system(size: 13)).foregroundStyle(Color.dsFg)
                .onTapGesture {
                    UserDefaults.standard.set("Setup", forKey: "agentTab")
                    item = .agent(agent.ref.id)
                }
                .help("Open \(agent.title)'s Setup")
            Text("Never more than \(agent.title) already has.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        } else if let p = a.project.flatMap({ p in engine.projects.first { $0.id == p } }) {
            (Text("What \(p.name) allows. ") + Text("Project settings ›").foregroundStyle(Color.accentColor))
                .font(.system(size: 13)).foregroundStyle(Color.dsFg)
                .onTapGesture { NotificationCenter.default.post(name: .projectSettings, object: p.id) }
            Text("Never more than the project's permissions.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        } else {
            Text("What Piopio can do in a new conversation.").font(.system(size: 13)).foregroundStyle(Color.dsFg)
            Text("It can't see your files without a project.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        }
    }

    /// "web search, read web pages, memory, messages, Calendar".
    static func toolWords(_ def: AgentDef?) -> String? {
        guard let def else { return nil }
        let names: [String: String] = ["web_search": "web search", "web_fetch": "read web pages", "memory": "memory", "send_message": "messages"]
        let words = def.tools.builtin.compactMap { names[$0] } + (def.tools.apple ?? []).map(\.capitalized)
        return words.isEmpty ? "talking only" : words.joined(separator: ", ")
    }

    // MARK: Runs

    private func runs(_ a: Automation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Runs").font(.system(size: 13, weight: .semibold)).padding(.bottom, 2)
                let list = isDraft ? [] : detail?.runs ?? []
                if isDraft {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Not on yet.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                        Text(a.next.map { "First run would be \(Self.firstRun($0))" } ?? (a.on == "time" ? "Not scheduled" : "It starts \(Self.lowerFirst(a.label))"))
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsFg.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else if list.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No runs yet.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                        if let next = a.next {
                            Text("First run: \(Self.firstRun(next))").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.dsFg)
                        } else {
                            Text(a.on == "time" ? "Not scheduled" : "When its event happens").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsFg.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                ForEach(list) { run in runCard(run) }
            }
            .padding(.horizontal, 16).padding(.top, 28).padding(.bottom, 20)
        }
    }

    private func runCard(_ run: AutomationRun) -> some View {
        let tone: Color = run.status == "waiting" ? .dsWarn : run.status == "running" ? .accentColor : run.status == "failed" ? .dsRed : .dsFg
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.status == "running" ? "\(Self.runWhen(run.firedAt)) · Running…" : Self.runWhen(run.firedAt))
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(tone)
                Spacer()
                if let cost = run.costUsd, cost > 0 {
                    Text(cost < 0.01 ? String(format: "$%.3f", cost) : String(format: "$%.2f", cost)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.dsFg3)
                }
            }
            let what = [run.status == "running" ? nil : AutomationText.word(run.status).capitalizedFirst, run.summary.map { String($0.prefix(140)) }].compactMap { $0 }.joined(separator: " · ")
            if !what.isEmpty { Text(what).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
            if run.conversation != nil {
                Button("Open conversation ›") { open(run) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsLine))
    }

    /// "Just now", "Today 08:00", "Mon 16 Nov, 09:30".
    static func runWhen(_ iso: String) -> String {
        guard let d = ISODate.parse(iso) else { return iso }
        if Date().timeIntervalSince(d) < 90 { return "Just now" }
        let time = d.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(d) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday \(time)" }
        return "\(d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(time)"
    }

    /// "Mon 23 Nov, 09:00".
    static func firstRun(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        return "\(d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(d.formatted(date: .omitted, time: .shortened))"
    }

    /// A run's conversation: Piopio's opens in the sidebar; an agent's in its page.
    private func open(_ run: AutomationRun) {
        guard let conversation = run.conversation else { return }
        if let agent = run.agent {
            item = .agent(agent)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NotificationCenter.default.post(name: .openAgentRun, object: conversation) }
        } else if let target = engine.item(for: conversation) {
            item = target
        }
    }

    private func changeRunner(_ a: Automation, to runner: String) {
        guard runner != a.runsAs else { return }
        // An agent never works in a project (AU6); Piopio has no channels (AU7).
        save(runner == "piopio" ? AutomationChange(runsAs: runner, result: a.result == "quiet" ? "quiet" : "conversation")
                                : AutomationChange(runsAs: runner, project: .clear, result: a.result == "quiet" ? "quiet" : "chat"))
    }

    private func save(_ change: AutomationChange) {
        guard let id else {
            pending.merge(change)
            drafted = draftAutomation()
            if change.runsAs != nil { Task { await loadRunner(pending.runsAs ?? "piopio") } }
            return
        }
        Task {
            do {
                error = nil
                _ = try await engine.updateAutomation(id, change)
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: The draft

    /// A new one starts every day at 09:00, run by who you'd picked (or the agent the list showed), without a project
    /// unless the list showed one, telling you the usual way, with the usual budget.
    private func loadDraft() async {
        if drafted == nil {
            let start = draft ?? AutomationDraft(runsAs: "piopio", prompt: "")
            let project = start.preset.flatMap { p in engine.projects.first { $0.id == p }?.id }
            let runsAs = project == nil && engine.agents.contains(where: { $0.ref.id == start.preset }) ? start.preset! : project == nil ? start.runsAs : "piopio"
            let agent = runsAs != "piopio"
            pending = AutomationChange(on: "time", when: "0 9 * * *", runsAs: runsAs, project: project.map { .set($0) }, result: agent ? "chat" : "conversation",
                                       approval: "wait", budgetPerRunUsd: .set(agent ? 0.25 : 0.50))
            prompt = start.prompt
            drafted = draftAutomation()
            if let drafted { trigger = TriggerChoice(drafted) }
            promptFocused = true
        } else {
            drafted = draftAutomation()
        }
        await loadRunner(pending.runsAs ?? "piopio")
    }

    /// The draft as the page shows it, in the engine's words (packages/engine/src/automations/model.ts).
    private func draftAutomation() -> Automation {
        let c = pending
        let runsAs = c.runsAs ?? "piopio"
        let on = c.on ?? "time"
        let project: String? = if case .set(let p)? = c.project { p } else { nil }
        let budget: Double? = if case .set(let b)? = c.budgetPerRunUsd { b } else { nil }
        let when = c.when ?? ""
        let cron = on == "time" && when.split(separator: " ").count == 5 ? when : nil
        let at = on == "time" && cron == nil ? AutomationWords.localDate(when).map { $0.timeIntervalSince1970 * 1000 } : nil
        let next = on == "time" ? AutomationWords.next(cron: cron, at: at).map { $0.timeIntervalSince1970 * 1000 } : nil
        let runnerName = engine.runnerName(runsAs)
        let projectName = project.flatMap { p in engine.projects.first { $0.id == p }?.name }
        return Automation(id: "draft", name: name, on: on, runsAs: runsAs, prompt: prompt, result: c.result ?? "conversation", approval: c.approval ?? "wait",
                          cron: cron, at: at, folder: c.folder, from: c.from, subject: c.subject, project: project, budgetPerRunUsd: budget, next: next,
                          label: AutomationWords.when(on: on, cron: cron, at: at, folder: c.folder, from: c.from, subject: c.subject),
                          runnerName: runnerName,
                          resultLabel: AutomationWords.result(c.result ?? "conversation", piopio: runsAs == "piopio", runner: runnerName, project: projectName))
    }

    /// Turn on: the engine gets it (named after its first words unless you named it) and its page opens.
    private func turnOn() {
        let told = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !told.isEmpty else {
            promptError = "Say what it should do. That's the one thing it needs."
            promptFocused = true
            return
        }
        var change = pending
        change.prompt = told
        change.enabled = true
        let named = name.trimmingCharacters(in: .whitespacesAndNewlines)
        change.name = named.isEmpty ? nil : named
        if case .clear? = change.project { change.project = nil }
        if case .clear? = change.budgetPerRunUsd { change.budgetPerRunUsd = nil }
        turningOn = true
        Task {
            defer { turningOn = false }
            do {
                error = nil
                let made = try await engine.addAutomation(change)
                item = .automation(made.id)
            } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    private func run() {
        guard let id else { return }
        running = true
        Task {
            defer { running = false }
            do { _ = try await engine.runAutomation(id) } catch { self.error = error.localizedDescription }
        }
    }
}

/// A choice in a sentence word's popover: hover grey, a blue ✓ on the current one; clicking picks and closes.
private struct PopoverRow<Content: View>: View {
    let picked: Bool
    var disabled = false
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content
                Spacer(minLength: 6)
                if picked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hovering && !disabled ? Color.dsSide : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}

/// Lays its views out left to right, wrapping to the next line (the sentence's words and menus).
struct Flow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

// MARK: When

/// What starts it, as the app edits it: a time (every day, weekdays, a weekday, once), an email, a file in a folder,
/// or a URL. A schedule the app can't show this way ("custom") keeps its cron until you choose another.
struct TriggerChoice: Equatable {
    enum Kind: String, CaseIterable { case time, email, folder, webhook }
    enum Repeat: Hashable { case daily, weekdays, weekday(Int), once, custom(String) }
    var kind: Kind = .time
    var repeats: Repeat = .daily
    var time: Date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    var day: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    var from = ""
    var subject = ""
    var folder = ""

    init() {}

    /// The same trigger: the time of day counts, and the day only for a once.
    static func == (l: TriggerChoice, r: TriggerChoice) -> Bool {
        let cal = Calendar.current
        let hm = { (d: Date) in cal.dateComponents([.hour, .minute], from: d) }
        let ymd = { (d: Date) in cal.dateComponents([.year, .month, .day], from: d) }
        guard l.kind == r.kind else { return false }
        switch l.kind {
        case .time: return l.repeats == r.repeats && hm(l.time) == hm(r.time) && (l.repeats != .once || ymd(l.day) == ymd(r.day))
        case .email: return l.from == r.from && l.subject == r.subject
        case .folder: return l.folder == r.folder
        case .webhook: return true
        }
    }

    init(_ a: Automation) {
        kind = Kind(rawValue: a.on) ?? .time
        from = a.from ?? ""
        subject = a.subject ?? ""
        folder = a.folder ?? ""
        if let at = a.at {
            repeats = .once
            let d = Date(timeIntervalSince1970: at / 1000)
            day = d
            time = d
        } else if let cron = a.cron {
            let f = cron.split(separator: " ").map(String.init)
            if f.count == 5, let m = Int(f[0]), let h = Int(f[1]), f[2] == "*", f[3] == "*" {
                time = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? time
                if f[4] == "*" { repeats = .daily }
                else if f[4] == "1-5" { repeats = .weekdays }
                else if let d = Int(f[4]), (0...7).contains(d) { repeats = .weekday(d % 7) }
                else { repeats = .custom(cron) }
            } else {
                repeats = .custom(cron)
            }
        }
    }

    var isComplete: Bool {
        switch kind {
        case .time: true
        case .email: !from.trimmingCharacters(in: .whitespaces).isEmpty || !subject.trimmingCharacters(in: .whitespaces).isEmpty
        case .folder: !folder.isEmpty
        case .webhook: true
        }
    }

    /// The engine's words: `when` as a cron or a local date-time.
    var change: AutomationChange {
        switch kind {
        case .time:
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            let (h, m) = (c.hour ?? 9, c.minute ?? 0)
            let when: String = switch repeats {
            case .daily: "\(m) \(h) * * *"
            case .weekdays: "\(m) \(h) * * 1-5"
            case .weekday(let d): "\(m) \(h) * * \(d)"
            case .custom(let cron): cron
            case .once: {
                let d = Calendar.current.dateComponents([.year, .month, .day], from: day)
                return String(format: "%04d-%02d-%02dT%02d:%02d", d.year ?? 2026, d.month ?? 1, d.day ?? 1, h, m)
            }()
            }
            return AutomationChange(on: "time", when: when)
        case .email: return AutomationChange(on: "email", from: from, subject: subject)
        case .folder: return AutomationChange(on: "folder", folder: folder)
        case .webhook: return AutomationChange(on: "webhook")
        }
    }
}

/// Rows that edit a `TriggerChoice` (in a SetupGroup).
struct TriggerEditor: View {
    @Binding var choice: TriggerChoice
    private static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        SetupRow("Starts") {
            Picker("", selection: $choice.kind) {
                Text("At a time").tag(TriggerChoice.Kind.time)
                Text("An email").tag(TriggerChoice.Kind.email)
                Text("A file").tag(TriggerChoice.Kind.folder)
                Text("A URL").tag(TriggerChoice.Kind.webhook)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        switch choice.kind {
        case .time:
            SetupRow("Repeats") {
                Picker("", selection: $choice.repeats) {
                    Text("Every day").tag(TriggerChoice.Repeat.daily)
                    Text("Every weekday").tag(TriggerChoice.Repeat.weekdays)
                    ForEach(0..<7, id: \.self) { d in Text("Every \(Self.days[(d + 1) % 7])").tag(TriggerChoice.Repeat.weekday((d + 1) % 7)) }
                    Text("Once").tag(TriggerChoice.Repeat.once)
                    if case .custom(let cron) = choice.repeats { Text("Custom (\(cron))").tag(choice.repeats) }
                }
                .labelsHidden().fixedSize()
            }
            SetupRow(choice.repeats == .once ? "On" : "At") {
                if choice.repeats == .once {
                    DatePicker("", selection: $choice.day, in: Date()..., displayedComponents: .date).labelsHidden()
                }
                DatePicker("", selection: $choice.time, displayedComponents: .hourAndMinute).labelsHidden()
            }
        case .email:
            SetupRow("From", subtitle: "Part of the sender's name or address") {
                TextField("the bank", text: $choice.from).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            SetupRow("About", subtitle: "Words in the subject") {
                TextField("invoice", text: $choice.subject).textFieldStyle(.roundedBorder).frame(width: 220)
            }
        case .folder:
            SetupRow("In", subtitle: "A file appears or changes there (not in its subfolders)") {
                Text(choice.folder.isEmpty ? "No folder" : (choice.folder as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(1).truncationMode(.middle)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { choice.folder = url.path }
                }
                .buttonStyle(PillStyle(compact: true))
            }
        case .webhook:
            SetupRow("Its address", subtitle: "It gets one when it's saved; other apps call it") { EmptyView() }
        }
    }
}

// MARK: The draft's words

extension AutomationChange {
    /// A change on top of the draft's record: a new trigger replaces the old one whole.
    mutating func merge(_ c: AutomationChange) {
        if c.on != nil { on = c.on; when = c.when; folder = c.folder; from = c.from; subject = c.subject }
        if let v = c.name { name = v }
        if let v = c.runsAs { runsAs = v }
        if let v = c.prompt { prompt = v }
        if let v = c.result { result = v }
        if let v = c.approval { approval = v }
        if let v = c.project { project = v }
        if let v = c.budgetPerRunUsd { budgetPerRunUsd = v }
        if let v = c.enabled { enabled = v }
    }
}

/// The engine's words for an automation it doesn't have yet (whenLabel, resultLabel and nextOf in
/// packages/engine/src/automations/model.ts), for the schedules the app's trigger editor makes.
enum AutomationWords {
    private static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func when(on: String, cron: String?, at: Double?, folder: String?, from: String?, subject: String?) -> String {
        switch on {
        case "folder": return "When a file appears or changes in \(folder ?? "a folder")"
        case "email":
            let who = from.flatMap { $0.isEmpty ? nil : " from \($0)" } ?? ""
            let about = subject.flatMap { $0.isEmpty ? nil : " about “\($0)”" } ?? ""
            return "When an email\(who)\(about) arrives"
        case "webhook": return "When its URL is called"
        default: break
        }
        if let at {
            let d = Date(timeIntervalSince1970: at / 1000)
            let sameYear = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
            let day = d.formatted(sameYear ? .dateTime.weekday(.abbreviated).day().month(.abbreviated) : .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
            return "Once, \(day), \(hm(d))"
        }
        guard let cron else { return "At a time" }
        let f = cron.split(separator: " ").map(String.init)
        guard f.count == 5, let m = Int(f[0]), let h = Int(f[1]), f[2] == "*", f[3] == "*" else { return "On the schedule “\(cron)”" }
        let at = String(format: "%02d:%02d", h, m)
        switch f[4] {
        case "*": return "Every day at \(at)"
        case "1-5": return "Every weekday at \(at)"
        case "0,6", "6,0": return "Every weekend day at \(at)"
        default: return Int(f[4]).map { "Every \(days[$0 % 7]) at \(at)" } ?? "On the schedule “\(cron)”"
        }
    }

    static func result(_ result: String, piopio: Bool, runner: String, project: String?) -> String {
        switch result {
        case "quiet": "Only if it needs you"
        case "telegram": "Telegram"
        default: piopio ? project.map { "A conversation in \($0)" } ?? "A new conversation" : "\(runner)’s chat"
        }
    }

    /// The next time it would run, from now.
    static func next(cron: String?, at: Double?) -> Date? {
        if let at { let d = Date(timeIntervalSince1970: at / 1000); return d > Date() ? d : nil }
        guard let cron else { return nil }
        let f = cron.split(separator: " ").map(String.init)
        guard f.count == 5, let m = Int(f[0]), let h = Int(f[1]), f[2] == "*", f[3] == "*" else { return nil }
        let cal = Calendar.current
        let now = Date()
        for offset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now),
                  let d = cal.date(bySettingHour: h, minute: m, second: 0, of: day), d > now else { continue }
            let wd = cal.component(.weekday, from: d) - 1
            let fits = switch f[4] {
            case "*": true
            case "1-5": (1...5).contains(wd)
            case "0,6", "6,0": wd == 0 || wd == 6
            default: Int(f[4]).map { $0 % 7 == wd } ?? false
            }
            if fits { return d }
        }
        return nil
    }

    /// "2026-11-23T09:00", local.
    static func localDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: text)
    }

    private static func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
