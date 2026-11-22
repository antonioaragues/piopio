import PiopioKit
import PiopioTranscript
import SwiftUI

// Apps (docs/spec/35 §14): a page that reads its data from files and redraws when they change. It opens wherever a
// file opens (the Library, a pin, the card in a conversation): the toolbar says when its data was read and, in Piopio's
// own words, which source failed and since when; the page below gets the data through `piopio.onData`.

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

/// An app in a sheet, as large as the window allows.
struct AppSheet: View {
    let path: String
    let engine: EngineController
    @Environment(\.dismiss) private var dismiss
    @State private var app: AppView?
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            if let app {
                notices(app)
                AppCanvas(html: app.html, title: app.title, payload: Self.payload(app)) { _, _ in
                    // An app's buttons have no conversation to go to yet (its panel comes with spec 35 L3).
                }
            } else if let problem {
                Text(problem).font(.system(size: 13)).foregroundStyle(Color.dsFg2).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, idealWidth: 1080, minHeight: 560, idealHeight: 760)
        .background(Color.dsWin)
        .task {
            do { app = try await engine.openApp(path) } catch { problem = error.localizedDescription }
        }
        .onDisappear { Task { await engine.closeApp(path) } }
        .onChange(of: engine.appUpdates[path]) { _, update in if let update { app = update } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2").foregroundStyle(Color.dsFg3)
            Text(app?.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if let app { Text(Self.updated(app)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1) }
            Spacer()
            Button {
                Task {
                    busy = true
                    defer { busy = false }
                    if let fresh = try? await engine.refreshApp(path) { app = fresh }
                }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle()).help("Read its files again").accessibilityLabel("Refresh").disabled(busy || app == nil)
            Menu {
                ForEach(app?.sources ?? [], id: \.name) { s in
                    Button("\(s.file)\(s.readAt.map { " · read \(Self.time($0))" } ?? "")") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)]) }
                }
            } label: { Image(systemName: "doc.text") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Where its data comes from").accessibilityLabel("Sources")
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "folder") }
                .buttonStyle(IconButtonStyle()).help("Show the app in Finder").accessibilityLabel("Show in Finder")
            Button("Done") { dismiss() }.buttonStyle(PillStyle(kind: .strong, compact: true)).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    /// What's wrong, above the page: sources waiting for Allow, and sources whose latest read failed.
    @ViewBuilder private func notices(_ app: AppView) -> some View {
        if !app.allowed {
            notice("This app now reads \(app.sources.map(\.file).joined(separator: ", ")). Allow it to read them; until then it shows what it read before.", action: "Allow") {
                Task { if let fresh = try? await engine.allowApp(path) { self.app = fresh } }
            }
        }
        ForEach(app.sources.filter { $0.state == "failed" }, id: \.name) { s in
            notice("\(s.error ?? "\(s.file) couldn't be read.") \(s.readAt.map { "Showing what it read \(Self.time($0))." } ?? "Nothing to show from it yet.")", action: "Show file") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)])
            }
        }
    }

    private func notice(_ text: String, action: String, run: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.dsAmber)
                Text(text).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action, action: run).buttonStyle(PillStyle(compact: true))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.dsAmber.opacity(0.1))
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
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
