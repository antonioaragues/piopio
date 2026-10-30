import PiopioKit
import PiopioTranscript
import SwiftUI
import UniformTypeIdentifiers

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
            Text("New Debate").font(.system(size: 20, weight: .bold))
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
                Text(role == .author ? "Author" : "Reviewer").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg2)
                Text("· \(verb.lowercased())").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            Button { picking = role } label: {
                Text(engine.model(model.wrappedValue).map(ModelChip.short) ?? model.wrappedValue?.id ?? "Choose…").font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dsLine, lineWidth: 0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

// MARK: Layout (docs/design/grey 12a): the story on the left, the document on the right

struct DebateLayout: View {
    let engine: EngineController
    let thread: ThreadModel
    let debate: DebateState
    let showPane: Bool
    /// The version on screen (nil: the latest), and the version it's compared with (Changes).
    @State private var version: Int?
    @State private var comparing = false
    /// What you and the author said after the debate ended: an ordinary conversation.
    @State private var followUps = TranscriptDocument(versions: false)
    @State private var followUpItems: [TimelineItem] = []

    private var shown: DebateState.Draft? {
        if let version, let d = debate.drafts.first(where: { $0.version == version }) { return d }
        return debate.drafts.last
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if followUpItems.isEmpty {
                    DebateStory(thread: thread, debate: debate, shown: shown?.version, panes: showPane, open: open)
                } else {
                    DebateStory(thread: thread, debate: debate, shown: shown?.version, panes: showPane, open: open)
                        .frame(maxHeight: 280)
                    Rectangle().fill(Color.dsLine).frame(height: 0.5)
                    TranscriptView(document: followUps)
                }
                Composer(engine: engine, thread: thread)
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
            }
            .frame(minWidth: 380, maxWidth: showPane ? 600 : .infinity)
            if showPane {
                DebatePane(debate: debate, draft: shown, thread: thread, version: $version, comparing: $comparing)
                    .frame(maxWidth: .infinity)
                    .sidePanel(background: .dsCard)
            }
        }
        .task(id: thread.revision) { await refreshFollowUps() }
        .onChange(of: debate.drafts.count) { _, _ in version = nil; comparing = false }
    }

    private func open(_ target: Int, compare: Bool) {
        version = target
        comparing = compare
    }

    private func refreshFollowUps() async {
        guard debate.status != .running else {
            if !followUpItems.isEmpty { followUpItems = [] }
            return
        }
        let items = thread.document.items
        guard let end = items.lastIndex(where: { if case .debate(let d) = $0 { d.event == .result } else { false } }) else { return }
        let after = Array(items[(end + 1)...])
        guard after != followUpItems, let state = thread.state else { return }
        followUpItems = after
        await followUps.load(Snapshot(ref: thread.ref, items: after, state: state))
        followUps.scrollToLatest()
    }
}

// MARK: Story: what happened, one grey line per round

private struct DebateStory: View {
    let thread: ThreadModel
    let debate: DebateState
    let shown: Int?
    let panes: Bool
    let open: (Int, Bool) -> Void
    @State private var expanded: Set<Int> = []

    private var author: String { debate.label(.author) }
    private var reviewer: String { debate.label(.reviewer) }

    private struct Round: Identifiable {
        let id: Int
        var title: String
        var trailing = ""
        var objections: [DebateState.Objection] = []
        var from: Int?
        var to: Int?
        var working = false
    }

    /// "1 Opus wrote v1", "2 DeepSeek raised 5 objections, Opus accepted 4 → v2", "4 DeepSeek approved v4 · agreed".
    private var rounds: [Round] {
        var out: [Round] = []
        var previous: DebateState.Draft?
        for draft in debate.drafts {
            if let before = previous {
                let raised = debate.objections.filter { $0.round >= before.round && $0.round < draft.round }
                let accepted = raised.filter { $0.status != .open }.count
                let title = raised.isEmpty ? "\(author) revised the draft" : "\(reviewer) raised \(Self.count(raised.count)), \(author) accepted \(accepted == raised.count && raised.count == 2 ? "both" : "\(accepted)")"
                out.append(Round(id: out.count + 1, title: title, trailing: "→ v\(draft.version)", objections: raised, from: before.version, to: draft.version))
            } else {
                out.append(Round(id: out.count + 1, title: "\(author) wrote v\(draft.version)"))
            }
            previous = draft
        }
        let last = previous
        let pending = debate.objections.filter { o in last.map { o.round >= $0.round } ?? true }
        switch debate.status {
        case .agreed:
            out.append(Round(id: out.count + 1, title: "\(reviewer) approved v\(last?.version ?? 1)", trailing: "agreed", objections: pending))
        case .running:
            let openNow = pending.filter { $0.status == .open }
            if !openNow.isEmpty, debate.turn == .author {
                out.append(Round(id: out.count + 1, title: "\(reviewer) raised \(Self.count(openNow.count))", objections: openNow))
            }
            let working: String = switch debate.turn {
            case .reviewer?: "\(reviewer) is reviewing v\(last?.version ?? 1)"
            case .author?: "\(author) is writing v\((last?.version ?? 0) + 1)"
            case nil: "Starting…"
            }
            out.append(Round(id: out.count + 1, title: working, working: true))
        case .noAgreement:
            out.append(Round(id: out.count + 1, title: "No agreement after \(debate.round) rounds", objections: pending))
        case .stopped:
            out.append(Round(id: out.count + 1, title: "Stopped in round \(debate.round)", objections: pending))
        }
        return out
    }

