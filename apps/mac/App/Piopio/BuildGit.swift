import AppKit
import Observation
import PiopioKit
import PiopioTranscript
import SwiftUI

// Git in Build (docs/spec/05-build §8 G1–G3, BP5; docs/design 2a toolbar, 7a new session sheet).

/// Git state of a folder (the project, or a session's worktree), refreshed on demand.
@Observable @MainActor
final class GitModel {
    let cwd: String
    private(set) var status: GitStatus?
    private(set) var branches: [GitBranch] = []
    private(set) var busy: String?
    /// The last git error or result, shown under the header for a few seconds.
    var notice: (text: String, failed: Bool)?
    @ObservationIgnored private weak var engine: EngineController?

    init(cwd: String, engine: EngineController) {
        self.cwd = cwd
        self.engine = engine
    }

    var changedCount: Int { status?.files.count ?? 0 }

    func refresh() async {
        guard let client = engine?.client else { return }
        status = try? await client.call("git.status", CwdParams(cwd: cwd), as: GitStatus.self)
        if status?.repo == true {
            branches = (try? await client.call("git.branches", CwdParams(cwd: cwd), as: GitBranchesResult.self).branches) ?? []
        }
    }

    func checkout(_ branch: String, create: Bool = false) async {
        await run("Switching to \(branch)…", success: "On \(branch)") {
            _ = try await $0.call("git.checkout", GitCheckoutParams(cwd: self.cwd, branch: branch, create: create), as: Empty.self)
        }
    }

    func sync(_ action: GitSyncParams.Action) async {
        let names: [GitSyncParams.Action: (String, String)] = [.push: ("Pushing…", "Pushed"), .pull: ("Pulling…", "Up to date"), .fetch: ("Fetching…", "Fetched")]
        await run(names[action]!.0, success: names[action]!.1) {
            _ = try await $0.call("git.sync", GitSyncParams(cwd: self.cwd, action: action), as: GitSyncResult.self)
        }
    }

    func commit(_ message: String, paths: [String]?, amend: Bool, push: Bool) async -> Bool {
        var ok = false
        await run("Committing…", success: push ? nil : "Committed") {
            _ = try await $0.call("git.commit", GitCommitParams(cwd: self.cwd, message: message, paths: paths, amend: amend ? true : nil), as: GitCommitResult.self)
            ok = true
        }
        if ok, push { await sync(.push) }
        return ok
    }

    /// A commit message for `paths`, written by the utility model from the diff.
    func generateMessage(paths: [String]?) async throws -> String {
        guard let client = engine?.client else { return "" }
        return try await client.call("git.message", GitMessageParams(cwd: cwd, paths: paths), as: GitMessageResult.self).message
    }

    private func run(_ label: String, success: String?, _ work: @escaping (EngineClient) async throws -> Void) async {
        guard let client = engine?.client else { return }
        busy = label
        do {
            try await work(client)
            if let success { show(success, failed: false) }
        } catch {
            show(String(describing: error), failed: true)
        }
        busy = nil
        await refresh()
    }

    private func show(_ text: String, failed: Bool) {
        notice = (text, failed)
        Task {
            try? await Task.sleep(for: .seconds(failed ? 8 : 3))
            if notice?.text == text { notice = nil }
        }
    }
}

/// The branch pill (G1): branch, ahead/behind and changes; switch or create branches, sync, commit,
/// and finish a worktree (merge into its base or discard).
struct GitMenu: View {
    let git: GitModel
    let engine: EngineController
    let summary: SessionSummary
    @Binding var committing: Bool
    @State private var newBranch = false
    @State private var branchName = ""
    @State private var finishing: FinishParams.Action?

