import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// A provider sign-in in progress (docs/spec/10-model-providers FR1): pi runs it in the engine, this follows
/// its steps — a browser page, a device code, a key or a pasted code — until it's done or fails.
@MainActor @Observable final class ProviderLogin {
    let provider: ProviderInfo
    let method: ProviderInfo.Method.Kind
    var loginId: String?
    var url: URL?
    var instructions: String?
    var deviceCode: String?
    var verificationURL: URL?
    var progress: String?
    var info: String?
    var prompt: ProviderAuthEvent?
    var finished = false
    var error: String?

    init(provider: ProviderInfo, method: ProviderInfo.Method.Kind) {
        self.provider = provider
        self.method = method
    }

    func apply(_ event: ProviderAuthEvent) {
        switch event.type {
        case "auth_url":
            url = event.url.flatMap(URL.init(string:))
            instructions = event.instructions
            if let url { NSWorkspace.shared.open(url) }
        case "device_code":
            deviceCode = event.userCode
            verificationURL = event.verificationUri.flatMap(URL.init(string:))
        case "progress": progress = event.message
        case "info": info = event.message
        case "prompt": prompt = event
        case "prompt_closed": if prompt?.promptId == event.promptId { prompt = nil }
        case "done":
            finished = true
            error = nil
        case "failed":
            finished = true
            error = event.message ?? "Couldn't connect."
        default: break
        }
    }
}

/// Settings › Models › Providers: the featured providers, then every other one pi supports, folded.
struct ProvidersCard: View {
    let engine: EngineController
    @State private var showMore = false
    @State private var disconnecting: ProviderInfo?
    @State private var detected: [EndpointsDetectResult.Found] = []
    @State private var editing: EndpointDraft?
    @State private var adding: String?

    private var featured: [ProviderInfo] { engine.providers.filter(\.featured) }
    private var endpoints: [ProviderInfo] { engine.providers.filter { $0.endpoint != nil } }
    private var others: [ProviderInfo] { engine.providers.filter { !$0.featured && $0.endpoint == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ListCard {
                ForEach(Array(featured.enumerated()), id: \.element.id) { i, p in
                    ProviderRow(engine: engine, provider: p, disconnect: { disconnecting = p })
                    if i < featured.count - 1 { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 58) }
                }
                if featured.isEmpty {
                    Text(engine.client == nil ? "The engine isn't running." : "Loading providers…").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity).frame(height: 60)
                }
            }
            // Everything else, custom providers included: the ones you added and servers found on this Mac first,
            // then "Add a custom provider…", then pi's other providers (connected ones first).
            Button { withAnimation(.easeOut(duration: 0.15)) { showMore.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(showMore ? 90 : 0))
                    Text("More providers (\(others.count + endpoints.count))")
                    let connected = others.filter(\.isConnected).count + endpoints.count
                    if connected > 0 { Text("· \(connected) connected").foregroundStyle(Color.dsFg3) }
                    if !detected.isEmpty { Text("· \(detected.map(\.name).joined(separator: ", ")) found on this Mac").foregroundStyle(Color.dsFg3) }
                }
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsFg2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            if showMore {
                ListCard {
                    customRows
                    let sorted = others.sorted { $0.isConnected && !$1.isConnected }
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { i, p in
                        ProviderRow(engine: engine, provider: p, disconnect: { disconnecting = p })
                        if i < sorted.count - 1 { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 58) }
                    }
                }
                .padding(.top, 6)
            }
            Text("A ChatGPT subscription, the OpenAI API and OpenRouter credits are billed separately; each model in the picker says which one it uses.")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: Binding(get: { engine.login != nil }, set: { if !$0 { Task { await engine.cancelLogin() } } })) {
            if let login = engine.login { ProviderSignInSheet(engine: engine, login: login) }
        }
        .confirmationDialog(disconnecting.map { $0.endpoint == nil ? "Disconnect \($0.name)?" : "Remove \($0.name)?" } ?? "", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }), presenting: disconnecting) { p in
            Button(p.endpoint == nil ? "Disconnect" : "Remove", role: .destructive) { Task { p.endpoint == nil ? await engine.disconnect(p) : await engine.removeEndpoint(p) } }
        } message: { p in
            Text(disconnectMessage(p))
        }
        .onAppear { if !endpoints.isEmpty || others.contains(where: \.isConnected) { showMore = true } }
        .task(id: endpoints.count) { detected = await engine.detectEndpoints() }
        .sheet(item: $editing) { draft in EndpointSheet(engine: engine, draft: draft) }
    }

    /// Custom providers you added, servers found running on this Mac, and "Add a custom provider…".
    @ViewBuilder private var customRows: some View {
            ForEach(endpoints) { p in
                EndpointRow(engine: engine, provider: p, edit: { editing = EndpointDraft(provider: p) }, remove: { disconnecting = p })
                Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 58)
            }
            ForEach(detected, id: \.baseUrl) { found in
                HStack(spacing: 12) {
                    EndpointTile(name: found.name)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(found.name).font(.system(size: 13, weight: .semibold))
                            Text("Found on this Mac").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                        }
                        Text("\(Self.host(found.baseUrl)) · runs here, free · \(found.models) model\(found.models == 1 ? "" : "s")").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                    }
                    Spacer()
                    if adding == found.baseUrl {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add") {
                            adding = found.baseUrl
                            Task {
                                try? await engine.saveEndpoint(id: nil, name: found.name, baseUrl: found.baseUrl, key: nil)
                                adding = nil
                            }
                        }
                        .buttonStyle(PillStyle(compact: true))
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 60)
                Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 58)
            }
            Button { editing = EndpointDraft() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.dsAccentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add a custom provider…").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                        Text("Any OpenAI-compatible server: LiteLLM, Ollama, LM Studio, vLLM").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !others.isEmpty { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
    }

    static func host(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host() else { return url }
        return u.port.map { "\(host):\($0)" } ?? host
    }

    /// FR1: warn when the provider serves a default model; the others stay connected.
    private func disconnectMessage(_ p: ProviderInfo) -> String {
        if p.endpoint != nil { return "Its models leave the model picker\(p.endpoint?.keyless == false ? " and its key is removed from the Keychain" : ""). The server itself isn't touched." }
        let names: [EngineController.ModelRole: String] = [.build: "Build sessions", .chat: "chats and notebooks", .quick: "Quick Chat", .agent: "new agents"]
        let uses = EngineController.ModelRole.allCases.filter { engine.model(for: $0)?.provider == p.id }.compactMap { names[$0] }
        let base = "Its sign-in or key is removed from this Mac. Other providers stay connected."
        guard !uses.isEmpty else { return base + " Conversations using its models will ask you to pick another one." }
        return base + " It's your default for \(ListFormatter.localizedString(byJoining: uses)); pick another model in Default model below."
    }
}

