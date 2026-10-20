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
        // PIOPIO_DEMO_SPACE=<name>: a new Space; PIOPIO_DEMO_SPACE_MESSAGES: messages to Main, separated by "||",
        // each sent once the previous settles; PIOPIO_DEMO_TOPIC=<title>: then open that topic.
        if let name = env["PIOPIO_DEMO_SPACE"], engine.status == .ready {
            Task {
                guard let ref = await engine.createSpace(name: name, instructions: env["PIOPIO_DEMO_SPACE_INSTRUCTIONS"] ?? "") else { return }
                NotificationCenter.default.post(name: .selectThread, object: ref.id)
                let main = engine.thread(ref)
                await main.open()
                for message in (env["PIOPIO_DEMO_SPACE_MESSAGES"] ?? "").components(separatedBy: "||") where !message.isEmpty {
                    await main.send(message.replacingOccurrences(of: "\\n", with: "\n"))
                    for _ in 0..<60 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if main.state?.status == .idle { break }
                    }
                    try? await Task.sleep(for: .milliseconds(1500))
                }
                if let title = env["PIOPIO_DEMO_TOPIC"], let topic = engine.space(ref.id)?.topics?.first(where: { $0.title == title }) {
                    NotificationCenter.default.post(name: .openTopic, object: TopicTarget(spaceId: ref.id, topicId: topic.id, itemId: nil))
                }
            }
        }
        // PIOPIO_DEMO_CHAT_PROJECT: add this folder in Chat and open a chat-profile session; PIOPIO_DEMO_PREVIEW=<path>
        // previews a file; PIOPIO_DEMO_BUILD_PROMPT is sent there too.
        if let folder = env["PIOPIO_DEMO_CHAT_PROJECT"], engine.status == .ready {
            Task {
                NotificationCenter.default.post(name: .setMode, object: AppMode.chat)
                guard let project = await engine.addProject(URL(fileURLWithPath: folder), lens: .chat),
                      let ref = await engine.createBuildSession(in: project, profile: .chat) else { return }
                NotificationCenter.default.post(name: .selectThread, object: ref.id)
                let session = engine.thread(ref)
                await session.open()
                if let path = env["PIOPIO_DEMO_PREVIEW"] {
                    try? await Task.sleep(for: .seconds(1))
                    NotificationCenter.default.post(name: .previewFile, object: path)
                }
                if let prompt = env["PIOPIO_DEMO_BUILD_PROMPT"] { await session.send(prompt) }
            }
        }
        // PIOPIO_DEMO_PROJECT: add this folder in Build and open a session there; PIOPIO_DEMO_BUILD_PROMPT: send it.
        if let folder = env["PIOPIO_DEMO_PROJECT"], engine.status == .ready {
            Task {
                NotificationCenter.default.post(name: .setMode, object: AppMode.build)
                guard let project = await engine.addProject(URL(fileURLWithPath: folder)) else { return }
                // PIOPIO_DEMO_NEW_SESSION=<prompt>: open the new session sheet with this prompt (PIOPIO_DEMO_WORKTREE=1: on a worktree).
                if env["PIOPIO_DEMO_NEW_SESSION"] != nil {
                    NotificationCenter.default.post(name: .newBuildSession, object: project.id)
                    return
                }
                guard let ref = await engine.createBuildSession(in: project) else { return }
                NotificationCenter.default.post(name: .selectBuildSession, object: ref.id)
                let session = engine.thread(ref)
                await session.open()
                // PIOPIO_DEMO_PLAN=1: plan mode first; PIOPIO_DEMO_DRAFT: text left in the composer (shows @ and / suggestions).
                if env["PIOPIO_DEMO_PLAN"] == "1" { await session.setPlanMode(true) }
                // PIOPIO_DEMO_TERMINAL=<command>: open the terminal drawer and type it. PIOPIO_DEMO_VIEW=<path>[:line]: the file viewer.
                if let command = env["PIOPIO_DEMO_TERMINAL"] {
                    UserDefaults.standard.set(true, forKey: "buildTerminal")
                    try? await Task.sleep(for: .seconds(2))
                    TerminalStore.shared.tabs(for: session.cwd ?? folder).first?.view.send(txt: command + "\r")
                }
                if let view = env["PIOPIO_DEMO_VIEW"] {
                    let parts = view.split(separator: ":")
                    try? await Task.sleep(for: .seconds(1))
                    session.viewing = FileTarget(path: String(parts[0]), line: parts.count > 1 ? Int(parts[1]) : nil)
                }
                if let draft = env["PIOPIO_DEMO_DRAFT"] {
                    try? await Task.sleep(for: .seconds(1))
                    session.draft = draft
                }
                guard let prompt = env["PIOPIO_DEMO_BUILD_PROMPT"] else { return }
                await session.send(prompt)
                // PIOPIO_DEMO_BUILD_FOLLOWUP: a second turn; PIOPIO_DEMO_REVIEW=1 then opens the diff review,
                // PIOPIO_DEMO_RESTORE=1 the restore sheet for the first checkpoint.
                if let followUp = env["PIOPIO_DEMO_BUILD_FOLLOWUP"] {
                    await waitIdle(session)
                    await session.send(followUp)
                }
                if env["PIOPIO_DEMO_REVIEW"] == "1" || env["PIOPIO_DEMO_RESTORE"] == "1" {
                    await waitIdle(session)
                    try? await Task.sleep(for: .milliseconds(500))
                    if env["PIOPIO_DEMO_REVIEW"] == "1" { NotificationCenter.default.post(name: .showReview, object: ref.id) }
                    if env["PIOPIO_DEMO_RESTORE"] == "1" { session.restoring = session.checkpoints.first }
                }
                // PIOPIO_DEMO_COMMIT=1: open the commit sheet once the turn is done.
                if env["PIOPIO_DEMO_COMMIT"] == "1" {
                    await waitIdle(session)
                    try? await Task.sleep(for: .milliseconds(800))
                    NotificationCenter.default.post(name: .showCommit, object: ref.id)
                }
                // PIOPIO_DEMO_RESPOND=allow|always|deny: answer the first approval the session asks for.
                if let decision = env["PIOPIO_DEMO_RESPOND"].flatMap(PromptResponse.Decision.init(rawValue:)) {
                    for _ in 0..<100 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if let first = session.prompts.first {
                            await session.respond(first, PromptResponse(decision: decision))
                            break
                        }
                    }
                }
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
