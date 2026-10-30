import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Settings › Extensions (docs/spec/07-shared-resources §6.1) and the memory providers of Settings › Chat (§6.2).
// No Piopio plugin format: pi packages (shared with the pi CLI) and memory systems behind MCP servers.

// Design handoff e1–e2 and the package page: the page lists installed packages with what each adds in plain words;
// installing happens in a sheet that previews the package before anything runs.

private let galleryURL = URL(string: "https://pi.dev/packages")!

/// How a package reads in a list: its name, where it comes from, and what it adds.
enum PackageText {
    static func name(_ p: PiPackage) -> String {
        if let name = p.name { return name }
        let s = p.source.replacingOccurrences(of: "npm:", with: "").replacingOccurrences(of: "git:", with: "")
        return URL(fileURLWithPath: s).lastPathComponent
    }

    /// "npm · 1.4.0", "git · github.com/antonio/writing", "folder · ~/prompts".
    static func origin(_ p: PiPackage) -> String {
        switch p.kind ?? "npm" {
        case "local": "folder · \((p.installedPath ?? p.source).replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
        case "git": "git · \(p.source.replacingOccurrences(of: "git:", with: "").replacingOccurrences(of: "https://", with: ""))"
        default: ["npm", p.version].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// "Extension · Build", "2 skills", "1 skill · everywhere", "4 templates · everywhere".
    static func badges(extensions: Int, skills: Int, prompts: Int) -> [String] {
        let everywhere = extensions == 0 ? " · everywhere" : ""
        var out: [String] = []
        if extensions > 0 { out.append(extensions == 1 ? "Extension · Build" : "\(extensions) extensions · Build") }
        if skills > 0 { out.append("\(skills) skill\(skills == 1 ? "" : "s")\(everywhere)") }
        if prompts > 0 { out.append("\(prompts) template\(prompts == 1 ? "" : "s")\(everywhere)") }
        return out
    }

    /// A resource's name from its path: an extension's file (or folder for index.ts), a skill's folder, a template's file.
    static func resource(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == "SKILL.md" || url.deletingPathExtension().lastPathComponent == "index" { return url.deletingLastPathComponent().lastPathComponent }
        return url.deletingPathExtension().lastPathComponent
    }

    static func tile(extensions: Int, skills: Int) -> (String, Color) {
        if extensions > 0 { return ("shippingbox.fill", .purple) }
        if skills > 0 { return ("text.badge.star", .orange) }
        return ("doc.on.doc.fill", .teal)
    }
}

struct PackageTile: View {
    let extensions: Int
    let skills: Int
    var size: CGFloat = 34
    var body: some View {
        let (symbol, color) = PackageText.tile(extensions: extensions, skills: skills)
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Color.dsFg2)
            .frame(width: size, height: size)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

// MARK: - e1 · Installed packages

struct ExtensionsPane: View {
    let engine: EngineController
    @State private var packages: [PiPackage] = []
    @State private var loaded = false
    @State private var detail: String?
    @State private var installing = false
    @State private var working: String?
    @State private var error: String?

    private var updates: Int { packages.filter { $0.latest != nil }.count }

    var body: some View {
        Group {
            if let id = detail, let p = packages.first(where: { $0.id == id }) {
                PackageDetail(engine: engine, package: p, back: { detail = nil }, changed: { Task { await load() } })
            } else if loaded, packages.isEmpty {
                SettingsEmpty(title: "Add skills and commands", message: "pi packages add skills and templates you can use in any chat, and extensions for Build. Piopio shares them with the pi CLI.") {
                    HStack(spacing: 10) {
                        Button { NSWorkspace.shared.open(galleryURL) } label: { Label("Browse pi.dev", systemImage: "arrow.up.right") }.buttonStyle(PillStyle(kind: .toolbar))
                        Button { installing = true } label: { Label("Install", systemImage: "plus").font(.system(size: 12.5, weight: .semibold)) }.buttonStyle(PillStyle(kind: .strong))
                    }
                }
            } else {
                page
            }
        }
        .task {
            await load()
            if ProcessInfo.processInfo.environment["PIOPIO_DEMO_INSTALL_PACKAGE"] != nil { installing = true }
            if let name = ProcessInfo.processInfo.environment["PIOPIO_DEMO_PACKAGE_DETAIL"] { detail = packages.first { PackageText.name($0).contains(name) }?.id }
        }
        .sheet(isPresented: $installing) {
            InstallPackageSheet(engine: engine) {
                installing = false
                Task { await load() }
            }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "Extensions", summary: ["\(packages.count) package\(packages.count == 1 ? "" : "s")", updates > 0 ? "\(updates) update\(updates == 1 ? "" : "s")" : nil, "shared with the pi CLI"].compactMap { $0 }.joined(separator: " · ")) {
                Button { NSWorkspace.shared.open(galleryURL) } label: { Label("Browse pi.dev", systemImage: "arrow.up.right").font(.system(size: 12.5)) }
                    .buttonStyle(PillStyle(kind: .toolbar))
                AddButton(title: "Install") { installing = true }
            }
            CardTitle(title: "Installed") {
                Button(working == "update" ? "Updating…" : "Update all") { updateAll() }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor).disabled(working != nil)
            }
            ListCard {
                ForEach(Array(packages.enumerated()), id: \.element.id) { i, p in
                    PackageRow(package: p, updating: working == p.source, update: { update(p) }) { detail = p.id }
                    if i < packages.count - 1 { RowDivider() }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2).padding(.top, 8) }
            VStack(alignment: .leading, spacing: 3) {
                (Text("Extension ").fontWeight(.semibold) + Text("runs code in Build, with your permissions"))
                (Text("Skills, templates ").fontWeight(.semibold) + Text("are text, usable everywhere"))
            }
            .font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 12)
        }
    }

