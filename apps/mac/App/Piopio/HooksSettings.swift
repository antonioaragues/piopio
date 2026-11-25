import AppKit
import PiopioKit
import SwiftUI

/// Your hooks (PAR6, docs/design/hooks): each one a pi extension file Piopio writes from a sentence. Yours in Settings ›
/// Extensions; a project's in its page under Approvals (they run once the project is trusted), with Claude Code's
/// hooks offered for import. A file changed by hand is code: it opens in your editor, never in the sentence.
struct HooksCard: View {
    let engine: EngineController
    /// A project's folder; nil for yours (every project).
    var project: String?
    @State private var hooks: [HookInfo] = []
    @State private var claude: [HooksResult.Claude] = []
    @State private var editing: HookEditTarget?
    @State private var error: String?

    private var mine: [HookInfo] { hooks.filter { $0.where == (project == nil ? "yours" : "project") } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: project == nil ? "Your hooks" : "Hooks") {
                Button("New hook") { editing = HookEditTarget(info: nil) }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
            }
            if let project, !claude.isEmpty { importBanner(project) }
            ListCard {
                if mine.isEmpty {
                    Text(project == nil ? "None yet. A hook runs a command every time, at the moment you pick: after an edit, before a command, when Piopio finishes." : "None yet. A project's hooks travel with it, in .pi/extensions.")
                        .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                        .padding(.horizontal, 14).frame(minHeight: 52, alignment: .leading)
                }
                ForEach(Array(mine.enumerated()), id: \.element.id) { i, hook in
                    row(hook)
                    if i < mine.count - 1 { RowDivider() }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed).padding(.top, 6) }
            FinePrint(project == nil
                      ? "Saved in ~/.pi/agent/extensions as small pi extensions, so the pi CLI runs them too. They run on this Mac with your permissions."
                      : "Saved in this project's .pi/extensions. They run only while the project is trusted.")
                .padding(.top, 10)
        }
        .task {
            await load()
            // PIOPIO_DEMO_HOOK_SHEET=edit|new (captures): the first hook's sentence, or a new one.
            if project == nil, let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_HOOK_SHEET"] {
                editing = HookEditTarget(info: demo == "edit" ? mine.first { $0.spec?.when == .after } : nil)
            }
        }
        .sheet(item: $editing) { target in
            HookSheet(engine: engine, project: project, info: target.info) { editing = nil; Task { await load() } }
        }
    }

    private func row(_ hook: HookInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: hook.spec == nil ? "curlybraces" : symbol(hook.spec!.when)).font(.system(size: 13)).foregroundStyle(Color.dsFg2).frame(width: 22)
            Button {
                if hook.spec == nil { NSWorkspace.shared.open(URL(fileURLWithPath: hook.path)) } else { editing = HookEditTarget(info: hook) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hook.sentence).font(.system(size: 13)).foregroundStyle(hook.on ? Color.dsFg : Color.dsFg3).lineLimit(2).multilineTextAlignment(.leading)
                    Text(hook.spec == nil ? "\(hook.name) · changed by hand, opens as code" : hook.name).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(get: { hook.on }, set: { on in toggle(hook, on) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(hook.on ? "On: pi loads it" : "Off: the file is set aside")
        }
        .padding(.horizontal, 14).frame(minHeight: 52)
    }

    private func importBanner(_ project: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This project has Claude Code hooks").font(.system(size: 13, weight: .semibold))
            Text(".claude/settings.json has \(claude.count). Piopio can write them as pi extensions here, so Piopio and the pi CLI run them too.")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg2)
            ForEach(claude, id: \.self) { c in Text(c.sentence).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg2).lineLimit(1) }
            HStack {
                Spacer()
                Button("Import \(claude.count) hook\(claude.count == 1 ? "" : "s")") { importClaude(project) }.buttonStyle(PillStyle(kind: .strong, compact: true))
            }
        }
        .padding(12)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.dsLine, lineWidth: 0.5))
        .padding(.bottom, 10)
    }

    private func symbol(_ when: HookSpec.When) -> String {
        switch when { case .before: "hand.raised"; case .after: "arrow.turn.down.right"; case .end: "checkmark.circle" }
    }

    private func load() async {
        guard let got = try? await engine.client?.call("hooks.list", HooksListParams(project: project), as: HooksResult.self) else { return }
        hooks = got.hooks
        // Offered until imported: one already written the same way isn't offered again.
        claude = got.claude.filter { c in !got.hooks.contains { $0.spec == c.spec } }
    }

    private func toggle(_ hook: HookInfo, _ on: Bool) {
        Task {
            do { _ = try await engine.client?.call("hooks.toggle", HookToggleParams(path: hook.path, on: on), as: HookPathResult.self) } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
            await load()
        }
    }

    private func importClaude(_ project: String) {
        Task {
            do { _ = try await engine.client?.call("hooks.importClaude", HookImportParams(project: project), as: HookImportResult.self) } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
            await load()
        }
    }
}

