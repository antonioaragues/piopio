import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Settings › Models (design handoff "Settings › Models", screens m0–m6): the page shows only what's in use —
// connected providers, servers found on this Mac, the default model per mode. Adding happens in a sheet with the
// whole catalog and custom endpoints; each provider has its own detail page for its key, models and removal.

/// What the Add provider sheet opens on.
enum AddProviderRoute: Identifiable, Hashable {
    case catalog
    case provider(String)
    case custom(String?)
    var id: String {
        switch self {
        case .catalog: "catalog"
        case .provider(let p): "provider:\(p)"
        case .custom(let preset): "custom:\(preset ?? "")"
        }
    }
}

/// Presets for custom endpoints (m4): where each server listens by default, and how to start it when it doesn't answer.
struct EndpointPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    let startHint: String

    static let all: [EndpointPreset] = [
        EndpointPreset(id: "lmstudio", name: "LM Studio", url: "http://localhost:1234/v1", startHint: "Is LM Studio's server running? In LM Studio: Developer › Start server."),
        EndpointPreset(id: "ollama", name: "Ollama", url: "http://localhost:11434/v1", startHint: "Is Ollama running? Open the Ollama app, or run “ollama serve”."),
        EndpointPreset(id: "litellm", name: "LiteLLM", url: "http://localhost:4000/v1", startHint: "Is the LiteLLM proxy running? Start it with “litellm --config config.yaml”."),
        EndpointPreset(id: "vllm", name: "vLLM", url: "http://localhost:8000/v1", startHint: "Is vLLM serving? Start it with “vllm serve <model>”."),
        EndpointPreset(id: "llamacpp", name: "llama.cpp", url: "http://localhost:8080/v1", startHint: "Is llama-server running? Start it with “llama-server -m <model.gguf>”."),
    ]

    static func find(_ id: String?) -> EndpointPreset? { all.first { $0.id == id } }
}

// MARK: - m1 / m0 · Models page

struct ModelsPane: View {
    let engine: EngineController
    @State private var detail: String?
    @State private var adding: AddProviderRoute?
    @State private var detected: [EndpointsDetectResult.Found] = []
    @State private var picking: EngineController.ModelRole?
    @AppStorage("dismissedLocalServers") private var dismissedRaw = ""

    private var connected: [ProviderInfo] { engine.providers.filter { $0.isConnected || $0.status == .connecting } }
    private var dismissed: Set<String> { Set(dismissedRaw.split(separator: "\n").map(String.init)) }
    /// Found on this Mac, not added, not dismissed.
    private var banner: EndpointsDetectResult.Found? {
        let added = Set(engine.providers.compactMap { $0.endpoint?.baseUrl })
        return detected.first { !added.contains($0.baseUrl) && !dismissed.contains($0.baseUrl) }
    }

    var body: some View {
        Group {
            if let id = detail, let provider = engine.providers.first(where: { $0.id == id }) {
                ProviderDetailView(engine: engine, provider: provider, back: { detail = nil })
            } else if connected.isEmpty, !engine.providers.isEmpty {
                empty
            } else {
                page
            }
        }
        .task {
            // Detection (design: on open, then every 60 s while Settings is open).
            while !Task.isCancelled {
                detected = await engine.detectEndpoints()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task {
            await engine.loadProviders()
            // Captures: PIOPIO_DEMO_ADD_PROVIDER=catalog | provider:<id> | custom:<preset>; PIOPIO_DEMO_PROVIDER_DETAIL=<id>.
            let env = ProcessInfo.processInfo.environment
            try? await Task.sleep(for: .seconds(1.5))
            if let id = env["PIOPIO_DEMO_PROVIDER_DETAIL"] { detail = id }
            if let route = env["PIOPIO_DEMO_ADD_PROVIDER"] {
                let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
                adding = parts[0] == "provider" ? .provider(parts[1]) : parts[0] == "custom" ? .custom(parts.count > 1 ? parts[1] : nil) : .catalog
            }
        }
        .sheet(item: $adding) { route in AddProviderSheet(engine: engine, start: route, detected: detected, done: { adding = nil }) }
        .sheet(isPresented: Binding(get: { engine.login != nil }, set: { if !$0 { Task { await engine.cancelLogin() } } })) {
            if let login = engine.login { ProviderSignInSheet(engine: engine, login: login) }
        }
    }

    // m1
    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Models").font(.system(size: 24, weight: .bold)).tracking(-0.4)
                    Text(subtitle).font(.system(size: 13.5)).foregroundStyle(Color.dsFg2)
                }
                Spacer()
                Button { adding = .catalog } label: {
                    Label("Add provider", systemImage: "plus").font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(PillStyle(kind: .strong))
            }
            .padding(.bottom, 20)

            Text("Connected").font(.system(size: 13, weight: .semibold)).padding(.bottom, 7)
            ListCard {
                ForEach(Array(connected.enumerated()), id: \.element.id) { i, p in
                    ConnectedProviderRow(engine: engine, provider: p) { detail = p.id }
                    if i < connected.count - 1 { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 62) }
                }
            }

            if let found = banner {
                DetectedBanner(found: found, add: { addDetected(found) }, dismiss: { dismissedRaw = (Array(dismissed) + [found.baseUrl]).joined(separator: "\n") })
                    .padding(.top, 14)
            }

            HStack {
                Text("Default model").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Any chat can still switch").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            .padding(.top, 22).padding(.bottom, 7)
            ListCard {
                roleRow(.build, "Build sessions")
                roleRow(.chat, "Chats and notebooks")
                roleRow(.quick, "Quick Chat")
                roleRow(.agent, "New agents", last: true)
            }
            Text("Billed to your own accounts. Keys stay in the macOS Keychain.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 12)
        }
    }

