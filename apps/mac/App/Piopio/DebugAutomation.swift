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
        // PIOPIO_DEMO_ITEM=<sidebar item> (home, needs, index:projects, project:<id>…): select it after the demo set-up
        // (PIOPIO_DEMO_ITEM_DELAY seconds, default 10).
        if let raw = env["PIOPIO_DEMO_ITEM"] {
            Task {
                try? await Task.sleep(for: .seconds(Double(env["PIOPIO_DEMO_ITEM_DELAY"] ?? "") ?? 10))
                NotificationCenter.default.post(name: .selectItem, object: raw)
            }
        }
        // PIOPIO_DEMO_RESIZE=<width>: resize the main window to this width after 5 s (layout after a resize).
        if let width = env["PIOPIO_DEMO_RESIZE"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(5))
                guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true, animate: false)
            }
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
                // PIOPIO_DEMO_MODEL_PICKER=1: open the model picker (snapshot it with PIOPIO_SNAPSHOT_WINDOW=popover).
                if env["PIOPIO_DEMO_MODEL_PICKER"] == "1" {
                    await waitIdle(thread)
                    thread.showModelPicker = true
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
        // PIOPIO_DEMO_CONNECT=<provider>:<key>,…: connect providers with these (fake) API keys, answering the sign-in
        // sheet's prompt; PIOPIO_DEMO_CONNECT_SHOW=<provider>: then open its sheet and leave it (captures). Use with
        // PIOPIO_KEYCHAIN_SERVICE so nothing lands in the real Keychain.
        if env["PIOPIO_DEMO_CONNECT"] != nil || env["PIOPIO_DEMO_CONNECT_SHOW"] != nil {
            Task {
                await engine.loadProviders()
                for pair in (env["PIOPIO_DEMO_CONNECT"] ?? "").split(separator: ",") {
                    let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let provider = engine.providers.first(where: { $0.id == parts[0] }) else { continue }
                    await engine.connect(provider, method: .apiKey)
                    for _ in 0..<50 where engine.login?.prompt == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    await engine.answerLogin(parts[1])
                    for _ in 0..<50 where engine.login?.finished != true { try? await Task.sleep(for: .milliseconds(100)) }
                    await engine.cancelLogin()
                }
                if let id = env["PIOPIO_DEMO_CONNECT_SHOW"], let provider = engine.providers.first(where: { $0.id == id }) {
                    try? await Task.sleep(for: .seconds(1.5))
                    await engine.connect(provider, method: provider.methods.first?.type ?? .apiKey)
                }
            }
        }
        // PIOPIO_DEMO_ENDPOINT=<name>|<address>: add a custom endpoint; PIOPIO_DEMO_ENDPOINT_SHEET=1: open the add sheet.
        if let spec = env["PIOPIO_DEMO_ENDPOINT"] {
            let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { Task { try? await engine.saveEndpoint(id: nil, name: parts[0], baseUrl: parts[1], key: nil) } }
        }
        // PIOPIO_DEMO_SETTINGS=1: open Settings (snapshot it with PIOPIO_SNAPSHOT_WINDOW=key).
        if env["PIOPIO_DEMO_SETTINGS"] == "1" {
            Task {
                try? await Task.sleep(for: .seconds(1))
                ThreadModel.openSettings()
            }
        }
        // PIOPIO_DEMO_AGENT=<template>: a new agent "Coach"; PIOPIO_DEMO_AGENT_MESSAGES: messages to it ("||");
        // PIOPIO_DEMO_AGENT_CONTACT=<name>: add that contact and write as them once; PIOPIO_DEMO_AGENT_TAB: the tab to show.
        if let template = env["PIOPIO_DEMO_AGENT"], engine.status == .ready {
            Task {
                if let tab = env["PIOPIO_DEMO_AGENT_TAB"] { UserDefaults.standard.set(tab, forKey: "agentTab") }
                guard let ref = try? await engine.createAgent(name: "Coach", template: template.isEmpty ? nil : template, avatar: "") else { return }
                UserDefaults.standard.set(ref.id, forKey: "agentSelection")
                NotificationCenter.default.post(name: .setMode, object: AppMode.agents)
                // PIOPIO_DEMO_AGENT_PEER=<name>: a second agent that Coach may ask (06-agents §7).
                if let peerName = env["PIOPIO_DEMO_AGENT_PEER"], let peer = try? await engine.createAgent(name: peerName, template: nil, avatar: "📒"),
                   let got = await engine.agentDefinition(ref), var def = AgentDef(got.definition) {
                    def.tools.agents = [peer.id]
                    _ = try? await engine.saveAgent(ref, definition: def.json, instructions: got.instructions, message: "Let Coach ask \(peerName)")
                    try? await engine.refreshCatalog()
                }
                if let contact = env["PIOPIO_DEMO_AGENT_CONTACT"], let got = await engine.agentDefinition(ref), var def = AgentDef(got.definition) {
                    def.contacts.append(.init(id: "maria", name: contact, role: "contact"))
                    // PIOPIO_DEMO_AGENT_APPROVE: approval rules (comma-separated), e.g. send_message:to_non_owner.
                    if let rules = env["PIOPIO_DEMO_AGENT_APPROVE"] {
                        var p = def.policies ?? .init()
                        p.requireApproval = rules.components(separatedBy: ",")
                        def.policies = p
                    }
                    _ = try? await engine.saveAgent(ref, definition: def.json, instructions: got.instructions, message: "Add \(contact)")
                    let maria = engine.thread(ContainerRef(kind: .agent, id: ref.id, conversationId: "person:maria"))
                    await maria.open()
                    await maria.send("call: remember | {\"fact\":\"\(contact) is vegetarian\"}")
                }
                let owner = engine.thread(ref)
                await owner.open()
                for message in (env["PIOPIO_DEMO_AGENT_MESSAGES"] ?? "").components(separatedBy: "||") where !message.isEmpty {
                    await owner.send(message.replacingOccurrences(of: "\\n", with: "\n"))
                    for _ in 0..<60 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if owner.state?.status == .idle { break }
                    }
                    try? await Task.sleep(for: .milliseconds(800))
                }
                // PIOPIO_DEMO_AGENT_RUNS: prompts run now ("||"), as if a schedule fired them.
                for prompt in (env["PIOPIO_DEMO_AGENT_RUNS"] ?? "").components(separatedBy: "||") where !prompt.isEmpty {
                    _ = try? await engine.agentRunNow(ref, prompt: prompt.replacingOccurrences(of: "\\n", with: "\n"))
                    try? await Task.sleep(for: .milliseconds(1500))
                }
                // PIOPIO_DEMO_TRACE=1: then open the trace of the last message between agents.
                if env["PIOPIO_DEMO_TRACE"] == "1" {
                    let trace = owner.document.items.reversed().compactMap { item -> String? in if case .agentMsg(let m) = item { m.traceId } else { nil } }.first
                    if let trace { NotificationCenter.default.post(name: .openTrace, object: trace) }
                }
                // PIOPIO_DEMO_INBOX=1: then show the Inbox.
                if env["PIOPIO_DEMO_INBOX"] == "1" { NotificationCenter.default.post(name: .openInbox, object: nil) }
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
                // PIOPIO_DEMO_SPACE_THREAD=<text>: then a thread with this message (its Space suggestion shows).
                if let text = env["PIOPIO_DEMO_SPACE_THREAD"], let thread = await engine.createThread() {
                    try? await engine.refreshCatalog()
                    NotificationCenter.default.post(name: .selectThread, object: thread.id)
                    let model = engine.thread(thread)
                    await model.open()
                    await model.send(text)
                    return
                }
                if let title = env["PIOPIO_DEMO_TOPIC"], let topic = engine.space(ref.id)?.topics?.first(where: { $0.title == title }) {
                    NotificationCenter.default.post(name: .openTopic, object: TopicTarget(spaceId: ref.id, topicId: topic.id, itemId: nil))
                }
                // PIOPIO_DEMO_SPACE_SETTINGS=1: then open its settings sheet; =picker also opens the topic model picker.
                if env["PIOPIO_DEMO_SPACE_SETTINGS"] != nil {
                    try? await Task.sleep(for: .seconds(1))
                    NotificationCenter.default.post(name: .editSpaceInstructions, object: ref.id)
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
                // PIOPIO_DEMO_PROJECT_ONLY=1: just add it (the empty state with a project).
                if env["PIOPIO_DEMO_PROJECT_ONLY"] == "1" { return }
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
                // PIOPIO_DEMO_ANSWER=<text>: answer the first question the agent asks with it.
                if let reply = env["PIOPIO_DEMO_ANSWER"] {
                    for _ in 0..<50 where session.prompts.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                    if let question = session.prompts.first { await session.respond(question, PromptResponse(choice: reply)) }
                }
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
        case "popover": NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
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