    private func update(_ p: PiPackage) {
        working = p.source
        Task {
            do { try await engine.spaceCall("packages.update", PackageParams(source: p.source)) } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
            working = nil
            await load()
        }
    }

    private func updateAll() {
        working = "update"
        error = nil
        Task {
            do { try await engine.spaceCall("packages.update", PackageParams(source: nil)) } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
            working = nil
            await load()
        }
    }

    private func load() async {
        packages = (try? await engine.client?.call("packages.list", Empty(), as: PackagesResult.self).packages) ?? []
        loaded = engine.client != nil
    }
}

private struct PackageRow: View {
    let package: PiPackage
    let updating: Bool
    let update: () -> Void
    let open: () -> Void

    var body: some View {
        let r = package.resources
        Button(action: open) {
            HStack(spacing: 12) {
                PackageTile(extensions: r.extensions.count, skills: r.skills.count)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(PackageText.name(package)).font(.system(size: 14, weight: .semibold)).foregroundStyle(package.enabled ? Color.dsFg : Color.dsFg3)
                        if !package.installed { Text("Not installed").font(.system(size: 11.5)).foregroundStyle(Color.dsFg2) } else if !package.enabled { Text("Off").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3) }
                    }
                    HStack(spacing: 6) {
                        ForEach(PackageText.badges(extensions: r.extensions.count, skills: r.skills.count, prompts: r.prompts.count), id: \.self) { b in
                            Text(b).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dsFg2).padding(.horizontal, 6).frame(height: 18).background(Color.dsChip, in: RoundedRectangle(cornerRadius: 5))
                        }
                        Text(PackageText.origin(package)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 12)
                if let latest = package.latest {
                    Button(action: update) {
                        Text(updating ? "Updating…" : "Update to \(latest)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 9).frame(height: 22).background(Color.dsAccentSoft, in: Capsule())
                    }
                    .buttonStyle(.plain).disabled(updating)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 14).frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

// MARK: - e2 · Install sheet

struct InstallPackageSheet: View {
    let engine: EngineController
    let done: () -> Void
    @State private var source = ProcessInfo.processInfo.environment["PIOPIO_DEMO_INSTALL_PACKAGE"] ?? ""
    @State private var preview: PackagePreview?
    @State private var checking = false
    @State private var installing = false
    @State private var error: String?
    @FocusState private var focused: Bool

    /// What pi installs: "npm:" for package names, "git:" for a host/owner/repo, folders as they are.
    private var normalized: String {
        let s = source.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.hasPrefix("npm:") || s.hasPrefix("git:") || s.hasPrefix("http") || s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix(".") { return s }
        if s.hasPrefix("github.com/") || s.hasPrefix("gitlab.com/") { return "git:\(s)" }
        return "npm:\(s)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Install a package").font(.system(size: 17, weight: .bold))
            Text("From npm, a git repository, or a folder on this Mac").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).padding(.top, 2)
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField("npm:@scope/name, git:github.com/user/repo or a folder", text: $source)
                        .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced)).focused($focused)
                    if checking { ProgressView().controlSize(.mini) }
                    else if let preview { preview.ok ? AnyView(Label("Found", systemImage: "checkmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg3)) : AnyView(EmptyView()) }
                }
                .padding(.horizontal, 10).frame(height: 32)
                .settingsRows()
                .background(focused ? RoundedRectangle(cornerRadius: 11).fill(Color.dsAccentSoft).padding(-3) : nil)
                Button("Choose Folder…") { chooseFolder() }.buttonStyle(PillStyle())
            }
            .padding(.top, 14)
            if let preview, !preview.ok, let message = preview.error {
                Text(message).font(.system(size: 12)).foregroundStyle(Color.dsFg2).padding(.top, 6)
            }
            if let preview, preview.ok { previewCard(preview).padding(.top, 14) }
            if let preview, preview.ok, !preview.extensions.isEmpty || !preview.contentsKnown {
                Text("The extension runs with your user's permissions. Only install packages you trust.")
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg2).padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 12)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2).padding(.top, 8) }
            HStack {
                Text("Installs with pi, shared with the pi CLI").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                Spacer()
                Button("Cancel", action: done).buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(installing ? "Installing…" : "Install") { install() }
                    .buttonStyle(PillStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(preview?.ok != true || installing)
            }
            .padding(.top, 18)
        }
        .padding(22)
        .frame(width: 600)
        .background(Color.dsWin)
        .onAppear { focused = true }
        .task(id: normalized) {
            preview = nil
            guard !normalized.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let client = engine.client else { return }
            checking = true
            preview = try? await client.call("packages.preview", PackageParams(source: normalized), as: PackagePreview.self)
            checking = false
        }
    }

    private func previewCard(_ p: PackagePreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PackageTile(extensions: p.extensions.count, skills: p.skills.count, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name ?? normalized).font(.system(size: 14, weight: .semibold))
                        Text([p.version, p.author.map { "by \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    }
                    if let d = p.description { Text(d).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(2) }
                }
                Spacer()
            }
            .padding(14)
            RowDivider(inset: 0)
            VStack(alignment: .leading, spacing: 8) {
                Text("What it adds").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
                if !p.contentsKnown {
                    part(.dsFg3, "Contents", "shown after installing", "Can't read it before")
                }
                if !p.extensions.isEmpty { part(.dsAmber, p.extensions.count == 1 ? "Extension" : "\(p.extensions.count) extensions", p.extensions.joined(separator: ", "), "Build only · runs code") }
                if !p.skills.isEmpty { part(.dsFg3, "\(p.skills.count) skill\(p.skills.count == 1 ? "" : "s")", p.skills.joined(separator: ", "), "Everywhere") }
                if !p.prompts.isEmpty { part(.dsFg3, "\(p.prompts.count) template\(p.prompts.count == 1 ? "" : "s")", p.prompts.map { "/\($0)" }.joined(separator: ", "), "Everywhere") }
                if !p.themes.isEmpty { part(.dsFg3.opacity(0.5), "Themes", p.themes.joined(separator: ", "), "Not shown in Piopio", muted: true) }
                if !p.extensions.isEmpty { part(.dsFg3.opacity(0.5), "Terminal panels", nil, "Not shown in Piopio", muted: true) }
                if p.contentsKnown, p.extensions.isEmpty, p.skills.isEmpty, p.prompts.isEmpty, p.themes.isEmpty {
                    Text("Nothing pi can load was found in it.").font(.system(size: 12.5)).foregroundStyle(Color.dsAmber)
                }
            }
            .padding(14)
        }
        .settingsRows()
    }

    private func part(_ dot: Color, _ title: String, _ names: String?, _ where_: String, muted: Bool = false) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 6, height: 6)
            (Text(title).fontWeight(.semibold) + Text(names.map { ": \($0)" } ?? ""))
                .font(.system(size: 12.5)).foregroundStyle(muted ? Color.dsFg3 : Color.dsFg).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 10)
            Text(where_).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize()
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
        installing = true
        error = nil
        Task {
            do {
                try await engine.spaceCall("packages.install", PackageParams(source: normalized))
                done()
            } catch {
                self.error = (error as? EngineError)?.message ?? String(describing: error)
            }
            installing = false
        }
    }
}