    private var subtitle: String {
        let count = connected.count
        let models = engine.models.filter { $0.provider != "faux" }.count
        var parts = ["\(count) provider\(count == 1 ? "" : "s")", "\(models) model\(models == 1 ? "" : "s")"]
        if let month = engine.usage?.monthUsd, month > 0 { parts.append("\(MainSidebar.money(month)) this month") }
        return parts.joined(separator: " · ")
    }

    private func roleRow(_ role: EngineController.ModelRole, _ title: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Button { picking = role } label: {
                    HStack(spacing: 5) {
                        if let m = engine.model(engine.model(for: role)) {
                            Text(ModelChip.short(m)).foregroundStyle(Color.dsFg)
                            Text(ModelPicker.providerTag(m)).foregroundStyle(Color.dsFg3)
                        } else {
                            Text(engine.model(for: role)?.id ?? "Choose…")
                        }
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dsFg3)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(PillStyle(compact: true))
                .popover(isPresented: Binding(get: { picking == role }, set: { if !$0 { picking = nil } })) {
                    ModelPicker(engine: engine, selected: engine.model(for: role), role: role) { m in engine.setModel(m, for: role); picking = nil }
                }
            }
            .padding(.horizontal, 14).frame(minHeight: 46)
            if !last { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 14) }
        }
    }

    private func addDetected(_ found: EndpointsDetectResult.Found) {
        Task { try? await engine.saveEndpoint(EndpointSaveParams(id: nil, name: found.name, baseUrl: found.baseUrl, key: nil)) }
    }

    // m0
    private var empty: some View {
        VStack(spacing: 0) {
            Text("Connect a model to get started").font(.system(size: 20, weight: .bold)).padding(.top, 40)
            Text("Piopio uses your own accounts. Pick one; you can add more later.").font(.system(size: 13.5)).foregroundStyle(Color.dsFg2).padding(.top, 6)
            VStack(spacing: 10) {
                optionRow(tile: "OR", color: Color(red: 0.39, green: 0.40, blue: 0.95), title: "OpenRouter", badge: "Recommended", line: "One key, 300+ models from every lab", action: "Connect", primary: true) {
                    adding = .provider("openrouter")
                }
                if let chatgpt = engine.providers.first(where: { $0.id == "openai" }) {
                    optionRow(tile: "GPT", color: Color(red: 0.06, green: 0.64, blue: 0.5), title: "ChatGPT subscription", badge: nil, line: "Sign in; usage counts against your plan", action: "Sign in", primary: false) {
                        Task { await engine.connect(chatgpt, method: .oauth) }
                    }
                }
                if let found = detected.first {
                    optionRow(tile: String(found.name.prefix(2)).uppercased(), color: .gray, title: found.name, badge: "Found on this Mac", line: "\(found.models) model\(found.models == 1 ? "" : "s") · free and private", action: "Add", primary: false, yolk: true) {
                        addDetected(found)
                    }
                }
            }
            .frame(maxWidth: 460)
            .padding(.top, 24)
            HStack(spacing: 18) {
                Button("Browse all providers…") { adding = .catalog }
                Button("Custom endpoint…") { adding = .custom(nil) }
            }
            .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private func optionRow(tile: String, color: Color, title: String, badge: String?, line: String, action: String, primary: Bool, yolk: Bool = false, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(tile).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsFg2)
                .frame(width: 34, height: 34).background(Color.dsChip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let badge { Text(badge).font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                }
                Text(line).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Spacer()
            Button(action, action: perform).buttonStyle(PillStyle(kind: primary ? .primary : .secondary, compact: true))
        }
        .padding(.horizontal, 14).frame(minHeight: 60)
        .settingsRows()
    }
}

/// One connected provider (m1): tile, name, status, Custom badge, what it is, spend; the whole row opens its page.
private struct ConnectedProviderRow: View {
    let engine: EngineController
    let provider: ProviderInfo
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ProviderGlyph(provider: provider, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dsFg)
                        Circle().fill(dotColor).frame(width: 7, height: 7)
                        if provider.endpoint != nil {
                            Text("Custom").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.dsFg2)
                                .padding(.horizontal, 6).frame(height: 18).background(Color.dsChip, in: Capsule())
                        }
                    }
                    subtitle
                }
                Spacer(minLength: 12)
                spend
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 14).frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }

    private var dotColor: Color {
        switch provider.status {
        case .connected: .dsFg3
        case .needsAttention: provider.message?.contains("answering") == true ? .dsFg2 : .dsAmber
        default: .dsFg3
        }
    }

    @ViewBuilder private var subtitle: some View {
        if provider.status == .needsAttention, let message = provider.message {
            Text(message).font(.system(size: 12)).foregroundStyle(dotColor).lineLimit(1)
        } else if let e = provider.endpoint {
            HStack(spacing: 0) {
                Text(ProvidersCard.host(e.baseUrl)).font(.system(size: 12, design: .monospaced))
                Text(" · \(e.local ? "This Mac" : "Your server") · \(provider.models) model\(provider.models == 1 ? "" : "s")").font(.system(size: 12))
            }
            .foregroundStyle(Color.dsFg3)
        } else {
            Text([ProviderGlyph.kindLabel(provider), provider.connectedWith == .oauth ? "Sign in" : "API key", "\(provider.models) models"].joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        }
    }

    @ViewBuilder private var spend: some View {
        if provider.id == "openrouter", let month = engine.usage?.monthUsd {
            figure(MainSidebar.money(month), "this month")
        } else if let e = provider.endpoint {
            figure(e.local ? "Free" : "Yours", e.local ? "runs locally" : "your server")
        } else if provider.connectedWith == .oauth, provider.billing?.contains("subscription") == true {
            figure("Plan", "subscription")
        }
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg)
            Text(caption).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
        }
    }
}

