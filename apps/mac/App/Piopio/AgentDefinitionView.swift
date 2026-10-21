import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// The Setup tab (docs/design v2, 8a): a form over agent.json and instructions.md, grouped like System Settings, with a
/// jump list on the left and "View as JSON" at its foot. Saving validates first; errors show at the top with their
/// path. Each save is a commit in the folder's git history (the History group). Tools that don't work yet are hidden.
struct AgentDefinitionView: View {
    let engine: EngineController
    let summary: SessionSummary
    @State private var loaded: AgentGetResult?
    @State private var def: AgentDef?
    @State private var original: AgentDef?
    @State private var instructions = ""
    @State private var originalInstructions = ""
    @State private var raw = ""
    @State private var editingJSON = false
    @State private var errors: [DefinitionError] = []
    @State private var saving = false
    @State private var pickingModel = false
    @State private var jump: String?

    private var dirty: Bool { def != original || instructions != originalInstructions || (editingJSON && raw != rawText(original)) }

    private static let groups = ["Instructions", "Model", "Abilities", "Mac apps", "Schedule", "People", "Limits", "Memory", "History"]

    var body: some View {
        VStack(spacing: 0) {
            saveBar
            HStack(alignment: .top, spacing: 28) {
                jumpList
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if !errors.isEmpty { errorBox }
                            if editingJSON {
                                TextEditor(text: $raw)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(minHeight: 480)
                                    .padding(6)
                                    .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
                            } else if def != nil {
                                instructionsGroup.id("Instructions")
                                modelGroup.id("Model")
                                abilitiesGroup.id("Abilities")
                                macAppsGroup.id("Mac apps")
                                scheduleGroup.id("Schedule")
                                peopleGroup.id("People")
                                limitsGroup.id("Limits")
                                memoryGroup.id("Memory")
                            }
                            historyGroup.id("History")
                        }
                        .padding(.vertical, 20)
                        .padding(.trailing, 28)
                        .frame(maxWidth: 760, alignment: .leading)
                    }
                    .onChange(of: jump) { _, target in
                        if let target { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) } }
                    }
                }
            }
            .padding(.leading, 28)
        }
        .task(id: summary.ref.id) { await load() }
        .popover(isPresented: $pickingModel) {
            ModelPicker(engine: engine, selected: modelRef(def?.models.default), role: .agent) { ref in
                def?.models.default = modelString(ref)
                pickingModel = false
            }
        }
    }

    // MARK: Bars

    private var saveBar: some View {
        HStack(spacing: 10) {
            Spacer()
            if dirty {
                Circle().fill(Color.dsAmber).frame(width: 6, height: 6)
                Text("\(changeCount) unsaved change\(changeCount == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Color.dsAmber)
            } else if let at = loaded?.history.first?.at {
                Text("Saved \(BuildSessionView.relative(at))").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Button("Revert") { Task { await load() } }.buttonStyle(PillStyle(compact: true)).disabled(!dirty || saving)
            Button(saving ? "Saving…" : "Save ⌘S") { save() }.buttonStyle(PillStyle(kind: .primary, compact: true)).keyboardShortcut("s").disabled(!dirty || saving)
        }
        .padding(.horizontal, 28)
        .frame(height: 44)
    }

    /// Roughly how many things changed (top-level fields, plus the instructions).
    private var changeCount: Int {
        guard let def, let original, let a = try? JSONEncoder.pretty.encode(def), let b = try? JSONEncoder.pretty.encode(original),
              let x = try? JSONDecoder().decode([String: JSONValue].self, from: a), let y = try? JSONDecoder().decode([String: JSONValue].self, from: b) else { return 1 }
        let keys = Set(x.keys).union(y.keys)
        return keys.filter { x[$0] != y[$0] }.count + (instructions != originalInstructions ? 1 : 0)
    }

    private var jumpList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.groups, id: \.self) { g in
                Button { editingJSON = false; jump = nil; DispatchQueue.main.async { jump = g } } label: {
                    Text(g).font(.system(size: 13, weight: jump == g ? .semibold : .regular)).foregroundStyle(Color.dsFg)
                        .padding(.horizontal, 10).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading)
                        .background(jump == g ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(editingJSON ? "Back to the form" : "View as JSON") {
                if editingJSON, let parsed = parse(raw) { def = parsed } else if !editingJSON { raw = rawText(def) }
                editingJSON.toggle()
            }
            .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
            .padding(.horizontal, 10).padding(.bottom, 18)
        }
        .frame(width: 170)
        .padding(.top, 20)
    }

    private var errorBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not saved: fix these first").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.dsRed)
            ForEach(errors, id: \.self) { e in
                Text("\(e.path)  \(e.message)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Groups

    private var instructionsGroup: some View {
        SetupGroup("Instructions", trailing: "Markdown · \(instructions.count / 4) tokens") {
            SetupRow("Name") {
                HStack(spacing: 6) {
                    TextField("🙂", text: optional(\.avatar)).textFieldStyle(.roundedBorder).frame(width: 46)
                    TextField("Name", text: bind(\.name)).textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            SetupRow("One line", subtitle: "Shown under its name") {
                TextField("What it does", text: optional(\.description)).textFieldStyle(.roundedBorder).frame(width: 300)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $instructions)
                    .font(.system(size: 13.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(10)
                    .background(instructions != originalInstructions ? Color(nsColor: DS.addbg).opacity(0.5) : .clear)
            }
        }
    }

    private var modelGroup: some View {
        SetupGroup("Model") {
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
        }
    }

    /// The tools that work today, by what they let the agent do (the rest stay hidden until they arrive).
    private static let abilities: [(title: String, tools: [String], ids: String)] = [
        ("Search and read the web", ["web_search", "web_fetch"], "Web search, fetch pages"),
        ("Remember things", ["memory"], "Remember, recall, forget"),
        ("Send messages", ["send_message"], "send_message"),
        ("Set reminders and schedules", ["schedule"], "schedule, list_schedules, cancel_schedule"),
    ]

    private var abilitiesGroup: some View {
        SetupGroup("Abilities", footer: "HTTP requests, code and workspace files are coming later and stay hidden until then.") {
            ForEach(Self.abilities, id: \.title) { a in
                let on = a.tools.allSatisfy { def?.tools.builtin.contains($0) ?? false }
                SetupRow(a.title, subtitle: on ? subtitle(for: a) : "Off") {
                    HStack(spacing: 10) {
                        if on {
                            let asks = asksFirst(a.tools)
                            Text(asks == nil ? "Allowed" : "Asks first").font(.system(size: 12)).foregroundStyle(asks == nil ? Color.dsFg3 : Color.dsAmber)
                        }
                        Toggle("", isOn: Binding(get: { on }, set: { value in
                            guard var d = def else { return }
                            d.tools.builtin.removeAll { a.tools.contains($0) }
                            if value { d.tools.builtin.append(contentsOf: a.tools) }
                            def = d
                        }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
            }
        }
    }

    /// The approval rule that makes these tools ask first, if any.
    private func asksFirst(_ tools: [String]) -> String? {
        (def?.policies?.requireApproval ?? []).first { rule in tools.contains { rule == $0 || rule.hasPrefix($0 + ":") || rule == "*" } }
    }

    private func subtitle(for a: (title: String, tools: [String], ids: String)) -> String {
        if a.tools == ["send_message"], let rule = asksFirst(a.tools) {
            return rule.hasSuffix("to_non_owner") ? "To you; to others asks first" : "Asks before each message"
        }
        return a.ids
    }

    private static let appleChoices: [(String, String, String)] = [
        ("reminders", "Reminders", "Read, add, tick and reschedule"), ("calendar", "Calendar", "Events and free time, add and move"),
        ("contacts", "Contacts", "Look people up (read only)"), ("notes", "Notes", "Search, read, write"), ("music", "Music", "Play and control"),
    ]

    private var macAppsGroup: some View {
        SetupGroup("Mac apps", footer: "Served by Piopio while it's open; macOS asks once per app. Changes can be undone.") {
            ForEach(Self.appleChoices, id: \.0) { id, title, sub in
                SetupRow(title, subtitle: sub) {
                    Toggle("", isOn: Binding(get: { def?.tools.apple?.contains(id) ?? false }, set: { on in
                        guard var d = def else { return }
                        var groups = (d.tools.apple ?? []).filter { $0 != id }
                        if on { groups.append(id) }
                        d.tools.apple = groups.isEmpty ? nil : groups
                        def = d
                    }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            SetupRow("Shortcuts", subtitle: "Names it may run, comma-separated") {
                TextField("Log water, Morning routine", text: Binding(get: { def?.tools.shortcuts?.joined(separator: ", ") ?? "" }, set: { v in
                    let names = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    def?.tools.shortcuts = names.isEmpty ? nil : names
                }))
                .textFieldStyle(.roundedBorder).frame(width: 260)
            }
        }
    }

    private var scheduleGroup: some View {
        SetupGroup("Schedule", footer: "cron: minute hour day month weekday, in the agent's time zone. Activity shows each run.") {
            ForEach(Array((def?.schedules ?? []).enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(CronText.describe(s.cron)).font(.system(size: 13, weight: .medium))
                        Spacer()
                        TextField("0 8 * * 1-5", text: scheduleBinding(i, \.cron)).textFieldStyle(.roundedBorder).frame(width: 110).font(.system(size: 12, design: .monospaced))
                        Button { def?.schedules?.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Color.dsFg3)
                    }
                    TextField("What to do", text: scheduleBinding(i, \.prompt)).textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            Button("+ Add a schedule") {
                var list = def?.schedules ?? []
                list.append(.init(id: "schedule\(list.count + 1)", cron: "0 9 * * *", tz: TimeZone.current.identifier, prompt: "", deliverTo: "owner"))
                def?.schedules = list
            }
            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14).frame(height: 40, alignment: .leading)
            SetupRow("Time zone") {
                TextField(TimeZone.current.identifier, text: Binding(get: { def?.timezone ?? "" }, set: { def?.timezone = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 180)
            }
            SetupRow("Quiet hours", subtitle: "Messages wait until they end") {
                TextField("22:30-07:30", text: policy(\.quietHours)).textFieldStyle(.roundedBorder).frame(width: 110)
            }
        }
    }

    private var peopleGroup: some View {
        SetupGroup("People", footer: "The owner is who the agent works for; contacts only see their own memory.") {
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
        SetupGroup("Limits") {
            SetupRow("Monthly budget", subtitle: "It pauses itself when it's used up") {
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

    private var memoryGroup: some View {
        SetupGroup("Memory") {
            AgentMemoryView(engine: engine, summary: summary).frame(height: 380)
        }
    }

    private var historyGroup: some View {
        SetupGroup("History", trailing: loaded?.folder) {
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
        Task {
            defer { saving = false }
            do {
                let result = try await engine.saveAgent(summary.ref, definition: json, instructions: instructions, message: "")
                errors = result.errors
                if result.errors.isEmpty { await load() }
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
    @ViewBuilder var content: Content

    init(_ title: String, trailing: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.footer = footer
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
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
            if let footer { Text(footer).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
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
