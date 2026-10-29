import PiopioKit
import PiopioTranscript
import SwiftUI

// Debate threads (docs/spec/16-debate): two models work on one goal, an author and a reviewer, until they agree.

extension Notification.Name {
    static let newDebate = Notification.Name("piopio.newDebate")
}

extension EngineController {
    func createDebate(_ config: DebateConfig) async throws -> ContainerRef {
        guard let client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "The engine isn't running.") }
        let author = config.participants.first { $0.role == .author }?.model
        let ref = try await client.call("sessions.create", CreateSessionParams(kind: .thread, model: author, debate: config), as: CreateSessionResult.self).ref
        try? await refreshCatalog()
        return ref
    }
}

// MARK: Start sheet (§5)

/// New Debate: the goal, what a good result needs, the two models and the round limit, with what it may cost.
struct NewDebateSheet: View {
    let engine: EngineController
    let created: (ContainerRef) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""
    @State private var criteria = ""
    @State private var author: ModelRef?
    @State private var reviewer: ModelRef?
    @State private var rounds = 6
    @State private var picking: DebateRole?
    @State private var starting = false
    @State private var error: String?
    @AppStorage("debate.reviewer") private var lastReviewer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.wave.2").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(nsColor: DS.debateAuthor))
                Text("New Debate").font(.system(size: 17, weight: .bold))
            }
            Text("One model writes, the other reviews it against your goal, round after round, until the reviewer approves or the rounds run out.")
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            field("Goal", hint: "What should come out of it, and for whom.") {
                editor($goal, placeholder: "A one-page plan to migrate our billing to Stripe, for the CTO", height: 88)
            }
            field("A good result must… (optional)", hint: "The reviewer checks every draft against this.") {
                editor($criteria, placeholder: "Cover rollback. Stay under 600 words. No vendor marketing.", height: 56)
            }
            HStack(alignment: .top, spacing: 12) {
                participant(.author, "Writes", $author)
                participant(.reviewer, "Reviews", $reviewer)
            }
            if let author, let reviewer, family(author) == family(reviewer) {
                Label("Models from different makers catch more of each other's blind spots.", systemImage: "lightbulb")
                    .font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
            }
            HStack(spacing: 10) {
                Text("Rounds").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
                Stepper(value: $rounds, in: 2...12) { Text("up to \(rounds)").font(.system(size: 12.5)).monospacedDigit() }.fixedSize()
                Spacer()
                if let estimate { Text("about \(estimate) at most").font(.system(size: 12)).foregroundStyle(Color.dsFg3).help("A rough estimate for a one-page draft; it stops sooner when the reviewer approves.") }
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
                .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || author == nil || reviewer == nil || starting)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear(perform: defaults)
    }

    private func participant(_ role: DebateRole, _ verb: String, _ model: Binding<ModelRef?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: ItemRendererColors.speaker(role))).frame(width: 7, height: 7)
                Text(role == .author ? "Author" : "Reviewer").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
                Text("· \(verb.lowercased())").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Button { picking = role } label: {
                HStack {
                    Text(engine.model(model.wrappedValue).map(ModelChip.short) ?? model.wrappedValue?.id ?? "Choose…").lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.dsFg3)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillStyle(compact: true))
            .popover(isPresented: Binding(get: { picking == role }, set: { if !$0 { picking = nil } })) {
                ModelPicker(engine: engine, selected: model.wrappedValue) { m in model.wrappedValue = m; picking = nil }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ title: String, hint: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
            content()
            Text(hint).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
        }
    }

    private func editor(_ text: Binding<String>, placeholder: String, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                }
            }
    }

    /// The maker: "anthropic" in "anthropic/claude-…", else the provider.
    private func family(_ m: ModelRef) -> String {
        m.id.contains("/") ? String(m.id.split(separator: "/")[0]) : m.provider
    }

    /// The Chat model writes; the last reviewer reviews, or a model from another maker.
    private func defaults() {
        author = author ?? engine.preferredModel
        if reviewer == nil {
            let parts = lastReviewer.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2, engine.model(ModelRef(provider: parts[0], id: parts[1])) != nil {
                reviewer = ModelRef(provider: parts[0], id: parts[1])
            } else if let author {
                let other = engine.models.first { family(ModelRef(provider: $0.provider, id: $0.id)) != family(author) && $0.provider != "faux" }
                reviewer = other.map { ModelRef(provider: $0.provider, id: $0.id) } ?? author
            }
        }
    }

    /// Up to `rounds` rounds of a one-page draft: each side's context grows by one exchange a round.
    private var estimate: String? {
        guard let a = engine.model(author), let r = engine.model(reviewer) else { return nil }
        var usd = 0.0
        for round in 1...rounds {
            let n = Double(round)
            usd += (2_000 + n * 2_200) * a.pricing.input / 1e6 + 1_400 * a.pricing.output / 1e6
            usd += (3_000 + n * 1_200) * r.pricing.input / 1e6 + 600 * r.pricing.output / 1e6
        }
        guard usd > 0 else { return nil }
        return usd < 0.01 ? "<$0.01" : String(format: "$%.2f", usd)
    }

    private func start() async {
        guard let author, let reviewer else { return }
        starting = true
        defer { starting = false }
        let config = DebateConfig(
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            criteria: criteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : criteria.trimmingCharacters(in: .whitespacesAndNewlines),
            participants: [.init(role: .author, model: author), .init(role: .reviewer, model: reviewer)],
            maxRounds: rounds
        )
        do {
            let ref = try await engine.createDebate(config)
            lastReviewer = "\(reviewer.provider)|\(reviewer.id)"
            created(ref)
            dismiss()
        } catch {
            self.error = (error as? EngineError)?.message ?? error.localizedDescription
        }
    }
}

