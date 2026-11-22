import PiopioKit
import PiopioTranscript
import SwiftUI

// Side conversations (docs/spec/24 §6): in a side conversation, the "Started from <parent> ›" bar; in its parent, their
// lines in the transcript (a grey line each that says where it stands, a card only for what needs you: a proposal, a
// side waiting on an approval), whose links act here; and the offer
// card's answers, with "Always start" after three New conversation in a row.

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

/// The side links in the transcript (docs/spec/24 §1, §6): an offer's New conversation (it starts beside this one; you
/// stay here) or Do it here, a proposal's Start or Dismiss, a side's title (opens it) and its branch's Merge or
/// Discard. It also tells the transcript where each side stands. After three New in a row, "Always start these?" (SCQ3)
/// sets Settings › Chat.
struct SideOffers: ViewModifier {
    let engine: EngineController
    let ref: ContainerRef
    let document: TranscriptDocument
    @State private var askAlways = false
    @State private var error: String?

    private var sides: [SideInfo] {
        engine.sides(of: ref.id).map { s in
            SideInfo(id: s.ref.id, title: s.title, state: s.side?.state ?? "working", line: s.side?.line, branch: s.worktree?.branch,
                     finished: s.worktree?.finished?.rawValue, from: s.side?.from)
        }
    }

    /// Open proposals and when each expires (the card says "until 24 Nov").
    private var openProposals: [String: Date] {
        let me = (engine.buildSessions + engine.threads).first { $0.ref.id == ref.id }
        var open: [String: Date] = [:]
        for p in me?.sideProposals ?? [] {
            let expires = SideOffers.iso.date(from: p.expiresAt) ?? .distantFuture
            if expires > Date() { open[p.id] = expires }
        }
        return open
    }

    func body(content: Content) -> some View {
        let sides = sides, proposals = openProposals
        content
            .onChange(of: sides, initial: true) { _, now in document.setSides(now, openProposals: proposals) }
            .onChange(of: proposals) { _, now in document.setSides(sides, openProposals: now) }
            // Automation cards (docs/spec/27): one that's gone reads "Removed".
            .onChange(of: engine.automationsGeneration, initial: true) { _, _ in document.setAutomations(Set(engine.automations.map(\.id))) }
            .onReceive(NotificationCenter.default.publisher(for: .transcriptOffer)) { note in
                guard note.object as? String == ref.id, let kind = note.userInfo?["kind"] as? String, kind.hasPrefix("side-"),
                      let id = note.userInfo?["call"] as? String else { return }
                take(kind, id)
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

    private func take(_ kind: String, _ id: String) {
        switch kind {
        case SideActionKind.open:
            openConversation(engine, id)
        case SideActionKind.merge, SideActionKind.discard:
            guard let side = engine.sides(of: ref.id).first(where: { $0.ref.id == id }) else { return }
            run { try await engine.finish(side.ref, kind == SideActionKind.merge ? .merge : .discard) }
        default:
            let choice = switch kind {
            case "side-new": "new"
            case SideActionKind.start: "start"
            case SideActionKind.dismiss: "dismiss"
            default: "here"
            }
            run {
                let result = try await engine.answerSide(ref, id: id, choice: choice)
                if result.askAlways == true { askAlways = true }
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await work() } catch { self.error = (error as? EngineError)?.message ?? error.localizedDescription }
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
