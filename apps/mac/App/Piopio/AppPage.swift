import PiopioKit
import PiopioTranscript
import SwiftUI

// Apps (docs/spec/35 §14–15): a page that reads its data from files and redraws when they change, with the
// conversation about it beside it. The toolbar says when its data was read and, in Piopio's own words, which source
// failed and since when; Undo takes back the conversation's latest change to the page and leaves the data as it is.

/// True when an `.html` file starts with an app manifest (`<script … id="piopio-app">`).
enum AppFile {
    static func isApp(_ url: URL) -> Bool {
        guard ["html", "htm"].contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 16_384)) ?? Data(), as: UTF8.self)
        return head.range(of: #"id\s*=\s*["']piopio-app["']"#, options: .regularExpression) != nil
    }
}

/// An app's page: the app in the content card, and its conversation in a panel on the right.
struct AppPage: View {
    let engine: EngineController
    let path: String
    @State private var app: AppView?
    @State private var problem: String?
    @State private var busy = false
    /// The page's script errors since it last loaded (a change that broke it shows here, with Undo).
    @State private var pageErrors: [String] = []
    @State private var conflict: String?
    /// The conversation panel: open the first time, then as you left it (AL11).
    @AppStorage("app.panel") private var panelShown = true

    var body: some View {
        HStack(spacing: CardLayout.margin) {
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                content
            }
            .contentCard()
            if panelShown {
                AppConversationPanel(engine: engine, path: path, conversation: app?.conversation, close: { withAnimation(.easeOut(duration: 0.15)) { panelShown = false } })
                    .frame(width: 360)
                    .contentCard()
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ownsContentCard()
        .task {
            do { app = try await engine.openApp(path) } catch { problem = error.localizedDescription }
        }
        .onDisappear { Task { await engine.closeApp(path) } }
        .onChange(of: engine.appUpdates[path]) { _, update in if let update { show(update) } }
        .alert("Undo anyway?", isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })) {
            Button("Undo Anyway", role: .destructive) { undo(force: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(conflict ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if let app {
            notices(app)
            AppCanvas(html: app.html, title: app.title, payload: Self.payload(app), answer: { text, _ in
                // A button in the app puts its words in the conversation's box, for you to send.
                withAnimation(.easeOut(duration: 0.15)) { panelShown = true }
                NotificationCenter.default.post(name: .appPrefill, object: AppPrefill(path: path, text: text))
            }, onProblem: { text in
                if !pageErrors.contains(text) { pageErrors.append(text) }
            })
        } else if let problem {
            Text(problem).font(.system(size: 13)).foregroundStyle(Color.dsFg2).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2").foregroundStyle(Color.dsFg3)
            Text(app?.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if let app { Text(Self.updated(app)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1) }
            Spacer()
            if let undo = app?.undo {
                Button("Undo") { self.undo(force: false) }
                    .buttonStyle(PillStyle(compact: true))
                    .help("Undo “\(undo.label)”: the page goes back; its data stays as it is now")
            }
            Button {
                Task {
                    busy = true
                    defer { busy = false }
                    if let fresh = try? await engine.refreshApp(path) { show(fresh) }
                }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle()).help("Read its files again").accessibilityLabel("Refresh").disabled(busy || app == nil)
            Menu {
                ForEach(app?.sources ?? [], id: \.name) { s in
                    if let accounts = s.accounts {
                        // A calendar source: each account and when it was read (docs/spec/35 §16).
                        Section(s.file) {
                            ForEach(accounts, id: \.id) { a in
                                Text("\(a.label) · \(a.state == "gone" ? "not connected" : a.readAt.map { "read \(Self.time($0))" } ?? "not read yet")")
                            }
                        }
                    } else {
                        Button("\(s.file)\(s.readAt.map { " · read \(Self.time($0))" } ?? "")") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)]) }
                    }
                }
                Divider()
                if app?.allowed == true {
                    Button("Stop Reading Its Sources") {
                        Task { if let fresh = try? await engine.revokeApp(path) { show(fresh) } }
                    }
                    .help("It reads nothing until you allow it again, and forgets what it read from your calendars")
                }
                Button("Show the App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            } label: { Image(systemName: "doc.text") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Where its data comes from").accessibilityLabel("Sources")
            Button { withAnimation(.easeOut(duration: 0.15)) { panelShown.toggle() } } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(IconButtonStyle()).help(panelShown ? "Hide the conversation" : "Ask about it or change it").accessibilityLabel("Conversation")
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(height: 48)
    }

    /// What's wrong, above the page: a change that broke it, sources waiting for Allow, sources whose read failed.
    @ViewBuilder private func notices(_ app: AppView) -> some View {
        if let first = pageErrors.first {
            notice("The page has an error: \(first)", action: app.undo == nil ? nil : "Undo") { undo(force: false) }
        }
        if !app.allowed {
            // Calendar sources name their accounts: allowing is for those, not every calendar you connect later.
            let reads = app.sources.map { s in s.accounts.map { "\(s.file) from \($0.map(\.label).joined(separator: " and "))" } ?? s.file }
            notice("This app reads \(reads.joined(separator: ", ")). Allow it to read them; until then it shows what it read before, if anything.", action: "Allow") {
                Task { if let fresh = try? await engine.allowApp(path) { show(fresh) } }
            }
        }
        ForEach(app.sources.filter { $0.state == "failed" }, id: \.name) { s in
            if s.accounts != nil {
                // A calendar: the accounts that answered are shown as read now; the others say since when.
                notice("\(s.error ?? "\(s.file) couldn't be read.") \(s.readAt.map { "Its other events are from \(Self.time($0))." } ?? "")", action: "Try Again") {
                    Task { if let fresh = try? await engine.refreshApp(path) { show(fresh) } }
                }
            } else {
                notice("\(s.error ?? "\(s.file) couldn't be read.") \(s.readAt.map { "Showing what it read \(Self.time($0))." } ?? "Nothing to show from it yet.")", action: "Show File") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)])
                }
            }
        }
    }

    private func notice(_ text: String, action: String?, run: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.dsAmber)
                Text(text).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let action { Button(action, action: run).buttonStyle(PillStyle(compact: true)) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.dsAmber.opacity(0.1))
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
        }
    }

