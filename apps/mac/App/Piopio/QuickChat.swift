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
        // Quick Chat belongs to Chat: no global shortcut while Chat is hidden (docs/spec/15).
        if Areas.shared.contains(.chat), let modifiers = shortcut.carbonModifiers { GlobalHotKey.shared.register(keyCode: UInt32(kVK_Space), modifiers: modifiers) } else { GlobalHotKey.shared.unregister() }
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
        let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 72), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: QuickChatView(model: model))
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        panel.contentViewController = host
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
    /// Shown in the header while the answer is on screen (docs/design 3a).
    var lastQuestion: String?
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
            lastQuestion = nil
        }
    }

    func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, engine.status == .ready else { return }
        text = ""
        lastQuestion = message
        UserDefaults.standard.set(Date(), forKey: "quickChatLastUsed")
        Task {
            if thread == nil {
                guard let ref = await engine.createThread(model: engine.quickChatModel) else { return }
                let t = ThreadModel(ref: ref, engine: engine, notifies: false, compact: true)
                t.document.bottomInset = 12
                thread = t
                await t.open()
            }
            await thread?.send(message)
        }
    }

    var modelName: String {
        let ref = thread?.state?.model ?? engine.quickChatModel
        return engine.model(ref).map(ModelChip.short) ?? ref?.id ?? ""
    }

    func copyAnswer() {
        guard case .assistant(let a)? = thread?.document.lastItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(a.text, forType: .string)
    }

    func newChat() {
        thread?.close()
        thread = nil
        text = ""
        lastQuestion = nil
        focusToken += 1
    }

    func openInMain() {
        guard let ref = thread?.ref else { return }
        hide?()
        WindowOpener.shared.showMain()
        NotificationCenter.default.post(name: .selectThread, object: ref.id)
    }
}

/// docs/design 3a: the question in the header, the answer streaming below, a few actions.
struct QuickChatView: View {
    let model: QuickChatModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if model.text.isEmpty, let question = model.lastQuestion {
                        // The question stays in the header; typing asks a follow-up.
                        Text(question).font(.system(size: 15)).foregroundStyle(Color.dsFg).lineLimit(3).allowsHitTesting(false)
                    }
                    TextField(model.lastQuestion == nil ? "Ask anything…" : "", text: Bindable(model).text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .lineLimit(1...6)
                        .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        model.send()
                        return .handled
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 52)
            if let thread = model.thread {
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                TranscriptView(document: thread.document)
                    .frame(height: 280)
                Rectangle().fill(Color.dsLine).frame(height: 0.5)
                HStack(spacing: 12) {
                    Button("Open in Piopio ⌘O") { model.openInMain() }.keyboardShortcut("o")
                    Button("Copy") { model.copyAnswer() }.keyboardShortcut("c", modifiers: [.command, .shift])
                    Button("New chat") { model.newChat() }.keyboardShortcut("n")
                    Spacer()
                    Text("\(model.modelName) · esc to close").font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.dsFg2)
                .padding(.horizontal, 18)
                .frame(height: 36)
            }
        }
        .frame(width: 620)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.quickChat, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.quickChat, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.quickChat, style: .continuous))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _, _ in focused = true }
    }
}

// MARK: Main window access (the window may be closed while Quick Chat keeps the app running)

@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var openMain: (() -> Void)?
    var openSettings: (() -> Void)?

    func showMain() {
        openMain?()
        NSApp.activate()
    }
}
