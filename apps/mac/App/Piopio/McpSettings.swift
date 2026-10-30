import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Settings › MCP servers (design handoff p0–p2 and the server page): servers from pi's mcp.json files, shared with
// the pi CLI. Each server is started to show its status and tools; where it's used (Build, chats) is chosen per
// server; tools can be turned off one by one. Servers set up in other apps are offered for import, never imported
// on their own.

/// A configured server and, for project servers, the project whose .pi/mcp.json has it.
struct McpEntry: Identifiable, Hashable {
    let server: McpServerInfo
    let project: ProjectInfo?
    var id: String { "\(project?.id ?? "global"):\(server.name)" }
    var cwd: String? { project?.path }

    var commandLine: String { server.url ?? ([server.command ?? ""] + (server.args ?? [])).joined(separator: " ") }

    /// "Build", "Build + Chat", "Chat", "Off".
    var usedIn: String {
        switch (server.enabled, server.chat == true) {
        case (true, true): "Build + Chat"
        case (true, false): "Build"
        case (false, true): "Chat"
        case (false, false): "Off"
        }
    }
}

// MARK: - p1 / p0 · MCP servers page

struct McpPane: View {
    let engine: EngineController
    @State private var entries: [McpEntry] = []
    @State private var waiting: [(project: ProjectInfo, count: Int)] = []
    @State private var statuses: [String: McpProbe] = [:]
    @State private var errors: [String] = []
    @State private var found: [McpDetectResult.Found] = []
    @State private var loaded = false
    @State private var detail: String?
    @State private var adding = false
    @State private var importing: McpDetectResult.Found?
    @State private var showWaiting = false

    var body: some View {
        Group {
            if let id = detail, let entry = entries.first(where: { $0.id == id }) {
                McpServerDetail(engine: engine, entry: entry, status: statuses[id], back: { detail = nil }, changed: { Task { await refresh() } }) { refreshed in
                    statuses[id] = refreshed
                }
            } else if loaded, entries.isEmpty, waiting.isEmpty {
                empty
            } else {
                page
            }
        }
        .task {
            await refresh()
            let env = ProcessInfo.processInfo.environment
            if env["PIOPIO_DEMO_ADD_MCP"] == "1" { adding = true }
            if let name = env["PIOPIO_DEMO_MCP_DETAIL"] { detail = entries.first { $0.server.name == name }?.id }
        }
        .sheet(isPresented: $adding) {
            AddMcpServerView(engine: engine, back: nil) {
                adding = false
                Task { await refresh() }
            }
            .frame(width: 600)
        }
        .sheet(item: $importing) { f in McpImportSheet(engine: engine, found: f) { Task { await refresh() } } }
    }