/// One provider: its tile, how it's connected and who bills, and Connect or its ⋯ menu.
struct ProviderRow: View {
    let engine: EngineController
    let provider: ProviderInfo
    let disconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProviderTile(provider: provider)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.name).font(.system(size: 13, weight: .semibold))
                    status
                }
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(provider.status == .needsAttention ? Color.dsAmber : Color.dsFg3).lineLimit(2)
            }
            Spacer(minLength: 12)
            if provider.id == "openrouter", provider.isConnected, let month = engine.usage?.monthUsd {
                Text("\(MainSidebar.money(month)) this month").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
            }
            if provider.status == .connecting {
                ProgressView().controlSize(.small)
            } else if provider.isConnected {
                Menu {
                    ForEach(provider.methods, id: \.self) { m in
                        Button(m.type == .apiKey ? "Replace key…" : "Sign in again…") { Task { await engine.connect(provider, method: m.type) } }
                    }
                    Divider()
                    Button("Disconnect…", role: .destructive, action: disconnect)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsFg2).frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                if provider.status == .needsAttention, let m = provider.methods.first {
                    Button("Reconnect") { Task { await engine.connect(provider, method: m.type) } }.buttonStyle(PillStyle(kind: .primary, compact: true))
                }
            } else if provider.methods.count > 1 {
                Menu {
                    ForEach(provider.methods, id: \.self) { m in
                        Button(m.label) { Task { await engine.connect(provider, method: m.type) } }
                    }
                } label: { Text("Connect") }
                    .menuStyle(.button).buttonStyle(PillStyle(compact: true)).fixedSize()
            } else if let m = provider.methods.first {
                Button("Connect") { Task { await engine.connect(provider, method: m.type) } }.buttonStyle(PillStyle(compact: true))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
    }

    @ViewBuilder private var status: some View {
        switch provider.status {
        case .connected: Text("● Connected").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsGreen)
        case .needsAttention: Text("● Needs attention").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsAmber)
        case .connecting: Text("Connecting…").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsFg3)
        case .notConnected: EmptyView()
        }
    }

    private var subtitle: String {
        if provider.status == .needsAttention, let message = provider.message { return message }
        if let billing = provider.billing { return "\(billing) · \(provider.models) models" }
        return provider.methods.map(\.label).joined(separator: " or ")
    }
}

/// The provider's initials on a color of its own (no brand logos).
struct ProviderTile: View {
    let provider: ProviderInfo
    var size: CGFloat = 32

