import PiopioKit
import PiopioTranscript
import SwiftUI

/// First run (docs/spec/15-onboarding-and-areas §3, after docs/design v2 12b): the chick asks what Piopio is for
/// you, connects a model, sets up each area you picked, and offers first steps for those areas only. Fills the
/// window; every step can be skipped, and Settings › General › Run setup again brings it back.
struct WelcomeView: View {
    let engine: EngineController
    /// Where to go after it (nil: stay where you were).
    let done: (SidebarItem?) -> Void

    enum Step: Int, CaseIterable {
        case areas, model, setup, ready
        var label: String {
            switch self {
            case .areas: "For you"
            case .model: "Model"
            case .setup: "Set up"
            case .ready: "Ready"
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .areas
    @State private var forward = true
    /// All three ticked at first (§7); a rerun starts from what's on.
    @State private var chosen = Areas.shared.set
    @State private var setup = WelcomeSetup()
    @State private var working = false
    @State private var wasConnected = false

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 34)
            ScrollView {
                page
                    .id(step)
                    .transition(.asymmetric(insertion: .offset(x: forward ? 28 : -28).combined(with: .opacity), removal: .opacity))
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 44)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color.dsWin)
        .onAppear {
            wasConnected = connected
            // PIOPIO_DEMO_WELCOME_STEP=model|setup|ready opens a later step (captures).
            if let raw = ProcessInfo.processInfo.environment["PIOPIO_DEMO_WELCOME_STEP"], let s = Step.allCases.first(where: { "\($0)" == raw }) { step = s }
        }
        .onChange(of: connected) { _, now in
            // Connecting moves on by itself, once the check mark has been seen.
            guard now, !wasConnected, step == .model else { return }
            wasConnected = true
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                if step == .model { go(.setup) }
            }
        }
    }

    private var connected: Bool { engine.faux || engine.hasKey || engine.providers.contains(where: \.isConnected) }

    // MARK: Chrome

    /// Four short bars with the step names under them; the current one is accent, done ones are accent too.
    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                VStack(spacing: 6) {
                    Capsule().fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.dsChip).frame(width: 64, height: 4)
                    Text(s.label).font(.system(size: 11, weight: s == step ? .semibold : .regular)).foregroundStyle(s == step ? Color.dsFg : Color.dsFg3)
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of 4, \(step.label)")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack(spacing: 10) {
                if step != .ready {
                    Button("Skip setup") { done(nil) }.buttonStyle(.plain).foregroundStyle(Color.dsFg2)
                    Text("· you can change all of this in Settings").foregroundStyle(Color.dsFg3)
                }
                Spacer()
                if step != .areas, step != .ready {
                    Button("Back") { go(Step(rawValue: step.rawValue - 1)!) }.buttonStyle(PillStyle())
                }
                Button(action: next) {
                    HStack(spacing: 6) {
                        if working { ProgressView().controlSize(.mini) }
                        Text(nextTitle)
                    }
                }
                .buttonStyle(PillStyle(kind: step == .model && !connected ? .secondary : .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 24)
            .frame(height: 60)
        }
    }

    private var nextTitle: String {
        switch step {
        case .areas: "Continue"
        case .model: connected ? "Continue" : "Set up later"
        case .setup: working ? "Setting up…" : "Continue"
        case .ready: "Go to Home"
        }
    }

    private func go(_ s: Step) {
        forward = s.rawValue > step.rawValue
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { step = s }
    }

    private func next() {
        switch step {
        case .areas:
            Areas.shared.replace(chosen)
            go(.model)
        case .model: go(.setup)
        case .setup:
            working = true
            Task {
                await setup.apply(engine: engine, areas: chosen)
                working = false
                go(.ready)
            }
        case .ready: done(.home)
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .areas: areasPage
        case .model: WelcomeModelStep(engine: engine, areas: chosen, connected: connected)
        case .setup: WelcomeSetupStep(engine: engine, areas: chosen, setup: setup)
        case .ready: WelcomeReadyStep(engine: engine, areas: chosen, setup: setup, connected: connected, open: done)
        }
    }

    // MARK: Step 1 · What's Piopio for you?

    private var areasPage: some View {
        VStack(alignment: .leading, spacing: 26) {
            ChickSays(title: "Pío pío! I'm Piopio.", large: true) {
                Text("I can work with you in your code, talk through anything, and run small agents that keep going while you're away. Everything stays on this Mac or in your own accounts.\n\nWhat do you want me for? Keep what you'll use.")
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(Area.allCases) { area in
                    AreaChoiceCard(area: area, on: chosen.contains(area), locked: chosen.contains(area) && !chosen.canTurnOff(area)) {
                        withAnimation(.easeOut(duration: 0.15)) { chosen.set(area, on: !chosen.contains(area)) }
                    }
                }
            }
            .padding(.leading, chickIndent)
            Text("You can turn areas on and off any time in Settings › General. Hiding one deletes nothing.")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                .padding(.leading, chickIndent)
        }
    }
}

