import AppKit
import PiopioKit
import SwiftUI

// Automations (docs/spec/27 §4): work that starts when nobody started it. One list for Piopio and every agent; each
// one's page reads as a sentence ("Every Monday at 09:00, ask Rita to …, and tell me on Telegram"), with what it's
// told, what it may do while you're away, and its runs. You make them by asking; New Automation is for when you'd
// rather not.

/// The list: a line, a filter by who runs it, and one row per automation with a switch.
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

    /// All, Piopio, each agent that runs one, each project that has one.
    private var chips: [(id: String?, title: String)] {
        var out: [(id: String?, title: String)] = [(nil, "All")]
        if engine.automations.contains(where: \.isPiopio) { out.append(("piopio", "Piopio")) }
        let agents = Set(engine.automations.map(\.runsAs)).subtracting(["piopio"])
        for id in agents.sorted(by: { engine.runnerName($0) < engine.runnerName($1) }) { out.append((id, engine.runnerName(id))) }
        for p in engine.projects where engine.automations.contains(where: { $0.project == p.id }) { out.append((p.id, p.name)) }
        if let filter, !out.contains(where: { $0.id == filter }) { out.append((filter, engine.projects.first { $0.id == filter }?.name ?? engine.runnerName(filter))) }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automations").font(.system(size: 28, weight: .bold)).tracking(-0.6)
                        Text("Work that runs when nobody started it. Ask Piopio or any agent to set one up, or make one here.")
                            .font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                    }
                    Spacer()
                    Button("New Automation") { making = true }.buttonStyle(PillStyle(kind: .strong))
                }
                HStack(spacing: 6) {
                    ForEach(chips, id: \.id) { chip in
                        let on = chip.id == filter
                        Button(chip.title) { item = .automations(chip.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(on ? Color.dsInvFg : Color.dsFg2)
                            .padding(.horizontal, 11).frame(height: 26)
                            .background(Capsule().fill(on ? Color.dsInv : Color.clear))
                            .overlay(Capsule().strokeBorder(on ? Color.clear : Color.dsLine))
                    }
                    Spacer()
                    RunsOnNote()
                }
                .padding(.top, 20)
                if shown.isEmpty {
                    empty
                } else {
                    header.padding(.top, 14)
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, a in
                            if i > 0 { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
                            AutomationRow(engine: engine, automation: a) { item = .automation(a.id) }
                        }
                    }
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
                    Text("Home shows what's next and what ran while you were away.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 14)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(Color.dsWin)
        .sheet(isPresented: $making) {
            AutomationEditor(engine: engine, preset: filter) { made in item = .automation(made.id) }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Automation").frame(maxWidth: .infinity, alignment: .leading)
            Text("Runs as").frame(width: 170, alignment: .leading)
            Text("Tells you").frame(width: 150, alignment: .leading)
            Text("Last or next run").frame(width: 190, alignment: .leading)
            Text("On").frame(width: 36, alignment: .trailing)
        }
        .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
        .padding(.horizontal, 16).padding(.bottom, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(filter == nil ? "Nothing runs on its own yet." : "Nothing here runs on its own yet.").font(.system(size: 14, weight: .medium))
            Text("Ask Piopio or one of your agents, in words: “Every Monday at 9, send me what competitors shipped last week” or “When an invoice arrives, file it.” Or make one here.")
                .font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            Button("New Automation…") { making = true }.buttonStyle(PillStyle()).padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.dsLine))
        .padding(.top, 18)
    }
}

/// "Runs on This Mac, only while it's awake" (AU9), with its amber dot.
struct RunsOnNote: View {
    var long = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(Color.dsWarn).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(long ? "This Mac, only while it's awake. A run it misses happens when the Mac wakes." : "Runs on This Mac, only while it's awake")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
        }
        .help("Automations run in Piopio's engine on this Mac. The cloud comes later.")
    }
}

/// One row of the list: name and when, who runs it, where it tells you, its last or next run, and its switch.
struct AutomationRow: View {
    let engine: EngineController
    let automation: Automation
    let open: () -> Void

