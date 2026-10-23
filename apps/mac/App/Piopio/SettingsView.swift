import PiopioKit
import PiopioTranscript
import SwiftUI

/// Settings (docs/design v2, 9a): a grouped sidebar of sections; models and engines are lists of cards.
struct SettingsView: View {
    let engine: EngineController
    // PIOPIO_DEMO_SETTINGS_SECTION=General|Models|Engines picks the first section (captures).
    @State private var section: Section = Section(demo: ProcessInfo.processInfo.environment["PIOPIO_DEMO_SETTINGS_SECTION"] ?? "") ?? .providers

    enum Section: String, CaseIterable, Identifiable {
        case general = "General", providers = "Models", connectors = "Connectors", chat = "Chat", approvals = "Approvals", mcp = "MCP servers", extensions = "Extensions", engines = "This Mac & cloud"
        var id: String { rawValue }
        init?(demo: String) {
            switch demo {
            case "Providers": self = .providers
            case "Engines": self = .engines
            default: self.init(rawValue: demo)
            }
        }
        static let groups: [(String?, [Section])] = [(nil, [.general, .providers, .connectors, .chat, .approvals]), ("Extend", [.mcp, .extensions]), ("Where it runs", [.engines])]
        var icon: (String, Color) {
            switch self {
            case .general: ("gearshape.fill", .gray)
            case .providers: ("key.fill", .blue)
            case .connectors: ("app.connected.to.app.below.fill", .teal)
            case .chat: ("bubble.left.and.bubble.right.fill", .teal)
            case .extensions: ("shippingbox.fill", .indigo)
            case .approvals: ("checkmark.shield.fill", .orange)
            case .mcp: ("puzzlepiece.extension.fill", .purple)
            case .engines: ("cpu.fill", .green)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(Section.groups.enumerated()), id: \.offset) { _, group in
                    if let title = group.0 {
                        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
                            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 2)
                    }
                    ForEach(group.1) { s in
                    Button { section = s } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 5).fill(s.icon.1.gradient).frame(width: 20, height: 20)
                                .overlay(Image(systemName: s.icon.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
                            Text(s.rawValue).font(.system(size: 13))
                            // Nothing to think with yet (design m0): an amber dot on Models.
                            if s == .providers, !engine.faux, !engine.providers.isEmpty, !engine.providers.contains(where: \.isConnected) {
                                Circle().fill(Color.dsAmber).frame(width: 6, height: 6)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
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
            .glassPanel()
            .padding(8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch section {
                    case .general: GeneralPane()
                    case .providers: ModelsPane(engine: engine)
                    case .connectors: ConnectorsPane(engine: engine)
                    case .chat: ChatPane(engine: engine)
                    case .extensions: ExtensionsPane(engine: engine)
                    case .approvals: ApprovalsPane(engine: engine)
                    case .mcp: McpPane(engine: engine)
                    case .engines: EnginesPane(engine: engine)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 820, height: 560)
        .background(Color.dsWin)
    }
}

struct PaneTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.dsFg2)
        }
        .padding(.bottom, 18)
    }
}

/// Rows inside a card list, separated by hairlines.
struct ListCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }
}

struct Row<Trailing: View>: View {
    let title: String
    var last = false
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 13, weight: .semibold)).frame(width: 110, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            if !last { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
        }
    }
}

// MARK: General

private struct GeneralPane: View {
    @State private var tick = 0
    private let updater = AppUpdater.shared

