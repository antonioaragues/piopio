import AppKit
import Observation
import PiopioKit
import PiopioTranscript
import SwiftTerm
import SwiftUI

// Terminal drawer (docs/spec/05-build §9 TM1–TM2, docs/design 6b): local shells in the session's folder,
// several tabs, and "Send to agent". The agent's own bash runs in the engine (TM3), not here.

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
    let close: () -> Void
    @State private var selected: UUID?
    private let store = TerminalStore.shared

    private var tabs: [TerminalTab] { store.tabs(for: cwd) }
    private var current: TerminalTab? { tabs.first { $0.id == selected } ?? tabs.last }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    HStack(spacing: 6) {
                        Circle().fill(tab.running ? Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255) : Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)).frame(width: 6, height: 6)
                        Text(tab.title).font(.system(size: 11.5, weight: .medium))
                        Button { store.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain)
                            .help("Close this terminal")
                    }
                    .foregroundStyle(Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255).opacity(tab.id == current?.id ? 1 : 0.6))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(tab.id == current?.id ? Color.white.opacity(0.1) : .clear, in: Capsule())
                    .onTapGesture { selected = tab.id }
                }
                Button { selected = store.open(in: cwd).id } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255))
                    .help("New terminal")
                Spacer()
                if let tab = current {
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
            if let tab = current {
                TerminalHost(tab: tab)
                    .id(tab.id)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .frame(height: 300)
        .background(Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255), in: RoundedRectangle(cornerRadius: DS.Radius.panel))
        .onAppear { if tabs.isEmpty { selected = store.open(in: cwd).id } }
    }
}