// MARK: - Pieces

/// Where the chick's text starts: content under a message lines up with it.
let chickIndent: CGFloat = 64

/// One message from the chick: its avatar on the left, a title and text beside it.
struct ChickSays<Content: View>: View {
    let title: String
    var large = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Chick(size: 48, ring: 4)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: large ? 26 : 22, weight: .bold)).tracking(large ? -0.5 : -0.3)
                content
                    .font(.system(size: 15)).lineSpacing(15 * 0.55 - 4).foregroundStyle(Color.dsFg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, large ? 6 : 10)
        }
    }
}

/// A tickable area: its tile, name, what it's for and what it holds; ticked cards carry the decision halo.
private struct AreaChoiceCard: View {
    let area: Area
    let on: Bool
    let locked: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var holds: [String] {
        switch area {
        case .build: ["Projects", "Git", "Terminal"]
        case .chat: ["Chats", "Notebooks", "Memory"]
        case .agents: ["Schedules", "Reminders", "Inbox"]
        }
    }

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    AreaTile(area: area, size: 40).saturation(on ? 1 : 0.15).opacity(on ? 1 : 0.7)
                    Spacer()
                    ZStack {
                        Circle().strokeBorder(on ? Color.clear : Color.dsFg3.opacity(0.45), lineWidth: 1.5)
                        if on {
                            Circle().fill(Color.accentColor)
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 22, height: 22)
                }
                Text(area.title).font(.system(size: 17, weight: .bold)).foregroundStyle(on ? Color.dsFg : Color.dsFg2).padding(.top, 16)
                Text(area.blurb).font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(Color.dsFg2)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
                Spacer(minLength: 14)
                Text(holds.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 214, alignment: .topLeading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? Color.dsAccentLine : Color.dsLine, lineWidth: on ? 1 : 0.5))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(on ? Color.dsAccentSoft : .clear).padding(-4))
            .shadow(color: .black.opacity(hovering && !on ? 0.06 : 0), radius: 10, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(locked ? "Pick at least one" : on ? "Hide \(area.title)" : "Use \(area.title)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// What step 3 collects; applied when you continue from it.
@MainActor @Observable final class WelcomeSetup {
    var project: ProjectInfo?
    var aboutMe = ""
    var savedFacts = 0
    var template: AgentTemplate?
    var hatched: SessionSummary?
    var keepRunning = false
    var error: String?

    /// Saves About me, hatches the agent and turns on background mode, for the areas you picked.
    func apply(engine: EngineController, areas: AreaSet) async {
        error = nil
        if areas.contains(.chat) { await saveAboutMe(engine) }
        if areas.contains(.agents) {
            if let template, hatched == nil {
                do {
                    let ref = try await engine.createAgent(name: template.name, template: template.id, avatar: template.avatar)
                    hatched = engine.agents.first { $0.ref.id == ref.id }
                } catch {
                    self.error = "Couldn't hatch \(template.name): \((error as? EngineError)?.message ?? error.localizedDescription)"
                }
            }
            if keepRunning, engine.canRunInBackground, !engine.runsInBackground { await engine.setRunsInBackground(true) }
        }
    }

    /// Each sentence or line becomes a fact under "## Notes" in About me.
    private func saveAboutMe(_ engine: EngineController) async {
        let facts = Self.facts(aboutMe)
        guard !facts.isEmpty, savedFacts == 0 else { return }
        var text = (await engine.aboutMe()?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lastHeading = text.split(separator: "\n").last { $0.hasPrefix("## ") }
        if lastHeading != nil, lastHeading != "## Notes" { text += "\n\n## Notes" }
        for f in facts { text += (text.isEmpty ? "" : "\n") + "- \(f)" }
        do {
            try await engine.spaceCall("aboutMe.set", TextParams(text: text))
            savedFacts = facts.count
        } catch {
            self.error = "Couldn't save About me: \((error as? EngineError)?.message ?? error.localizedDescription)"
        }
    }

    static func facts(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline }).flatMap { line in
            line.split(separator: ". ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .-•\t")) }
        }
        .filter { !$0.isEmpty }
    }
}

