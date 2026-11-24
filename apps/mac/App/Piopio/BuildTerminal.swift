import AppKit
import Observation
import PiopioKit
import PiopioTranscript
import SwiftTerm
import SwiftUI

// Terminal drawer (docs/spec/05-build §9 TM1–TM2, docs/design 6b): local shells in the session's folder,
// several tabs, and "Send to agent". The agent's own bash runs in the engine (TM3), not here; the commands it leaves
// running (TM4) show as tabs of their own, with their output, Stop and Send to agent.

/// One shell. Kept by `TerminalStore`, so switching sessions or closing the drawer doesn't end it.
@MainActor
final class TerminalTab: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let cwd: String
    let view: LocalProcessTerminalView
    private(set) var title: String
    private(set) var running = true
    var onChange: (() -> Void)?

    init(cwd: String, number: Int) {
        self.cwd = cwd
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        title = "\(URL(fileURLWithPath: shell).lastPathComponent) · you\(number > 1 ? " \(number)" : "")"
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 280))
        super.init()
        view.processDelegate = self
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255, alpha: 1)
        view.caretColor = NSColor(srgbRed: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255, alpha: 0.9)
        // A login shell in the folder, with the user's environment minus Piopio's own variables.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PIOPIO_") }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Piopio"
        view.startProcess(executable: shell, args: ["-l"], environment: env.map { "\($0.key)=\($0.value)" }, execName: "-" + URL(fileURLWithPath: shell).lastPathComponent, currentDirectory: cwd)
    }

    /// The selection, or the last lines of output.
    func textForAgent(lines: Int = 60) -> String {
        if let selection = view.getSelection(), !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return selection }
        let all = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        var rows = all.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows.suffix(lines).joined(separator: "\n")
    }

    func interrupt() {
        view.send(data: ArraySlice([3])) // ⌃C
    }

    func terminate() {
        view.process?.terminate()
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.running = false
            self.onChange?()
        }
    }
}

/// Terminals per folder, for the life of the app.
@Observable @MainActor
final class TerminalStore {
    static let shared = TerminalStore()
    private(set) var tabs: [String: [TerminalTab]] = [:]
    private var counter: [String: Int] = [:]
    private var tick = 0

    func tabs(for cwd: String) -> [TerminalTab] {
        _ = tick
        return tabs[cwd] ?? []
    }

    @discardableResult
    func open(in cwd: String) -> TerminalTab {
        counter[cwd, default: 0] += 1
        let tab = TerminalTab(cwd: cwd, number: counter[cwd]!)
        tab.onChange = { [weak self] in self?.tick += 1 }
        tabs[cwd, default: []].append(tab)
        return tab
    }

    func close(_ tab: TerminalTab) {
        tab.terminate()
        tabs[tab.cwd]?.removeAll { $0 === tab }
    }

    /// Ends every shell (app quit).
    func closeAll() {
        for tab in tabs.values.flatMap({ $0 }) { tab.terminate() }
        tabs = [:]
    }
}

/// Shows a tab's terminal view (the same NSView moves between tabs and sessions).
private struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if tab.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        tab.view.removeFromSuperview()
        tab.view.frame = container.bounds
        tab.view.autoresizingMask = [.width, .height]
        container.addSubview(tab.view)
        DispatchQueue.main.async { container.window?.makeFirstResponder(tab.view) }
    }
}

/// The drawer under the transcript (6b): tabs, Send to agent, Stop ⌃C.
struct TerminalDrawer: View {
    let cwd: String
    let session: ThreadModel
    /// The project's preview profile: its folder, as the engine names it (docs/spec/22 §6).
    var previewProfile: String = ""
    let close: () -> Void
    @State private var selected: UUID?
    /// A background command's tab (TM4), instead of a shell.
    @State private var selectedProcess: String?
    private let store = TerminalStore.shared
    private var process: BackgroundProcess? { selectedProcess.flatMap { id in session.processes.first { $0.id == id } } }

