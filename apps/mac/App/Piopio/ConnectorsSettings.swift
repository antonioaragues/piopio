import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// Signing in to an app (docs/spec/12-connectors): the browser opens; this follows until done or failed.
@MainActor @Observable final class ConnectorLogin {
    let connector: ConnectorInfo
    var loginId: String?
    var url: URL?
    var progress: String?
    var finished = false
    var error: String?

    init(connector: ConnectorInfo) { self.connector = connector }

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

/// Settings › Connectors: connect an app once and any chat can use it. Reading runs; changes ask first.
struct ConnectorsPane: View {
    let engine: EngineController
    @State private var settingUp: ConnectorInfo?
    @State private var disconnecting: ConnectorInfo.Account?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connectors").font(.system(size: 24, weight: .bold))
            Text("Connect an app once and any chat, notebook or agent can use it. Reading runs; anything that changes something asks you first.")
                .font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(engine.connectors) { c in
                ConnectorCard(engine: engine, connector: c, setUp: { settingUp = c }, disconnect: { disconnecting = $0 })
            }
            if engine.connectors.isEmpty {
                Text(engine.client == nil ? "The engine isn't running." : "Loading…").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
            }
            Text("More apps — Gmail, Google Drive, Slack, Jira, Notion, GitHub, Datadog — are coming.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        }
        .task { await engine.loadConnectors() }
        .sheet(item: $settingUp) { c in ConnectorSetupSheet(engine: engine, connector: c) }
        .sheet(isPresented: Binding(get: { engine.connectorLogin != nil }, set: { if !$0 { Task { await engine.cancelConnectorLogin() } } })) {
            if let login = engine.connectorLogin { ConnectorSignInSheet(engine: engine, login: login) }
        }
        .confirmationDialog(disconnecting.map { "Disconnect \($0.label)?" } ?? "", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }), presenting: disconnecting) { account in
            Button("Disconnect", role: .destructive) { Task { await engine.disconnect(account: account) } }
        } message: { _ in
            Text("Chats and agents stop using this account. Its sign-in is removed from this Mac.")
        }
    }
}

/// One app: its accounts, Connect, whether chats use it, and what it can do (reads run, changes ask).
private struct ConnectorCard: View {
    let engine: EngineController
    let connector: ConnectorInfo
    let setUp: () -> Void
    let disconnect: (ConnectorInfo.Account) -> Void
    @State private var expanded = false

    var body: some View {
        ListCard {
            HStack(spacing: 12) {
                ConnectorTile(id: connector.id)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(connector.name).font(.system(size: 13.5, weight: .semibold))
                        if !connector.accounts.isEmpty {
                            Text(connector.accounts.contains { $0.problem != nil } ? "● Needs attention" : "● Connected").font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(connector.accounts.contains { $0.problem != nil } ? Color.dsAmber : Color.dsGreen)
                        }
                    }
                    Text(connector.description).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(2)
                }
                Spacer(minLength: 12)
                if connector.connecting {
                    ProgressView().controlSize(.small)
                } else if !connector.ready {
                    Button("Set up…", action: setUp).buttonStyle(PillStyle(compact: true)).help("This app needs an OAuth client first")
                } else {
                    Button(connector.accounts.isEmpty ? "Connect" : "Add account") { Task { await engine.connect(connector) } }
                        .buttonStyle(PillStyle(kind: connector.accounts.isEmpty ? .primary : .secondary, compact: true))
                }
            }
            .padding(.horizontal, 14).frame(minHeight: 62)
            ForEach(connector.accounts) { account in
                Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 58)
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle").font(.system(size: 15)).foregroundStyle(Color.dsFg3).frame(width: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.label).font(.system(size: 12.5, weight: .medium))
                        if let problem = account.problem { Text(problem).font(.system(size: 11.5)).foregroundStyle(Color.dsAmber).lineLimit(2) }
                    }
                    Spacer()
                    if account.problem != nil {
                        Button("Reconnect") { Task { await engine.connect(connector) } }.buttonStyle(PillStyle(kind: .primary, compact: true))
                    }
                    Menu {
                        Button("Disconnect…", role: .destructive) { disconnect(account) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsFg2).frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .padding(.horizontal, 14).frame(minHeight: 44)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("What it can do")
                    Spacer()
                    if connector.ownClient { Text("Your OAuth client").foregroundStyle(Color.dsFg3) }
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
                .padding(.horizontal, 14).frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { details }
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { connector.chats }, set: { on in Task { try? await engine.configure(ConnectorConfigureParams(connector: connector.id, chats: on)) } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use in chats").font(.system(size: 12.5, weight: .medium))
                    Text("Chats, notebooks and Build sessions can use it. Agents always can.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            ForEach(connector.tools, id: \.name) { tool in
                HStack {
                    Text(tool.label).font(.system(size: 12.5))
                    Spacer()
                    switch tool.access {
                    case .read: Text("Runs").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                    case .write:
                        Menu {
                            Button("Asks first") { setDontAsk(tool.name, false) }
                            Button("Don't ask") { setDontAsk(tool.name, true) }
                        } label: { Text(tool.dontAsk ? "Don't ask" : "Asks first") }
                            .menuStyle(.button).buttonStyle(ChipStyle()).fixedSize()
                    case .send, .destructive: Text("Always asks").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsAmber)
                    }
                }
            }
            Button("Use your own OAuth client…", action: setUp).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor).padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    private func setDontAsk(_ tool: String, _ on: Bool) {
        var list = Set(connector.tools.filter(\.dontAsk).map(\.name))
        if on { list.insert(tool) } else { list.remove(tool) }
        Task { try? await engine.configure(ConnectorConfigureParams(connector: connector.id, dontAsk: Array(list))) }
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
        Image(systemName: symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }
}

/// Your own OAuth client, until Piopio's is registered (docs/spec/12 §2): the client ID, and Google's secret.
private struct ConnectorSetupSheet: View {
    let engine: EngineController
    let connector: ConnectorInfo
    @State private var clientId = ""
    @State private var secret = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ConnectorTile(id: connector.id, size: 36)
                Text("Set up \(connector.name)").font(.system(size: 17, weight: .bold))
            }
            Text("Piopio's own sign-in for \(connector.name) isn't registered yet. Until it is, use an OAuth client of your own. \(connector.setupHelp)")
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
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed) }
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

/// While you sign in in the browser; then connected, or why not.
private struct ConnectorSignInSheet: View {
    let engine: EngineController
    let login: ConnectorLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ConnectorTile(id: login.connector.id, size: 36)
                Text("Connect \(login.connector.name)").font(.system(size: 17, weight: .bold))
            }
            if login.finished {
                if let error = login.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Color.dsRed).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Connected. Any chat can use it now — try “What do I have tomorrow?”", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsGreen).fixedSize(horizontal: false, vertical: true)
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
