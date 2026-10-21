import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Settings › Extensions (docs/spec/07-shared-resources §6.1) and the memory providers of Settings › Chat (§6.2).
// No Piopio plugin format: pi packages (shared with the pi CLI) and memory systems behind MCP servers.

struct ExtensionsPane: View {
    let engine: EngineController
    @State private var packages: [PiPackage] = []
    @State private var source = ""
    @State private var working: String?
    @State private var error: String?

    var body: some View {
        PaneTitle(title: "Extensions", subtitle: "pi packages: extensions for Build; skills and prompt templates for every mode. Shared with the pi CLI.")
        HStack(spacing: 8) {
            TextField("npm:@scope/name, git:github.com/user/repo or a folder", text: $source)
                .textFieldStyle(.roundedBorder)
                .onSubmit(install)
            Button("Choose Folder…") { chooseFolder() }.buttonStyle(PillStyle(compact: true))
            Button(working == "install" ? "Installing…" : "Install") { install() }
                .buttonStyle(PillStyle(kind: .primary, compact: true))
                .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || working != nil)
        }
        .padding(.bottom, 8)
        if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed).padding(.bottom, 8) }
        HStack {
            SectionLabel("Installed")
            Spacer()
            Button(working == "update" ? "Updating…" : "Update All") { act("update") { try await engine.spaceCall("packages.update", PackageParams(source: nil)) } }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor).disabled(packages.isEmpty || working != nil)
        }
        .padding(.bottom, 6)
        ListCard {
            if packages.isEmpty {
                Row(title: "None yet", last: true) {
                    Text("Find packages at pi.dev/packages, or install with `pi install` in a terminal.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Spacer()
                }
            }
            ForEach(packages) { p in
                Row(title: name(p), last: p.id == packages.last?.id) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.source).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg2).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 10) {
                            kind(p, "extensions", "Extensions", p.resources.extensions.count)
                            kind(p, "skills", "Skills", p.resources.skills.count)
                            kind(p, "prompts", "Templates", p.resources.prompts.count)
                            if !p.installed { Text("not installed").font(.system(size: 11)).foregroundStyle(Color.dsRed) }
                        }
                    }
                    Spacer()
                    Button { act("remove") { try await engine.spaceCall("packages.remove", PackageParams(source: p.source)) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Remove")
                    Toggle("", isOn: Binding(get: { p.enabled }, set: { on in act("toggle") { try await engine.spaceCall("packages.setEnabled", PackageEnableParams(source: p.source, enabled: on)) } }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
        }
        Text("Extensions run in Build only, with your permissions. Skills and templates are text, so Threads, Notebooks and Agents use them too. Terminal-UI parts of an extension don't show in Piopio.")
            .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).padding(.top, 8)
            .task { await load() }
    }

    private func name(_ p: PiPackage) -> String {
        let s = p.source.replacingOccurrences(of: "npm:", with: "").replacingOccurrences(of: "git:", with: "")
        return URL(fileURLWithPath: s).lastPathComponent
    }

    /// "Skills 2" as a checkbox: that kind of resource on or off.
    @ViewBuilder private func kind(_ p: PiPackage, _ key: String, _ title: String, _ count: Int) -> some View {
        if count > 0 || p.off.contains(key) {
            Toggle("\(title) \(count)", isOn: Binding(get: { !p.off.contains(key) }, set: { on in act("toggle") { try await engine.spaceCall("packages.setEnabled", PackageEnableParams(source: p.source, enabled: on, kinds: [key])) } }))
                .toggleStyle(.checkbox).font(.system(size: 11.5))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url.path
    }

    private func install() {
        let s = source.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Install \(s)?"
        alert.informativeText = "A pi package can add extensions that run code with your permissions in Build sessions, and skills that tell the agent what to do. Install packages you trust; check the source first."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        act("install") {
            try await engine.spaceCall("packages.install", PackageParams(source: s))
            source = ""
        }
    }

    private func act(_ what: String, _ work: @escaping () async throws -> Void) {
        working = what
        error = nil
        Task {
            do { try await work() } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
            working = nil
            await load()
        }
    }

    private func load() async {
        packages = (try? await engine.client?.call("packages.list", Empty(), as: PackagesResult.self).packages) ?? []
    }
}

// MARK: Memory providers

/// Where About me lives, and the MCP memory providers (07-shared §6.2).
struct MemoryProvidersSection: View {
    let engine: EngineController
    @State private var editing: McpMemoryProvider?
    @State private var trying: McpMemoryProvider?

    private var providers: [McpMemoryProvider] { engine.settings?.memory.providers ?? [] }

    var body: some View {
        HStack {
            SectionLabel("Memory providers")
            Spacer()
            Button("+ MCP memory") { editing = McpMemoryProvider(id: UUID().uuidString.lowercased(), name: "", tools: .init(recall: .init(tool: "", args: [:]))) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
        }
        .padding(.bottom, 6)
        ListCard {
            Row(title: "Built-in", last: providers.isEmpty) {
                Text("On this Mac: facts and messages with their sources, keyword search and recency").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Spacer()
            }
            ForEach(providers) { p in
                Row(title: p.name, last: p.id == providers.last?.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.url ?? "MCP server “\(p.server ?? "")”").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg2).lineLimit(1)
                        if p.tools.list == nil { Text("Limited visibility: it can't list what it stores").font(.system(size: 11)).foregroundStyle(Color.dsAmber) }
                    }
                    Spacer()
                    Button("Try…") { trying = p }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    Button("Edit…") { editing = p }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    Button { save(providers.filter { $0.id != p.id }) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Color.dsFg3)
                }
            }
        }
        .sheet(item: $editing) { p in
            McpMemoryEditor(engine: engine, provider: p) { saved in
                save(providers.contains { $0.id == saved.id } ? providers.map { $0.id == saved.id ? saved : $0 } : providers + [saved])
            }
        }
        .sheet(item: $trying) { p in MemoryTrySheet(engine: engine, provider: p) }
    }

    private func save(_ next: [McpMemoryProvider]) {
        Task {
            var patch = SettingsPatch(memory: .init(providers: next))
            if let current = engine.settings?.aboutMe.provider, current != "builtin", !next.contains(where: { $0.id == current }) { patch.aboutMe = .init(provider: "builtin") }
            await engine.updateSettings(patch)
        }
    }
}

