import AppKit
import PiopioKit

/// Development hooks for scripted smoke tests and design captures. Inactive unless the env vars are set.
///   PIOPIO_DEMO_PROMPT  create a thread and send this message once the engine is ready (PIOPIO_DEMO_PROMPT_MODEL: on this model)
///   PIOPIO_SNAPSHOT     write a PNG of the main window to this path after PIOPIO_SNAPSHOT_DELAY seconds (default 6)
///   PIOPIO_QUIT_AFTER_SNAPSHOT=1  quit afterwards
@MainActor
enum DebugAutomation {
    private static func seedMemory(_ engine: EngineController) async {
        guard let client = engine.client else { return }
        _ = try? await client.call("aboutMe.set", TextParams(text: "## Home\n- Lives in Madrid, in Chamberí\n- Partner: Sam, a sound engineer\n\n## Health\n- Allergic to cashews\n\n## Preferences\n- Prefers short answers"), as: Empty.self)
        await engine.updateSettings(SettingsPatch(aboutMe: .init(enabled: true, capture: true, inThreads: true)))
        guard let ref = try? await engine.createAgent(name: "Daily briefing", template: "daily-briefing", avatar: "☀️") else { return }
        let owner = "\(ref.id)/owner"
        let me = HomeView.firstName
        let add = { (text: String, replaces: String?) async in
            _ = try? await client.call("memory.add", MemoryAddParams(provider: "builtin", bank: owner, text: text, replaces: replaces), as: Empty.self)
        }
        await add("\(me) is a nurse at Hospital La Fe, on night shifts", nil)
        await add("\(me) runs most mornings and is training for the Madrid half marathon on 27 September", nil)
        await add("\(me) wants the briefing at 7:00, with the weather first", nil)
        await add("\(me)'s sister Lucía gets married on 3 October in Seville", nil)
        let list = try? await client.call("memory.list", MemoryListParams(provider: "builtin", bank: owner, kinds: ["fact"]), as: MemoryListResult.self)
        if let nurse = list?.records.first(where: { $0.text.contains("La Fe") }) { await add("\(me) works in pediatrics at Hospital Gregorio Marañón, on day shifts (since June)", nurse.id) }
        if let wedding = list?.records.first(where: { $0.text.contains("Lucía") }) { await add("Lucía's wedding moved to 7 November, same city", wedding.id) }
        _ = try? await client.call("memory.add", MemoryAddParams(provider: "builtin", bank: "\(ref.id)/shared", text: "The family calendar is the shared one called Home"), as: Empty.self)
    }

