import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// The Definition tab (06-agents AD1, AD3, docs/design 6a): a form over agent.json and instructions.md, or the JSON
/// itself. Saving validates first; errors show at the top with their path. Each save is a commit in the folder's git
/// history, listed below. Schedules, heartbeat and channels are saved now and run from milestone 4.3.
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
    @State private var message = ""
    @State private var saving = false
    @State private var pickingModel = false

    private var dirty: Bool { def != original || instructions != originalInstructions || (editingJSON && raw != rawText(original)) }

    var body: some View {
        VStack(spacing: 0) {
            saveBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !errors.isEmpty { errorBox }
                    if editingJSON {
                        TextEditor(text: $raw)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 420)
                            .padding(6)
                            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
                    } else if def != nil {
                        persona
                        model
                        tools
                        contacts
                        schedules
                        policies
                    }
                    history
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .task(id: summary.ref.id) { await load() }
        .popover(isPresented: $pickingModel) {
            ModelPicker(engine: engine, selected: modelRef(def?.models.default)) { ref in
                def?.models.default = modelString(ref)
                pickingModel = false
            }
            .frame(width: 420, height: 380)
        }
    }

    // MARK: Bars

    private var saveBar: some View {
        HStack(spacing: 8) {
            if dirty { Circle().fill(Color.dsAmber).frame(width: 6, height: 6); Text("Unsaved changes").font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            else { Text("Saved · \(loaded?.history.first.map { BuildSessionView.relative($0.at) } ?? "")").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
            Spacer()
            Toggle("JSON", isOn: Binding(get: { editingJSON }, set: { on in
                if on { raw = rawText(def) } else if let parsed = parse(raw) { def = parsed }
                editingJSON = on
            }))
            .toggleStyle(.button).controlSize(.small)
            TextField("What changed (optional)", text: $message).textFieldStyle(.roundedBorder).frame(width: 220)
            Button("Revert") { Task { await load() } }.buttonStyle(PillStyle(compact: true)).disabled(!dirty || saving)
            Button(saving ? "Saving…" : "Save") { save() }.buttonStyle(PillStyle(kind: .primary, compact: true)).keyboardShortcut("s").disabled(!dirty || saving)
        }
        .padding(.horizontal, 24)
        .frame(height: 46)
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

    // MARK: Sections

    private func section<Content: View>(_ title: String, _ subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
            }
            content()
        }
    }

    private var persona: some View {
        section("Persona") {
            HStack(spacing: 8) {
                TextField("🙂", text: optional(\.avatar)).textFieldStyle(.roundedBorder).frame(width: 52)
                TextField("Name", text: bind(\.name)).textFieldStyle(.roundedBorder)
            }
            TextField("One line for the sidebar", text: optional(\.description)).textFieldStyle(.roundedBorder)
            HStack {
                Text("Instructions").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
                Spacer()
                Text("Markdown · about \(instructions.count / 4) tokens").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            }
            TextEditor(text: $instructions)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(minHeight: 160)
                .padding(6)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
        }
    }

    private var model: some View {
        section("Model") {
            HStack {
                Button(engine.model(modelRef(def?.models.default))?.name ?? def?.models.default ?? "Choose…") { pickingModel = true }.buttonStyle(PillStyle(compact: true))
                Picker("Thinking", selection: Binding(get: { def?.thinking ?? "off" }, set: { def?.thinking = $0 == "off" ? nil : $0 })) {
                    ForEach(["off", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                .fixedSize()
            }
        }
    }

    private static let toolChoices: [(String, String, Bool)] = [
        ("web_search", "Web search", true), ("web_fetch", "Read web pages", true), ("memory", "Memory (remember, recall, forget)", true),
        ("schedule", "Reminders and schedules", false), ("send_message", "Send messages", false), ("http_request", "HTTP requests", false),
        ("codemode", "Code mode", false), ("files", "Workspace files", false),
    ]

    private var tools: some View {
        section("Tools", "Grey ones are saved now and arrive in later milestones") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Self.toolChoices, id: \.0) { id, title, ready in
                    Toggle(title, isOn: Binding(get: { def?.tools.builtin.contains(id) ?? false }, set: { on in
                        guard var d = def else { return }
                        d.tools.builtin.removeAll { $0 == id }
                        if on { d.tools.builtin.append(id) }
                        def = d
                    }))
                    .toggleStyle(.checkbox)
                    .foregroundStyle(ready ? Color.dsFg : Color.dsFg3)
                }
            }
        }
    }

    private var contacts: some View {
        section("Contacts", "The owner is who the agent works for; contacts only see their own memory") {
            ForEach(Array((def?.contacts ?? []).enumerated()), id: \.offset) { i, _ in
                HStack(spacing: 6) {
                    TextField("id", text: contactBinding(i, \.id)).textFieldStyle(.roundedBorder).frame(width: 90).font(.system(size: 12, design: .monospaced))
                    TextField("Name", text: contactBinding(i, \.name)).textFieldStyle(.roundedBorder).frame(width: 140)
                    Picker("", selection: contactBinding(i, \.role)) {
                        Text("Owner").tag("owner")
                        Text("Contact").tag("contact")
                    }
                    .labelsHidden().frame(width: 100)
                    TextField("About them (optional)", text: Binding(get: { def?.contacts[safe: i]?.notes ?? "" }, set: { def?.contacts[i].notes = $0.isEmpty ? nil : $0 })).textFieldStyle(.roundedBorder)
                    Button { def?.contacts.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Color.dsFg3)
                }
            }
            Button("+ Contact") {
                let n = (def?.contacts.count ?? 0) + 1
                def?.contacts.append(.init(id: "contact\(n)", name: "", role: "contact"))
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
        }
    }

    private var schedules: some View {
        section("Schedules", "cron (minute hour day month weekday) · they run from milestone 4.3") {
            ForEach(Array((def?.schedules ?? []).enumerated()), id: \.offset) { i, _ in
                HStack(spacing: 6) {
                    TextField("id", text: scheduleBinding(i, \.id)).textFieldStyle(.roundedBorder).frame(width: 90).font(.system(size: 12, design: .monospaced))
                    TextField("0 8 * * 1-5", text: scheduleBinding(i, \.cron)).textFieldStyle(.roundedBorder).frame(width: 110).font(.system(size: 12, design: .monospaced))
                    TextField("What to do", text: scheduleBinding(i, \.prompt)).textFieldStyle(.roundedBorder)
                    Button { def?.schedules?.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Color.dsFg3)
                }
            }
            Button("+ Schedule") {
                var list = def?.schedules ?? []
                list.append(.init(id: "schedule\(list.count + 1)", cron: "0 9 * * *", tz: TimeZone.current.identifier, prompt: "", deliverTo: "owner"))
                def?.schedules = list
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
        }
    }

    private var policies: some View {
        section("Policies", "Enforced from milestones 4.3–4.4") {
            HStack(spacing: 12) {
                labeled("Quiet hours") { TextField("22:30-07:30", text: policy(\.quietHours)).textFieldStyle(.roundedBorder).frame(width: 110) }
                labeled("Messages a day") {
                    TextField("20", text: Binding(get: { def?.policies?.maxOutboundPerDay.map(String.init) ?? "" }, set: { v in var p = def?.policies ?? .init(); p.maxOutboundPerDay = Int(v); def?.policies = p }))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                }
                labeled("Budget $/month") {
                    TextField("15", text: Binding(get: { def?.policies?.budgetUsdPerMonth.map { String(format: "%g", $0) } ?? "" }, set: { v in var p = def?.policies ?? .init(); p.budgetUsdPerMonth = Double(v); def?.policies = p }))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                }
                labeled("Unknown senders") {
                    Picker("", selection: Binding(get: { def?.policies?.unknownSenders ?? "ignore" }, set: { v in var p = def?.policies ?? .init(); p.unknownSenders = v; def?.policies = p })) {
                        Text("Ignore").tag("ignore")
                        Text("Canned reply").tag("reply_canned")
                        Text("Ask me").tag("ask_owner")
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    private var history: some View {
        section("History", loaded?.folder) {
            ForEach(loaded?.history ?? [], id: \.self) { c in
                HStack {
                    Text(c.message).font(.system(size: 12.5))
                    Spacer()
                    Text("\(String(c.commit.prefix(7))) · \(BuildSessionView.relative(c.at))").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3)
                }
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            content()
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
                let result = try await engine.saveAgent(summary.ref, definition: json, instructions: instructions, message: message)
                errors = result.errors
                if result.errors.isEmpty {
                    message = ""
                    await load()
                }
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
