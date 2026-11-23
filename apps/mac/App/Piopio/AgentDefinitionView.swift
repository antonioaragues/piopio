import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// The Setup tab (docs/spec/27 AU3, the agents and automations handoff, screen 3): who the agent is, never when it acts.
/// One centered column of four groups (Who it is · What it can use · Where you reach it · Limits), then a block on its
/// automations, which live in Automations, and History · View as file at its foot. It's a form over agent.json and
/// instructions.md that saves itself a moment after each change (a Save at the top went unseen: "I thought it saved on
/// its own"); saving validates first, errors show at the top with their path, and each save is a commit in the folder's
/// git history. View as file keeps Revert and Save: half-typed JSON can't be saved on its own.
struct AgentDefinitionView: View {
    let engine: EngineController
    let summary: SessionSummary
    /// The section to open at (a glance cell on the agent page).
    @Binding var section: String?
    /// Starts a request in its chat (routines set by asking).
    var askInChat: (String) -> Void = { _ in }
    @State private var runs: AgentRunsResult?
    @State private var loaded: AgentGetResult?
    @State private var def: AgentDef?
    @State private var original: AgentDef?
    @State private var instructions = ""
    @State private var originalInstructions = ""
    @State private var raw = ""
    @State private var editingJSON = false
    @State private var errors: [DefinitionError] = []
    @State private var saving = false
    /// The save waiting for typing to settle (the form saves itself).
    @State private var autosave: Task<Void, Never>?
    @State private var pickingModel = false
    @State private var jump: String?
    @State private var showingMemory = false
    /// Its kept files (docs/spec/06-agents §14): how many, and the sheet that lists them.
    @State private var showingFiles = false
    @State private var fileCount: Int?
    /// Facts it learned with you (the owner's partition), for "14 things learned".
    @State private var learned: Int?

    private var dirty: Bool { def != original || instructions != originalInstructions || (editingJSON && raw != rawText(original)) }

