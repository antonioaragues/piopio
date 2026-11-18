import AppKit
import PiopioKit
import SwiftUI

// How work is done in a project (docs/spec/26 §4), in its settings: parallel work on or off and, once it has been on,
// review, checks, tasks at once, the helpers' models and what they may do, the budget per job and the playbook. The
// fit check when parallel work first goes on, and the project's AGENTS.md and NOTES.md.

struct WayOfWorkingSection: View {
    let engine: EngineController
    let project: ProjectInfo
    @State private var fitting = false
    @State private var testCommand = ""
    @State private var playbooks: [Playbook] = []
    @State private var picking: String?
    @State private var error: String?

    private var work: ProjectWork? { engine.work(in: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Parallel work", work?.way.parallel == true ? "Piopio may split bigger work onto the board, for helpers that work at once" : "Piopio does everything itself, in the conversation") {
                Toggle("", isOn: Binding(get: { work?.way.parallel ?? false }, set: setParallel)).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if let work { settings(work) }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
        }
        .task(id: work?.way.testCommand) { testCommand = work?.way.testCommand ?? "" }
        .task(id: project.id) { playbooks = await engine.playbooks(in: project) }
        .sheet(isPresented: $fitting) { ParallelFitSheet(engine: engine, project: project) { fitting = false } }
    }

    @ViewBuilder private func settings(_ work: ProjectWork) -> some View {
        let way = work.way
        row("Review", way.review ? "Every task is checked by a helper with fresh eyes" : "Tasks are done when their helper finishes") {
            HStack(spacing: 10) {
                if way.review {
                    Stepper(value: Binding(get: { way.reviewLimit }, set: { n in configure(ConfigureWorkParams(project: project.id, reviewLimit: n)) }), in: 1...10) {
                        Text("sent back at most \(way.reviewLimit) time\(way.reviewLimit == 1 ? "" : "s"), then ask me").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    }
                    .fixedSize()
                }
                Toggle("", isOn: Binding(get: { way.review }, set: { on in configure(ConfigureWorkParams(project: project.id, review: on)) })).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
        row("Checks", work.git == nil ? "Run after each task, in the project's folder" : "Run on the work branch after each merge; a failure sends the task back") {
            HStack(spacing: 6) {
                TextField("", text: $testCommand, prompt: Text("npm test"))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced)).frame(width: 170)
                    .onSubmit(saveChecks)
                if testCommand.trimmingCharacters(in: .whitespaces) != (way.testCommand ?? "") {
                    Button("Save", action: saveChecks).buttonStyle(PillStyle(compact: true))
                }
            }
        }
        row("Tasks at once", "The rest wait their turn") {
            Stepper(value: Binding(get: { way.maxParallel }, set: { n in configure(ConfigureWorkParams(project: project.id, maxParallel: n)) }), in: 1...8) {
                Text("\(way.maxParallel)").font(.system(size: 13).monospacedDigit())
            }
            .fixedSize()
        }
        row("Helpers' models", "For doing tasks, and for reviewing them") {
            HStack(spacing: 6) {
                model("build", way.buildModel, fallback: "The project's")
                model("review", way.reviewModel, fallback: way.buildModel == nil ? "The project's" : "The build model")
            }
        }
        row("Helpers may", "What they do without asking") {
            Picker("", selection: Binding(get: { way.helperMode }, set: { v in configure(ConfigureWorkParams(project: project.id, helperMode: v)) })) {
                ForEach(ApprovalMode.allCases) { m in Text(m.title).tag(m.rawValue) }
            }
            .labelsHidden().fixedSize()
        }
        row("Budget", "Per job: what one conversation's tasks may spend") {
            TextField("No limit", value: Binding(get: { way.budgetPerJob }, set: { v in configure(ConfigureWorkParams(project: project.id, budgetPerJob: v ?? 0)) }), format: .currency(code: "USD"))
                .textFieldStyle(.roundedBorder).frame(width: 100)
        }
        row("Playbook", playbooks.first { $0.id == way.playbook }?.description ?? "How Piopio plans and splits the work") {
            Picker("", selection: Binding(get: { way.playbook }, set: { v in configure(ConfigureWorkParams(project: project.id, playbook: v)) })) {
                ForEach(playbooks) { p in Text(p.source == "project" ? "\(p.name) · this project's" : p.name).tag(p.id) }
                if !playbooks.contains(where: { $0.id == way.playbook }) { Text(way.playbook).tag(way.playbook) }
            }
            .labelsHidden().fixedSize()
        }
    }

