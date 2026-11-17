import AppKit
import PiopioKit
import SwiftUI

// GitHub in the app (docs/spec/05-build G4–G8): Create PR from a conversation or the Board, the pull request above
// the composer with its checks and comments (Fix CI, Address comments), Settings › Git & GitHub, and Clone.

extension Notification.Name {
    /// Opens the Create PR sheet for a conversation (object: its id).
    static let createPullRequest = Notification.Name("piopio.createPullRequest")
}

/// Create PR (G6): a title and body drafted from the conversation and its diff, the base branch, draft or ready.
struct CreatePRSheet: View {
    let engine: EngineController
    let ref: ContainerRef
    let done: () -> Void
    @State private var title = ""
    @State private var prBody = ""
    @State private var base = ""
    @State private var head = ""
    @State private var draft = false
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create pull request").font(.system(size: 15, weight: .semibold))
            if loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Writing a draft from the conversation and its diff…").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3) }
            } else {
                HStack(spacing: 6) {
                    Text(head).font(.system(size: 12.5, design: .monospaced))
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Color.dsFg3)
                    TextField("Base", text: $base).textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced)).frame(width: 140)
                }
                .foregroundStyle(Color.dsFg2)
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                TextEditor(text: $prBody).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(height: 180)
                    .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
                Toggle("Open as a draft", isOn: $draft).toggleStyle(.checkbox)
                Text("The branch is pushed to GitHub first. Only what's committed goes in.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Create pull request", action: create).keyboardShortcut(.defaultAction)
                    .disabled(loading || busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .task {
            do {
                let d = try await engine.prDraft(ref)
                title = d.title; prBody = d.body; base = d.base; head = d.head
            } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
            loading = false
        }
    }

    private func create() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await engine.createPR(ref, title: title, body: prBody, base: base, draft: draft)
                done()
            } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}

/// A conversation's pull request (G7), above its composer: its state and checks, comments, and the two hand-offs to
/// the conversation, Fix CI (G8) and Address comments.
struct PullRequestBlock: View {
    let engine: EngineController
    let summary: SessionSummary
    @State private var status: PrStatus?
    @State private var open = false
    @State private var error: String?