    private static func seedAutomations(_ engine: EngineController, screen: String) async {
        let select = { (item: SidebarItem) in NotificationCenter.default.post(name: .selectItem, object: item.raw) }
        let demo = { (what: String) in NotificationCenter.default.post(name: .automationsDemo, object: what) }
        if screen == "empty" { select(.automations(nil)); return }
        // ask: the empty page asks Piopio for one in plain words (the scripted model calls automate). draft-empty: by hand.
        if screen == "ask" || screen == "draft-empty" {
            select(.automations(nil))
            try? await Task.sleep(for: .seconds(1.5))
            demo(screen == "ask" ? "ask:call: automate | {\"when\":\"0 8 * * 1-5\",\"name\":\"Morning brief\",\"prompt\":\"Send me today's calendar and anything urgent in my inbox.\"}" : "draft")
            return
        }
        guard let rita = try? await engine.createAgent(name: "Rita", template: nil, avatar: "", instructions: "Watch what Acme, Brightly and Northwind ship and what they charge. Tell me what changed, briefly.", schedule: .null),
              let coach = try? await engine.createAgent(name: "Coach", template: nil, avatar: "", instructions: "Keep me to my training plan.", schedule: .null) else { return }
        for (ref, line) in [(rita, "Watches Acme, Brightly and Northwind"), (coach, "Keeps you to your training plan")] {
            if let got = await engine.agentDefinition(ref), var def = AgentDef(got.definition) {
                def.description = line
                _ = try? await engine.saveAgent(ref, definition: def.json, instructions: got.instructions, message: "One line")
            }
        }
        try? await engine.refreshCatalog()
        let folder = FileManager.default.temporaryDirectory.appending(path: "Invoices").path
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        _ = try? await engine.addAutomation(AutomationChange(name: "Daily price check", when: "0 8 * * *", runsAs: rita.id, prompt: "call: send_message | {\"to\":\"owner\",\"text\":\"Brightly dropped its Pro plan from $24 to $18 a month overnight. Acme and Northwind didn't change.\"}", result: .chat))
        _ = try? await engine.addAutomation(AutomationChange(name: "File new invoices", on: .folder, folder: folder, runsAs: "piopio", prompt: "Read the new invoice, file it under its supplier and tell me the total.", result: .quiet))
        if let morning = try? await engine.addAutomation(AutomationChange(name: "Morning summary", when: "30 7 * * 1-5", runsAs: coach.id, prompt: "Summarise today's training and what I ate yesterday.", result: .chat)) {
            _ = try? await engine.updateAutomation(morning.id, AutomationChange(enabled: false))
        }
        // The price check runs once: its message in Rita's chat carries "From Daily price check".
        if let check = engine.automations.first(where: { $0.name == "Daily price check" }) { _ = try? await engine.runAutomation(check.id) }
        try? await Task.sleep(for: .seconds(2))
        // Rita makes one in her chat: the creation card ("from": only the run's message, with its label).
        if screen == "from" { UserDefaults.standard.set("Chat", forKey: "agentTab"); select(.agent(rita.id)); return }
        let owner = engine.thread(rita)
        await owner.open()
        await owner.send("call: automate | {\"when\":\"0 9 * * 1\",\"name\":\"Weekly competitor brief\",\"prompt\":\"Summarise what competitors shipped last week. Lead with anything that affects our pricing. Keep it under 10 lines.\"}")
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(100))
            if owner.state?.status == .idle { break }
        }
        await engine.loadAutomations()
        switch screen {
        case "page": if let a = engine.automations.first(where: { $0.name == "Weekly competitor brief" }) { select(.automation(a.id)) }
        case "chat": UserDefaults.standard.set("Chat", forKey: "agentTab"); select(.agent(rita.id))
        case "setup": UserDefaults.standard.set("Setup", forKey: "agentTab"); select(.agent(rita.id))
        // new: New automation's popover over the list; draft: setting one up by hand.
        case "new", "draft", "draft-on":
            select(.automations(nil))
            try? await Task.sleep(for: .seconds(1))
            demo(screen == "new" ? "new" : "draft")
            // draft-on: then it's told something and turned on (its page opens).
            if screen == "draft-on" {
                try? await Task.sleep(for: .seconds(1.5))
                demo("turn-on:Check the weather in Madrid and tell me if I need an umbrella.")
            }
        default: select(.automations(nil))
        }
    }

    static func run(engine: EngineController) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["PIOPIO_RECOVERY_REPORT"] {
            Task { await DebugRecovery.run(engine, report: URL(fileURLWithPath: path)) }
            return
        }
        // PIOPIO_DEMO_APPEARANCE=dark|light: force the appearance (captures). PIOPIO_DEMO_MODE=build|chat|agents.
        if let appearance = env["PIOPIO_DEMO_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        // PIOPIO_DEMO_HOVER_PROBE="x,y;c:x,y;…" (main-window points from the top left, "c:" clicks there first): after
        // PIOPIO_DEMO_HOVER_DELAY seconds (default 8), moves the mouse through the points as events, leaves the I-beam set
        // as a text field would, moves once more and writes the cursor at each point, and the view under it, to
        // PIOPIO_DEMO_CURSOR_OUT (expected: the I-beam over text, the arrow elsewhere).
        if let probe = env["PIOPIO_DEMO_HOVER_PROBE"], let out = env["PIOPIO_DEMO_CURSOR_OUT"] {
            Task {
                try? await Task.sleep(for: .seconds(Double(env["PIOPIO_DEMO_HOVER_DELAY"] ?? "") ?? 8))
                let lines = await hoverProbe(probe)
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // PIOPIO_DEMO_ITEM=<sidebar item> (home, index:projects, project:<id>…): select it after the demo set-up
        // (PIOPIO_DEMO_ITEM_DELAY seconds, default 10).
        if let raw = env["PIOPIO_DEMO_ITEM"] {
            Task {
                try? await Task.sleep(for: .seconds(Double(env["PIOPIO_DEMO_ITEM_DELAY"] ?? "") ?? 10))
                NotificationCenter.default.post(name: .selectItem, object: raw)
            }
        }
        // PIOPIO_DEMO_TEMPORARY=box|new|first|chat (docs/spec/14 M4): Home's box with Temporary on; the New conversation page
        // from New Temporary Chat; a temporary chat just after its first message; or one left and opened again.
        if let what = env["PIOPIO_DEMO_TEMPORARY"] {
            Task {
                try? await Task.sleep(for: .seconds(3))
                switch what {
                case "box": NotificationCenter.default.post(name: .newTemporaryChat, object: "home")
                case "new": startTemporaryChat()
                default:
                    guard let ref = await engine.createThread(temporary: true) else { return }
                    let thread = engine.thread(ref)
                    await thread.open()
                    _ = await thread.send("I started the new blood pressure pills on Monday and I get dizzy when I stand up. Is that normal?")
                    try? await engine.refreshCatalog()
                    if what == "first" { NotificationCenter.default.post(name: .selectThread, object: ref.id); return }
                    NotificationCenter.default.post(name: .selectItem, object: SidebarItem.home.raw)
                    try? await Task.sleep(for: .seconds(1.5))
                    NotificationCenter.default.post(name: .selectThread, object: ref.id)
                }
            }
        }
        // PIOPIO_DEMO_LEARN=card|later|saved|skill|edit (docs/spec/14 M5): a Build session in a scratch folder whose scripted
        // model proposes two rules and a fact (a rule and a skill: "skill"); then written past ("later") or saved. "edit":
        // a rule and a skill in the Edit… sheet, with a second skill whose instructions you've cleared there.
        if let what = env["PIOPIO_DEMO_LEARN"] {
            Task {
                try? await Task.sleep(for: .seconds(3))
                let folder = FileManager.default.temporaryDirectory.appending(path: "piopio-learn-demo")
                try? FileManager.default.removeItem(at: folder)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? "# piopio\n\n## Testing\n\n- Swift tests: scripts/swift-test.sh.\n".write(to: folder.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
                guard let client = engine.client,
                      let ref = try? await client.call("sessions.create", CreateSessionParams(kind: .build, cwd: folder.path, title: "Fix the release script"), as: CreateSessionResult.self).ref else { return }
                try? await engine.refreshCatalog()
                NotificationCenter.default.post(name: .selectBuildSession, object: ref.id)
                let thread = engine.thread(ref)
                await thread.open()
                let skill = #"{"to":"skill","name":"release-piopio","text":"When asked to cut, tag or publish a Piopio release.","body":"1. Bump the version in `apps/mac/App/project.yml`.\n2. Write the notes in `build/release/updates/`.\n3. Run `scripts/release.sh <version>` with the signing variables.\n4. Upload the DMG, the deltas and `appcast.xml`.","why":"you walked it through a release"}"#
                let items = what == "skill" || what == "edit" ? #"{"items":[{"to":"project","section":"Testing","text":"Run unit tests with `pnpm test:unit`; `npm test` is the whole suite.","why":"you corrected the test command"},"# + skill + "]}" : #"{"items":[{"to":"project","section":"Testing","text":"Run unit tests with `pnpm test:unit` (14 s); `npm test` runs the whole suite (6 min), only before a release.","why":"you corrected the test command"},{"to":"project","section":"Generated files","text":"Never edit `apps/mac/App/build/`: it's generated by `scripts/build-app.sh`.","why":"you said the build folder is generated"},{"to":"about_me","text":"Writes commit messages in English, without emoji.","why":"you rewrote two commit messages"}]}"#
                _ = await thread.send("call: propose_learnings | \(items)")
                // The scripted model echoes the call slowly: wait for its card, then for the turn to end.
                var call: String?
                for _ in 0..<120 where call == nil || thread.isRunning {
                    try? await Task.sleep(for: .milliseconds(250))
                    call = thread.document.items.compactMap({ if case .tool(let t) = $0, t.tool == "propose_learnings" { t.callId } else { nil } }).last
                }
                guard let call else { return }
                if what == "later" { _ = await thread.send("Now update the changelog for 0.1.0.") }
                if what == "saved" { await thread.learn("save", call) }
                if what == "edit" {
                    await thread.learn("edit", call)
                    thread.editingLearn?.items.append(LearnItem(to: .skill, text: "When asked to update the changelog.", name: "changelog", body: ""))
                }
            }
        }
        // PIOPIO_DEMO_SKILLS=1 (backlog D9): two skills of yours, then Settings › Extensions. Set PIOPIO_PI_AGENT_DIR too,
        // or they're written to your real ~/.pi/agent/skills.
        if env["PIOPIO_DEMO_SKILLS"] == "1", env["PIOPIO_PI_AGENT_DIR"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(3))
                for (name, when, body) in [("release-piopio", "When asked to cut, tag or publish a Piopio release.", "1. Bump the version.\n2. Run scripts/release.sh."),
                                           ("monthly-invoices", "When asked for the monthly invoice report: totals by client from the bank CSV.", "1. Export the CSV.\n2. Sum by client.")] {
                    _ = try? await engine.client?.call("skills.save", SkillSaveParams(name: name, description: when, body: body), as: SkillSaveResult.self)
                }
                // Two hooks (PAR6) beside them.
                for spec in [HookSpec(when: .after, tools: [.edit, .write], files: "*.swift", run: "swiftformat \"$FILE\""),
                             HookSpec(when: .before, tools: [.bash], command: "git push --force*", stop: "Ask me before force-pushing.")] {
                    _ = try? await engine.client?.call("hooks.save", HookSaveParams(spec: spec), as: HookPathResult.self)
                }
                UserDefaults.standard.set("Extensions", forKey: "settingsSection")
                ThreadModel.openSettings()
            }
        }
        // PIOPIO_DEMO_LINK=<folder>[!],…: link these folders to the first project ("!": editable) after the item delay, then
        // open it (docs/spec/18 §18).
        if let spec = env["PIOPIO_DEMO_LINK"] {
            Task {
                try? await Task.sleep(for: .seconds((Double(env["PIOPIO_DEMO_ITEM_DELAY"] ?? "") ?? 10) + 1))
                await engine.loadProjects()
                guard let project = engine.projects.first else { return }
                for part in spec.split(separator: ",") {
                    let edit = part.hasSuffix("!")
                    try? await engine.linkFolder(URL(fileURLWithPath: String(edit ? part.dropLast() : part)), edit: edit, to: project)
                }
                NotificationCenter.default.post(name: .selectItem, object: SidebarItem.project(project.id).raw)
                // PIOPIO_DEMO_PROJECT_SETTINGS=1|instructions|memory: then its settings sheet, or that file's editor (18 §19).
                if let open = env["PIOPIO_DEMO_PROJECT_SETTINGS"] {
                    try? await Task.sleep(for: .seconds(1))
                    NotificationCenter.default.post(name: .projectSettings, object: open == "1" ? project.id : project.id + "|" + open)
                }
            }
        }
        // PIOPIO_DEMO_NAME_PROJECT=<name>: New project after the item delay (+1 s), named in the sidebar; with a name, it's
        // typed and made ("1": the empty row, waiting for a name).
        if let name = env["PIOPIO_DEMO_NAME_PROJECT"] {
            Task {
                try? await Task.sleep(for: .seconds((Double(env["PIOPIO_DEMO_ITEM_DELAY"] ?? "") ?? 10) + 1))
                if name != "1" { ProjectNaming.shared.demoName = name }
                NotificationCenter.default.post(name: .newProject, object: nil)
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
                // With PIOPIO_DEMO_CONNECT_APPS, wait until those apps are connected.
                let apps = (env["PIOPIO_DEMO_CONNECT_APPS"] ?? "").split(separator: ",").map(String.init)
                for _ in 0..<60 where !apps.allSatisfy({ id in engine.connectors.first { $0.id == id }?.accounts.isEmpty == false }) { try? await Task.sleep(for: .milliseconds(200)) }
                guard let ref = await engine.createThread() else { return }
                try? await engine.refreshCatalog()
                NotificationCenter.default.post(name: .selectThread, object: ref.id)
                let thread = engine.thread(ref)
                await thread.open()
                // PIOPIO_DEMO_PROMPT_MODEL=provider/id: the chat's model before its first message (claude-code/opus with
                // PIOPIO_FAKE_CLAUDE_CODE=1 for a conversation on the pretend Claude Code, docs/spec/31).
                if let raw = env["PIOPIO_DEMO_PROMPT_MODEL"], let slash = raw.firstIndex(of: "/") {
                    await thread.setModel(ModelRef(provider: String(raw[..<slash]), id: String(raw[raw.index(after: slash)...])))
                }
                // PIOPIO_DEMO_BROWSER=1: open the Browser panel in this chat.
                if env["PIOPIO_DEMO_BROWSER"] == "1" { BrowserCenter.shared.openPanels.insert(ref.id) }
                // PIOPIO_DEMO_ATTACH: colon-separated file paths attached to the first message.
                let files = (env["PIOPIO_DEMO_ATTACH"] ?? "").split(separator: ":").compactMap { try? AttachmentLoader.load(URL(fileURLWithPath: String($0))).attachment }
                await thread.send(prompt, attachments: files)
                // PIOPIO_DEMO_ALLOW=<seconds>: allow the chat's first card that asks, after that long (a card's after).
                if let wait = env["PIOPIO_DEMO_ALLOW"].flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(wait))
                    let pending = thread.document.items.compactMap { item -> String? in
                        if case .approval(let a) = item, a.status == .pending { return a.approvalId } else { return nil }
                    }.first
                    if let pending { thread.handle(.decideApproval(approvalId: pending, approve: true)) }
                }
                // PIOPIO_DEMO_OPEN_ATTACHMENT=1: then open the first file sent, in the viewer.
                if env["PIOPIO_DEMO_OPEN_ATTACHMENT"] == "1" {
                    await waitIdle(thread)
                    if case .user(let u)? = thread.document.lastUser, let stored = u.attachments?.first?.stored { thread.handle(.openAttachment(stored: stored)) }
                }
                // PIOPIO_DEMO_SWITCH_MODEL alone: switch after the first answer and stop there (the composer's Undo).
                if let raw = env["PIOPIO_DEMO_SWITCH_MODEL"], env["PIOPIO_DEMO_FOLLOWUP"] == nil, let slash = raw.firstIndex(of: "/") {
                    await waitIdle(thread)
                    await thread.setModel(ModelRef(provider: String(raw[..<slash]), id: String(raw[raw.index(after: slash)...])))
                }
                // PIOPIO_DEMO_FOLLOWUP: a second message; PIOPIO_DEMO_EDIT: then edit it into this text.
                if let followUp = env["PIOPIO_DEMO_FOLLOWUP"] {
                    await waitIdle(thread)
                    // PIOPIO_DEMO_SWITCH_MODEL=provider/id: switch the conversation's model first (docs/spec/31 CA7).
                    if let raw = env["PIOPIO_DEMO_SWITCH_MODEL"], let slash = raw.firstIndex(of: "/") {
                        await thread.setModel(ModelRef(provider: String(raw[..<slash]), id: String(raw[raw.index(after: slash)...])))
                    }
                    await thread.send(followUp)
                    if let edit = env["PIOPIO_DEMO_EDIT"] {
                        await waitIdle(thread)
                        guard case .user(let u)? = thread.document.lastUser else { return }
                        thread.beginEditing(u.id, original: u.text)
                        await thread.send(edit)
                    }
                }
                // PIOPIO_DEMO_CONTEXT=1: open the context popover (snapshot it with PIOPIO_SNAPSHOT_WINDOW=popover).
                if env["PIOPIO_DEMO_CONTEXT"] == "1" {
                    await waitIdle(thread)
                    for _ in 0..<300 where thread.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                    thread.showContext = true
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
        // PIOPIO_DEMO_CONNECT_APPS=google-calendar,outlook: connect these apps (with PIOPIO_CONNECTOR_ENDPOINTS pointing at a
        // fake server and PIOPIO_KEYCHAIN_SERVICE set, so nothing real is touched).
        if let apps = env["PIOPIO_DEMO_CONNECT_APPS"] {
            Task {
                await engine.loadConnectors()
                for id in apps.split(separator: ",").map(String.init) {
                    guard let c = engine.connectors.first(where: { $0.id == id }) else { continue }
                    await engine.connect(c)
                    for _ in 0..<50 where engine.connectorLogin?.finished != true { try? await Task.sleep(for: .milliseconds(100)) }
                    await engine.cancelConnectorLogin()
                }
            }
        }
        // PIOPIO_DEMO_MEMORY_SEED=1: About me, and an agent with learned facts, one of them replaced (Settings › Memory).
        let seeded: Task<Void, Never>? = env["PIOPIO_DEMO_MEMORY_SEED"] == "1" && engine.status == .ready ? Task { await seedMemory(engine) } : nil
        // PIOPIO_DEMO_SETTINGS=1: open Settings (snapshot it with PIOPIO_SNAPSHOT_WINDOW=key).
        if env["PIOPIO_DEMO_SETTINGS"] == "1" {
            Task {
                await seeded?.value
                try? await Task.sleep(for: .seconds(1))
                ThreadModel.openSettings()
            }
        }
        // PIOPIO_DEMO_AUTOMATIONS=list|page|chat|setup|empty|ask|new|draft|draft-on|draft-empty: two agents (Rita, Coach) and a few automations, one made in
        // Rita's chat (its card) and one run that wrote to her (its "From" label), then that screen (the agents and
        // automations handoff's captures).
        if let screen = env["PIOPIO_DEMO_AUTOMATIONS"], engine.status == .ready {
            Task { await seedAutomations(engine, screen: screen) }
        }
        // PIOPIO_DEMO_LIBRARY=page|preview|<an item's name>: the Library (docs/spec/35 §4), with that item's preview open.
        if let screen = env["PIOPIO_DEMO_LIBRARY"], engine.status == .ready {
            Task {
                NotificationCenter.default.post(name: .selectItem, object: SidebarItem.library.raw)
                await engine.loadLibrary()
                try? await Task.sleep(for: .seconds(1))
                let hit = engine.library.first { $0.name == screen } ?? (screen == "preview" ? engine.library.first : nil)
                if let hit { engine.libraryFocus = hit.id }
            }
        }
        // PIOPIO_DEMO_APP=<path>: that app open, as opening it from the Library does (docs/spec/35 §14).
        if let path = env["PIOPIO_DEMO_APP"], engine.status == .ready {
            Task {
                try? await Task.sleep(for: .seconds(1))
                NotificationCenter.default.post(name: .viewFile, object: URL(fileURLWithPath: path))
                // PIOPIO_DEMO_APP_ASK=<text>: that message in the app's conversation (docs/spec/35 §15).
                if let ask = env["PIOPIO_DEMO_APP_ASK"], let ref = try? await engine.appConversation(path) {
                    let thread = engine.thread(ref)
                    await thread.open()
                    _ = await thread.send(ask)
                }
            }
        }
        // PIOPIO_DEMO_AGENT=<template>: a new agent "Coach"; PIOPIO_DEMO_AGENT_MESSAGES: messages to it ("||");
        // PIOPIO_DEMO_AGENT_CONTACT=<name>: add that contact and write as them once; PIOPIO_DEMO_AGENT_TAB: the tab to show.
        if let template = env["PIOPIO_DEMO_AGENT"], engine.status == .ready {
            Task {
                if let tab = env["PIOPIO_DEMO_AGENT_TAB"] { UserDefaults.standard.set(tab, forKey: "agentTab") }
                guard let ref = try? await engine.createAgent(name: "Coach", template: template.isEmpty ? nil : template, avatar: "") else { return }
                // PIOPIO_DEMO_AGENT_BROWSER=1: Coach uses Piopio's browser (its Watch button shows).
                if env["PIOPIO_DEMO_AGENT_BROWSER"] == "1", let got = await engine.agentDefinition(ref), var def = AgentDef(got.definition) {
                    def.tools.browser = .init(use: "asks", sites: nil, profile: nil)
                    _ = try? await engine.saveAgent(ref, definition: def.json, instructions: got.instructions, message: "Use the browser")
                    try? await engine.refreshCatalog()
                }
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
        // PIOPIO_DEMO_NEW_PROJECT=<name>: New project (a folder in ~/Piopio with AGENTS.md and NOTES.md, docs/spec/18 CF4),
        // with PIOPIO_DEMO_NEW_PROJECT_INSTRUCTIONS; then its new conversation page.
        if let name = env["PIOPIO_DEMO_NEW_PROJECT"], engine.status == .ready {
            Task {
                var found = engine.projects.first { $0.name == name }
                if found == nil { found = try? await engine.createProject(name: name, instructions: env["PIOPIO_DEMO_NEW_PROJECT_INSTRUCTIONS"]) }
                guard let project = found else { return }
                NotificationCenter.default.post(name: .newBuildSession, object: project.id)
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
        // PIOPIO_DEMO_PARALLEL=<folder>: the folder as a project with parallel work on (docs/spec/26), PIOPIO_DEMO_PARALLEL_TEST
        // as its checks; then PIOPIO_DEMO_PARALLEL_TAB: "board", "settings", or a new conversation there that gets
        // PIOPIO_DEMO_PARALLEL_GOAL.
        if let folder = env["PIOPIO_DEMO_PARALLEL"], engine.status == .ready {
            Task {
                guard let project = await engine.addProject(URL(fileURLWithPath: folder)) else { return }
                _ = try? await engine.configureWork(ConfigureWorkParams(project: project.id, parallel: true, testCommand: env["PIOPIO_DEMO_PARALLEL_TEST"]))
                switch env["PIOPIO_DEMO_PARALLEL_TAB"] {
                case "board": NotificationCenter.default.post(name: .selectItem, object: SidebarItem.board(project.id).raw)
                case "settings": NotificationCenter.default.post(name: .projectSettings, object: project.id)
                default:
                    guard let ref = await engine.createBuildSession(in: project) else { return }
                    NotificationCenter.default.post(name: .selectItem, object: SidebarItem.session(ref.id).raw)
                    if let goal = env["PIOPIO_DEMO_PARALLEL_GOAL"] { _ = await engine.thread(ref).send(goal) }
                }
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
                // PIOPIO_DEMO_FULL_AUTO=1: no approvals in this session (captures of what runs).
                if env["PIOPIO_DEMO_FULL_AUTO"] == "1" { await session.setApprovalMode(.fullAuto) }
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
                // PIOPIO_DEMO_CURSOR_PROBE="x,y;x,y" (window points from the top left): after 6 s, the cursor the
                // transcript shows at each point, one line per point, to PIOPIO_DEMO_CURSOR_OUT.
                if let probe = env["PIOPIO_DEMO_CURSOR_PROBE"], let out = env["PIOPIO_DEMO_CURSOR_OUT"] {
                    try? await Task.sleep(for: .seconds(6))
                    let height = NSApp.windows.first { $0.isVisible && $0.contentView != nil }?.contentView?.bounds.height ?? 0
                    var lines: [String] = []
                    for pair in probe.split(separator: ";") {
                        let xy = pair.split(separator: ",").compactMap { Double($0) }
                        let point = NSPoint(x: xy[0], y: height - xy[1])
                        _ = session.document.debugCursor(at: point) // reveals hover buttons
                        try? await Task.sleep(for: .milliseconds(600))
                        lines.append("\(pair) \(session.document.debugCursor(at: point))")
                    }
                    try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                }
                // PIOPIO_DEMO_PLAN_EDIT=1: open the plan editor; =approve: approve an edited version (drops the last step).
                if let mode = env["PIOPIO_DEMO_PLAN_EDIT"] {
                    for _ in 0..<50 where !session.prompts.contains(where: { $0.kind == .plan }) { try? await Task.sleep(for: .milliseconds(200)) }
                    if let plan = session.prompts.first(where: { $0.kind == .plan }) {
                        if mode == "approve" { await session.respond(plan, PromptResponse(decision: .allow, summary: plan.title, steps: Array((plan.steps ?? []).dropLast().reversed()))) }
                        else { session.editingPlan = plan }
                    }
                }
                // PIOPIO_DEMO_ANSWER=<text>: answer the first question the agent asks with it.
                if let reply = env["PIOPIO_DEMO_ANSWER"] {
                    for _ in 0..<50 where session.prompts.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                    if let question = session.prompts.first { await session.respond(question, PromptResponse(choice: reply)) }
                }
                // PIOPIO_DEMO_APPROVE_PLAN=1: approve the first plan it proposes (plan mode captures of what follows).
                if env["PIOPIO_DEMO_APPROVE_PLAN"] == "1" {
                    for _ in 0..<50 where !session.prompts.contains(where: { $0.kind == .plan }) { try? await Task.sleep(for: .milliseconds(200)) }
                    if let plan = session.prompts.first(where: { $0.kind == .plan }) { await session.respond(plan, PromptResponse(decision: .allow)) }
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
                // PIOPIO_DEMO_RESPOND=allow|always|deny: answer the approvals the session asks for (up to 5).
                if let decision = env["PIOPIO_DEMO_RESPOND"].flatMap(PromptResponse.Decision.init(rawValue:)) {
                    var answered = 0
                    for _ in 0..<150 where answered < 5 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if let first = session.prompts.first {
                            await session.respond(first, PromptResponse(decision: decision))
                            answered += 1
                        }
                    }
                }
                // PIOPIO_DEMO_OPEN_STEPS=1: open the activity lines once the turn is done.
                if env["PIOPIO_DEMO_OPEN_STEPS"] == "1" {
                    await waitIdle(session)
                    try? await Task.sleep(for: .milliseconds(500))
                    session.document.debugOpenActivity()
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

    /// Posts mouse events through the app's queue, as the real mouse would, so tracking areas and event monitors see them.
    private static func hoverProbe(_ probe: String) async -> [String] {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }),
              let content = window.contentView else { return ["no window"] }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let height = content.bounds.height
        func post(_ type: NSEvent.EventType, _ point: NSPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        var lines: [String] = []
        var last: NSPoint?
        for raw in probe.split(separator: ";") {
            let click = raw.hasPrefix("c:")
            let xy = raw.dropFirst(click ? 2 : 0).split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { continue }
            let point = NSPoint(x: xy[0], y: height - xy[1])
            // A few steps on the way, as a real move would send.
            let from = last ?? point
            for i in 1...6 {
                let t = CGFloat(i) / 6
                post(.mouseMoved, NSPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t))
                try? await Task.sleep(for: .milliseconds(30))
            }
            last = point
            if click {
                post(.leftMouseDown, point)
                post(.leftMouseUp, point)
            }
            // The state a text field leaves behind: the I-beam, then one more move.
            NSCursor.iBeam.set()
            post(.mouseMoved, point)
            try? await Task.sleep(for: .milliseconds(400))
            let cursor = NSCursor.current == .arrow ? "arrow" : NSCursor.current == .iBeam ? "ibeam" : NSCursor.current == .pointingHand ? "hand" : "other"
            var chain: [String] = []
            var view = content.superview?.hitTest(content.superview!.convert(point, from: nil)) ?? content.hitTest(point)
            while let v = view, chain.count < 4 { chain.append(String(describing: type(of: v))); view = v.superview }
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            lines.append("\(raw) \(cursor) key=\(window.isKeyWindow) text=\(CursorKeeper.isText(content.superview?.hitTest(point) ?? content)) hit=\(chain.joined(separator: "<")) fr=\(responder)")
        }
        return lines
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
        // A popover opened from another (an agent's models at the side of the picker).
        case "popover-last": NSApp.windows.last { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
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