    private var tabs: [TerminalTab] { store.tabs(for: cwd) }
    private var current: TerminalTab? { tabs.first { $0.id == selected } ?? tabs.last }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    HStack(spacing: 6) {
                        Circle().fill(tab.running ? Color(white: 0.85) : Color(white: 0.45)).frame(width: 6, height: 6)
                        Text(tab.title).font(.system(size: 11.5, weight: .medium))
                        Button { store.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain)
                            .help("Close this terminal")
                    }
                    .foregroundStyle(Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255).opacity(tab.id == current?.id ? 1 : 0.6))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(tab.id == current?.id && process == nil ? Color.white.opacity(0.1) : .clear, in: Capsule())
                    .onTapGesture { selected = tab.id; selectedProcess = nil }
                }
                // What the agent left running (TM4).
                ForEach(session.processes) { p in
                    HStack(spacing: 6) {
                        Circle().fill(p.status == .running ? Color(white: 0.85) : Color(white: 0.45)).frame(width: 6, height: 6)
                        Text("\(Self.label(p)) · agent").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255).opacity(p.id == process?.id ? 1 : 0.6))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(p.id == process?.id ? Color.white.opacity(0.1) : .clear, in: Capsule())
                    .onTapGesture { selectedProcess = p.id }
                    .help(p.command)
                }
                Button { selected = store.open(in: cwd).id; selectedProcess = nil } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255))
                    .help("New terminal")
                Spacer()
                if let p = process {
                    // Only while it runs: a stopped server's page is gone.
                    if p.status == .running, let url = p.urls.first.flatMap(URL.init(string:)) {
                        // The project preview (docs/spec/22 §6): in Piopio's browser, in the project's own profile.
                        Button(url.host.map { "Preview \($0)\(url.port.map { ":\($0)" } ?? "")" } ?? "Preview") {
                            BrowserCenter.shared.session(session.ref.id).openPreview(url, profile: previewProfile)
                        }
                        .help("Opens \(url.absoluteString) in Piopio's browser, in the project's own profile")
                    }
                    Button("Send to agent") {
                        Task {
                            let out = await session.processOutput(p.id, since: 0)
                            let lines = (out?.text ?? "").split(separator: "\n", omittingEmptySubsequences: false).suffix(60).joined(separator: "\n")
                            session.draft = "Output of `\(p.command)` (\(p.id)):\n```\n\(lines)\n```\n"
                        }
                    }
                    .help("Puts its last lines of output in the composer")
                    if p.status == .running {
                        Button("Stop") { Task { await session.stopProcess(p.id) } }
                            .help("Stops it and what it started")
                    }
                } else if let tab = current {
                    Button("Send to agent") {
                        let text = tab.textForAgent()
                        session.draft = "Terminal output (\(URL(fileURLWithPath: cwd).lastPathComponent)):\n```\n\(text)\n```\n"
                    }
                    .help("Puts the selection, or the last lines of output, in the composer")
                    Button("Stop ⌃C") { tab.interrupt() }
                        .help("Interrupts the running command")
                }
                Button { close() } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                    .help("Hide the terminal (⌃`)")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255))
            .padding(.horizontal, 10)
            .frame(height: 34)
            if let p = process {
                ProcessOutputView(session: session, process: p)
                    .id(p.id)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else if let tab = current {
                TerminalHost(tab: tab)
                    .id(tab.id)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .frame(height: 300)
        .background(Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255), in: RoundedRectangle(cornerRadius: DS.Radius.panel))
        .onAppear { if tabs.isEmpty { selected = store.open(in: cwd).id } }
        // Captures: PIOPIO_DEMO_PROCESS_TAB=1 opens the first background command's tab once there is one.
        .onChange(of: session.processes.first?.id) { _, id in
            if ProcessInfo.processInfo.environment["PIOPIO_DEMO_PROCESS_TAB"] == "1", let id { selectedProcess = id }
        }
    }

    /// "npm run dev", or the agent's label for it, short enough for a tab.
    static func label(_ p: BackgroundProcess) -> String {
        let text = p.command.count <= 28 ? p.command : (p.description ?? String(p.command.prefix(26)) + "…")
        return text
    }
}

/// A background command's output (TM4), read from the engine as it comes while the tab is open.
private struct ProcessOutputView: View {
    let session: ThreadModel
    let process: BackgroundProcess
    @State private var text = ""
    @State private var next: Double = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "No output yet." : text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255).opacity(text.isEmpty ? 0.5 : 1))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .task(id: process.id) {
            while !Task.isCancelled {
                if let r = await session.processOutput(process.id, since: next) {
                    if !r.text.isEmpty {
                        text += r.text
                        if text.count > 200_000 { text = String(text.suffix(200_000)) }
                    }
                    next = r.next
                    if r.process.status != .running { break }
                }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }
}
