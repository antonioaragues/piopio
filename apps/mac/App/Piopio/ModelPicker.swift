import PiopioKit
import PiopioTranscript
import SwiftUI

/// The model picker (docs/design v2, 10a): search and capability filters, recent models first, then every model
/// grouped by its maker with a $–$$$ tier; batch and alias variants folded away; a detail pane for the highlighted one.
/// Keyboard: type to search, ↑↓ to move, ↩ to pick, ⌘↩ to pick and make it the default for `role`.
struct ModelPicker: View {
    let engine: EngineController
    let selected: ModelRef?
    var role: EngineController.ModelRole = .chat
    let onPick: (ModelRef) -> Void
    @State private var query = ""
    @State private var showVariants = false
    @State private var filter: Filter = .all
    @State private var highlighted: String?
    @FocusState private var searching: Bool
    @AppStorage("recentModels") private var recentRaw = ""

    enum Filter: String, CaseIterable { case all = "All", reasoning = "Reasoning", vision = "Vision", free = "Free" }

    private struct Section: Identifiable { let id: String; let title: String; let models: [ModelInfo] }

    var body: some View {
        VStack(spacing: 0) {
            search
            filters
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack(spacing: 0) {
                list
                Rectangle().fill(Color.dsLine).frame(width: 0.5)
                detail.frame(width: 300)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            footer
        }
        .frame(width: 760, height: 520)
        .background(Color.dsWin)
        .onAppear {
            searching = true
            highlighted = keys.first
        }
        .onChange(of: query) { _, _ in highlighted = keys.first }
        .onChange(of: filter) { _, _ in highlighted = keys.first }
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
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            SwiftUI.Section {
                                ForEach(section.models) { model in row(model, in: section.id) }
                            } header: {
                                Text(section.title.uppercased())
                                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.4).foregroundStyle(Color.dsFg3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                                    .background(Color.dsWin)
                            }
                        }
                        if sections.isEmpty {
                            Text(engine.models.isEmpty ? "Loading models…" : "No models match.")
                                .font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                                .frame(maxWidth: .infinity).padding(.top, 60)
                        }
                        if foldsVariants, hiddenVariants > 0 {
                            Button { showVariants = true } label: {
                                Text("Show batch and alias variants (\(hiddenVariants))").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .onChange(of: highlighted) { _, key in
                    if let key { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(key) } }
                }
            }
    }

    /// The highlighted model: who makes it, what it costs and what it can do.
    @ViewBuilder private var detail: some View {
        if let m = model(for: highlighted) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        MakerTile(maker: Self.maker(m), size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.shortName(m)).font(.system(size: 15, weight: .bold)).lineLimit(2)
                            Text(m.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    Text(Self.blurb(m)).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        priceTile("Input", m.pricing.input)
                        priceTile("Output", m.pricing.output)
                    }
                    VStack(spacing: 0) {
                        fact("Context", "\(Self.context(m)) tokens")
                        fact("Longest answer", "\(Self.tokens(m.maxOutputTokens)) tokens")
                        fact("Reasoning", m.supports.reasoning ? "Yes" : "No")
                        fact("Images", m.supports.vision ? "Reads them" : "No", last: m.billing == nil)
                        if let billing = m.billing { fact("Billed to", billing, last: true) }
                    }
                    .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
                    if engine.model(for: role) == m.ref {
                        Text("Your default for \(Self.roleName(role))").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    } else {
                        Button("Set as default for \(Self.roleName(role))") { engine.setModel(m.ref, for: role) }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.accentColor)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Pick a model to see its details.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func priceTile(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            Text(value == 0 ? "Free" : String(format: value >= 10 ? "$%.0f" : "$%.2f", value)).font(.system(size: 17, weight: .semibold).monospacedDigit())
            Text("per million tokens").font(.system(size: 10.5)).foregroundStyle(Color.dsFg3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 10))
    }