// MARK: - Package page

private struct PackageDetail: View {
    let engine: EngineController
    let package: PiPackage
    let back: () -> Void
    let changed: () -> Void
    @State private var working = false
    @State private var removing = false
    @State private var error: String?

    var body: some View {
        let r = package.resources
        SettingsDetail(back: "Extensions", title: PackageText.name(package), goBack: back, footer: impact, remove: "Uninstall…", onRemove: { removing = true }) {
            PackageTile(extensions: r.extensions.count, skills: r.skills.count, size: 48)
        } status: {
            if !package.installed {
                StatusText(color: .dsFg2, text: "Not installed · run Update to install it")
            } else if let latest = package.latest {
                StatusText(color: .dsAmber, text: "\(package.version ?? "") installed · \(latest) available")
            } else {
                StatusText(color: package.enabled ? .dsFg3 : .dsFg3, text: [package.enabled ? "On" : "Off", package.kind == "local" ? "folder" : package.kind ?? "npm", package.version].compactMap { $0 }.joined(separator: " · "))
            }
        } actions: {
            if package.latest != nil || package.kind == "git" || !package.installed {
                Button(working ? "Updating…" : package.latest.map { "Update to \($0)" } ?? "Update") { update() }
                    .buttonStyle(PillStyle(kind: package.latest != nil ? .primary : .secondary, compact: true)).disabled(working)
            }
        } content: {
            if let description = package.description { Text(description).font(.system(size: 13)).foregroundStyle(Color.dsFg2) }
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("Package")
                ListCard {
                    ToggleRow(title: "Turned on", subtitle: "Off: nothing of it loads, here or in the pi CLI", isOn: Binding(get: { package.enabled }, set: { on in
                        act { try await engine.spaceCall("packages.setEnabled", PackageEnableParams(source: package.source, enabled: on)) }
                    }))
                    info("Source", package.source, mono: true)
                    if let path = package.installedPath {
                        HStack(spacing: 10) {
                            Text("Installed in").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).frame(width: 110, alignment: .leading)
                            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 40)
                    }
                }
            }
            section("Extensions", "extensions", r.extensions, where_: "Build only · runs code")
            section("Skills", "skills", r.skills, where_: "Everywhere")
            section("Templates", "prompts", r.prompts, where_: "Everywhere", slash: true)
            section("Themes", "themes", r.themes, where_: "Not shown in Piopio")
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
        }
        .alert("Uninstall \(PackageText.name(package))?", isPresented: $removing) {
            Button("Uninstall", role: .destructive) {
                act { try await engine.spaceCall("packages.remove", PackageParams(source: package.source)) }
                back()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(impact) The pi CLI stops loading it too.")
        }
    }

    private var impact: String {
        let r = package.resources
        var parts: [String] = []
        if !r.skills.isEmpty || !r.prompts.isEmpty { parts.append("its skills and templates leave every chat") }
        if !r.extensions.isEmpty { parts.append("its extension leaves Build") }
        return parts.isEmpty ? "Uninstalling removes it from Piopio and the pi CLI." : "Uninstalling: \(parts.joined(separator: "; "))."
    }

    @ViewBuilder private func section(_ title: String, _ kind: String, _ items: [PiPackage.Resource], where_: String, slash: Bool = false) -> some View {
        if !items.isEmpty || package.off.contains(kind) {
            let kindOn = !package.off.contains(kind)
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: title, detail: where_) {
                    Toggle("", isOn: Binding(get: { kindOn }, set: { on in
                        act { try await engine.spaceCall("packages.setEnabled", PackageEnableParams(source: package.source, enabled: on, kinds: [kind])) }
                    }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().help("All of its \(title.lowercased())")
                }
                ListCard {
                    if items.isEmpty { Text("Turned off").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading) }
                    ForEach(Array(items.enumerated()), id: \.element.path) { i, item in
                        HStack(spacing: 10) {
                            Text((slash ? "/" : "") + PackageText.resource(item.path)).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(item.enabled && kindOn ? Color.dsFg : Color.dsFg3)
                            Spacer()
                            Toggle("", isOn: Binding(get: { item.enabled }, set: { on in
                                act { try await engine.spaceCall("packages.setResource", PackageResourceParams(source: package.source, kind: kind, path: item.path, enabled: on)) }
                            }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(!kindOn)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 38)
                        if i < items.count - 1 { RowDivider(inset: 14) }
                    }
                }
            }
        }
    }

    private func info(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).frame(width: 110, alignment: .leading)
                Text(value).font(.system(size: 12, design: mono ? .monospaced : .default)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            RowDivider(inset: 14)
        }
    }

    private func update() {
        working = true
        act { try await engine.spaceCall("packages.update", PackageParams(source: package.source)) }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        error = nil
        Task {
            do { try await work() } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
            working = false
            changed()
        }
    }
}

// MARK: Memory providers

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
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
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
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
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
