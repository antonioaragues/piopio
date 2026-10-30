import PiopioKit
import PiopioTranscript
import SwiftUI

/// ⌘K (docs/design/grey 10b): search and commands in one box. Results first (places, then messages), actions after.
/// The right column says where each result lives, so rows need no icons or colors. ⇥ switches All / Messages.
struct CommandPalette: View {
    enum Mode { case all, messages, models }

    let engine: EngineController
    let thread: ThreadModel?
    let close: () -> Void
    let newThread: () -> Void
    let openThread: (String, String?) -> Void // thread id, item to reveal

    let openResult: (SearchResult) -> Void
    @State private var searchScope: SearchScope = .all
    enum SearchScope: String, CaseIterable {
        case all = "Everything", build = "Build", chat = "Chats", notebooks = "Notebooks", agents = "Agents"
        var kind: ContainerKind? { switch self { case .all: nil; case .build: .build; case .chat: .thread; case .notebooks: .space; case .agents: .agent } }
    }
    @State var mode: Mode
    @State var query = ""
    @State private var selection = 0
    @State private var searching = false
    @State private var searchError: String?
    @State private var hits: [SearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    struct Row: Identifiable {
        let id: String
        let icon: String
        let title: String
        var detail: AttributedString?
        var trailing: String?
        let run: () -> Void
    }

    struct Group: Identifiable {
        let id: String
        let rows: [Row]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: mode == .models ? "cpu" : "magnifyingglass").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return) { runSelected(); return .handled }
                    .onKeyPress(.tab) {
                        guard mode != .models else { return .ignored }
                        mode = mode == .all ? .messages : .all
                        scheduleSearch(query)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if mode == .models { mode = .all; query = ""; return .handled }
                        close(); return .handled
                    }
                if mode != .models {
                    Menu {
                        ForEach(SearchScope.allCases, id: \.self) { s in Button(s.rawValue) { searchScope = s } }
                    } label: { Text(mode == .messages ? "Messages in \(searchScope.rawValue.lowercased())" : searchScope.rawValue) }
                        .menuStyle(.button).buttonStyle(ChipStyle()).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Search scope")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        let groups = self.groups
                        let flat = groups.flatMap(\.rows)
                        ForEach(groups) { group in
                            Text(group.id).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                            ForEach(group.rows) { row in
                                let index = flat.firstIndex { $0.id == row.id } ?? 0
                                rowView(row, selected: index == selection)
                                    .id(index)
                                    .onTapGesture { row.run() }
                            }
                        }
                        if flat.isEmpty {
                            Text(searching ? "Searching conversations…" : query.count < 2 ? "Type at least two characters to search messages" : "No matches")
                                .font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(14)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: selection) { _, s in proxy.scrollTo(s) }
            }
            .frame(height: min(400, listHeight))
            if let searchError { Text(searchError).font(.system(size: 12)).foregroundStyle(Color.dsFg2).padding(10) }
        }
        .frame(width: 560)
        .glassPanel(radius: 12)
        .shadow(color: .black.opacity(0.08), radius: 24, y: 10)
        .onAppear {
            focused = true
            scheduleSearch(query) // a query passed in (automation)
        }
        .onChange(of: query) { _, q in
            selection = 0
            scheduleSearch(q)
        }
        .onChange(of: mode) { _, _ in selection = 0 }
        .onChange(of: searchScope) { _, _ in selection = 0; scheduleSearch(query) }
    }

    private var placeholder: String {
        switch mode {
        case .all: "Search projects, conversations and messages"
        case .messages: "Search messages"
        case .models: "Pick a model"
        }
    }

    private var listHeight: CGFloat {
        let g = groups
        return CGFloat(g.flatMap(\.rows).count) * 33 + CGFloat(g.count) * 30 + 16
    }

    // MARK: Rows

    private var groups: [Group] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ s: String) -> Bool { q.isEmpty || q.split(separator: " ").allSatisfy { s.lowercased().contains($0) } }
        switch mode {
        case .models:
            let rows = engine.models.filter { matches($0.name + " " + $0.id) }.prefix(60).map { m in
                Row(id: "m:\(m.provider)/\(m.id)", icon: m.supports.reasoning ? "brain" : "cpu", title: ModelChip.short(m), detail: AttributedString(" · \(m.id)"), trailing: price(m)) {
                    if let thread { Task { await thread.setModel(m.ref) } }
                    close()
                }
            }
            return rows.isEmpty ? [] : [Group(id: "Models", rows: Array(rows))]
        case .messages:
            let rows = messageRows
            return rows.isEmpty ? [] : [Group(id: "Messages", rows: rows)]
        case .all:
            let actions = commands.filter { matches($0.title) }
            let areas = Areas.shared.set
            var destinations: [Row] = []
            func add(_ id: String, _ title: String, _ type: String, _ icon: String, _ kind: ContainerKind, _ run: @escaping () -> Void) {
                guard matches(title), searchScope.kind == nil || searchScope.kind == kind else { return }
                destinations.append(Row(id: id, icon: icon, title: title, trailing: type, run: { run(); close() }))
            }
            if areas.showsProjects {
                for p in engine.projects { add("p:\(p.id)", p.name, "Folder", "folder", .build) { NotificationCenter.default.post(name: .selectItem, object: SidebarItem.project(p.id).raw) } }
            }
            if areas.contains(.build) {
                for s in engine.buildSessions { add("b:\(s.ref.id)", s.title, "Build", "chevron.left.forwardslash.chevron.right", .build) { openThread(s.ref.id, nil) } }
            }
            if areas.contains(.chat) {
                for s in engine.threads { add("t:\(s.ref.id)", s.title, "Chat", "bubble.left", .thread) { openThread(s.ref.id, nil) } }
                for s in engine.spaces {
                    add("n:\(s.ref.id)", s.title, "Notebook", "book.closed", .space) { NotificationCenter.default.post(name: .selectItem, object: SidebarItem.notebook(s.ref.id).raw) }
                    for topic in s.topics ?? [] { add("n:\(s.ref.id)/\(topic.id)", topic.title, s.title, "text.bubble", .space) { NotificationCenter.default.post(name: .selectItem, object: SidebarItem.notebook("\(s.ref.id)/\(topic.id)").raw) } }
                }
            }
            if areas.contains(.agents) { for s in engine.agents { add("a:\(s.ref.id)", s.title, "Agent", "bird", .agent) { NotificationCenter.default.post(name: .selectItem, object: SidebarItem.agent(s.ref.id).raw) } } }
            let goTo = Array(destinations.prefix(q.isEmpty ? 10 : 25))
            return [Group(id: "Results", rows: goTo + (q.count >= 2 ? messageRows : [])), Group(id: "Actions", rows: searchScope == .all ? actions : [])].filter { !$0.rows.isEmpty }

        }
    }

    private var messageRows: [Row] {
        hits.filter { hit in
            guard hit.kind != .title else { return false }
            switch hit.ref.kind {
            case .thread, .space: return Areas.shared.contains(.chat)
            case .build: return Areas.shared.contains(.build)
            case .agent: return Areas.shared.contains(.agents)
            }
        }.map { hit in
            Row(id: "s:\(hit.id)", icon: hit.kind == .user ? "person" : "sparkles", title: hit.title, detail: AttributedString(" · ") + highlighted(hit.snippet), trailing: hit.ref.kind.rawValue.capitalized + (hit.kind == .user ? " · You" : " · Answer")) {
                openResult(hit)
                close()
            }
        }
    }

    private var commands: [Row] {
        // Only the areas that are on (docs/spec/15).
        let areas = Areas.shared.set
        var rows: [Row] = []
        if areas.contains(.chat) {
            rows += [
                Row(id: "c:new", icon: "square.and.pencil", title: "New Chat", trailing: "⌘N") { newThread(); close() },
                Row(id: "c:notebook", icon: "book.closed", title: "New Notebook", trailing: "⇧⌘N") { close(); NotificationCenter.default.post(name: .newSpace, object: nil) },
                Row(id: "c:debate", icon: "person.2.wave.2", title: "New Debate", trailing: "⌥⌘N") { close(); NotificationCenter.default.post(name: .newDebate, object: nil) },
                Row(id: "c:quick", icon: "bolt", title: "Quick Chat", trailing: QuickChatController.shortcutLabel) { QuickChatController.shared?.show(); close() },
            ]
        }
        if areas.contains(.build) {
            rows.append(Row(id: "c:folder", icon: "folder", title: "Open Folder…", trailing: "⌘O") { close(); NotificationCenter.default.post(name: .openProject, object: nil) })
        }
        if areas.contains(.agents) {
            rows.append(Row(id: "c:agent", icon: "bird", title: "New Agent", trailing: nil) { close(); NotificationCenter.default.post(name: .newAgent, object: nil) })
        }
        rows += [
            Row(id: "c:search", icon: "text.magnifyingglass", title: "Search Messages", trailing: "⇧⌘F") { mode = .messages; query = "" },
            Row(id: "c:settings", icon: "gearshape", title: "Settings", trailing: "⌘,") { ThreadModel.openSettings(); close() },
        ]
        if let thread {
            rows += [
                Row(id: "c:model", icon: "cpu", title: "Change Model…", trailing: "Thread") { mode = .models; query = "" },
                Row(id: "c:web", icon: "globe", title: thread.webEnabled ? "Turn Off Web Search" : "Turn On Web Search", trailing: "Thread") { Task { await thread.setWeb(!thread.webEnabled) }; close() },
                Row(id: "c:copy", icon: "doc.on.doc", title: "Copy Thread as Markdown", trailing: "Thread") { Task { await thread.copyAsMarkdown() }; close() },
                Row(id: "c:export-md", icon: "square.and.arrow.up", title: "Export Thread as Markdown…", trailing: "Thread") { close(); Task { await thread.export(.markdown) } },
                Row(id: "c:export-html", icon: "square.and.arrow.up", title: "Export Thread as HTML…", trailing: "Thread") { close(); Task { await thread.export(.html) } },
            ]
        }
        return rows
    }

    private func rowView(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(rowText(row, selected: selected)).lineLimit(1)
            Spacer(minLength: 8)
            if let trailing = row.trailing {
                Text(selected && row.id.hasPrefix("c:") ? "↩" : trailing).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
        }
        .foregroundStyle(Color.dsFg)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(selected ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
        .contentShape(Rectangle())
    }

    // MARK: Behavior

    private func move(_ delta: Int) {
        let count = groups.flatMap(\.rows).count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func runSelected() {
        let rows = groups.flatMap(\.rows)
        guard rows.indices.contains(selection) else { return }
        rows[selection].run()
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        hits = []; searchError = nil; searching = false
        guard mode != .models, q.trimmingCharacters(in: .whitespaces).count >= 2, let client = engine.client else {
            hits = []
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do {
                let results = try await client.call("catalog.search", SearchParams(query: q, limit: 60, kind: searchScope.kind), as: SearchResults.self).results
                if !Task.isCancelled { hits = results; searching = false }
            } catch {
                if !Task.isCancelled { searchError = "Couldn't search conversations. Check the engine connection and try again."; searching = false }
            }
        }
    }

    private func price(_ m: ModelInfo) -> String {
        m.pricing.input == 0 && m.pricing.output == 0 ? "free" : String(format: "$%.2f/$%.2f", m.pricing.input, m.pricing.output)
    }

    private func rowText(_ row: Row, selected: Bool) -> AttributedString {
        var title = bolded(row.title)
        title.font = title.font ?? .system(size: 13)
        var detail = row.detail ?? AttributedString()
        detail.foregroundColor = .dsFg3
        for run in detail.runs where run.font == nil { detail[run.range].font = .system(size: 12) }
        return title + detail
    }

    /// The typed letters in bold (first match per word).
    private func bolded(_ title: String) -> AttributedString {
        var out = AttributedString(title)
        out.font = .system(size: 13)
        for word in query.lowercased().split(separator: " ") {
            if let r = out.range(of: String(word), options: .caseInsensitive) { out[r].font = .system(size: 13, weight: .semibold) }
        }
        return out
    }

    /// Bold the matches the engine marked (U+0002 … U+0003).
    private func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var current = ""
        func flush() {
            var part = AttributedString(current)
            if bold { part.font = .system(size: 12, weight: .semibold) }
            out += part
            current = ""
        }
        for ch in snippet {
            if ch == "\u{2}" { flush(); bold = true } else if ch == "\u{3}" { flush(); bold = false } else { current.append(ch) }
        }
        flush()
        return out
    }
}
