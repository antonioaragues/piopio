import PiopioKit
import PiopioTranscript
import SwiftUI

/// The model picker (docs/design/grey 11f): a search field, a group per provider, one plain line for each model, ✓ on the
/// current one, whatever the caller adds (Thinking), and Manage providers. Recently used models lead their group; batch
/// and alias variants stay folded until you search. Searching also matches "free", "vision" and "reasoning".
/// With coding agents (docs/spec/31, docs/design/agent-runtimes/picker.html) the list has two parts, Models then Agents:
/// one row per agent ("Claude Code", "Opus 5.5 · Pro plan"), and the models that match a search under its row.
/// An agent row works like a menu item with a submenu (docs/design/agent-picker/agent-submenu.html): hovering it opens its
/// models beside the picker, clicking it picks the model it shows. Moving diagonally toward the submenu keeps it open.
/// Keyboard: type to search, ↑↓ to move, → to open an agent's models (← or esc to go back), ↩ to pick, ⌘↩ to pick and
/// make it the default for `role`.
struct ModelPicker: View {
    let engine: EngineController
    let selected: ModelRef?
    var role: EngineController.ModelRole = .chat
    /// Shown between the list and Manage providers (the composer's Thinking control).
    var accessory: AnyView?
    /// Coding agents' models (Claude Code runs the whole conversation, docs/spec/31): only where a conversation starts or
    /// continues (the composer, start pages, the Build and chat defaults), not for agents, Quick Chat or background work.
    var agents = false
    let onPick: (ModelRef) -> Void
    @State private var query = ""
    /// The agent whose models are open at its side, the row highlighted there (keyboard or pointer), and whether its
    /// older models are unfolded.
    @State private var agentMenu: String?
    @State private var subHighlight: Int?
    @State private var showOlder = false
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var submenu = AgentSubmenu()
    @State private var showVariants = false
    @State private var highlighted: String?
    @FocusState private var searching: Bool
    @AppStorage("recentModels") private var recentRaw = ""

    private struct Section: Identifiable { let id: String; let title: String; let models: [ModelInfo] }

