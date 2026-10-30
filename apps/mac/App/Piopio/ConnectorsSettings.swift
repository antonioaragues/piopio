import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Settings › Connectors (design handoff c0–c4, docs/spec/12-connectors): connect an app once and any chat, notebook
// or agent can use it. The page lists connected accounts; each opens its page (what it may do, its calendars);
// adding happens in a sheet with the catalog and a connect step that sets permissions before signing in.

/// Signing in to an app: the browser opens; this follows until done or failed.
@MainActor @Observable final class ConnectorLogin {
    let connector: ConnectorInfo
    /// Started from the Add connector sheet, which shows the progress itself.
    let inline: Bool
    var loginId: String?
    var url: URL?
    var progress: String?
    var finished = false
    var error: String?

    init(connector: ConnectorInfo, inline: Bool = false) { self.connector = connector; self.inline = inline }

    func apply(_ event: ProviderAuthEvent) {
        switch event.type {
        case "auth_url":
            url = event.url.flatMap(URL.init(string:))
            // Captures sign in to a fake server without a browser (PIOPIO_DEMO_CONNECT_APPS).
            if let url, ProcessInfo.processInfo.environment["PIOPIO_DEMO_CONNECT_APPS"] != nil { URLSession.shared.dataTask(with: url).resume() }
            else if let url { NSWorkspace.shared.open(url) }
        case "progress": progress = event.message
        case "done": finished = true; error = nil
        case "failed": finished = true; error = event.message ?? "Couldn't connect."
        default: break
        }
    }
}

/// What the Add connector sheet opens on.
enum AddConnectorRoute: Identifiable, Hashable {
    case catalog
    case connect(String)
    var id: String {
        switch self {
        case .catalog: "catalog"
        case .connect(let c): "connect:\(c)"
        }
    }
}

// MARK: - c1 / c0 · Connectors page

struct ConnectorsPane: View {
    let engine: EngineController
    @State private var detail: String?
    @State private var adding: AddConnectorRoute?
    @State private var highlight: String?

    private var accounts: [(connector: ConnectorInfo, account: ConnectorInfo.Account)] {
        engine.connectors.flatMap { c in c.accounts.map { (c, $0) } }
    }

    var body: some View {
        Group {
            if let id = detail, let item = accounts.first(where: { $0.account.id == id }) {
                ConnectorDetailView(engine: engine, connector: item.connector, account: item.account, back: { detail = nil }, switched: { detail = $0 })
            } else if accounts.isEmpty {
                empty
            } else {
                page
            }
        }
        .task {
            await engine.loadConnectors()
            // Captures: PIOPIO_DEMO_ADD_CONNECTOR=catalog | connect:<id>; PIOPIO_DEMO_CONNECTOR_DETAIL=<account id>.
            let env = ProcessInfo.processInfo.environment
            try? await Task.sleep(for: .seconds(1.5))
            if let id = env["PIOPIO_DEMO_CONNECTOR_DETAIL"] { detail = accounts.first { $0.account.id.hasPrefix(id) }?.account.id }
            if let route = env["PIOPIO_DEMO_ADD_CONNECTOR"] { adding = route.hasPrefix("connect:") ? .connect(String(route.dropFirst(8))) : .catalog }
        }
        .sheet(item: $adding) { route in
            AddConnectorSheet(engine: engine, start: route) { added in
                adding = nil
                guard let added else { return }
                highlight = added
                Task { try? await Task.sleep(for: .seconds(2)); withAnimation(.easeOut(duration: 0.6)) { highlight = nil } }
            }
        }
        .sheet(isPresented: Binding(get: { engine.connectorLogin.map { !$0.inline } ?? false }, set: { if !$0 { Task { await engine.cancelConnectorLogin() } } })) {
            if let login = engine.connectorLogin { ConnectorSignInSheet(engine: engine, login: login) }
        }
    }