    var body: some View {
        let initials: String = switch provider.id {
        case "openrouter": "OR"
        case "openai": "GPT"
        case "openai-api": "API"
        default: String(provider.name.split(separator: " ").compactMap(\.first).prefix(2)).uppercased()
        }
        let hue = Double(provider.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        let color: Color = switch provider.id {
        case "openrouter": Color(red: 0.39, green: 0.40, blue: 0.95)
        case "openai", "openai-api": Color(red: 0.06, green: 0.64, blue: 0.5)
        default: Color(hue: hue, saturation: 0.55, brightness: 0.75)
        }
        Text(initials).font(.system(size: initials.count > 2 ? size * 0.28 : size * 0.36, weight: .bold, design: .rounded)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }
}

/// Connecting a provider: whatever step pi is on — a browser page, a device code, a key — then done or why not.
struct ProviderSignInSheet: View {
    let engine: EngineController
    let login: ProviderLogin
    @State private var text = ""
    @State private var copied = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProviderTile(provider: login.provider, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect \(login.provider.name)").font(.system(size: 17, weight: .bold))
                    Text(login.provider.methods.first { $0.type == login.method }?.label ?? "").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
            }
            Text(billingNote).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            content
            HStack {
                Spacer()
                if login.finished {
                    if login.error != nil {
                        Button("Close") { Task { await engine.cancelLogin() } }.buttonStyle(PillStyle())
                        Button("Try Again") { Task { await engine.connect(login.provider, method: login.method) } }.buttonStyle(PillStyle(kind: .primary))
                    } else {
                        Button("Done") { Task { await engine.cancelLogin() } }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("Cancel") { Task { await engine.cancelLogin() } }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                    if let prompt = login.prompt, prompt.kind != "select" {
                        Button("Continue") { submit() }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .onChange(of: login.prompt?.promptId) { _, _ in text = ""; focused = true }
    }

    @ViewBuilder private var content: some View {
        if login.finished {
            if let error = login.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Color.dsRed).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Connected. Its models are in the model picker now.", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsGreen)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let code = login.deviceCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter this code on the sign-in page:").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                        HStack(spacing: 10) {
                            Text(code).font(.system(size: 24, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Button(copied ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                                copied = true
                            }
                            .buttonStyle(PillStyle(compact: true))
                        }
                        if let url = login.verificationURL {
                            Button("Open \(url.host() ?? "the sign-in page")") { NSWorkspace.shared.open(url) }.buttonStyle(PillStyle(kind: .primary, compact: true))
                        }
                    }
                } else if let url = login.url {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(login.instructions ?? "Finish signing in in your browser. This sheet updates when you're done.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                        Button("Open the browser again") { NSWorkspace.shared.open(url) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                    }
                }
                if let prompt = login.prompt { promptView(prompt) }
                if login.prompt == nil, login.deviceCode == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(login.progress ?? (login.url == nil ? "Starting…" : "Waiting for the browser…")).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                    }
                }
                if let info = login.info { Text(info).font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    @ViewBuilder private func promptView(_ prompt: ProviderAuthEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt.message ?? "").font(.system(size: 12.5, weight: .medium))
            switch prompt.kind {
            case "select":
                VStack(spacing: 6) {
                    ForEach(prompt.options ?? [], id: \.id) { option in
                        Button { Task { await engine.answerLogin(option.id) } } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg)
                                if let d = option.description { Text(d).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            case "secret":
                SecureField(prompt.placeholder ?? "", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced)).focused($focused).onSubmit(submit)
            default:
                TextField(prompt.placeholder ?? (prompt.kind == "manual_code" ? "Paste the address the browser ended on" : ""), text: $text)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13)).focused($focused).onSubmit(submit)
            }
        }
    }

    private var billingNote: String {
        let p = login.provider
        if login.method == .oauth, login.provider.methods.first(where: { $0.type == .oauth })?.subscription == true {
            return "Requests use your \(p.id == "openai" ? "ChatGPT" : p.name) plan and its limits. They aren't billed to OpenRouter or an API account."
        }
        if p.id == "openai-api" { return "Requests are billed to the OpenAI API account this key belongs to, separately from a ChatGPT subscription." }
        return "Requests are billed to your \(p.name) account. The key is stored in the macOS Keychain."
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task { await engine.answerLogin(value) }
    }
}

/// What the endpoint sheet edits: a new endpoint, or an existing one (its key stays unless you type a new one).
struct EndpointDraft: Identifiable {
    let id = UUID()
    var providerId: String?
    var name = ""
    var baseUrl = ""
    var hasKey = false

    init() {}
    init(provider: ProviderInfo) {
        providerId = provider.id
        name = provider.name
        baseUrl = provider.endpoint?.baseUrl ?? ""
        hasKey = provider.endpoint?.keyless == false
    }
}

/// A custom endpoint's row: its address and who pays, then ⋯ (Edit, Check again, Remove).
struct EndpointRow: View {
    let engine: EngineController
    let provider: ProviderInfo
    let edit: () -> Void
    let remove: () -> Void
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 12) {
            EndpointTile(name: provider.name)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.name).font(.system(size: 13, weight: .semibold))
                    if problem == nil, provider.status == .connected {
                        Text("● Connected").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsGreen)
                    } else {
                        Text("● Needs attention").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsAmber)
                    }
                }
                Text(problem ?? provider.message ?? "\(ProvidersCard.host(provider.endpoint?.baseUrl ?? "")) · \(provider.billing ?? "Your server") · \(provider.models) model\(provider.models == 1 ? "" : "s")")
                    .font(.system(size: 11.5)).foregroundStyle(problem == nil ? Color.dsFg3 : Color.dsAmber).lineLimit(2)
            }
            Spacer(minLength: 12)
            if checking { ProgressView().controlSize(.small) }
            Menu {
                Button("Edit…", action: edit)
                Button("Check again") { recheck() }
                Divider()
                Button("Remove…", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsFg2).frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
    }

    /// Reads the server's models again (new ones appear, removed ones go).
    private func recheck() {
        guard let baseUrl = provider.endpoint?.baseUrl else { return }
        checking = true
        Task {
            do {
                try await engine.saveEndpoint(id: provider.id, name: provider.name, baseUrl: baseUrl, key: nil)
                problem = nil
            } catch {
                problem = (error as? EngineError)?.message ?? error.localizedDescription
            }
            checking = false
        }
    }
}

