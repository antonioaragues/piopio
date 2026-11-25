import PiopioKit
import PiopioTranscript
import SwiftUI

/// Settings (docs/design v2, 9a): a grouped sidebar of sections; models and engines are lists of cards.
struct SettingsView: View {
    let engine: EngineController
    // PIOPIO_DEMO_SETTINGS_SECTION=General|Models|Engines picks the first section (captures).
    @State private var section: Section = Section(demo: ProcessInfo.processInfo.environment["PIOPIO_DEMO_SETTINGS_SECTION"] ?? "") ?? .providers

    enum Section: String, CaseIterable, Identifiable {
        case general = "General", providers = "Models", connectors = "Connectors", chat = "Chat", memory = "Memory", approvals = "Approvals", github = "Git & GitHub", mcp = "MCP servers", browser = "Browser", extensions = "Extensions", engines = "This Mac & cloud", data = "Backup"
        var id: String { rawValue }
        init?(demo: String) {
            switch demo {
            case "Providers": self = .providers
            case "Engines": self = .engines
            default: self.init(rawValue: demo)
            }
        }
        static let groups: [(String?, [Section])] = [(nil, [.general, .providers, .connectors, .chat, .browser, .memory, .approvals, .github, .data]), ("Extend", [.mcp, .extensions]), ("Where it runs", [.engines])]
        /// The sidebar's symbol, in ink like the text (docs/design/grey: nothing gets a color but status).
        var icon: String {
            switch self {
            case .data: "externaldrive"
            case .general: "gearshape"
            case .providers: "sparkles"
            case .connectors: "app.connected.to.app.below.fill"
            case .chat: "bubble.left.and.bubble.right"
            case .memory: "brain.head.profile"
            case .extensions: "shippingbox"
            case .approvals: "checkmark.shield"
            case .github: "arrow.triangle.pull"
            case .mcp: "puzzlepiece.extension"
            case .browser: "globe"
            case .engines: "cpu"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(Section.groups.enumerated()), id: \.offset) { _, group in
                    if let title = group.0 {
                        Text(title).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
                    }
                    ForEach(group.1) { s in
                    Button { section = s } label: {
                        HStack(spacing: 8) {
                            Image(systemName: s.icon).font(.system(size: 12.5)).foregroundStyle(section == s ? Color.dsFg : Color.dsFg2).frame(width: 18)
                            Text(s.rawValue).font(.system(size: 13)).foregroundStyle(section == s ? Color.dsFg : Color.dsFg2)
                            // Nothing to think with yet (design m0): an amber dot on Models.
                            if s == .providers, !engine.faux, !engine.providers.isEmpty, !engine.providers.contains(where: \.isConnected) {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 29)
                        .background(section == s ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .padding(.top, 14)
            .padding(.horizontal, 8)
            .frame(width: 200)
            .frame(maxHeight: .infinity, alignment: .top)

            // The pane in a content card over the window, as in the main window (docs/design/card-layout).
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch section {
                    case .data: DataPane(engine: engine)
                    case .general: GeneralPane(engine: engine)
                    case .providers: ModelsPane(engine: engine)
                    case .connectors: ConnectorsPane(engine: engine)
                    case .chat: ChatPane(engine: engine)
                    case .memory: MemoryPane(engine: engine)
                    case .extensions: ExtensionsPane(engine: engine)
                    case .approvals: ApprovalsPane(engine: engine)
                    case .github: GitHubPane(engine: engine)
                    case .mcp: McpPane(engine: engine)
                    case .browser: BrowserSettingsPane(engine: engine)
                    case .engines: EnginesPane(engine: engine)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentCard()
            .padding([.top, .bottom, .trailing], CardLayout.margin)
        }
        .frame(width: 820, height: 560)
        .background(Color.dsSide)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear(perform: openRequested)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in openRequested() }
        .onReceive(NotificationCenter.default.publisher(for: .settingsSection)) { note in
            if let raw = note.object as? String, let s = Section(rawValue: raw) { section = s }
        }
    }

    /// Home's areas tip opens Settings on General.
    private func openRequested() {
        guard let raw = UserDefaults.standard.string(forKey: "settingsSection"), let s = Section(rawValue: raw) else { return }
        UserDefaults.standard.removeObject(forKey: "settingsSection")
        section = s
    }
}

/// Rows inside a card list, separated by hairlines.
struct ListCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .settingsRows()
    }
}

// MARK: General

private struct GeneralPane: View {
    let engine: EngineController
    @State private var tick = 0
    private let updater = AppUpdater.shared

    var body: some View {
        SettingsHeader(title: "General", summary: "What Piopio shows, how it looks, and how it reaches you.")
        AreasCard(engine: engine) {
            NSApp.keyWindow?.performClose(nil)
            NotificationCenter.default.post(name: .runSetupAgain, object: nil)
        }
        CardTitle("App")
        ListCard {
            SettingRow(title: "Appearance", subtitle: AppAppearance.current == .system ? "Follows macOS" : "Just for Piopio") {
                NeutralSegmented(selection: Binding(get: { AppAppearance.current }, set: { $0.save(); tick += 1 }),
                                 options: AppAppearance.allCases.map { (value: $0, title: $0.title) })
                    .frame(width: 220)
                    .accessibilityLabel("Appearance")
            }
            SettingRow(title: "Quick Chat", subtitle: "Opens from any app") {
                Picker("", selection: Binding(get: { QuickChatShortcut.current }, set: { value in
                    UserDefaults.standard.set(value.rawValue, forKey: "quickChatShortcut")
                    QuickChatController.shared?.applyShortcut()
                    tick += 1
                })) {
                    ForEach(QuickChatShortcut.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            ToggleRow(title: "Notifications", subtitle: "When an answer finishes or fails while I'm elsewhere", isOn: Binding(get: { Notifier.enabled }, set: { UserDefaults.standard.set($0, forKey: "notifyAnswers"); tick += 1 }))
            SettingRow(title: "Open files in", subtitle: Editor.installed.isEmpty ? "No supported editor found (Zed, VS Code, Cursor, Xcode, Sublime Text)" : "Build's “Open in” and the file viewer") {
                if !Editor.installed.isEmpty {
                    Picker("", selection: Binding(get: { Editor.preferred?.id ?? "" }, set: { UserDefaults.standard.set($0, forKey: "editor"); tick += 1 })) {
                        ForEach(Editor.installed) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if updater.isConfigured {
                SettingRow(title: "Check for updates automatically", subtitle: "Version \(updater.version)", last: true) {
                    Button("Check Now") { updater.checkForUpdates() }
                        .buttonStyle(PillStyle(compact: true))
                        .disabled(!updater.canCheck)
                    Toggle("", isOn: Binding(get: { updater.checksAutomatically }, set: { updater.checksAutomatically = $0 }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
            } else {
                SettingRow(title: "Updates", subtitle: "Version \(updater.version) · this build doesn't update itself", last: true) { EmptyView() }
            }
        }
        .id(tick)
    }
}

// MARK: Approvals

/// Per project: the approval mode new sessions start with, and the "Always allow" rules (docs/spec/05-build §6, AP2).
/// The page lists projects, one row each, with a search once there are many; each opens its own page, so the page
/// stays the same size however many projects there are.
private struct ApprovalsPane: View {
    let engine: EngineController
    @State private var open: String?
    @State private var query = ""

    var body: some View {
        Group {
            if let id = open, let project = engine.projects.first(where: { $0.id == id }) {
                ProjectApprovalsPage(engine: engine, project: project) { open = nil }
            } else {
                main
            }
        }
        .task { if engine.settings == nil { await engine.loadSettings() } }
        .task {
            // PIOPIO_DEMO_APPROVALS_PROJECT=<name>: captures open that project's page.
            guard let name = ProcessInfo.processInfo.environment["PIOPIO_DEMO_APPROVALS_PROJECT"] else { return }
            if engine.projects.isEmpty { await engine.loadProjects() }
            open = engine.projects.first { $0.name == name }?.id
        }
    }

    private var shown: [ProjectInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? engine.projects : engine.projects.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "Approvals", summary: "What Build sessions may do without asking. Risky commands always ask.")
            CardTitle("All projects")
            ListCard {
                ToggleRow(title: "Keep commands inside the project", subtitle: "They read and use the network (filtered in a project you haven't trusted), but writing outside the project asks", isOn: Binding(get: { engine.settings?.build?.sandbox ?? true }, set: { v in
                    Task { await engine.updateSettings(SettingsPatch(build: .init(sandbox: v))) }
                }))
                .help("Commands run in macOS's sandbox: they can read and use the network, but only write in the project, temporary folders and package caches. To write elsewhere they ask you first. In a project you haven't trusted, the network is filtered too: package registries, GitHub and the sites you allow. Off, they run with full access.")
                ToggleRow(title: "Auto review", subtitle: "In Auto-edit, the model runs clearly safe commands instead of asking you", last: true, isOn: Binding(get: { engine.settings?.build?.autoReview ?? false }, set: { v in
                    Task { await engine.updateSettings(SettingsPatch(build: .init(autoReview: v))) }
                }))
                .help("Before asking you about a command, the session's own model looks at it and runs the clearly safe ones. It costs a request per command and can be wrong; risky commands still ask.")
            }
            CardTitle(title: "Projects", detail: engine.projects.isEmpty ? nil : "\(engine.projects.count)") {
                if engine.projects.count > 6 {
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 180)
                }
            }
            .padding(.top, 22)
            if engine.projects.isEmpty {
                FinePrint("Add a project in Build to set its approvals.")
            } else if shown.isEmpty {
                FinePrint("No project matches “\(query)”.")
            } else {
                ListCard {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, project in
                        SettingsListRow(name: project.name, dot: project.waitsForTrust ? .dsAmber : nil, open: { open = project.id }) {
                            MemoryTile(symbol: "folder", color: .gray)
                        } subtitle: {
                            Text(Self.line(project))
                        } trailing: { EmptyView() }
                        if i < shown.count - 1 { RowDivider() }
                    }
                }
            }
            if !engine.projects.isEmpty {
                FinePrint("Rules come from “Always for …” on an approval card and apply to every session in the project.").padding(.top, 12)
            }
        }
    }

    /// "Auto-edit · 3 rules", "Ask · not trusted".
    static func line(_ project: ProjectInfo) -> String {
        let rules = project.rules.count
        var parts = [ApprovalModeMenu.title(project.approvalMode)]
        if rules > 0 { parts.append("\(rules) rule\(rules == 1 ? "" : "s")") }
        if project.waitsForTrust { parts.append("trust not decided") } else if project.trust == .untrusted { parts.append("not trusted") }
        return parts.joined(separator: " · ")
    }
}

/// One project's approvals: whether it's trusted, the mode new sessions start in, and its "Always allow" rules.
private struct ProjectApprovalsPage: View {
    let engine: EngineController
    let project: ProjectInfo
    let back: () -> Void

    /// What trusting it changes here: its own setup loads, its commands' network opens, or both (docs/spec/39).
    static func trustSubtitle(_ project: ProjectInfo) -> String {
        let setup = "its .pi and Claude Code setup loads", network = "its commands reach any site, and Full auto is available"
        switch (project.needsTrust, project.network == .filtered) {
        case (true, true): return "Trusted: \(setup), \(network)"
        case (false, true): return "Trusted: \(network)"
        case (true, false): return "Trusted: \(setup) (extensions, hooks, MCP servers, prompts and skills)"
        case (false, false): return "Whether its .pi and Claude Code setup loads"
        }
    }

    var body: some View {
        SettingsDetail(back: "Approvals", title: project.name, goBack: back) {
            MemoryTile(symbol: "folder", color: .gray, size: 48)
        } status: {
            Text(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).truncationMode(.middle)
        } actions: {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("Sessions")
                ListCard {
                    if project.trustMatters || project.trust != .undecided {
                        SettingRow(title: "Trust this project", subtitle: Self.trustSubtitle(project)) {
                            Picker("", selection: Binding(get: { project.trust }, set: { value in
                                if value != .undecided { Task { await engine.setTrust(value == .trusted, for: project) } }
                            })) {
                                Text("Trusted").tag(ProjectInfo.Trust.trusted)
                                Text("Not trusted").tag(ProjectInfo.Trust.untrusted)
                                if project.trust == .undecided { Text("Not decided").tag(ProjectInfo.Trust.undecided) }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Trust this project")
                            .fixedSize()
                        }
                    }
                    // docs/spec/39: on for a project you added or cloned until you trust it.
                    SettingRow(title: "Filter commands' network", subtitle: project.network == .filtered ? "Only package registries, GitHub and the sites you allow; others ask" : "Commands reach any site") {
                        Toggle("", isOn: Binding(get: { project.network == .filtered }, set: { on in Task { await engine.setNetwork(filtered: on, for: project) } }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Filter commands' network")
                    }
                    SettingRow(title: "New sessions start in", subtitle: ApprovalModeMenu.summary(project.approvalMode), last: true) {
                        Picker("", selection: Binding(get: { project.approvalMode }, set: { mode in Task { await engine.setApprovalMode(mode, for: project) } })) {
                            // Full access only once the project is trusted (docs/spec/39 §2).
                            ForEach(ApprovalMode.allCases) { Text(ApprovalModeMenu.title($0)).tag($0).selectionDisabled($0 == .fullAuto && !project.allowsFullAccess) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            // A project's hooks (PAR6): its .pi/extensions, run once it's trusted; Claude Code's offered for import.
            HooksCard(engine: engine, project: project.path).padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("Always allowed", detail: project.rules.isEmpty ? nil : "\(project.rules.count)")
                if project.rules.isEmpty {
                    FinePrint("Nothing yet. “Always for …” on an approval card adds a rule here.")
                } else {
                    ListCard {
                        ForEach(project.rules) { rule in
                            SettingRow(title: rule.pattern, subtitle: rule.kind == .command ? "Command, with any arguments" : rule.kind == .tool ? "Tool" : rule.kind == .host ? "Site its commands may reach" : "Path", last: rule.id == project.rules.last?.id) {
                                Button { Task { await engine.removeRule(rule, from: project) } } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(Color.dsFg3)
                                }
                                .buttonStyle(.plain)
                                .help("Remove this rule: it will ask again")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: This Mac & cloud

/// Your cloud (docs/spec/30 §3.3, K1): connect a Worker you deployed (its address and owner token), see whether it
/// answers and which agents run there, and disconnect once none do. Agents go up from their info panel.
private struct CloudCard: View {
    let engine: EngineController
    @State private var connecting = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        let cloud = engine.cloud
        VStack(alignment: .leading, spacing: 8) {
            ListCard {
                HStack(spacing: 12) {
                    Image(systemName: "cloud.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dsFg2)
                        .frame(width: 34, height: 34).background(Color.dsChip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Cloudflare").font(.system(size: 13.5, weight: .semibold))
                            if cloud?.connected == true {
                                if cloud?.reachable == true { StatusText(color: .dsFg3, text: "Connected").font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
                                else { StatusText(color: .dsFg, text: "Can't reach it").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg) }
                            }
                        }
                        Text(line(cloud)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(2)
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    if cloud?.connected == true {
                        // Piopio deployed it: Update puts this version's Worker and your current OpenRouter key there.
                        if cloud?.managed == true {
                            Button("Update") { update() }.buttonStyle(PillStyle(compact: true)).disabled(busy)
                                .help("Upload this version of Piopio's Worker and your current OpenRouter key. Agents up there stay as they are.")
                        } else {
                            Button("Set Up Again…") { connecting = true }.buttonStyle(PillStyle(compact: true)).disabled(busy)
                                .help("Connect with a Cloudflare token, so Piopio can update it and its model key. On the same account, agents up there stay.")
                        }
                        Button("Disconnect") { disconnect() }.buttonStyle(PillStyle(compact: true)).disabled(busy)
                    } else {
                        Button("Connect…") { connecting = true }.buttonStyle(PillStyle(kind: .primary, compact: true))
                    }
                }
                .padding(.horizontal, 14).frame(minHeight: 62)
                if let cloud, cloud.connected {
                    RowDivider(inset: 14)
                    VStack(alignment: .leading, spacing: 6) {
                        if cloud.agents.isEmpty {
                            Text("No agents there yet. Open an agent's info panel and choose Keep it always on.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                        } else {
                            ForEach(cloud.agents) { agent in
                                HStack(spacing: 8) {
                                    Image(systemName: "cloud").font(.system(size: 11)).foregroundStyle(Color.dsFg2)
                                    Text(agent.name).font(.system(size: 13))
                                    Spacer()
                                    Text("Up since \(Self.day(agent.deployedAt))").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                                }
                            }
                        }
                        if let e = cloud.error { Text(e).font(.system(size: 12)).foregroundStyle(Color.dsWarn).fixedSize(horizontal: false, vertical: true) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn).fixedSize(horizontal: false, vertical: true) }
        }
        .task(id: engine.status) { await engine.loadCloud() }
        .sheet(isPresented: $connecting) { CloudConnectSheet(engine: engine) { connecting = false } }
    }

    private func line(_ cloud: CloudStatus?) -> String {
        guard let cloud, cloud.connected, let url = cloud.url else { return "Agents that keep going with your Mac off, in your own Cloudflare account" }
        let host = URL(string: url)?.host ?? url
        return [host, cloud.version.map { "version \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    static func day(_ iso: String) -> String {
        guard let date = ISODate.parse(iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func update() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await engine.updateCloud() } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    private func disconnect() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await engine.disconnectCloud() } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}

/// Connect your cloud (docs/spec/30 §3.3): what goes there and what it costs, then one Cloudflare API token. Piopio
/// deploys its Worker to that account, makes the owner token itself and gives it your OpenRouter key. A Worker you
/// deployed by hand still connects by address and owner token, under Advanced.
private struct CloudConnectSheet: View {
    let engine: EngineController
    let done: () -> Void
    @State private var apiToken = ""
    @State private var accounts: [CloudSetupResult.Account]?
    @State private var account: String?
    @State private var advanced = false
    @State private var url = ""
    @State private var ownerToken = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect your cloud").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                point("checkmark.circle", "Agents you put there answer and run their automations with your Mac off.")
                point("tray.full", "It runs in your own Cloudflare account. Their conversations and memory are kept there.")
                point("key", "Cloud agents use your OpenRouter key, which Piopio gives your cloud.")
                point("creditcard", "The free plan is enough to try. For daily use, Workers Paid is $5 a month.")
            }
            if advanced { byHand } else { withToken }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(advanced ? "Use a Cloudflare token instead" : "Advanced: a Worker you deployed") { advanced.toggle(); error = nil }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    if !advanced { Text("Setting up your cloud…").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                }
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Connect", action: connect).keyboardShortcut(.defaultAction).disabled(busy || !ready)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    /// Step 1: make a token in Cloudflare (a template does it); step 2: paste it. Then pick the account if there are several.
    private var withToken: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("1").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsFg2).frame(width: 16)
                VStack(alignment: .leading, spacing: 6) {
                    Text("In Cloudflare, create an API token from the template “Edit Cloudflare Workers”. No account yet? Sign up there first; it's free.")
                        .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    Button("Open Cloudflare") { NSWorkspace.shared.open(URL(string: "https://dash.cloudflare.com/profile/api-tokens")!) }
                        .buttonStyle(PillStyle(compact: true))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("2").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsFg2).frame(width: 16)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste it here. Piopio keeps it in your Keychain, to update your cloud later.").font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    SecureField("Cloudflare API token", text: $apiToken).textFieldStyle(.roundedBorder)
                        .onChange(of: apiToken) { _, _ in accounts = nil; account = nil }
                }
            }
            if let accounts {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("3").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsFg2).frame(width: 16)
                    Picker("Account", selection: $account) {
                        Text("Choose…").tag(String?.none)
                        ForEach(accounts) { a in Text(a.name).tag(Optional(a.id)) }
                    }
                    .fixedSize()
                }
            }
        }
    }

    private var byHand: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The address and owner token of a Worker you deployed yourself (packages/cloud, node scripts/deploy.ts). Piopio can't update this one for you.")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            TextField("https://piopio-cloud.<you>.workers.dev", text: $url).textFieldStyle(.roundedBorder)
            SecureField("Owner token", text: $ownerToken).textFieldStyle(.roundedBorder)
        }
    }

    private var ready: Bool {
        if advanced { return !url.trimmingCharacters(in: .whitespaces).isEmpty && !ownerToken.trimmingCharacters(in: .whitespaces).isEmpty }
        return !apiToken.trimmingCharacters(in: .whitespaces).isEmpty && (accounts == nil || account != nil)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 16)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                if advanced {
                    try await engine.connectCloud(url: url, token: ownerToken)
                    done()
                } else if let several = try await engine.setupCloud(apiToken: apiToken, accountId: account) {
                    accounts = several
                } else {
                    done()
                }
            } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}

/// Where agents run (design handoff g1): the local engine with its status and actions, keep running when Piopio quits,
/// the runtime details under Details, and your cloud (docs/spec/30 K1).
private struct EnginesPane: View {
    let engine: EngineController
    @State private var status: EngineStatusResult?
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "This Mac & cloud", summary: "Where agents run. Everything stays in your own accounts.")
            CardTitle("This Mac")
            ListCard {
                HStack(spacing: 12) {
                    Image(systemName: "cpu").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dsFg2)
                        .frame(width: 34, height: 34).background(Color.dsChip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Local engine").font(.system(size: 13.5, weight: .semibold))
                            state
                        }
                        Text(line).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                    }
                    Spacer()
                    Button("View logs") { engine.revealLogs() }.buttonStyle(PillStyle(compact: true))
                    Button("Restart") { engine.restart() }.buttonStyle(PillStyle(kind: failed ? .primary : .secondary, compact: true))
                        .disabled(engine.status == .starting)
                }
                .padding(.horizontal, 14).frame(minHeight: 62)
                RowDivider(inset: 14)
                ToggleRow(title: "Keep running when Piopio quits", subtitle: engine.canRunInBackground ? "Scheduled agents keep working while the app is closed" : "Available in release builds, which carry their own engine", isOn: Binding(get: { engine.runsInBackground }, set: { on in
                    Task { await engine.setRunsInBackground(on) }
                }))
                .disabled(!engine.canRunInBackground)
                VStack(alignment: .leading, spacing: 8) {
                    Button { withAnimation(.easeOut(duration: 0.15)) { details.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(details ? 90 : 0))
                            Text("Details").font(.system(size: 12.5))
                        }
                        .foregroundStyle(Color.dsFg2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if details {
                        fact("Runtime", status?.runtime ?? "…")
                        fact("Version", engine.engineVersion ?? "…")
                        fact("Running for", status.map { Self.uptime($0.uptimeMs) } ?? "…")
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Data").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).frame(width: 90, alignment: .leading)
                            Text(dataPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dataPath)]) }
                                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                        }
                        .padding(.leading, 14)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            CardTitle("Cloud").padding(.top, 22)
            CloudCard(engine: engine)
        }
        .task(id: engine.status) {
            status = try? await engine.client?.call("engine.status", Empty(), as: EngineStatusResult.self)
        }
    }

    private var failed: Bool { if case .failed = engine.status { true } else { false } }
    private var dataPath: String { status?.dataPath ?? engine.home.path }

    @ViewBuilder private var state: some View {
        switch engine.status {
        case .ready: StatusText(color: .dsFg3, text: "Running").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
        case .starting: HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Starting…") }.font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        case .failed: StatusText(color: .dsFg, text: "Stopped").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg)
        }
    }

    /// "1 session open · 3 chats · 104 MB", or why it stopped.
    private var line: String {
        if case .failed(let message) = engine.status { return "Exited unexpectedly · \(message)" }
        guard let status else { return "…" }
        let chats = engine.threads.count
        return ["\(status.openSessions) session\(status.openSessions == 1 ? "" : "s") open", "\(chats) chat\(chats == 1 ? "" : "s")", "\(Int(status.memoryMB)) MB"].joined(separator: " · ")
    }

    static func uptime(_ ms: Double) -> String {
        let minutes = Int(ms / 60_000)
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        if minutes < 60 * 24 { return "\(minutes / 60) h \(minutes % 60) min" }
        return "\(minutes / (60 * 24)) d"
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).frame(width: 90, alignment: .leading)
            Text(value).font(.system(size: 12.5)).lineLimit(1)
        }
        .padding(.leading, 14)
    }
}

extension Notification.Name {
    /// Object: a Settings section's name ("Memory"): Settings switches to it.
    static let settingsSection = Notification.Name("piopio.settingsSection")
}