struct HookEditTarget: Identifiable {
    let info: HookInfo?
    var id: String { info?.path ?? "new" }
}

/// A hook as a sentence you fill in (design A, docs/design/hooks): the sentence is the editor. Its moments are chips that
/// open their choices (only the ones that make sense: "stop it" only before a tool), and what it matches and runs are
/// fields inside the sentence that grow as you type. Under it: where it's kept, Try it and its result, Show the file.
struct HookSheet: View {
    let engine: EngineController
    let info: HookInfo?
    let done: () -> Void

    enum Target: String, CaseIterable { case files = "edits or writes", command = "runs a command", any = "uses any tool" }
    enum Action: String, CaseIterable { case stop = "stop it", run = "run" }

    @State private var scope: String?
    @State private var when: HookSpec.When = .after
    @State private var target: Target = .files
    @State private var files = ""
    @State private var command = ""
    @State private var action: Action = .run
    @State private var run = ""
    @State private var stop = ""
    @State private var tried: (ok: Bool, text: String, output: String)?
    @State private var trying = false
    @State private var error: String?
    @State private var confirmDelete = false

    init(engine: EngineController, project: String?, info: HookInfo?, done: @escaping () -> Void) {
        self.engine = engine
        self.info = info
        self.done = done
        _scope = State(initialValue: project)
    }

    private var spec: HookSpec {
        let tools: [HookSpec.Tool]? = when == .end ? nil : target == .files ? [.edit, .write] : target == .command ? [.bash] : [.any]
        let f = files.trimmingCharacters(in: .whitespaces), c = command.trimmingCharacters(in: .whitespaces)
        let r = run.trimmingCharacters(in: .whitespaces), s = stop.trimmingCharacters(in: .whitespaces)
        return HookSpec(when: when, tools: tools,
                        files: (when == .end || target == .files) && !f.isEmpty ? f : nil,
                        command: when != .end && target == .command && !c.isEmpty ? c : nil,
                        run: when == .before && action == .stop ? nil : (r.isEmpty ? nil : r),
                        stop: when == .before && action == .stop && !s.isEmpty ? s : nil)
    }