    // p1
    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "MCP servers", summary: summary) {
                AddButton(title: "Add server") { adding = true }
            }
            let global = entries.filter { $0.project == nil }
            if !global.isEmpty { group("For all projects", global) }
            ForEach(projectsWithServers, id: \.id) { project in
                group("In \(project.name) only", entries.filter { $0.project?.id == project.id })
            }
            if !waiting.isEmpty { waitingGroup }
            ForEach(found) { f in
                FoundCard(title: "\(f.servers.count) server\(f.servers.count == 1 ? "" : "s") in \(f.app)", detail: f.servers.map(\.name).joined(separator: ", ")) {
                    Button("Review & import") { importing = f }.buttonStyle(PillStyle(kind: .toolbar, compact: true))
                }
                .padding(.bottom, 14)
            }
            ForEach(errors, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Color.dsFg2).padding(.bottom, 6) }
            FinePrint("Changes apply to sessions you start or reopen.")
        }
    }

    private var summary: String {
        let tools = statuses.values.reduce(0) { $0 + $1.tools.count }
        return ["\(entries.count) server\(entries.count == 1 ? "" : "s")", tools > 0 ? "\(tools) tools" : nil, "shared with the pi CLI"].compactMap { $0 }.joined(separator: " · ")
    }

    private var projectsWithServers: [ProjectInfo] {
        var seen = Set<String>()
        return entries.compactMap(\.project).filter { seen.insert($0.id).inserted }
    }

    private func group(_ title: String, _ list: [McpEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title)
            ListCard {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, entry in
                    McpServerRow(entry: entry, status: statuses[entry.id]) { detail = entry.id }
                    if i < list.count - 1 { RowDivider() }
                }
            }
        }
        .padding(.bottom, 18)
    }

    /// Servers in projects you haven't trusted: pi doesn't load them until you do.
    private var waitingGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showWaiting.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showWaiting ? 90 : 0))
                    Text("Waiting for trust (\(waiting.reduce(0) { $0 + $1.count }))").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.dsFg2).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.bottom, 7)
            if showWaiting {
                ListCard {
                    ForEach(Array(waiting.enumerated()), id: \.element.project.id) { i, w in
                        HStack(spacing: 12) {
                            InitialTile(name: w.project.name, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(w.project.name).font(.system(size: 13, weight: .medium))
                                Text("\(w.count) server\(w.count == 1 ? "" : "s") in .pi/mcp.json, not loaded until you trust the project").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                            }
                            Spacer()
                            Button("Trust project…") { trust(w.project) }.buttonStyle(PillStyle(compact: true))
                        }
                        .padding(.horizontal, 14).frame(minHeight: 50)
                        if i < waiting.count - 1 { RowDivider(inset: 52) }
                    }
                }
            }
        }
        .padding(.bottom, 18)
    }

    // p0
    private var empty: some View {
        SettingsEmpty(title: "Give the agent more tools", message: "MCP servers add tools like a browser, a database or your company's APIs. Piopio shares them with the pi CLI.") {
            Button { adding = true } label: { Label("Add server", systemImage: "plus").font(.system(size: 12.5, weight: .semibold)) }
                .buttonStyle(PillStyle(kind: .strong))
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Found in other apps").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
                    ForEach(found) { f in
                        FoundCard(title: "\(f.servers.count) server\(f.servers.count == 1 ? "" : "s") in \(f.app)", detail: f.servers.map(\.name).joined(separator: ", ")) {
                            Button("Review & import") { importing = f }.buttonStyle(PillStyle(kind: .toolbar, compact: true))
                        }
                    }
                }
                .padding(.top, 22)
            }
        }
    }

    private func trust(_ project: ProjectInfo) {
        let alert = NSAlert()
        alert.messageText = "Trust \(project.name)?"
        alert.informativeText = "Its .pi folder loads: extensions, MCP servers, prompts and skills. They run with your permissions in Build sessions. Shared with the pi CLI."
        alert.addButton(withTitle: "Trust")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await engine.setTrust(true, for: project)
            await refresh()
        }
    }

    private func refresh() async {
        guard let client = engine.client else { return }
        var all: [McpEntry] = []
        var waits: [(ProjectInfo, Int)] = []
        var errs: [String] = []
        if let global = try? await client.call("mcp.list", McpListParams(), as: McpListResult.self) {
            all += global.servers.map { McpEntry(server: $0, project: nil) }
            errs += global.errors
        }
        for project in engine.projects where project.missing != true {
            guard let result = try? await client.call("mcp.list", McpListParams(cwd: project.path), as: McpListResult.self) else { continue }
            let own = result.servers.filter { $0.scope == .project && $0.override != true }
            if project.trust == .trusted { all += own.map { McpEntry(server: $0, project: project) } } else if !own.isEmpty { waits.append((project, own.count)) }
            errs += result.errors.filter { !errs.contains($0) }
        }
        entries = all
        waiting = waits
        errors = errs
        found = (try? await client.call("mcp.detect", Empty(), as: McpDetectResult.self).found) ?? []
        loaded = true
        // Each server's status, started in parallel (the engine keeps them a while).
        await withTaskGroup(of: (String, McpProbe?).self) { group in
            for entry in all where statuses[entry.id] == nil {
                group.addTask { (entry.id, try? await client.call("mcp.status", McpStatusParams(scope: entry.server.scope, cwd: entry.cwd, name: entry.server.name), as: McpProbe.self)) }
            }
            for await (id, status) in group { if let status { statuses[id] = status } }
        }
    }
}