/// "Ollama is running on this Mac" (m1): Add, or Not now (remembered).
private struct DetectedBanner: View {
    let found: EndpointsDetectResult.Found
    let add: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            EndpointTile(name: found.name, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(found.name) is running on this Mac").font(.system(size: 13.5, weight: .semibold))
                HStack(spacing: 0) {
                    Text(ProvidersCard.host(found.baseUrl)).font(.system(size: 12, design: .monospaced))
                    Text(" · \(found.models) model\(found.models == 1 ? "" : "s") · free, nothing leaves your Mac").font(.system(size: 12))
                }
                .foregroundStyle(Color.dsFg2).lineLimit(1)
            }
            Spacer()
            Button("Not now", action: dismiss).buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            Button("Add", action: add).buttonStyle(PillStyle(kind: .strong, compact: true))
        }
        .padding(.horizontal, 14).frame(minHeight: 60)
        .background(Color.dsYolkSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A provider's tile: catalog providers by initials and color; endpoints by name.
struct ProviderGlyph: View {
    let provider: ProviderInfo
    var size: CGFloat = 34

    var body: some View {
        if provider.endpoint != nil { EndpointTile(name: provider.name, size: size) } else { ProviderTile(provider: provider, size: size) }
    }

    static func kindLabel(_ p: ProviderInfo) -> String {
        switch p.kind {
        case "subscription": "Subscription"
        case "platform": "Cloud platform"
        case "custom": "Custom"
        default: "Cloud"
        }
    }
}

// MARK: - m6 · Provider detail

struct ProviderDetailView: View {
    let engine: EngineController
    let provider: ProviderInfo
    let back: () -> Void
    @State private var models: [ProviderModelsResult.Model] = []
    @State private var query = ""
    @State private var filter = 0
    @State private var checking = false
    @State private var checked: Date?
    @State private var checkMessage: String?
    @State private var editing: Field?
    @State private var removing = false
    @State private var refreshing = false

    enum Field: String, Identifiable { case name, url, key, headers; var id: String { rawValue } }

    private var isCustom: Bool { provider.endpoint != nil }
    private var shownCount: Int { models.filter { !$0.hidden }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { back() } label: { Label("Models", systemImage: "chevron.left").font(.system(size: 12.5)) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).padding(.bottom, 14)
            HStack(spacing: 14) {
                ProviderGlyph(provider: provider, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.system(size: 22, weight: .bold))
                    statusLine
                }
                Spacer()
                Button { test() } label: { checking ? AnyView(ProgressView().controlSize(.small)) : AnyView(Text("Test connection")) }
                    .buttonStyle(PillStyle(compact: true)).disabled(checking)
            }
            .padding(.bottom, 18)

            ListCard {
                if isCustom { infoRow("Name", provider.name, action: "Rename") { editing = .name } }
                if let e = provider.endpoint {
                    infoRow("Base URL", e.baseUrl, mono: true, action: "Edit") { editing = .url }
                    infoRow("API format", e.format == "anthropic" ? "Anthropic" : "OpenAI-compatible", action: nil) {}
                }
                infoRow("API key", keyValue, mono: provider.keyHint != nil, note: provider.keyHint != nil ? "Keychain" : nil, action: provider.connectedWith == .oauth ? "Sign in again" : keyValue == "None" ? "Add" : "Replace") { replaceKey() }
                if let e = provider.endpoint {
                    infoRow("Headers", e.headers.map { $0.isEmpty ? "None" : $0.keys.sorted().joined(separator: ", ") } ?? "None", mono: e.headers?.isEmpty == false, action: e.headers?.isEmpty == false ? "Edit" : "Add", last: true) { editing = .headers }
                } else {
                    infoRow("Billed to", provider.billing ?? "—", action: nil, last: true) {}
                }
            }

            HStack {
                Text("Models").font(.system(size: 13, weight: .semibold))
                Text("\(shownCount) shown in the picker").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                Spacer()
                if isCustom || provider.id == "openrouter" {
                    Button(refreshing ? "Refreshing…" : "Refresh list") { refresh() }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor).disabled(refreshing)
                }
            }
            .padding(.top, 20).padding(.bottom, 7)
            if models.count > 12 {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                        TextField("Search \(models.count) models", text: $query).textFieldStyle(.plain).font(.system(size: 12.5))
                    }
                    .padding(.horizontal, 9).frame(height: 28).background(Color.dsChip, in: RoundedRectangle(cornerRadius: 8))
                    Picker("", selection: $filter) { Text("All").tag(0); Text("Shown").tag(1); Text("Hidden").tag(2) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Menu("Show only…") {
                        Button("Show all") { setAll(hidden: false) }
                        Button("Hide all") { setAll(hidden: true) }
                    }
                    .menuStyle(.button).buttonStyle(ChipStyle()).fixedSize()
                }
                .padding(.bottom, 8)
            }
            ListCard {
                let list = filtered
                if list.isEmpty {
                    Text(models.isEmpty ? "No models listed yet." : "Nothing matches.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity).frame(height: 44)
                }
                ForEach(Array(list.prefix(200).enumerated()), id: \.element.id) { i, m in
                    HStack(spacing: 10) {
                        Text(isCustom ? m.id : m.name).font(.system(size: 12.5, design: isCustom ? .monospaced : .default)).foregroundStyle(m.hidden ? Color.dsFg3 : Color.dsFg).lineLimit(1)
                        Spacer(minLength: 8)
                        if let use = usage(m.id) { Text(use).font(.system(size: 11.5)).foregroundStyle(Color.accentColor) }
                        Text(m.embedding == true ? "Embeddings" : m.contextWindow > 0 ? ModelPicker.tokens(m.contextWindow) : "").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Color.dsFg3).frame(width: 72, alignment: .trailing)
                        Toggle("", isOn: Binding(get: { !m.hidden }, set: { on in toggle(m.id, visible: on) })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                            .disabled(m.embedding == true)
                    }
                    .padding(.horizontal, 14).frame(height: 38)
                    if i < min(list.count, 200) - 1 { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 14) }
                }
                if list.count > 200 { Text("Showing 200 of \(list.count). Search to find the rest.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).padding(10) }
            }

            if provider.id == "openrouter", let month = engine.usage?.monthUsd {
                HStack {
                    Text("This month").font(.system(size: 13))
                    Text(MainSidebar.money(month)).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Link("Billing ›", destination: URL(string: "https://openrouter.ai/activity")!).font(.system(size: 12.5))
                }
                .padding(.top, 18)
            }

            Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.top, 22)
            HStack(alignment: .center) {
                Text(impact).font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button { removing = true } label: { Text("Remove provider…").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsFg2) }
                    .buttonStyle(PillStyle(compact: true))
            }
            .padding(.top, 12)
        }
        .task(id: provider.models) { models = await engine.providerModels(provider.id) }
        .sheet(item: $editing) { field in ProviderFieldSheet(engine: engine, provider: provider, field: field) }
        .alert("Remove \(provider.name)?", isPresented: $removing) {
            Button("Remove", role: .destructive) {
                Task {
                    if isCustom { await engine.removeEndpoint(provider) } else { await engine.disconnect(provider) }
                    back()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(impact) Its key is deleted from the Keychain.")
        }
    }

    @ViewBuilder private var statusLine: some View {
        let (color, state): (Color, String) = switch provider.status {
        case .connected: (.dsFg3, "Connected")
        case .needsAttention: (.dsAmber, provider.message ?? "Needs attention")
        default: (.dsFg3, "Not connected")
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text([state, checked.map { "checked \(MainSidebar.when($0.ISO8601Format()))" }, checkMessage, kindDetail].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(1)
        }
    }

    private var kindDetail: String {
        if let e = provider.endpoint { return "Custom, \(e.format == "anthropic" ? "Anthropic" : "OpenAI-compatible")" }
        return [ProviderGlyph.kindLabel(provider), provider.billing].compactMap { $0 }.joined(separator: ", ")
    }

    private var keyValue: String {
        if provider.connectedWith == .oauth { return "Signed in" }
        if let hint = provider.keyHint { return hint }
        return provider.endpoint?.keyless == true ? "None" : "Stored"
    }

    private var rolesUsing: [EngineController.ModelRole] { EngineController.ModelRole.allCases.filter { engine.model(for: $0)?.provider == provider.id } }

    private var impact: String {
        let names: [EngineController.ModelRole: String] = [.build: "Build sessions", .chat: "Chats and notebooks", .quick: "Quick Chat", .agent: "New agents"]
        let uses = rolesUsing.compactMap { names[$0] }
        guard !uses.isEmpty else { return "Nothing uses it as a default." }
        let fallback = engine.models.first { $0.provider != provider.id && $0.provider != "faux" }.map(ModelChip.short) ?? "another model"
        return "Used by \(ListFormatter.localizedString(byJoining: uses)). Removing it switches \(uses.count == 1 ? "it" : "them") to \(fallback)."
    }

    private func usage(_ model: String) -> String? {
        let names: [EngineController.ModelRole: String] = [.build: "Build", .chat: "Chats", .quick: "Quick Chat", .agent: "New agents"]
        let uses = EngineController.ModelRole.allCases.filter { engine.model(for: $0) == ModelRef(provider: provider.id, id: model) }.compactMap { names[$0] }
        return uses.isEmpty ? nil : "Default for \(ListFormatter.localizedString(byJoining: uses))"
    }

    private var filtered: [ProviderModelsResult.Model] {
        models.filter { m in
            (query.isEmpty || m.id.localizedCaseInsensitiveContains(query) || m.name.localizedCaseInsensitiveContains(query))
                && (filter == 0 || (filter == 1 ? !m.hidden : m.hidden))
        }
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false, note: String? = nil, action: String?, last: Bool = false, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).frame(width: 120, alignment: .leading)
                Text(value).font(.system(size: 12.5, design: mono ? .monospaced : .default)).lineLimit(1).truncationMode(.middle)
                if let note { Text("· \(note)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
                Spacer()
                if let action { Button(action, action: perform).buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            if !last { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 14) }
        }
    }

    private func replaceKey() {
        if provider.connectedWith == .oauth, let m = provider.methods.first(where: { $0.type == .oauth }) {
            Task { await engine.connect(provider, method: m.type) }
        } else {
            editing = .key
        }
    }

    private func test() {
        checking = true
        Task {
            if let e = provider.endpoint {
                let r = await engine.checkEndpoint(e.baseUrl, key: nil, id: provider.id)
                checkMessage = r?.ok == true ? r?.latencyMs.map { "\(Int($0)) ms" } : (r?.message ?? "Can't connect")
            } else {
                let r = await engine.verifyKey(provider.id, key: "")
                checkMessage = r?.ok == false ? (r?.message ?? "Rejected") : nil
                await engine.loadProviders()
            }
            checked = Date()
            checking = false
        }
    }

    private func refresh() {
        refreshing = true
        Task {
            if let e = provider.endpoint {
                try? await engine.saveEndpoint(EndpointSaveParams(id: provider.id, name: provider.name, baseUrl: e.baseUrl, key: nil, force: true))
            } else {
                try? await engine.loadModels()
            }
            models = await engine.providerModels(provider.id)
            refreshing = false
        }
    }

    private func toggle(_ id: String, visible: Bool) {
        var hidden = Set(models.filter { $0.hidden && $0.embedding != true }.map(\.id))
        if visible { hidden.remove(id) } else { hidden.insert(id) }
        if let i = models.firstIndex(where: { $0.id == id }) { models[i].hidden = !visible }
        Task { await engine.setHidden(provider.id, hidden: Array(hidden)) }
    }

    private func setAll(hidden: Bool) {
        let ids = hidden ? models.filter { $0.embedding != true }.map(\.id) : []
        for i in models.indices where models[i].embedding != true { models[i].hidden = hidden }
        Task { await engine.setHidden(provider.id, hidden: ids) }
    }
}

/// Rename, edit the URL, replace the key, or edit headers (m6 actions).
private struct ProviderFieldSheet: View {
    let engine: EngineController
    let provider: ProviderInfo
    let field: ProviderDetailView.Field
    @State private var text = ""
    @State private var headers: [HeaderRow] = []
    @State private var verify: ProviderVerifyResult?
    @State private var check: EndpointCheckResult?
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 17, weight: .bold))
            switch field {
            case .name:
                TextField("Name", text: $text).textFieldStyle(.roundedBorder)
            case .url:
                TextField("http://localhost:1234/v1", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                if let check { EndpointStatus(check: check) }
            case .key:
                SecureField(provider.keyHint ?? "Paste the new key", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                if let verify { KeyStatus(result: verify) }
                if let page = provider.keyPage, let url = URL(string: page) {
                    Link("Create a key at \(url.host() ?? page) ›", destination: url).font(.system(size: 12))
                }
            case .headers:
                HeadersEditor(rows: $headers)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction).disabled(busy || (field != .headers && text.trimmingCharacters(in: .whitespaces).isEmpty) || (field == .key && provider.endpoint == nil && verify?.ok == false))
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            switch field {
            case .name: text = provider.name
            case .url: text = provider.endpoint?.baseUrl ?? ""
            case .headers: headers = (provider.endpoint?.headers ?? [:]).sorted { $0.key < $1.key }.map { HeaderRow(name: $0.key, value: $0.value) }
            case .key: break
            }
        }
        .task(id: text) {
            guard field == .key || field == .url, !text.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            if field == .key, provider.endpoint == nil { verify = await engine.verifyKey(provider.id, key: text) }
            if field == .url { check = await engine.checkEndpoint(text, key: nil, id: provider.id) }
        }
    }

    private var title: String {
        switch field {
        case .name: "Rename \(provider.name)"
        case .url: "Base URL"
        case .key: provider.endpoint == nil ? "Replace the \(provider.name) key" : "API key for \(provider.name)"
        case .headers: "Headers"
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            do {
                if let e = provider.endpoint {
                    var params = EndpointSaveParams(id: provider.id, name: provider.name, baseUrl: e.baseUrl, key: nil, force: true)
                    switch field {
                    case .name: params.name = text
                    case .url: params.baseUrl = text; params.force = nil
                    case .key: params.key = text
                    case .headers: params.headers = Dictionary(headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) }, uniquingKeysWith: { _, b in b })
                    }
                    try await engine.saveEndpoint(params)
                } else {
                    try await engine.saveKey(provider.id, key: text)
                }
                dismiss()
            } catch {
                self.error = (error as? EngineError)?.message ?? error.localizedDescription
            }
            busy = false
        }
    }
}

