import AppKit
import SwiftUI

@main
struct PiopioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine = EngineController()
    @State private var areas = Areas.shared

    init() {
        // Text without macOS font smoothing everywhere (sidebar, composer, Settings), like Claude's app
        // (-webkit-font-smoothing: antialiased): the same SF Pro reads lighter and crisper. AppKit reads this the
        // first time it draws text, so it's registered before any window opens; the transcript also draws its
        // paragraphs this way (Cards.swift drawText).
        UserDefaults.standard.register(defaults: ["AppleFontSmoothing": 0])
    }

    var body: some Scene {
        Window("Piopio", id: "main") {
            RootView(engine: engine)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    appDelegate.engine = engine
                    _ = AppUpdater.shared
                    if QuickChatController.shared == nil { _ = QuickChatController(engine: engine) }
                    Notifier.shared.setUp()
                    Notifier.shared.engine = engine
                    if engine.status != .ready { await engine.start() }
                    DebugAutomation.run(engine: engine)
                }
        }
        .defaultSize(width: 1280, height: 820)
        // The engine starts from this window, so it always opens at launch, even if the app quit without it.
        .defaultLaunchBehavior(.presented)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }
            CommandGroup(replacing: .newItem) {
                // Only the areas that are on (docs/spec/15).
                Button(newTitle) { NotificationCenter.default.post(name: .newThread, object: nil) }
                    .keyboardShortcut("n")
                if areas.contains(.chat) {
                    Button("New Notebook…") { NotificationCenter.default.post(name: .newSpace, object: nil) }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                    Button("New Debate…") { NotificationCenter.default.post(name: .newDebate, object: nil) }
                        .keyboardShortcut("n", modifiers: [.command, .option])
                    Button("Quick Chat") { QuickChatController.shared?.show() }
                }
                if areas.contains(.build) {
                    Divider()
                    Button("Open Folder…") { NotificationCenter.default.post(name: .openProject, object: nil) }
                        .keyboardShortcut("o")
                }
            }
            CommandGroup(after: .textEditing) {
                Button("Command Palette") { NotificationCenter.default.post(name: .showPalette, object: false) }
                    .keyboardShortcut("k")
                Button("Search Messages") { NotificationCenter.default.post(name: .showPalette, object: true) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        // The Inbox in the menu bar (06-agents §12), once there are agents, while Agents is on or something waits.
        MenuBarExtra(isInserted: .constant((areas.contains(.agents) && !engine.agents.isEmpty) || engine.inboxCount > 0)) {
            InboxMenu(engine: engine)
        } label: {
            Image(systemName: engine.inboxCount > 0 ? "tray.full" : "tray")
            if engine.inboxCount > 0 { Text("\(engine.inboxCount)") }
        }

        Settings {
            SettingsView(engine: engine)
        }
        .restorationBehavior(.disabled)
    }
}

extension PiopioApp {
    private var newTitle: String {
        switch (areas.contains(.build), areas.contains(.chat)) {
        case (true, true): "New Chat / Session"
        case (true, false): "New Session"
        case (false, true): "New Chat"
        default: "New Agent"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var engine: EngineController?

    /// Quick Chat keeps working with the main window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            if engine?.agents.isEmpty == false { return false }
            return QuickChatShortcut.current == .off || !Areas.shared.contains(.chat)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { WindowOpener.shared.showMain() } }
        return true
    }

    /// Quitting stops sessions that are working or waiting on you, unless the engine runs in the background.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let engine else { return .terminateNow }
            if engine.isMaintaining {
                let alert = NSAlert(); alert.messageText = "Piopio is saving or restoring data"
                alert.informativeText = "Let this finish before quitting."; alert.runModal()
                return .terminateCancel
            }
            if !engine.runsInBackground, ProcessInfo.processInfo.environment["PIOPIO_QUIT_AFTER_SNAPSHOT"] == nil {
                let busy = engine.busySessions
                if !busy.isEmpty {
                    let alert = NSAlert()
                    let waiting = busy.contains { engine.liveStatus[$0.ref.id] == .waitingApproval }
                    alert.messageText = busy.count == 1 ? "“\(busy[0].title)” is still \(waiting ? "waiting for you" : "working")" : "\(busy.count) sessions are still working"
                    alert.informativeText = "Quitting stops them\(waiting ? " and cancels what they're waiting for" : ""). Your sessions are saved. To continue after quit, turn on background mode in Settings › This Mac & cloud."
                    alert.addButton(withTitle: "Quit Anyway"); alert.addButton(withTitle: "Cancel")
                    if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
                }
            }
            Task {
                do { try await engine.flushDrafts(); sender.reply(toApplicationShouldTerminate: true) }
                catch {
                    let alert = NSAlert(); alert.messageText = "Your latest draft couldn't be saved"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "Stay in Piopio"); alert.addButton(withTitle: "Quit Anyway")
                    sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
                }
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            TerminalStore.shared.closeAll()
            engine?.stop()
        }
    }
}

extension Notification.Name {
    static let newThread = Notification.Name("piopio.newThread")
    /// Object: `true` opens message search.
    static let showPalette = Notification.Name("piopio.showPalette")
}