/// An MCP memory provider: the server (or URL), then a tool and its arguments for each operation.
struct McpMemoryEditor: View {
    let engine: EngineController
    @State var provider: McpMemoryProvider
    let onSave: (McpMemoryProvider) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var useURL = false
    @State private var servers: [String] = []
    @State private var tools: [MemoryToolsResult.Tool] = []
    @State private var args: [String: String] = [:]
    @State private var toolNames: [String: String] = [:]
    @State private var error: String?

    private static let ops = [("recall", "Recall (required)"), ("retain", "Retain"), ("list", "List"), ("forget", "Forget"), ("reflect", "Reflect")]

    init(engine: EngineController, provider: McpMemoryProvider, onSave: @escaping (McpMemoryProvider) -> Void) {
        self.engine = engine
        self._provider = State(initialValue: provider)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(provider.name.isEmpty ? "MCP memory provider" : provider.name).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Use the Hindsight preset") { hindsight() }.buttonStyle(PillStyle(compact: true))
            }
            TextField("Name", text: $provider.name).textFieldStyle(.roundedBorder)
            Picker("", selection: $useURL) {
                Text("MCP server").tag(false)
                Text("URL").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            HStack {
                if useURL {
                    TextField("http://127.0.0.1:8888/mcp", text: Binding(get: { provider.url ?? "" }, set: { provider.url = $0; provider.server = nil }))
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Server", selection: Binding(get: { provider.server ?? "" }, set: { provider.server = $0; provider.url = nil })) {
                        Text("Choose…").tag("")
                        ForEach(servers, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button("Load Tools") { Task { await loadTools() } }.buttonStyle(PillStyle(compact: true))
            }
            Text("Arguments are JSON; {bank}, {query}, {content}, {source}, {at}, {id}, {limit} and {budget} are filled in.").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            ForEach(Self.ops, id: \.0) { op, title in
                HStack(alignment: .top) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).frame(width: 110, alignment: .leading)
                    Picker("", selection: Binding(get: { toolNames[op] ?? "" }, set: { toolNames[op] = $0 })) {
                        Text("None").tag("")
                        ForEach(Array(Set(tools.map(\.name) + [toolNames[op] ?? ""]).filter { !$0.isEmpty }).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                    TextField("{\"query\": \"{query}\"}", text: Binding(get: { args[op] ?? "" }, set: { args[op] = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced))
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(provider.name.trimmingCharacters(in: .whitespaces).isEmpty || (toolNames["recall"] ?? "").isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            servers = (try? await engine.client?.call("mcp.list", McpListParams(cwd: nil), as: McpListResult.self).servers.filter { $0.scope == .global }.map(\.name)) ?? []
            useURL = provider.url != nil
            load(provider.tools)
        }
    }

    private func load(_ t: McpMemoryProvider.Tools) {
        for (op, mapping) in [("recall", t.recall as McpMemoryProvider.Mapping?), ("retain", t.retain), ("list", t.list), ("forget", t.forget), ("reflect", t.reflect)] {
            guard let mapping, !mapping.tool.isEmpty else { continue }
            toolNames[op] = mapping.tool
            args[op] = (try? String(data: JSONEncoder.sorted.encode(mapping.args), encoding: .utf8)) ?? "{}"
        }
    }

    private func hindsight() {
        if provider.name.isEmpty { provider.name = "Hindsight" }
        provider.url = "http://127.0.0.1:8888/mcp"
        provider.server = nil
        useURL = true
        let s: (String) -> JSONValue = { .string($0) }
        load(.init(
            recall: .init(tool: "recall", args: ["query": s("{query}"), "bank_id": s("{bank}"), "max_tokens": s("{budget}"), "budget": s("mid")]),
            retain: .init(tool: "retain", args: ["content": s("{content}"), "bank_id": s("{bank}"), "timestamp": s("{at}"), "context": s("{source}")]),
            list: .init(tool: "list_memories", args: ["bank_id": s("{bank}"), "limit": s("{limit}")]),
            forget: .init(tool: "invalidate_memory", args: ["memory_id": s("{id}"), "bank_id": s("{bank}"), "reason": s("Forgotten in Piopio")]),
            reflect: .init(tool: "reflect", args: ["query": s("{query}"), "bank_id": s("{bank}")])
        ))
    }

    private func loadTools() async {
        error = nil
        do {
            tools = try await engine.client?.call("memory.tools", MemoryToolsParams(server: useURL ? nil : provider.server, url: useURL ? provider.url : nil), as: MemoryToolsResult.self).tools ?? []
        } catch {
            self.error = (error as? EngineError)?.message ?? String(describing: error)
        }
    }

    private func mapping(_ op: String) throws -> McpMemoryProvider.Mapping? {
        guard let tool = toolNames[op], !tool.isEmpty else { return nil }
        let text = (args[op] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .init(tool: tool, args: [:]) }
        guard let data = text.data(using: .utf8), let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw EngineError(code: "INVALID", message: "The \(op) arguments aren't a JSON object.")
        }
        return .init(tool: tool, args: parsed)
    }

    private func save() {
        do {
            guard let recall = try mapping("recall") else { return }
            provider.tools = .init(recall: recall, retain: try mapping("retain"), list: try mapping("list"), forget: try mapping("forget"), reflect: try mapping("reflect"))
            onSave(provider)
            dismiss()
        } catch {
            self.error = (error as? EngineError)?.message ?? String(describing: error)
        }
    }
}

/// Try a provider: what it recalls from a bank.
struct MemoryTrySheet: View {
    let engine: EngineController
    let provider: McpMemoryProvider
    @Environment(\.dismiss) private var dismiss
    @State private var bank = "about-me"
    @State private var query = ""
    @State private var hits: [MemoryRecallResult.Hit] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try \(provider.name)").font(.system(size: 15, weight: .semibold))
            HStack {
                TextField("Bank", text: $bank).textFieldStyle(.roundedBorder).frame(width: 140)
                TextField("What do you want to find?", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await recall() } }
                Button("Recall") { Task { await recall() } }.buttonStyle(PillStyle(kind: .primary, compact: true))
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed) }
            List(hits, id: \.self) { h in Text(h.text).font(.system(size: 12.5)) }.frame(height: 220)
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func recall() async {
        error = nil
        do {
            hits = try await engine.client?.call("memory.recall", MemoryRecallParams(provider: provider.id, bank: bank, query: query), as: MemoryRecallResult.self).hits ?? []
        } catch {
            self.error = (error as? EngineError)?.message ?? String(describing: error)
        }
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
