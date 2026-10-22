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
    /// Edit, Regenerate and Fork make new versions (threads). Build sessions show Copy only for now.
    var versions = true

    private var body: NSFont { .systemFont(ofSize: DS.transcriptSize) }
    private var mono: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    private var small: NSFont { .systemFont(ofSize: 12) }
    /// SF line height is ~1.2× its size; this gives the design's 13.5 / 1.6.
    private static let lineHeight: CGFloat = DS.transcriptLineHeight / 1.2

    func render(_ items: some Sequence<TimelineItem>) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for item in items { out.append(render(item)) }
        return out
    }

    func render(_ item: TimelineItem) -> NSAttributedString {
        switch item {
        case .user(let u):
            if compact { return NSAttributedString() }
            let out = NSMutableAttributedString()
            if let files = u.attachments, !files.isEmpty { out.append(fileChips(files)) }
            out.append(bubble(u.text))
            out.append(userFooter(u))
            return out
        case .assistant(let a):
            let out = NSMutableAttributedString()
            let thinking = a.parts.filter { $0.type == .thinking }.map(\.text).joined()
            if !thinking.isEmpty { out.append(thinkingCard(DisclosureCard(kind: .thinking, title: "Thought", detail: "", body: thinking))) }
            if let o = a.outbound { out.append(note(o.from.hasPrefix("run_") ? "Sent on its own, from an automatic run" : "Sent on its own", dot: DS.accent)) }
            for block in MarkdownStream(text: a.text).blocks { out.append(render(block)) }
            out.append(statusCard(a))
            if a.status != .streaming, !compact { out.append(answerFooter(a)) }
            return out
        case .tool(let t) where t.tool == "ask_user":
            return questionCard(t)
        case .tool(let t):
            return attachmentParagraph(DisclosureAttachment(card: Self.toolCard(t)))
        case .system(let s):
            if s.level == .error { return errorCard(title: s.text, safe: "Nothing was lost.", actions: []) }
            return note(s.text, dot: s.level == .warn ? DS.amber : DS.accent)
        case .compaction:
            return note("Context compacted: older messages were summarized", dot: DS.fg3)
        case .checkpoint(let c):
            return checkpointDivider(c)
        case .routing(let r):
            return routingCard(r)
        case .memory(let m):
            return memoryNote(m)
        case .steps(let s):
            return attachmentParagraph(DisclosureAttachment(card: Self.stepsCard(s)))
        case .approval(let a):
            return approvalCard(a)
        case .result(let r):
            return resultCard(r)
        case .agentMsg(let m):
            return agentMessage(m)
        }
    }

    /// An agent asks before acting (06-agents §9 AS1, docs/design 2a): what it wants to do, Deny / Edit… / Approve.
    /// Once answered, one line says how.
    private func approvalCard(_ a: ApprovalItem) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let (dot, state): (NSColor, String) = switch a.status {
        case .pending: (DS.amber, "Needs your approval")
        case .approved: (DS.green, a.editedArgs == nil ? "Approved" : "Approved with your changes")
        case .denied: (DS.red, a.reason.map { "Declined: \($0)" } ?? "Declined")
        case .expired: (DS.fg3, "No answer in 24 hours: not done")
        case .cancelled: (DS.fg3, "Cancelled")
        }
        if a.status != .pending {
            m.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: dot, .baselineOffset: 1.5]))
            m.append(NSAttributedString(string: "\(state) · \(a.title)", attributes: [.font: small, .foregroundColor: DS.fg2]))
            let p = paragraph(spacing: 14, before: 6, indent: 12)
            let out = NSMutableAttributedString(attributedString: line(m, p))
            out.addAttribute(.piopioCard, value: CardStyle.note.rawValue, range: NSRange(location: 0, length: out.length))
            return out
        }
        m.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: dot, .baselineOffset: 1]))
        m.append(NSAttributedString(string: state, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: DS.fg]))
        m.append(NSAttributedString(string: lineSeparator + a.title, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: DS.fg2]))
        if !compact {
            m.append(NSAttributedString(string: lineSeparator, attributes: [.font: small]))
            m.append(pill("Deny", .decideApproval(approvalId: a.approvalId, approve: false), .secondary))
            m.append(NSAttributedString(string: "  ", attributes: [.font: small]))
            m.append(pill("Edit…", .editApproval(approvalId: a.approvalId), .secondary))
            m.append(NSAttributedString(string: "  ", attributes: [.font: small]))
            m.append(pill("Approve", .decideApproval(approvalId: a.approvalId, approve: true), .primary))
        }
        return card(m, .approval, lineHeight: 1.5)
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
            case .failed: m.append(NSAttributedString(string: "Couldn't undo", attributes: [.font: small, .foregroundColor: DS.red]))
            case .expired: break
            }
        }
        if let detail = r.card.detail, !detail.isEmpty {
            m.append(NSAttributedString(string: lineSeparator + detail, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: undone ? DS.fg3 : DS.fg2]))
        }
        return card(m, .link, lineHeight: 1.5)
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
        case .failed?: (DS.red, "not sent")
        case .noReply?: (DS.amber, "no answer yet")
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
            out.append(NSAttributedString(string: lineSeparator + who + reply, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: m.status == .failed ? DS.red : DS.fg]))
        }
        return card(out, .link, lineHeight: 1.5)
    }

    /// "Worked 1.2s · 2 steps" (06-agents UI2): one line for a turn's tool calls; it opens to each step.
    static func stepsCard(_ s: StepsItem) -> DisclosureCard {
        let running = s.tools.contains { $0.status == .running }
        let waiting = s.tools.contains { $0.status == .pendingApproval }
        let seconds = s.tools.compactMap(\.durationMs).reduce(0, +) / 1000
        let time = seconds < 10 ? String(format: "%.0fs", max(1, seconds.rounded())) : String(format: "%.0fs", seconds)
        let lead = running ? "Working" : waiting ? "Waiting on you" : seconds >= 0.5 ? "Worked for \(time)" : "Worked"
        let parts = [lead] + activitySummary(s.tools)
        let card = DisclosureCard(kind: .activity, title: parts.joined(separator: " · "), body: "")
        card.content = .cards(s.tools.map(toolCard))
        card.working = running
        card.waiting = waiting
        card.failed = s.tools.contains { $0.status == .error }
        return card
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
        let known: Set<String> = ["read", "edit", "write", "bash", "web_search", "web_fetch"]
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
        let m2 = NSMutableAttributedString(string: "✎  ", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: DS.fg3])
        m2.append(NSAttributedString(string: lead, attributes: [.font: small, .foregroundColor: m.status == .undone || m.status == .dismissed ? DS.fg3 : DS.fg2, .toolTip: facts]))
        if !compact {
            let link: (String, TranscriptAction) -> NSAttributedString = { title, action in
                NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: DS.accent, .link: action.url])
            }
            if m.status == .saved, let revision = m.revisionId {
                m2.append(NSAttributedString(string: "  ·  ", attributes: [.font: small, .foregroundColor: DS.fg3]))
                m2.append(link("Undo", .undoMemory(revisionId: revision)))
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

    /// A notebook's Main (docs/design v2, 4a): one compact row per topic a message went to — status dot,
    /// the topic, one line of where it stands, Open › — instead of a full card. The reply lives in the topic.
    private func routingCard(_ r: RoutingItem) -> NSAttributedString {
        let (status, dot): (String, NSColor) = switch r.status {
        case .thinking: ("Thinking…", DS.accent)
        case .replying: ("Replying…", DS.accent)
        case .replied: (r.message.isEmpty ? "Created" : "Replied", DS.green)
        case .needsYou: ("Needs you", DS.amber)
        case .failed: ("Failed", DS.red)
        }
        let m = NSMutableAttributedString()
        m.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: dot, .baselineOffset: 1.5]))
        m.append(NSAttributedString(string: r.topicTitle, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: DS.fg]))
        let kind = r.decision == .create ? "new topic" : "sent here"
        m.append(NSAttributedString(string: "  ·  \(kind)  ·  ", attributes: [.font: small, .foregroundColor: DS.fg3, .toolTip: r.reason]))
        m.append(NSAttributedString(string: status, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: r.status == .needsYou ? DS.amber : r.status == .failed ? DS.red : DS.fg3]))
        if !compact, !r.topicId.isEmpty {
            let link: (String, TranscriptAction) -> NSAttributedString = { title, action in
                NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: DS.accent, .link: action.url])
            }
            m.append(NSAttributedString(string: "     ", attributes: [.font: small]))
            m.append(link("Open ›", .openTopic(topicId: r.topicId, itemId: r.replyItemId)))
            if !r.message.isEmpty, r.status != .failed {
                m.append(NSAttributedString(string: "   ", attributes: [.font: small]))
                m.append(NSAttributedString(string: "Change", attributes: [.font: small, .foregroundColor: DS.fg3, .link: TranscriptAction.wrongTopic(itemId: r.id).url, .toolTip: "Send this to another topic"]))
            }
        }
        let line2 = r.preview.map { String($0.prefix(140)) } ?? (r.reason.isEmpty ? nil : r.reason)
        if let line2 {
            m.append(NSAttributedString(string: lineSeparator + "    " + line2, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: DS.fg2]))
        }
        return card(m, .link, lineHeight: 1.5)
    }

    // MARK: Messages

    /// Files sent with a message: right-aligned chips above the bubble.
    private func fileChips(_ files: [AttachmentInfo]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        for (i, f) in files.enumerated() {
            if i > 0 { m.append(NSAttributedString(string: "   ", attributes: [.font: small])) }
            let icon = f.kind == .image ? "▣" : (f.mimeType == "application/pdf" ? "PDF" : "TXT")
            m.append(NSAttributedString(string: "\u{2009}\u{2009}\(icon)  ", attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: f.mimeType == "application/pdf" ? DS.red : DS.fg3, .piopioPill: PillStyle.file.rawValue]))
            m.append(NSAttributedString(string: f.name + "\u{2009}\u{2009}", attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: DS.fg, .piopioPill: PillStyle.file.rawValue]))
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
        let p = paragraph(spacing: 6 + CardLayoutFragment.bubblePadV, before: CardLayoutFragment.bubblePadV + 4, indent: 120, tail: -CardLayoutFragment.bubblePadH)
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
                actions = [("Open Settings", .openSettings, .primary), ("Retry now", .regenerate(itemId: a.id), .secondary)]
            } else {
                actions = [("Retry now", .regenerate(itemId: a.id), .primary), ("Use another model", .chooseModel, .secondary)]
            }
            if a.errorDetail != nil { actions.append(("Details", .showErrorDetail(itemId: a.id), .secondary)) }
            let safe = auth ? "Your message is saved. Update the provider key, then retry." :
                a.errorKind == .context ? "Nothing was lost. Start a new thread, or pick a model with a larger context." :
                "Nothing was lost. Your message is saved."
            return errorCard(title: a.error ?? "The model request failed.", safe: safe, actions: actions)
        case .aborted:
            return note("Stopped", dot: DS.fg3)
        case .done, .streaming:
            return NSAttributedString()
        }
    }

    private func errorCard(title: String, safe: String, actions: [(String, TranscriptAction, PillStyle)]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        m.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: DS.red, .baselineOffset: 1]))
        m.append(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: DS.fg]))
        m.append(NSAttributedString(string: lineSeparator + safe, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: DS.fg2]))
        if !actions.isEmpty {
            m.append(NSAttributedString(string: lineSeparator, attributes: [.font: small]))
            for (i, (title, action, style)) in actions.enumerated() {
                if i > 0 { m.append(NSAttributedString(string: "  ", attributes: [.font: small])) }
                m.append(pill(title, action, style))
            }
        }
        return card(m, .errorCard, lineHeight: 1.75)
    }

    /// Routing, memory and other notes: a small capsule with a colored dot (8e "System note").
    /// "Checkpoint · Before turn 2   Restore…" between hairlines.
    private func checkpointDivider(_ c: CheckpointItem) -> NSAttributedString {
        let small = NSFont.systemFont(ofSize: 11)
        let m = NSMutableAttributedString(string: "Checkpoint · \(c.label)", attributes: [.font: small, .foregroundColor: DS.fg3])
        if !compact {
            m.append(NSAttributedString(string: "   ", attributes: [.font: small]))
            m.append(NSAttributedString(string: "Restore…", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: DS.fg2, .link: TranscriptAction.restoreCheckpoint(itemId: c.id).url, .toolTip: "Put the project's files back as they were here"]))
        }
        let p = paragraph(spacing: 16, before: 4)
        p.alignment = .center
        let out = NSMutableAttributedString(attributedString: line(m, p))
        out.addAttribute(.piopioCard, value: CardStyle.divider.rawValue, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// A question the agent asked (ask_user) and what you answered, kept in the transcript as Cursor and Claude
    /// do; while it waits, the question card above the composer takes the answer.
    private func questionCard(_ t: ToolItem) -> NSAttributedString {
        let question = t.args?["question"]?.stringValue ?? ""
        if t.status == .running || t.status == .pendingApproval { return note("Waiting for your answer: \(question)", dot: DS.amber) }
        let prefix = "The user answered: "
        let answer = t.details?["answer"]?.stringValue ?? t.output.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
        let m = NSMutableAttributedString(string: "The agent asked", attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: DS.fg3])
        m.append(NSAttributedString(string: lineSeparator + question, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg2]))
        if let answer {
            m.append(NSAttributedString(string: lineSeparator + "↳  ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.accent]))
            m.append(NSAttributedString(string: answer, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: DS.fg]))
        } else {
            m.append(NSAttributedString(string: lineSeparator + (t.status == .interrupted ? "Stopped before you answered" : "Not answered"), attributes: [.font: small, .foregroundColor: DS.fg3]))
        }
        return card(m, .link, lineHeight: 1.5)
    }

    private func note(_ text: String, dot: NSColor) -> NSAttributedString {
        let m = NSMutableAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: dot, .baselineOffset: 1.5])
        m.append(NSAttributedString(string: text, attributes: [.font: small, .foregroundColor: DS.fg2]))
        let p = paragraph(spacing: 14, before: 6, indent: 12)
        let out = NSMutableAttributedString(attributedString: line(m, p))
        out.addAttribute(.piopioCard, value: CardStyle.note.rawValue, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// The card for a tool call (docs/spec/05-build BR1): edits and writes show their diff (open by default),
    /// bash its command, output and exit code, other tools their output.
    static func toolCard(_ t: ToolItem) -> DisclosureCard {
        let (title, detail) = toolTitle(t)
        let duration = t.durationMs.map { $0 < 1000 ? String(format: "%.1fs", $0 / 1000) : String(format: "%.0fs", $0 / 1000) } ?? (t.status == .running ? "…" : "")
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
            var trailing = [String]()
            if let exitCode, exitCode != 0 { trailing.append("exit \(exitCode)") }
            if !duration.isEmpty { trailing.append(duration) }
            card = DisclosureCard(tool: title, detail: detail, trailing: trailing.joined(separator: " · "), content: .terminal(t.output ?? ""))
        default:
            var body = t.output ?? ""
            if t.tool == "propose_plan", case .array(let steps)? = t.args?["steps"] {
                body = steps.enumerated().map { "\($0.offset + 1). \($0.element.stringValue ?? "")" }.joined(separator: "\n") + (body.isEmpty ? "" : "\n\n\(body)")
            }
            card = DisclosureCard(tool: title, detail: detail, trailing: duration, content: .text(body))
            card.expanded = t.tool == "propose_plan"
        }
        card.failed = failed
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
        case "task":
            return (running ? "Subagent working" : "Subagent", t.args?["description"]?.stringValue ?? "")
        case "propose_plan":
            return (running ? "Proposed a plan" : "Plan", t.args?["summary"]?.stringValue ?? "")
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
        case "search_space":
            return (running ? "Searching the Notebook" : "Searched the Notebook", t.args?["query"]?.stringValue ?? "")
        case "space_files_list", "space_files_read", "space_files_search":
            return (running ? "Reading the Notebook's files" : "Read the Notebook's files", t.args?["name"]?.stringValue ?? t.args?["query"]?.stringValue ?? "")
        case "rename_topic", "archive_topic", "merge_topics":
            return (failed ? "Suggested tidying" : "Tidied topics", t.args?["topic"]?.stringValue ?? t.args?["from"]?.stringValue ?? "")
        case "ask_user":
            return (running ? "Waiting for your answer" : "Asked you", t.args?["question"]?.stringValue ?? "")
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

    // MARK: Footers (shown on hover, and for the latest answer)

    private var footerFont: NSFont { .systemFont(ofSize: 11.5, weight: .medium) }

    /// A clickable word. Footer actions start hidden; `TranscriptDocument` reveals them on hover.
    func action(_ title: String, _ action: TranscriptAction, itemId: String? = nil, help: String? = nil) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: footerFont]
        if let itemId {
            attrs[.piopioFooter] = itemId
            attrs[.piopioFooterLink] = action.url
            attrs[.piopioFooterColor] = DS.fg3
            attrs[.foregroundColor] = NSColor.clear
        } else {
            attrs[.link] = action.url
            attrs[.foregroundColor] = DS.fg3
        }
        if let help { attrs[.toolTip] = help }
        return NSAttributedString(string: title, attributes: attrs)
    }

    /// A capsule button (error cards): accent fill for the primary action, chip fill otherwise.
    func pill(_ title: String, _ action: TranscriptAction, _ style: PillStyle) -> NSAttributedString {
        NSAttributedString(string: "\u{2009}\u{2009}\u{2009}\(title)\u{2009}\u{2009}\u{2009}", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: style == .primary ? NSColor.white : DS.fg,
            .link: action.url,
            .piopioPill: style.rawValue,
        ])
    }

    private func gap(_ itemId: String) -> NSAttributedString {
        NSAttributedString(string: "    ", attributes: [.font: footerFont, .piopioFooter: itemId])
    }

    /// Under your message: version switcher (always visible), then Edit and Copy (on hover).
    func userFooter(_ u: UserItem) -> NSAttributedString {
        let m = NSMutableAttributedString()
        if u.direct == true {
            m.append(NSAttributedString(string: "direct", attributes: [.font: footerFont, .foregroundColor: DS.fg3, .toolTip: "Typed in this topic, not routed from Main"]))
            m.append(NSAttributedString(string: "    ", attributes: [.font: footerFont]))
        }
        if versions {
            m.append(action("Edit", .edit(itemId: u.id), itemId: u.id, help: "Edit and resend (keeps this version)"))
            m.append(gap(u.id))
        }
        m.append(action("Copy", .copy(itemId: u.id), itemId: u.id))
        if let b = u.branch {
            let dim: [NSAttributedString.Key: Any] = [.font: footerFont, .foregroundColor: DS.line]
            m.append(NSAttributedString(string: "      ", attributes: [.font: footerFont]))
            m.append(b.previous.map { self.action("‹", .switchBranch($0), help: "Previous version") } ?? NSAttributedString(string: "‹", attributes: dim))
            m.append(NSAttributedString(string: "  \(b.index + 1) / \(b.count)  ", attributes: [.font: footerFont, .foregroundColor: DS.fg3]))
            m.append(b.next.map { self.action("›", .switchBranch($0), help: "Next version") } ?? NSAttributedString(string: "›", attributes: dim))
        }
        let p = paragraph(spacing: 14)
        p.alignment = .right
        p.tailIndent = -4
        return line(m, p)
    }

    /// Under an answer: Copy, Regenerate, Fork, then the model and cost (all on hover).
    func answerFooter(_ a: AssistantItem) -> NSAttributedString {
        let m = NSMutableAttributedString()
        if !a.text.isEmpty {
            m.append(action("Copy", .copy(itemId: a.id), itemId: a.id))
            m.append(gap(a.id))
        }
        if versions, a.outbound == nil {
            m.append(action("Retry", .regenerate(itemId: a.id), itemId: a.id, help: "Ask again (keeps this version)"))
            m.append(gap(a.id))
            m.append(action("Fork", .fork(itemId: a.id), itemId: a.id, help: "Continue from here in a new thread"))
        } else if a.text.isEmpty {
            return NSAttributedString() // a step that only called tools
        }
        var meta: [String] = []
        if let model = a.model { meta.append(model.split(separator: "/").dropFirst().joined(separator: "/").nilIfEmpty ?? model) }
        if let u = a.usage, u.costUsd > 0 { meta.append(u.costUsd < 0.01 ? String(format: "$%.4f", u.costUsd) : String(format: "$%.2f", u.costUsd)) }
        if !meta.isEmpty {
            var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.clear, .piopioFooter: a.id, .piopioFooterColor: DS.fg3]
            if let u = a.usage { attrs[.toolTip] = "\(Int(u.inputTokens)) in · \(Int(u.outputTokens)) out · \(Int(u.cacheReadTokens)) cached tokens" }
            if versions { m.append(gap(a.id)) } // otherwise Copy's gap already separates them
            m.append(NSAttributedString(string: meta.joined(separator: " · "), attributes: attrs))
        }
        return line(m, paragraph(spacing: 20, before: 2))
    }

    func thinkingCard(_ card: DisclosureCard) -> NSAttributedString {
        attachmentParagraph(DisclosureAttachment(card: card))
    }

    // MARK: Markdown blocks

    func render(_ block: MarkdownBlock) -> NSAttributedString {
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = level == 1 ? 18 : level == 2 ? 16 : 14
            return line(Inline.ns(text, font: .systemFont(ofSize: size, weight: .semibold), color: DS.fg), paragraph(spacing: 6, before: 8))
        case .paragraph(let text):
            return line(Inline.ns(text, font: body, color: DS.fg), paragraph())
        case .quote(let text):
            let p = paragraph(spacing: 12, indent: 14)
            return card(Inline.ns(text.replacingOccurrences(of: "\n", with: lineSeparator), font: body, color: DS.fg2), .quote, paragraphStyle: p)
        case .list(let items):
            let out = NSMutableAttributedString()
            for (i, item) in items.enumerated() {
                let marker = item.task.map { $0 ? "☑︎\t" : "☐\t" } ?? (item.ordered ? "\(item.number ?? i + 1).\t" : "•\t")
                let indent = CGFloat(item.indent) * 10 + 4
                let m = NSMutableAttributedString(string: marker, attributes: [.font: body, .foregroundColor: DS.fg3])
                m.append(Inline.ns(item.text, font: body, color: DS.fg))
                let p = paragraph(spacing: i == items.count - 1 ? 10 : 2, indent: indent, head: indent + 20)
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent + 20)]
                out.append(line(m, p))
            }
            return out
        case .code(let language, let code, _):
            let m = NSMutableAttributedString()
            if let language {
                m.append(NSAttributedString(string: language + lineSeparator, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: DS.fg3]))
            }
            let start = m.length
            m.append(NSAttributedString(string: code.replacingOccurrences(of: "\n", with: lineSeparator), attributes: [.font: mono, .foregroundColor: DS.fg]))
            for (range, token) in Highlighter.tokens(code) where NSMaxRange(range) + start <= m.length {
                m.addAttribute(.foregroundColor, value: Highlighter.color(token), range: NSRange(location: range.location + start, length: range.length))
            }
            return card(m, .code, lineHeight: 1.25)
        case .table(let header, _, let rows):
            let widths = header.indices.map { c in ([header] + rows).map { $0.indices.contains(c) ? $0[c].count : 0 }.max() ?? 0 }
            func row(_ cells: [String]) -> String { cells.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "   ") }
            let text = NSMutableAttributedString(string: row(header), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: DS.fg3])
            for r in rows { text.append(NSAttributedString(string: lineSeparator + row(r), attributes: [.font: mono, .foregroundColor: DS.fg])) }
            return card(text, .table, lineHeight: 1.35)
        case .rule:
            return line(NSAttributedString(string: " ", attributes: [.font: small, .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: DS.line]), paragraph())
        }
    }

    // MARK: Helpers

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

    private func attachmentParagraph(_ attachment: NSTextAttachment) -> NSAttributedString {
        let s = NSMutableAttributedString(attachment: attachment)
        s.append(NSAttributedString(string: "\n"))
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 12
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