// MARK: - Step 2 · A model to think with

private struct WelcomeModelStep: View {
    let engine: EngineController
    let areas: AreaSet
    let connected: Bool
    @State private var key = ""
    @State private var check: KeyCheck = .idle
    @State private var checkTask: Task<Void, Never>?
    @State private var detected: [EndpointsDetectResult.Found] = []
    @State private var adding: AddProviderRoute?

    enum KeyCheck: Equatable { case idle, checking, verified(Int?), failed(String) }

    private var chatgpt: ProviderInfo? { engine.providers.first { $0.id == "openai" } }
    private var connectedNames: [String] { engine.providers.filter(\.isConnected).map(\.name) + (engine.hasKey && !engine.providers.contains { $0.id == "openrouter" && $0.isConnected } ? ["OpenRouter"] : []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if connected {
                ChickSays(title: "I've got a model to think with.") {
                    Text("You're connected. More providers can be added any time in Settings › Models.")
                }
                connectedCard.padding(.leading, chickIndent)
            } else {
                ChickSays(title: "Now, a model to think with.") {
                    Text("Piopio uses your own accounts. Keys and sign-ins go straight into your Keychain, never anywhere else.")
                }
                VStack(alignment: .leading, spacing: 10) {
                    // Build users often pay for ChatGPT already: their plan first.
                    if areas.contains(.build), let chatgpt { chatgptRow(chatgpt, primary: true) }
                    keyCard(primary: !areas.contains(.build) || chatgpt == nil)
                    if !areas.contains(.build), let chatgpt { chatgptRow(chatgpt, primary: false) }
                    ForEach(detected.prefix(2), id: \.baseUrl) { found in localRow(found) }
                    HStack(spacing: 18) {
                        Button("Other providers…") { adding = .catalog }
                        Button("Custom endpoint…") { adding = .custom(nil) }
                    }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                    .padding(.top, 4)
                    if areas.contains(.agents) {
                        Text("Agents in the cloud (coming next) need an API key, like OpenRouter's. A ChatGPT sign-in works for agents on this Mac.")
                            .font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.leading, chickIndent)
            }
        }
        .task { detected = await engine.detectEndpoints() }
        .sheet(item: $adding) { route in AddProviderSheet(engine: engine, start: route, detected: detected, done: { adding = nil }) }
        .sheet(isPresented: Binding(get: { engine.login != nil }, set: { if !$0 { Task { await engine.cancelLogin() } } })) {
            if let login = engine.login { ProviderSignInSheet(engine: engine, login: login) }
        }
    }

    private var connectedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Color.dsFg3)
            VStack(alignment: .leading, spacing: 2) {
                Text(connectedNames.isEmpty ? "Connected" : "Connected to \(ListFormatter.localizedString(byJoining: connectedNames))").font(.system(size: 14, weight: .semibold))
                Text("\(engine.models.count) models available").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Spacer()
        }
        .padding(.horizontal, 16).frame(minHeight: 62)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsFg3.opacity(0.45), lineWidth: 1))
        .frame(maxWidth: 520)
        .transition(.scale(scale: 0.97).combined(with: .opacity))
    }

    /// OpenRouter: paste a key, checked as you paste (from 12b).
    private func keyCard(primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("OR").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Color.dsFg2)
                    .frame(width: 34, height: 34)
                    .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("OpenRouter").font(.system(size: 14, weight: .semibold))
                        if primary { Text("Recommended").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor) }
                    }
                    Text("One key, hundreds of models from every lab").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                switch check {
                case .idle: EmptyView()
                case .checking: ProgressView().controlSize(.mini)
                case .verified(let n): Text(n.map { "✓ Verified · \($0) models" } ?? "✓ Verified").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg3)
                case .failed(let m): Text(m).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                SecureField("sk-or-v1-…", text: $key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.dsWin, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.dsLine, lineWidth: 0.5))
                    .onSubmit(save)
                    .onChange(of: key) { _, value in verify(value) }
                Button("Use this key", action: save)
                    .buttonStyle(PillStyle(kind: .primary, compact: true))
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || check == .checking)
            }
            Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!).font(.system(size: 12))
        }
        .padding(14)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(primary ? Color.dsAccentLine : Color.dsLine, lineWidth: primary ? 1 : 0.5))
        .background(primary ? RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.dsAccentSoft).padding(-4) : nil)
    }

    private func chatgptRow(_ provider: ProviderInfo, primary: Bool) -> some View {
        optionRow(primary: primary, yolk: false) {
            ProviderTile(provider: provider, size: 34)
        } text: {
            HStack(spacing: 6) {
                Text("ChatGPT subscription").font(.system(size: 14, weight: .semibold))
                if primary { Text("You may already pay for it").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor) }
            }
            Text("Sign in; usage counts against your Plus or Pro plan").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        } action: {
            Button("Sign in") { Task { await engine.connect(provider, method: .oauth) } }
                .buttonStyle(PillStyle(kind: primary ? .primary : .secondary, compact: true))
        }
    }

    private func localRow(_ found: EndpointsDetectResult.Found) -> some View {
        optionRow(primary: false, yolk: true) {
            EndpointTile(name: found.name, size: 34)
        } text: {
            HStack(spacing: 6) {
                Text(found.name).font(.system(size: 14, weight: .semibold))
                Text("Found on this Mac").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            Text("\(found.models) model\(found.models == 1 ? "" : "s") · free, nothing leaves your Mac").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        } action: {
            Button("Add") { Task { try? await engine.saveEndpoint(EndpointSaveParams(id: nil, name: found.name, baseUrl: found.baseUrl, key: nil)) } }
                .buttonStyle(PillStyle(kind: .strong, compact: true))
        }
    }

    private func optionRow<Tile: View, Lines: View, Action: View>(primary: Bool, yolk: Bool, @ViewBuilder tile: () -> Tile, @ViewBuilder text: () -> Lines, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            tile()
            VStack(alignment: .leading, spacing: 2) { text() }
            Spacer()
            action()
        }
        .padding(.horizontal, 14).frame(minHeight: 62)
        .background(yolk ? Color.dsYolkSoft : Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(primary ? Color.dsAccentLine : yolk ? .clear : Color.dsLine, lineWidth: primary ? 1 : 0.5))
        .background(primary ? RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.dsAccentSoft).padding(-4) : nil)
        .padding(.bottom, primary ? 4 : 0)
    }

    private func verify(_ value: String) {
        checkTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else {
            check = .idle
            return
        }
        check = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let result = await engine.verifyKey("openrouter", key: trimmed)
            guard !Task.isCancelled else { return }
            check = result?.ok == true ? .verified(result?.models) : .failed(result?.message ?? "Couldn't check the key.")
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await engine.saveKey("openrouter", key: trimmed)
            } catch {
                check = .failed((error as? EngineError)?.message ?? "Couldn't save the key.")
            }
        }
    }
}

