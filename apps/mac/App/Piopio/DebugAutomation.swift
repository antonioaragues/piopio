import AppKit
import PiopioKit

/// Development hooks for scripted smoke tests (scripts/app-smoke.sh). Inactive unless the env vars are set.
///   PIOPIO_DEMO_PROMPT  create a thread and send this message once the engine is ready
///   PIOPIO_SNAPSHOT     write a PNG of the main window to this path after PIOPIO_SNAPSHOT_DELAY seconds (default 6)
///   PIOPIO_QUIT_AFTER_SNAPSHOT=1  quit afterwards
@MainActor
enum DebugAutomation {
    static func run(engine: EngineController) {
        let env = ProcessInfo.processInfo.environment
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
        let wantsPanel = ProcessInfo.processInfo.environment["PIOPIO_DEMO_QUICK"] != nil
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && ($0 is NSPanel) == wantsPanel }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