struct HeaderRow: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var value: String
}

/// Custom headers, one per row.
struct HeadersEditor: View {
    @Binding var rows: [HeaderRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField("Header", text: $row.name).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 150)
                    TextField("Value", text: $row.value).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle").foregroundStyle(Color.dsFg3) }.buttonStyle(.plain)
                }
            }
            Button { rows.append(HeaderRow(name: "", value: "")) } label: { Label("Add header", systemImage: "plus") }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
            Text("Sent with every request. Put secrets in the API key field: it goes to the Keychain.").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
        }
    }
}

/// "✓ Valid · 9 models" or why not.
struct KeyStatus: View {
    let result: ProviderVerifyResult

    var body: some View {
        switch result.ok {
        case true?: Label("Valid\(result.models.map { " · \($0) models" } ?? "")", systemImage: "checkmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg3)
        case false?: Text(result.message ?? "This key was rejected.").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
        case nil: Text(result.message ?? "Checked on first use.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        }
    }
}

/// "● Reachable · 82 ms" or "● Can't connect".
struct EndpointStatus: View {
    let check: EndpointCheckResult

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(check.ok ? Color.dsFg3 : Color.dsFg2).frame(width: 6, height: 6)
            Text(check.ok ? "Reachable\(check.latencyMs.map { " · \(Int($0)) ms" } ?? "")" : "Can't connect").font(.system(size: 12, weight: .medium)).foregroundStyle(check.ok ? Color.dsFg3 : Color.dsFg2)
        }
    }
}

// MARK: - m2 · Add provider sheet

struct AddProviderSheet: View {
    let engine: EngineController
    let start: AddProviderRoute
    let detected: [EndpointsDetectResult.Found]
    let done: () -> Void
    @State private var page: AddProviderRoute = .catalog
    @State private var fromCatalog = false
    @State private var category: Category = .suggested
    @State private var query = ""
    @FocusState private var searching: Bool

