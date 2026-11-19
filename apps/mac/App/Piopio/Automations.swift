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
struct AutomationsPage: View {
    let engine: EngineController
    /// "piopio", an agent's id or a project's id: only those.
    let filter: String?
    @Binding var item: SidebarItem
    @State private var making = false

    private var shown: [Automation] {
        guard let filter else { return engine.automations }
        return engine.automations.filter { $0.runsAs == filter || $0.project == filter }
    }

    private var project: ProjectInfo? { filter.flatMap { f in engine.projects.first { $0.id == f } } }

    /// All, Piopio, then each agent that runs one (and the one filtered on, even with none).
    private var runners: [String] {
        var ids = Set(engine.automations.map(\.runsAs)).subtracting(["piopio"])
        if let filter, project == nil, filter != "piopio" { ids.insert(filter) }
        return ["piopio"] + ids.sorted { engine.runnerName($0) < engine.runnerName($1) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Automations").font(.system(size: 28, weight: .bold)).tracking(-0.6).foregroundStyle(Color.dsFg)
                        Text("Work that runs when nobody started it. Ask Piopio or any agent to set one up, or make one here.")
                            .font(.system(size: 14)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("New automation") { making = true }.buttonStyle(OutlineButtonStyle())
                }
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
            .padding(.vertical, 44)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(Color.dsWin)
        .sheet(isPresented: $making) {
            AutomationEditor(engine: engine, preset: filter) { made in item = .automation(made.id) }
        }
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

    /// Nothing yet: what to ask, in two examples (the handoff's empty state).
    private var empty: some View {
        VStack(spacing: 12) {
            Text(filter == nil ? "Nothing runs on its own yet" : "Nothing here runs on its own yet").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.dsFg)
            Text("Ask Piopio or any of your agents in plain words. They set it up and it shows here.")
                .font(.system(size: 13.5)).foregroundStyle(Color.dsFg2).multilineTextAlignment(.center)
            VStack(spacing: 8) {
                example("“Every Monday at 9, send me what competitors shipped last week.”")
                example("“When an invoice arrives by email, file it and tell me the total.”")
            }
            .padding(.top, 6)
            (Text("Or use ") + Text("New automation").fontWeight(.semibold) + Text(" above."))
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).padding(.top, 4)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private func example(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Color.dsFg)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: DS.bubble), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .textSelection(.enabled)
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
    let id: String
    @Binding var item: SidebarItem
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

    private var a: Automation? { detail?.automation }

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
        .confirmationDialog("Delete “\(a?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
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
        guard let got = await engine.automation(id) else { missing = true; return }
        let first = detail == nil
        let before = detail?.automation
        detail = got
        // What you're typing stays; what changed elsewhere comes in.
        if first || name == before?.name { name = got.automation.name }
        if first || prompt == before?.prompt { prompt = got.automation.prompt }
        if first || before.map(TriggerChoice.init) == trigger { trigger = TriggerChoice(got.automation) }
        if let agent = engine.agents.first(where: { $0.ref.id == got.automation.runsAs }), let def = await engine.agentDefinition(agent.ref) {
            runnerDef = AgentDef(def.definition)
        } else {
            runnerDef = nil
        }
    }

    @ViewBuilder private func content(_ a: Automation) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { item = .automations(nil) } label: {
                        HStack(spacing: 3) { Image(systemName: "chevron.left").font(.system(size: 10.5, weight: .semibold)); Text("Automations") }
                            .font(.system(size: 13)).foregroundStyle(Color.dsFg2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(running ? "Running…" : "Run now") { run() }.buttonStyle(PillStyle(kind: .primary)).disabled(running)
                        .help("Run it once now, even while it's paused")
                }
                HStack(spacing: 12) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain).font(.system(size: 28, weight: .bold)).tracking(-0.6)
                        .opacity(a.enabled ? 1 : 0.5)
                        .onSubmit { save(AutomationChange(name: name)) }
                    Spacer()
                    Text(a.enabled ? "On" : "Paused").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                    EnabledSwitch(engine: engine, automation: a, size: .regular)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                sentence(a)
                Text("Blue words are choices. Click the time to change when; to change what it does, edit the prompt below or ask \(a.isPiopio ? "Piopio" : engine.runnerName(a.runsAs)).")
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
                        .frame(minHeight: 70)
                        .padding(.horizontal, 9).padding(.vertical, 8)
                        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine))
                    if prompt != a.prompt {
                        HStack {
                            Button("Cancel") { prompt = a.prompt }.buttonStyle(PillStyle(compact: true))
                            Button("Save") { save(AutomationChange(prompt: prompt)) }.buttonStyle(PillStyle(kind: .strong, compact: true))
                                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            away(a)
            Button("Delete automation") { confirmDelete = true }
                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.dsRed)
        }
    }

    // MARK: The sentence

    // "Every Monday at 09:00, ask Rita to summarise …, without a project, and tell me on Telegram." (27 §3): when and
    // what in bold; who, where and the result in blue, each opening its choices under it.
    private func sentence(_ a: Automation) -> some View {
        let piopio = a.isPiopio
        let runner = piopio ? "Piopio" : engine.runnerName(a.runsAs)
        let project = a.project.flatMap { p in engine.projects.first { $0.id == p }?.name }
        let words = Self.lowerFirst(Self.gist(a.prompt)).split(separator: " ").map(String.init)
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
                Text(i == words.count - 1 ? "\(w)," : w).font(.system(size: 23, weight: .semibold)).tracking(-0.2).foregroundStyle(Color.dsFg)
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
                let list = detail?.runs ?? []
                if list.isEmpty {
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
        Task {
            do {
                error = nil
                _ = try await engine.updateAutomation(id, change)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func run() {
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

// MARK: New automation

/// New Automation (27 §4): for when you'd rather not ask. Who runs it, when, what it's told, where it works and where
/// the result goes.
struct AutomationEditor: View {
    let engine: EngineController
    /// The list's filter: an agent's id, "piopio" or a project's id, to start from.
    var preset: String?
    let made: (Automation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var runsAs = "piopio"
    @State private var project: String?
    @State private var prompt = ""
    @State private var result = "conversation"
    @State private var trigger = TriggerChoice()
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Automation").font(.system(size: 18, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SetupGroup("Who runs it") {
                        SetupRow("Runs as") {
                            Picker("", selection: $runsAs) {
                                Text("Piopio").tag("piopio")
                                ForEach(engine.agents, id: \.ref.id) { Text($0.title).tag($0.ref.id) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        if runsAs == "piopio" {
                            SetupRow("Works in") {
                                Picker("", selection: $project) {
                                    Text("No project").tag(String?.none)
                                    ForEach(engine.projects) { Text($0.name).tag(String?.some($0.id)) }
                                }
                                .labelsHidden().fixedSize()
                            }
                        }
                        SetupRow("Tells you") {
                            Picker("", selection: $result) {
                                if runsAs == "piopio" {
                                    Text("In a new conversation").tag("conversation")
                                } else {
                                    Text("In \(engine.runnerName(runsAs))’s chat").tag("chat")
                                    Text("On Telegram").tag("telegram")
                                }
                                Text("Only if it needs me").tag("quiet")
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                    SetupGroup("When") { TriggerEditor(choice: $trigger) }
                    SetupGroup("What it's told") {
                        TextEditor(text: $prompt)
                            .font(.system(size: 13)).scrollContentBackground(.hidden)
                            .frame(minHeight: 90)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .overlay(alignment: .topLeading) {
                                if prompt.isEmpty {
                                    Text("Summarise what competitors shipped last week, with links.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                                        .padding(.horizontal, 15).padding(.vertical, 8).allowsHitTesting(false)
                                }
                            }
                    }
                    SetupGroup("Name", footer: "Optional: its first words otherwise.") {
                        TextField("Weekly competitor brief", text: $name).textFieldStyle(.plain).padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    RunsOnNote()
                }
            }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Color.dsRed).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(saving ? "Making…" : "Make It") { make() }.buttonStyle(PillStyle(kind: .strong)).keyboardShortcut(.defaultAction)
                    .disabled(saving || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !trigger.isComplete)
            }
        }
        .padding(24)
        .frame(width: 560, height: 640)
        .background(Color.dsWin)
        .onAppear {
            if let preset {
                if engine.projects.contains(where: { $0.id == preset }) { project = preset }
                else if engine.agents.contains(where: { $0.ref.id == preset }) { runsAs = preset; result = "chat" }
            }
        }
        .onChange(of: runsAs) { _, now in
            if now == "piopio" { if result != "quiet" { result = "conversation" } }
            else { project = nil; if result != "quiet" { result = "chat" } }
        }
    }

    private func make() {
        saving = true
        Task {
            defer { saving = false }
            var change = trigger.change
            change.runsAs = runsAs
            change.prompt = prompt
            change.result = result
            if let project, runsAs == "piopio" { change.project = .set(project) }
            if !name.trimmingCharacters(in: .whitespaces).isEmpty { change.name = name }
            do {
                let a = try await engine.addAutomation(change)
                dismiss()
                made(a)
            } catch { self.error = error.localizedDescription }
        }
    }
}