    /// Older section names (glance cells, the identity card, captures) land on the group that holds them now.
    private static func group(_ name: String) -> String {
        switch name {
        case "What it does", "What it knows": "Who it is"
        case "Who it talks to": "Where you reach it"
        default: name
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        saveBar
                        if !errors.isEmpty { errorBox }
                        if editingJSON {
                            TextEditor(text: $raw)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 480)
                                .padding(6)
                                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color.dsLine))
                        } else if def != nil {
                            whoGroup.id("Who it is")
                            toolsGroup.id("What it can use")
                            VStack(alignment: .leading, spacing: 22) {
                                channelsGroup
                                peopleGroup
                            }
                            .id("Where you reach it")
                            limitsGroup.id("Limits")
                            automationsBlock.id("Automations")
                        }
                        historyGroup.id("History")
                        footerLinks
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 16).padding(.bottom, 40)
                    .frame(maxWidth: 800)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: jump) { _, target in
                    if let target { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.group(target), anchor: .top) } }
                }
            }
        }
        .task(id: summary.ref.id) {
            await load()
            runs = await engine.agentRuns(summary.ref)
            if let section { jump = nil; DispatchQueue.main.async { jump = section } }
            await countLearned()
            fileCount = await engine.agentFiles(summary.ref)?.files.count
        }
        .onChange(of: section) { _, s in if let s { jump = nil; DispatchQueue.main.async { jump = s } } }
        .onChange(of: def) { _, _ in scheduleSave() }
        .onChange(of: instructions) { _, _ in scheduleSave() }
        // Leaving Setup (Chat, another agent) saves what's still waiting.
        .onDisappear { if autosave != nil { autosave?.cancel(); autosave = nil; if dirty, !editingJSON { save() } } }
        .popover(isPresented: $pickingModel) {
            ModelPicker(engine: engine, selected: modelRef(def?.models.default), role: .agent) { ref in
                def?.models.default = modelString(ref)
                pickingModel = false
            }
        }
        .sheet(isPresented: $showingFiles) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(summary.title)'s files").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Done") { showingFiles = false }.buttonStyle(PillStyle(kind: .strong, compact: true)).keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 16).padding(.top, 16)
                AgentFilesView(engine: engine, summary: summary) { fileCount = $0 }
            }
            .frame(width: 640, height: 520)
            .background(Color.dsWin)
        }
        .sheet(isPresented: $showingMemory) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("What \(summary.title) remembers").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Done") { showingMemory = false; Task { await countLearned() } }.buttonStyle(PillStyle(kind: .strong, compact: true)).keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 16).padding(.top, 16)
                AgentMemoryView(engine: engine, summary: summary)
            }
            .frame(width: 640, height: 520)
            .background(Color.dsWin)
        }
    }

    private func countLearned() async {
        guard let info = await engine.agentMemory(summary.ref), let owner = info.partitions.first(where: { $0.id == "owner" }) ?? info.partitions.first else { return }
        let list = await engine.memoryList(provider: info.provider, bank: owner.bank)
        learned = list?.records.filter { $0.kind != "message" }.count
    }

    // MARK: Bars

    /// Saving… or Saved, small, above the groups on the right; the form saves itself. View as file: how many changes wait,
    /// with Revert and Save ⌘S.
    private var saveBar: some View {
        HStack(spacing: 10) {
            Spacer()
            if !editingJSON, dirty || saving {
                Text(errors.isEmpty ? "Saving…" : "Not saved: fix what's above").font(.system(size: 12)).foregroundStyle(errors.isEmpty ? Color.dsFg3 : Color.dsWarn)
            } else if dirty {
                Circle().fill(Color.dsWarn).frame(width: 6, height: 6)
                Text("\(changeCount) unsaved change\(changeCount == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
            } else if let at = loaded?.history.first?.at {
                Text("Saved \(BuildSessionView.relative(at))").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            // Revert and Save only for the file, and only when there's something to save.
            if editingJSON, dirty || saving {
                Button("Revert") { Task { await load() } }.buttonStyle(PillStyle(compact: true)).disabled(saving)
                Button(saving ? "Saving…" : "Save ⌘S") { save() }.buttonStyle(PillStyle(kind: .primary, compact: true)).keyboardShortcut("s").disabled(saving)
            }
        }
        .frame(height: 30)
    }

    /// Roughly how many things changed (top-level fields, plus the instructions).
    private var changeCount: Int {
        guard let def, let original, let a = try? JSONEncoder.pretty.encode(def), let b = try? JSONEncoder.pretty.encode(original),
              let x = try? JSONDecoder().decode([String: JSONValue].self, from: a), let y = try? JSONDecoder().decode([String: JSONValue].self, from: b) else { return 1 }
        let keys = Set(x.keys).union(y.keys)
        return keys.filter { x[$0] != y[$0] }.count + (instructions != originalInstructions ? 1 : 0)
    }

    /// "History · View as file" at the foot.
    private var footerLinks: some View {
        HStack(spacing: 6) {
            Button(editingJSON ? "Back to the form" : "View as file") {
                if editingJSON, let parsed = parse(raw) { def = parsed } else if !editingJSON { raw = rawText(def) }
                editingJSON.toggle()
            }
            Text("·")
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.agent?.folder ?? "")]) }
        }
        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
    }

    private var errorBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not saved: fix these first").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.dsFg2)
            ForEach(errors, id: \.self) { e in
                Text("\(e.path)  \(e.message)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsFg2.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Its automations, at the end (docs/spec/27 AU3, the handoff's closing block): how many, that they're set in
    /// Automations and not here, one row each (dimmed while paused), and Open Automations ›.
    private var automationsBlock: some View {
        let mine = engine.automations.filter { $0.runsAs == summary.ref.id }
        let name = summary.title
        return VStack(alignment: .leading, spacing: 12) {
            if mine.isEmpty {
                (Text("\(name) doesn't run any automations. ").foregroundStyle(Color.dsFg) + Text("When it acts on its own is set in Automations. You can just ask \(name): “every morning at 8, …”").foregroundStyle(Color.dsFg2))
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            } else {
                (Text("\(name) runs \(mine.count) automation\(mine.count == 1 ? "" : "s"). ").fontWeight(.semibold).foregroundStyle(Color.dsFg) + Text("When they run is set in Automations, not here. You can also just ask \(name).").foregroundStyle(Color.dsFg2))
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 6) {
                    ForEach(mine) { a in
                        Button { NotificationCenter.default.post(name: .selectItem, object: SidebarItem.automation(a.id).raw) } label: {
                            HStack(spacing: 10) {
                                Text(a.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(a.enabled ? a.label : "Paused · \(a.label)").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(1)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .opacity(a.enabled ? 1 : 0.5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 16) {
                if !mine.isEmpty {
                    Button("Open Automations ›") { NotificationCenter.default.post(name: .selectItem, object: SidebarItem.automations(summary.ref.id).raw) }
                }
                Button(mine.isEmpty ? "Ask \(name) for one" : "Ask for another") { askInChat("Every morning at 8, ") }
            }
            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsSide, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// One tool (or app) and whether it may use it: Off · Asks · Allowed (design 2c), in place of one approval mode.
    private struct ToolChoice { let title: String; let detail: String; let tools: [String]; let apple: String? }

    private static let toolChoices: [ToolChoice] = [
        .init(title: "Search and read the web", detail: "", tools: ["web_search", "web_fetch"], apple: nil),
        .init(title: "Remember things", detail: "remember, recall, forget", tools: ["memory"], apple: nil),
        .init(title: "Send messages", detail: "to you, and to people it knows", tools: ["send_message"], apple: nil),
        .init(title: "Make its own automations", detail: "times and events, run as itself", tools: ["schedule"], apple: nil),
        .init(title: "Keep files", detail: "what you send it, to read later", tools: ["files"], apple: nil),
        .init(title: "Reminders", detail: "read, add, tick", tools: [], apple: "reminders"),
        .init(title: "Calendar", detail: "events and free time", tools: [], apple: "calendar"),
        .init(title: "Contacts", detail: "look people up", tools: [], apple: "contacts"),
        .init(title: "Notes", detail: "search, read, write", tools: [], apple: "notes"),
        .init(title: "Music", detail: "play and control", tools: [], apple: "music"),
    ]

    private var toolsGroup: some View {
        SetupGroup("What it can use", footer: "For each tool, whether it asks you first. Mac apps are served by Piopio while it's open; macOS asks once per app.", card: true) {
            ForEach(Self.toolChoices, id: \.title) { c in
                SetupRow(c.title, subtitle: c.detail.isEmpty ? nil : c.detail) {
                    NeutralSegmented(selection: Binding(get: { level(c) }, set: { setLevel(c, $0) }), options: [("off", "Off"), ("asks", "Asks"), ("allowed", "Allowed")])
                        .frame(width: 210)
                }
            }
            SetupRow("Shortcuts", subtitle: "Names it may run, comma-separated") {
                TextField("Log water, Morning routine", text: Binding(get: { def?.tools.shortcuts?.joined(separator: ", ") ?? "" }, set: { v in
                    let names = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    def?.tools.shortcuts = names.isEmpty ? nil : names
                }))
                .textFieldStyle(.roundedBorder).frame(width: 260)
            }
            browserRows
        }
    }

    /// Piopio's browser (docs/spec/22 W3): Off hides it; Asks asks you before it clicks or types on a site; Allowed
    /// doesn't ask on the sites listed. It browses with a profile of its own unless you give it yours.
    @ViewBuilder private var browserRows: some View {
        SetupRow("Browser", subtitle: "Read pages; clicking and typing on a site asks you") {
            NeutralSegmented(selection: Binding(get: { def?.tools.browser?.use ?? "off" }, set: { v in
                if v == "off" { def?.tools.browser = nil } else { def?.tools.browser = .init(use: v, sites: def?.tools.browser?.sites, profile: def?.tools.browser?.profile) }
            }), options: [("off", "Off"), ("asks", "Asks"), ("allowed", "Allowed")])
            .frame(width: 210)
        }
        if let browser = def?.tools.browser {
            if browser.use == "allowed" {
                SetupRow("Sites", subtitle: "It clicks and types on these without asking; other sites still ask") {
                    TextField("example.com, shop.example", text: Binding(get: { def?.tools.browser?.sites?.joined(separator: ", ") ?? "" }, set: { v in
                        let sites = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                        def?.tools.browser?.sites = sites.isEmpty ? nil : sites
                    }))
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                }
            }
            SetupRow("Sign-ins", subtitle: browser.profile == "yours" ? "It browses as you, signed in where you are" : "Its own, empty: sign it in with Watch on its page") {
                Picker("", selection: Binding(get: { def?.tools.browser?.profile ?? "own" }, set: { def?.tools.browser?.profile = $0 == "own" ? nil : $0 })) {
                    Text("Its own").tag("own")
                    Text("Yours").tag("yours")
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    /// The rules that make a choice ask first: its tools by name, or `apple_<app>_*`.
    private func rules(_ c: ToolChoice) -> [String] { c.apple.map { ["apple_\($0)_*"] } ?? c.tools }

    private func level(_ c: ToolChoice) -> String {
        guard let def else { return "off" }
        let on = c.apple.map { def.tools.apple?.contains($0) ?? false } ?? c.tools.contains { def.tools.builtin.contains($0) }
        guard on else { return "off" }
        let asks = (def.policies?.requireApproval ?? []).contains { rule in
            rule == "*" || rules(c).contains { rule == $0 || rule.hasPrefix($0 + ":") } || (c.apple.map { rule.hasPrefix("apple_\($0)_") || rule == "apple_*" } ?? false)
        }
        return asks ? "asks" : "allowed"
    }

    private func setLevel(_ c: ToolChoice, _ value: String) {
        guard var d = def else { return }
        if let app = c.apple {
            var apps = (d.tools.apple ?? []).filter { $0 != app }
            if value != "off" { apps.append(app) }
            d.tools.apple = apps.isEmpty ? nil : apps
        } else {
            d.tools.builtin.removeAll { c.tools.contains($0) }
            if value != "off" { d.tools.builtin.append(contentsOf: c.tools) }
        }
        var p = d.policies ?? .init()
        var list = (p.requireApproval ?? []).filter { rule in !rules(c).contains { rule == $0 || rule.hasPrefix($0 + ":") } && !(c.apple.map { rule.hasPrefix("apple_\($0)_") } ?? false) }
        if value == "asks" { list.append(contentsOf: rules(c)) }
        p.requireApproval = list.isEmpty ? nil : list
        d.policies = p
        def = d
    }

    /// Where you reach it: Piopio always; Telegram once connected (connecting is a token pasted in its chat); Slack and
    /// WhatsApp later.
    private var channelsGroup: some View {
        SetupGroup("Where you reach it", card: true) {
            SetupRow("Piopio", subtitle: "Its chat here, and notifications") { Text("Always").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3) }
            if def?.channels?["telegram"] != nil {
                SetupRow("Telegram", subtitle: "Messages reach you there too") { Text("Connected").font(.system(size: 12.5)).foregroundStyle(Color.dsGreen) }
            } else {
                SetupRow("Telegram", subtitle: "Make a bot with @BotFather, then paste its token in this agent's chat") {
                    Button("Connect…") { askInChat("") }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                }
            }
            SetupRow("Slack, WhatsApp") { Text("Later").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3) }
                .foregroundStyle(Color.dsFg3)
        }
    }

    // MARK: Groups

    /// Who it is: name and icon, its one line, its instructions, its model, and what it remembers.
    private var whoGroup: some View {
        SetupGroup("Who it is", card: true) {
            SetupRow("Name") {
                HStack(spacing: 6) {
                    AvatarPicker(avatar: optional(\.avatar))
                    TextField("Name", text: bind(\.name)).textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            SetupRow("What it's for", subtitle: "Shown under its name") {
                TextField("Watches Acme, Brightly and Northwind", text: optional(\.description)).textFieldStyle(.roundedBorder).frame(width: 300)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Instructions").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Spacer()
                    Text("Markdown · \(instructions.count / 4) tokens").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                }
                TextEditor(text: $instructions)
                    .font(.system(size: 13)).lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(.horizontal, -5)
                    .background(instructions != originalInstructions ? Color(nsColor: DS.addbg).opacity(0.5) : .clear)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            SetupRow("Model") {
                Button { pickingModel = true } label: {
                    HStack(spacing: 4) {
                        Text(engine.model(modelRef(def?.models.default)).map(ModelChip.short) ?? def?.models.default ?? "Choose…")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(ChipStyle())
            }
            SetupRow("Thinking") {
                Picker("", selection: Binding(get: { def?.thinking ?? "off" }, set: { def?.thinking = $0 == "off" ? nil : $0 })) {
                    ForEach(["off", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SetupRow("Memory") {
                HStack(spacing: 4) {
                    Text(learned.map { $0 == 0 ? "Nothing learned yet" : "\($0) thing\($0 == 1 ? "" : "s") learned" } ?? "…").foregroundStyle(Color.dsFg)
                    Text("·").foregroundStyle(Color.dsFg3)
                    Button("View") { showingMemory = true }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                .font(.system(size: 12.5))
            }
            if def?.tools.builtin.contains("files") == true {
                SetupRow("Files", subtitle: fileCount == 0 ? "Send them in its chat" : nil) {
                    HStack(spacing: 4) {
                        Text(fileCount.map { $0 == 0 ? "No files yet" : "\($0) file\($0 == 1 ? "" : "s")" } ?? "…").foregroundStyle(Color.dsFg)
                        Text("·").foregroundStyle(Color.dsFg3)
                        Button("View") { showingFiles = true }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                    .font(.system(size: 12.5))
                }
            }
        }
    }

    private var peopleGroup: some View {
        SetupGroup("People it talks to", footer: "The owner is who the agent works for; contacts only see their own memory.", card: true) {
            ForEach(Array((def?.contacts ?? []).enumerated()), id: \.offset) { i, _ in
                HStack(spacing: 6) {
                    TextField("Name", text: contactBinding(i, \.name)).textFieldStyle(.roundedBorder).frame(width: 140)
                    Picker("", selection: contactBinding(i, \.role)) {
                        Text("Owner").tag("owner")
                        Text("Contact").tag("contact")
                    }
                    .labelsHidden().frame(width: 100)
                    TextField("About them", text: Binding(get: { def?.contacts[safe: i]?.notes ?? "" }, set: { def?.contacts[i].notes = $0.isEmpty ? nil : $0 })).textFieldStyle(.roundedBorder)
                    TextField("id", text: contactBinding(i, \.id)).textFieldStyle(.roundedBorder).frame(width: 80).font(.system(size: 12, design: .monospaced))
                    Button { def?.contacts.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Color.dsFg3)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            Button("+ Add a person") {
                let n = (def?.contacts.count ?? 0) + 1
                def?.contacts.append(.init(id: "contact\(n)", name: "", role: "contact"))
            }
            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14).frame(height: 40, alignment: .leading)
            ForEach(engine.agents.filter { $0.ref.id != summary.ref.id }, id: \.ref.id) { other in
                SetupRow(other.title, subtitle: "Another agent") {
                    HStack(spacing: 12) {
                        Toggle("Can ask it", isOn: Binding(get: { def?.tools.agents?.contains(other.ref.id) ?? false }, set: { on in
                            var list = (def?.tools.agents ?? []).filter { $0 != other.ref.id }
                            if on { list.append(other.ref.id) }
                            def?.tools.agents = list.isEmpty ? nil : list
                        }))
                        Toggle("Accepts it", isOn: Binding(get: { def?.acceptFrom.map { $0.contains(other.ref.id) } ?? true }, set: { on in
                            let others = engine.agents.filter { $0.ref.id != summary.ref.id }.map(\.ref.id)
                            var list = def?.acceptFrom ?? others
                            list.removeAll { $0 == other.ref.id }
                            if on { list.append(other.ref.id) }
                            def?.acceptFrom = Set(list) == Set(others) ? nil : list
                        }))
                        Toggle("Shares memory", isOn: Binding(get: { def?.shareMemory?[other.ref.id]?.contains("shared") ?? false }, set: { on in
                            var share = def?.shareMemory ?? [:]
                            share[other.ref.id] = on ? ["shared"] : nil
                            def?.shareMemory = share.isEmpty ? nil : share
                        }))
                    }
                    .toggleStyle(.checkbox).font(.system(size: 12))
                }
            }
        }
    }

    private var limitsGroup: some View {
        SetupGroup("Limits", card: true) {
            SetupRow("Quiet hours", subtitle: "Messages wait until they end; urgent ones don't") {
                TextField("22:30-07:30", text: policy(\.quietHours)).textFieldStyle(.roundedBorder).frame(width: 110)
            }
            SetupRow("Time zone", subtitle: def?.timezone == nil ? "From this Mac" : nil) {
                TextField(TimeZone.current.identifier, text: Binding(get: { def?.timezone ?? "" }, set: { def?.timezone = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 180)
            }
            SetupRow("Monthly budget", subtitle: "It pauses itself when it's used up\(summary.agent?.status.map { " · \(MainSidebar.money($0.spendUsd)) spent this month" } ?? "")") {
                TextField("15", text: Binding(get: { def?.policies?.budgetUsdPerMonth.map { String(format: "%g", $0) } ?? "" }, set: { v in var p = def?.policies ?? .init(); p.budgetUsdPerMonth = Double(v); def?.policies = p }))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
            }
            SetupRow("Messages a day", subtitle: "In all, and to each person") {
                HStack(spacing: 6) {
                    TextField("20", text: Binding(get: { def?.policies?.maxOutboundPerDay.map(String.init) ?? "" }, set: { v in var p = def?.policies ?? .init(); p.maxOutboundPerDay = Int(v); def?.policies = p }))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                    TextField("5", text: Binding(get: { def?.policies?.maxOutboundPerContactPerDay.map(String.init) ?? "" }, set: { v in var p = def?.policies ?? .init(); p.maxOutboundPerContactPerDay = Int(v); def?.policies = p }))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                }
            }
            SetupRow("Urgent messages", subtitle: "Go out during quiet hours") {
                Toggle("", isOn: Binding(get: { def?.policies?.urgentBypassesQuiet ?? false }, set: { v in var p = def?.policies ?? .init(); p.urgentBypassesQuiet = v ? true : nil; def?.policies = p }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            SetupRow("Unknown senders") {
                Picker("", selection: Binding(get: { def?.policies?.unknownSenders ?? "ignore" }, set: { v in var p = def?.policies ?? .init(); p.unknownSenders = v; def?.policies = p })) {
                    Text("Ignore").tag("ignore")
                    Text("Canned reply").tag("reply_canned")
                    Text("Ask me").tag("ask_owner")
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    private var historyGroup: some View {
        SetupGroup("History", trailing: loaded?.folder, card: true) {
            ForEach(loaded?.history ?? [], id: \.self) { c in
                HStack {
                    Text(c.message).font(.system(size: 13))
                    Spacer()
                    Text("\(String(c.commit.prefix(7))) · \(BuildSessionView.relative(c.at))").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3)
                }
                .padding(.horizontal, 14).frame(height: 36)
            }
        }
    }

    // MARK: Bindings

    private func bind(_ path: WritableKeyPath<AgentDef, String>) -> Binding<String> {
        Binding(get: { def?[keyPath: path] ?? "" }, set: { def?[keyPath: path] = $0 })
    }

    private func optional(_ path: WritableKeyPath<AgentDef, String?>) -> Binding<String> {
        Binding(get: { def?[keyPath: path] ?? "" }, set: { def?[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    private func policy(_ path: WritableKeyPath<AgentDef.Policies, String?>) -> Binding<String> {
        Binding(get: { def?.policies?[keyPath: path] ?? "" }, set: { v in var p = def?.policies ?? .init(); p[keyPath: path] = v.isEmpty ? nil : v; def?.policies = p })
    }

    private func contactBinding(_ i: Int, _ path: WritableKeyPath<AgentDef.Contact, String>) -> Binding<String> {
        Binding(get: { def?.contacts[safe: i]?[keyPath: path] ?? "" }, set: { def?.contacts[i][keyPath: path] = $0 })
    }

    private func scheduleBinding(_ i: Int, _ path: WritableKeyPath<AgentDef.Schedule, String>) -> Binding<String> {
        Binding(get: { def?.schedules?[safe: i]?[keyPath: path] ?? "" }, set: { def?.schedules?[i][keyPath: path] = $0 })
    }

    // MARK: Load and save

    private func load() async {
        guard let got = await engine.agentDefinition(summary.ref) else { return }
        loaded = got
        def = AgentDef(got.definition)
        original = def
        instructions = got.instructions
        originalInstructions = got.instructions
        raw = rawText(def) .isEmpty ? (String(data: (try? JSONEncoder.sorted.encode(got.definition)) ?? Data(), encoding: .utf8) ?? "") : rawText(def)
        errors = got.errors
        if def == nil { editingJSON = true }
    }

    /// The form saves itself once changes settle: a switch at once, typing after a pause.
    private func scheduleSave() {
        autosave?.cancel()
        guard !editingJSON, def != nil, dirty else { autosave = nil; return }
        autosave = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            autosave = nil
            if saving { scheduleSave() } else if dirty { save() }
        }
    }

    private func save() {
        let json: JSONValue
        if editingJSON {
            guard let data = raw.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                errors = [DefinitionError(path: "/", message: "This isn't valid JSON.")]
                return
            }
            json = value
        } else {
            guard let def else { return }
            json = def.json
        }
        saving = true
        let sent = (def: def, instructions: instructions, file: editingJSON)
        Task {
            defer { saving = false }
            do {
                let result = try await engine.saveAgent(summary.ref, definition: json, instructions: sent.instructions, message: "")
                errors = result.errors
                guard result.errors.isEmpty else { return }
                if sent.file { await load(); return }
                // What was sent is saved; what was typed meanwhile stays and saves next (a reload would drop it).
                original = sent.def
                originalInstructions = sent.instructions
                if let got = await engine.agentDefinition(summary.ref) { loaded = got }
                if dirty { scheduleSave() }
            } catch {
                errors = [DefinitionError(path: "/", message: (error as? EngineError)?.message ?? String(describing: error))]
            }
        }
    }

    private func rawText(_ def: AgentDef?) -> String {
        guard let def, let data = try? JSONEncoder.pretty.encode(def) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parse(_ text: String) -> AgentDef? {
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return AgentDef(value)
    }
}

/// A System Settings-like group: a title, then rows in one card with inset dividers.
struct SetupGroup<Content: View>: View {
    let title: String
    var trailing: String?
    var footer: String?
    /// A white card with a hairline border (the agents and automations handoff), not hairlines above and below.
    var card = false
    @ViewBuilder var content: Content

    init(_ title: String, trailing: String? = nil, footer: String? = nil, card: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.footer = footer
        self.card = card
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle) }
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if i > 0 { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 14) }
                        row
                    }
                }
            }
            .modifier(GroupChrome(card: card))
            if let footer { Text(footer).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A group's rows: in a white card, or between hairlines (Settings).
private struct GroupChrome: ViewModifier {
    let card: Bool
    func body(content: Content) -> some View {
        if card {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color.dsLine))
        } else {
            content.settingsRows()
        }
    }
}

/// One row of a group: a title (and subtitle) on the left, the control on the right.
struct SetupRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14)
        .frame(minHeight: subtitle == nil ? 40 : 48)
    }
}

/// "0 7 * * *" → "Every day at 7:00" (the common shapes; the cron itself otherwise).
enum CronText {
    static func describe(_ cron: String) -> String {
        let f = cron.split(separator: " ").map(String.init)
        guard f.count == 5, let m = Int(f[0]), let h = Int(f[1]), f[2] == "*", f[3] == "*" else { return cron }
        let time = String(format: "%d:%02d", h, m)
        switch f[4] {
        case "*": return "Every day at \(time)"
        case "1-5": return "Weekdays at \(time)"
        case "0,6", "6,0": return "Weekends at \(time)"
        default:
            let names = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]
            if let d = Int(f[4]), names.indices.contains(d) { return "\(names[d]) at \(time)" }
            return cron
        }
    }

    /// "every day 7:00" for the agent header.
    static func short(_ cron: String) -> String {
        let text = describe(cron)
        return text == cron ? cron : text.replacingOccurrences(of: " at ", with: " ").lowercased()
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
