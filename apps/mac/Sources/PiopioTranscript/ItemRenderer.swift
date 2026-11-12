import AppKit
import PiopioKit

/// Moves an NSAttributedString across isolation domains (immutable once built).
struct SendableText: @unchecked Sendable { let value: NSAttributedString }

/// Renders timeline items to attributed text in the design's transcript style (docs/design 2a, 8a, 8d, 8e).
/// Thread-safe: windows are built off the main thread. Every rendered item ends with a paragraph break
/// (or is empty), so items never share a paragraph.
nonisolated struct ItemRenderer: Sendable {
    /// Compact (Quick Chat): your messages and the action footers are not shown; answers stand alone.
    var compact = false
    /// Edit, Regenerate and Fork make new versions (threads).
    var versions = true
    /// Build sessions (docs/design chat v3): Edit and Retry rewind the conversation, Fork makes a new session, and
    /// your messages offer "Rewind to here".
    var build = false
    /// The project folder: paths inside it show relative, as chips (the full path in their tooltip).
    var root: String?
    /// Answers with more text after them in the same turn: no action row under them (only the turn's last text has one).
    var midTurn: Set<String> = []

    /// A standalone document (a debate's artifact): larger headings.
    var prose = false
    /// Answers 15 / 1.6 (chat v3); Quick Chat keeps the compact 13.5.
    private var bodySize: CGFloat { compact ? DS.transcriptSize : 15 }
    private var body: NSFont { .systemFont(ofSize: bodySize) }
    private var mono: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    private var small: NSFont { .systemFont(ofSize: 12) }
    /// SF line height is ~1.2× its size; this gives the design's 1.6.
    private static let lineHeight: CGFloat = DS.transcriptLineHeight / 1.2

    func render(_ items: some Sequence<TimelineItem>) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for item in items { out.append(render(item)) }
        return out
    }

    func render(_ item: TimelineItem) -> NSAttributedString {
        switch item {
        case .user(let u) where u.text.hasPrefix("[Board] ") || u.text.hasPrefix("[Routine] "):
            // A board update or a routine firing (docs/spec/20 §4): an event, not something you wrote. Its first line
            // shows; the report opens under it.
            if compact { return NSAttributedString() }
            let routine = u.text.hasPrefix("[Routine] ")
            let text = String(u.text.dropFirst(routine ? 10 : 8))
            // The plan block above the composer shows each task's state (docs/spec/21 AD9): only what's notable stays a
            // line here, a task sent back or blocked.
            if !routine, !Self.notable(text) { return NSAttributedString() }
            let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
            let rest = text.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (routine ? "Routine · " : "Board · ") + first
            if rest.isEmpty { return note(title) }
            return thinkingCard(DisclosureCard(kind: .thinking, title: title, body: rest))
        case .user(let u):
            if compact { return NSAttributedString() }
            let out = NSMutableAttributedString()
            if let files = u.attachments, !files.isEmpty { out.append(fileChips(files)) }
            out.append(bubble(u.text))
            out.append(userFooter(u))
            return out
        case .assistant(let a):
            let out = NSMutableAttributedString()
            if let speaker = a.speaker { out.append(speakerLine(speaker)) }
            let thinking = a.parts.filter { $0.type == .thinking }.map(\.text).joined()
            if !thinking.isEmpty { out.append(thinkingCard(DisclosureCard(kind: .thinking, title: Self.thought(a.thinkingMs), detail: "", body: thinking))) }
            // A new agent's greeting (docs/spec/19 S2) reads as its first message, with no label.
            // A run's message follows its run line (docs/spec/21 D3), which says so; others are marked here.
            if let o = a.outbound, o.from != "greeting", !o.from.hasPrefix("run_") { out.append(note("Sent on its own" + (Self.date(a.at).map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))) }
            for block in MarkdownStream(text: a.text).blocks { out.append(render(block)) }
            out.append(statusCard(a))
            if a.status != .streaming, !compact, !midTurn.contains(a.id) { out.append(answerFooter(a)) }
            return out
        case .tool(let t) where t.tool == "ask_user":
            return questionCard(t)
        case .tool(let t) where t.tool == "ask_owner":
            // A new agent's question (docs/spec/21 D4): it reads as its message; its answers to tap are above the composer.
            let out = NSMutableAttributedString()
            if case .number(let n)? = t.args?["number"] { out.append(note("Question \(Int(n)) of 3")) }
            for block in MarkdownStream(text: t.args?["question"]?.stringValue ?? "").blocks { out.append(render(block)) }
            return out
        case .tool(let t) where t.tool == "ask_agent":
            return agentAnswer(t)
        case .tool(let t) where t.tool == "propose_plan":
            return attachmentParagraph(DisclosureAttachment(card: DisclosureCard(plan: Self.planContent(t))))
        case .tool(let t) where t.tool == "present_files" && t.status == .done:
            // Files the agent handed over: a card per file that opens it (piopio-present).
            guard case .files(let files)? = t.typedDetails, !files.isEmpty else { return attachmentParagraph(DisclosureAttachment(card: Self.toolCard(t, root: root))) }
            let out = NSMutableAttributedString()
            for file in files { out.append(attachmentParagraph(FileCardAttachment(model: FileCardModel(file: file, shownPath: Self.relative(file.path, root: root))), spacing: 8)) }
            return out
        case .tool(let t):
            return attachmentParagraph(DisclosureAttachment(card: Self.toolCard(t, root: root)))
        case .system(let s) where s.run != nil:
            // A run (docs/spec/21 D3, design 2a): one quiet line, "Today 8:00 · Automatic run · nothing new"; it opens to
            // its last answer, and "Open" shows the run's own conversation.
            let run = s.run!
            let when = Self.date(s.at).map { Self.dayAndTime($0) } ?? ""
            let title = when.isEmpty ? s.text : "\(when) · \(s.text)"
            guard let summary = run.summary, !summary.isEmpty, run.status != "running" else { return note(title, dot: run.status == "failed" ? DS.amber : nil) }
            let card = DisclosureCard(kind: .thinking, title: title, body: summary)
            card.action = ("Open", .openSession("run:\(run.id)"))
            card.failed = run.status == "failed"
            return thinkingCard(card)
        case .system(let s):
            if s.level == .error { return errorCard(title: s.text, safe: "Nothing was lost.", actions: []) }
            return note(s.text)
        case .compaction:
            return note("Context compacted: older messages were summarized", dot: DS.fg3)
        case .checkpoint:
            // Saved silently before every message (chat v3, 14b): rewinding is an action on your message.
            return NSAttributedString()
        case .routing(let r):
            return routingCard(r)
        case .memory(let m):
            return memoryNote(m)
        case .steps(let s):
            return attachmentParagraph(DisclosureAttachment(card: Self.stepsCard(s, root: root)))
        case .approval(let a):
            return approvalCard(a)
        case .result(let r):
            return resultCard(r)
        case .agentMsg(let m):
            return agentMessage(m)
        case .debate(let d):
            return debateItem(d)
        }
    }

    // MARK: Debate (docs/spec/16-debate §5)

    static func speakerColor(_ role: DebateRole) -> NSColor { role == .author ? DS.debateAuthor : DS.debateReviewer }

    /// Above a debate answer: who wrote it, in that side's color.
    private func speakerLine(_ s: Speaker) -> NSAttributedString {
        let m = NSMutableAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: Self.speakerColor(s.role), .baselineOffset: 1.5])
        m.append(NSAttributedString(string: s.label, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: DS.fg]))
        m.append(NSAttributedString(string: "  ·  \(s.role == .author ? "author" : "reviewer")", attributes: [.font: small, .foregroundColor: DS.fg3]))
        return line(m, paragraph(spacing: 4, before: 6))
    }

    private func debateItem(_ d: DebateItem) -> NSAttributedString {
        switch d.event {
        case .round:
            // A centered label between hairlines, like the checkpoint divider.
            let p = paragraph(spacing: 12, before: 14)
            p.alignment = .center
            let label = NSAttributedString(string: d.title.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: DS.fg3, .kern: 0.8])
            let out = NSMutableAttributedString(attributedString: line(label, p))
            out.addAttribute(.piopioCard, value: CardStyle.divider.rawValue, range: NSRange(location: 0, length: out.length))
            return out
        case .turn:
            // What the turn did, quietly: "● Draft v2 · 3 changes", then each change, pushback or objection.
            let color = d.speaker.map { Self.speakerColor($0.role) } ?? DS.fg3
            let m = NSMutableAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: color, .baselineOffset: 1.5])
            if let s = d.speaker { m.append(NSAttributedString(string: "\(s.label)  ", attributes: [.font: small, .foregroundColor: DS.fg3])) }
            m.append(NSAttributedString(string: d.title, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: DS.fg2]))
            for text in d.lines ?? [] {
                m.append(NSAttributedString(string: lineSeparator + "    " + text, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: DS.fg2]))
            }
            return line(m, paragraph(spacing: 14, before: 2, indent: 0, head: 20))
        case .result:
            return debateResult(d)
        }
    }

    /// How a debate ended (agreed, no agreement, stopped), what's still open, the final draft, and its actions.
    private func debateResult(_ d: DebateItem) -> NSAttributedString {
        let (mark, color): (String, NSColor) = switch d.status {
        case .agreed?: ("✓", DS.fg2)
        case .noAgreement?: ("≠", DS.fg2)
        default: ("■", DS.fg3)
        }
        let m = NSMutableAttributedString(string: "\(mark)  ", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: color])
        m.append(NSAttributedString(string: d.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: DS.fg]))
        if let cost = d.costUsd, cost > 0 {
            m.append(NSAttributedString(string: "  ·  " + (cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)), attributes: [.font: small, .foregroundColor: DS.fg3]))
        }
        for text in d.lines ?? [] {
            m.append(NSAttributedString(string: lineSeparator + text, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: DS.fg2]))
        }
        if let open = d.open, !open.isEmpty {
            m.append(NSAttributedString(string: lineSeparator + "Still open:", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: DS.fg2]))
            for o in open {
                m.append(NSAttributedString(string: lineSeparator + "•  \(o.text)" + (o.severity == .blocking ? "  (blocking)" : ""), attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: DS.fg]))
                if let pushback = o.pushback {
                    m.append(NSAttributedString(string: lineSeparator + "    Author: \(pushback)", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: DS.fg3]))
                }
            }
        }
        if !compact {
            m.append(NSAttributedString(string: lineSeparator, attributes: [.font: small]))
            if d.draft != nil { m.append(pill("Copy draft", .copyDraft(itemId: d.id), d.status == .agreed ? .primary : .secondary)) }
            if d.status != .agreed {
                m.append(NSAttributedString(string: "  ", attributes: [.font: small]))
                m.append(pill("Keep going", .continueDebate, .primary))
            }
        }
        let out = NSMutableAttributedString(attributedString: card(m, .approval, lineHeight: 1.5))
        if let draft = d.draft {
            // The deliverable itself, as the answer would show it.
            out.append(line(NSAttributedString(string: d.status == .agreed ? "Final draft" : "Latest draft", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: DS.fg3, .kern: 0.4]), paragraph(spacing: 6, before: 4)))
            for block in MarkdownStream(text: draft).blocks { out.append(render(block)) }
        }
        return out
    }

    /// An agent asks before acting (06-agents §9 AS1, docs/design 2a): what it wants to do, Deny / Edit… / Approve.
    /// Once answered, one line says how.
    private func approvalCard(_ a: ApprovalItem) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let state: String = switch a.status {
        case .pending: ""
        case .approved: a.editedArgs == nil ? "Allowed" : "Allowed with your changes"
        case .denied: a.reason.map { "Denied (\($0))" } ?? "Denied"
        case .expired: "No answer in 24 hours, not done"
        case .cancelled: "Cancelled"
        }
        if a.status != .pending { return note("\(state) · \(a.title)") }
        m.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: DS.accent, .baselineOffset: 1.5]))
        m.append(NSAttributedString(string: a.title.hasSuffix("?") ? a.title : a.title + "?", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: DS.fg]))
        if !compact, a.source == "connector" {
            // A connected app's change in a chat (docs/spec/12-connectors): Deny / Allow, and "don't ask again" for plain writes.
            m.append(NSAttributedString(string: lineSeparator, attributes: [.font: small]))
            m.append(pill("Allow", .decideApproval(approvalId: a.approvalId, approve: true), .primary))
            m.append(NSAttributedString(string: "    ", attributes: [.font: small]))
            m.append(pill("Deny", .decideApproval(approvalId: a.approvalId, approve: false), .secondary))
            if !a.always.isEmpty {
                m.append(NSAttributedString(string: "  ", attributes: [.font: small]))
                m.append(pill("Allow, don't ask again", .allowAlways(approvalId: a.approvalId), .secondary))
            }
        } else if !compact {
            m.append(NSAttributedString(string: lineSeparator, attributes: [.font: small]))
            m.append(pill("Allow", .decideApproval(approvalId: a.approvalId, approve: true), .primary))
            m.append(NSAttributedString(string: "    ", attributes: [.font: small]))
            m.append(pill("Deny", .decideApproval(approvalId: a.approvalId, approve: false), .secondary))
            m.append(NSAttributedString(string: "  ", attributes: [.font: small]))
            m.append(pill("Edit…", .editApproval(approvalId: a.approvalId), .secondary))
        }
        return card(m, .approval, lineHeight: 1.6)
    }

    /// What a tool changed (06-agents §4.2 RC1): the change, and Undo while it can be undone.
    private func resultCard(_ r: ResultItem) -> NSAttributedString {
        let icon = switch r.card.kind { case "reminder": "◷"; case "message": "✉︎"; default: "✎" }
        let undone = r.undo?.status == .undone
        let m = NSMutableAttributedString(string: "\(icon)  ", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: DS.fg3])
        m.append(NSAttributedString(string: r.card.title, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: undone ? DS.fg3 : DS.fg, .strikethroughStyle: undone ? NSUnderlineStyle.single.rawValue : 0]))
        if let undo = r.undo, !compact {
            m.append(NSAttributedString(string: "   ", attributes: [.font: small]))
            switch undo.status {
            case .available: m.append(NSAttributedString(string: "Undo", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: DS.accent, .link: TranscriptAction.undoChange(undoId: undo.id).url, .toolTip: "Reverse this change (for 24 hours)"]))
            case .undone: m.append(NSAttributedString(string: "Undone", attributes: [.font: small, .foregroundColor: DS.fg3]))
            case .failed: m.append(NSAttributedString(string: "Couldn't undo", attributes: [.font: small, .foregroundColor: DS.fg3]))
            case .expired: break
            }
        }
        if let detail = r.card.detail, !detail.isEmpty {
            m.append(NSAttributedString(string: lineSeparator + detail, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: undone ? DS.fg3 : DS.fg2]))
        }
        return card(m, .link, lineHeight: 1.5)
    }

    /// A board update worth a line in the lead's conversation (AD9): a task sent back, or blocked.
    static func notable(_ boardText: String) -> Bool {
        let first = boardText.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? boardText
        return first.contains(" went back to ") || first.contains(" is blocked")
    }

    /// One of your agents, asked from a conversation (docs/spec/21 D6, design 5c-2): "Rita · joined for this message"
    /// when `@Rita` brought her in, else "Asked Rita"; her answer indented under a rule in her colour.
    private func agentAnswer(_ t: ToolItem) -> NSAttributedString {
        let agent = t.details?["agent"]
        let name = agent?["name"]?.stringValue ?? t.args?["agent"]?.stringValue ?? "Agent"
        let id = agent?["id"]?.stringValue ?? ""
        var joined = false
        if case .bool(let j)? = t.details?["joined"] { joined = j }
        let tint = id.isEmpty ? DS.fg3 : AgentPalette.color(id)
        let head = NSMutableAttributedString()
        head.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: tint, .baselineOffset: 1]))
        head.append(NSAttributedString(string: joined ? name : "Asked \(name)", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: DS.fg]))
        let state: String? = switch t.status {
        case .running, .pendingApproval: "  thinking…"
        default: joined ? "  joined for this message" : nil
        }
        if let state { head.append(NSAttributedString(string: state, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: DS.fg3])) }
        let out = NSMutableAttributedString(attributedString: line(head, paragraph(spacing: 4, before: 8)))
        let answer = (t.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.status != .running, !answer.isEmpty else { return out }
        let p = paragraph(spacing: 14, before: 2, indent: 14, tail: 0)
        let body = NSMutableAttributedString(attributedString: card(Inline.ns(answer.replacingOccurrences(of: "\n", with: lineSeparator), font: self.body, color: t.status == .error ? DS.fg2 : DS.fg), .quote, paragraphStyle: p))
        body.addAttribute(.piopioCardTint, value: tint, range: NSRange(location: 0, length: body.length))
        out.append(body)
        return out
    }

    /// A message to or from another agent (06-agents §7 AA5): who, what, the answer once it comes, and the trace.
    private func agentMessage(_ m: AgentMsgItem) -> NSAttributedString {
        let lead: String = switch (m.direction, m.mode) {
        case (.out, .ask): "Asked \(m.toAgent.name)"
        case (.out, _): "Told \(m.toAgent.name)"
        case (.in, .ask): "\(m.fromAgent.name) asks"
        case (.in, .tell): "\(m.fromAgent.name) says"
        case (.in, .reply): "\(m.fromAgent.name) answered (later)"
        }
        let (dot, state): (NSColor, String?) = switch m.status {
        case .waiting?: (DS.accent, "waiting…")
        case .failed?: (DS.fg2, "not sent")
        case .noReply?: (DS.fg3, "no answer yet")
        default: (DS.fg3, nil)
        }
        let out = NSMutableAttributedString(string: "⇄  ", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: dot])
        out.append(NSAttributedString(string: lead, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: DS.fg]))
        if let state { out.append(NSAttributedString(string: "  \(state)", attributes: [.font: small, .foregroundColor: dot])) }
        if let trace = m.traceId, !compact {
            out.append(NSAttributedString(string: "   ", attributes: [.font: small]))
            out.append(NSAttributedString(string: "Trace", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: DS.accent, .link: TranscriptAction.openTrace(traceId: trace).url, .toolTip: "Every message between agents in this exchange, with costs"]))
        }
        out.append(NSAttributedString(string: lineSeparator + m.text, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: DS.fg2]))
        if let reply = m.reply, !reply.isEmpty {
            let who = m.status == .failed ? "" : "\(m.toAgent.name): "
            out.append(NSAttributedString(string: lineSeparator + who + reply, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: m.status == .failed ? DS.fg2 : DS.fg]))
        }
        return card(out, .link, lineHeight: 1.5)
    }

    /// A turn's activity as one quiet line (chat v3, 14a): "Thought for 3s, edited RESUMEN.md +13 ›", or what's running
    /// now ("Running a command…", "Editing RESUMEN.md…"). It opens to the thought and each step's card.
    static func stepsCard(_ s: StepsItem, root: String? = nil) -> DisclosureCard {
        let running = s.tools.first { $0.status == .running }
        let waiting = s.tools.contains { $0.status == .pendingApproval }
        let card = DisclosureCard(kind: .activity, title: "", body: "")
        var nested = s.tools.map { toolCard($0, root: root) }
        if let thinking = s.thinking, !thinking.isEmpty {
            let thought = DisclosureCard(kind: .thinking, title: thought(s.thinkingMs), body: thinking.trimmingCharacters(in: .whitespacesAndNewlines))
            thought.glyph = "circle.dashed"
            nested.insert(thought, at: 0)
        }
        card.content = .cards(nested)
        card.working = running != nil
        card.waiting = waiting
        card.failed = s.tools.contains { $0.status == .error }
        if waiting {
            card.title = "Waiting for you"
        } else if let running, running.tool == "bash" {
            // Commands are often long chains ("cd … && export … && pnpm test"): the line just says one is running, and
            // opening it shows the command in full.
            card.title = "Running a command…"
        } else if let running {
            let (verb, raw) = toolTitle(running)
            card.title = relative(raw, root: root).isEmpty ? "\(verb)…" : "\(verb) \(relative(raw, root: root))…"
        } else {
            card.parts = activityParts(s, root: root)
            card.title = card.parts.map { [$0.text, $0.chip].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", ")
        }
        return card
    }

    /// "Thought for 3s" (measured live), or "Thought" for history reloaded from disk.
    static func thought(_ ms: Double?) -> String {
        guard let ms, ms >= 500 else { return "Thought" }
        let s = Int((ms / 1000).rounded())
        return s < 60 ? "Thought for \(s)s" : "Thought for \(s / 60)m \(s % 60)s"
    }

    /// The pieces of a finished activity line, in the order they happened: what it thought, read, edited (+lines),
    /// ran, and anything else (docs/design/activity).
    static func activityParts(_ s: StepsItem, root: String?) -> [ActivityPart] {
        var parts: [ActivityPart] = []
        let tools = s.tools
        if let thinking = s.thinking, !thinking.isEmpty { parts.append(ActivityPart(text: thought(s.thinkingMs).lowercased())) }
        func paths(_ kinds: Set<String>) -> [String] {
            var seen: [String] = []
            for t in tools where kinds.contains(t.tool) && t.status != .denied {
                let path = relative(t.args?["path"]?.stringValue ?? "", root: root)
                if !path.isEmpty, !seen.contains(path) { seen.append(path) }
            }
            return seen
        }
        func group(_ tool: String) -> String { ["read": "read", "edit": "edit", "write": "edit", "bash": "bash"][tool] ?? "rest" }
        var order: [String] = []
        for t in tools where t.status != .denied && !order.contains(group(t.tool)) { order.append(group(t.tool)) }
        let failedCommands = tools.filter { $0.tool == "bash" && $0.status == .error }.count
        for key in order {
            switch key {
            case "read":
                let reads = paths(["read"])
                if reads.count == 1 { parts.append(ActivityPart(text: "read", chip: reads[0], help: reads[0])) }
                else if reads.count > 1 { parts.append(ActivityPart(text: "read \(reads.count) files", help: reads.joined(separator: "\n"))) }
            case "edit":
                let edited = paths(["edit", "write"])
                let added = tools.filter { ["edit", "write"].contains($0.tool) && $0.status != .error }.reduce(0) { n, t in
                    if case .diff(_, let patch)? = t.typedDetails { n + DiffLine.parse(patch).added } else { n }
                }
                let verb = tools.contains { $0.tool == "edit" } ? "edited" : "wrote"
                if edited.count == 1 { parts.append(ActivityPart(text: verb, chip: edited[0], added: added > 0 ? added : nil, help: edited[0])) }
                else if edited.count > 1 { parts.append(ActivityPart(text: "\(verb) \(edited.count) files", added: added > 0 ? added : nil, help: edited.joined(separator: "\n"))) }
            case "bash":
                let commands = tools.filter { $0.tool == "bash" && $0.status != .denied }.count
                var text = commands == 1 ? "ran a command" : "ran \(commands) commands"
                if failedCommands > 0 { text += commands == 1 ? " (it failed)" : " (\(failedCommands) failed)" }
                parts.append(ActivityPart(text: text, warning: failedCommands > 0))
            default:
                let rest = tools.filter { group($0.tool) == "rest" && $0.status != .denied }
                parts += activitySummary(rest).map { ActivityPart(text: $0) }
            }
        }
        let denied = tools.filter { $0.status == .denied }.count
        if denied > 0 { parts.append(ActivityPart(text: denied == 1 ? "you denied 1 step" : "you denied \(denied) steps")) }
        let failed = tools.filter { $0.status == .error && $0.tool != "bash" }.count
        if failed > 0 { parts.append(ActivityPart(text: failed == 1 ? "1 step failed" : "\(failed) steps failed", warning: true)) }
        if parts.isEmpty { parts.append(ActivityPart(text: "worked")) }
        parts[0].text = parts[0].text.prefix(1).uppercased() + parts[0].text.dropFirst()
        return parts
    }

    /// A command as it reads best: without a leading `cd` into the project (where the session already is). A `cd`
    /// somewhere else is dropped too and named as `folder`.
    static func displayCommand(_ command: String, root: String?) -> (command: String, folder: String?) {
        let pattern = #"^\s*cd\s+("[^"]+"|'[^']+'|\S+)\s*(&&|;)\s*"#
        guard let match = command.range(of: pattern, options: .regularExpression) else { return (command, nil) }
        var dir = String(command[match]).replacingOccurrences(of: #"^\s*cd\s+"#, with: "", options: .regularExpression)
        dir = dir.replacingOccurrences(of: #"\s*(&&|;)\s*$"#, with: "", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let rest = String(command[match.upperBound...])
        guard !rest.isEmpty else { return (command, nil) }
        if dir == "." { return (rest, nil) }
        // /var and /private/var are the same folder: compare where both really are.
        let real = { (path: String) in URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
        if let root, real(dir) == real(root) { return (rest, nil) }
        return (rest, URL(fileURLWithPath: dir).lastPathComponent)
    }

    /// A path inside the project, relative to it ("src/app.ts"); anything else as given.
    static func relative(_ path: String, root: String?) -> String {
        guard let root, !root.isEmpty else { return path }
        if path == root { return URL(fileURLWithPath: root).lastPathComponent }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }

    /// "read README.md, package.json", "edited App.swift", "1 command", "searched the web".
    static func activitySummary(_ tools: [ToolItem]) -> [String] {
        func names(_ kind: Set<String>) -> [String] {
            var seen: [String] = []
            for t in tools where kind.contains(t.tool) {
                let path = t.args?["path"]?.stringValue ?? ""
                let name = (path as NSString).lastPathComponent
                if !name.isEmpty, !seen.contains(name) { seen.append(name) }
            }
            return seen
        }
        func list(_ verb: String, _ items: [String]) -> String? {
            guard !items.isEmpty else { return nil }
            let shown = items.prefix(3).joined(separator: ", ")
            return items.count > 3 ? "\(verb) \(shown) +\(items.count - 3)" : "\(verb) \(shown)"
        }
        var out: [String] = []
        if let r = list("read", names(["read"])) { out.append(r) }
        if let e = list("edited", names(["edit", "write"])) { out.append(e) }
        let commands = tools.filter { $0.tool == "bash" }.count
        if commands > 0 { out.append("\(commands) command\(commands == 1 ? "" : "s")") }
        let searches = tools.filter { $0.tool == "web_search" }.count
        if searches > 0 { out.append(searches == 1 ? "searched the web" : "searched the web \(searches) times") }
        let pages = tools.filter { $0.tool == "web_fetch" }.count
        if pages > 0 { out.append("read \(pages) page\(pages == 1 ? "" : "s")") }
        // Connected apps (docs/spec/12-connectors): what was done, in words.
        let apps: [(Set<String>, String, String)] = [
            (["calendar_events", "calendar_free_time"], "read your calendar", "reading your calendar"),
            (["calendar_create_event", "calendar_update_event", "calendar_delete_event"], "changed your calendar", "changing your calendar"),
            (["mail_search", "mail_read"], "read your mail", "reading your mail"),
            (["mail_draft"], "wrote a draft", "writing a draft"),
            (["mail_send"], "sent an email", "sending an email"),
        ]
        for (names, done, doing) in apps {
            let calls = tools.filter { names.contains($0.tool) }
            guard !calls.isEmpty else { continue }
            out.append(calls.contains { $0.status == .done } ? done : calls.contains { $0.status == .running || $0.status == .pendingApproval } ? doing : done)
        }
        let known = Set(["read", "edit", "write", "bash", "web_search", "web_fetch"]).union(apps.flatMap { $0.0 })
        let others = tools.filter { !known.contains($0.tool) }.count
        if others > 0 { out.append(out.isEmpty ? "\(others) step\(others == 1 ? "" : "s")" : "\(others) more") }
        return out
    }

    /// "✎ Saved 2 facts to notebook memory · Undo" (docs/design v2, 4a), or a topic's proposal with Save and Dismiss.
    /// The facts themselves show on hover.
    private func memoryNote(_ m: MemoryItem) -> NSAttributedString {
        let facts = (m.added.map { "“\($0)”" } + m.removed.map { "removed “\($0)”" }).joined(separator: ", ")
        let count = m.added.count + m.removed.count
        let n = m.removed.isEmpty ? (count == 1 ? "1 fact" : "\(count) facts") : (count == 1 ? "1 change" : "\(count) changes")
        let lead: String = switch (m.action, m.status) {
        case (_, .failed): "Memory not changed: \(m.reason ?? "the change failed")"
        case (_, .undone): "Undone: \(n) no longer in memory"
        case (.saved, _): m.removed.isEmpty ? "Saved \(n) to notebook memory" : "Updated notebook memory · \(n)"
        case (.proposed, .pending): "Suggested for memory: \(facts)"
        case (.proposed, .saved): "Saved \(n) to notebook memory"
        case (.proposed, .dismissed): "Dismissed: \(facts)"
        case (.proposed, _): "Suggested: \(facts)"
        }
        let m2 = NSMutableAttributedString(string: lead, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3, .toolTip: facts])
        if !compact {
            let link: (String, TranscriptAction) -> NSAttributedString = { title, action in
                NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg2, .link: action.url])
            }
            if m.status == .saved, let revision = m.revisionId {
                m2.append(NSAttributedString(string: " · ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3]))
                m2.append(link("undo", .undoMemory(revisionId: revision)))
            } else if m.status == .pending, let proposal = m.proposalId {
                m2.append(NSAttributedString(string: "   ", attributes: [.font: small]))
                m2.append(link("Save", .decideMemory(proposalId: proposal, accept: true)))
                m2.append(NSAttributedString(string: "   ", attributes: [.font: small]))
                m2.append(link("Dismiss", .decideMemory(proposalId: proposal, accept: false)))
            }
        }
        if let reason = m.reason, m.action == .proposed, m.status == .pending {
            m2.append(NSAttributedString(string: lineSeparator + reason, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: DS.fg3]))
        }
        return line(m2, paragraph(spacing: 14, before: 4))
    }

    /// Where the organizer sent a message (docs/design/grey 13e): one grey line under it, right-aligned like the
    /// message: "New topic: Muebles · Open · Change". The reply lives in the topic.
    private func routingCard(_ r: RoutingItem) -> NSAttributedString {
        let status: String? = switch r.status {
        case .thinking: "thinking…"
        case .replying: "replying…"
        case .needsYou: "needs you"
        case .failed: "failed"
        case .replied: nil
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: DS.fg3]
        let m = NSMutableAttributedString(string: r.decision == .create ? "New topic: " : "Sent to ", attributes: attrs)
        m.addAttribute(.toolTip, value: r.preview ?? r.reason, range: NSRange(location: 0, length: m.length))
        m.append(NSAttributedString(string: r.topicTitle, attributes: attrs))
        if let status { m.append(NSAttributedString(string: " · \(status)", attributes: attrs)) }
        if !compact, !r.topicId.isEmpty {
            m.append(NSAttributedString(string: " · ", attributes: attrs))
            m.append(NSAttributedString(string: "open", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: DS.fg2, .link: TranscriptAction.openTopic(topicId: r.topicId, itemId: r.replyItemId).url]))
            if !r.message.isEmpty, r.status != .failed {
                m.append(NSAttributedString(string: " · ", attributes: attrs))
                m.append(NSAttributedString(string: "change", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: DS.fg2, .link: TranscriptAction.wrongTopic(itemId: r.id).url, .toolTip: "Send this to another topic"]))
            }
        }
        let p = paragraph(spacing: 14, before: 2)
        p.alignment = .right
        return line(m, p)
    }

    // MARK: Messages

    /// Files sent with a message: right-aligned chips above the bubble.
    private func fileChips(_ files: [AttachmentInfo]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        for (i, f) in files.enumerated() {
            if i > 0 { m.append(NSAttributedString(string: "   ", attributes: [.font: small])) }
            // An earlier chat sent along with @ reads CHAT.
            let icon = f.kind == .image ? "▣" : f.mimeType == "application/pdf" ? "PDF" : f.mimeType == "text/x-piopio-conversation" ? "CHAT" : "TXT"
            let start = m.length
            m.append(NSAttributedString(string: "\u{2009}\u{2009}\(icon)  ", attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: f.mimeType == "application/pdf" ? DS.red : DS.fg3, .piopioPill: PillStyle.file.rawValue]))
            m.append(NSAttributedString(string: f.name + "\u{2009}\u{2009}", attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: DS.fg, .piopioPill: PillStyle.file.rawValue]))
            // A kept copy opens in the file viewer (roadmap D8).
            if let stored = f.stored {
                let range = NSRange(location: start, length: m.length - start)
                m.addAttribute(.link, value: TranscriptAction.openAttachment(stored: stored).url, range: range)
                m.addAttribute(.toolTip, value: "Open \(f.name)", range: range)
            }
        }
        let p = paragraph(spacing: 10)
        p.alignment = .right
        p.lineHeightMultiple = 1.9
        return line(m, p)
    }

    /// Your own words, as typed (no markdown interpretation), in a bubble that hugs the text on the right.
    /// The document sets the indent from `.piopioBubbleWidth` for the current column width.
    private func bubble(_ text: String) -> NSAttributedString {
        let lines = text.replacingOccurrences(of: "\n", with: lineSeparator)
        let attrs: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: DS.fg]
        let natural = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { NSAttributedString(string: String($0), attributes: attrs).size().width }
            .max() ?? 0
        let p = paragraph(spacing: 2 + CardLayoutFragment.bubblePadV, before: CardLayoutFragment.bubblePadV + 4, indent: 120, tail: -CardLayoutFragment.bubblePadH)
        if !compact { p.lineHeightMultiple = 1.5 / 1.2 }
        let m = NSMutableAttributedString(attributedString: line(NSAttributedString(string: lines, attributes: attrs), p))
        let all = NSRange(location: 0, length: m.length)
        m.addAttribute(.piopioCard, value: CardStyle.user.rawValue, range: all)
        m.addAttribute(.piopioBubbleWidth, value: NSNumber(value: Double(ceil(natural) + 2)), range: all)
        return m
    }

    /// Error (8d pattern: what happened, what's safe, one primary action) or "Stopped" note under an answer.
    private func statusCard(_ a: AssistantItem) -> NSAttributedString {
        switch a.status {
        case .error:
            let auth = a.errorKind == .auth
            var actions: [(String, TranscriptAction, PillStyle)] = []
            if auth {
                actions = [("Open Settings", .openSettings, .primary), ("Retry", .regenerate(itemId: a.id), .primary)]
            } else {
                actions = [("Retry", .regenerate(itemId: a.id), .primary), ("Use another model", .chooseModel, .primary)]
            }
            if a.errorDetail != nil { actions.append(("Details", .showErrorDetail(itemId: a.id), .secondary)) }
            let safe = auth ? "Your message is saved. Update the provider key, then retry." :
                a.errorKind == .context ? "Nothing was lost. Start a new thread, or pick a model with a larger context." :
                "Nothing was changed."
            return errorCard(title: a.error ?? "The model request failed.", safe: safe, actions: actions)
        case .aborted:
            let stopped = NSMutableAttributedString(string: "Stopped", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3])
            if !compact, a.speaker == nil {
                stopped.append(NSAttributedString(string: " · ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3]))
                stopped.append(NSAttributedString(string: "continue", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg2, .link: TranscriptAction.continueAnswer.url]))
            }
            return line(stopped, paragraph(spacing: 14, before: 6))
        case .done, .streaming:
            return NSAttributedString()
        }
    }

    /// An interruption (docs/design/grey 11h): what happened, then what's safe and the next steps as links, in grey.
    private func errorCard(title: String, safe: String, actions: [(String, TranscriptAction, PillStyle)]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        m.append(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: DS.fg]))
        m.append(NSAttributedString(string: lineSeparator + safe, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3]))
        for (title, action, style) in actions {
            m.append(NSAttributedString(string: " · ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3]))
            m.append(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: style == .primary ? DS.accent : DS.fg2, .link: action.url]))
        }
        return card(m, .errorCard, lineHeight: 1.5)
    }

    /// A plan in the transcript (docs/spec/09 P1–P3): its details once the engine has them, else its arguments.
    static func planContent(_ t: ToolItem) -> PlanContent {
        let strings = { (key: String) -> [String] in
            guard case .array(let items)? = t.args?[key] else { return [] }
            return items.compactMap(\.stringValue)
        }
        var plan = PlanContent(callId: t.callId, summary: t.args?["summary"]?.stringValue ?? "", steps: strings("steps"), files: strings("files"), risks: strings("risks"), state: .pending)
        var outcome: String?
        if case .plan(let d)? = t.typedDetails {
            plan.summary = d.summary.isEmpty ? plan.summary : d.summary
            plan.steps = d.steps.isEmpty ? plan.steps : d.steps
            plan.files = d.files
            plan.risks = d.risks
            outcome = d.outcome
            if d.outcome == "approved" { plan.state = d.edited ? .approvedEdited : .approved }
            else if d.outcome == "changes" { plan.state = .changes(d.note) }
            else if d.outcome == "unanswered" { plan.state = .unanswered }
        }
        if outcome == nil {
            switch t.status {
            case .running, .pendingApproval: plan.state = .pending
            case .interrupted, .error, .denied: plan.state = .unanswered
            case .done: plan.state = (t.output ?? "").contains("approved") ? .approved : .changes(nil)
            }
        }
        return plan
    }

    /// A question the agent asked (ask_user) and what you answered, kept in the transcript as Cursor and Claude
    /// do; while it waits, the question card above the composer takes the answer.
    private func questionCard(_ t: ToolItem) -> NSAttributedString {
        let question = t.args?["question"]?.stringValue ?? ""
        // While it waits, the card above the composer holds the question.
        if t.status == .running || t.status == .pendingApproval { return NSAttributedString() }
        let prefix = "The user answered: "
        let answer = t.details?["answer"]?.stringValue ?? t.output.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
        // Once answered, one grey line (docs/design/grey 11d); the question is in its tooltip.
        let grey: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3, .toolTip: question]
        let m = NSMutableAttributedString()
        if answer == "Skipped" {
            m.append(NSAttributedString(string: "Skipped", attributes: grey))
        } else if let answer {
            m.append(NSAttributedString(string: "You chose ", attributes: grey))
            m.append(NSAttributedString(string: answer, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg2, .toolTip: question]))
        } else {
            m.append(NSAttributedString(string: (t.status == .interrupted ? "Stopped before you answered: " : "Not answered: ") + question, attributes: grey))
        }
        return line(m, paragraph(spacing: 14, before: 6))
    }

    /// A grey line in the transcript (docs/design/grey 11h). Only something waiting on you gets the blue dot.
    private func note(_ text: String, dot: NSColor? = nil) -> NSAttributedString {
        let m = NSMutableAttributedString()
        if let dot { m.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: dot, .baselineOffset: 1.5])) }
        m.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3]))
        let p = paragraph(spacing: 14, before: 6)
        let out = NSMutableAttributedString(attributedString: line(m, p))
        out.addAttribute(.piopioCard, value: CardStyle.note.rawValue, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// The card for a tool call (docs/spec/05-build BR1): edits and writes show their diff (open by default),
    /// bash its command, output and exit code, other tools their output.
    static func toolCard(_ t: ToolItem, root: String? = nil) -> DisclosureCard {
        let (title, raw) = toolTitle(t)
        let detail = relative(raw, root: root)
        // Steps quicker than a tenth of a second show no time.
        let duration = t.durationMs.map { $0 < 100 ? "" : $0 < 1000 ? String(format: "%.1fs", $0 / 1000) : String(format: "%.0fs", $0 / 1000) } ?? (t.status == .running ? "…" : "")
        let failed = t.status == .error
        let card: DisclosureCard
        switch t.typedDetails {
        case .diff(_, let patch) where !patch.isEmpty && !failed:
            let parsed = DiffLine.parse(patch)
            card = DisclosureCard(tool: title, detail: detail, trailing: "", content: .diff(parsed.lines))
            card.added = parsed.added
            card.removed = parsed.removed
            card.expanded = true
        case .todos(let todos):
            let done = todos.filter { $0.status == .done }.count
            let current = todos.first { $0.status == .inProgress }?.text
            card = DisclosureCard(tool: title, detail: "\(done) of \(todos.count) done" + (current.map { " · \($0)" } ?? ""), trailing: "", content: .text(todos.map { "\($0.status == .done ? "✓" : $0.status == .inProgress ? "▸" : "○")  \($0.text)" }.joined(separator: "\n")))
        case .task(let sessionId, let status, let cost):
            var trailing = [String]()
            if status == "error" { trailing.append("failed") } else if status == "stopped" { trailing.append("stopped") }
            if let cost, cost > 0 { trailing.append(cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)) }
            if trailing.isEmpty, !duration.isEmpty { trailing.append(duration) }
            card = DisclosureCard(tool: title, detail: detail, trailing: trailing.joined(separator: " · "), content: .text(t.output ?? ""))
            if let sessionId { card.action = ("Open", .openSession(sessionId)) }
        case .terminal(_, let exitCode):
            let full = t.args?["command"]?.stringValue ?? raw
            let shown = displayCommand(full, root: root)
            var trailing = [String]()
            if let folder = shown.folder { trailing.append("in \(folder)") }
            if let exitCode, exitCode != 0 { trailing.append("exit \(exitCode)") }
            // Ran without asking you because auto review judged it safe: said on the row, and why when opened.
            if t.review != nil { trailing.append("auto-reviewed") }
            if !duration.isEmpty { trailing.append(duration) }
            let firstLine = shown.command.split(separator: "\n").first.map(String.init) ?? shown.command
            // Opened: the whole command, then what it printed.
            let output = (t.output ?? "").trimmingCharacters(in: .newlines)
            let review = t.review.map { "# Auto review ran this without asking: \($0)\n" } ?? ""
            card = DisclosureCard(tool: title, detail: firstLine, trailing: trailing.joined(separator: " · "), content: .terminal(review + "$ \(full)" + (output.isEmpty ? "" : "\n\n\(output)")))
            card.truncateTail = true
            card.action = ("Copy", .copyText(full))
        default:
            var body = t.output ?? ""
            if t.tool == "propose_plan", case .array(let steps)? = t.args?["steps"] {
                body = steps.enumerated().map { "\($0.offset + 1). \($0.element.stringValue ?? "")" }.joined(separator: "\n") + (body.isEmpty ? "" : "\n\n\(body)")
            }
            card = DisclosureCard(tool: title, detail: detail, trailing: duration, content: .text(body))
            card.expanded = t.tool == "propose_plan"
        }
        card.failed = failed
        card.glyph = glyph(t.tool)
        if ["codemode"].contains(t.tool) { card.truncateTail = true }
        // Files the agent read or changed open in the viewer (BR4).
        if ["read", "edit", "write"].contains(t.tool), let path = t.args?["path"]?.stringValue, t.status != .denied {
            var line: Int?
            if case .number(let offset)? = t.args?["offset"] { line = Int(offset) }
            card.action = ("Open", .openFile(path: path, line: line))
        }
        switch t.status {
        case .pendingApproval:
            card.waiting = true
            card.trailing = "waiting for you"
        case .denied: card.trailing = "denied"
        case .interrupted where t.output != nil: card.trailing = "stopped"
        default: break
        }
        return card
    }

    /// A file the agent handed over: its name and what it is, opening in the viewer; a missing one says so.
    static func fileCard(_ file: PresentedFile, root: String?) -> DisclosureCard {
        let size = file.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        let card = DisclosureCard(tool: file.name, detail: file.description ?? relative(file.path, root: root), trailing: file.missing ? "not found" : size, content: .text(relative(file.path, root: root)))
        card.glyph = "doc.richtext"
        card.failed = file.missing
        if !file.missing { card.action = ("Open", .openFile(path: file.path, line: nil)) }
        return card
    }

    /// A step's icon in the activity log.
    static func glyph(_ tool: String) -> String {
        switch tool {
        case "read": "doc.text"
        case "edit", "write": "pencil"
        case "bash", "codemode": "apple.terminal"
        case "grep", "find", "web_search", "tool_search": "magnifyingglass"
        case "ls": "folder"
        case "web_fetch": "globe"
        case "todo": "checklist"
        case "task": "person.2"
        case "propose_plan": "list.number"
        case "present_files": "doc.richtext"
        case "search_conversations", "read_conversation": "bubble.left.and.text.bubble.right"
        case "update_goal": "flag.checkered"
        case let name where name.hasPrefix("calendar"): "calendar"
        case let name where name.hasPrefix("mail"): "envelope"
        default: "wrench.and.screwdriver"
        }
    }

    /// Human titles for known tools ("Searched the web" + the query); others show their name and status.
    static func toolTitle(_ t: ToolItem) -> (String, String) {
        if t.status == .pendingApproval || t.status == .denied {
            let (_, detail) = toolTitle(ToolItem(id: t.id, at: t.at, callId: t.callId, tool: t.tool, args: t.args, status: .done))
            let verb = ["bash": "Run", "edit": "Edit", "write": "Write", "read": "Read", "web_fetch": "Open", "web_search": "Search the web"][t.tool] ?? t.tool
            return (verb, detail)
        }
        let running = t.status == .running
        let failed = t.status == .error
        let path = t.args?["path"]?.stringValue ?? ""
        switch t.tool {
        case "read":
            var range = ""
            if case .number(let offset)? = t.args?["offset"] {
                range = ":\(Int(offset))"
                if case .number(let limit)? = t.args?["limit"] { range += "–\(Int(offset + limit - 1))" }
            }
            return (running ? "Reading" : failed ? "Couldn't read" : "Read", path + range)
        case "edit":
            return (running ? "Editing" : failed ? "Edit failed" : "Edited", path)
        case "write":
            return (running ? "Writing" : failed ? "Write failed" : "Wrote", path)
        case "bash":
            let command = t.args?["command"]?.stringValue ?? ""
            return (running ? "Running" : "Ran", command.split(separator: "\n").first.map(String.init) ?? command)
        case "grep":
            return (running ? "Searching" : "Searched", t.args?["pattern"]?.stringValue ?? "")
        case "find":
            return (running ? "Finding files" : "Found files", t.args?["pattern"]?.stringValue ?? path)
        case "ls":
            return (running ? "Listing" : "Listed", path.isEmpty ? "." : path)
        case "todo":
            return (running ? "Updating the checklist" : "Checklist", "")
        case "task" where t.args?["agent"]?.stringValue == "claude" || t.args?["agent"]?.stringValue == "codex":
            let who = t.args?["agent"]?.stringValue == "claude" ? "Claude Code" : "Codex"
            return (running ? "\(who) working" : who, t.args?["description"]?.stringValue ?? "")
        case "task":
            return (running ? "Subagent working" : "Subagent", t.args?["description"]?.stringValue ?? "")
        case "propose_plan":
            return (running ? "Proposed a plan" : "Plan", t.args?["summary"]?.stringValue ?? "")
        case "present_files":
            let names = t.args?["files"]?.arrayValue?.compactMap { $0["path"]?.stringValue.map { ($0 as NSString).lastPathComponent } }.joined(separator: ", ") ?? ""
            return (running ? "Handing over files" : failed ? "Files not found" : "Files for you", names)
        case "search_conversations":
            return (running ? "Searching your conversations" : "Searched your conversations", t.args?["query"]?.stringValue ?? "")
        case "read_conversation":
            return (running ? "Reading a conversation" : failed ? "Couldn't read a conversation" : "Read a conversation", t.args?["query"]?.stringValue ?? "")
        case "update_goal":
            let status = t.args?["status"]?.stringValue
            return (status == "done" ? "Goal done" : status == "blocked" ? "Goal blocked" : "Goal", t.args?["note"]?.stringValue ?? "")
        case "codemode":
            let script = t.args?["code"]?.stringValue ?? t.args?["script"]?.stringValue ?? ""
            return (running ? "Running a script" : "Ran a script", script.split(separator: "\n").first.map(String.init) ?? "")
        case "tool_search":
            return (running ? "Finding tools" : "Found tools", t.args?["query"]?.stringValue ?? "")
        case let name where name.hasPrefix("mcp__"):
            let parts = name.split(separator: "_", omittingEmptySubsequences: true)
            let server = parts.count > 1 ? String(parts[1]) : "MCP"
            let tool = name.components(separatedBy: "__").dropFirst(2).joined(separator: "__")
            return (server, tool.isEmpty ? name : tool)
        case "remember_about_me":
            let facts = t.args?["add"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? ""
            return (running ? "Saving to About me" : failed ? "Not saved to About me" : "Saved to About me", facts)
        case "ask_topic":
            return (running ? "Asking \(t.args?["topic"]?.stringValue ?? "a topic")" : "Asked \(t.args?["topic"]?.stringValue ?? "a topic")", t.args?["question"]?.stringValue ?? "")
        // Projects without a folder, before docs/spec/18 CF4: their tools still show in old conversations.
        case "read_project_file":
            return (running ? "Reading a project file" : "Read a project file", t.args?["name"]?.stringValue ?? "")
        case "remember_in_project":
            return (running ? "Saving to the project" : "Saved to the project", t.args?["fact"]?.stringValue ?? "")
        case "rename_topic", "archive_topic", "merge_topics":
            return (failed ? "Suggested tidying" : "Tidied topics", t.args?["topic"]?.stringValue ?? t.args?["from"]?.stringValue ?? "")
        case "ask_user":
            return (running ? "Waiting for your answer" : "Asked you", t.args?["question"]?.stringValue ?? "")
        case "calendar_events":
            return (running ? "Reading your calendar" : failed ? "Couldn't read your calendar" : "Read your calendar", t.args?["query"]?.stringValue ?? "")
        case "calendar_free_time":
            return (running ? "Finding free time" : "Found free time", "")
        case "calendar_create_event":
            return (running ? "Creating an event" : failed ? "Didn't create the event" : "Created an event", t.args?["title"]?.stringValue ?? "")
        case "calendar_update_event":
            return (running ? "Changing an event" : failed ? "Didn't change the event" : "Changed an event", t.args?["title"]?.stringValue ?? "")
        case "calendar_delete_event":
            return (running ? "Deleting an event" : failed ? "Didn't delete the event" : "Deleted an event", "")
        case "mail_search":
            return (running ? "Searching your mail" : "Searched your mail", t.args?["query"]?.stringValue ?? "")
        case "mail_read":
            return (running ? "Reading an email" : "Read an email", "")
        case "mail_draft":
            return (running ? "Writing a draft" : failed ? "Didn't save the draft" : "Wrote a draft", t.args?["subject"]?.stringValue ?? "")
        case "mail_send":
            return (running ? "Sending an email" : failed ? "Didn't send the email" : "Sent an email", "")
        case "notify_user":
            return ("Notified you", t.args?["message"]?.stringValue ?? "")
        case "web_search":
            let query = t.args?["query"]?.stringValue ?? ""
            return (running ? "Searching the web" : t.status == .error ? "Web search failed" : "Searched the web", query)
        case "web_fetch":
            let url = t.args?["url"]?.stringValue ?? ""
            let host = URL(string: url)?.host() ?? url
            return (running ? "Reading" : t.status == .error ? "Couldn't read" : "Read", host)
        default:
            return (t.tool, t.status == .running ? "running" : t.status.rawValue)
        }
    }

    // MARK: Footers (shown on hover)

    private var footerFont: NSFont { .systemFont(ofSize: 11.5, weight: .medium) }

    /// A capsule button (error cards): accent fill for the primary action, chip fill otherwise.
    func pill(_ title: String, _ action: TranscriptAction, _ style: PillStyle) -> NSAttributedString {
        NSAttributedString(string: "\u{2009}\u{2009}\u{2009}\(title)\u{2009}\u{2009}\u{2009}", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: style == .primary ? DS.invfg : DS.fg2,
            .link: action.url,
            .piopioPill: style.rawValue,
        ])
    }

    /// Under your message, on hover (14b): Copy, Edit and, in Build, Rewind to here; a thread's versions switcher.
    func userFooter(_ u: UserItem) -> NSAttributedString {
        let actions = MessageActions(itemId: u.id, role: .user, text: u.text)
        actions.canEdit = versions || build
        actions.canRewind = build
        actions.branch = versions ? u.branch : nil
        actions.note = u.direct == true ? "direct" : nil
        actions.at = Self.date(u.at)
        return actionsLine(actions, spacing: 2)
    }

    /// Under an answer (14a): Copy, Retry, Fork from here; the model and cost on the right.
    func answerFooter(_ a: AssistantItem) -> NSAttributedString {
        guard !a.text.isEmpty else { return NSAttributedString() } // a step that only called tools
        let actions = MessageActions(itemId: a.id, role: .answer, text: a.text)
        actions.at = Self.date(a.at)
        actions.canRetry = (versions || build) && a.outbound == nil
        actions.canFork = (versions || build) && a.outbound == nil
        // The model's name beside the buttons; what it cost and the tokens only in its tooltip.
        actions.meta = a.model.map(Self.modelName) ?? ""
        var help: [String] = []
        if let model = a.model { help.append(model) }
        if let u = a.usage, u.costUsd > 0 { help.append(u.costUsd < 0.01 ? String(format: "$%.4f", u.costUsd) : String(format: "$%.2f", u.costUsd)) }
        if let u = a.usage { help.append("\(Int(u.inputTokens)) in · \(Int(u.outputTokens)) out · \(Int(u.cacheReadTokens)) cached tokens") }
        actions.metaHelp = help.joined(separator: "\n")
        return actionsLine(actions, spacing: 18)
    }

    /// An item's ISO time, with or without fractional seconds (nil when it has none).
    static func date(_ iso: String) -> Date? {
        guard !iso.isEmpty else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    /// "Today 8:00", "Yesterday 21:00", "Fri 8:00", "3 Nov 8:00".
    static func dayAndTime(_ date: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday \(time)" }
        if let days = cal.dateComponents([.day], from: date, to: now).day, days < 7 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }

    /// "anthropic/claude-haiku-5.5" → "Haiku 5.5"; other ids lose only their provider.
    static func modelName(_ id: String) -> String {
        if let known = ModelNames.name(for: id) { return known }
        var name = id.split(separator: "/").last.map(String.init) ?? id
        if name.hasPrefix("claude-") {
            name = name.dropFirst(7).replacingOccurrences(of: "-", with: " ")
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return name
    }

    private func actionsLine(_ actions: MessageActions, spacing: CGFloat) -> NSAttributedString {
        let s = NSMutableAttributedString(attachment: ActionsAttachment(actions: actions))
        s.append(NSAttributedString(string: "\n"))
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing
        p.paragraphSpacingBefore = 0
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        return s
    }

    func thinkingCard(_ card: DisclosureCard) -> NSAttributedString {
        attachmentParagraph(DisclosureAttachment(card: card))
    }

    // MARK: Markdown blocks

    func render(_ block: MarkdownBlock) -> NSAttributedString {
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = prose ? (level == 1 ? 28 : level == 2 ? 17 : 15) : (level == 1 ? 19 : level == 2 ? 17 : 15)
            let weight: NSFont.Weight = prose && level == 1 ? .bold : .semibold
            return line(chips(Inline.ns(text, font: .systemFont(ofSize: size, weight: weight), color: DS.fg)), paragraph(spacing: prose ? 10 : 6, before: prose ? 18 : 8))
        case .paragraph(let text):
            // A single line break inside a paragraph stays a line break, not a new paragraph with its spacing.
            return line(chips(Inline.ns(text.replacingOccurrences(of: "\n", with: lineSeparator), font: body, color: DS.fg)), paragraph(spacing: compact ? 10 : 12))
        case .quote(let text):
            let p = paragraph(spacing: 12, indent: 14)
            return card(Inline.ns(text.replacingOccurrences(of: "\n", with: lineSeparator), font: body, color: DS.fg2), .quote, paragraphStyle: p)
        case .list(let items):
            let out = NSMutableAttributedString()
            for (i, item) in items.enumerated() {
                let marker = item.task.map { $0 ? "☑︎\t" : "☐\t" } ?? (item.ordered ? "\(item.number ?? i + 1).\t" : "•\t")
                let indent = CGFloat(item.indent) * 10 + 4
                let m = NSMutableAttributedString(string: marker, attributes: [.font: body, .foregroundColor: DS.fg3])
                m.append(chips(Inline.ns(item.text, font: body, color: DS.fg)))
                let p = paragraph(spacing: i == items.count - 1 ? 10 : 2, indent: indent, head: indent + 20)
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent + 20)]
                out.append(line(m, p))
            }
            return out
        case .code(let language, let code, _):
            // A table drawn with spaces (a model's comparison in a code block) reads better as a table.
            if !compact, language == nil || ["text", "txt", "plaintext", "markdown", "md"].contains(language!.lowercased()), let table = TableContent.spaced(code) {
                return attachmentParagraph(TableAttachment(table: table))
            }
            // The header: what it is, and Copy.
            let m = NSMutableAttributedString()
            let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: DS.fg3]
            if let language { m.append(NSAttributedString(string: language + "  ·  ", attributes: label)) }
            m.append(NSAttributedString(string: "Copy", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: DS.fg2, .link: TranscriptAction.copyText(code).url]))
            m.append(NSAttributedString(string: lineSeparator, attributes: label))
            m.append(NSAttributedString(string: lineSeparator, attributes: [.font: NSFont.systemFont(ofSize: 4)]))
            let start = m.length
            m.append(NSAttributedString(string: code.replacingOccurrences(of: "\n", with: lineSeparator), attributes: [.font: mono, .foregroundColor: DS.fg]))
            for (range, token) in Highlighter.tokens(code) where NSMaxRange(range) + start <= m.length {
                m.addAttribute(.foregroundColor, value: Highlighter.color(token), range: NSRange(location: range.location + start, length: range.length))
            }
            return card(m, .code, lineHeight: 1.25)
        case .table(let header, _, let rows):
            if compact {
                // Quick Chat's narrow panel keeps the plain, monospaced form.
                let widths = header.indices.map { c in ([header] + rows).map { $0.indices.contains(c) ? $0[c].count : 0 }.max() ?? 0 }
                func row(_ cells: [String]) -> String { cells.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "   ") }
                let text = NSMutableAttributedString(string: row(header), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: DS.fg3])
                for r in rows { text.append(NSAttributedString(string: lineSeparator + row(r), attributes: [.font: mono, .foregroundColor: DS.fg])) }
                return card(text, .table, lineHeight: 1.35)
            }
            return attachmentParagraph(TableAttachment(table: TableContent(header: header, rows: rows)))
        case .rule:
            return line(NSAttributedString(string: " ", attributes: [.font: small, .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: DS.line]), paragraph())
        }
    }

    // MARK: Helpers

    /// Code spans become chips (chat v3, 14f), and paths inside the project show relative: "RESUMEN.md" instead of
    /// "/Users/…/smart-paste/RESUMEN.md", the full path in the tooltip; clicking shows the file in the inspector.
    private func chips(_ m: NSMutableAttributedString) -> NSMutableAttributedString {
        if compact { return m }
        let chipFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        // Code spans: the chip replaces the flat background.
        var spans: [NSRange] = []
        m.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            if value != nil { spans.append(range) }
        }
        for range in spans.reversed() {
            let text = (m.string as NSString).substring(with: range)
            // "src/app.ts:42" (or ":42:5"): the file, opened at that line.
            let (name, line) = Self.splitLine(text)
            let full = Self.absolute(name, root: root)
            var attrs: [NSAttributedString.Key: Any] = [.font: chipFont, .foregroundColor: DS.fg, .piopioPill: PillStyle.code.rawValue]
            if let full {
                attrs[.toolTip] = line.map { "\(full), line \($0)" } ?? full
                attrs[.link] = (line.map { TranscriptAction.openFile(path: full, line: $0) } ?? TranscriptAction.revealFile(path: full)).url
            }
            let shown = full.map { Self.relative($0, root: root) + (line.map { ":\($0)" } ?? "") } ?? text
            m.replaceCharacters(in: range, with: NSAttributedString(string: "\u{2009}\(shown)\u{2009}", attributes: attrs))
        }
        // Bare absolute paths in the prose.
        guard let root, !root.isEmpty else { return m }
        let pattern = NSRegularExpression.escapedPattern(for: root) + #"(/[^\s`'"<>()\[\],;]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return m }
        for match in regex.matches(in: m.string, range: NSRange(location: 0, length: m.length)).reversed() {
            var range = match.range
            if m.attribute(.piopioPill, at: range.location, effectiveRange: nil) != nil { continue }
            var path = (m.string as NSString).substring(with: range)
            while let last = path.last, ".:!?".contains(last) { path.removeLast(); range.length -= 1 }
            m.replaceCharacters(in: range, with: NSAttributedString(string: "\u{2009}\(Self.relative(path, root: root))\u{2009}", attributes: [
                .font: chipFont, .foregroundColor: DS.fg, .piopioPill: PillStyle.code.rawValue, .toolTip: path, .link: TranscriptAction.revealFile(path: path).url,
            ]))
        }
        return m
    }

    /// "path:42" or "path:42:5" → ("path", 42); anything else → (text, nil).
    static func splitLine(_ text: String) -> (String, Int?) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3, !parts[0].isEmpty, parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let line = Int(parts[1]), line > 0 else { return (text, nil) }
        return (String(parts[0]), line)
    }

    /// A code span that names something in the project: its absolute path (it may already be relative).
    static func absolute(_ text: String, root: String?) -> String? {
        guard let root, !root.isEmpty, !text.contains(" "), !text.contains("\n") else { return nil }
        if text == root || text.hasPrefix(root + "/") { return text }
        guard text.contains("/") || text.contains("."), !text.hasPrefix("/"), !text.hasPrefix("http"), !text.hasPrefix("-") else { return nil }
        let candidate = root + "/" + (text.hasPrefix("./") ? String(text.dropFirst(2)) : text)
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    private func paragraph(spacing: CGFloat = 10, before: CGFloat = 0, indent: CGFloat = 0, head: CGFloat? = nil, tail: CGFloat = 0) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing
        p.paragraphSpacingBefore = before
        p.firstLineHeadIndent = indent
        p.headIndent = head ?? indent
        p.tailIndent = tail
        p.lineHeightMultiple = Self.lineHeight
        return p
    }

    private func line(_ s: NSAttributedString, _ style: NSParagraphStyle) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        m.append(NSAttributedString(string: "\n", attributes: [.font: s.length > 0 ? (s.attribute(.font, at: max(0, s.length - 1), effectiveRange: nil) as? NSFont ?? body) : body]))
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        return m
    }

    private func attachmentParagraph(_ attachment: NSTextAttachment, spacing: CGFloat = 12) -> NSAttributedString {
        let s = NSMutableAttributedString(attachment: attachment)
        s.append(NSAttributedString(string: "\n"))
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing
        p.paragraphSpacingBefore = 2
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        return s
    }

    /// One paragraph that `CardLayoutFragment` draws a background behind (full column width).
    private func card(_ s: NSAttributedString, _ kind: CardStyle, lineHeight: CGFloat? = nil, paragraphStyle: NSMutableParagraphStyle? = nil) -> NSAttributedString {
        let pad = CardLayoutFragment.padding
        let p = paragraphStyle ?? paragraph(spacing: 14 + pad, before: pad + 2, indent: pad + 2, tail: -(pad + 2))
        if let lineHeight { p.lineHeightMultiple = lineHeight / 1.2 }
        let m = NSMutableAttributedString(attributedString: line(s, p))
        m.addAttribute(.piopioCard, value: kind.rawValue, range: NSRange(location: 0, length: m.length))
        return m
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What the app calls each model ("DeepSeek V4.1 Flash 1017" for "deepseek-v4.1-flash-1017"), so a message's footer names
/// it as the composer's chip does. The app fills it from the engine's catalog; unknown ids fall back to the id.
/// An agent's colour (docs/spec/21, design 1a): one of five hues, stable for its id. The app's avatars use the same.
public enum AgentPalette {
    /// The design's five hues (oklch 0.72 0.12 H, H = 70, 150, 190, 255, 300), as sRGB.
    public static let rgb: [(Double, Double, Double)] = [(0.86, 0.66, 0.38), (0.49, 0.78, 0.52), (0.36, 0.76, 0.76), (0.46, 0.66, 0.95), (0.72, 0.59, 0.93)]

    public static func index(_ id: String) -> Int {
        var h: UInt32 = 5381
        for b in id.utf8 { h = (h &* 33) ^ UInt32(b) }
        return Int(h % UInt32(rgb.count))
    }

    static func color(_ id: String) -> NSColor {
        let (r, g, b) = rgb[index(id)]
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

public enum ModelNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: [String: String] = [:]

    /// `models`: (provider, id, name) from the catalog.
    public static func set(_ models: [(provider: String, id: String, name: String)]) {
        var table: [String: String] = [:]
        for m in models {
            for key in [m.id, "\(m.provider)/\(m.id)", m.id.split(separator: "/").last.map(String.init) ?? m.id] where table[key] == nil {
                table[key] = m.name
            }
        }
        lock.withLock { names = table }
    }

    static func name(for id: String) -> String? {
        lock.withLock { names[id] ?? id.split(separator: "/").last.flatMap { names[String($0)] } }
    }
}