/// The speakers' colors for SwiftUI (the transcript's own, from the renderer).
enum ItemRendererColors {
    static func speaker(_ role: DebateRole) -> NSColor { role == .author ? DS.debateAuthor : DS.debateReviewer }
}

// MARK: Panel (§5): the current draft and the objections

struct DebatePanel: View {
    let debate: DebateState
    let thread: ThreadModel
    @State private var version: Int?
    @State private var showChanges = false
    @State private var expanded: Set<String> = []

    private var draft: DebateState.Draft? {
        if let version, let d = debate.drafts.first(where: { $0.version == version }) { return d }
        return debate.drafts.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
            Divider().overlay(Color.dsLine)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    draftSection
                    objectionsSection
                }
                .padding(16)
            }
        }
        .frame(width: 340)
        .background(Color.dsWin)
        .onChange(of: debate.drafts.count) { _, _ in version = nil }
    }

    // MARK: Status

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg)
                Spacer()
                Text("Round \(debate.round) of \(debate.maxRounds)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).monospacedDigit()
            }
            if let reason = debate.reason, debate.status != .running {
                Text(reason.prefix(1).uppercased() + reason.dropFirst()).font(.system(size: 12)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                ForEach(debate.participants, id: \.role) { p in
                    HStack(spacing: 4) {
                        Circle().fill(Color(nsColor: ItemRendererColors.speaker(p.role))).frame(width: 6, height: 6)
                        Text(p.label).font(.system(size: 11.5)).foregroundStyle(Color.dsFg2).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusTitle: String {
        switch debate.status {
        case .running:
            guard let turn = debate.turn else { return "Starting…" }
            return "\(debate.label(turn)) is \(turn == .author ? (debate.drafts.isEmpty ? "writing" : "revising") : "reviewing")…"
        case .agreed: return "Agreed"
        case .noAgreement: return "No agreement"
        case .stopped: return "Stopped"
        }
    }

    private var statusColor: Color {
        switch debate.status {
        case .running: Color(nsColor: debate.turn.map(ItemRendererColors.speaker) ?? DS.fg3)
        case .agreed: .dsFg2
        case .noAgreement: .dsFg2
        case .stopped: .dsFg3
        }
    }

    // MARK: Draft

    @ViewBuilder private var draftSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("DRAFT").font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(Color.dsFg3)
                if debate.drafts.count > 1 {
                    Picker("", selection: Binding(get: { draft?.version ?? 0 }, set: { version = $0 })) {
                        ForEach(debate.drafts) { d in Text("v\(d.version)").tag(d.version) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                } else if let draft {
                    Text("v\(draft.version)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.dsFg2)
                }
                Spacer()
                if let draft {
                    if previous(draft) != nil {
                        Toggle("Changes", isOn: $showChanges).toggleStyle(.button).controlSize(.small).help("What changed since the version before")
                    }
                    Button { copy(draft.text) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy this draft")
                }
            }
            if let draft {
                Text("Round \(draft.round)").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                if !draft.changes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(draft.changes.enumerated()), id: \.offset) { _, change in
                            Text("+ \(change)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Group {
                    if showChanges, let before = previous(draft) {
                        diff(before.text, draft.text)
                    } else {
                        Text(markdown(draft.text)).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
            } else {
                Text(debate.status == .running ? "The first draft is on its way." : "No draft was written.")
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
        }
    }

    private func previous(_ d: DebateState.Draft) -> DebateState.Draft? {
        debate.drafts.last { $0.version < d.version }
    }

    /// Lines removed (red, struck) and added (green) since the version before.
    private func diff(_ before: String, _ after: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(LineDiff.lines(before, after).enumerated()), id: \.offset) { _, line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: 12))
                    .strikethrough(line.kind == .removed)
                    .foregroundStyle(line.kind == .same ? Color.dsFg2 : Color.dsFg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3)
                    .background(line.kind == .added ? Color(nsColor: DS.addbg) : line.kind == .removed ? Color(nsColor: DS.delbg) : .clear)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: Objections

    @ViewBuilder private var objectionsSection: some View {
        let open = debate.objections.filter { $0.status == .open }
        let closed = debate.objections.filter { $0.status != .open }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("OBJECTIONS").font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(Color.dsFg3)
                Spacer()
                if !debate.objections.isEmpty {
                    Text("\(open.count) open · \(closed.count) closed").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                }
            }
            if debate.objections.isEmpty {
                Text(debate.drafts.isEmpty ? "The reviewer's objections show here." : "None yet.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            ForEach(open + closed) { objection(row: $0) }
        }
    }

    private func objection(row o: DebateState.Objection) -> some View {
        let isOpen = o.status == .open
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(o.id).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color.dsFg2)
                Text(o.severity == .blocking ? "blocking" : "minor")
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .foregroundStyle(o.severity == .blocking && isOpen ? Color.dsFg : Color.dsFg3)
                Spacer()
                Text(o.status.rawValue).font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            }
            Text(o.text).font(.system(size: 12.5)).foregroundStyle(isOpen ? Color.dsFg : Color.dsFg3).fixedSize(horizontal: false, vertical: true)
            if let pushback = o.pushback, isOpen {
                Text("↩ \(debate.label(.author)): \(pushback)").font(.system(size: 11.5)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            }
            if o.history.count > 1 {
                Button(expanded.contains(o.id) ? "Hide history" : "History (\(o.history.count))") {
                    if expanded.contains(o.id) { expanded.remove(o.id) } else { expanded.insert(o.id) }
                }
                .buttonStyle(.link).font(.system(size: 11))
                if expanded.contains(o.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(o.history.enumerated()), id: \.offset) { _, step in
                            Text("Round \(step.round) · \(debate.label(step.by)) \(step.action.replacingOccurrences(of: "_", with: " "))\(step.note.map { ": \($0)" } ?? "")")
                                .font(.system(size: 11)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.row + 2))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.row + 2).strokeBorder(Color.dsLine, lineWidth: 0.5))
        .opacity(isOpen ? 1 : 0.8)
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A line diff by longest common subsequence (drafts are a page or two).
enum LineDiff {
    enum Kind { case same, added, removed }
    struct Line { var kind: Kind; var text: String }

    static func lines(_ before: String, _ after: String) -> [Line] {
        let a = before.components(separatedBy: "\n"), b = after.components(separatedBy: "\n")
        guard a.count * b.count <= 400_000 else { return b.map { Line(kind: .same, text: $0) } }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { out.append(Line(kind: .same, text: a[i])); i += 1; j += 1 }
            else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] { out.append(Line(kind: .added, text: b[j])); j += 1 }
            else { out.append(Line(kind: .removed, text: a[i])); i += 1 }
        }
        return out
    }
}