    /// New data or a new page: a new page starts with no errors.
    private func show(_ next: AppView) {
        if next.html != app?.html { pageErrors = [] }
        app = next
    }

    private func undo(force: Bool) {
        Task {
            do {
                show(try await engine.undoApp(path, force: force))
            } catch let error as EngineError where error.code == "CONFLICT" {
                conflict = error.message
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// `[data, meta]` for `piopio.onData`.
    static func payload(_ app: AppView) -> String {
        struct Meta: Encodable { let updatedAt: String?; let stale: [String] }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(app.data), let meta = try? encoder.encode(Meta(updatedAt: app.updatedAt, stale: app.stale)) else { return "[{}, {}]" }
        return "[\(String(decoding: data, as: UTF8.self)), \(String(decoding: meta, as: UTF8.self))]"
    }

    static func updated(_ app: AppView) -> String {
        guard let at = app.updatedAt else { return "Not read yet" }
        // "Updated" only when every source read now; otherwise say how old what's shown is (the notice says why).
        return app.stale.isEmpty ? "Updated \(time(at))" : "Data from \(time(at))"
    }

    /// "10:42" today, "Sat 10:42" this week, else a date.
    static func time(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if abs(d.timeIntervalSinceNow) < 6 * 86_400 { return "\(d.formatted(.dateTime.weekday(.abbreviated))) \(d.formatted(date: .omitted, time: .shortened))" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Words from a button in an app, for its conversation's box.
struct AppPrefill { let path: String; let text: String }

extension Notification.Name {
    static let appPrefill = Notification.Name("piopio.appPrefill")
}

/// The conversation about an app: ask about it ("Which month was highest?") or ask for a change ("Add a budget line").
/// It's made when you first write here, so opening an app leaves nothing behind.
struct AppConversationPanel: View {
    let engine: EngineController
    let path: String
    let conversation: String?
    let close: () -> Void
    @State private var thread: ThreadModel?
    @State private var draft = ""
    @State private var starting = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Ask or change").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle()).help("Hide the conversation").accessibilityLabel("Hide the conversation")
            }
            .padding(.leading, 16).padding(.trailing, 10)
            .frame(height: 48)
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            if let thread {
                ZStack(alignment: .bottom) {
                    TranscriptView(document: thread.document)
                    Composer(engine: engine, thread: thread)
                        .padding(.horizontal, 12).padding(.bottom, 12)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in thread.document.bottomInset = height + 24 }
                }
            } else {
                starter
            }
        }
        .task(id: conversation) { await adopt() }
        .onReceive(NotificationCenter.default.publisher(for: .appPrefill)) { note in
            guard let fill = note.object as? AppPrefill, fill.path == path else { return }
            if let thread { thread.draft = [thread.draft ?? "", fill.text].filter { !$0.isEmpty }.joined(separator: "\n\n") } else { draft = fill.text; focused = true }
        }
    }

    /// Before the first message: a box, and what you can ask.
    private var starter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text("Ask about it: “Which month was highest?”\nOr ask for a change: “Add a budget line at 1.100 €.”")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask or ask for a change…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(1...6).focused($focused)
                    .onSubmit(start)
                Button(action: start) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(PillStyle(kind: .strong, compact: true))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || starting)
                    .accessibilityLabel("Send")
            }
            .padding(10)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
        }
        .padding(16)
    }

    private func adopt() async {
        guard thread == nil, let id = conversation else { return }
        let t = engine.thread(ContainerRef(kind: .thread, id: id))
        thread = t
        await t.open()
    }

    private func start() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            guard let ref = try? await engine.appConversation(path) else { return }
            let t = engine.thread(ref)
            thread = t
            await t.open()
            if await t.send(text) { draft = "" }
        }
    }
}