    var body: some View {
        VStack(spacing: 0) {
            TextField(hasAgents ? "Search models and agents" : "Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($searching)
                .padding(.horizontal, 16)
                .frame(height: 40)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            list
            if let accessory {
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                accessory
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack {
                Button(hasAgents ? "Manage providers and agents" : "Manage providers") {
                    UserDefaults.standard.set("Models", forKey: "settingsSection")
                    WindowOpener.shared.openSettings?()
                }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                Spacer()
                Text("⌘↩ sets as default").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
        }
        .frame(width: 340, height: accessory == nil ? 440 : 500)
        .background(Color.dsCard)
        .coordinateSpace(name: AgentSubmenu.space)
        .background(AgentSubmenu.Anchor(submenu: submenu))
        .onPreferenceChange(AgentRowFrames.self) { rowFrames = $0; syncSubmenu() }
        .onContinuousHover { phase in if case .active = phase { submenu.track(NSEvent.mouseLocation) } }
        .onChange(of: agentMenu) { _, _ in showOlder = false; syncSubmenu() }
        .onChange(of: subHighlight) { _, _ in syncSubmenu() }
        .onChange(of: showOlder) { _, _ in syncSubmenu() }
        .onDisappear { submenu.close() }
        .onAppear {
            searching = true
            // Captures: PIOPIO_DEMO_MODEL_QUERY types a search.
            if let q = ProcessInfo.processInfo.environment["PIOPIO_DEMO_MODEL_QUERY"] { query = q }
            // PIOPIO_DEMO_AGENT_MENU=<provider>: open that agent's models at its side.
            if let agent = ProcessInfo.processInfo.environment["PIOPIO_DEMO_AGENT_MENU"] {
                Task { try? await Task.sleep(for: .seconds(1)); agentMenu = agent }
            }
            highlighted = keys.first { $0.hasSuffix("|\(selected?.provider ?? "")/\(selected?.id ?? "")") } ?? keys.first { $0 == "agent|\(selected?.provider ?? "")" } ?? keys.first
        }
        .onChange(of: query) { _, _ in highlighted = keys.first; closeSubmenu() }
        .onKeyPress(.downArrow) {
            if let i = subHighlight { subHighlight = min(subItems.count - 1, i + 1) } else { closeSubmenu(); move(1) }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if let i = subHighlight { subHighlight = max(0, i - 1) } else { closeSubmenu(); move(-1) }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard subHighlight == nil, let key = highlighted, key.hasPrefix("agent|"), query.isEmpty else { return .ignored }
            let id = String(key.dropFirst("agent|".count))
            agentMenu = id
            // Start on the model the row shows.
            if let group = agentGroups.first(where: { $0.id == id }) {
                showOlder = !Self.current(group).contains(chosenModel(group))
                subHighlight = items(group, older: showOlder).firstIndex { $0.model?.ref == chosenModel(group).ref } ?? 0
            }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard agentMenu != nil else { return .ignored }
            closeSubmenu()
            return .handled
        }
        .onKeyPress(.escape) {
            guard agentMenu != nil else { return .ignored }
            closeSubmenu()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            if let i = subHighlight, subItems.indices.contains(i) {
                guard let model = subItems[i].model else { showOlder = true; return .handled }
                if press.modifiers.contains(.command) { engine.setModel(model.ref, for: role) }
                pick(model)
                return .handled
            }
            guard let model = model(for: highlighted) else { return .ignored }
            if press.modifiers.contains(.command) { engine.setModel(model.ref, for: role) }
            pick(model)
            return .handled
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if hasAgents, !sections.isEmpty { part("Models", "Piopio's agent runs them") }
                    ForEach(sections) { section in
                        Text(section.title).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
                        ForEach(section.models) { model in row(model, in: section.id) }
                    }
                    // Under the models it unfolds, before the agents.
                    if foldsVariants, hiddenVariants > 0 {
                        Button("Show \(hiddenVariants) more variant\(hiddenVariants == 1 ? "" : "s")") { showVariants = true }
                            .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    if !agentGroups.isEmpty {
                        if !sections.isEmpty { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.horizontal, 4).padding(.vertical, 8) }
                        part("Agents", "run the whole conversation")
                        ForEach(agentGroups) { group in
                            agentRow(group)
                            if !query.isEmpty { ForEach(group.models) { model in row(model, in: "agent:\(group.id)", indented: true) } }
                        }
                    }
                    if sections.isEmpty && agentGroups.isEmpty {
                        Text(engine.models.isEmpty ? "Loading models…" : "No models match.")
                            .font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(6)
            }
            .onChange(of: highlighted) { _, key in
                if let key { proxy.scrollTo(key) }
            }
            .onAppear { if let highlighted { proxy.scrollTo(highlighted, anchor: .center) } }
        }
    }

    private func row(_ model: ModelInfo, in section: String, indented: Bool = false) -> some View {
        let key = "\(section)|\(model.provider)/\(model.id)"
        let isSelected = selected?.provider == model.provider && selected?.id == model.id
        return Button { pick(model) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.shortName(model)).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                    if !indented { Text(line(model)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if isSelected { Image(systemName: "checkmark").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dsFg2) }
            }
            .padding(.leading, indented ? 46 : 10).padding(.trailing, 10)
            .frame(height: indented ? 34 : 42)
            .background(isSelected || highlighted == key ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(key)
        .help("\(model.id)\n\(Self.price(model)) per million tokens, input / output · \(Self.context(model)) context")
        .onHover { inside in
            if inside { hover(key) } else if submenu.hovered == key { submenu.hovered = nil }
        }
        .contextMenu { Button("Set as Default for \(Self.roleName(role))") { engine.setModel(model.ref, for: role) } }
    }

    /// "Models · Piopio's agent runs them", "Agents · run the whole conversation".
    private func part(_ title: String, _ hint: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.dsFg)
            Spacer()
            Text(hint).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    /// One row per coding agent: what it will run (the model you chose, else the last you used in it, else its first),
    /// and the plan. Hovering it opens its models at its side; clicking it picks the model it shows.
    private func agentRow(_ group: AgentGroup) -> some View {
        let key = "agent|\(group.id)"
        let chosen = chosenModel(group)
        let isSelected = selected?.provider == group.id
        return Button { pick(chosen) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: DS.bubble)).frame(width: 26, height: 26)
                    .overlay(AgentGlyph(size: 12))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.providerTag(chosen)).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                    Text(query.isEmpty ? [Self.shortName(chosen), Self.planLabel(chosen)].compactMap { $0 }.joined(separator: " · ") : (Self.planLabel(chosen) ?? ""))
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if isSelected { Image(systemName: "checkmark").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dsFg2) }
                    // A sign, like a menu item's: the whole row opens the submenu.
                    if query.isEmpty { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3) }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background(isSelected || highlighted == key || agentMenu == group.id ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(key)
        .background(GeometryReader { g in Color.clear.preference(key: AgentRowFrames.self, value: [group.id: g.frame(in: .named(AgentSubmenu.space))]) })
        .onHover { inside in
            if inside { hover(key) } else if submenu.hovered == key { submenu.hovered = nil }
        }
    }

    // MARK: Submenu

    /// The pointer entered a row: highlight it, open an agent's models after a beat, or close the open ones. While the
    /// pointer heads for the open submenu, rows it crosses on the way are skipped, then looked at again once it rests.
    private func hover(_ key: String) {
        submenu.hovered = key
        let agent = key.hasPrefix("agent|") ? String(key.dropFirst("agent|".count)) : nil
        if let open = agentMenu, agent != open, submenu.headingIn() {
            submenu.later(0.3) { if submenu.hovered == key { hover(key) } }
            return
        }
        highlighted = key
        if let agent {
            if agent == agentMenu { submenu.cancel(); subHighlight = nil; return }
            submenu.later(0.1) {
                guard submenu.hovered == key else { return }
                subHighlight = nil
                agentMenu = agent
            }
        } else if agentMenu != nil {
            submenu.later(0.15) { if submenu.hovered == key { closeSubmenu() } }
        }
    }

    private func closeSubmenu() {
        submenu.cancel()
        agentMenu = nil
        subHighlight = nil
    }

    /// The agent's main models (Claude Code: Opus, Sonnet, Fable, Haiku), then "Older models", unfolded on demand.
    struct SubItem: Hashable { let model: ModelInfo?; let older: Int }

    static func current(_ group: AgentGroup) -> [ModelInfo] { Array(group.all.prefix(4)) }

    private func items(_ group: AgentGroup, older: Bool) -> [SubItem] {
        let rest = group.all.dropFirst(4)
        if rest.isEmpty || older { return group.all.map { SubItem(model: $0, older: 0) } }
        return Self.current(group).map { SubItem(model: $0, older: 0) } + [SubItem(model: nil, older: rest.count)]
    }

    private var subItems: [SubItem] {
        guard let group = agentGroups.first(where: { $0.id == agentMenu }) else { return [] }
        return items(group, older: showOlder)
    }

    private func syncSubmenu() {
        guard let id = agentMenu, query.isEmpty, let frame = rowFrames[id] else { submenu.close(); return }
        submenu.show(
            AnyView(AgentModelsMenu(
                items: subItems, selected: selected, highlighted: subHighlight,
                onHover: { subHighlight = $0; submenu.cancel() },
                onPick: { model in
                    if NSEvent.modifierFlags.contains(.command) { engine.setModel(model.ref, for: role) }
                    pick(model)
                },
                onOlder: { showOlder = true }
            )),
            row: frame
        )
    }

    private func chosenModel(_ group: AgentGroup) -> ModelInfo {
        if let selected, selected.provider == group.id, let m = group.all.first(where: { $0.ref == selected }) { return m }
        if let last = recent.first(where: { $0.hasPrefix("\(group.id)/") }), let m = group.all.first(where: { "\($0.provider)/\($0.id)" == last }) { return m }
        return group.all[0]
    }

    /// One plain line: who makes it and what it's like, not its specs. "Anthropic · premium, reads images · default".
    private func line(_ m: ModelInfo) -> String {
        var traits: [String] = []
        switch Self.tier(m) {
        case "Free": traits.append("free")
        case "Plan": traits.append("in your plan")
        case "Yours": traits.append(m.billing == "On this Mac" ? "runs on this Mac" : "your server")
        case "$": traits.append("low cost")
        case "$$": traits.append("mid-priced")
        case "$$$": traits.append("premium")
        default: break
        }
        if m.supports.reasoning { traits.append("thinks first") }
        if m.supports.vision { traits.append("reads images") }
        let main = [Self.maker(m), traits.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · ")
        return engine.model(for: role) == m.ref ? main + " · default" : main
    }

    // MARK: Data

    struct AgentGroup: Identifiable {
        let id: String
        /// Every model it offers, in its own order.
        let all: [ModelInfo]
        /// The ones that match the search (all of them when not searching).
        let models: [ModelInfo]
    }

    private var hasAgents: Bool { agents && engine.models.contains(where: \.isAgent) }

    /// Coding agents, one per provider, in the engine's order; while searching, those whose name or a model matches.
    private var agentGroups: [AgentGroup] {
        guard agents else { return [] }
        let all = engine.models.filter(\.isAgent)
        let matched = Set(matching.filter(\.isAgent).map(\.id))
        var order: [String] = []
        for m in all where !order.contains(m.provider) { order.append(m.provider) }
        return order.compactMap { provider in
            let models = all.filter { $0.provider == provider }
            let hits = models.filter { matched.contains($0.id) }
            let nameHit = query.isEmpty || query.lowercased().split(separator: " ").allSatisfy { Self.providerTag(models[0]).lowercased().contains($0) }
            if !query.isEmpty, hits.isEmpty, !nameHit { return nil }
            return AgentGroup(id: provider, all: models, models: query.isEmpty ? models : hits)
        }
    }

    private var matching: [ModelInfo] {
        let terms = query.lowercased().split(separator: " ")
        return engine.models.filter { m in
            guard agents || !m.isAgent else { return false }
            let traits = (Self.isFree(m) ? "free " : "") + (m.supports.vision ? "vision images " : "") + (m.supports.reasoning ? "reasoning thinking " : "")
            let hay = "\(m.name) \(m.id) \(m.provider) \(m.providerName ?? "") \(m.billing ?? "") \(traits)".lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    /// Batch and alias variants stay folded unless searching or asked for.
    private var foldsVariants: Bool { !showVariants && query.isEmpty }
    private var hiddenVariants: Int { matching.filter { !$0.isAgent && Self.isVariant($0) }.count }

    /// A group per provider, OpenRouter first. In a group: what you used lately, then the known makers, then the rest.
    private var sections: [Section] {
        // Coding agents' models are in their own part (agentGroups).
        let models = matching.filter { !$0.isAgent }
        let listed = foldsVariants ? models.filter { !Self.isVariant($0) || ($0.provider == selected?.provider && $0.id == selected?.id) } : models
        let recents = (selected.map { ["\($0.provider)/\($0.id)"] } ?? []) + recent
        let order = ["openrouter", "faux", "openai", "openai-api"]
        let groups = Dictionary(grouping: listed, by: \.provider)
        // Coding agents come after the model providers.
        let rank = { (p: String) in groups[p]?.first?.isAgent == true ? 20 : order.firstIndex(of: p) ?? 9 }
        return groups.keys.sorted { (rank($0), $0) < (rank($1), $1) }.map { provider in
            let models = groups[provider]!.sorted { a, b in
                let ra = query.isEmpty ? recents.firstIndex(of: "\(a.provider)/\(a.id)") ?? 99 : 99, rb = query.isEmpty ? recents.firstIndex(of: "\(b.provider)/\(b.id)") ?? 99 : 99
                if ra != rb { return ra < rb }
                // A coding agent's models keep its own order (Opus first).
                if a.isAgent, b.isAgent { return (engine.models.firstIndex(of: a) ?? 0) < (engine.models.firstIndex(of: b) ?? 0) }
                let ma = Self.makerRank(a), mb = Self.makerRank(b)
                return ma != mb ? ma < mb : Self.shortName(a) < Self.shortName(b)
            }
            // "Claude Code · Claude Pro plan": the agent runs the conversation, and the plan pays (docs/spec/31 §5).
            let title = models[0].isAgent ? [Self.providerTag(models[0]), models[0].billing].compactMap { $0 }.joined(separator: " · ") : Self.providerTag(models[0])
            return Section(id: "provider:\(provider)", title: title, models: models)
        }
    }

    private static func makerRank(_ m: ModelInfo) -> Int {
        knownMakers.firstIndex { $0.caseInsensitiveCompare(maker(m)) == .orderedSame } ?? knownMakers.count
    }

    /// Row keys in display order (keyboard navigation).
    private var keys: [String] {
        sections.flatMap { s in s.models.map { "\(s.id)|\($0.provider)/\($0.id)" } }
            + agentGroups.flatMap { g in ["agent|\(g.id)"] + (query.isEmpty ? [] : g.models.map { "agent:\(g.id)|\($0.provider)/\($0.id)" }) }
    }

    private func model(for key: String?) -> ModelInfo? {
        guard let key else { return nil }
        if key.hasPrefix("agent|") { return agentGroups.first { "agent|\($0.id)" == key }.map(chosenModel) }
        guard let ref = key.split(separator: "|", maxSplits: 1).last else { return nil }
        return engine.models.first { "\($0.provider)/\($0.id)" == ref }
    }

    private func move(_ by: Int) {
        let all = keys
        guard !all.isEmpty else { return }
        let i = highlighted.flatMap { all.firstIndex(of: $0) } ?? -1
        highlighted = all[max(0, min(all.count - 1, i + by))]
    }

    private func pick(_ model: ModelInfo) {
        closeSubmenu()
        let key = "\(model.provider)/\(model.id)"
        recentRaw = ([key] + recent.filter { $0 != key }).prefix(8).joined(separator: "\n")
        onPick(model.ref)
    }

    // MARK: Formatting

    private static let knownMakers = ["Anthropic", "OpenAI", "Google", "xAI", "Meta", "Mistral", "DeepSeek", "Qwen", "Moonshot", "Z.ai"]

    /// "Anthropic: Claude Haiku 5.5" → "Anthropic"; otherwise the id's vendor ("anthropic/…") or the provider.
    static func maker(_ m: ModelInfo) -> String {
        if m.isAgent { return "Runs in \(m.providerName ?? "the agent")" }
        if m.provider.hasPrefix("custom-") { return m.providerName ?? "Custom" }
        if m.provider == "openai" || m.provider == "openai-api" { return "OpenAI" }
        if let colon = m.name.firstIndex(of: ":") { return String(m.name[..<colon]).trimmingCharacters(in: .whitespaces) }
        if let slash = m.id.firstIndex(of: "/") { return String(m.id[..<slash]).capitalized }
        return m.provider.capitalized
    }

    /// How the picker and chips name where a model runs: "ChatGPT", "OpenAI API", "OpenRouter".
    static func providerTag(_ m: ModelInfo) -> String {
        switch m.provider {
        case "openai": "ChatGPT"
        case "openai-api": "OpenAI API"
        case "openrouter": "OpenRouter"
        default: m.providerName ?? m.provider.capitalized
        }
    }

    /// "Claude Pro plan" → "Pro plan", "Google AI Pro plan" → "AI Pro plan", "ChatGPT Plus plan" → "Plus plan": the
    /// agent's row already names who it's from.
    static func planLabel(_ m: ModelInfo) -> String? {
        guard let billing = m.billing else { return nil }
        for brand in ["Claude ", "ChatGPT ", "Google "] where billing.hasPrefix(brand) && billing.count > brand.count + 5 {
            return String(billing.dropFirst(brand.count))
        }
        return billing
    }

    static func shortName(_ m: ModelInfo) -> String {
        guard let colon = m.name.firstIndex(of: ":") else { return m.name }
        return String(m.name[m.name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    static func isFree(_ m: ModelInfo) -> Bool { m.pricing.input == 0 && m.pricing.output == 0 }

    /// "$" under $2, "$$" under $15, "$$$" above, per million output tokens; "Plan" when a subscription pays.
    static func tier(_ m: ModelInfo) -> String {
        if m.isAgent || m.billing?.contains("subscription") == true { return "Plan" }
        if m.billing == "Your server" || m.billing == "On this Mac" { return "Yours" }
        if isFree(m) { return "Free" }
        return m.pricing.output < 2 ? "$" : m.pricing.output < 15 ? "$$" : "$$$"
    }

    /// OpenRouter's routing aliases (":free", ":nitro", ":beta", "-latest") and dated or batch snapshots of a model.
    static func isVariant(_ m: ModelInfo) -> Bool {
        let id = m.id.lowercased()
        if id.contains(":") || id.hasSuffix("-latest") || id.contains("batch") { return true }
        return id.range(of: #"-\d{4}-?\d{2}-?\d{2}$"#, options: .regularExpression) != nil
            || id.range(of: #"-\d{4}$"#, options: .regularExpression) != nil
    }

    static func blurb(_ m: ModelInfo) -> String {
        var can = [String]()
        if m.supports.reasoning { can.append("reasons before answering") }
        if m.supports.vision { can.append("reads images") }
        let size = m.contextWindow >= 500_000 ? "Reads very long documents" : m.contextWindow >= 100_000 ? "Reads long documents" : "Suited to short exchanges"
        return can.isEmpty ? "\(size)." : "\(size); \(can.joined(separator: " and "))."
    }

    static func tokens(_ v: Double) -> String {
        v >= 1_000_000 ? String(format: "%gM", (v / 100_000).rounded() / 10) : v >= 1000 ? "\(Int(v / 1000))K" : "\(Int(v))"
    }

    static func roleName(_ role: EngineController.ModelRole) -> String {
        switch role {
        case .build: "Build sessions"
        case .chat: "conversations"
        case .quick: "Quick Chat"
        case .agent: "new agents"
        }
    }

    static func price(_ m: ModelInfo) -> String {
        if isFree(m) { return "Free" }
        let f = { (v: Double) in v >= 10 ? String(format: "$%.0f", v) : String(format: "$%.2f", v) }
        return "\(f(m.pricing.input)) / \(f(m.pricing.output))"
    }

    static func context(_ m: ModelInfo) -> String {
        if m.contextWindow <= 0 { return "unknown" }
        return m.contextWindow >= 1_000_000 ? String(format: "%gM", (m.contextWindow / 100_000).rounded() / 10) : "\(Int(m.contextWindow / 1000))K"
    }
}

/// The agent rows' frames in the picker, where their submenus line up.
private struct AgentRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// A coding agent's models beside its row, drawn like a menu (docs/design/agent-picker/agent-submenu.html): ✓ on the one
/// in use, "Older models" folded below a line. The picker owns its state, so the keyboard and the pointer agree.
private struct AgentModelsMenu: View {
    let items: [ModelPicker.SubItem]
    let selected: ModelRef?
    let highlighted: Int?
    let onHover: (Int) -> Void
    let onPick: (ModelInfo) -> Void
    let onOlder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element) { i, item in
                if item.model == nil { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.horizontal, 6).padding(.vertical, 4) }
                Button { if let m = item.model { onPick(m) } else { onOlder() } } label: {
                    HStack(spacing: 6) {
                        Group {
                            if let m = item.model, m.ref == selected { Image(systemName: "checkmark").font(.system(size: 10.5, weight: .semibold)) }
                        }
                        .foregroundStyle(Color.dsFg2).frame(width: 12)
                        if let m = item.model {
                            Text(ModelPicker.shortName(m)).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                        } else {
                            Text("Older models").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                            Spacer(minLength: 8)
                            Text("\(item.older)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(highlighted == i ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { onHover(i) } }
            }
        }
        .padding(5)
        .frame(width: 200)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }
}

/// The window an agent's models open in: a borderless child panel of the picker's popover window, flush with the
/// picker's right edge (its left one when the screen ends), its first row level with the agent row. A SwiftUI popover
/// would bring an arrow and a gap. It never becomes key, so the search field keeps the keyboard.
@MainActor final class AgentSubmenu {
    static let space = "modelPicker"

    /// The picker's own view, to place the panel from the rows' frames.
    fileprivate weak var host: NSView?
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var task: Task<Void, Never>?
    /// The row under the pointer, if any.
    var hovered: String?
    /// The pointer's last two positions on screen, to tell whether it's heading for the panel.
    private var prev: NSPoint?
    private var now: NSPoint?

    func track(_ p: NSPoint) { if p != now { prev = now; now = p } }

    /// Runs `action` after `delay`, replacing what was waiting.
    func later(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { action() }
        }
    }

    func cancel() { task?.cancel(); task = nil }

    /// Whether the pointer is moving into the open panel: it lies in the triangle between where it was and the panel's
    /// near edge (with some slack above and below).
    func headingIn() -> Bool {
        guard let panel, panel.isVisible, let a = prev else { return false }
        let p = NSEvent.mouseLocation, f = panel.frame
        let edge = abs(f.minX - a.x) < abs(f.maxX - a.x) ? f.minX : f.maxX
        let b = NSPoint(x: edge, y: f.maxY + 20), c = NSPoint(x: edge, y: f.minY - 20)
        func side(_ p1: NSPoint, _ p2: NSPoint, _ p3: NSPoint) -> CGFloat { (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y) }
        let d1 = side(p, a, b), d2 = side(p, b, c), d3 = side(p, c, a)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }

    /// Shows `content` beside `row` (a frame in the picker's coordinate space), or updates it in place.
    func show(_ content: AnyView, row: CGRect) {
        guard let host, let window = host.window else { return }
        let panel = panel ?? makePanel()
        hosting?.rootView = content
        let size = hosting?.fittingSize ?? .zero
        let rowOnScreen = window.convertToScreen(host.convert(row, to: nil))
        let picker = window.convertToScreen(host.convert(host.bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? .infinite
        var x = picker.maxX - 2
        if x + size.width > visible.maxX { x = picker.minX - size.width + 2 }
        // The first model sits level with the row: the panel's padding above it.
        let y = max(visible.minY, min(rowOnScreen.maxY + 5 - size.height, visible.maxY - size.height))
        panel.appearance = window.effectiveAppearance
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    func close() {
        cancel()
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        let hosting = FirstClickHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Clicks land on the first try, though the panel is never key.
    private final class FirstClickHostingView: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// Hands the picker's view to the submenu. Flipped, so frames read top-down as in SwiftUI.
    struct Anchor: NSViewRepresentable {
        let submenu: AgentSubmenu
        func makeNSView(context: Context) -> NSView { let v = Flipped(); submenu.host = v; return v }
        func updateNSView(_ view: NSView, context: Context) { submenu.host = view }
        private final class Flipped: NSView { override var isFlipped: Bool { true } }
    }
}
