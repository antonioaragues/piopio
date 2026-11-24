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
        .task { await load() }
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

/// A hook as a sentence you fill in (design A): when, which tools or files, and what runs or what stops it.
struct HookSheet: View {
    let engine: EngineController
    let project: String?
    let info: HookInfo?
    let done: () -> Void

    enum Target: String, CaseIterable { case files = "edits or writes", command = "runs a command", any = "uses any tool" }
    enum Action: String, CaseIterable { case stop = "stop it", run = "run a command" }

    @State private var when: HookSpec.When = .after
    @State private var target: Target = .files
    @State private var files = ""
    @State private var command = ""
    @State private var action: Action = .run
    @State private var run = ""
    @State private var stop = ""
    @State private var tried: String?
    @State private var trying = false
    @State private var error: String?
    @State private var confirmDelete = false

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

    private var valid: Bool {
        if when == .before && action == .stop { return !stop.trimmingCharacters(in: .whitespaces).isEmpty }
        return !run.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(info == nil ? "New hook" : "Hook").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                Picker("", selection: $when) {
                    Text("Before Piopio").tag(HookSpec.When.before)
                    Text("After Piopio").tag(HookSpec.When.after)
                    Text("When Piopio finishes an answer").tag(HookSpec.When.end)
                }
                .labelsHidden().fixedSize()
                if when != .end {
                    Picker("", selection: $target) { ForEach(Target.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize()
                }
            }
            if when == .end || target == .files {
                field(when == .end ? "Only when it changed files like" : "Files like", hint: when == .end ? "Leave empty for any change; packages/** for a folder" : "*.swift · src/**/*.ts · leave empty for any file") {
                    TextField("*.swift", text: $files).textFieldStyle(.roundedBorder)
                }
            }
            if when != .end && target == .command {
                field("Commands like", hint: "git push --force* · leave empty for every command") {
                    TextField("git push --force*", text: $command).textFieldStyle(.roundedBorder)
                }
            }
            if when == .before {
                Picker("Then", selection: $action) { ForEach(Action.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).fixedSize()
            }
            if when == .before && action == .stop {
                field("Stop it with", hint: "Piopio sees this and asks you or tries another way") {
                    TextField("Ask me before force-pushing.", text: $stop).textFieldStyle(.roundedBorder)
                }
            } else {
                field("Run", hint: when == .before ? "$FILE and $COMMAND are set; exiting 2 stops the tool, with its output" : when == .after ? "$FILE is the file; if it fails, Piopio is told" : "If it fails, Piopio gets its output and keeps going, 3 times at most") {
                    TextField(when == .end ? "pnpm test:unit" : "swiftformat \"$FILE\"", text: $run).textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                }
            }
            // The sentence it will read as, and Try it.
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.sentence(spec)).font(.system(size: 13)).foregroundStyle(Color.dsFg)
                if let tried { Text(tried).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg2).lineLimit(4) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsChip.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed) }
            HStack(spacing: 10) {
                if info != nil { Button("Delete…", role: .destructive) { confirmDelete = true } }
                Button(trying ? "Trying…" : "Try it", action: tryIt).disabled(trying || !valid || (when == .before && action == .stop))
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(info == nil ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction).buttonStyle(PillStyle(kind: .strong, compact: true)).disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: fill)
        .confirmationDialog("Delete this hook?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive, action: delete)
        } message: { Text("Its file goes to the Trash; Piopio and the pi CLI stop running it.") }
    }

    private func field(_ title: String, hint: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
            content()
            Text(hint).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
        }
    }

    /// As the engine words it (user-hooks.ts `hookSentence`).
    static func sentence(_ h: HookSpec) -> String {
        let tools = h.tools ?? [.any]
        let verbs = tools.contains(.any) ? "uses any tool" : tools.contains(.bash) ? "runs a command" : "edits or writes"
        let what = verbs + (h.files != nil && !tools.contains(.bash) ? " a \(h.files!) file" : "") + (h.command.map { " matching \($0)" } ?? "")
        switch h.when {
        case .end: return "When Piopio finishes an answer\(h.files.map { " that changed \($0) files" } ?? ""), run \(h.run ?? "…"); if it fails, Piopio keeps going (3 times at most)"
        case .after: return "After Piopio \(what), run \(h.run ?? "…")"
        case .before: return h.run != nil ? "Before Piopio \(what), run \(h.run!); if it exits 2, stop it" : "Before Piopio \(what), stop it: \"\(h.stop ?? "…")\""
        }
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
                let r = try await engine.client!.call("hooks.try", HookTryParams(spec: spec, project: project), as: HookTryResult.self)
                let on = r.file.map { " on \($0)" } ?? ""
                tried = (r.code == 0 ? "✓ Ran\(on) · \(String(format: "%.1f", r.ms / 1000)) s" : "✗ Exited \(r.code)\(on)") + (r.output.isEmpty ? "" : "\n\(r.output)")
            } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
        }
    }

    private func save() {
        Task {
            do {
                _ = try await engine.client?.call("hooks.save", HookSaveParams(path: info?.path, project: info == nil ? project : nil, spec: spec), as: HookPathResult.self)
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