    // c1
    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "Connectors", summary: "\(accounts.count) connected · used by chats, notebooks and agents") {
                AddButton(title: "Add connector") { adding = .catalog }
            }
            CardTitle("Connected")
            ListCard {
                ForEach(Array(accounts.enumerated()), id: \.element.account.id) { i, item in
                    ConnectorAccountRow(engine: engine, connector: item.connector, account: item.account, highlighted: highlight == item.account.id) { detail = item.account.id }
                    if i < accounts.count - 1 { RowDivider() }
                }
            }
            FinePrint("Reading runs on its own; anything that changes something asks you first. Change it per connector.").padding(.top, 12)
        }
    }

    // c0
    private var empty: some View {
        SettingsEmpty(title: "Connect your apps", message: "Connect once and any chat, notebook or agent can use it. Reading runs on its own; changes ask you first.") {
            ForEach(engine.connectors) { c in
                HStack(spacing: 12) {
                    ConnectorTile(id: c.id, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.system(size: 14, weight: .semibold))
                        Text(ConnectorCatalog.tagline(c.id)).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    Spacer()
                    Button("Connect") { adding = .connect(c.id) }.buttonStyle(PillStyle(kind: c.id == engine.connectors.first?.id ? .primary : .secondary, compact: true))
                }
                .padding(.horizontal, 14).frame(minHeight: 60)
                .settingsRows()
            }
            if engine.connectors.isEmpty {
                FinePrint(engine.client == nil ? "The engine isn't running." : "Loading…")
            }
            Button("Browse all connectors…") { adding = .catalog }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor).padding(.top, 6)
        }
    }
}

/// One connected account (c1): who, what it may do, and where it's available. An expired sign-in reruns inline.
private struct ConnectorAccountRow: View {
    let engine: EngineController
    let connector: ConnectorInfo
    let account: ConnectorInfo.Account
    let highlighted: Bool
    let open: () -> Void

    var body: some View {
        SettingsListRow(name: connector.name, dot: account.problem == nil ? .dsFg3 : .dsAmber, highlighted: highlighted, open: open) {
            ConnectorTile(id: connector.id, size: 34)
        } subtitle: {
            if account.problem != nil {
                HStack(spacing: 0) {
                    Text("Sign-in expired · ").foregroundStyle(Color.dsAmber)
                    Button("Sign in again") { Task { await engine.connect(connector) } }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            } else {
                Text("\(account.label) · \(ConnectorCatalog.summary(connector))")
            }
        } trailing: {
            Text(connector.chats ? "Chats & agents" : "Agents only").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        }
    }
}

// MARK: - c2 · Connector detail

struct ConnectorDetailView: View {
    let engine: EngineController
    let connector: ConnectorInfo
    let account: ConnectorInfo.Account
    let back: () -> Void
    let switched: (String) -> Void
    @State private var calendars: [ConnectorCalendarsResult.Calendar] = []
    @State private var calendarsError: String?
    @State private var disconnecting = false
    @State private var switchingFrom: Set<String>?

    private var hasCalendar: Bool { connector.capabilities.contains { $0.id.hasPrefix("calendar.") } }