    var body: some View {
        Menu {
            if let status = git.status, status.repo {
                Button("Commit…") { committing = true }.disabled(status.files.isEmpty)
                Divider()
                Button("Push") { Task { await git.sync(.push) } }
                Button("Pull") { Task { await git.sync(.pull) } }.disabled(status.upstream == nil)
                Button("Fetch") { Task { await git.sync(.fetch) } }
                if summary.worktree == nil || summary.worktree?.finished != nil {
                    Divider()
                    Menu("Switch Branch") {
                        ForEach(git.branches) { branch in
                            Button(branch.current ? "\(branch.name)  ✓" : branch.name) { Task { await git.checkout(branch.name) } }
                                .disabled(branch.current)
                        }
                    }
                    Button("New Branch…") { branchName = ""; newBranch = true }
                }
                if let worktree = summary.worktree, worktree.finished == nil {
                    Divider()
                    Button("Merge into \(worktree.base)…") { finishing = .merge }
                    Button("Discard Worktree…") { finishing = .discard }
                }
            } else {
                Text("Not a git repository")
            }
        } label: {
            // The branch is in the subtitle; here only the icon and what's waiting to sync.
            HStack(spacing: 5) {
                Image(systemName: summary.worktree != nil ? "square.split.2x1" : "arrow.triangle.branch").font(.system(size: 13))
                if let s = git.status, s.ahead > 0 { Text("↑\(s.ahead)").font(.system(size: 11.5)) }
                if let s = git.status, s.behind > 0 { Text("↓\(s.behind)").font(.system(size: 11.5)) }
                if git.busy != nil { ProgressView().controlSize(.mini) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(PillStyle(kind: .toolbar))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(git.busy ?? helpText)
        .alert("New Branch", isPresented: $newBranch) {
            TextField("Branch name", text: $branchName)
            Button("Create") { Task { await git.checkout(branchName.trimmingCharacters(in: .whitespaces), create: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("From \(git.status?.branch ?? "the current commit"). Uncommitted changes come along.")
        }
        .alert(finishing == .merge ? "Merge into \(summary.worktree?.base ?? "")?" : "Discard this worktree?", isPresented: Binding(get: { finishing != nil }, set: { if !$0 { finishing = nil } })) {
            Button(finishing == .merge ? "Merge" : "Discard", role: finishing == .discard ? .destructive : nil) {
                if let action = finishing { Task { await finish(action) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if finishing == .merge {
                Text("Merges \(summary.worktree?.branch ?? "") into \(summary.worktree?.base ?? "") in the project, then removes the worktree and its branch. Commit the worktree's changes first.")
            } else {
                Text("Removes the worktree and the branch \(summary.worktree?.branch ?? ""), with any work that isn't merged. This can't be undone.")
            }
        }
    }

    private var helpText: String {
        guard let s = git.status, s.repo else { return "This folder isn't a git repository" }
        var parts = [s.upstream.map { "Tracking \($0)" } ?? "No upstream yet: Push creates it"]
        if s.ahead > 0 { parts.append("\(s.ahead) to push") }
        if s.behind > 0 { parts.append("\(s.behind) to pull") }
        return parts.joined(separator: " · ")
    }

    private func finish(_ action: FinishParams.Action) async {
        do {
            try await engine.finish(summary.ref, action)
        } catch {
            git.notice = (String(describing: error), true)
        }
    }
}

// MARK: Commit (G2)

struct CommitSheet: View {
    let git: GitModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var message = ""
    @State private var amend = false
    @State private var generating = false
    @State private var error: String?

    private var files: [GitFile] { git.status?.files ?? [] }
    private var paths: [String]? { selected.count == files.count ? nil : Array(selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit to \(git.status?.branch ?? "HEAD")").font(.system(size: 15, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files) { file in
                        Toggle(isOn: Binding(get: { selected.contains(file.path) }, set: { on in if on { selected.insert(file.path) } else { selected.remove(file.path) } })) {
                            HStack(spacing: 6) {
                                Text(letter(file.status)).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(color(file.status)).frame(width: 14)
                                Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .padding(10)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text("Commit message").foregroundStyle(Color.dsFg3).padding(.top, 8).padding(.leading, 9).allowsHitTesting(false)
                }
                TextEditor(text: $message)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(4)
            }
            .frame(height: 100)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.row).strokeBorder(Color.dsLine, lineWidth: 0.5))
            HStack {
                Button { Task { await generate() } } label: {
                    HStack(spacing: 5) {
                        if generating { ProgressView().controlSize(.mini) } else { Text("✨") }
                        Text("Generate")
                    }
                }
                .buttonStyle(PillStyle())
                .disabled(selected.isEmpty || generating)
                .help("Writes a message from the diff of the selected files")
                Toggle("Amend last commit", isOn: $amend).toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(git.status?.upstream == nil ? "Commit & Publish" : "Commit & Push") { Task { await commit(push: true) } }
                    .buttonStyle(PillStyle())
                    .disabled(!canCommit)
                Button("Commit \(selected.count == 1 ? "1 file" : "\(selected.count) files")") { Task { await commit(push: false) } }
                    .buttonStyle(PillStyle(kind: .strong))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            await git.refresh()
            selected = Set(files.map(\.path))
        }
    }

    private var canCommit: Bool { !selected.isEmpty && (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || amend) && git.busy == nil }

    private func generate() async {
        generating = true
        error = nil
        do { message = try await git.generateMessage(paths: paths) } catch { self.error = String(describing: error) }
        generating = false
    }

    private func commit(push: Bool) async {
        if await git.commit(message, paths: paths, amend: amend, push: push) { dismiss() } else { error = git.notice?.text }
    }

    private func letter(_ s: GitFile.Status) -> String {
        switch s {
        case .added, .untracked: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .conflicted: "U"
        }
    }

    private func color(_ s: GitFile.Status) -> Color {
        switch s {
        case .added, .untracked: .dsFg3
        case .modified, .renamed: .dsAmber
        case .deleted, .conflicted: .dsFg2
        }
    }
}

// MARK: New session (7a)

/// Prompt first; then where to work (new branch, worktree, current branch), permissions and model.
struct NewSessionSheet: View {
    let engine: EngineController
    let project: ProjectInfo
    var initialPrompt = ""
    let onStart: (ContainerRef) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var workOn: Kind = .current
    @State private var branch = ""
    @State private var branchEdited = false
    @State private var mode: ApprovalMode = .autoEdit
    @State private var model: ModelRef?
    @State private var showModels = false
    @State private var starting = false
    @State private var error: String?
    @FocusState private var focused: Bool

    enum Kind: String, CaseIterable, Identifiable {
        case branch = "New branch", worktree = "Worktree", current = "Current branch"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New session in \(project.name)").font(.system(size: 15, weight: .semibold))
                if let branch = project.branch { Text("on \(branch)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsFg3) }
            }
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("What should the agent do?").font(.system(size: 13.5)).foregroundStyle(Color.dsFg3).padding(.top, 8).padding(.leading, 9).allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .font(.system(size: 13.5))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .focused($focused)
            }
            .frame(height: 110)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsAccentLine, lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: DS.Radius.card + 4).fill(Color.dsAccentSoft).padding(-4))

            row("Work on") {
                Picker("", selection: $workOn) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .disabled(project.branch == nil)
            }
            if workOn != .current {
                row("Branch") {
                    TextField("piopio/…", text: Binding(get: { branch }, set: { branch = $0; branchEdited = true }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Text("from \(project.branch ?? "HEAD")").font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize()
                }
                if workOn == .worktree {
                    Text("A separate checkout in Piopio's data folder, so this session doesn't touch your working copy. Merge or discard it when done.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true).padding(.leading, 96)
                }
            }
            row("Permissions") {
                Picker("", selection: $mode) { ForEach(ApprovalMode.allCases) { Text(ApprovalModeMenu.title($0)).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            row("Model") {
                Button(engine.model(model).map(ModelChip.short) ?? model?.id ?? "Choose…") { showModels = true }
                    .buttonStyle(PillStyle(compact: true))
                    .popover(isPresented: $showModels) {
                        ModelPicker(engine: engine, selected: model, role: .build) { m in model = m; showModels = false }
                    }
                Spacer()
            }
            HStack(spacing: 6) {
                if let file = project.contextFile { chip(file, "doc.text") }
                if project.piConfig { chip(".pi config", "gearshape") }
                if !project.rules.isEmpty { chip("\(project.rules.count) approval \(project.rules.count == 1 ? "rule" : "rules")", "checkmark.shield") }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button { Task { await start() } } label: {
                    HStack(spacing: 6) {
                        if starting { ProgressView().controlSize(.mini) }
                        Text("Start ⌘↩")
                    }
                }
                .buttonStyle(PillStyle(kind: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || starting || (workOn != .current && branch.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            focused = true
            if prompt.isEmpty { prompt = initialPrompt }
            if let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_NEW_SESSION"], prompt.isEmpty { prompt = demo }
            let defaults = UserDefaults.standard
            if let raw = defaults.string(forKey: "newSession.workOn.\(project.id)"), let k = Kind(rawValue: raw), project.branch != nil { workOn = k }
            if ProcessInfo.processInfo.environment["PIOPIO_DEMO_WORKTREE"] == "1" { workOn = .worktree }
            mode = project.approvalMode
            model = engine.model(for: .build)
        }
        .onChange(of: prompt) { _, text in
            guard !branchEdited else { return }
            Task {
                if let suggested = try? await engine.client?.call("git.suggestBranch", SuggestBranchParams(prompt: text), as: SuggestBranchResult.self).branch, !branchEdited {
                    branch = suggested
                }
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsFg2).frame(width: 86, alignment: .leading)
            content()
        }
    }

    private func chip(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 11.5)).foregroundStyle(Color.dsFg2)
            .padding(.horizontal, 9).frame(height: 22).background(Color.dsChip, in: Capsule())
    }

    private func start() async {
        starting = true
        error = nil
        UserDefaults.standard.set(workOn.rawValue, forKey: "newSession.workOn.\(project.id)")
        let target: WorkOn = switch workOn {
        case .current: .current
        case .branch: .branch(branch, base: nil)
        case .worktree: .worktree(branch, base: nil)
        }
        do {
            let ref = try await engine.createBuildSession(in: project, workOn: target, mode: mode, model: model)
            let session = engine.thread(ref)
            await session.open()
            await session.send(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            onStart(ref)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
        starting = false
    }
}