    var body: some View {
        let a = automation
        HStack(spacing: 14) {
            Button(action: open) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text(a.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.dsFg).lineLimit(1)
                            if a.fresh == true {
                                Text("New").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.dsAccentSoft, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        Text(a.label).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    RunnerLabel(engine: engine, automation: a).frame(width: 170, alignment: .leading)
                    Text(a.resultLabel).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(1).frame(width: 150, alignment: .leading)
                    Text(AutomationText.status(a)).font(.system(size: 12.5)).foregroundStyle(a.lastStatus == "failed" && a.enabled ? Color.dsRed : Color.dsFg2)
                        .lineLimit(1).frame(width: 190, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            EnabledSwitch(engine: engine, automation: a).frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 16).frame(height: 58)
        .opacity(a.enabled ? 1 : 0.6)
    }
}

/// On or paused.
struct EnabledSwitch: View {
    let engine: EngineController
    let automation: Automation
    var body: some View {
        Toggle("", isOn: Binding(get: { automation.enabled }, set: { on in Task { try? await engine.updateAutomation(automation.id, AutomationChange(enabled: on)) } }))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            .help(automation.enabled ? "Pause \(automation.name)" : "Turn on \(automation.name)")
    }
}

/// Who runs it: Piopio's chick or the agent's avatar, and "Piopio in shop" or the agent's name.
struct RunnerLabel: View {
    let engine: EngineController
    let automation: Automation
    var body: some View {
        HStack(spacing: 8) {
            if let agent = engine.agents.first(where: { $0.ref.id == automation.runsAs }) {
                AgentAvatar(summary: agent, size: 20)
            } else {
                Chick(size: 20)
            }
            Text(automation.runnerName).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).lineLimit(1)
        }
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
        case "waiting": return "Waiting for your OK"
        default: break
        }
        if let next = a.next { return "Next \(MainSidebar.when(date(next)))" }
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

/// One automation (27 §4): its name and switch; the sentence, whose blue words change who runs it, where and where
/// the result goes; when; what it's told; while you're away; and its runs.
struct AutomationPage: View {
    let engine: EngineController
    let id: String
    @Binding var item: SidebarItem
    @State private var detail: AutomationDetail?
    @State private var missing = false
    @State private var name = ""
    @State private var prompt = ""
    @State private var budget = ""
    @State private var trigger = TriggerChoice()
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var running = false

    private var a: Automation? { detail?.automation }

    var body: some View {
        Group {
            if let a {
                ScrollView { content(a).padding(.horizontal, 40).padding(.vertical, 28).frame(maxWidth: 1040).frame(maxWidth: .infinity) }
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

    private func load() async {
        guard let got = await engine.automation(id) else { missing = true; return }
        let first = detail == nil
        let before = detail?.automation
        detail = got
        // What you're typing stays; what changed elsewhere comes in.
        if first || name == before?.name { name = got.automation.name }
        if first || prompt == before?.prompt { prompt = got.automation.prompt }
        if first || budget == Self.money(before?.budgetPerRunUsd) { budget = Self.money(got.automation.budgetPerRunUsd) }
        if first || before.map(TriggerChoice.init) == trigger { trigger = TriggerChoice(got.automation) }
    }

    static func money(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }

    @ViewBuilder private func content(_ a: Automation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button { item = .automations(nil) } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)); Text("Automations") }
                }
                .buttonStyle(PillStyle(kind: .toolbar))
                Spacer()
                Button(running ? "Running…" : "Run Now") { run() }.buttonStyle(PillStyle()).disabled(running)
                    .help("Run it once now, even while it's paused")
            }
            HStack(spacing: 12) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 26, weight: .bold))
                    .onSubmit { save(AutomationChange(name: name)) }
                Spacer()
                Text(a.enabled ? "On" : "Paused").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                EnabledSwitch(engine: engine, automation: a)
            }
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 20) {
                    sentence(a)
                    if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Color.dsRed).fixedSize(horizontal: false, vertical: true) }
                    SetupGroup("When", footer: a.on == "webhook" ? "Other apps call its address with a POST; what they send comes with the run." : nil) {
                        TriggerEditor(choice: $trigger)
                        if trigger != TriggerChoice(a) {
                            HStack {
                                Spacer()
                                Button("Cancel") { trigger = TriggerChoice(a) }.buttonStyle(PillStyle(compact: true))
                                Button("Save") { saveTrigger() }.buttonStyle(PillStyle(kind: .strong, compact: true)).disabled(!trigger.isComplete)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        }
                        if let url = a.url {
                            SetupRow("Its address") {
                                Text(url).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg2).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }.buttonStyle(PillStyle(compact: true))
                            }
                        }
                    }
                    SetupGroup("What it's told") {
                        VStack(alignment: .trailing, spacing: 8) {
                            TextEditor(text: $prompt)
                                .font(.system(size: 13)).scrollContentBackground(.hidden)
                                .frame(minHeight: 90)
                            if prompt != a.prompt {
                                HStack {
                                    Button("Cancel") { prompt = a.prompt }.buttonStyle(PillStyle(compact: true))
                                    Button("Save") { save(AutomationChange(prompt: prompt)) }.buttonStyle(PillStyle(kind: .strong, compact: true))
                                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    away(a)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                runs(a).frame(width: 280)
            }
        }
    }

    // The sentence (27 §3): the blue words are menus.
    private func sentence(_ a: Automation) -> some View {
        let piopio = a.isPiopio
        let runner = piopio ? "Piopio" : engine.runnerName(a.runsAs)
        let project = a.project.flatMap { p in engine.projects.first { $0.id == p }?.name }
        let what = Self.gist(a.prompt)
        return VStack(alignment: .leading, spacing: 10) {
            Flow(spacing: 5, lineSpacing: 6) {
                HStack(spacing: 0) {
                    word(a.label, plain: true)
                    glue(",")
                }
                glue("ask")
                Menu {
                    Button("Piopio") { changeRunner(a, to: "piopio") }
                    if !engine.agents.isEmpty { Divider() }
                    ForEach(engine.agents, id: \.ref.id) { agent in Button(agent.title) { changeRunner(a, to: agent.ref.id) } }
                } label: { word(runner) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                glue("to")
                // What it does, word by word so it wraps; the comma rides on the last word.
                let words = lowerFirst(what).split(separator: " ").map(String.init)
                ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                    Text(i == words.count - 1 ? "\(w)," : w).font(.system(size: 19, weight: .medium)).foregroundStyle(Color.dsFg)
                }
                if piopio {
                    HStack(spacing: 0) {
                        Menu {
                            Button("Without a project") { save(AutomationChange(project: .clear)) }
                            if !engine.projects.isEmpty { Divider() }
                            ForEach(engine.projects) { p in Button("In \(p.name)") { save(AutomationChange(project: .set(p.id))) } }
                        } label: { word(project.map { "in \($0)" } ?? "without a project") }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        glue(",")
                    }
                } else {
                    HStack(spacing: 0) {
                        word("outside any project", plain: true).help("Only Piopio works in a project. Run it as Piopio there; its prompt can ask \(runner) with @\(runner).")
                        glue(",")
                    }
                }
                glue("and")
                HStack(spacing: 0) {
                    Menu {
                        if piopio {
                            Button("Start a conversation") { save(AutomationChange(result: "conversation")) }
                            Button("Tell me only if it needs me") { save(AutomationChange(result: "quiet")) }
                        } else {
                            Button("Post in \(runner)’s chat") { save(AutomationChange(result: "chat")) }
                            Button("Tell me on Telegram") { save(AutomationChange(result: "telegram")) }
                            Button("Tell me only if it needs me") { save(AutomationChange(result: "quiet")) }
                        }
                    } label: { word(resultWords(a, runner: runner)) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    glue(".")
                }
            }
            Text("The blue words change with a click. To change when it runs or what it does, edit it below or ask \(runner).")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.dsLine))
    }

    private func resultWords(_ a: Automation, runner: String) -> String {
        switch a.result {
        case "quiet": "tell me only if it needs me"
        case "telegram": "tell me on Telegram"
        case "conversation": "start a conversation"
        default: "post in \(runner)’s chat"
        }
    }

    private func word(_ text: String, plain: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(plain ? Color.dsFg : Color.accentColor)
            .underline(true, pattern: .dot, color: plain ? Color.dsFg3 : Color.accentColor)
            .contentShape(Rectangle())
    }

    private func glue(_ text: String) -> some View {
        Text(text).font(.system(size: 19)).foregroundStyle(Color.dsFg2)
    }

    private func lowerFirst(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).lowercased() + s.dropFirst() }

    /// What it does, for the sentence: the prompt's first sentence (up to a colon or a full stop), at most 90 characters.
    static func gist(_ prompt: String) -> String {
        var s = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        for stop in [": ", ". "] {
            if let r = s.range(of: stop), s.distance(from: s.startIndex, to: r.lowerBound) >= 20 { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .:;,"))
        return s.count > 90 ? "\(s.prefix(89))…" : s
    }

    @ViewBuilder private func away(_ a: Automation) -> some View {
        SetupGroup("While you're away") {
            SetupRow("If it needs your OK") {
                Picker("", selection: Binding(get: { a.approval }, set: { save(AutomationChange(approval: $0)) })) {
                    Text("Wait in Waiting on you").tag("wait")
                    Text("Skip this run").tag("skip")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SetupRow("Budget per run", subtitle: "It stops and tells you before it goes over.") {
                HStack(spacing: 4) {
                    Text("$").foregroundStyle(Color.dsFg2)
                    TextField("0.25", text: $budget)
                        .textFieldStyle(.roundedBorder).frame(width: 64)
                        .onSubmit { if let v = Double(budget), v > 0 { save(AutomationChange(budgetPerRunUsd: .set(v))) } }
                }
            }
            SetupRow("It may use") {
                if let agent = engine.agents.first(where: { $0.ref.id == a.runsAs }) {
                    Button("\(agent.title)’s tools and data ›") { item = .agent(agent.ref.id) }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 12.5))
                } else if let p = a.project.flatMap({ p in engine.projects.first { $0.id == p } }) {
                    Text("Piopio in \(p.name), with the project’s permissions").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                } else {
                    Text("What Piopio can do in a new conversation").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                }
            }
            SetupRow("Runs on") { RunsOnNote(long: true).frame(maxWidth: 300, alignment: .trailing) }
        }
    }

    private func runs(_ a: Automation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runs").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                let list = detail?.runs ?? []
                if list.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No runs yet").font(.system(size: 12.5))
                        Text(a.next.map { "First run \(MainSidebar.when(AutomationText.date($0)))" } ?? (a.on == "time" ? "Not scheduled" : "When its event happens"))
                            .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, run in
                    if i > 0 { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
                    Button { open(run) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MainSidebar.when(run.firedAt).capitalizedFirst).font(.system(size: 12.5)).foregroundStyle(Color.dsFg)
                            Text([AutomationText.word(run.status).capitalizedFirst, run.summary.map { String($0.prefix(80)) }, run.costUsd.flatMap { $0 > 0 ? String(format: "$%.3f", $0) : nil }].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(run.status == "failed" ? Color.dsRed : Color.dsFg2).lineLimit(2)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(run.conversation == nil)
                    .help(run.conversation == nil ? "" : "Open what it did")
                }
            }
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.dsLine))
            Text("Each result goes where the sentence says. A run that needs your OK waits in Home, or is skipped, as set.")
                .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            Button("Delete Automation…") { confirmDelete = true }.buttonStyle(.plain).foregroundStyle(Color.dsRed).font(.system(size: 12.5)).padding(.top, 6)
        }
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

    private func saveTrigger() {
        save(trigger.change)
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
                    RunsOnNote(long: true)
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