    private var stops: Bool { when == .before && action == .stop }
    private var valid: Bool { !(stops ? stop : run).trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(info == nil ? "New hook" : "Hook").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                Flow(spacing: 5, lineSpacing: 9) { sentence }
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    scopeMenu
                    tryButton
                    Spacer(minLength: 8)
                    if let path = info?.path {
                        Button("Show the file") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            .buttonStyle(.plain).foregroundStyle(Color.dsFg2)
                    }
                    Button("Cancel", action: done).buttonStyle(.plain).foregroundStyle(Color.dsFg2).keyboardShortcut(.cancelAction)
                    Button(info == nil ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction).buttonStyle(PillStyle(kind: .strong, compact: true)).disabled(!valid)
                }
                .font(.system(size: 12.5))
                if let tried, !tried.output.isEmpty {
                    Text(tried.output).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg2).lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            Text(hint).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed) }
            if info != nil {
                Button("Delete…", role: .destructive) { confirmDelete = true }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.dsRed)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear(perform: fill)
        .onChange(of: spec) { _, _ in tried = nil }
        .confirmationDialog("Delete this hook?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive, action: delete)
        } message: { Text("Its file goes to the Trash; Piopio and the pi CLI stop running it.") }
    }

    // MARK: The sentence

    @ViewBuilder private var sentence: some View {
        if when == .end {
            HookChip(text: "When Piopio finishes an answer", strong: true) { whenChoices }
            word("that changed")
            HookField(text: $files, placeholder: "any", mono: true)
            word("files, run")
            HStack(spacing: 0) { HookField(text: $run, placeholder: "pnpm test:unit", mono: true); word(";") }
            word("if it fails, Piopio keeps going")
        } else {
            HookChip(text: when == .before ? "Before" : "After", strong: true) { whenChoices }
            word("Piopio")
            HookChip(text: target.rawValue) {
                ForEach(Target.allCases, id: \.self) { t in Button(t.rawValue) { target = t } }
            }
            switch target {
            case .files:
                word("a")
                HookField(text: $files, placeholder: "*.swift", mono: true)
                word("file,")
            case .command:
                word("matching")
                HStack(spacing: 0) { HookField(text: $command, placeholder: "git push --force*", mono: true); word(",") }
            case .any:
                word(",")
            }
            if when == .before {
                HookChip(text: action.rawValue) {
                    Button("stop it") { action = .stop }
                    Button("run a command (exiting 2 stops it)") { action = .run }
                }
                if stops {
                    word(":")
                    HookField(text: $stop, placeholder: "Ask me first.", mono: false)
                } else {
                    HStack(spacing: 0) { HookField(text: $run, placeholder: "./scripts/guard.sh", mono: true); word(";") }
                    word("if it exits 2, stop it")
                }
            } else {
                word("run")
                HookField(text: $run, placeholder: "swiftformat \"$FILE\"", mono: true)
            }
        }
    }

    @ViewBuilder private var whenChoices: some View {
        Button("Before (can stop it)") { when = .before }
        Button("After") { when = .after }
        Button("When Piopio finishes an answer") { when = .end }
    }

    private func word(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Color.dsFg).padding(.vertical, 3)
    }

    /// What the fields mean, for the moment chosen.
    private var hint: String {
        switch when {
        case .before: stops ? "Piopio sees the message and asks you, or tries another way." : "$FILE and $COMMAND are set, and the call comes as JSON on its input; exiting 2 stops the tool, with its output."
        case .after: "$FILE is the file. If the command fails, Piopio is told in the tool's result."
        case .end: "If it fails, Piopio gets its output and keeps going, 3 times at most. Leave the files empty for any change."
        }
    }

    // MARK: Under the sentence

    private var scopeMenu: some View {
        let name = scope.flatMap { s in engine.projects.first { $0.path == s }?.name } ?? "Every project"
        return Group {
            if info != nil {
                Text(info?.where == "project" ? name : "Every project").foregroundStyle(Color.dsFg2)
            } else {
                Menu {
                    Button("Every project") { scope = nil }
                    let folders = engine.projects.filter { $0.missing != true }
                    if !folders.isEmpty { Divider() }
                    ForEach(folders) { p in Button(p.name) { scope = p.path } }
                } label: { Text("\(name) ▾").foregroundStyle(Color.dsFg2) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Every project: ~/.pi/agent/extensions. A project: its .pi/extensions, while it's trusted.")
            }
        }
    }

    private var tryButton: some View {
        Button(action: tryIt) {
            if trying { Text("Trying…").foregroundStyle(Color.dsFg3) }
            else if let tried { Text(tried.text).foregroundStyle(tried.ok ? Color.dsGreen : Color.dsRed) }
            else { Text("Try it").foregroundStyle(Color.accentColor) }
        }
        .buttonStyle(.plain)
        .disabled(trying || !valid || stops)
        .help(stops ? "A hook that only stops has nothing to run" : "Run the command once, on a file it would match")
    }

    private func fill() {
        guard let s = info?.spec else { return }
        when = s.when
        let tools = s.tools ?? [.any]
        target = tools.contains(.bash) ? .command : tools.contains(.any) ? .any : .files
        files = s.files ?? ""; command = s.command ?? ""; run = s.run ?? ""; stop = s.stop ?? ""
        action = s.when == .before && s.run == nil ? .stop : .run
    }

    private func tryIt() {
        trying = true
        Task {
            defer { trying = false }
            do {
                let r = try await engine.client!.call("hooks.try", HookTryParams(spec: spec, project: scope), as: HookTryResult.self)
                let on = r.file.map { " on \(($0 as NSString).lastPathComponent)" } ?? ""
                tried = r.code == 0 ? (true, "✓ Tried\(on) · \(String(format: "%.1f", r.ms / 1000)) s", r.output) : (false, "✗ Exited \(r.code)\(on)", r.output)
            } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
        }
    }

    private func save() {
        Task {
            do {
                _ = try await engine.client?.call("hooks.save", HookSaveParams(path: info?.path, project: info == nil ? scope : nil, spec: spec), as: HookPathResult.self)
                done()
            } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
        }
    }

    private func delete() {
        guard let path = info?.path else { return }
        Task {
            do { try await engine.spaceCall("hooks.delete", SkillPathParams(path: path)); done() }
            catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
        }
    }
}

/// A part of the sentence that opens its choices: a grey chip, outlined while its menu is open.
private struct HookChip<Choices: View>: View {
    let text: String
    var strong = false
    @ViewBuilder let choices: () -> Choices
    @State private var hovering = false

    var body: some View {
        Menu { choices() } label: {
            Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.dsFg)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(hovering ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hovering = $0 }
    }
}

/// A field inside the sentence: a chip you type into, as wide as what's in it.
private struct HookField: View {
    @Binding var text: String
    let placeholder: String
    var mono = true
    @FocusState private var focused: Bool

    private var font: Font { mono ? .system(size: 12.5, design: .monospaced) : .system(size: 14) }

    var body: some View {
        Text(text.isEmpty ? placeholder : text).font(font).lineLimit(1).opacity(0)
            .padding(.trailing, 6)
            .frame(minWidth: 44, alignment: .leading)
            .overlay(alignment: .leading) {
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.dsFg3))
                    .textFieldStyle(.plain).font(font).focused($focused)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 1.5))
    }
}