    private func fact(_ label: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                Spacer()
                Text(value).font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 12).frame(height: 32)
            if !last { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 12) }
        }
    }

    // MARK: Parts

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg3)
            TextField("Search \(engine.models.count) models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searching)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.dsFg3) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var filters: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    HStack(spacing: 4) {
                        switch f {
                        case .reasoning: Image(systemName: "brain").font(.system(size: 10))
                        case .vision: Image(systemName: "eye").font(.system(size: 10))
                        case .free: Image(systemName: "gift").font(.system(size: 10))
                        case .all: EmptyView()
                        }
                        Text(f.rawValue)
                    }
                }
                .buttonStyle(ChipStyle(active: filter == f))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text("$ under $2 · $$ under $15 · $$$ more, per million output tokens").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            Spacer()
            Text("↑↓ move · ↩ choose · ⌘↩ set as default").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private func row(_ model: ModelInfo, in section: String) -> some View {
        let key = "\(section)|\(model.provider)/\(model.id)"
        let isSelected = selected?.provider == model.provider && selected?.id == model.id
        let fg: Color = isSelected ? .white : Color.dsFg
        let fg3: Color = isSelected ? .white.opacity(0.75) : Color.dsFg3
        return Button { pick(model) } label: {
            HStack(spacing: 10) {
                MakerTile(maker: Self.maker(model))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(Self.shortName(model)).font(.system(size: 13, weight: isSelected ? .semibold : .medium)).foregroundStyle(fg).lineLimit(1)
                        if model.supports.reasoning { capability("brain", "Reasons before answering").foregroundStyle(fg3) }
                        if model.supports.vision { capability("eye", "Reads images").foregroundStyle(fg3) }
                    }
                    Text("\(multiProvider ? "via \(Self.providerTag(model))" : Self.maker(model)) · \(Self.context(model)) context").font(.system(size: 11)).foregroundStyle(fg3).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Self.tier(model))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? .white : Self.isFree(model) ? Color.dsGreen : Color.dsFg2)
                    .help(Self.price(model) + " per million tokens, input / output")
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : highlighted == key ? Color.dsAccentSoft : .clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .id(key)
        .onHover { if $0 { highlighted = key } }
    }

    private func capability(_ symbol: String, _ help: String) -> some View {
        Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.dsFg3).help(help)
    }

    // MARK: Data

    private var matching: [ModelInfo] {
        let terms = query.lowercased().split(separator: " ")
        return engine.models.filter { m in
            let hay = "\(m.name) \(m.id) \(m.provider) \(m.providerName ?? "") \(m.billing ?? "")".lowercased()
            guard terms.allSatisfy({ hay.contains($0) }) else { return false }
            switch filter {
            case .all: return true
            case .reasoning: return m.supports.reasoning
            case .vision: return m.supports.vision
            case .free: return Self.isFree(m)
            }
        }
    }

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    /// More than one provider connected: rows say which one, OpenRouter's sections say so too.
    private var multiProvider: Bool { Set(engine.models.map(\.provider)).subtracting(["faux"]).count > 1 }

    /// Batch and alias variants stay folded unless searching, filtering for free models, or asked for.
    private var foldsVariants: Bool { !showVariants && query.isEmpty && filter != .free }
    private var hiddenVariants: Int { matching.filter(Self.isVariant).count }

    private var sections: [Section] {
        let all = matching
        var out: [Section] = []
        if query.isEmpty {
            // The current model leads Recent.
            let keys = (selected.map { ["\($0.provider)/\($0.id)"] } ?? []) + recent
            var seen = Set<String>()
            let recents = keys.filter { seen.insert($0).inserted }.compactMap { key in all.first { "\($0.provider)/\($0.id)" == key } }
            if !recents.isEmpty { out.append(Section(id: "recent", title: "Recent", models: Array(recents.prefix(5)))) }
        }
        let listed = foldsVariants ? all.filter { !Self.isVariant($0) } : all
        // Providers other than OpenRouter first, one section each, titled with who bills (docs/spec/10 FR2):
        // the same model through two providers stays two choices.
        let direct = Dictionary(grouping: listed.filter { $0.provider != "openrouter" }, by: \.provider)
        let providerOrder = ["faux", "openai", "openai-api"]
        for provider in direct.keys.sorted(by: { (providerOrder.firstIndex(of: $0) ?? 9, $0) < (providerOrder.firstIndex(of: $1) ?? 9, $1) }) {
            let models = direct[provider]!
            let title = [Self.providerTag(models[0]), models[0].billing].compactMap { $0 }.joined(separator: " · ")
            out.append(Section(id: "provider:\(provider)", title: title, models: models.sorted { Self.shortName($0) < Self.shortName($1) }))
        }
        let routed = listed.filter { $0.provider == "openrouter" }
        let byMaker = Dictionary(grouping: routed, by: Self.maker)
        // Well-known makers first, then the rest by how many models they have; models by name within a maker.
        let rank = { (maker: String) in Self.knownMakers.firstIndex { $0.caseInsensitiveCompare(maker) == .orderedSame } ?? Self.knownMakers.count }
        let ordered = byMaker.keys.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : byMaker[a]!.count != byMaker[b]!.count ? byMaker[a]!.count > byMaker[b]!.count : a < b
        }
        for maker in ordered {
            out.append(Section(id: "maker:\(maker)", title: multiProvider ? "OpenRouter · \(maker)" : maker, models: byMaker[maker]!.sorted { Self.shortName($0) < Self.shortName($1) }))
        }
        return out
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
        m.contextWindow >= 1_000_000 ? String(format: "%gM", (m.contextWindow / 100_000).rounded() / 10) : "\(Int(m.contextWindow / 1000))K"
    }
}

/// A maker's tile: its initial on a color of its own (no brand logos).
private struct MakerTile: View {
    let maker: String
    var size: CGFloat = 28

    var body: some View {
        let hue = Double(maker.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        Text(String(maker.prefix(1)).uppercased())
            .font(.system(size: size * 0.43, weight: .bold, design: .rounded))
            .foregroundStyle(Color(hue: hue, saturation: 0.55, brightness: 0.55))
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.35, brightness: 0.95).opacity(0.55), in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }
}
