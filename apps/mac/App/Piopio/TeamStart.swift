import AppKit
import PiopioKit
import SwiftUI

/// New team (docs/spec/20 P4): describe it in a sentence and Piopio drafts the members for you to adjust, or start
/// from a template (built in, or one of yours). It's made as a definition; a project gets it in its Settings.
struct TeamStart: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var text = ""
    @State private var draft: TeamDraft?
    @State private var templates: [TeamTemplate] = []
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: StartField?

    var body: some View {
        StartColumn(top: 96) {
            StartHeader(kind: .team, description: "Describe it in a sentence: who's on it and what it does. Piopio drafts the members; you adjust them before it's made. Then give it to a project in the project's Settings.") {
                TitleText(text: "New team")
            }
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("A marketing team with a lead, a copywriter, a designer and an editor who reviews")
                            .font(.system(size: 14)).foregroundStyle(Color.dsFg3).padding(.horizontal, 17).padding(.vertical, 20).allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .focused($focus, equals: .text)
                        .font(.system(size: 14)).scrollContentBackground(.hidden).padding(12).frame(height: 84)
                        .accessibilityLabel("Describe the team")
                }
                .composerBox()
                HStack {
                    Spacer()
                    // Once there's a draft, ⌘↩ creates it; drafting again is a plain button.
                    if draft == nil {
                        MainAction(title: "Draft members ⌘↩", busy: busy, enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: makeDraft)
                    } else {
                        Button("Draft again", action: makeDraft).buttonStyle(PillStyle())
                    }
                }
            }
            if let draft { preview(draft) }
            StartError(text: error)
            VStack(alignment: .leading, spacing: 10) {
                Text("Or start from a template").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg2)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(templates) { t in templateCard(t) }
                }
            }
        }
        .disabled(busy)
        .task {
            templates = await engine.teamTemplates()
            focus = .text
            // PIOPIO_DEMO_TEAM_DESCRIBE=<text>: captures show a drafted team.
            if let demo = ProcessInfo.processInfo.environment["PIOPIO_DEMO_TEAM_DESCRIBE"] {
                text = demo
                makeDraft()
            }
        }
    }

    /// The drafted team: its name and members, each one removable (except the lead) and renamable.
    private func preview(_ d: TeamDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Team name", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 }))
                .textFieldStyle(.plain).font(.system(size: 17, weight: .semibold))
            ForEach(Array(d.roles.enumerated()), id: \.offset) { i, role in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            TextField("Name", text: Binding(get: { draft?.roles[safe: i]?.name ?? "" }, set: { draft?.roles[i].name = $0 }))
                                .textFieldStyle(.plain).font(.system(size: 13.5, weight: .semibold)).fixedSize()
                            Text(kind(role.kind)).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                        }
                        Text(role.responsibility).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if role.kind != "lead" {
                        Button { draft?.roles.remove(at: i) } label: { Image(systemName: "minus.circle").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Leave this member out")
                    }
                }
                .padding(10)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            }
            HStack {
                Text("You can change members, models and instructions on the team's page later.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                Spacer()
                MainAction(title: "Create team ⌘↩", busy: busy, enabled: !(draft?.name.trimmingCharacters(in: .whitespaces).isEmpty ?? true), action: createFromDraft)
            }
        }
    }

    private func templateCard(_ t: TeamTemplate) -> some View {
        Button { createFromTemplate(t) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(t.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
                    if t.source == "yours" { Text("Yours").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.dsFg2).padding(.horizontal, 6).padding(.vertical, 1).background(Color.dsChip, in: Capsule()) }
                }
                Text(t.description).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text(t.roles.map(\.name).joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.folder.map { "Your template, in \($0)" } ?? "Make a team from this template")
    }

    private func kind(_ k: String) -> String {
        switch k {
        case "lead": "Plans and assigns"
        case "write": "Does tasks"
        case "review": "Reviews every task"
        default: "Merges and runs the checks"
        }
    }

    private func makeDraft() {
        let description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return }
        run {
            draft = nil
            draft = try await engine.draftTeam(description)
        }
    }

    private func createFromDraft() {
        guard let d = draft else { return }
        run {
            let def = try await engine.createTeamDefinition(CreateTeamDefinitionParams(name: d.name, style: d.style, instructions: d.instructions, roles: d.roles))
            item = .team(def.id)
        }
    }

    private func createFromTemplate(_ t: TeamTemplate) {
        run {
            let def = try await engine.createTeamDefinition(CreateTeamDefinitionParams(template: t.id))
            item = .team(def.id)
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await work() } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }
}
