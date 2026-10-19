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
                    if QuickChatController.shared == nil { _ = QuickChatController(engine: engine) }
                    Notifier.shared.setUp()
                    if engine.status != .ready { await engine.start() }
                    DebugAutomation.run(engine: engine)
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") { NotificationCenter.default.post(name: .newThread, object: nil) }
                    .keyboardShortcut("n")
                Button("Quick Chat") { QuickChatController.shared?.show() }
            }
            CommandGroup(after: .textEditing) {
                Button("Command Palette") { NotificationCenter.default.post(name: .showPalette, object: false) }
                    .keyboardShortcut("k")
                Button("Search Messages") { NotificationCenter.default.post(name: .showPalette, object: true) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(engine: engine)
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { engine?.stop() }
    }
}

extension Notification.Name {
    static let newThread = Notification.Name("piopio.newThread")
    /// Object: `true` opens message search.
    static let showPalette = Notification.Name("piopio.showPalette")
}
