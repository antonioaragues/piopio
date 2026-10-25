import PiopioKit
import PiopioTranscript
import SwiftUI

/// ⌘K (docs/design 3b): one list of actions and destinations. Actions first, then "Go to"
/// (threads and messages). Each row shows where it belongs on the right. ⇥ switches All / Messages.
struct CommandPalette: View {
    enum Mode { case all, messages, models }

    let engine: EngineController
    let thread: ThreadModel?
    let close: () -> Void
    let newThread: () -> Void
    let openThread: (String, String?) -> Void // thread id, item to reveal

    @State var mode: Mode
    @State var query = ""
    @State private var selection = 0
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
                Text(scope).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dsFg2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.badge))
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
                            Text(group.id).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
                                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                            ForEach(group.rows) { row in
                                let index = flat.firstIndex { $0.id == row.id } ?? 0
                                rowView(row, selected: index == selection)
                                    .id(index)
                                    .onTapGesture { row.run() }
                            }
                        }
                        if flat.isEmpty {
                            Text(query.isEmpty ? "Type to search" : "No matches")
                                .font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(14)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: selection) { _, s in proxy.scrollTo(s) }
            }
            .frame(height: min(400, listHeight))
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack(spacing: 14) {
                Text("↑↓ navigate"); Text("↩ run"); Text("esc close")
                Spacer()
                if mode != .models { Text("⇥ \(mode == .all ? "messages only" : "everything")") }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.dsFg3)
            .padding(.horizontal, 16)
            .frame(height: 32)
        }
        .frame(width: 560)
        .glassPanel(radius: 16, material: .regularMaterial)
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .onAppear {
            focused = true
            scheduleSearch(query) // a query passed in (automation)
        }
        .onChange(of: query) { _, q in
            selection = 0
            scheduleSearch(q)
        }
        .onChange(of: mode) { _, _ in selection = 0 }
    }

    private var placeholder: String {
        switch mode {
        case .all: "Search actions, threads and messages"
        case .messages: "Search messages"
        case .models: "Pick a model"
        }
    }

    private var scope: String {
        switch mode {
        case .all: "All"
        case .messages: "Messages"
        case .models: "Models"
        }
    }

    private var listHeight: CGFloat {
        let g = groups
        return CGFloat(g.flatMap(\.rows).count) * 40 + CGFloat(g.count) * 30 + 16
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
            let threads = (Areas.shared.set.showsChats ? engine.threads : []).filter { matches($0.title) }.prefix(q.isEmpty ? 6 : 10).map { t in
                Row(id: "t:\(t.ref.id)", icon: "bubble.left", title: t.title, trailing: "Thread") { openThread(t.ref.id, nil); close() }
            }
            let goTo = Array(threads) + (q.count >= 2 ? messageRows : [])
            return [Group(id: "Actions", rows: actions), Group(id: "Go to", rows: goTo)].filter { !$0.rows.isEmpty }
        }
    }

    private var messageRows: [Row] {
        hits.filter { $0.kind != .title }.map { hit in
            Row(id: "s:\(hit.id)", icon: hit.kind == .user ? "person" : "sparkles", title: hit.title, detail: AttributedString(" · ") + highlighted(hit.snippet), trailing: hit.kind == .user ? "You" : "Answer") {
                openThread(hit.ref.id, hit.itemId)
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
            RoundedRectangle(cornerRadius: DS.Radius.badge)
                .fill(selected ? Color.white.opacity(0.22) : Color.dsChip)
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: row.icon).font(.system(size: 10.5, weight: .medium)).foregroundStyle(selected ? .white : Color.dsFg2))
            Text(rowText(row, selected: selected)).lineLimit(1)
            Spacer(minLength: 8)
            if let trailing = row.trailing {
                Text(selected && row.id.hasPrefix("c:") ? "↩" : trailing).font(.system(size: 11.5)).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.dsFg3)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.dsFg)
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: DS.Radius.row))
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
        guard mode != .models, q.trimmingCharacters(in: .whitespaces).count >= 2, let client = engine.client else {
            hits = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let results = (try? await client.call("catalog.search", SearchParams(query: q, limit: 30), as: SearchResults.self).results) ?? []
            if !Task.isCancelled { hits = results }
        }
    }

    private func price(_ m: ModelInfo) -> String {
        m.pricing.input == 0 && m.pricing.output == 0 ? "free" : String(format: "$%.2f/$%.2f", m.pricing.input, m.pricing.output)
    }

    private func rowText(_ row: Row, selected: Bool) -> AttributedString {
        var title = bolded(row.title)
        title.font = title.font ?? .system(size: 13)
        var detail = row.detail ?? AttributedString()
        detail.foregroundColor = selected ? .white.opacity(0.8) : .dsFg3
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
