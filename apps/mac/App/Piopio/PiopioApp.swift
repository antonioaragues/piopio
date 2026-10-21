import AppKit
import SwiftUI

@main
struct PiopioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine = EngineController()

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
                Button("New Thread / Session") { NotificationCenter.default.post(name: .newThread, object: nil) }
                    .keyboardShortcut("n")
                Button("New Notebook…") { NotificationCenter.default.post(name: .newSpace, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Quick Chat") { QuickChatController.shared?.show() }
                Divider()
                Button("Open Folder…") { NotificationCenter.default.post(name: .openProject, object: nil) }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .textEditing) {
                Button("Command Palette") { NotificationCenter.default.post(name: .showPalette, object: false) }
                    .keyboardShortcut("k")
                Button("Search Messages") { NotificationCenter.default.post(name: .showPalette, object: true) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        // The Inbox in the menu bar (06-agents §12), once there are agents.
        MenuBarExtra(isInserted: .constant(!engine.agents.isEmpty)) {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var engine: EngineController?

    /// Quick Chat keeps working with the main window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { QuickChatShortcut.current == .off }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { WindowOpener.shared.showMain() } }
        return true
    }

    /// Quitting stops sessions that are working or waiting on you, unless the engine runs in the background.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let engine, !engine.runsInBackground, ProcessInfo.processInfo.environment["PIOPIO_QUIT_AFTER_SNAPSHOT"] == nil else { return .terminateNow }
            let busy = engine.busySessions
            guard !busy.isEmpty else { return .terminateNow }
            let alert = NSAlert()
            let waiting = busy.contains { engine.liveStatus[$0.ref.id] == .waitingApproval }
            alert.messageText = busy.count == 1 ? "“\(busy[0].title)” is still \(waiting ? "waiting for you" : "working")" : "\(busy.count) sessions are still working"
            alert.informativeText = "Quitting stops them\(waiting ? " and cancels what they're waiting for" : ""). Your sessions are saved, and you can ask the agent to continue later. To keep sessions running after you quit, turn on Settings › Engines › Keep running when Piopio quits."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
