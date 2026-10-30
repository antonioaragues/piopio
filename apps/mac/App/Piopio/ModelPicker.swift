import PiopioKit
import PiopioTranscript
import SwiftUI

/// The model picker (docs/design/grey 11f): a search field, a group per provider, one plain line for each model, ✓ on the
/// current one, whatever the caller adds (Thinking), and Manage providers. Recently used models lead their group; batch
/// and alias variants stay folded until you search. Searching also matches "free", "vision" and "reasoning".
/// Keyboard: type to search, ↑↓ to move, ↩ to pick, ⌘↩ to pick and make it the default for `role`.
struct ModelPicker: View {
    let engine: EngineController
    let selected: ModelRef?
    var role: EngineController.ModelRole = .chat
    /// Shown between the list and Manage providers (the composer's Thinking control).
    var accessory: AnyView?
    let onPick: (ModelRef) -> Void
    @State private var query = ""
    @State private var showVariants = false
    @State private var highlighted: String?
    @FocusState private var searching: Bool
    @AppStorage("recentModels") private var recentRaw = ""

    private struct Section: Identifiable { let id: String; let title: String; let models: [ModelInfo] }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search models", text: $query)
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
                Button("Manage providers") {
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
        .onAppear {
            searching = true
            highlighted = keys.first { $0.hasSuffix("|\(selected?.provider ?? "")/\(selected?.id ?? "")") } ?? keys.first
        }
        .onChange(of: query) { _, _ in highlighted = keys.first }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return, phases: .down) { press in
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
                    ForEach(sections) { section in
                        Text(section.title).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
                        ForEach(section.models) { model in row(model, in: section.id) }
                    }
                    if sections.isEmpty {
                        Text(engine.models.isEmpty ? "Loading models…" : "No models match.")
                            .font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    if foldsVariants, hiddenVariants > 0 {
                        Button("Show \(hiddenVariants) more variants") { showVariants = true }
                            .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                            .padding(.horizontal, 10).padding(.vertical, 8)
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

    private func row(_ model: ModelInfo, in section: String) -> some View {
        let key = "\(section)|\(model.provider)/\(model.id)"
        let isSelected = selected?.provider == model.provider && selected?.id == model.id
        return Button { pick(model) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.shortName(model)).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                    Text(line(model)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                Spacer(minLength: 8)
                if isSelected { Image(systemName: "checkmark").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dsFg2) }
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(isSelected || highlighted == key ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(key)
        .help("\(model.id)\n\(Self.price(model)) per million tokens, input / output · \(Self.context(model)) context")
        .onHover { if $0 { highlighted = key } }
        .contextMenu { Button("Set as Default for \(Self.roleName(role))") { engine.setModel(model.ref, for: role) } }
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

    private var matching: [ModelInfo] {
        let terms = query.lowercased().split(separator: " ")
        return engine.models.filter { m in
            let traits = (Self.isFree(m) ? "free " : "") + (m.supports.vision ? "vision images " : "") + (m.supports.reasoning ? "reasoning thinking " : "")
            let hay = "\(m.name) \(m.id) \(m.provider) \(m.providerName ?? "") \(m.billing ?? "") \(traits)".lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    /// Batch and alias variants stay folded unless searching or asked for.
    private var foldsVariants: Bool { !showVariants && query.isEmpty }
    private var hiddenVariants: Int { matching.filter(Self.isVariant).count }

    /// A group per provider, OpenRouter first. In a group: what you used lately, then the known makers, then the rest.
    private var sections: [Section] {
        let listed = foldsVariants ? matching.filter { !Self.isVariant($0) || ($0.provider == selected?.provider && $0.id == selected?.id) } : matching
        let recents = (selected.map { ["\($0.provider)/\($0.id)"] } ?? []) + recent
        let order = ["openrouter", "faux", "openai", "openai-api"]
        let groups = Dictionary(grouping: listed, by: \.provider)
        return groups.keys.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }.map { provider in
            let models = groups[provider]!.sorted { a, b in
                let ra = query.isEmpty ? recents.firstIndex(of: "\(a.provider)/\(a.id)") ?? 99 : 99, rb = query.isEmpty ? recents.firstIndex(of: "\(b.provider)/\(b.id)") ?? 99 : 99
                if ra != rb { return ra < rb }
                let ma = Self.makerRank(a), mb = Self.makerRank(b)
                return ma != mb ? ma < mb : Self.shortName(a) < Self.shortName(b)
            }
            return Section(id: "provider:\(provider)", title: Self.providerTag(models[0]), models: models)
        }
    }

    private static func makerRank(_ m: ModelInfo) -> Int {
        knownMakers.firstIndex { $0.caseInsensitiveCompare(maker(m)) == .orderedSame } ?? knownMakers.count
    }

    /// Row keys in display order (keyboard navigation).
    private var keys: [String] {
        sections.flatMap { s in s.models.map { "\(s.id)|\($0.provider)/\($0.id)" } }
    }

    private func model(for key: String?) -> ModelInfo? {
        guard let key, let ref = key.split(separator: "|", maxSplits: 1).last else { return nil }
        return engine.models.first { "\($0.provider)/\($0.id)" == ref }
    }

    private func move(_ by: Int) {
        let all = keys
        guard !all.isEmpty else { return }
        let i = highlighted.flatMap { all.firstIndex(of: $0) } ?? -1
        highlighted = all[max(0, min(all.count - 1, i + by))]
    }

    private func pick(_ model: ModelInfo) {
        let key = "\(model.provider)/\(model.id)"
        recentRaw = ([key] + recent.filter { $0 != key }).prefix(8).joined(separator: "\n")
        onPick(model.ref)
    }

    // MARK: Formatting

    private static let knownMakers = ["Anthropic", "OpenAI", "Google", "xAI", "Meta", "Mistral", "DeepSeek", "Qwen", "Moonshot", "Z.ai"]

    /// "Anthropic: Claude Haiku 5.5" → "Anthropic"; otherwise the id's vendor ("anthropic/…") or the provider.
    static func maker(_ m: ModelInfo) -> String {
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

    static func shortName(_ m: ModelInfo) -> String {
        guard let colon = m.name.firstIndex(of: ":") else { return m.name }
        return String(m.name[m.name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    static func isFree(_ m: ModelInfo) -> Bool { m.pricing.input == 0 && m.pricing.output == 0 }

    /// "$" under $2, "$$" under $15, "$$$" above, per million output tokens; "Plan" when a subscription pays.
    static func tier(_ m: ModelInfo) -> String {
        if m.billing?.contains("subscription") == true { return "Plan" }
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
        case .chat: "chats and notebooks"
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
