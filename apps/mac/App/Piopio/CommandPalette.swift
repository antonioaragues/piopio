import PiopioKit
import SwiftUI

/// ⌘K: commands, threads by title, and message search in one keyboard-driven list.
/// ⌘⇧F opens it in message search mode.
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
        var subtitle: AttributedString?
        var shortcut: String?
        let run: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: mode == .models ? "cpu" : "magnifyingglass").foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return) { runSelected(); return .handled }
                    .onKeyPress(.escape) {
                        if mode == .models { mode = .all; query = ""; return .handled }
                        close(); return .handled
                    }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, selected: index == selection)
                                .id(index)
                                .onTapGesture { row.run() }
                        }
                        if rows.isEmpty {
                            Text(query.isEmpty ? "Type to search" : "No matches")
                                .foregroundStyle(.secondary)
                                .padding(14)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { _, s in proxy.scrollTo(s) }
            }
            .frame(height: min(380, CGFloat(max(rows.count, 1)) * 54 + 12))
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(radius: 24, y: 8)
        .onAppear {
            focused = true
            scheduleSearch(query) // a query passed in (⇧⌘F with a selection, automation)
        }
        .onChange(of: query) { _, q in
            selection = 0
            scheduleSearch(q)
        }
        .onChange(of: mode) { _, _ in selection = 0 }
    }

    private var placeholder: String {
        switch mode {
        case .all: "Search threads, messages and commands"
        case .messages: "Search messages"
        case .models: "Pick a model"
        }
    }

    // MARK: Rows

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ s: String) -> Bool { q.isEmpty || q.split(separator: " ").allSatisfy { s.lowercased().contains($0) } }
        switch mode {
        case .models:
            return engine.models.filter { matches($0.name + " " + $0.id) }.prefix(60).map { m in
                Row(id: "m:\(m.provider)/\(m.id)", icon: m.supports.reasoning ? "brain" : "cpu", title: m.name, subtitle: AttributedString(m.id)) {
                    if let thread { Task { await thread.setModel(m.ref) } }
                    close()
                }
            }
        case .messages:
            return messageRows
        case .all:
            let commands = self.commands.filter { matches($0.title) }
            let threads = engine.threads.filter { matches($0.title) }.prefix(q.isEmpty ? 6 : 12).map { t in
                Row(id: "t:\(t.ref.id)", icon: "bubble.left", title: t.title) { openThread(t.ref.id, nil); close() }
            }
            return commands + threads + (q.count >= 2 ? messageRows : [])
        }
    }

    private var messageRows: [Row] {
        hits.filter { $0.kind != .title || mode == .messages }.map { hit in
            Row(id: "s:\(hit.id)", icon: hit.kind == .user ? "person" : hit.kind == .assistant ? "sparkles" : "text.bubble", title: hit.title, subtitle: highlighted(hit.snippet)) {
                openThread(hit.ref.id, hit.itemId)
                close()
            }
        }
    }

    private var commands: [Row] {
        var rows: [Row] = [
            Row(id: "c:new", icon: "square.and.pencil", title: "New Thread", shortcut: "⌘N") { newThread(); close() },
            Row(id: "c:quick", icon: "bolt", title: "Quick Chat", shortcut: QuickChatController.shortcutLabel) { QuickChatController.shared?.show(); close() },
            Row(id: "c:search", icon: "text.magnifyingglass", title: "Search Messages", shortcut: "⇧⌘F") { mode = .messages; query = "" },
            Row(id: "c:settings", icon: "gearshape", title: "Settings", shortcut: "⌘,") { ThreadModel.openSettings(); close() },
        ]
        if let thread {
            rows += [
                Row(id: "c:model", icon: "cpu", title: "Change Model…") { mode = .models; query = "" },
                Row(id: "c:web", icon: "globe", title: thread.webEnabled ? "Turn Off Web Tools" : "Turn On Web Tools") { Task { await thread.setWeb(!thread.webEnabled) }; close() },
                Row(id: "c:copy", icon: "doc.on.doc", title: "Copy Thread as Markdown") { Task { await thread.copyAsMarkdown() }; close() },
                Row(id: "c:export-md", icon: "square.and.arrow.up", title: "Export Thread as Markdown…") { close(); Task { await thread.export(.markdown) } },
                Row(id: "c:export-html", icon: "square.and.arrow.up", title: "Export Thread as HTML…") { close(); Task { await thread.export(.html) } },
            ]
        }
        return rows
    }

    private func rowView(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.icon).frame(width: 18).foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1)
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.callout).lineLimit(2).foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer()
            if let shortcut = row.shortcut { Text(shortcut).font(.callout).foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary)) }
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    // MARK: Behavior

    private func move(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func runSelected() {
        let rows = self.rows
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

    /// Bold the matches marked by the engine (U+0002 … U+0003).
    private func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var current = ""
        func flush() {
            var part = AttributedString(current)
            if bold { part.font = .callout.bold() }
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
