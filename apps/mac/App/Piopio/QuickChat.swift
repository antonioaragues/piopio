import AppKit
import Carbon.HIToolbox
import Observation
import PiopioKit
import PiopioTranscript
import SwiftUI

// MARK: Global hotkey (Carbon: works without Accessibility permission)

@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    var action: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.action?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5050_4F50), id: 1) // 'PPOP'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

/// Quick Chat shortcut choices (Settings › General).
enum QuickChatShortcut: String, CaseIterable, Identifiable {
    case optionSpace, controlSpace, commandShiftSpace, optionCommandSpace, off
    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionSpace: "⌥Space"
        case .controlSpace: "⌃Space"
        case .commandShiftSpace: "⇧⌘Space"
        case .optionCommandSpace: "⌥⌘Space"
        case .off: "Off"
        }
    }

    var carbonModifiers: UInt32? {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlSpace: UInt32(controlKey)
        case .commandShiftSpace: UInt32(cmdKey | shiftKey)
        case .optionCommandSpace: UInt32(optionKey | cmdKey)
        case .off: nil
        }
    }

    static var current: QuickChatShortcut {
        UserDefaults.standard.string(forKey: "quickChatShortcut").flatMap(QuickChatShortcut.init(rawValue:)) ?? .optionSpace
    }
}

// MARK: Panel

/// A floating panel over any app (Spotlight-style): ask, read the answer, open it in the main window.
@MainActor
final class QuickChatController {
    static var shared: QuickChatController?
    static var shortcutLabel: String? { QuickChatShortcut.current == .off ? nil : QuickChatShortcut.current.label }

    private let model: QuickChatModel
    private var panel: NSPanel?

    init(engine: EngineController) {
        model = QuickChatModel(engine: engine)
        model.hide = { [weak self] in self?.hide() }
        Self.shared = self
        GlobalHotKey.shared.action = { [weak self] in self?.toggle() }
        applyShortcut()
    }

    func applyShortcut() {
        let shortcut = QuickChatShortcut.current
        if let modifiers = shortcut.carbonModifiers { GlobalHotKey.shared.register(keyCode: UInt32(kVK_Space), modifiers: modifiers) } else { GlobalHotKey.shared.unregister() }
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.maxY - frame.height - screen.visibleFrame.height * 0.18))
        }
        model.prepare()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Sends a question as if typed in the panel (automation).
    func ask(_ text: String) {
        model.text = text
        model.send()
    }

    private func makePanel() -> NSPanel {
        let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: QuickChatView(model: model))
        return panel
    }
}

private final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) } // Esc
}

@Observable @MainActor
final class QuickChatModel {
    let engine: EngineController
    private(set) var thread: ThreadModel?
    var text = ""
    var focusToken = 0
    @ObservationIgnored var hide: (() -> Void)?

    /// Follow-ups within this window continue the same quick thread.
    static let continueWindow: TimeInterval = 10 * 60

    init(engine: EngineController) { self.engine = engine }

    func prepare() {
        focusToken += 1
        if let thread, let last = UserDefaults.standard.object(forKey: "quickChatLastUsed") as? Date, Date().timeIntervalSince(last) > Self.continueWindow,
           thread.state?.status != .running {
            self.thread = nil // start fresh after a while
        }
    }

    func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, engine.status == .ready else { return }
        text = ""
        UserDefaults.standard.set(Date(), forKey: "quickChatLastUsed")
        Task {
            if thread == nil {
                guard let ref = await engine.createThread() else { return }
                let t = ThreadModel(ref: ref, engine: engine, notifies: false)
                thread = t
                await t.open()
            }
            await thread?.send(message)
        }
    }

    func newChat() {
        thread?.close()
        thread = nil
        text = ""
        focusToken += 1
    }

    func openInMain() {
        guard let ref = thread?.ref else { return }
        hide?()
        WindowOpener.shared.showMain()
        NotificationCenter.default.post(name: .selectThread, object: ref.id)
    }
}

struct QuickChatView: View {
    let model: QuickChatModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill").foregroundStyle(.tint)
                TextField("Ask anything…", text: Bindable(model).text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if press.modifiers.contains(.command) { model.openInMain() } else { model.send() }
                        return .handled
                    }
            }
            .padding(16)
            if let thread = model.thread {
                Divider()
                TranscriptView(document: thread.document)
                    .frame(minHeight: 240)
                Divider()
                HStack {
                    Text(model.engine.model(thread.state?.model)?.name ?? "").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("New Chat") { model.newChat() }.controlSize(.small)
                    Button("Open in Piopio  ⌘↩") { model.openInMain() }.controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(.regularMaterial)
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _, _ in focused = true }
    }
}

// MARK: Main window access (the window may be closed while Quick Chat keeps the app running)

@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var openMain: (() -> Void)?

    func showMain() {
        openMain?()
        NSApp.activate()
    }
}
