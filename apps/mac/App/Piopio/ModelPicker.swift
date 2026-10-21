import PiopioKit
import PiopioTranscript
import SwiftUI

/// The model picker (composer chip, Definition, Spaces, new session): search, capability filters, the current and
/// recent models first, then every model grouped by its maker, with context size and price per million tokens.
/// Keyboard: type to search, ↑↓ to move, ↩ to pick.
struct ModelPicker: View {
    let engine: EngineController
    let selected: ModelRef?
    let onPick: (ModelRef) -> Void
    @State private var query = ""
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
                    }
                    .padding(.bottom, 6)
                }
                .onChange(of: highlighted) { _, key in
                    if let key { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(key) } }
                }
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            footer
        }
        .frame(width: 520, height: 500)
        .background(Color.dsWin)
        .onAppear {
            searching = true
            highlighted = keys.first
        }
        .onChange(of: query) { _, _ in highlighted = keys.first }
        .onChange(of: filter) { _, _ in highlighted = keys.first }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            guard let model = model(for: highlighted) else { return .ignored }
            pick(model)
            return .handled
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
            Text("Prices per million tokens, input / output").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            Spacer()
            Text("↑↓ to move · ↩ to choose").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private func row(_ model: ModelInfo, in section: String) -> some View {
        let key = "\(section)|\(model.provider)/\(model.id)"
        let isSelected = selected?.provider == model.provider && selected?.id == model.id
        return Button { pick(model) } label: {
            HStack(spacing: 10) {
                MakerTile(maker: Self.maker(model))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(Self.shortName(model)).font(.system(size: 13, weight: isSelected ? .semibold : .medium)).foregroundStyle(Color.dsFg).lineLimit(1)
                        if model.supports.reasoning { capability("brain", "Reasons before answering") }
                        if model.supports.vision { capability("eye", "Reads images") }
                    }
                    Text("\(Self.maker(model)) · \(model.id)").font(.system(size: 11)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(Self.context(model))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.dsFg2)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Color.dsChip, in: Capsule())
                    .help("Context window")
                Text(Self.price(model))
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Self.isFree(model) ? Color.dsGreen : Color.dsFg2)
                    .frame(width: 92, alignment: .trailing)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor).opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(highlighted == key ? Color.dsAccentSoft : isSelected ? Color.dsChip : .clear)
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
            let hay = "\(m.name) \(m.id) \(m.provider)".lowercased()
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

    private var sections: [Section] {
        let all = matching
        var out: [Section] = []
        if query.isEmpty {
            if let s = selected, let current = all.first(where: { $0.provider == s.provider && $0.id == s.id }) {
                out.append(Section(id: "current", title: "Current", models: [current]))
            }
            let recents = recent.compactMap { key in all.first { "\($0.provider)/\($0.id)" == key } }
                .filter { !($0.provider == selected?.provider && $0.id == selected?.id) }
            if !recents.isEmpty { out.append(Section(id: "recent", title: "Recent", models: Array(recents.prefix(5)))) }
        }
        let byMaker = Dictionary(grouping: all, by: Self.maker)
        // Well-known makers first, then the rest by how many models they have; models by name within a maker.
        let rank = { (maker: String) in Self.knownMakers.firstIndex { $0.caseInsensitiveCompare(maker) == .orderedSame } ?? Self.knownMakers.count }
        let ordered = byMaker.keys.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : byMaker[a]!.count != byMaker[b]!.count ? byMaker[a]!.count > byMaker[b]!.count : a < b
        }
        for maker in ordered {
            out.append(Section(id: "maker:\(maker)", title: maker, models: byMaker[maker]!.sorted { Self.shortName($0) < Self.shortName($1) }))
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
        if let colon = m.name.firstIndex(of: ":") { return String(m.name[..<colon]).trimmingCharacters(in: .whitespaces) }
        if let slash = m.id.firstIndex(of: "/") { return String(m.id[..<slash]).capitalized }
        return m.provider.capitalized
    }

    static func shortName(_ m: ModelInfo) -> String {
        guard let colon = m.name.firstIndex(of: ":") else { return m.name }
        return String(m.name[m.name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    static func isFree(_ m: ModelInfo) -> Bool { m.pricing.input == 0 && m.pricing.output == 0 }

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

    var body: some View {
        let hue = Double(maker.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        Text(String(maker.prefix(1)).uppercased())
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color(hue: hue, saturation: 0.55, brightness: 0.55))
            .frame(width: 28, height: 28)
            .background(Color(hue: hue, saturation: 0.35, brightness: 0.95).opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
