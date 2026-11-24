import PiopioKit
import SwiftUI

/// Your skills in Settings › Extensions (backlog D9, PAR12, docs/spec/40 SH0): the ones you or /learn made, every
/// project's. A package's skills stay with the package. New skill, or a row, opens the skill's sheet.
struct YourSkillsCard: View {
    let engine: EngineController
    @State private var skills: [SkillInfo] = []
    @State private var editing: SkillEditTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: "Your skills") {
                Button("New skill") { editing = SkillEditTarget(path: nil) }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
            }
            ListCard {
                if skills.isEmpty {
                    Text("None yet. /learn proposes one when you walk Piopio through a job worth repeating, or make one here.")
                        .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                        .padding(.horizontal, 14).frame(minHeight: 52, alignment: .leading)
                }
                ForEach(Array(skills.enumerated()), id: \.element.id) { i, skill in
                    Button { editing = SkillEditTarget(path: skill.path) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "text.book.closed").font(.system(size: 14)).foregroundStyle(Color.dsFg2).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(skill.name).font(.system(size: 13.5, weight: .semibold))
                                    if skill.manual { Text("/skill:\(skill.name) only").font(.system(size: 11)).foregroundStyle(Color.dsFg3) }
                                }
                                Text(skill.description).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                    if i < skills.count - 1 { RowDivider() }
                }
            }
            FinePrint("Saved in ~/.pi/agent/skills, where pi and Piopio both find them. A skill loads when a task matches when it's used, or with /skill:name.")
                .padding(.top, 10)
        }
        .task { await load() }
        .sheet(item: $editing) { target in
            SkillSheet(engine: engine, path: target.path) { editing = nil; Task { await load() } }
        }
    }

    private func load() async {
        skills = ((try? await engine.client?.call("skills.list", SkillsListParams(), as: SkillsResult.self).skills) ?? [])
            .filter { $0.where == .yours }.sorted { $0.name < $1.name }
    }
}

struct SkillEditTarget: Identifiable {
    let path: String?
    var id: String { path ?? "new" }
}

/// One skill, as docs/design/learn draws it opened: its name, when it's used, its instructions, and whether it loads by
/// itself or only with /skill:name. Delete moves its folder to the Trash.
struct SkillSheet: View {
    let engine: EngineController
    let path: String?
    let done: () -> Void
    @State private var name = ""
    @State private var usedWhen = ""
    @State private var body_ = ""
    @State private var manual = false
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(path == nil ? "New skill" : "Skill").font(.system(size: 15, weight: .semibold))
            field("Name", hint: "Lowercase with hyphens; /skill:\(name.isEmpty ? "name" : name) calls it") {
                TextField("release-piopio", text: $name).textFieldStyle(.roundedBorder)
            }
            field("Used when", hint: "What the model reads to decide to load it") {
                TextField("When you're asked to cut a release of this app", text: $usedWhen, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
            }
            field("Instructions", hint: "Markdown: the steps with real commands and paths, and what to check") {
                TextEditor(text: $body_).font(.system(size: 12, design: .monospaced)).frame(minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.dsLine, lineWidth: 0.5))
            }
            Toggle("Only when I ask for it with /skill:\(name.isEmpty ? "name" : name)", isOn: $manual).toggleStyle(.checkbox).font(.system(size: 12.5))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed) }
            HStack(spacing: 10) {
                if path != nil {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).buttonStyle(PillStyle(kind: .strong, compact: true))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || usedWhen.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
        .confirmationDialog("Delete \(name)?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive, action: delete)
        } message: { Text("Its folder goes to the Trash; conversations stop loading it.") }
    }

    private func field(_ title: String, hint: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
            content()
            Text(hint).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
        }
    }

    private func load() async {
        guard let path, let got = try? await engine.client?.call("skills.get", SkillPathParams(path: path), as: SkillResult.self) else { return }
        name = got.info.name; usedWhen = got.info.description; body_ = got.body; manual = got.info.manual
    }

    private func save() {
        Task {
            do {
                _ = try await engine.client?.call("skills.save", SkillSaveParams(path: path, name: name, description: usedWhen, body: body_, manual: manual ? true : nil), as: SkillSaveResult.self)
                done()
            } catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
        }
    }

    private func delete() {
        guard let path else { return }
        Task {
            do { try await engine.spaceCall("skills.delete", SkillPathParams(path: path)); done() }
            catch { self.error = (error as? EngineError)?.message ?? String(describing: error) }
        }
    }
}
