import AppKit
import PiopioKit

/// Development hooks for scripted smoke tests and design captures. Inactive unless the env vars are set.
///   PIOPIO_DEMO_PROMPT  create a thread and send this message once the engine is ready
///   PIOPIO_SNAPSHOT     write a PNG of the main window to this path after PIOPIO_SNAPSHOT_DELAY seconds (default 6)
///   PIOPIO_QUIT_AFTER_SNAPSHOT=1  quit afterwards
@MainActor
enum DebugAutomation {
    static func run(engine: EngineController) {
        let env = ProcessInfo.processInfo.environment
        // PIOPIO_DEMO_APPEARANCE=dark|light: force the appearance (captures). PIOPIO_DEMO_MODE=build|chat|agents.
        if let appearance = env["PIOPIO_DEMO_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let mode = env["PIOPIO_DEMO_MODE"].flatMap(AppMode.init(rawValue:)) {
            NotificationCenter.default.post(name: .setMode, object: mode)
        }
        if let prompt = env["PIOPIO_DEMO_PROMPT"], engine.status == .ready {
            Task {
                guard let ref = await engine.createThread() else { return }
                try? await engine.refreshCatalog()
                NotificationCenter.default.post(name: .selectThread, object: ref.id)
                let thread = engine.thread(ref)
                await thread.open()
                // PIOPIO_DEMO_ATTACH: colon-separated file paths attached to the first message.
                let files = (env["PIOPIO_DEMO_ATTACH"] ?? "").split(separator: ":").compactMap { try? AttachmentLoader.load(URL(fileURLWithPath: String($0))).attachment }
                await thread.send(prompt, attachments: files)
                // PIOPIO_DEMO_FOLLOWUP: a second message; PIOPIO_DEMO_EDIT: then edit it into this text.
                if let followUp = env["PIOPIO_DEMO_FOLLOWUP"] {
                    await waitIdle(thread)
                    await thread.send(followUp)
                    if let edit = env["PIOPIO_DEMO_EDIT"] {
                        await waitIdle(thread)
                        guard case .user(let u)? = thread.document.lastUser else { return }
                        thread.beginEditing(u.id, original: u.text)
                        await thread.send(edit)
                    }
                }
                // PIOPIO_DEMO_SEARCH: open message search with this query.
                if let search = env["PIOPIO_DEMO_SEARCH"] {
                    await waitIdle(thread)
                    NotificationCenter.default.post(name: .showPalette, object: search)
                }
                // PIOPIO_DEMO_QUICK: ask this in the Quick Chat panel (snapshot shows the panel).
                if let quick = env["PIOPIO_DEMO_QUICK"] {
                    QuickChatController.shared?.show()
                    QuickChatController.shared?.ask(quick)
                }
            }
        }
        // PIOPIO_DEMO_SETTINGS=1: open Settings (snapshot it with PIOPIO_SNAPSHOT_WINDOW=key).
        if env["PIOPIO_DEMO_SETTINGS"] == "1" {
            Task {
                try? await Task.sleep(for: .seconds(1))
                ThreadModel.openSettings()
            }
        }
        // PIOPIO_DEMO_BACKGROUND=on|off: move the engine to launchd (SMAppService) or back into the app.
        if let background = env["PIOPIO_DEMO_BACKGROUND"] {
            Task { await engine.setRunsInBackground(background == "on") }
        }
        // PIOPIO_DEMO_CHECK_UPDATES=1: run a Sparkle update check (snapshot its window with PIOPIO_SNAPSHOT_WINDOW=key).
        // =install: download silently and install when the app quits.
        if let check = env["PIOPIO_DEMO_CHECK_UPDATES"] {
            Task {
                try? await Task.sleep(for: .seconds(2))
                if check == "install" { AppUpdater.shared.installSilently() } else { AppUpdater.shared.checkForUpdates() }
            }
        }
        if let path = env["PIOPIO_SNAPSHOT"] {
            let delay = Double(env["PIOPIO_SNAPSHOT_DELAY"] ?? "") ?? 6
            Task {
                try? await Task.sleep(for: .seconds(delay))
                snapshot(to: URL(fileURLWithPath: path))
                if env["PIOPIO_QUIT_AFTER_SNAPSHOT"] == "1" { NSApp.terminate(nil) }
            }
        }
    }

    private static func waitIdle(_ thread: ThreadModel) async {
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(50))
            if thread.state?.status == .idle, case .assistant? = thread.document.lastItem { return }
        }
    }

    private static func snapshot(to url: URL) {
        let env = ProcessInfo.processInfo.environment
        let wantsPanel = env["PIOPIO_DEMO_QUICK"] != nil
        let target: NSWindow? = switch env["PIOPIO_SNAPSHOT_WINDOW"] {
        case "sheet": NSApp.windows.compactMap(\.attachedSheet).first
        case "key": NSApp.keyWindow
        case "settings": NSApp.windows.first { $0.isVisible && ($0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") ?? false) }
        default: NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && ($0 is NSPanel) == wantsPanel && $0.attachedSheet == nil || ($0.isVisible && $0.attachedSheet != nil) })
        }
        guard let window = target,
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