    var body: some View {
        SettingsDetail(back: "Connectors", title: connector.name, goBack: back, footer: impact, remove: "Disconnect…", onRemove: { disconnecting = true }) {
            ConnectorTile(id: connector.id, size: 48)
        } status: {
            if let problem = account.problem {
                StatusText(color: .dsAmber, text: problem)
            } else {
                StatusText(color: .dsFg3, text: (["Connected as \(account.label)"] + (calendars.isEmpty ? [] : ["\(calendars.count) calendar\(calendars.count == 1 ? "" : "s")"])).joined(separator: " · "))
            }
        } actions: {
            Button(account.problem == nil ? "Switch account" : "Sign in again") {
                if account.problem == nil { switchingFrom = Set(connector.accounts.map(\.id)) }
                Task { await engine.connect(connector) }
            }
            .buttonStyle(PillStyle(kind: account.problem == nil ? .secondary : .primary, compact: true))
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("What it can do")
                CapabilitiesCard(capabilities: connector.capabilities) { capability, permission in
                    Task { await engine.setPermission(permission, for: capability, of: connector) }
                }
            }
            if hasCalendar {
                VStack(alignment: .leading, spacing: 0) {
                    CardTitle("Calendars", detail: "Only these are read")
                    ListCard {
                        if calendars.isEmpty {
                            Text(calendarsError ?? "Loading…").font(.system(size: 12.5)).foregroundStyle(calendarsError == nil ? Color.dsFg3 : Color.dsAmber)
                                .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        }
                        ForEach(Array(calendars.enumerated()), id: \.element.id) { i, cal in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 3).fill(Color(hex: cal.color) ?? Color.accentColor).frame(width: 10, height: 10)
                                Text(cal.name).font(.system(size: 13)).lineLimit(1)
                                if cal.primary { Text("Primary").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
                                Spacer()
                                Toggle("", isOn: Binding(get: { cal.enabled }, set: { on in
                                    calendars[i].enabled = on
                                    Task { await engine.setConnectorCalendar(account.id, cal.id, enabled: on) }
                                }))
                                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                            }
                            .padding(.horizontal, 14).frame(minHeight: 40)
                            if i < calendars.count - 1 { RowDivider(inset: 34) }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("Where it's used")
                ListCard {
                    ToggleRow(title: "Chats, notebooks and Build", subtitle: "Agents can always use it", last: true, isOn: Binding(get: { connector.chats }, set: { on in
                        Task { try? await engine.configure(ConnectorConfigureParams(connector: connector.id, chats: on)) }
                    }))
                }
            }
        }
        .task(id: account.id) {
            guard hasCalendar else { return }
            do { calendars = try await engine.connectorCalendars(account.id) } catch { calendarsError = "Couldn't list the calendars: \((error as? EngineError)?.message ?? error.localizedDescription)" }
        }
        .onChange(of: engine.connectorLogin?.finished) { _, finished in
            // Switch account: once the new account is in, the old one goes.
            guard finished == true, engine.connectorLogin?.error == nil, let before = switchingFrom else { return }
            switchingFrom = nil
            Task {
                await engine.loadConnectors()
                guard let added = engine.connectors.first(where: { $0.id == connector.id })?.accounts.first(where: { !before.contains($0.id) }) else { return }
                await engine.disconnect(account: account)
                switched(added.id)
            }
        }
        .alert("Disconnect \(connector.name) (\(account.label))?", isPresented: $disconnecting) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await engine.disconnect(account: account)
                    back()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(impact) Its sign-in is removed from this Mac.")
        }
    }

    private var impact: String {
        let what = [hasCalendar ? "calendar" : nil, connector.capabilities.contains { $0.id.hasPrefix("mail.") } ? "mail" : nil].compactMap { $0 }.joined(separator: " and ")
        return "Disconnecting removes \(what.isEmpty ? "its" : what) access from chats, notebooks and agents."
    }
}

/// "What it can do": one row per capability, its tools beneath, and its permission menu.
struct CapabilitiesCard: View {
    let capabilities: [ConnectorInfo.Capability]
    let set: (ConnectorInfo.Capability, ConnectorPermission) -> Void

    var body: some View {
        ListCard {
            ForEach(Array(capabilities.enumerated()), id: \.element.id) { i, c in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.label).font(.system(size: 13))
                        Text(c.tools.joined(separator: ", ")).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle)
                        if let note = c.note { Text(note).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
                    }
                    Spacer()
                    PermissionMenu(permission: c.permission, choices: c.choices) { set(c, $0) }
                }
                .padding(.horizontal, 14).frame(minHeight: 50)
                if i < capabilities.count - 1 { RowDivider(inset: 14) }
            }
        }
    }
}

// MARK: - c3 / c4 · Add connector sheet

/// The catalog: apps Piopio connects to today, and the ones coming (shown, not clickable).
enum ConnectorCatalog {
    enum Category: String, CaseIterable { case all = "All", mail = "Calendar & mail", files = "Files & docs", chat = "Team chat", dev = "Dev & ops" }
    struct Soon: Identifiable { let id, name, line: String; let category: Category; let color: Color }