    enum Category: String, CaseIterable { case suggested = "Suggested", cloud = "Cloud APIs", subscription = "Subscriptions", platform = "Cloud platforms", local = "Local & self-hosted" }

    private var catalog: [ProviderInfo] { engine.providers.filter { $0.endpoint == nil } }

    var body: some View {
        Group {
            switch page {
            case .catalog: catalogPage.frame(width: 800, height: 620)
            case .provider(let id):
                if let p = engine.providers.first(where: { $0.id == id }) {
                    ConnectProviderPage(engine: engine, provider: p, back: fromCatalog ? { page = .catalog } : nil, done: done).frame(width: 560)
                }
            case .custom(let preset):
                CustomEndpointPage(engine: engine, preset: EndpointPreset.find(preset), back: fromCatalog ? { page = .catalog } : nil, done: done).frame(width: 600)
            }
        }
        .onAppear { page = start }
    }

    private var catalogPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Add a provider").font(.system(size: 17, weight: .bold))
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    TextField("Search \(catalog.count) providers", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
                }
                .padding(.horizontal, 10).frame(height: 30).background(Color.dsChip, in: RoundedRectangle(cornerRadius: 8))
                Button("Cancel", action: done).buttonStyle(PillStyle(compact: true)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).frame(height: 56)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Category.allCases, id: \.self) { c in
                        Button { category = c; query = "" } label: {
                            HStack {
                                Text(c.rawValue).font(.system(size: 13))
                                Spacer()
                                if c != .suggested { Text("\(count(c))").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                            }
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(category == c && query.isEmpty ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.vertical, 6)
                    Button { fromCatalog = true; page = .custom(nil) } label: {
                        Label("Custom endpoint", systemImage: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.accentColor).padding(.horizontal, 10).frame(height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .frame(width: 190)
                .background(Color.dsChip.opacity(0.6))
                Rectangle().fill(Color.dsLine).frame(width: 0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { content }.padding(18)
                }
            }
        }
        .background(Color.dsWin)
        .onAppear { searching = true }
    }

    private func count(_ c: Category) -> Int {
        c == .local ? EndpointPreset.all.count : catalog.filter { ($0.kind ?? "cloud") == kind(c) }.count
    }

    private func kind(_ c: Category) -> String {
        switch c {
        case .subscription: "subscription"
        case .platform: "platform"
        default: "cloud"
        }
    }

    @ViewBuilder private var content: some View {
        if !query.isEmpty {
            let q = query.lowercased()
            let hits = catalog.filter { $0.name.lowercased().contains(q) || $0.id.contains(q) || ($0.families ?? []).contains { $0.hasPrefix(q) || q.hasPrefix($0) } }
            let presets = EndpointPreset.all.filter { $0.name.lowercased().contains(q) }
            if hits.isEmpty && presets.isEmpty { Text("No provider matches “\(query)”.").font(.system(size: 13)).foregroundStyle(Color.dsFg3) }
            grid(hits)
            if !presets.isEmpty { presetGrid(presets) }
            dontSeeYours
        } else {
            switch category {
            case .suggested:
                if !onThisMac.isEmpty {
                    section("On this Mac")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(onThisMac, id: \.0) { item in localCard(item) }
                    }
                }
                section("Popular")
                grid(["openrouter", "anthropic", "openai-api", "openai", "google", "amazon-bedrock"].compactMap { id in catalog.first { $0.id == id } })
                dontSeeYours
            case .local:
                presetGrid(EndpointPreset.all)
                dontSeeYours
            default:
                grid(catalog.filter { ($0.kind ?? "cloud") == kind(category) }.sorted { $0.name < $1.name })
            }
        }
    }

    /// Detected servers (not added) and local endpoints already added.
    private var onThisMac: [(String, EndpointsDetectResult.Found?, ProviderInfo?)] {
        let added = engine.providers.filter { $0.endpoint?.local == true }
        let addedUrls = Set(added.compactMap { $0.endpoint?.baseUrl })
        return detected.filter { !addedUrls.contains($0.baseUrl) }.map { ($0.baseUrl, $0, nil) } + added.map { ($0.id, nil, $0) }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
    }

    private func localCard(_ item: (String, EndpointsDetectResult.Found?, ProviderInfo?)) -> some View {
        HStack(spacing: 10) {
            EndpointTile(name: item.1?.name ?? item.2?.name ?? "", size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.1?.name ?? item.2?.name ?? "").font(.system(size: 13, weight: .semibold))
                Text(item.1.map { "Running · \($0.models) models" } ?? "Custom · \(ProvidersCard.host(item.2?.endpoint?.baseUrl ?? ""))").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            Spacer()
            if let found = item.1 {
                Button("Add") {
                    Task {
                        try? await engine.saveEndpoint(EndpointSaveParams(id: nil, name: found.name, baseUrl: found.baseUrl, key: nil))
                        done()
                    }
                }
                .buttonStyle(PillStyle(kind: .strong, compact: true))
            } else {
                Label("Added", systemImage: "checkmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg3)
            }
        }
        .padding(12)
        .background(item.1 != nil ? Color.dsYolkSoft : Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(item.1 != nil ? .clear : Color.dsLine, lineWidth: 0.5))
    }

    private func grid(_ providers: [ProviderInfo]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(providers) { p in
                Button { fromCatalog = true; page = .provider(p.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top) {
                            ProviderTile(provider: p, size: 28)
                            Spacer()
                            if p.isConnected { Label("Connected", systemImage: "checkmark").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dsFg3) }
                        }
                        Text(p.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg).padding(.top, 4)
                        Text(p.popular ?? "\(p.models) models").font(.system(size: 11.5)).foregroundStyle(Color.dsFg2).lineLimit(1)
                        Text(authLabel(p)).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    .settingsRows()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func presetGrid(_ presets: [EndpointPreset]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(presets) { preset in
                let found = detected.first { $0.baseUrl == preset.url }
                Button { fromCatalog = true; page = .custom(preset.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        EndpointTile(name: preset.name, size: 28)
                        Text(preset.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg).padding(.top, 4)
                        Text(found.map { "Running · \($0.models) models" } ?? ProvidersCard.host(preset.url)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg2)
                        Text("Free · runs on your machine").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    .background(found != nil ? Color.dsYolkSoft : Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(found != nil ? .clear : Color.dsLine, lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var dontSeeYours: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30).background(Color.dsAccentSoft, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Don't see yours?").font(.system(size: 13, weight: .semibold))
                Text("Any OpenAI- or Anthropic-compatible URL: LiteLLM, LM Studio, vLLM, a company gateway").font(.system(size: 11.5)).foregroundStyle(Color.dsFg2)
            }
            Spacer()
            Button("Custom endpoint…") { fromCatalog = true; page = .custom(nil) }.buttonStyle(PillStyle(compact: true))
        }
        .padding(12)
        .settingsRows()
    }

    private func authLabel(_ p: ProviderInfo) -> String {
        if p.kind == "platform" { return "Cloud credentials" }
        if p.methods.contains(where: { $0.type == .apiKey }) { return "API key" }
        return "Sign in"
    }
}

// MARK: - m3 · Connect a catalog provider

private struct ConnectProviderPage: View {
    let engine: EngineController
    let provider: ProviderInfo
    let back: (() -> Void)?
    let done: () -> Void
    @State private var key = ""
    @State private var result: ProviderVerifyResult?
    @State private var checking = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var usesKey: Bool { provider.kind != "platform" && provider.methods.contains { $0.type == .apiKey } }
    private var oauth: ProviderInfo.Method? { provider.methods.first { $0.type == .oauth } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let back { Button(action: back) { Label("All providers", systemImage: "chevron.left").font(.system(size: 12.5)) }.buttonStyle(.plain).foregroundStyle(Color.accentColor) }
            HStack(spacing: 12) {
                ProviderTile(provider: provider, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).font(.system(size: 19, weight: .bold))
                    Text(billsLine).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                }
            }
            if usesKey {
                VStack(alignment: .leading, spacing: 5) {
                    Text("API key").font(.system(size: 12.5, weight: .semibold))
                    HStack {
                        SecureField(provider.isConnected ? "Paste a new key to replace \(provider.keyHint ?? "the current one")" : "Paste your key", text: $key)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).focused($focused)
                        if checking { ProgressView().controlSize(.small) } else if let result { KeyStatus(result: result).fixedSize() }
                    }
                    .padding(.horizontal, 10).frame(height: 36)
                    .settingsRows()
                    HStack(spacing: 4) {
                        Text("Stored in your Keychain.").foregroundStyle(Color.dsFg3)
                        if let page = provider.keyPage, let url = URL(string: page) { Link("Create a key at \(url.host() ?? page) ›", destination: url) }
                    }
                    .font(.system(size: 12))
                }
                preview
            } else if let oauth {
                Text("You sign in with your \(provider.name) account in the browser. Usage counts against your plan, not an API account.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                Button { Task { await engine.connect(provider, method: oauth.type); done() } } label: { Text(oauth.label) }
                    .buttonStyle(PillStyle(kind: .primary))
            } else {
                Text("\(provider.name) uses your cloud account's credentials. Piopio asks for them step by step; they're stored in your Keychain.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                preview
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            HStack {
                Spacer()
                Button("Cancel", action: done).buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                if usesKey {
                    Button(busy ? "Connecting…" : "Connect") { connect() }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                        .disabled(busy || key.trimmingCharacters(in: .whitespaces).isEmpty || checking || result == nil || result?.ok == false)
                } else if oauth == nil, let m = provider.methods.first {
                    Button("Continue") { Task { await engine.connect(provider, method: m.type); done() } }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .onAppear { focused = true }
        .task(id: key) {
            result = nil
            guard usesKey, key.trimmingCharacters(in: .whitespaces).count > 8 else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            checking = true
            result = await engine.verifyKey(provider.id, key: key)
            checking = false
        }
    }

    private var billsLine: String {
        if provider.id == "openrouter" { return "Hundreds of models, billed to your OpenRouter credits" }
        if provider.kind == "subscription" { return "Uses your \(provider.name) plan" }
        let families = (provider.families ?? []).prefix(2).map(\.capitalized)
        return families.isEmpty ? "Billed by \(provider.name)" : "\(families.joined(separator: " and ")) models, billed by \(provider.name)"
    }

    private var preview: some View {
        let count = result?.models ?? provider.models
        let samples = provider.sampleModels ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(count) models available").font(.system(size: 12.5, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(samples, id: \.self) { s in
                    Text(s.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? s).font(.system(size: 11.5)).lineLimit(1)
                        .padding(.horizontal, 8).frame(height: 22).background(Color.dsCard, in: Capsule())
                }
                if count > samples.count { Text("+\(count - samples.count)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 10))
    }

    private func connect() {
        busy = true
        error = nil
        Task {
            do {
                try await engine.saveKey(provider.id, key: key)
                done()
            } catch {
                self.error = (error as? EngineError)?.message ?? error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - m4 / m5 · Custom endpoint

private struct CustomEndpointPage: View {
    let engine: EngineController
    let preset: EndpointPreset?
    let back: (() -> Void)?
    let done: () -> Void
    @State private var chosen: EndpointPreset?
    @State private var name = ""
    @State private var url = ""
    @State private var format = "openai"
    @State private var key = ""
    @State private var headers: [HeaderRow] = []
    @State private var context = ""
    @State private var advanced = false
    @State private var check: EndpointCheckResult?
    @State private var checking = false
    @State private var visible: [String: Bool] = [:]
    @State private var busy = false
    @State private var error: String?
    @FocusState private var keyFocused: Bool

    private var local: Bool { ["localhost", "127.0.0.1", "::1"].contains(URL(string: url)?.host() ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let back { Button(action: back) { Label("All providers", systemImage: "chevron.left").font(.system(size: 12.5)) }.buttonStyle(.plain).foregroundStyle(Color.accentColor) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Custom endpoint").font(.system(size: 19, weight: .bold))
                Text("Any server that speaks the OpenAI or Anthropic API").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            }
            HStack(spacing: 6) {
                Text("Start from").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                ForEach(EndpointPreset.all) { p in capsule(p.name, selected: chosen == p) { apply(p) } }
                capsule("Blank", selected: chosen == nil && !url.isEmpty && name.isEmpty == false && false) { apply(nil) }
            }
            ListCard {
                row("Name") { TextField("My server", text: $name).textFieldStyle(.plain) }
                row("Base URL", highlight: check?.ok == false) {
                    HStack {
                        TextField("http://localhost:4000/v1", text: $url).textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced))
                        if checking { ProgressView().controlSize(.small) } else if let check { EndpointStatus(check: check).fixedSize() }
                    }
                }
                row("API format") {
                    Picker("", selection: $format) { Text("OpenAI-compatible").tag("openai"); Text("Anthropic").tag("anthropic") }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                }
                row("API key") {
                    SecureField(keyPlaceholder, text: $key).textFieldStyle(.plain).font(.system(size: 12.5)).focused($keyFocused)
                }
                Button { withAnimation(.easeOut(duration: 0.15)) { advanced.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(advanced ? 90 : 0))
                        Text("Advanced").font(.system(size: 12.5))
                        Text("headers, context window").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                        Spacer()
                    }
                    .foregroundStyle(Color.dsFg2).padding(.horizontal, 14).frame(height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if advanced {
                    VStack(alignment: .leading, spacing: 10) {
                        HeadersEditor(rows: $headers)
                        HStack {
                            Text("Context window").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                            TextField("128000", text: $context).textFieldStyle(.roundedBorder).frame(width: 110)
                            Text("tokens, for models that don't report one").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
            if let check, !check.ok { help(check) }
            if let check, check.ok { found(check) }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            HStack {
                Text(local ? "Runs on this Mac · free" : "Runs on your network · free").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Spacer()
                Button("Cancel", action: done).buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(busy ? "Adding…" : "Add provider") { save(force: false) }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(busy || check?.ok != true)
            }
        }
        .padding(22)
        .onAppear { apply(preset) }
        .task(id: "\(url)|\(key)|\(format)|\(headers.map { "\($0.name)=\($0.value)" }.joined())") { await probe(delay: true) }
    }

    private var keyPlaceholder: String {
        if check?.error == "auth" { return "Required — the server wants a key" }
        if check?.ok == true, key.isEmpty { return "Optional — not needed for this server" }
        return "Optional"
    }

    private func capsule(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? Color.dsWin : Color.dsFg)
                .padding(.horizontal, 10).frame(height: 24).background(selected ? Color.dsFg : Color.dsChip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row<Content: View>(_ label: String, highlight: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).frame(width: 110, alignment: .leading)
                content()
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            .overlay(highlight ? RoundedRectangle(cornerRadius: 4).strokeBorder(Color.dsFg2, lineWidth: 1).padding(1) : nil)
            Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 14)
        }
    }

    /// Plain words for what went wrong, and what to do (m5).
    private func help(_ check: EndpointCheckResult) -> some View {
        let text: String = switch check.error {
        case "refused": chosen.map { "Nothing is listening at \(ProvidersCard.host(url)). \($0.startHint)" } ?? (check.message ?? "Nothing is answering.")
        case "auth": "The server wants an API key. Paste it in the API key field."
        case "not_found": check.message ?? "Reachable, but no model list."
        case "empty": "Connected, but no models are loaded on the server."
        case "tls": "The server's certificate isn't trusted. Use http:// for a local server, or a trusted certificate."
        default: check.message ?? "The server didn't answer as expected."
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Try again") { Task { await probe(delay: false) } }.buttonStyle(PillStyle(compact: true))
                if check.error != "auth" && check.error != "invalid" { Button("Add anyway") { save(force: true) }.buttonStyle(PillStyle(compact: true)) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRows()
        .onAppear { if check.error == "auth" { keyFocused = true } }
    }

    private func found(_ check: EndpointCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Found \(check.models.count) model\(check.models.count == 1 ? "" : "s")").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("Shown in the model picker").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            ListCard {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(check.models, id: \.id) { m in
                            HStack {
                                Text(m.id).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(m.embedding == true ? Color.dsFg3 : Color.dsFg).lineLimit(1)
                                Spacer()
                                if m.embedding == true {
                                    Text("Embeddings · hidden").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                                } else if let c = m.contextWindow {
                                    Text(ModelPicker.tokens(c)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Color.dsFg3)
                                }
                                Toggle("", isOn: Binding(get: { visible[m.id] ?? (m.embedding != true) }, set: { visible[m.id] = $0 })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                    .disabled(m.embedding == true)
                            }
                            .padding(.horizontal, 14).frame(height: 34)
                        }
                    }
                }
                .frame(maxHeight: 170)
            }
        }
    }

    private func apply(_ p: EndpointPreset?) {
        chosen = p
        name = p?.name ?? ""
        url = p?.url ?? ""
        format = "openai"
        check = nil
    }

    private func probe(delay: Bool) async {
        let address = url.trimmingCharacters(in: .whitespaces)
        guard address.count > 7 else { check = nil; return }
        if delay {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
        }
        checking = true
        let hdrs = Dictionary(headers.filter { !$0.name.isEmpty }.map { ($0.name, $0.value) }, uniquingKeysWith: { _, b in b })
        check = await engine.checkEndpoint(address, key: key.isEmpty ? nil : key, id: nil, format: format, headers: hdrs.isEmpty ? nil : hdrs)
        checking = false
    }

    private func save(force: Bool) {
        busy = true
        error = nil
        let hdrs = Dictionary(headers.filter { !$0.name.isEmpty }.map { ($0.name, $0.value) }, uniquingKeysWith: { _, b in b })
        let hidden = (check?.models ?? []).filter { !(visible[$0.id] ?? ($0.embedding != true)) }.map(\.id)
        let params = EndpointSaveParams(
            id: nil,
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? ProvidersCard.host(url) : name,
            baseUrl: url,
            key: key.isEmpty ? nil : key,
            format: format,
            headers: hdrs.isEmpty ? nil : hdrs,
            contextWindow: Double(context),
            hidden: hidden.isEmpty ? nil : hidden,
            force: force ? true : nil
        )
        Task {
            do {
                try await engine.saveEndpoint(params)
                done()
            } catch {
                self.error = (error as? EngineError)?.message ?? error.localizedDescription
            }
            busy = false
        }
    }
}
