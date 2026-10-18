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
                    await engine.start()
                    DebugAutomation.run(engine: engine)
                }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") { NotificationCenter.default.post(name: .newThread, object: nil) }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView(engine: engine)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var engine: EngineController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { engine?.stop() }
    }
}

extension Notification.Name {
    static let newThread = Notification.Name("piopio.newThread")
}