    static let soon: [Soon] = [
        Soon(id: "gmail", name: "Gmail", line: "Search, read and draft email", category: .mail, color: Color(red: 0.86, green: 0.27, blue: 0.22)),
        Soon(id: "drive", name: "Google Drive", line: "Find and read your files", category: .files, color: Color(red: 0.12, green: 0.63, blue: 0.33)),
        Soon(id: "notion", name: "Notion", line: "Pages and databases", category: .files, color: Color(red: 0.2, green: 0.2, blue: 0.2)),
        Soon(id: "slack", name: "Slack", line: "Read channels, send messages", category: .chat, color: Color(red: 0.38, green: 0.12, blue: 0.42)),
        Soon(id: "jira", name: "Jira", line: "Issues and sprints", category: .dev, color: Color(red: 0.0, green: 0.4, blue: 0.85)),
        Soon(id: "github", name: "GitHub", line: "Issues, PRs and repos", category: .dev, color: Color(red: 0.14, green: 0.16, blue: 0.18)),
        Soon(id: "datadog", name: "Datadog", line: "Monitors, logs and incidents", category: .dev, color: Color(red: 0.39, green: 0.17, blue: 0.64)),
    ]

    static func category(_ c: ConnectorInfo) -> Category { c.category == "calendar" || c.category == "email" ? .mail : .dev }

    static func tagline(_ id: String) -> String {
        switch id {
        case "google-calendar": "Your day in every briefing"
        case "outlook": "Calendar and mail"
        default: ""
        }
    }

    static func line(_ c: ConnectorInfo) -> String {
        switch c.id {
        case "google-calendar": "Read your calendars, find free time, create events"
        case "outlook": "Calendar and mail: events, messages, drafts"
        default: c.description
        }
    }

    static func signIn(_ id: String) -> String { id == "outlook" ? "Sign in with Microsoft…" : "Sign in with Google…" }

    /// "reads freely, asks before changes", from its permissions.
    static func summary(_ c: ConnectorInfo) -> String {
        let reads = c.capabilities.filter { $0.access == .read }
        let changes = c.capabilities.filter { $0.access != .read }
        let read = reads.allSatisfy { $0.permission == .off } ? "doesn't read" : reads.contains { $0.permission == .ask } ? "asks before reading" : "reads freely"
        let change = changes.allSatisfy { $0.permission == .off } ? "makes no changes" : changes.contains { $0.permission == .runs } ? "makes some changes on its own" : "asks before changes"
        return "\(read), \(change)"
    }
}

struct AddConnectorSheet: View {
    let engine: EngineController
    let start: AddConnectorRoute
    /// Closes the sheet; with the account just connected, if any.
    let done: (String?) -> Void
    @State private var page: Page = .catalog
    @State private var fromCatalog = false
    @State private var category: ConnectorCatalog.Category = .all
    @State private var query = ""
    @FocusState private var searching: Bool

    enum Page: Hashable { case catalog, connect(String), mcp }

    var body: some View {
        Group {
            switch page {
            case .catalog: catalogPage.frame(width: 800, height: 620)
            case .connect(let id):
                if let c = engine.connectors.first(where: { $0.id == id }) {
                    ConnectStep(engine: engine, connector: c, back: fromCatalog ? { page = .catalog } : nil, done: done).frame(width: 520)
                }
            case .mcp:
                AddMcpServerView(engine: engine, back: { page = .catalog }, done: { done(nil) }).frame(width: 600)
            }
        }
        .onAppear {
            switch start {
            case .catalog: page = .catalog
            case .connect(let id): page = .connect(id)
            }
        }
    }

