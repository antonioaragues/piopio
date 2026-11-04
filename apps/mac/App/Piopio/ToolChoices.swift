import PiopioKit
import SwiftUI

/// Connectors and MCP servers a conversation can turn off for itself (docs/design/session-panel, step 3). Settings
/// decides what's on; here each one that's on can be switched off for this conversation only. Those off in Settings
/// are listed, greyed out, with why.
struct ToolChoice: Identifiable, Hashable {
    enum Group { case app, mcp }
    /// "connector:<id>" or "mcp:<server>", as the engine's `toolsOff` list names them.
    let id: String
    let group: Group
    let title: String
    /// It's on in Settings for this kind of conversation, so it can be switched here.
    let available: Bool
    /// Why it's greyed out, or what needs you ("Sign in again").
    let note: String?
}

@MainActor enum ToolChoices {
    /// Which kinds a conversation has: connectors in chats and Build sessions; MCP in chats, notebooks and Build.
    static func supports(_ ref: ContainerRef, debate: Bool) -> (apps: Bool, mcp: Bool) {
        switch ref.kind {
        case .thread: (!debate, !debate)
        case .build: (true, true)
        case .space: (false, true)
        case .agent: (false, false)
        }
    }

    /// The choices for a conversation, from the connected apps and the MCP servers (`mcp.list` for its folder).
    static func compute(engine: EngineController, ref: ContainerRef, debate: Bool, servers: [McpServerInfo]) -> [ToolChoice] {
        let kinds = supports(ref, debate: debate)
        var out: [ToolChoice] = []
        if kinds.apps {
            for app in engine.connectors where !app.accounts.isEmpty {
                let problem = app.accounts.contains { $0.problem != nil }
                out.append(ToolChoice(id: "connector:\(app.id)", group: .app, title: app.name, available: app.chats,
                                      note: !app.chats ? "Off for conversations in Settings" : problem ? "Sign in again in Settings" : nil))
            }
        }
        if kinds.mcp {
            let build = ref.kind == .build
            let chatOn = engine.settings?.chat.mcp ?? false
            var seen = Set<String>()
            // A project entry that only overrides a global one wins; one row per name.
            for server in servers.sorted(by: { ($0.scope == .project ? 0 : 1) < ($1.scope == .project ? 0 : 1) }) where !seen.contains(server.name) {
                if !build && server.scope == .project { continue }
                seen.insert(server.name)
                let available = build ? server.enabled : (chatOn && server.enabled && server.chat == true)
                out.append(ToolChoice(id: "mcp:\(server.name)", group: .mcp, title: server.name, available: available,
                                      note: available ? nil : build ? "Off in Settings" : "Off for chats in Settings"))
            }
        }
        return out
    }

    static func load(engine: EngineController, cwd: String?) async -> [McpServerInfo] {
        if engine.connectors.isEmpty { await engine.loadConnectors() }
        return (try? await engine.client?.call("mcp.list", McpListParams(cwd: cwd), as: McpListResult.self).servers) ?? []
    }

    static func openSettings(_ section: String) {
        UserDefaults.standard.set(section, forKey: "settingsSection")
        NotificationCenter.default.post(name: .settingsSection, object: section)
        WindowOpener.shared.openSettings?()
    }
}

/// The + menu's "Connectors and MCP" submenu: a switch per app and server, for this conversation.
struct ToolChoicesMenu: View {
    let choices: [ToolChoice]
    let off: Set<String>
    let set: (String, Bool) -> Void

    var body: some View {
        Menu {
            section("Connected apps", choices.filter { $0.group == .app })
            section("MCP servers", choices.filter { $0.group == .mcp })
            Divider()
            Button("Connectors in Settings…") { ToolChoices.openSettings("Connectors") }
            Button("MCP servers in Settings…") { ToolChoices.openSettings("MCP servers") }
        } label: {
            Label(summary, systemImage: "square.grid.2x2")
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [ToolChoice]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Toggle(isOn: Binding(get: { item.available && !off.contains(item.id) }, set: { set(item.id, $0) })) {
                        Text(item.title)
                        if let note = item.note { Text(note) }
                    }
                    .disabled(!item.available)
                }
            }
        }
    }

    /// "Connectors and MCP · 3 on".
    private var summary: String {
        let on = choices.filter { $0.available && !off.contains($0.id) }.count
        return choices.isEmpty ? "Connectors and MCP" : "Connectors and MCP · \(on) on"
    }
}
