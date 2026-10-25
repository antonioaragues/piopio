import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

// Settings › Memory (docs/spec/14-memory §5.3, milestone M3): what Piopio remembers and whose it is, About me, memory
// search, learning, and your data (export, rebuild, erase). Browse… opens every bank of the built-in provider in one
// window, with search, the history and what replaced what.

struct MemoryPane: View {
    let engine: EngineController
    @State private var banks: MemoryBanksResult?
    @State private var page: Page = .main
    @State private var browsing: BrowseTarget?
    @State private var tick = 0
    @State private var note: String?
    @State private var erasing: EraseTarget?

    enum Page { case main, aboutMe }
    struct BrowseTarget: Identifiable { let bank: String?; var id: String { bank ?? "" } }
    struct EraseTarget: Identifiable { let bank: String; let label: String; let records: Int; var id: String { bank } }

    private var settings: EngineSettings? { engine.settings }

    var body: some View {
        Group {
            switch page {
            case .main: main
            case .aboutMe: aboutMe
            }
        }
        .task(id: tick) {
            await engine.loadSettings()
            banks = try? await engine.client?.call("memory.banks", Empty(), as: MemoryBanksResult.self)
        }
        .task {
            // Captures: PIOPIO_DEMO_MEMORY=browse opens Browse; about-me opens About me.
            switch ProcessInfo.processInfo.environment["PIOPIO_DEMO_MEMORY"] {
            case "browse":
                try? await Task.sleep(for: .seconds(1.2))
                browsing = BrowseTarget(bank: banks?.banks.first { $0.area == "agent" }?.bank)
            case "about-me": page = .aboutMe
            default: break
            }
        }
        .sheet(item: $browsing) { target in
            MemoryBrowser(engine: engine, start: target.bank) {
                browsing = nil
                tick += 1
            }
        }
        .alert(item: $erasing) { target in
            Alert(
                title: Text(target.bank == "*" ? "Erase all memory?" : "Erase “\(target.label)”?"),
                message: Text("\(target.records.formatted()) memor\(target.records == 1 ? "y" : "ies") and their history are deleted. Export first if you want a copy. This can't be undone."),
                primaryButton: .destructive(Text("Erase")) { erase(target) },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: Main page

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "Memory", summary: summary) {
                Button { browsing = BrowseTarget(bank: nil) } label: { Label("Browse…", systemImage: "rectangle.stack").font(.system(size: 12.5, weight: .semibold)) }
                    .buttonStyle(PillStyle(kind: .strong))
                    .disabled((banks?.banks ?? []).isEmpty)
            }
            VStack(alignment: .leading, spacing: 0) { remembers }.padding(.bottom, 22)
            MemorySearchCard(engine: engine, tick: tick).padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 0) { learning }.padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 0) { data }
            if let note { FinePrint(note).padding(.top, 8) }
        }
    }

    private var summary: String {
        guard let b = banks else { return "What Piopio remembers, and how" }
        let records = b.banks.reduce(0) { $0 + $1.records }
        guard records > 0 else { return "Nothing remembered yet" }
        let facts = b.banks.reduce(0) { $0 + $1.facts }
        let size = ByteCountFormatter.string(fromByteCount: Int64(b.bytes), countStyle: .file)
        return "\(records.formatted()) memories · \(facts.formatted()) facts · \(size) on this Mac"
    }

    private func bank(_ name: String) -> MemoryBanksResult.Bank? { banks?.banks.first { $0.bank == name } }

    @ViewBuilder private var remembers: some View {
        let agents = banks?.agents ?? []
        let others = (banks?.banks ?? []).filter { $0.area == "other" }
        CardTitle("What Piopio remembers")
        ListCard {
            SettingsListRow(name: "About me", open: { page = .aboutMe }) {
                MemoryTile(symbol: "person.text.rectangle.fill", color: .teal)
            } subtitle: {
                Text("\(count(bank("about-me")?.facts ?? 0, "fact")) · \(shareLine)")
            } trailing: { EmptyView() }
            ForEach(agents) { agent in
                RowDivider()
                let mine = (banks?.banks ?? []).filter { $0.agent?.id == agent.id }
                SettingsListRow(name: agent.name, open: { browsing = BrowseTarget(bank: mine.first?.bank ?? "\(agent.id)/owner") }) {
                    EmojiTile(text: agent.avatar ?? String(agent.name.prefix(1)))
                } subtitle: {
                    Text(agentLine(agent, mine))
                } trailing: {
                    if agent.provider != nil, agent.provider != "builtin" { SettingsBadge("MCP memory") }
                }
            }
            if !others.isEmpty {
                RowDivider()
                SettingsListRow(name: "From deleted agents", open: { browsing = BrowseTarget(bank: others.first?.bank) }) {
                    MemoryTile(symbol: "archivebox.fill", color: .gray)
                } subtitle: {
                    Text("\(count(others.reduce(0) { $0 + $1.records }, "memory", plural: "memories")) left behind")
                } trailing: { EmptyView() }
            }
            RowDivider()
            HStack(spacing: 12) {
                MemoryTile(symbol: "book.closed.fill", color: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notebooks").font(.system(size: 14, weight: .semibold))
                    Text(banks.map { $0.notebooks == 0 ? "No notebooks yet. Each keeps its own memory document." : "\(count($0.notebooks, "notebook")), each with its own memory document. Edit it from the notebook." } ?? "Each keeps its own memory document")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 14).frame(minHeight: 62)
        }
    }

    private var shareLine: String {
        guard let a = settings?.aboutMe, a.enabled else { return "not shared" }
        return a.inAgents == true ? "shared with chats, notebooks and agents" : "shared with chats and notebooks"
    }

    private func agentLine(_ agent: MemoryBanksResult.Agent, _ mine: [MemoryBanksResult.Bank]) -> String {
        let facts = mine.reduce(0) { $0 + $1.facts }, messages = mine.reduce(0) { $0 + $1.messages }
        let what = facts + messages == 0 ? "Nothing yet" : "\(count(facts, "fact")) · \(count(messages, "message"))"
        return "\(what) · \(agent.learns ? "learns by itself" : "keeps what was said")"
    }

    private func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? noun : plural ?? "\(noun)s")"
    }

    // MARK: Learning

    @ViewBuilder private var learning: some View {
        let agents = banks?.agents ?? []
        CardTitle("Learning")
        ListCard {
            ToggleRow(title: "Chats add to About me", subtitle: "When you mention something lasting about yourself", last: agents.isEmpty, isOn: Binding(get: { settings?.aboutMe.capture ?? false }, set: { v in
                Task { await engine.updateSettings(SettingsPatch(aboutMe: .init(capture: v))) }
            }))
            ForEach(Array(agents.enumerated()), id: \.element.id) { i, agent in
                ToggleRow(title: "\(agent.name) learns facts by itself", subtitle: agent.provider == nil || agent.provider == "builtin" ? "After a quiet moment, from what was said; newer facts replace older ones" : "Its MCP memory decides what it keeps", last: i == agents.count - 1, isOn: Binding(get: { agent.learns }, set: { v in setLearning(agent, v) }))
                    .disabled(agent.provider != nil && agent.provider != "builtin")
            }
        }
        FinePrint("Everything learned shows in the conversation with Undo, and in Browse with what it replaced.").padding(.top, 8)
    }

    private func setLearning(_ agent: MemoryBanksResult.Agent, _ learn: Bool) {
        Task {
            _ = try? await engine.client?.call("memory.setLearning", MemoryLearningParams(ref: ContainerRef(kind: .agent, id: agent.id), learn: learn), as: Empty.self)
            tick += 1
        }
    }

    // MARK: Your data

    @ViewBuilder private var data: some View {
        let all = banks?.banks ?? []
        CardTitle("Your data")
        ListCard {
            dataRow("Export everything", "memory.json and memory.md: every fact and message, and what replaced what") {
                Button("Export…", action: export).buttonStyle(PillStyle(compact: true)).disabled(all.isEmpty)
            }
            RowDivider(inset: 14)
            dataRow("Rebuild search index", "Embeds again whatever has no vector from the current model") {
                Button("Rebuild", action: reindex).buttonStyle(PillStyle(compact: true)).disabled(all.isEmpty)
            }
            RowDivider(inset: 14)
            dataRow("Erase memory", "One part, or everything. About me's history goes with it.", last: true) {
                Menu {
                    ForEach(all) { b in
                        Button("\(b.agent.map { "\($0.name) · " } ?? "")\(b.label) (\(b.records.formatted()))") { erasing = EraseTarget(bank: b.bank, label: b.agent.map { "\($0.name) · \(b.label)" } ?? b.label, records: b.records) }
                    }
                    Divider()
                    Button("Everything…") { erasing = EraseTarget(bank: "*", label: "everything", records: all.reduce(0) { $0 + $1.records }) }
                } label: {
                    Text("Erase…").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsRed)
                }
                .menuStyle(.button).buttonStyle(ChipStyle()).fixedSize()
                .disabled(all.isEmpty)
            }
        }
    }

    private func dataRow<Action: View>(_ title: String, _ subtitle: String, last: Bool = false, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            Spacer()
            action()
        }
        .padding(.horizontal, 14).frame(minHeight: 50)
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Piopio writes memory.json and memory.md into this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                guard let result = try await engine.client?.call("memory.export", MemoryExportParams(folder: url.path), as: MemoryExportResult.self) else { return }
                note = "Exported \(result.records.formatted()) memories to \(url.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting(result.files.map { URL(fileURLWithPath: $0) })
            } catch {
                note = "Couldn't export: \((error as? EngineError)?.message ?? error.localizedDescription)"
            }
        }
    }

    private func reindex() {
        Task {
            let result = try? await engine.client?.call("memory.reindex", Empty(), as: MemoryCountResult.self)
            let pending = result?.pending ?? 0
            note = pending == 0 ? "Everything is indexed." : "\(pending.formatted()) memories to embed. This runs in the background."
            tick += 1
        }
    }

    private func erase(_ target: EraseTarget) {
        Task {
            let result = try? await engine.client?.call("memory.wipe", MemoryWipeParams(bank: target.bank), as: MemoryCountResult.self)
            note = "Erased \((result?.records ?? 0).formatted()) memories."
            tick += 1
        }
    }

    // MARK: About me

    private var aboutMe: some View {
        SettingsDetail(back: "Memory", title: "About me", goBack: { page = .main; tick += 1 }) {
            MemoryTile(symbol: "person.text.rectangle.fill", color: .teal, size: 48)
        } status: {
            Text("What every chat knows about you · \(shareLine)")
        } actions: {
            EmptyView()
        } content: {
            AboutMeEditor(engine: engine)
        }
    }
}