// MARK: - Step 3 · Set up what you chose

private struct WelcomeSetupStep: View {
    let engine: EngineController
    let areas: AreaSet
    @Bindable var setup: WelcomeSetup
    @State private var repos: [BuildFirstRun.Repo] = []
    @State private var templates: [AgentTemplate] = []
    @State private var targeted = false
    @State private var shortcutTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ChickSays(title: "Let's set up what you picked.") {
                Text("A minute each, and all of it optional.")
            }
            VStack(alignment: .leading, spacing: 14) {
                if areas.contains(.build) { card(.build, "A project to work on", status: setup.project.map { _ in "Added" }) { buildContent } }
                if areas.contains(.chat) { card(.chat, "A little about you", status: nil) { chatContent } }
                if areas.contains(.agents) { card(.agents, "Your first agent", status: setup.hatched.map { _ in "Hatched" }) { agentsContent } }
                if let error = setup.error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            }
            .padding(.leading, chickIndent)
        }
        .task {
            if areas.contains(.build) { repos = await Task.detached { BuildFirstRun.scan().repos }.value }
            if areas.contains(.agents) { templates = await engine.agentTemplates() }
        }
    }

    private func card<Content: View>(_ area: Area, _ title: String, status: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AreaTile(area: area, size: 26)
                Text(area.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg3)
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let status {
                    Label(status, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg3)
                } else {
                    Text("Optional").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }

    // Build: a folder, by drop, Open Folder… or one of the repos found in the usual places.

    @ViewBuilder private var buildContent: some View {
        if let project = setup.project {
            HStack(spacing: 10) {
                InitialTile(name: project.name, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.system(size: 13, weight: .semibold))
                    Text(project.branch.map { "Git repository · on \($0)" } ?? "Not a git repository; checkpoints still work").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                Button("Choose another…") { choose() }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
            }
        } else {
            HStack(spacing: 12) {
                Text("Drop a folder here, or").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                Button("Open Folder…") { choose() }.buttonStyle(PillStyle(kind: .primary, compact: true))
            }
            .frame(maxWidth: .infinity).frame(height: 64)
            .background(targeted ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.dsAccentLine : Color.dsLine, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await add(url) }
                }
                return true
            }
            if !repos.isEmpty {
                HStack(spacing: 8) {
                    Text("Found:").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    ForEach(repos.prefix(3), id: \.self) { repo in
                        Button { Task { await add(repo.url) } } label: {
                            HStack(spacing: 5) {
                                InitialTile(name: repo.url.lastPathComponent, size: 14)
                                Text(repo.url.lastPathComponent)
                                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                            }
                        }
                        .buttonStyle(ChipStyle())
                    }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await add(url) }
    }

    private func add(_ url: URL) async {
        if let project = await engine.addProject(url, lens: .build) { withAnimation(.easeOut(duration: 0.2)) { setup.project = project } }
    }

    // Chat: About me, and the Quick Chat shortcut.

    @ViewBuilder private var chatContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("e.g. I live in Bilbao. I work as a developer. I like short answers.", text: $setup.aboutMe, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(3...5)
                .padding(10)
                .background(Color.dsWin, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.dsLine, lineWidth: 0.5))
                .disabled(setup.savedFacts > 0)
            Text(setup.savedFacts > 0 ? "Saved \(setup.savedFacts) fact\(setup.savedFacts == 1 ? "" : "s") to About me." : "Saved to About me, which chats read. Edit it later in Settings › Chat.")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        }
        Rectangle().fill(Color.dsLine).frame(height: 0.5)
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(Color.dsFg3).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Quick Chat").font(.system(size: 13, weight: .medium))
                Text("Ask from any app without opening Piopio").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Spacer()
            Picker("", selection: Binding(get: { QuickChatShortcut.current }, set: { value in
                UserDefaults.standard.set(value.rawValue, forKey: "quickChatShortcut")
                QuickChatController.shared?.applyShortcut()
                shortcutTick += 1
            })) {
                ForEach(QuickChatShortcut.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().fixedSize()
            .id(shortcutTick)
        }
    }

    // Agents: one template (or none), and whether they run with the app closed.

    @ViewBuilder private var agentsContent: some View {
        if let hatched = setup.hatched {
            HStack(spacing: 10) {
                AgentAvatar(summary: hatched, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hatched.title).font(.system(size: 13, weight: .semibold))
                    Text(MainSidebar.agentLine(hatched)).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                ForEach(featured) { t in templateCard(t) }
            }
            Text(setup.template == nil ? "Pick one to hatch it, or none for now." : "\(setup.template!.name) hatches when you continue. Click it again to unpick it.")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
        }
        Rectangle().fill(Color.dsLine).frame(height: 0.5)
        HStack(spacing: 10) {
            Image(systemName: "moon.stars.fill").font(.system(size: 12)).foregroundStyle(Color.dsFg3).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep running when Piopio quits").font(.system(size: 13, weight: .medium))
                Text(engine.canRunInBackground ? "Agents keep their schedules with the window closed" : "Available in release builds, which carry their own engine")
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { setup.keepRunning || engine.runsInBackground }, set: { setup.keepRunning = $0 }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(!engine.canRunInBackground || engine.runsInBackground)
        }
    }

    /// A briefing, a coach and a watcher first (as in Agents' empty state).
    private var featured: [AgentTemplate] {
        let order = ["daily-briefing", "habit-coach", "research-watcher"]
        return Array(templates.sorted { (order.firstIndex(of: $0.id) ?? 9) < (order.firstIndex(of: $1.id) ?? 9) }.prefix(3))
    }

    private func templateCard(_ t: AgentTemplate) -> some View {
        let picked = setup.template?.id == t.id
        return Button { withAnimation(.easeOut(duration: 0.15)) { setup.template = picked ? nil : t } } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top) {
                    Text(t.avatar).font(.system(size: 24))
                    Spacer()
                    if picked { Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Color.accentColor) }
                }
                Text(t.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
                Text(t.description).font(.system(size: 11.5)).foregroundStyle(Color.dsFg2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .background(picked ? Color.dsAccentSoft : Color.dsWin, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(picked ? Color.dsAccentLine : Color.dsLine, lineWidth: picked ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 4 · Ready

private struct WelcomeReadyStep: View {
    let engine: EngineController
    let areas: AreaSet
    let setup: WelcomeSetup
    let connected: Bool
    let open: (SidebarItem?) -> Void

    private var shown: String { ListFormatter.localizedString(byJoining: areas.ordered.map(\.title)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ChickSays(title: "All set.", large: true) {
                Text("Your sidebar shows \(shown). Change it any time in Settings › General.")
            }
            VStack(alignment: .leading, spacing: 18) {
                if !done.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(done, id: \.self) { line in
                            Label { Text(line).font(.system(size: 13)).foregroundStyle(Color.dsFg) } icon: {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.dsFg3)
                            }
                        }
                        if !connected {
                            Label { Text("No model yet: add one in Settings › Models").font(.system(size: 13)).foregroundStyle(Color.dsFg2) } icon: {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.dsAmber)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where to start?").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg2)
                    ForEach(starts, id: \.title) { s in choice(s) }
                }
                .frame(maxWidth: 520)
            }
            .padding(.leading, chickIndent)
        }
    }

    private var done: [String] {
        var out: [String] = []
        if connected {
            let names = engine.providers.filter(\.isConnected).map(\.name)
            out.append(names.isEmpty ? "A model is connected" : "\(ListFormatter.localizedString(byJoining: names)) connected")
        }
        if let p = setup.project { out.append("\(p.name) added as a project") }
        if setup.savedFacts > 0 { out.append("\(setup.savedFacts) fact\(setup.savedFacts == 1 ? "" : "s") about you saved") }
        if let a = setup.hatched {
            let next = a.agent?.status?.nextRun.map { " · first run \(MainSidebar.when($0))" } ?? ""
            out.append("\(a.title) hatched\(next)")
        }
        if engine.runsInBackground, areas.contains(.agents) { out.append("Agents keep running when Piopio quits") }
        return out
    }

    struct Start { let icon: String; let area: Area; let title: String; let detail: String; let go: () -> Void }

    private var starts: [Start] {
        var out: [Start] = []
        if areas.contains(.build) {
            if let p = setup.project {
                out.append(Start(icon: "play.fill", area: .build, title: "Start a session in \(p.name)", detail: "Build · ask for a change, a fix or a review") {
                    Task { if let ref = await engine.createBuildSession(in: p) { open(.session(ref.id)) } }
                })
            } else {
                out.append(Start(icon: "folder", area: .build, title: "Look at a project", detail: "Build · open a folder and start a session") { open(.index(.projects)) })
            }
        }
        if areas.contains(.chat) {
            out.append(Start(icon: "bubble.left", area: .chat, title: "Just ask something", detail: "Chat · a question, a draft, an idea") { open(.home) })
        }
        if areas.contains(.agents) {
            if let a = setup.hatched {
                out.append(Start(icon: "bird", area: .agents, title: "Meet \(a.title)", detail: "Agents · say hi, or change what it does") { open(.agent(a.ref.id)) })
            } else {
                out.append(Start(icon: "sun.max", area: .agents, title: "Hatch an agent", detail: "Agents · a briefing, a coach or one of your own") { open(.index(.agents)) })
            }
        }
        return out
    }

    private func choice(_ s: Start) -> some View {
        Button(action: s.go) {
            HStack(spacing: 12) {
                Image(systemName: s.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(s.area.tint)
                    .frame(width: 32, height: 32)
                    .background(s.area.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg)
                    Text(s.detail).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 12).frame(height: 56)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small rounded badge ("Soon", "CLOUD").
struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dsFg2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.badge))
    }
}