/// An endpoint's initials ("LiteLLM (home)" → "LH") on a color of its own.
struct EndpointTile: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        let words = name.split(separator: " ").map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        let initials = (words.count > 1 ? String(words[0].prefix(1) + words[1].prefix(1)) : String(words.first?.prefix(2) ?? "?")).uppercased()
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        Text(initials).font(.system(size: size * 0.36, weight: .bold, design: .rounded))
            .foregroundStyle(Color(hue: hue, saturation: 0.6, brightness: 0.45))
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.3, brightness: 0.95), in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }
}

/// "Add a custom endpoint" (sketch 2): name, address, key; checks the server's models before saving.
struct EndpointSheet: View {
    let engine: EngineController
    @State var draft: EndpointDraft
    @State private var key = ""
    @State private var check: EndpointCheckResult?
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(engine: EngineController, draft: EndpointDraft) {
        self.engine = engine
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.providerId == nil ? "Add a custom provider" : "Edit \(draft.name)").font(.system(size: 17, weight: .bold))
                Text("Any server that speaks the OpenAI API: LiteLLM, Ollama, LM Studio, vLLM. Its models show up in the model picker.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            }
            field("Name") { TextField("LiteLLM (home)", text: $draft.name).textFieldStyle(.roundedBorder) }
            field("Address") {
                TextField("http://localhost:4000/v1", text: $draft.baseUrl).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                    .onChange(of: draft.baseUrl) { _, _ in check = nil }
            }
            field(draft.hasKey ? "Key (leave empty to keep the current one)" : "Key (optional)") {
                SecureField(draft.hasKey ? "••••••••" : "Only if the server asks for one", text: $key).textFieldStyle(.roundedBorder)
                    .onChange(of: key) { _, _ in check = nil }
            }
            status
            HStack {
                Button("Check") { runCheck() }.buttonStyle(PillStyle()).disabled(draft.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(draft.providerId == nil ? "Add provider" : "Save") { save() }
                    .buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(draft.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    @ViewBuilder private var status: some View {
        if busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking the server for its models…").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3) }
        } else if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Color.dsRed).fixedSize(horizontal: false, vertical: true)
        } else if let check {
            if check.ok {
                let names = check.models.prefix(3).map(\.id).joined(separator: ", ")
                Label("Found \(check.models.count) model\(check.models.count == 1 ? "" : "s"): \(names)\(check.models.count > 3 ? "…" : "")", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsGreen).lineLimit(2)
            } else {
                Label(check.message ?? "The server didn't answer as expected.", systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Color.dsRed).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
            content()
        }
    }

    private var typedKey: String? { key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : key.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func runCheck() {
        busy = true
        error = nil
        Task {
            check = await engine.checkEndpoint(draft.baseUrl, key: typedKey, id: draft.providerId)
            if let resolved = check?.baseUrl, check?.ok == true { draft.baseUrl = resolved; check = check }
            busy = false
        }
    }

    private func save() {
        busy = true
        error = nil
        let name = draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? ProvidersCard.host(draft.baseUrl) : draft.name
        Task {
            do {
                try await engine.saveEndpoint(id: draft.providerId, name: name, baseUrl: draft.baseUrl, key: typedKey)
                dismiss()
            } catch {
                self.error = (error as? EngineError)?.message ?? error.localizedDescription
            }
            busy = false
        }
    }
}