/// One server (p1): tile, name, status, its command or URL and tool count, where it's used.
private struct McpServerRow: View {
    let entry: McpEntry
    let status: McpProbe?
    let open: () -> Void

    var body: some View {
        SettingsListRow(name: entry.server.name, dot: McpServerRow.dot(status), open: open) {
            LetterTile(text: LetterTile.initials(entry.server.name), color: InitialTile.color(for: entry.server.name), size: 34)
        } subtitle: {
            if let status, !status.ok {
                Text(status.error ?? "Couldn't start").foregroundStyle(McpServerRow.dot(status) ?? .dsFg2)
            } else {
                HStack(spacing: 0) {
                    Text(entry.commandLine).font(.system(size: 12, design: .monospaced)).truncationMode(.middle)
                    Text([status.map { "\($0.tools.count) tool\($0.tools.count == 1 ? "" : "s")" } ?? "starting…", entry.project != nil ? "trusted project" : nil].compactMap { $0 }.map { " · \($0)" }.joined())
                        .fixedSize()
                }
            }
        } trailing: {
            SettingsBadge(entry.usedIn)
        }
    }

    /// Green: started. Amber: wants a sign-in. Red: didn't start. None while starting.
    static func dot(_ status: McpProbe?) -> Color? {
        guard let status else { return nil }
        if status.ok { return .dsFg3 }
        return status.error?.contains("sign in") == true ? .dsAmber : .dsFg2
    }
}

// MARK: - Server page

private struct McpServerDetail: View {
    let engine: EngineController
    let entry: McpEntry
    let status: McpProbe?
    let back: () -> Void
    let changed: () -> Void
    let restarted: (McpProbe) -> Void
    @State private var restarting = false
    @State private var showingLog = false
    @State private var removing = false

    private var server: McpServerInfo { entry.server }
    private var hidden: Set<String> { Set(server.hiddenTools ?? []) }

