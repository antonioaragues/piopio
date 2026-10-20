import PiopioKit
import PiopioTranscript
import SwiftUI

/// Settings (docs/design 4b): a sidebar of sections; providers and engines are lists of cards.
struct SettingsView: View {
    let engine: EngineController
    // PIOPIO_DEMO_SETTINGS_SECTION=General|Providers|Engines picks the first section (captures).
    @State private var section: Section = Section(rawValue: ProcessInfo.processInfo.environment["PIOPIO_DEMO_SETTINGS_SECTION"] ?? "") ?? .providers

    enum Section: String, CaseIterable, Identifiable {
        case general = "General", providers = "Providers", engines = "Engines"
        var id: String { rawValue }
        var icon: (String, Color) {
            switch self {
            case .general: ("gearshape.fill", .gray)
            case .providers: ("key.fill", .blue)
            case .engines: ("cpu.fill", .green)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { s in
                    Button { section = s } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 5).fill(s.icon.1.gradient).frame(width: 20, height: 20)
                                .overlay(Image(systemName: s.icon.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
                            Text(s.rawValue).font(.system(size: 13))
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(section == s ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                    case .providers: ProvidersPane(engine: engine)
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

private struct PaneTitle: View {
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
private struct ListCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }
}

private struct Row<Trailing: View>: View {
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

// MARK: Providers

private struct ProvidersPane: View {
    let engine: EngineController
    @State private var replacing = false
    @State private var key = ""
    @State private var info: VerifyKeyResult?
    @State private var showDefault = false
    @State private var showQuick = false

    var body: some View {
        PaneTitle(title: "Providers", subtitle: "Where models come from. Everything is billed to your own accounts.")
        HStack {
            SectionLabel("Model providers")
            Spacer()
            Text("+ Add provider").font(.system(size: 12)).foregroundStyle(Color.dsFg3).help("More providers are coming")
        }
        .padding(.bottom, 6)
        ListCard {
            Row(title: "OpenRouter") {
                if replacing || !engine.hasKey {
                    SecureField("sk-or-v1-…", text: $key).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button("Save") {
                        Task {
                            try? await engine.saveKey(key)
                            key = ""
                            replacing = false
                            await refresh()
                        }
                    }
                    .buttonStyle(PillStyle(kind: .primary, compact: true))
                    .disabled(key.isEmpty)
                    if engine.hasKey { Button("Cancel") { replacing = false }.buttonStyle(PillStyle(compact: true)) }
                } else {
                    Text(info?.label ?? "Saved in Keychain").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg2).lineLimit(1).fixedSize()
                    if info?.ok == true { Text("✓ Verified").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsGreen) }
                    if let failed = info, !failed.ok { Text(failed.message ?? "Not verified").font(.system(size: 12)).foregroundStyle(Color.dsRed) }
                    Spacer()
                    if let usage = info?.usageUsd { Text(String(format: "$%.2f used", usage)).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
                    Button("Replace") { replacing = true }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 12))
                    Button("Remove") { Task { await engine.removeKey(); info = nil } }.buttonStyle(.plain).foregroundStyle(Color.dsRed).font(.system(size: 12))
                }
            }
            Row(title: "Default model") {
                Button(modelName(engine.preferredModel)) { showDefault = true }
                    .buttonStyle(PillStyle(compact: true))
                    .popover(isPresented: $showDefault) {
                        ModelPicker(engine: engine, selected: engine.preferredModel) { m in engine.setPreferredModel(m); showDefault = false }
                    }
                Text("Quick Chat uses").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Button(modelName(engine.quickChatModel)) { showQuick = true }
                    .buttonStyle(PillStyle(compact: true))
                    .popover(isPresented: $showQuick) {
                        ModelPicker(engine: engine, selected: engine.quickChatModel) { m in engine.setQuickChatModel(m); showQuick = false }
                    }
                Spacer()
            }
            Row(title: "ChatGPT", last: true) {
                Text("Subscription · sign in with OpenAI").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Spacer()
                Badge("Soon")
            }
        }
        Text("Keys are stored in the macOS Keychain. Cloud agents will receive them as secrets on their target, which you can revoke at any time.")
            .font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 10)
            .task { await refresh() }
    }

    private func modelName(_ ref: ModelRef?) -> String {
        engine.model(ref).map(ModelChip.short) ?? ref?.id ?? "Choose…"
    }

    private func refresh() async {
        guard engine.hasKey, let key = Keychain.read(secretOpenRouter), let client = engine.client else { return }
        info = try? await client.call("models.verifyKey", VerifyKeyParams(provider: "openrouter", key: key), as: VerifyKeyResult.self)
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