    var body: some View {
        PaneTitle(title: "General", subtitle: "Shortcuts, notifications and updates.")
        ListCard {
            Row(title: "Quick Chat") {
                Picker("", selection: Binding(get: { QuickChatShortcut.current }, set: { value in
                    UserDefaults.standard.set(value.rawValue, forKey: "quickChatShortcut")
                    QuickChatController.shared?.applyShortcut()
                    tick += 1
                })) {
                    ForEach(QuickChatShortcut.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Text("Opens from any app").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Spacer()
            }
            Row(title: "Notifications") {
                Toggle("When an answer finishes or fails while I'm elsewhere", isOn: Binding(get: { Notifier.enabled }, set: { UserDefaults.standard.set($0, forKey: "notifyAnswers"); tick += 1 }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 13))
                Spacer()
            }
            Row(title: "Open files in") {
                if Editor.installed.isEmpty {
                    Text("No supported editor found (Zed, VS Code, Cursor, Xcode, Sublime Text)").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                } else {
                    Picker("", selection: Binding(get: { Editor.preferred?.id ?? "" }, set: { UserDefaults.standard.set($0, forKey: "editor"); tick += 1 })) {
                        ForEach(Editor.installed) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("Build's “Open in” and the file viewer").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
            }
            Row(title: "Updates", last: true) {
                if updater.isConfigured {
                    Toggle("Check automatically", isOn: Binding(get: { updater.checksAutomatically }, set: { updater.checksAutomatically = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 13))
                    Spacer()
                    Text(updater.version).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Button("Check Now") { updater.checkForUpdates() }
                        .buttonStyle(PillStyle(compact: true))
                        .disabled(!updater.canCheck)
                } else {
                    Text("Version \(updater.version) · this build doesn't update itself").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Spacer()
                }
            }
        }
        .id(tick)
    }
}

// MARK: Approvals

/// Per project: the approval mode new sessions start with, and the "Always allow" rules (docs/spec/05-build §6, AP2).
private struct ApprovalsPane: View {
    let engine: EngineController

    var body: some View {
        PaneTitle(title: "Approvals", subtitle: "What Build sessions may do without asking. Risky commands and writes outside the project always ask.")
        if engine.projects.isEmpty {
            Text("Add a project in Build to set its approvals.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
        }
        VStack(alignment: .leading, spacing: 18) {
            ForEach(engine.projects) { project in
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(project.name)
                    ListCard {
                        if project.needsTrust || project.trust != .undecided {
                            Row(title: "Project setup") {
                                Picker("", selection: Binding(get: { project.trust }, set: { value in
                                    if value != .undecided { Task { await engine.setTrust(value == .trusted, for: project) } }
                                })) {
                                    Text("Trusted").tag(ProjectInfo.Trust.trusted)
                                    Text("Not trusted").tag(ProjectInfo.Trust.untrusted)
                                    if project.trust == .undecided { Text("Not decided").tag(ProjectInfo.Trust.undecided) }
                                }
                                .labelsHidden()
                                .fixedSize()
                                Text("Loads the project's .pi extensions, MCP servers, prompts and skills. Shared with the pi CLI.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(2)
                                Spacer()
                            }
                        }
                        Row(title: "New sessions", last: project.rules.isEmpty) {
                            Picker("", selection: Binding(get: { project.approvalMode }, set: { mode in Task { await engine.setApprovalMode(mode, for: project) } })) {
                                ForEach(ApprovalMode.allCases) { Text(ApprovalModeMenu.title($0)).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Text(ApprovalModeMenu.summary(project.approvalMode)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(2)
                            Spacer()
                        }
                        ForEach(project.rules) { rule in
                            Row(title: rule.kind == .command ? "Command" : rule.kind == .tool ? "Tool" : "Path", last: rule.id == project.rules.last?.id) {
                                Text(rule.pattern).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(rule.kind == .command ? "and its arguments" : "always allowed").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
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
        Text("Rules come from “Always for …” on an approval card. They apply to every session in the project.")
            .font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 10)
    }
}

// MARK: MCP servers (docs/design 4a)

/// Servers from pi's mcp.json files: global ones for every project, and each project's own (.pi/mcp.json).
/// Build sessions connect to the enabled ones when they start.
private struct McpPane: View {
    let engine: EngineController
    /// A server and, for project servers, the project whose .pi/mcp.json has it.
    struct Entry: Identifiable {
        let server: McpServerInfo
        let project: ProjectInfo?
        var id: String { "\(project?.id ?? "global"):\(server.name)" }
    }
    @State private var entries: [Entry] = []
    @State private var errors: [String] = []
    @State private var adding = false

    var body: some View {
        PaneTitle(title: "MCP servers", subtitle: "Tools from Model Context Protocol servers. Same files as the pi CLI.")
        ListCard {
            Row(title: "In Chat", last: true) {
                Toggle("Also in Threads and Notebooks (all servers; Chat doesn't ask before a tool runs)", isOn: Binding(get: { engine.settings?.chat.mcp ?? false }, set: { on in Task { await engine.updateSettings(SettingsPatch(chat: .init(mcp: on))) } }))
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
                Spacer()
            }
        }
        .padding(.bottom, 18)
        .task { await engine.loadSettings() }
        HStack {
            SectionLabel("Servers")
            Spacer()
            Button("+ Add server") { adding = true }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
        }
        .padding(.bottom, 6)
        ListCard {
            if entries.isEmpty {
                Row(title: "None yet", last: true) {
                    Text("Add one here, or with `pi mcp add` in a terminal.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Spacer()
                }
            }
            ForEach(entries) { entry in
                let server = entry.server
                Row(title: server.name, last: entry.id == entries.last?.id) {
                    StatusDot(status: server.enabled ? .done : .idle, size: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.url ?? ([server.command ?? ""] + (server.args ?? [])).joined(separator: " "))
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg2).lineLimit(1).truncationMode(.middle)
                        if let description = server.description { Text(description).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1) }
                    }
                    Spacer()
                    Text(entry.project.map { $0.name + (server.override == true ? " · override" : "") } ?? "All projects")
                        .font(.system(size: 11)).padding(.horizontal, 8).frame(height: 20).background(Color.dsChip, in: Capsule()).foregroundStyle(Color.dsFg2)
                    Toggle("", isOn: Binding(get: { server.enabled }, set: { on in Task { await setEnabled(entry, on) } }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    Button { Task { await remove(entry) } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Color.dsFg3) }
                        .buttonStyle(.plain)
                        .help("Remove from mcp.json")
                }
            }
        }
        ForEach(errors, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Color.dsRed).padding(.top, 6) }
        Text("Changes apply to sessions you start or reopen. Tools reach the model through codemode by default; project servers load only in trusted projects.")
            .font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 10)
            .task { await refresh() }
            .sheet(isPresented: $adding) { AddMcpServerSheet(engine: engine) { Task { await refresh() } } }
    }

    private func refresh() async {
        guard let client = engine.client else { return }
        var all: [Entry] = []
        var errs: [String] = []
        if let global = try? await client.call("mcp.list", McpListParams(), as: McpListResult.self) {
            all += global.servers.map { Entry(server: $0, project: nil) }
            errs += global.errors
        }
        for project in engine.projects where project.missing != true {
            if let result = try? await client.call("mcp.list", McpListParams(cwd: project.path), as: McpListResult.self) {
                all += result.servers.filter { $0.scope == .project }.map { Entry(server: $0, project: project) }
                errs += result.errors.filter { !errs.contains($0) }
            }
        }
        entries = all
        errors = errs
    }

    private func setEnabled(_ entry: Entry, _ on: Bool) async {
        _ = try? await engine.client?.call("mcp.setEnabled", McpNameParams(scope: entry.server.scope, cwd: entry.project?.path, name: entry.server.name, enabled: on), as: Empty.self)
        await refresh()
    }

    private func remove(_ entry: Entry) async {
        _ = try? await engine.client?.call("mcp.remove", McpNameParams(scope: entry.server.scope, cwd: entry.project?.path, name: entry.server.name), as: Empty.self)
        await refresh()
    }
}

private struct AddMcpServerSheet: View {
    let engine: EngineController
    let added: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var remote = false
    @State private var commandLine = ""
    @State private var url = ""
    @State private var description = ""
    @State private var projectId = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add MCP server").font(.system(size: 15, weight: .semibold))
            TextField("Name (letters, digits, - and _)", text: $name).textFieldStyle(.roundedBorder)
            Picker("", selection: $remote) {
                Text("Command (stdio)").tag(false)
                Text("URL (HTTP)").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if remote {
                TextField("https://example.com/mcp", text: $url).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            } else {
                TextField("npx -y @modelcontextprotocol/server-filesystem .", text: $commandLine).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            }
            TextField("What it offers (optional, helps the model find its tools)", text: $description).textFieldStyle(.roundedBorder)
            Picker("For", selection: $projectId) {
                Text("All projects").tag("")
                ForEach(engine.projects) { Text($0.name).tag($0.id) }
            }
            .fixedSize()
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button("Add") { Task { await add() } }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || (remote ? url.isEmpty : commandLine.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func add() async {
        let words = Self.split(commandLine)
        let project = engine.projects.first { $0.id == projectId }
        let params = McpAddParams(scope: project == nil ? .global : .project, cwd: project?.path, name: name.trimmingCharacters(in: .whitespaces),
                                  command: remote ? nil : words.first, args: remote ? nil : Array(words.dropFirst()), url: remote ? url : nil,
                                  description: description.isEmpty ? nil : description)
        do {
            _ = try await engine.client?.call("mcp.add", params, as: Empty.self)
            added()
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Splits a command line on spaces, keeping quoted parts together.
    static func split(_ line: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

// MARK: Engines

private struct EnginesPane: View {
    let engine: EngineController
    @State private var status: EngineStatusResult?

    var body: some View {
        PaneTitle(title: "Engines", subtitle: "Where agent logic runs. Everything stays in your own accounts.")
        HStack(alignment: .top, spacing: 12) {
            CardTile {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Local engine").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        StatusDot(status: engine.status == .ready ? .done : .failed, size: 6)
                        Text(engine.status == .ready ? "Running" : "Stopped").font(.system(size: 12)).foregroundStyle(engine.status == .ready ? Color.dsGreen : Color.dsRed)
                    }
                    fact("Runtime", status?.runtime ?? "…")
                    fact("Version", engine.engineVersion ?? "…")
                    fact("Sessions", status.map { "\($0.openSessions) open · \(engine.threads.count) threads" } ?? "…")
                    fact("Memory", status.map { "\(Int($0.memoryMB)) MB" } ?? "…")
                    fact("Data", (status?.dataPath ?? engine.home.path).replacingOccurrences(of: NSHomeDirectory(), with: "~"), mono: true)
                    Toggle(isOn: Binding(get: { engine.runsInBackground }, set: { on in Task { await engine.setRunsInBackground(on) } })) {
                        Text("Keep running when Piopio quits").font(.system(size: 12.5))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!engine.canRunInBackground)
                    .help(engine.canRunInBackground ? "Runs the engine as a login item, so it's ready at login and keeps working after you quit." : "Available in release builds, which carry their own engine.")
                    Rectangle().fill(Color.dsLine).frame(height: 0.5)
                    HStack {
                        Button("Restart") { engine.restart() }.buttonStyle(PillStyle(compact: true))
                        Button("View logs") { engine.revealLogs() }.buttonStyle(PillStyle(compact: true))
                    }
                }
            }
            CardTile {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Cloud · Cloudflare").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        StatusDot(status: .idle, size: 6)
                        Text("Not connected").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    Text("Runs agents 24/7 in your own Cloudflare account: one Worker, one Durable Object per agent.")
                        .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                    Rectangle().fill(Color.dsLine).frame(height: 0.5)
                    HStack {
                        Button("Connect…") {}.buttonStyle(PillStyle(compact: true)).disabled(true)
                        Spacer()
                        Text("Arrives with Agents").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                }
            }
        }
        .task {
            status = try? await engine.client?.call("engine.status", Empty(), as: EngineStatusResult.self)
        }
    }

    private func fact(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).frame(width: 70, alignment: .leading)
            Text(value).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5)).lineLimit(1).truncationMode(.middle)
        }
    }
}