// MARK: - Tiles

/// A memory area's tile: a symbol on its color.
struct MemoryTile: View {
    let symbol: String
    var color: Color
    var size: CGFloat = 34
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
    }
}

/// An agent's emoji on a soft tile.
struct EmojiTile: View {
    let text: String
    var size: CGFloat = 34
    var body: some View {
        Text(text).font(.system(size: size * 0.55))
            .frame(width: size, height: size)
            .background(Color.dsYolkSoft, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

// MARK: - Browse

/// Every bank in one window: banks on the left (About me, each agent's partitions), the records on the right with
/// search, Facts / Messages / All, the replaced facts and their history; edit, pin, forget and add in place.
struct MemoryBrowser: View {
    let engine: EngineController
    let start: String?
    let done: () -> Void
    @State private var banks: MemoryBanksResult?
    @State private var bank: String?
    @State private var records: [MemoryRecordInfo] = []
    @State private var query = ""
    @State private var filter: Filter = .facts
    @State private var showReplaced = false
    @State private var events: [MemoryHistoryResult.Event]?
    @State private var hovered: String?
    @State private var editing: String?
    @State private var draft = ""
    @State private var adding = ""
    @State private var loading = false

    enum Filter: String, CaseIterable { case facts = "Facts", messages = "Messages", all = "All" }

    private var current: MemoryBanksResult.Bank? { banks?.banks.first { $0.bank == bank } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Rectangle().fill(Color.dsLine).frame(width: 0.5)
            VStack(spacing: 0) {
                header
                toolbar
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                list
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                footer
            }
        }
        .frame(width: 780, height: 520)
        .background(Color.dsWin)
        .task {
            banks = try? await engine.client?.call("memory.banks", Empty(), as: MemoryBanksResult.self)
            bank = start ?? banks?.banks.first?.bank
            if ProcessInfo.processInfo.environment["PIOPIO_DEMO_MEMORY_REPLACED"] == "1" { showReplaced = true }
        }
        .task(id: "\(bank ?? "")|\(filter)|\(showReplaced)|\(query)") {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            await load()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let all = banks?.banks ?? []
        let agents = banks?.agents ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if let me = all.first(where: { $0.area == "about-me" }) {
                    bankRow(me, title: "About me", icon: AnyView(MemoryTile(symbol: "person.text.rectangle.fill", color: .teal, size: 18)))
                }
                ForEach(agents) { agent in
                    let mine = all.filter { $0.agent?.id == agent.id }
                    if !mine.isEmpty {
                        HStack(spacing: 6) {
                            Text(agent.avatar ?? "").font(.system(size: 11))
                            SectionLabel(agent.name)
                        }
                        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
                        ForEach(mine) { b in bankRow(b, title: b.label, icon: nil) }
                    }
                }
                let others = all.filter { $0.area == "other" }
                if !others.isEmpty {
                    SectionLabel("From deleted agents").padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
                    ForEach(others) { b in bankRow(b, title: b.bank, icon: nil) }
                }
            }
            .padding(8)
        }
        .background(Color.dsChip.opacity(0.5))
    }

    private func bankRow(_ b: MemoryBanksResult.Bank, title: String, icon: AnyView?) -> some View {
        let selected = bank == b.bank
        return Button { bank = b.bank; query = ""; editing = nil } label: {
            HStack(spacing: 8) {
                if let icon { icon }
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(b.facts)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).help("\(b.facts) facts, \(b.messages) messages")
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(selected ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Header and toolbar

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 18, weight: .bold)).lineLimit(1)
                if let c = current {
                    Text("\(c.facts.formatted()) facts · \(c.messages.formatted()) messages\(c.ended > 0 ? " · \(c.ended.formatted()) replaced" : "")\(c.updatedAt.map { " · updated \(BuildSessionView.relative($0))" } ?? "")")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
            }
            Spacer()
            Button("History") { Task { await loadHistory() } }
                .buttonStyle(PillStyle(compact: true))
                .popover(isPresented: Binding(get: { events != nil }, set: { if !$0 { events = nil } }), arrowEdge: .bottom) { history }
            Button("Done", action: done).buttonStyle(PillStyle(kind: .primary, compact: true)).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
    }

    private var title: String {
        guard let c = current else { return "Memory" }
        if c.area == "about-me" { return "About me" }
        return c.agent.map { "\($0.name) · \(c.label)" } ?? c.bank
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                TextField("Search by meaning or words", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.dsFg3) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 8))
            Picker("", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            Toggle("Replaced", isOn: $showReplaced).toggleStyle(.checkbox).font(.system(size: 12))
                .disabled(!query.isEmpty)
                .help("Facts that a newer fact replaced, or that stopped being true")
        }
        .padding(.horizontal, 18).padding(.bottom, 12)
    }

    // MARK: Records

    @ViewBuilder private var list: some View {
        if records.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: query.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 22)).foregroundStyle(Color.dsFg3)
                Text(query.isEmpty ? (filter == .facts ? "No facts here yet" : "Nothing here yet") : "Nothing matches “\(query)”").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                if query.isEmpty, filter == .facts { Text("Facts appear as they're learned or added.").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { r in
                        row(r)
                        Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 46)
                    }
                }
            }
        }
    }

    private func row(_ r: MemoryRecordInfo) -> some View {
        let ended = r.endedAt != nil
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: ended ? "clock.arrow.circlepath" : r.kind == "fact" ? "lightbulb" : "text.bubble")
                .font(.system(size: 12)).foregroundStyle(ended ? Color.dsFg3 : r.createdBy == "extraction" ? Color.accentColor : Color.dsFg3)
                .frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                if editing == r.id {
                    HStack {
                        TextField("", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).font(.system(size: 13)).onSubmit { save(r) }
                        Button("Save") { save(r) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                        Button("Cancel") { editing = nil }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    }
                } else {
                    Text(r.text).font(.system(size: 13)).foregroundStyle(ended ? Color.dsFg3 : Color.dsFg)
                        .strikethrough(ended, color: Color.dsFg3.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Text(meta(r)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(2)
            }
            Spacer(minLength: 8)
            if hovered == r.id, editing != r.id, !ended {
                HStack(spacing: 10) {
                    if r.kind == "fact" {
                        Button { pin(r) } label: { Image(systemName: r.pinned == true ? "pin.fill" : "pin") }.help(r.pinned == true ? "Unpin" : "Pin: always in the notes")
                        Button { draft = r.text; editing = r.id } label: { Image(systemName: "pencil") }.help("Correct it (the old text stays in the history)")
                    }
                    Button { forget(r) } label: { Image(systemName: "trash") }.help("Forget")
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
            } else if r.pinned == true {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
        .contextMenu {
            if !ended {
                if r.kind == "fact" { Button("Correct…") { draft = r.text; editing = r.id } }
                Button("Forget", role: .destructive) { forget(r) }
            }
        }
    }

    /// "Learned · 16 Jun", "You · 2 d ago", "Antonio said · 3 Apr"; replaced facts add when and by what.
    private func meta(_ r: MemoryRecordInfo) -> String {
        let who: String = switch (r.kind, r.createdBy) {
        case ("fact", "extraction"): "Learned"
        case ("fact", "user"): "You"
        case ("fact", _): "Saved by the agent"
        case (_, _): r.source?.title.map { "\($0) said" } ?? "Message"
        }
        var parts = [who, Self.day(r.at)]
        if let end = r.endedAt {
            if let by = r.replacedBy, let newer = records.first(where: { $0.id == by }) { parts.append("replaced \(Self.day(end)) by “\(newer.text)”") }
            else { parts.append(r.replacedBy == nil ? "no longer true since \(Self.day(end))" : "replaced \(Self.day(end))") }
        } else if let old = r.replaces, let older = records.first(where: { $0.id == old }) {
            parts.append("replaces “\(older.text)”")
        }
        return parts.joined(separator: " · ")
    }

    static func day(_ iso: String) -> String {
        let d = MainSidebar.date(iso)
        return Calendar.current.isDate(d, equalTo: .now, toGranularity: .year) ? d.formatted(.dateTime.day().month(.abbreviated)) : d.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
            TextField(current?.area == "about-me" ? "Add something about you…" : "Add a fact to \(title)…", text: $adding).textFieldStyle(.plain).font(.system(size: 13)).onSubmit(add)
            Spacer()
            Text("\(records.count) shown").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
        }
        .padding(.horizontal, 18).frame(height: 44)
        .disabled(bank == nil)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History").font(.system(size: 13, weight: .semibold)).padding(12)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(events ?? []) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.text).font(.system(size: 12.5)).lineLimit(3)
                            Text("\(Self.action(e.action)) · \(e.by == "extraction" ? "learned" : e.by == "user" ? "you" : "the agent") · \(Self.day(e.at))")
                                .font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                        }
                    }
                    if events?.isEmpty == true { Text("No changes yet.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3) }
                }
                .padding(12)
            }
        }
        .frame(width: 340, height: 360)
    }

    static func action(_ a: String) -> String {
        switch a {
        case "added": "Added"
        case "removed": "Forgotten"
        case "updated": "Corrected"
        case "replaced": "Replaced"
        case "ended": "No longer true"
        case "restored": "Restored"
        default: a.capitalized
        }
    }

    // MARK: Changes

    private func load() async {
        guard let bank else { return }
        loading = true
        defer { loading = false }
        let kinds: [String]? = switch filter {
        case .facts: ["fact"]
        case .messages: ["message"]
        case .all: nil
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        let params = MemoryListParams(provider: "builtin", bank: bank, kinds: kinds, includeEnded: q.isEmpty && showReplaced ? true : nil, query: q.isEmpty ? nil : q)
        records = (try? await engine.client?.call("memory.list", params, as: MemoryListResult.self))?.records ?? []
    }

    private func loadHistory() async {
        guard let bank else { return }
        events = (try? await engine.client?.call("memory.history", MemoryHistoryParams(bank: bank), as: MemoryHistoryResult.self))?.events ?? []
    }

    private func refreshBanks() async {
        banks = try? await engine.client?.call("memory.banks", Empty(), as: MemoryBanksResult.self)
    }

    private func save(_ r: MemoryRecordInfo) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        guard let bank, !text.isEmpty, text != r.text else { return }
        Task {
            if current?.area == "about-me" {
                // About me keeps its sections: corrected in place (its history shows the change).
                _ = try? await engine.client?.call("memory.update", MemoryIdParams(provider: "builtin", bank: bank, id: r.id, text: text), as: Empty.self)
            } else {
                // A correction replaces the fact, so the history keeps what it said before.
                _ = try? await engine.client?.call("memory.add", MemoryAddParams(provider: "builtin", bank: bank, text: text, replaces: r.id), as: Empty.self)
            }
            await load()
            await refreshBanks()
        }
    }

    private func pin(_ r: MemoryRecordInfo) {
        guard let bank else { return }
        Task {
            _ = try? await engine.client?.call("memory.update", MemoryIdParams(provider: "builtin", bank: bank, id: r.id, pinned: !(r.pinned ?? false)), as: Empty.self)
            await load()
        }
    }

    private func forget(_ r: MemoryRecordInfo) {
        guard let bank else { return }
        Task {
            _ = try? await engine.client?.call("memory.forget", MemoryIdParams(provider: "builtin", bank: bank, id: r.id), as: Empty.self)
            await load()
            await refreshBanks()
        }
    }

    private func add() {
        let text = adding.trimmingCharacters(in: .whitespaces)
        guard let bank, !text.isEmpty else { return }
        adding = ""
        Task {
            _ = try? await engine.client?.call("memory.add", MemoryAddParams(provider: "builtin", bank: bank, text: text), as: Empty.self)
            filter = .facts
            await load()
            await refreshBanks()
        }
    }
}