    var body: some View {
        if let pr = summary.pr {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dsFg3).rotationEffect(.degrees(open ? 90 : 0))
                            Image(systemName: "arrow.triangle.pull").font(.system(size: 12)).foregroundStyle(Self.color(pr.state, pr.checks))
                            Text("#\(pr.number)").font(.system(size: 12.5, weight: .semibold))
                            Text(pr.title).font(.system(size: 12.5)).lineLimit(1)
                            Text(line(pr)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    if pr.state == "open", pr.checks == "failing" { Button("Fix CI") { address("ci") }.buttonStyle(PillStyle(kind: .primary, compact: true)) }
                    if pr.state == "open", humanComments > 0 { Button("Address comments") { address("comments") }.buttonStyle(PillStyle(compact: true)) }
                    Button { if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) } } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).foregroundStyle(Color.dsFg2).help("Open on GitHub")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                if open, let status { details(status) }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn).padding(.horizontal, 12).padding(.bottom, 8) }
            }
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            .frame(maxWidth: 680)
            // While it's in view: now, then every minute (the engine polls every two for the conversation's sake).
            .task(id: "\(pr.number)\(pr.state)\(pr.checks ?? "")") {
                while !Task.isCancelled {
                    status = try? await engine.pullRequest(summary.ref)
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    private var humanComments: Int { status?.comments.filter { !$0.bot }.count ?? 0 }

    private func line(_ pr: SessionSummary.PR) -> String {
        var parts = [pr.state == "open" ? "open into \(pr.base)" : pr.state]
        switch pr.checks {
        case "failing": parts.append("checks failing")
        case "pending": parts.append("checks running")
        case "passing": parts.append("checks passed")
        default: break
        }
        if humanComments > 0 { parts.append("\(humanComments) comment\(humanComments == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func details(_ s: PrStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(s.checks, id: \.name) { c in
                HStack(spacing: 8) {
                    Circle().fill(c.status != "completed" ? Color.accentColor : ["success", "neutral", "skipped"].contains(c.conclusion ?? "") ? Color.dsGreen : Color.dsRed).frame(width: 7, height: 7)
                    Text(c.name).font(.system(size: 12.5))
                    Text(c.status == "completed" ? (c.conclusion ?? "done") : "running").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Spacer()
                    if let url = c.url.flatMap(URL.init(string:)) { Button("Details") { NSWorkspace.shared.open(url) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
                }
            }
            ForEach(s.comments.filter { !$0.bot }) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text([c.author, c.path.map { p in c.line.map { "\(p):\($0)" } ?? p }].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
                    Text(c.body).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            if s.checks.isEmpty && s.comments.isEmpty { Text("No checks or comments yet.").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private func address(_ what: String) {
        Task {
            do { try await engine.addressPR(summary.ref, what); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    static func color(_ state: String, _ checks: String?) -> Color {
        if state == "merged" { return Color.purple }
        if state == "closed" { return Color.dsFg3 }
        return checks == "failing" ? Color.dsRed : checks == "passing" ? Color.dsGreen : Color.dsFg2
    }
}

/// The Board's work branch as a pull request (G6): a title and body, then it opens on GitHub.
struct WorkPRSheet: View {
    let engine: EngineController
    let work: ProjectWork
    let done: () -> Void
    @State private var title = ""
    @State private var prBody = ""
    @State private var draft = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create pull request").font(.system(size: 15, weight: .semibold))
            Text("\(work.git?.branch ?? "") → \(work.git?.base ?? "")").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color.dsFg2)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $prBody).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(height: 140)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
            Toggle("Open as a draft", isOn: $draft).toggleStyle(.checkbox)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Create pull request") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            let pr = try await engine.createWorkPR(work, title: title, body: prBody, draft: draft)
                            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                            done()
                        } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            let done = work.tasks.filter { $0.state == "done" && $0.landed == nil }
            title = done.count == 1 ? done[0].title : "\(done.count) tasks from the board"
            prBody = done.map { "- \($0.id) \($0.title)" }.joined(separator: "\n")
        }
    }
}

/// Settings › Git & GitHub (G4): signed in through `gh`, a token of yours, or not at all.
struct GitHubPane: View {
    let engine: EngineController
    @State private var status: GitHubStatus?
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "Git & GitHub", summary: "Pull requests, checks and cloning")
            CardTitle("GitHub")
            ListCard {
                HStack(spacing: 12) {
                    Image(systemName: status?.connected == true ? "checkmark.circle.fill" : "circle").foregroundStyle(status?.connected == true ? Color.dsGreen : Color.dsFg3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status?.connected == true ? "Signed in as \(status?.login ?? "")" : "Not signed in").font(.system(size: 13))
                        Text(status?.via == "gh" ? "Through the GitHub CLI (gh)." : status?.via == "token" ? "With your token, kept in the Keychain." : (status?.error ?? "Sign in with `gh auth login` in Terminal, or add a token below.")).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                    }
                    Spacer()
                    if status?.via == "token" { Button("Sign out") { Task { await engine.signOutOfGitHub(); await reload() } }.buttonStyle(PillStyle(compact: true)) }
                }
                .padding(.horizontal, 14).frame(minHeight: 50)
                if status?.via != "gh" {
                    RowDivider(inset: 14)
                    HStack(spacing: 8) {
                        SecureField("Personal access token (repo, workflow)", text: $token).textFieldStyle(.roundedBorder)
                        Button("Add") { add() }.buttonStyle(PillStyle(compact: true)).disabled(busy || token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn).padding(.top, 6) }
            Text("What a conversation hears about its pull request (new comments, failing checks, merged) is set per project, in its settings.")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 12)
        }
        .task { await reload() }
    }

    private func reload() async { status = await engine.gitHubStatus() }

    private func add() {
        busy = true
        Task {
            defer { busy = false }
            do { _ = try await engine.setGitHubToken(token); token = ""; error = nil; await reload() } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}

/// Clone (G5): one of your repositories, or any URL, into ~/Piopio as a new project.
struct CloneSheet: View {
    let engine: EngineController
    let done: (ProjectInfo?) -> Void
    @State private var repos: [GitHubRepo] = []
    @State private var source = ""
    @State private var filter = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone a repository").font(.system(size: 15, weight: .semibold))
            TextField("owner/name or a URL", text: $source).textFieldStyle(.roundedBorder).onSubmit(clone)
            if !repos.isEmpty {
                TextField("Filter your repositories", text: $filter).textFieldStyle(.roundedBorder)
                List(repos.filter { filter.isEmpty || $0.fullName.localizedCaseInsensitiveContains(filter) }) { r in
                    Button { source = r.fullName } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(r.fullName).font(.system(size: 13, weight: source == r.fullName ? .semibold : .regular))
                                if r.private { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Color.dsFg3) }
                            }
                            if let d = r.description { Text(d).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 220)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Cloning…").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Clone", action: clone).keyboardShortcut(.defaultAction).disabled(busy || source.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task { repos = (try? await engine.gitHubRepos()) ?? [] }
    }

    private func clone() {
        let repo = source.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { done(try await engine.clone(repo)) } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}