    private var catalogPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Add a connector").font(.system(size: 17, weight: .bold))
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    TextField("Search apps", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
                }
                .padding(.horizontal, 10).frame(height: 30).background(Color.dsChip, in: RoundedRectangle(cornerRadius: 8))
                Button("Cancel") { done(nil) }.buttonStyle(PillStyle(compact: true)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).frame(height: 56)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ConnectorCatalog.Category.allCases, id: \.self) { c in
                        Button { category = c; query = "" } label: {
                            HStack {
                                Text(c.rawValue).font(.system(size: 13))
                                Spacer()
                                if c != .all { Text("\(count(c))").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                            }
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(category == c && query.isEmpty ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.vertical, 6)
                    Button { page = .mcp } label: {
                        Label("Use an MCP server", systemImage: "puzzlepiece.extension").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.accentColor).padding(.horizontal, 10).frame(height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .frame(width: 190)
                .background(Color.dsChip.opacity(0.6))
                Rectangle().fill(Color.dsLine).frame(width: 0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        let available = engine.connectors.filter { matches($0.name, ConnectorCatalog.category($0)) }
                        let soon = ConnectorCatalog.soon.filter { matches($0.name, $0.category) }
                        if available.isEmpty && soon.isEmpty { Text("No app matches “\(query)”.").font(.system(size: 13)).foregroundStyle(Color.dsFg3) }
                        if !available.isEmpty {
                            section("Available")
                            LazyVGrid(columns: columns, spacing: 10) { ForEach(available) { c in availableTile(c) } }
                        }
                        if !soon.isEmpty {
                            section("Coming soon")
                            LazyVGrid(columns: columns, spacing: 10) { ForEach(soon) { s in soonTile(s) } }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .background(Color.dsWin)
        .onAppear { searching = true }
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 10), count: 3) }

    private func matches(_ name: String, _ c: ConnectorCatalog.Category) -> Bool {
        query.isEmpty ? (category == .all || category == c) : name.localizedCaseInsensitiveContains(query)
    }

    private func count(_ c: ConnectorCatalog.Category) -> Int {
        engine.connectors.filter { ConnectorCatalog.category($0) == c }.count + ConnectorCatalog.soon.filter { $0.category == c }.count
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
    }

    private func availableTile(_ c: ConnectorInfo) -> some View {
        Button { fromCatalog = true; page = .connect(c.id) } label: {
            tile(name: c.name, line: ConnectorCatalog.line(c)) {
                ConnectorTile(id: c.id, size: 28)
            } badge: {
                if !c.accounts.isEmpty { Label("Connected", systemImage: "checkmark").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dsFg3) }
            }
        }
        .buttonStyle(.plain)
    }

    private func soonTile(_ s: ConnectorCatalog.Soon) -> some View {
        tile(name: s.name, line: s.line) {
            LetterTile(text: String(s.name.prefix(1)), color: s.color, size: 28)
        } badge: {
            SettingsBadge("Soon")
        }
        .opacity(0.6)
    }

    private func tile<Icon: View, B: View>(name: String, line: String, @ViewBuilder icon: () -> Icon, @ViewBuilder badge: () -> B) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) { icon(); Spacer(); badge() }
            Text(name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg).padding(.top, 4)
            Text(line).font(.system(size: 11.5)).foregroundStyle(Color.dsFg2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .settingsRows()
        .contentShape(Rectangle())
    }
}

/// c4: what the app may do (safe defaults, changeable), then sign in. Progress shows here; success closes the sheet.
private struct ConnectStep: View {
    let engine: EngineController
    let connector: ConnectorInfo
    let back: (() -> Void)?
    let done: (String?) -> Void
    @State private var permissions: [String: ConnectorPermission] = [:]
    @State private var before: Set<String> = []
    @State private var developer = false

    private var login: ConnectorLogin? { engine.connectorLogin.flatMap { $0.inline && $0.connector.id == connector.id ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let back {
                Button(action: back) { Label("All connectors", systemImage: "chevron.left").font(.system(size: 12.5)) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).padding(.bottom, 12)
            }
            HStack(spacing: 12) {
                ConnectorTile(id: connector.id, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name).font(.system(size: 19, weight: .bold))
                    Text(connector.description).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(2)
                }
            }
            .padding(.bottom, 16)
            CardTitle("What it can do")
            CapabilitiesCard(capabilities: connector.capabilities.map { c in var c = c; c.permission = permissions[c.id] ?? c.permission; return c }) { c, p in permissions[c.id] = p }
            FinePrint("Safe defaults. You can change these any time.").padding(.top, 8)
            status.padding(.top, 14)
            HStack {
                if !connector.ready {
                    Button("Developer setup…") { developer = true }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                Button("Cancel") {
                    Task { await engine.cancelConnectorLogin() }
                    done(nil)
                }
                .buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(login?.finished == true && login?.error != nil ? "Try Again" : ConnectorCatalog.signIn(connector.id)) { signIn() }
                    .buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(!connector.ready || (login != nil && login?.finished != true))
            }
            .padding(.top, 16)
        }
        .padding(22)
        .background(Color.dsWin)
        .onChange(of: login?.finished) { _, finished in
            guard finished == true, login?.error == nil else { return }
            Task {
                await engine.loadConnectors()
                let added = engine.connectors.first { $0.id == connector.id }?.accounts.first { !before.contains($0.id) }?.id
                await engine.cancelConnectorLogin()
                done(added ?? connector.accounts.first?.id)
            }
        }
        .sheet(isPresented: $developer) { ConnectorSetupSheet(engine: engine, connector: connector) }
    }

