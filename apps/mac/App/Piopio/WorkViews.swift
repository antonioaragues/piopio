import AppKit
import PiopioKit
import SwiftUI

// A project's board (docs/spec/26): the tasks Piopio put there for helpers, as a kanban you can edit (19 TD5); the
// merge card; and the project's routines.

/// The board: To do, Doing, Review, Done and Blocked. A card opens its helper's session; its menu moves it back or
/// stops it.
struct WorkBoard: View {
    let engine: EngineController
    let project: ProjectInfo
    let work: ProjectWork
    @Binding var item: SidebarItem
    @State private var adding = false

    private static let columns: [(id: String, title: String, states: Set<String>)] = [
        ("todo", "To do", ["todo"]), ("doing", "Doing", ["doing"]), ("review", "Review", ["review", "integrating"]), ("done", "Done", ["done"]), ("blocked", "Blocked", ["blocked"]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if work.git != nil { LandingCard(engine: engine, work: work).padding([.horizontal, .top], 20) }
            columns
        }
        .sheet(isPresented: $adding) { AddTask(engine: engine, project: project) { adding = false } }
    }

    private var columns: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Self.columns, id: \.id) { column in
                    let tasks = work.tasks.filter { column.states.contains($0.state) }
                    if column.id != "blocked" || !tasks.isEmpty { self.column(column.title, tasks, add: column.id == "todo") }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func column(_ title: String, _ tasks: [WorkTask], add: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(tasks.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
                Spacer()
                if add {
                    Button { adding = true } label: { Image(systemName: "plus").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Add a task")
                }
            }
            .padding(.horizontal, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tasks) { card($0) }
                    if tasks.isEmpty { Text(add ? "Piopio adds tasks here. You can too." : "Nothing here.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.horizontal, 4) }
                }
            }
        }
        .frame(width: 240, alignment: .topLeading)
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.dsChip.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func card(_ task: WorkTask) -> some View {
        Button { if let id = task.reviewSessionId ?? task.sessionId, task.state == "review" { item = .session(id) } else if let id = task.sessionId { item = .session(id) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(task.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3)
                    if task.state == "doing" || task.state == "review" || task.state == "integrating" { ProgressView().controlSize(.mini) }
                    Spacer()
                    Text(task.helper).font(.system(size: 11)).foregroundStyle(Color.dsFg2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.dsChip, in: Capsule())
                }
                Text(task.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                if let line = status(task) { Text(line).font(.system(size: 11.5)).foregroundStyle(task.state == "blocked" ? Color.dsWarn : Color.dsFg3).lineLimit(3) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.sessionId == nil ? task.brief : "Open its session")
        .contextMenu {
            if task.state != "todo" { Button("Move to To do") { update(task, state: "todo") } }
            if task.state != "blocked" { Button("Stop (Blocked)") { update(task, state: "blocked") } }
            if task.state != "done" { Button("Mark Done") { update(task, state: "done") } }
        }
    }

    private func status(_ task: WorkTask) -> String? {
        switch task.state {
        case "review": "In review"
        case "integrating": "Merging and checking"
        case "blocked": task.blocked
        case "doing": task.attempts > 0 ? "Round \(task.attempts + 1), after a review" : (task.by == "you" ? "Added by you" : nil)
        case "done": task.report.map { $0.replacingOccurrences(of: "\n", with: " ") }
        default: task.by == "you" ? "Added by you" : nil
        }
    }

    private func update(_ task: WorkTask, state: String) {
        Task { try? await engine.updateTask(project, task, state: state) }
    }
}

/// You add a card to the board: a title and a brief; a helper is made for it.
private struct AddTask: View {
    let engine: EngineController
    let project: ProjectInfo
    let done: () -> Void
    @State private var title = ""
    @State private var brief = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New task").font(.system(size: 15, weight: .semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $brief).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(height: 110)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsFg2) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task {
                        do {
                            try await engine.addTask(project, title: title, brief: brief)
                            done()
                        } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// The merge card (docs/spec/19 §11): what the work branch would bring to the project's, and the two ways to land
/// it: merge it here, or push it for a pull request. Shown once the branch has work the project doesn't.
struct LandingCard: View {
    let engine: EngineController
    let work: ProjectWork
    /// In the conversation that made the tasks (docs/spec/21 D6, design 5b-4): a green card with what they cost.
    var conversation: String? = nil
    var onMerged: (() -> Void)? = nil
    @State private var landing: WorkLanding?
    @State private var job: WorkJob?
    @State private var creatingPR = false
    @State private var showingFiles = false
    @State private var busy = false
    @State private var confirming = false
    @State private var note: (text: String, warn: Bool)?

    /// Reloads when a card moves or lands.
    private var key: String { work.tasks.map { "\($0.id)\($0.state)\($0.landed ?? "")" }.joined(separator: ",") }

    var body: some View {
        // A stack, not a Group: an empty Group has nothing to run the task on.
        VStack(alignment: .leading, spacing: 0) {
            if let landing, landing.ahead > 0 { if conversation != nil { conversationCard(landing) } else { card(landing) } }
            else if let note { line(note.text, warn: note.warn).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .sheet(isPresented: $creatingPR) { WorkPRSheet(engine: engine, work: work) { creatingPR = false } }
        .task(id: key) {
            landing = await engine.landing(work)
            if let conversation { job = await engine.job(work, conversationId: conversation) }
        }
    }

    /// The design's green: oklch(0.66 0.14 150) on a dark green.
    private static let green = Color(red: 0.36, green: 0.66, blue: 0.42)

    /// "Ready for main · 3 tasks · 14 files · checks passed · $0.36", with Merge, See changes and Push for a PR.
    private func conversationCard(_ l: WorkLanding) -> some View {
        var meta = [count(l.tasks.count, "task"), count(l.files.count, "file")]
        if work.way.testCommand?.isEmpty == false { meta.append("checks passed") }
        if let cost = job?.cost, cost > 0 { meta.append(cost < 0.01 ? "<$0.01" : String(format: "$%.2f", cost)) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Self.green)
                Text("Ready for \(l.base)").font(.system(size: 13.5, weight: .semibold))
                Text(meta.joined(separator: " · ")).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg2)
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 8) {
                Button("Merge into \(l.base)") { confirming = true }.buttonStyle(PillStyle(kind: .primary, compact: true))
                Button("See changes") { showingFiles = true }.buttonStyle(PillStyle(compact: true))
                    .popover(isPresented: $showingFiles, arrowEdge: .bottom) { files(l) }
                if l.remote != nil { Button("Create PR…") { creatingPR = true }.buttonStyle(PillStyle(compact: true)) }
                Spacer()
            }
            if l.behind > 0 { line("\(l.base) has \(count(l.behind, "commit")) the work branch doesn't. If they touch the same files, the merge stops and changes nothing.", warn: false) }
            if let note { line(note.text, warn: note.warn) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.green.opacity(0.1)))
        .background(Color.dsWin, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Self.green, lineWidth: 1))
        .disabled(busy)
        .alert("Merge \(l.branch) into \(l.base)?", isPresented: $confirming) {
            Button("Merge") { Task { await land("merge") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(count(l.tasks.count, "task")), \(count(l.files.count, "file")). New tasks start from there.")
        }
    }

    private func files(_ l: WorkLanding) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(l.files, id: \.path) { f in
                HStack(spacing: 8) {
                    Text(f.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 12)
                    if f.added > 0 { Text("+\(f.added)").foregroundStyle(Color.dsGreen) }
                    if f.removed > 0 { Text("−\(f.removed)").foregroundStyle(Color.dsRed) }
                }
                .font(.system(size: 12).monospacedDigit())
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private func card(_ l: WorkLanding) -> some View {
        let added = l.files.reduce(0) { $0 + $1.added }, removed = l.files.reduce(0) { $0 + $1.removed }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 15)).foregroundStyle(Color.dsFg2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.open > 0 ? "Done work is ready for \(l.base)" : "Ready for \(l.base)").font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(count(l.tasks.count, "task")).help(l.tasks.map { "\($0.id) \($0.title)" }.joined(separator: "\n"))
                        Text("·")
                        Text(count(l.files.count, "file")).help(l.files.map { "\($0.path)  +\($0.added) −\($0.removed)" }.joined(separator: "\n"))
                        if added > 0 { Text("+\(added)").foregroundStyle(Color.dsGreen) }
                        if removed > 0 { Text("−\(removed)").foregroundStyle(Color.dsRed) }
                        Text("·")
                        Text(l.branch).font(.system(size: 12, design: .monospaced))
                    }
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg3)
                }
                Spacer(minLength: 12)
                if busy { ProgressView().controlSize(.small) }
                if l.remote != nil {
                    Button("Create PR…") { creatingPR = true }.buttonStyle(PillStyle())
                        .help("Pushes \(l.branch) to \(l.remote ?? "the remote") and opens a pull request into \(l.base)")
                }
                Button("Merge into \(l.base)…") { confirming = true }.buttonStyle(PillStyle(kind: .primary))
            }
            if l.open > 0 { line("\(count(l.open, "task")) still on the board; they stay on the work branch.", warn: false) }
            if l.behind > 0 { line("\(l.base) has \(count(l.behind, "commit")) the work branch doesn't. If they touch the same files, the merge stops and changes nothing.", warn: false) }
            if let note { line(note.text, warn: note.warn) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .disabled(busy)
        .alert("Merge \(l.branch) into \(l.base)?", isPresented: $confirming) {
            Button("Merge") { Task { await land("merge") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(l.checkedOut == l.base
                ? "In the project's folder, which is on \(l.base): \(count(l.tasks.count, "task")), \(count(l.files.count, "file")). New tasks start from there."
                : "The project's folder is on \(l.checkedOut ?? "another branch") and stays there; \(l.base) is updated aside. \(count(l.tasks.count, "task")), \(count(l.files.count, "file")).")
        }
    }

    private func line(_ text: String, warn: Bool) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(warn ? Color.dsWarn : Color.dsFg3).fixedSize(horizontal: false, vertical: true)
    }

    private func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    private func land(_ action: String) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await engine.land(work, action: action)
            if action == "push" {
                if let url = result.compareUrl.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
                note = ("Pushed \(work.git?.branch ?? "the work branch")\(result.compareUrl != nil ? ": create the pull request in your browser." : ".")", false)
            } else {
                note = ("Merged into \(work.git?.base ?? "the project")\(result.commit.map { " (\($0))" } ?? ""). Piopio knows.", false)
                onMerged?()
            }
        } catch {
            note = ((error as? EngineError)?.message ?? error.localizedDescription, true)
        }
        landing = await engine.landing(work)
    }
}

/// What starts work in a project on its own (docs/spec/27 AU10): automations Piopio runs here. They live in
/// Automations; the project's settings show them and lead there.
struct ProjectAutomationsLink: View {
    let engine: EngineController
    let project: ProjectInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let mine = engine.automations.filter { $0.project == project.id }
        VStack(alignment: .leading, spacing: 10) {
            Text(mine.isEmpty
                 ? "Nothing starts work here on its own yet. Ask Piopio in a conversation here (“every Monday, a brief on our competitors”), or make one in Automations."
                 : "Each run is a new conversation with Piopio in this project. Ask Piopio to change them, or open one.")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            ForEach(mine) { a in
                Button { select(.automation(a.id)) } label: {
                    HStack(spacing: 8) {
                        Text(a.name).font(.system(size: 13)).foregroundStyle(a.enabled ? Color.dsFg : Color.dsFg3).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(a.enabled ? a.label : "Paused").font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button(mine.isEmpty ? "Open Automations ›" : "\(mine.count) automation\(mine.count == 1 ? "" : "s") work here ›") { select(.automations(project.id)) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 12.5))
        }
    }

    private func select(_ item: SidebarItem) {
        dismiss()
        NotificationCenter.default.post(name: .selectItem, object: item.raw)
    }
}
