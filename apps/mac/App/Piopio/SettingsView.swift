import PiopioKit
import PiopioTranscript
import SwiftUI

/// Settings (docs/design v2, 9a): a grouped sidebar of sections; models and engines are lists of cards.
struct SettingsView: View {
    let engine: EngineController
    // PIOPIO_DEMO_SETTINGS_SECTION=General|Models|Engines picks the first section (captures).
    @State private var section: Section = Section(demo: ProcessInfo.processInfo.environment["PIOPIO_DEMO_SETTINGS_SECTION"] ?? "") ?? .providers

    enum Section: String, CaseIterable, Identifiable {
        case general = "General", providers = "Models", connectors = "Connectors", chat = "Chat", memory = "Memory", approvals = "Approvals", mcp = "MCP servers", extensions = "Extensions", engines = "This Mac & cloud"
        var id: String { rawValue }
        init?(demo: String) {
            switch demo {
            case "Providers": self = .providers
            case "Engines": self = .engines
            default: self.init(rawValue: demo)
            }
        }
        static let groups: [(String?, [Section])] = [(nil, [.general, .providers, .connectors, .chat, .memory, .approvals]), ("Extend", [.mcp, .extensions]), ("Where it runs", [.engines])]
        var icon: (String, Color) {
            switch self {
            case .general: ("gearshape.fill", .gray)
            case .providers: ("key.fill", .blue)
            case .connectors: ("app.connected.to.app.below.fill", .teal)
            case .chat: ("bubble.left.and.bubble.right.fill", .teal)
            case .memory: ("brain.head.profile", .pink)
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
                    case .general: GeneralPane(engine: engine)
                    case .providers: ModelsPane(engine: engine)
                    case .connectors: ConnectorsPane(engine: engine)
                    case .chat: ChatPane(engine: engine)
                    case .memory: MemoryPane(engine: engine)
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
    let engine: EngineController
    @State private var tick = 0
    private let updater = AppUpdater.shared

    var body: some View {
        PaneTitle(title: "General", subtitle: "Areas, shortcuts, notifications and updates.")
        AreasCard(engine: engine) {
            NSApp.keyWindow?.performClose(nil)
            NotificationCenter.default.post(name: .runSetupAgain, object: nil)
        }
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

// MARK: This Mac & cloud

/// Where agents run (design handoff g1): the local engine with its status and actions, keep running when Piopio quits,
/// the runtime details under Details, and the cloud (Cloudflare) as coming soon.
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
                    Image(systemName: "cpu").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Local engine").font(.system(size: 14, weight: .semibold))
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
            ListCard {
                HStack(spacing: 12) {
                    Image(systemName: "cloud.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cloudflare").font(.system(size: 14, weight: .semibold))
                        Text("Runs agents 24/7 in your own account, even when your Mac sleeps").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    Spacer()
                    SettingsBadge("Coming soon")
                }
                .padding(.horizontal, 14).frame(minHeight: 62)
            }
        }
        .task(id: engine.status) {
            status = try? await engine.client?.call("engine.status", Empty(), as: EngineStatusResult.self)
        }
    }

    private var failed: Bool { if case .failed = engine.status { true } else { false } }
    private var dataPath: String { status?.dataPath ?? engine.home.path }

    @ViewBuilder private var state: some View {
        switch engine.status {
        case .ready: StatusText(color: .dsGreen, text: "Running").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsGreen)
        case .starting: HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Starting…") }.font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        case .failed: StatusText(color: .dsRed, text: "Stopped").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsRed)
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