    var body: some View {
        SettingsDetail(back: "MCP servers", title: server.name, goBack: back, footer: "Sessions stop using its tools when you start or reopen them.", remove: "Remove server…", onRemove: { removing = true }) {
            LetterTile(text: LetterTile.initials(server.name), color: InitialTile.color(for: server.name), size: 48)
        } status: {
            if restarting || status == nil {
                StatusText(color: .dsFg3, text: "Starting…")
            } else if let status, status.ok {
                StatusText(color: .dsFg3, text: "Started · \(status.tools.count) tool\(status.tools.count == 1 ? "" : "s")\(status.ms.map { " · " + Self.seconds($0) } ?? "")")
            } else {
                StatusText(color: McpServerRow.dot(status) ?? .dsFg2, text: status?.error ?? "Couldn't start")
            }
        } actions: {
            if status?.log?.isEmpty == false { Button("View log") { showingLog = true }.buttonStyle(PillStyle(compact: true)) }
            Button("Restart") { restart() }.buttonStyle(PillStyle(compact: true)).disabled(restarting)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("Connection")
                ListCard {
                    info(server.url != nil ? "URL" : "Command", entry.commandLine, mono: true)
                    info("Environment", server.env?.joined(separator: ", ") ?? "None", mono: server.env != nil)
                    if let description = server.description { info("Description", description) }
                    info("Available to", entry.project.map { "\($0.name) only" } ?? "All projects", last: true)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("Where it's used")
                ListCard {
                    ToggleRow(title: "Use in Build sessions", subtitle: "Follows your Approvals settings", isOn: Binding(get: { server.enabled }, set: { on in
                        call("mcp.setEnabled", McpNameParams(scope: server.scope, cwd: entry.cwd, name: server.name, enabled: on))
                    }))
                    if entry.project == nil {
                        ToggleRow(title: "Use in chats and notebooks", subtitle: "Tools run there without asking", subtitleColor: .dsAmber, last: true, isOn: Binding(get: { server.chat == true }, set: { on in
                            call("mcp.setChat", McpSetChatParams(name: server.name, chat: on))
                        }))
                    } else {
                        ToggleRow(title: "Use in chats and notebooks", subtitle: "Project servers are for Build sessions in that project", last: true, isOn: .constant(false)).disabled(true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("Tools", detail: status.map { "\($0.tools.count - $0.tools.filter { hidden.contains($0.name) }.count) of \($0.tools.count) on" })
                ListCard {
                    let tools = status?.tools ?? []
                    if tools.isEmpty {
                        Text(status == nil ? "Starting the server…" : "Its tools show once it starts.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    }
                    ForEach(Array(tools.enumerated()), id: \.element.name) { i, tool in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(hidden.contains(tool.name) ? Color.dsFg3 : Color.dsFg)
                                if let d = tool.description { Text(d).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1) }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { !hidden.contains(tool.name) }, set: { on in
                                call("mcp.setTool", McpSetToolParams(scope: server.scope, cwd: entry.cwd, name: server.name, tool: tool.name, enabled: on))
                            }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        }
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        if i < tools.count - 1 { RowDivider(inset: 14) }
                    }
                }
            }
        }
        .sheet(isPresented: $showingLog) { McpLogSheet(name: server.name, log: status?.log ?? "") }
        .alert("Remove \(server.name)?", isPresented: $removing) {
            Button("Remove", role: .destructive) {
                Task {
                    _ = try? await engine.client?.call("mcp.remove", McpNameParams(scope: server.scope, cwd: entry.cwd, name: server.name), as: Empty.self)
                    changed()
                    back()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from \(entry.project == nil ? "~/.pi/agent/mcp.json" : ".pi/mcp.json"), for the pi CLI too.")
        }
    }

    static func seconds(_ ms: Double) -> String { ms < 1000 ? "\(Int(ms)) ms" : String(format: "%.1f s", ms / 1000) }

    private func info(_ label: String, _ value: String, mono: Bool = false, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).frame(width: 110, alignment: .leading)
                Text(value).font(.system(size: 12.5, design: mono ? .monospaced : .default)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            if !last { RowDivider(inset: 14) }
        }
    }

    private func call<P: Encodable & Sendable>(_ method: String, _ params: P) {
        Task {
            _ = try? await engine.client?.call(method, params, as: Empty.self)
            changed()
        }
    }

    private func restart() {
        restarting = true
        Task {
            if let r = try? await engine.client?.call("mcp.status", McpStatusParams(scope: server.scope, cwd: entry.cwd, name: server.name, refresh: true), as: McpProbe.self) { restarted(r) }
            restarting = false
        }
    }
}

private struct McpLogSheet: View {
    let name: String
    let log: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(name) · log").font(.system(size: 17, weight: .bold))
            ScrollView {
                Text(log.isEmpty ? "Nothing was written." : log).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(height: 320)
            .settingsRows()
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 620)
    }
}

// MARK: - Import from other apps

private struct McpImportSheet: View {
    let engine: EngineController
    let found: McpDetectResult.Found
    let done: () -> Void
    @State private var picked: Set<String> = []
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import from \(found.app)").font(.system(size: 17, weight: .bold))
                Text("Copied to ~/.pi/agent/mcp.json for every project. Nothing changes in \(found.app).").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            }
            ListCard {
                ForEach(Array(found.servers.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(get: { picked.contains(s.name) }, set: { if $0 { picked.insert(s.name) } else { picked.remove(s.name) } })).toggleStyle(.checkbox).labelsHidden()
                        LetterTile(text: LetterTile.initials(s.name), color: InitialTile.color(for: s.name), size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).font(.system(size: 13, weight: .semibold))
                            Text(s.url ?? ([s.command ?? ""] + (s.args ?? [])).joined(separator: " ")).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let env = s.env, !env.isEmpty { Text("\(env.count) env").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
                    }
                    .padding(.horizontal, 14).frame(minHeight: 48)
                    if i < found.servers.count - 1 { RowDivider(inset: 54) }
                }
            }
            FinePrint("They're used in Build sessions. Turn each on for chats on its page.")
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            HStack {
                Text(found.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(picked.count == 1 ? "Import 1 server" : "Import \(picked.count) servers") { importPicked() }
                    .buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { picked = Set(found.servers.map(\.name)) }
    }

    private func importPicked() {
        Task {
            do {
                for s in found.servers where picked.contains(s.name) {
                    _ = try await engine.client?.call("mcp.add", McpAddParams(scope: .global, cwd: nil, name: s.name, command: s.command, args: s.args, url: s.url, description: nil, env: s.env), as: Empty.self)
                }
                done()
                dismiss()
            } catch {
                self.error = (error as? EngineError)?.message ?? error.localizedDescription
            }
        }
    }
}

// MARK: - p2 · Add server

struct AddMcpServerView: View {
    let engine: EngineController
    /// Back to the Add connector catalog, when opened from there.
    let back: (() -> Void)?
    let done: () -> Void
    @State private var mode: Mode = .command
    @State private var name = ""
    // Captures: PIOPIO_DEMO_MCP_COMMAND fills in the command.
    @State private var command = ProcessInfo.processInfo.environment["PIOPIO_DEMO_MCP_COMMAND"] ?? ""
    @State private var url = ""
    @State private var json = ""
    @State private var jsonError: String?
    @State private var oneProject = false
    @State private var projectId = ""
    @State private var env: [HeaderRow] = []
    @State private var showEnv = false
    @State private var build = true
    @State private var chat = false
    @State private var probe: McpProbe?
    @State private var probing = false
    @State private var error: String?

    enum Mode: String, CaseIterable { case command = "Command", url = "URL", json = "Paste JSON" }

    private var target: String { mode == .url ? url : command }
    private var project: ProjectInfo? { oneProject ? engine.projects.first { $0.id == projectId } : nil }
    private var probeKey: String { "\(mode.rawValue)|\(target)|\(env.map { "\($0.name)=\($0.value)" }.joined(separator: ","))" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let back {
                Button(action: back) { Label("All connectors", systemImage: "chevron.left").font(.system(size: 12.5)) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).padding(.bottom, 12)
            }
            Text("Add an MCP server").font(.system(size: 17, weight: .bold))
            Text("Run a command on this Mac, or connect to a URL").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).padding(.top, 2)
            Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 14).padding(.bottom, 12)
            if mode == .json { jsonForm } else { form }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2).padding(.top, 8) }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved to \(project.map { "\($0.name)/.pi/mcp.json" } ?? "~/.pi/agent/mcp.json")")
                    Text("Or in a terminal: pi mcp add").font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                Spacer()
                Button("Cancel", action: done).buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(probe?.ok == false ? "Add anyway" : "Add server") { add() }
                    .buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(mode == .json || name.isEmpty || target.trimmingCharacters(in: .whitespaces).isEmpty || probing || probe == nil)
            }
            .padding(.top, 16)
        }
        .padding(22)
        .background(Color.dsWin)
        .task(id: probeKey) {
            // The server is started a moment after you stop typing.
            probe = nil
            guard mode != .json, !target.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await runProbe()
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            ListCard {
                row("Name") {
                    TextField(suggestedName.isEmpty ? "playwright" : suggestedName, text: $name).textFieldStyle(.plain).font(.system(size: 13))
                }
                row(mode == .url ? "URL" : "Command", highlight: true) {
                    TextField(mode == .url ? "https://example.com/mcp" : "npx @playwright/mcp@latest", text: mode == .url ? $url : $command)
                        .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced))
                        .onSubmit { Task { await runProbe() } }
                    probeStatus
                }
                row("Available to") {
                    Picker("", selection: $oneProject) { Text("All projects").tag(false); Text("One project…").tag(true) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if oneProject {
                        Picker("", selection: $projectId) {
                            Text("Choose…").tag("")
                            ForEach(engine.projects) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button { withAnimation(.easeOut(duration: 0.15)) { showEnv.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showEnv ? 90 : 0))
                            Text("Environment variables\(env.isEmpty ? "" : " (\(env.count))")").font(.system(size: 12.5))
                            Text("${NAME} reads it from your environment").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                        }
                        .foregroundStyle(Color.dsFg2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showEnv { envEditor }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let probe, probe.ok {
                HStack(spacing: 8) {
                    Text("Found \(probe.tools.count) tool\(probe.tools.count == 1 ? "" : "s")").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(toolPreview(probe)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.tail)
                }
                .padding(.top, 14).padding(.bottom, 7)
            } else {
                Text("Where it's used").font(.system(size: 13, weight: .semibold)).padding(.top, 14).padding(.bottom, 7)
            }
            ListCard {
                ToggleRow(title: "Use in Build sessions", subtitle: "Follows your Approvals settings", isOn: $build)
                if oneProject {
                    ToggleRow(title: "Use in chats and notebooks", subtitle: "Project servers are for Build sessions in that project", last: true, isOn: .constant(false)).disabled(true)
                } else {
                    ToggleRow(title: "Use in chats and notebooks", subtitle: "Tools run there without asking", subtitleColor: .dsAmber, last: true, isOn: $chat)
                }
            }
        }
    }

    private var jsonForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $json)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 200)
                .settingsRows()
                .overlay(alignment: .topLeading) {
                    if json.isEmpty {
                        Text("{ \"mcpServers\": { \"playwright\": { \"command\": \"npx\", \"args\": [\"@playwright/mcp@latest\"] } } }")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg3).padding(13).allowsHitTesting(false)
                    }
                }
            Text(jsonError ?? "Paste a server from a README or another app's config; it fills in the form.").font(.system(size: 11.5)).foregroundStyle(jsonError == nil ? Color.dsFg3 : Color.dsFg2)
        }
        .onChange(of: json) { _, text in fill(from: text) }
    }

    @ViewBuilder private var probeStatus: some View {
        if probing {
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Starting…") }.font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize()
        } else if let probe {
            if probe.ok {
                StatusText(color: .dsFg3, text: "Started\(probe.ms.map { " · " + McpServerDetailSeconds.text($0) } ?? "")").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg3).fixedSize()
            } else {
                Text(probe.error ?? "Couldn't start").font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(2).frame(maxWidth: 220, alignment: .trailing).help(probe.log ?? "")
            }
        }
    }

    private var envEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($env) { $row in
                HStack(spacing: 6) {
                    TextField("NAME", text: $row.name).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 150)
                    TextField("value or ${NAME}", text: $row.value).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button { env.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle").foregroundStyle(Color.dsFg3) }.buttonStyle(.plain)
                }
            }
            Button { env.append(HeaderRow(name: "", value: "")) } label: { Label("Add variable", systemImage: "plus") }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
            Text("Saved in mcp.json as written, where the pi CLI reads it too. Keep secrets in your shell and use ${NAME}.").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
        }
    }

    private func row<Content: View>(_ label: String, highlight: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).frame(width: 110, alignment: .leading)
                content()
            }
            .padding(.horizontal, 14).frame(minHeight: 42)
            .background(highlight && probe?.ok == true ? Color.dsAccentSoft.opacity(0.6) : .clear)
            RowDivider(inset: 0)
        }
    }

    /// "playwright" from "npx @playwright/mcp@latest" or "https://mcp.linear.app/mcp".
    private var suggestedName: String {
        if mode == .url, let host = URL(string: url)?.host {
            let parts = host.split(separator: ".")
            return String(parts.count >= 2 ? parts[parts.count - 2] : parts.first ?? "")
        }
        let runners: Set<String> = ["npx", "uvx", "uv", "run", "node", "python", "python3", "bunx", "bun", "pnpm", "dlx", "deno", "docker"]
        let words = Self.split(command).filter { !$0.hasPrefix("-") && !runners.contains(URL(fileURLWithPath: $0).lastPathComponent) }
        guard let pkg = words.first else { return "" }
        var base: String
        if pkg.hasPrefix("/") || pkg.hasPrefix("~") || pkg.hasPrefix(".") {
            base = URL(fileURLWithPath: pkg).deletingPathExtension().lastPathComponent
        } else {
            base = pkg.split(separator: "@").first { !$0.isEmpty }.map(String.init) ?? pkg
            let parts = base.split(separator: "/").map(String.init)
            // "@playwright/mcp" → playwright; "@modelcontextprotocol/server-github" → github.
            base = parts.count > 1 && ["mcp", "server", "mcp-server"].contains(parts[1]) ? parts[0] : parts.last ?? base
        }
        for affix in ["mcp-server-", "server-", "mcp-"] where base.hasPrefix(affix) && base.count > affix.count { base.removeFirst(affix.count) }
        for affix in ["-mcp-server", "-server", "-mcp"] where base.hasSuffix(affix) && base.count > affix.count { base.removeLast(affix.count) }
        return base.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func toolPreview(_ p: McpProbe) -> String {
        let names = p.tools.prefix(3).map(\.name).joined(separator: ", ")
        return p.tools.count > 3 ? "\(names) +\(p.tools.count - 3)" : names
    }

    private var envMap: [String: String]? {
        let pairs = env.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) }
        return pairs.isEmpty ? nil : Dictionary(pairs, uniquingKeysWith: { $1 })
    }

    private func runProbe() async {
        guard let client = engine.client else { return }
        probing = true
        defer { probing = false }
        let words = Self.split(command)
        let params = McpProbeParams(command: mode == .url ? nil : words.first, args: mode == .url ? nil : Array(words.dropFirst()), url: mode == .url ? url.trimmingCharacters(in: .whitespaces) : nil, env: envMap)
        probe = try? await client.call("mcp.probe", params, as: McpProbe.self)
        if name.isEmpty, probe?.ok == true { name = suggestedName }
    }

    /// A standard `mcpServers` block, a `{ name: server }` map, or one server: fills the form.
    private func fill(from text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { jsonError = nil; return }
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { jsonError = "That isn't valid JSON yet."; return }
        var serverName: String?
        var spec: [String: Any] = obj
        let map = (obj["mcpServers"] ?? obj["servers"]) as? [String: Any]
        if let map, let first = map.first, let s = first.value as? [String: Any] { serverName = first.key; spec = s }
        else if obj["command"] == nil, obj["url"] == nil, let first = obj.first, let s = first.value as? [String: Any] { serverName = first.key; spec = s }
        guard spec["command"] != nil || spec["url"] != nil || spec["serverUrl"] != nil else { jsonError = "No server found: it needs a “command” or a “url”."; return }
        jsonError = nil
        if let serverName { name = serverName.replacingOccurrences(of: " ", with: "-") }
        if let u = (spec["url"] ?? spec["serverUrl"]) as? String {
            url = u
            mode = .url
        } else if let c = spec["command"] as? String {
            command = ([c] + ((spec["args"] as? [Any])?.map { "\($0)" } ?? [])).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
            mode = .command
        }
        if let e = spec["env"] as? [String: Any] { env = e.map { HeaderRow(name: $0.key, value: "\($0.value)") }.sorted { $0.name < $1.name }; showEnv = true }
    }

    private func add() {
        let words = Self.split(command)
        let p = project
        let params = McpAddParams(scope: p == nil ? .global : .project, cwd: p?.path, name: name.trimmingCharacters(in: .whitespaces),
                                  command: mode == .url ? nil : words.first, args: mode == .url ? nil : Array(words.dropFirst()), url: mode == .url ? url.trimmingCharacters(in: .whitespaces) : nil,
                                  description: nil, env: envMap, enabled: build ? nil : false, chat: p == nil ? chat : nil)
        Task {
            do {
                _ = try await engine.client?.call("mcp.add", params, as: Empty.self)
                done()
            } catch {
                self.error = (error as? EngineError)?.message ?? String(describing: error)
            }
        }
    }

    /// Splits a command line on spaces, keeping quoted parts together.
    static func split(_ line: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?
        for ch in line.trimmingCharacters(in: .whitespaces) {
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

enum McpServerDetailSeconds {
    static func text(_ ms: Double) -> String { ms < 1000 ? "\(Int(ms)) ms" : String(format: "%.1f s", ms / 1000) }
}