    @ViewBuilder private var status: some View {
        if !connector.ready {
            Label("Sign-in for \(connector.name) isn't available in this build yet.", systemImage: "info.circle")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
        } else if let login {
            if let error = login.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            } else if !login.finished {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(login.progress ?? "Finish signing in in your browser. This updates when you're done.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    if let url = login.url { Button("Open again") { NSWorkspace.shared.open(url) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor) }
                }
            }
        }
    }

    private func signIn() {
        before = Set(connector.accounts.map(\.id))
        Task {
            let changed = connector.capabilities.filter { permissions[$0.id] != nil && permissions[$0.id] != $0.permission }
            if !changed.isEmpty {
                var map: [String: ConnectorPermission] = [:]
                for c in changed { for t in c.tools { map[t] = permissions[c.id] } }
                try? await engine.configure(ConnectorConfigureParams(connector: connector.id, permissions: map))
            }
            await engine.connect(connector, inline: true)
        }
    }
}

struct ConnectorTile: View {
    let id: String
    var size: CGFloat = 32

    var body: some View {
        let (symbol, color): (String, Color) = switch id {
        case "google-calendar": ("calendar", Color(red: 0.26, green: 0.52, blue: 0.96))
        case "outlook": ("envelope.fill", Color(red: 0.0, green: 0.47, blue: 0.83))
        default: ("app.connected.to.app.below.fill", Color.gray)
        }
        Image(systemName: symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(Color.dsFg2)
            .frame(width: size, height: size)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }
}

/// Developer-only: an OAuth client of your own, until Piopio's own sign-in is registered (docs/spec/12 §2).
private struct ConnectorSetupSheet: View {
    let engine: EngineController
    let connector: ConnectorInfo
    @State private var clientId = ""
    @State private var secret = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Developer setup · \(connector.name)").font(.system(size: 17, weight: .bold))
            Text("For development builds without Piopio's registered sign-in. \(connector.setupHelp)")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Client ID").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                TextField(connector.id == "outlook" ? "00000000-0000-0000-0000-000000000000" : "…apps.googleusercontent.com", text: $clientId).textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
            }
            if connector.needsSecret {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Client secret").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                    SecureField("Stored in the macOS Keychain", text: $secret).textFieldStyle(.roundedBorder)
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(clientId.trimmingCharacters(in: .whitespaces).isEmpty || (connector.needsSecret && secret.isEmpty && !connector.ownClient))
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func save() {
        Task {
            do {
                try await engine.configure(ConnectorConfigureParams(connector: connector.id, clientId: clientId.trimmingCharacters(in: .whitespaces), clientSecret: secret.isEmpty ? nil : secret))
                dismiss()
            } catch {
                self.error = (error as? EngineError)?.message ?? error.localizedDescription
            }
        }
    }
}

/// Signing in again from the page or a detail (not from the Add sheet): the browser, then connected or why not.
private struct ConnectorSignInSheet: View {
    let engine: EngineController
    let login: ConnectorLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ConnectorTile(id: login.connector.id, size: 36)
                Text("Sign in to \(login.connector.name)").font(.system(size: 17, weight: .bold))
            }
            if login.finished {
                if let error = login.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Connected.", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg3)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(login.progress ?? "Finish signing in in your browser. This updates when you're done.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                }
                if let url = login.url {
                    Button("Open the browser again") { NSWorkspace.shared.open(url) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                }
            }
            HStack {
                Spacer()
                if login.finished {
                    if login.error != nil { Button("Try Again") { Task { await engine.connect(login.connector) } }.buttonStyle(PillStyle()) }
                    Button("Done") { Task { await engine.cancelConnectorLogin() } }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { Task { await engine.cancelConnectorLogin() } }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

extension Color {
    /// "#7986cb" (Google's and Outlook's calendar colors).
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