    private func model(_ kind: String, _ raw: String?, fallback: String) -> some View {
        Button(engine.modelName(raw) ?? fallback) { picking = kind }
            .buttonStyle(ChipStyle()).font(.system(size: 12.5))
            .help(kind == "build" ? "Doing tasks" : "Reviewing them")
            .popover(isPresented: Binding(get: { picking == kind }, set: { if !$0 { picking = nil } }), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ModelPicker(engine: engine, selected: modelRef(raw), role: .build) { m in
                        picking = nil
                        configure(kind == "build" ? ConfigureWorkParams(project: project.id, buildModel: "\(m.provider):\(m.id)") : ConfigureWorkParams(project: project.id, reviewModel: "\(m.provider):\(m.id)"))
                    }
                    if raw != nil {
                        Divider()
                        Button("Use \(fallback.lowercased()) model") {
                            picking = nil
                            configure(kind == "build" ? ConfigureWorkParams(project: project.id, buildModel: "") : ConfigureWorkParams(project: project.id, reviewModel: ""))
                        }
                        .buttonStyle(.plain).font(.system(size: 12.5)).padding(10)
                    }
                }
            }
    }

    private func row<V: View>(_ title: String, _ detail: String, @ViewBuilder content: () -> V) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(Color.dsFg)
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            content()
        }
    }

    /// The first time, the fit check; after that, a switch.
    private func setParallel(_ on: Bool) {
        if on, work == nil { fitting = true } else { configure(ConfigureWorkParams(project: project.id, parallel: on)) }
    }

    private func saveChecks() {
        configure(ConfigureWorkParams(project: project.id, testCommand: testCommand.trimmingCharacters(in: .whitespaces)))
    }

    private func configure(_ params: ConfigureWorkParams) {
        Task {
            do { try await engine.configureWork(params); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}

/// When parallel work first goes on in a folder (design 5c-2): what it needs there, each missing thing with its fix,
/// then Switch on.
struct ParallelFitSheet: View {
    let engine: EngineController
    let project: ProjectInfo
    let done: () -> Void
    @State private var fit: FitCheck?
    @State private var startGit = true
    @State private var checks = ""
    @State private var writeAgents = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Parallel work in \(project.name)").font(.system(size: 15, weight: .semibold))
                Text("Piopio may split bigger work onto the board: a helper for each part, working at once, each part reviewed before it's merged. It still does small things itself.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            }
            if let fit {
                VStack(alignment: .leading, spacing: 12) {
                    row(ok: fit.git || startGit, title: fit.git ? "Git" : "No git yet",
                        detail: fit.git ? "Each task works on its own branch; you merge when it's ready." : "Without it, helpers share the folder, each on its own files.") {
                        if !fit.git { Toggle("Start git", isOn: $startGit).toggleStyle(.checkbox) }
                    }
                    row(ok: !checks.trimmingCharacters(in: .whitespaces).isEmpty, title: "Checks",
                        detail: fit.checks != nil ? "Found in the folder; they run after each merge. A failure sends the task back." : "None found. Without them, a review is the only check.") {
                        TextField("", text: $checks, prompt: Text("npm test"))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced)).frame(width: 150)
                    }
                    row(ok: fit.agentsMd, title: "AGENTS.md",
                        detail: fit.agentsMd ? "What every helper is told about this project." : "Helpers only know what Piopio's brief tells them.") {
                        if !fit.agentsMd { Toggle("Write one with Piopio", isOn: $writeAgents).toggleStyle(.checkbox) }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Switch on", action: switchOn).keyboardShortcut(.defaultAction).disabled(busy || fit == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            fit = await engine.fitCheck(project.path)
            checks = fit?.checks ?? ""
        }
    }

    private func row<Fix: View>(ok: Bool, title: String, detail: String, @ViewBuilder fix: () -> Fix) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 14)).foregroundStyle(ok ? Color.dsGreen : Color.dsWarn).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            fix()
        }
    }

    private func switchOn() {
        busy = true
        let command = checks.trimmingCharacters(in: .whitespaces)
        let initGit = fit?.git == false && startGit
        let agents = fit?.agentsMd == false && writeAgents
        Task {
            defer { busy = false }
            do {
                try await engine.configureWork(ConfigureWorkParams(project: project.id, parallel: true, testCommand: command, initGit: initGit ? true : nil))
                // AGENTS.md by Piopio: a conversation of its own in the project.
                if agents, let ref = await engine.createBuildSession(in: project) {
                    _ = await engine.thread(ref).send("Read this project and write an AGENTS.md at its root for the helpers that work here: what the project is, how to build, run and test it, its layout and conventions. Keep it short and concrete.")
                }
                done()
            } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}
