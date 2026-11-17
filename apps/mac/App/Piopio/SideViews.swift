import PiopioKit
import SwiftUI

// Side conversations (docs/spec/24 §6): in a side conversation, the "Started from <parent> ›" bar; in its parent, a
// block above the composer with each one's state and what it's doing, which opens it, a finished one's Merge and
// Discard when it worked on its own branch, and Piopio's proposals with Start and Dismiss; and the offer card's
// answers, with "Always start" after three New conversation in a row.

/// Opens a conversation by id: a project's (a session) or one without a project (a chat).
@MainActor func openConversation(_ engine: EngineController, _ id: String) {
    let item: SidebarItem = engine.threads.contains { $0.ref.id == id } ? .chat(id) : .session(id)
    NotificationCenter.default.post(name: .selectItem, object: item.raw)
}

/// "Started from Agent page redesign ›" (docs/spec/24 §1.4): the same bar as Continued in.
struct SideStartedBar: View {
    let engine: EngineController
    let side: SessionSummary.Side

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.up.left").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
            Text("Started from").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
            Button { openConversation(engine, side.parent.id) } label: {
                HStack(spacing: 3) {
                    Text(side.parent.title).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            }
            .buttonStyle(.plain)
            .help("Open the conversation this one was started from")
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.dsChip.opacity(0.5))
    }
}

/// A conversation's side conversations, above its composer: a row each with a dot, its title and a live line.
struct SideConversations: View {
    let engine: EngineController
    let parentId: String
    @State private var open = true
    @State private var error: String?

    private var proposals: [SessionSummary.SideProposal] {
        let me = (engine.buildSessions + engine.threads).first { $0.ref.id == parentId }
        return (me?.sideProposals ?? []).filter { (Self.iso.date(from: $0.expiresAt) ?? .distantFuture) > Date() }
    }

    var body: some View {
        let sides = engine.sides(of: parentId)
        let proposals = proposals
        if !sides.isEmpty || !proposals.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dsFg3)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Text("Side conversations").font(.system(size: 12.5, weight: .semibold))
                        Text([sides.isEmpty ? nil : Self.summary(sides), proposals.isEmpty ? nil : "\(proposals.count) proposed"].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sides, id: \.ref.id) { row($0) }
                        ForEach(proposals) { proposal($0) }
                    }
                    .padding(.bottom, 6)
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsWarn).padding(.horizontal, 12).padding(.bottom, 8) }
                }
            }
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            .frame(maxWidth: 680)
        }
    }

    private func row(_ s: SessionSummary) -> some View {
        let state = s.side?.state ?? "working"
        let (word, color) = Self.state(state)
        let unmerged = state == "done" && s.worktree != nil && s.worktree?.finished == nil
        return HStack(spacing: 10) {
            Button { openConversation(engine, s.ref.id) } label: {
                HStack(spacing: 10) {
                    if state == "working" { ProgressView().controlSize(.mini).frame(width: 7, height: 7) } else { Circle().fill(color).frame(width: 7, height: 7) }
                    Text(s.title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                    Text(state == "working" ? (s.side?.line ?? word) : word).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                    Spacer(minLength: 8)
                    if let branch = s.worktree?.branch { Text(s.worktree?.finished.map { "\(branch) · \($0.rawValue)" } ?? branch).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open it")
            if unmerged {
                Button("Merge") { finish(s, .merge) }.buttonStyle(PillStyle(kind: .primary, compact: true))
                    .help("Merge \(s.worktree?.branch ?? "its branch") into \(s.worktree?.base ?? "the base branch")")
                Button("Discard") { finish(s, .discard) }.buttonStyle(PillStyle(compact: true))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    /// "Proposed · Fix the same clipping in the team page · until 24 Nov", its reason, Start and Dismiss (§6).
    private func proposal(_ p: SessionSummary.SideProposal) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().strokeBorder(Color.dsFg3, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Proposed").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                    Text(p.title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                    if let project = p.project { Text("in \(project)").font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
                }
                Text([p.why, Self.iso.date(from: p.expiresAt).map { "until \($0.formatted(.dateTime.day().month(.abbreviated)))" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Start") { answer(p.id, "start") }.buttonStyle(PillStyle(kind: .primary, compact: true))
            Button("Dismiss") { answer(p.id, "dismiss") }.buttonStyle(PillStyle(compact: true))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func answer(_ id: String, _ choice: String) {
        guard let ref = (engine.buildSessions + engine.threads).first(where: { $0.ref.id == parentId })?.ref else { return }
        Task {
            do { try await engine.answerSide(ref, id: id, choice: choice); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func finish(_ s: SessionSummary, _ action: FinishParams.Action) {
        Task {
            do { try await engine.finish(s.ref, action); error = nil } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    /// "2 · 1 working, 1 done".
    static func summary(_ sides: [SessionSummary]) -> String {
        var counts: [(String, Int)] = []
        for s in sides {
            let word = state(s.side?.state ?? "working").0
            if let i = counts.firstIndex(where: { $0.0 == word }) { counts[i].1 += 1 } else { counts.append((word, 1)) }
        }
        return "\(sides.count) · " + counts.map { "\($0.1) \($0.0)" }.joined(separator: ", ")
    }

    /// A side conversation's state as a word and its dot (§6: grey queued, working, amber needs you, green done, red failed).
    static func state(_ state: String) -> (String, Color) {
        switch state {
        case "queued": ("queued", Color.dsFg3)
        case "working": ("working", Color.accentColor)
        case "needs_you": ("needs you", Color.dsWarn)
        case "done": ("done", Color.dsGreen)
        case "failed": ("failed", Color.dsRed)
        default: ("stopped", Color.dsFg3)
        }
    }
}

/// The offer card's answers (docs/spec/24 §1): New conversation starts it beside this one (you stay here), Do it here
/// tells Piopio so. After three New in a row, "Always start these?" (SCQ3) sets Settings › Chat.
struct SideOffers: ViewModifier {
    let engine: EngineController
    let ref: ContainerRef
    @State private var askAlways = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .transcriptOffer)) { note in
                guard note.object as? String == ref.id, let kind = note.userInfo?["kind"] as? String, kind.hasPrefix("side-"),
                      let call = note.userInfo?["call"] as? String else { return }
                Task {
                    do {
                        let result = try await engine.answerSide(ref, id: call, choice: kind == "side-new" ? "new" : "here")
                        if result.askAlways == true { askAlways = true }
                    } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
                }
            }
            .alert("Start these on their own?", isPresented: $askAlways) {
                Button("Always start") { Task { await engine.updateSettings(SettingsPatch(chat: .init(sideOnUnrelated: "start"))) } }
                Button("Keep asking", role: .cancel) {}
            } message: {
                Text("You chose New conversation three times in a row. Piopio can start a side conversation for something unrelated without asking. Settings › Chat changes it back.")
            }
            .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            }
    }
}
