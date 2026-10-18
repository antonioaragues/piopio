import PiopioKit
import SwiftUI

struct RootView: View {
    let engine: EngineController
    @State private var selection: String?
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            ThreadSidebar(engine: engine, selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
        } detail: {
            detail
        }
        .onReceive(NotificationCenter.default.publisher(for: .newThread)) { _ in newThread() }
        .onReceive(NotificationCenter.default.publisher(for: .selectThread)) { note in selection = note.object as? String }
        .onChange(of: engine.status) { _, status in
            if status == .ready, engine.needsKey { showOnboarding = true }
            if status == .ready, selection == nil { selection = engine.threads.first?.ref.id }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(engine: engine) { showOnboarding = false }
        }
    }

    @ViewBuilder private var detail: some View {
        switch engine.status {
        case .starting:
            ProgressView("Starting engine…")
        case .failed(let message):
            ContentUnavailableView {
                Label("The engine isn't running", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await engine.start() } }
            }
        case .ready:
            if let id = selection, let summary = engine.threads.first(where: { $0.ref.id == id }) {
                ThreadView(engine: engine, thread: engine.thread(summary.ref), title: summary.title)
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("No thread selected", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Start a conversation with any model on OpenRouter.")
                } actions: {
                    Button("New Thread") { newThread() }.keyboardShortcut("n")
                }
            }
        }
    }

    private func newThread() {
        Task {
            if let ref = await engine.createThread() {
                try? await engine.refreshCatalog()
                selection = ref.id
            }
        }
    }
}

extension Notification.Name {
    static let selectThread = Notification.Name("piopio.selectThread")
}

struct ThreadSidebar: View {
    let engine: EngineController
    @Binding var selection: String?
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""

    var body: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.threads, id: \.ref.id) { thread in
                        Text(thread.title)
                            .lineLimit(1)
                            .tag(thread.ref.id)
                            .contextMenu {
                                Button("Rename…") {
                                    newTitle = thread.title
                                    renaming = thread
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    if selection == thread.ref.id { selection = nil }
                                    Task { await engine.delete(thread.ref) }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Threads")
        .toolbar {
            ToolbarItem {
                Button { NotificationCenter.default.post(name: .newThread, object: nil) } label: { Label("New Thread", systemImage: "square.and.pencil") }
                    .help("New Thread (⌘N)")
            }
        }
        .alert("Rename Thread", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let thread = renaming { Task { await engine.rename(thread.ref, to: newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private struct Group { let title: String; let threads: [SessionSummary] }

    /// Today / Yesterday / Previous 7 Days / Older, by last activity.
    private var groups: [Group] {
        let calendar = Calendar.current
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var buckets: [(String, [SessionSummary])] = [("Today", []), ("Yesterday", []), ("Previous 7 Days", []), ("Older", [])]
        for t in engine.threads {
            let date = iso.date(from: t.updatedAt) ?? .distantPast
            let index = calendar.isDateInToday(date) ? 0 : calendar.isDateInYesterday(date) ? 1 : now.timeIntervalSince(date) < 7 * 86_400 ? 2 : 3
            buckets[index].1.append(t)
        }
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, threads: $0.1) }
    }
}