    private static func count(_ n: Int) -> String { n == 1 ? "1 objection" : "\(n) objections" }

    var body: some View {
        let _ = thread.revision
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    bubble(debate.goal).padding(.bottom, 14)
                    Text("\(author) writes · \(reviewer) reviews · up to \(debate.maxRounds) rounds").font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(.bottom, 8)
                    let all = rounds
                    ForEach(all) { round in row(round, isLast: round.id == all.last?.id) }
                    if debate.status == .running, let activity { 
                        Text(activity).font(.system(size: 13)).foregroundStyle(Color.dsFg3).lineLimit(1).padding(.leading, 32).padding(.top, 2)
                    }
                    ForEach(notes, id: \.self) { note in bubble(note).padding(.top, 12) }
                    if debate.status != .running { closing.padding(.top, 16) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: debate.round) { _, _ in withAnimation { proxy.scrollTo("end") } }
        }
    }

    private func bubble(_ text: String) -> some View {
        Text(text).font(.system(size: 14.5)).lineSpacing(3).foregroundStyle(Color.dsFg).textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.dsBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
    }

    private func row(_ round: Round, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded.contains(round.id) { expanded.remove(round.id) } else { expanded.insert(round.id) }
            } label: {
                HStack(spacing: 0) {
                    Text("\(round.id)").frame(width: 32, alignment: .leading).foregroundStyle(Color.dsFg3).monospacedDigit()
                    Text(round.title).foregroundStyle(isLast ? Color.dsFg : Color.dsFg2).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 12)
                    if round.working { RunningRing() }
                    if !round.trailing.isEmpty { Text(round.trailing).foregroundStyle(Color.dsFg3).padding(.trailing, 8) }
                    if !round.objections.isEmpty {
                        Image(systemName: expanded.contains(round.id) ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Color.dsFg3)
                    }
                }
                .font(.system(size: 13))
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.contains(round.id) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(round.objections) { objection($0) }
                    if let from = round.from, let to = round.to {
                        Button("See changes from v\(from) to v\(to)") { open(to, true) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.leading, 16).padding(.vertical, 8)
                .overlay(alignment: .leading) { Rectangle().fill(Color.dsLine).frame(width: 1.5) }
                .padding(.leading, 32).padding(.bottom, 6)
            }
        }
    }

    private func objection(_ o: DebateState.Objection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(o.text).font(.system(size: 13)).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text(verdict(o)).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Accepted · what changed", "Rejected · Opus: why not", "Open".
    private func verdict(_ o: DebateState.Objection) -> String {
        let note = o.history.last { $0.note != nil }?.note
        switch o.status {
        case .resolved: return note.map { "Accepted · \($0)" } ?? "Accepted"
        case .withdrawn: return note.map { "Withdrawn · \($0)" } ?? "Withdrawn"
        case .open: return o.pushback.map { "Rejected · \(author): \($0)" } ?? "Open\(o.severity == .blocking ? " · blocking" : "")"
        }
    }

    /// What the working model is doing, from its running steps.
    private var activity: String? {
        for item in thread.document.items.reversed() {
            if case .steps(let s) = item { return s.tools.contains { $0.status == .running } ? TranscriptText.activity(s) : nil }
            if case .debate = item { return nil }
        }
        return nil
    }

    /// Notes you sent while it ran: every message of yours after the goal, up to the result.
    private var notes: [String] {
        var out: [String] = []
        var first = true
        for item in thread.document.items {
            if case .debate(let d) = item, d.event == .result { break }
            if case .user(let u) = item {
                if first { first = false } else { out.append(u.text) }
            }
        }
        return out
    }

    @ViewBuilder private var closing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(closingLine).font(.system(size: 14.5)).lineSpacing(3).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let draft = debate.drafts.last { artifactCard(draft) }
            if debate.status != .agreed {
                Button("Keep going") { Task { await thread.continueDebate() } }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.accentColor)
                    .help("Add as many rounds again as it started with")
            }
        }
    }

    private var closingLine: String {
        let open = debate.objections.filter { $0.status == .open }.count
        switch debate.status {
        case .agreed: return "Both models agreed on v\(debate.drafts.last?.version ?? 1)."
        case .noAgreement: return "They didn't agree after \(debate.round) rounds. \(open == 1 ? "1 objection is" : "\(open) objections are") still open; v\(debate.drafts.last?.version ?? 1) is the latest draft."
        default: return debate.drafts.isEmpty ? "Stopped before the first draft." : "Stopped. v\(debate.drafts.last?.version ?? 1) is the latest draft."
        }
    }

    private func artifactCard(_ draft: DebateState.Draft) -> some View {
        let showing = panes && shown == draft.version
        return Button { open(draft.version, false) } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").font(.system(size: 18, weight: .light)).foregroundStyle(Color.dsFg3)
                    .frame(width: 32, height: 38)
                    .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.dsLine, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg).lineLimit(1)
                    Text("Draft · v\(draft.version) · \(draft.words) words").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                }
                Spacer()
                Text(showing ? "Showing" : "Open").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(showing ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension DebateState.Draft {
    /// The document's first heading, or its first words.
    var title: String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let heading = lines.first(where: { $0.hasPrefix("#") }) { return heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
        return lines.first.map { String($0.prefix(60)) } ?? "Draft"
    }

    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

// MARK: Pane: the document, always rendered

private struct DebatePane: View {
    let debate: DebateState
    let draft: DebateState.Draft?
    let thread: ThreadModel
    @Binding var version: Int?
    @Binding var comparing: Bool
    @State private var document = TranscriptDocument(versions: false)
    @State private var loaded: Int?

    private var latest: Int? { debate.drafts.last?.version }
    private var previous: DebateState.Draft? { draft.flatMap { d in debate.drafts.last { $0.version < d.version } } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            if let draft {
                if let latest, draft.version != latest, !comparing { banner(draft, latest: latest) }
                if comparing, let previous {
                    DebateChanges(debate: debate, before: previous, after: draft)
                } else {
                    TranscriptView(document: document)
                        .onAppear { show(draft, force: true) }
                        .onChange(of: draft.version) { _, _ in show(draft) }
                }
            } else {
                Text(debate.status == .running ? "The first draft is on its way." : "No draft was written.")
                    .font(.system(size: 13)).foregroundStyle(Color.dsFg3).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            document.bottomInset = 32
            document.onAction = { action in if case .quote(let text) = action { thread.draft = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n" } }
        }
    }

    private func show(_ draft: DebateState.Draft, force: Bool = false) {
        guard force || loaded != draft.version else { return }
        loaded = draft.version
        document.showDocument(draft.text)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 2) {
            if comparing, let draft, let previous {
                Text(draft.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                Text("Changes from v\(previous.version) to v\(draft.version) · round \(draft.round)").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).lineLimit(1).padding(.leading, 8)
                Spacer(minLength: 12)
                Button("Done") { comparing = false }.buttonStyle(PillStyle(kind: .toolbar))
            } else {
                VStack(spacing: 0) {
                    Spacer()
                    Text(draft?.title ?? "Draft").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                    Spacer()
                    Rectangle().fill(Color.dsFg).frame(height: 1.5)
                }
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                ForEach(debate.drafts) { d in
                    Button("v\(d.version)") { version = d.version }
                        .buttonStyle(SelectorStyle(active: draft?.version == d.version))
                        .font(.system(size: 12.5)).foregroundStyle(draft?.version == d.version ? Color.dsFg : Color.dsFg2)
                }
                if draft != nil {
                    Rectangle().fill(Color.dsLine).frame(width: 0.5, height: 16).padding(.horizontal, 8)
                    if previous != nil { Button("Changes") { comparing = true }.buttonStyle(PillStyle(kind: .toolbar)) }
                    Button("Copy") { copy() }.buttonStyle(PillStyle(kind: .toolbar))
                    Button("Export") { export() }.buttonStyle(PillStyle(kind: .toolbar))
                }
            }
        }
        .padding(.leading, 20).padding(.trailing, 12)
        .frame(height: 48)
    }

    private func banner(_ draft: DebateState.Draft, latest: Int) -> some View {
        HStack(spacing: 6) {
            Text("Viewing v\(draft.version), written in round \(draft.round). \(debate.status == .agreed ? "The agreed version is" : "The latest is") v\(latest).").foregroundStyle(Color.dsFg2)
            Button("Show v\(latest)") { version = nil }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            Spacer()
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 20).frame(height: 34)
        .background(Color.dsTrack)
    }

    private func copy() {
        guard let draft else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft.text, forType: .string)
    }

    private func export() {
        guard let draft else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(draft.title).md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try draft.text.write(to: url, atomically: true, encoding: .utf8) } catch { NSSound.beep() }
    }
}

// MARK: Changes (12c): inline on the document

private struct DebateChanges: View {
    let debate: DebateState
    let before: DebateState.Draft
    let after: DebateState.Draft

    /// The objections this version answered, the reason for its changes. The engine records them per version, not per
    /// sentence, so they sit above the document rather than beside each change.
    private var reasons: [DebateState.Objection] {
        debate.objections.filter { $0.round >= before.round && $0.round < after.round }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !reasons.isEmpty || !after.changes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(reasons) { o in
                            Text("\(debate.label(.reviewer)), round \(o.round): “\(o.text)” \(o.status == .open ? "Rejected" : "Accepted").")
                        }
                        ForEach(Array(after.changes.enumerated()), id: \.offset) { _, change in Text(change) }
                    }
                    .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.dsLine).frame(width: 1.5) }
                }
                ForEach(Array(ProseDiff.paragraphs(before.text, after.text).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 40).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Two versions of a document as styled paragraphs: removed text struck through in grey, added text on a faint tint.
enum ProseDiff {
    static func paragraphs(_ before: String, _ after: String) -> [AttributedString] {
        let a = split(before), b = split(after)
        var out: [AttributedString] = []
        var removed: [String] = []
        for op in LineDiff.diff(a, b) {
            switch op.kind {
            case .removed: removed.append(op.text)
            case .added:
                if removed.isEmpty { out.append(styled(op.text, .added)) }
                else { out.append(words(removed.removeFirst(), op.text)) }
            case .same:
                out += removed.map { styled($0, .removed) }
                removed = []
                out.append(styled(op.text, .same))
            }
        }
        out += removed.map { styled($0, .removed) }
        return out
    }

    private static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A changed paragraph: word by word.
    private static func words(_ before: String, _ after: String) -> AttributedString {
        var out = AttributedString()
        let ops = LineDiff.diff(before.components(separatedBy: " "), after.components(separatedBy: " "))
        for (i, op) in ops.enumerated() { out += run(op.text + (i == ops.count - 1 ? "" : " "), op.kind, font: font(after)) }
        return out
    }

    private static func styled(_ line: String, _ kind: LineDiff.Kind) -> AttributedString {
        run(clean(line), kind, font: font(line))
    }

    private static func font(_ line: String) -> Font {
        if line.hasPrefix("# ") { return .system(size: 24, weight: .bold) }
        if line.hasPrefix("## ") { return .system(size: 17, weight: .semibold) }
        if line.hasPrefix("#") { return .system(size: 15, weight: .semibold) }
        return .system(size: 14.5)
    }

    private static func clean(_ line: String) -> String {
        var s = line
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") || s.hasPrefix("* ") { s = "· " + s.dropFirst(2) }
        return s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    private static func run(_ text: String, _ kind: LineDiff.Kind, font: Font) -> AttributedString {
        var r = AttributedString(clean(text) + (text.hasSuffix(" ") ? " " : ""))
        r.font = font
        switch kind {
        case .same: r.foregroundColor = .dsFg
        case .added:
            r.foregroundColor = .dsFg
            r.backgroundColor = Color(nsColor: DS.addbg)
        case .removed:
            r.foregroundColor = .dsFg3
            r.strikethroughStyle = .single
        }
        return r
    }
}

/// A diff by longest common subsequence (drafts are a page or two).
enum LineDiff {
    enum Kind { case same, added, removed }
    struct Line { var kind: Kind; var text: String }

    static func diff(_ a: [String], _ b: [String]) -> [Line] {
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
            else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] { out.append(Line(kind: .removed, text: a[i])); i += 1 }
            else { out.append(Line(kind: .added, text: b[j])); j += 1 }
        }
        return out
    }
}
