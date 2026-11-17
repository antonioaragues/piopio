import AppKit
import PiopioKit

/// One of a conversation's side conversations as its transcript shows it (docs/spec/24 §6): where it stands now.
public struct SideInfo: Sendable, Hashable {
    public var id: String
    public var title: String
    /// queued, working, needs_you, done, failed or stopped.
    public var state: String
    /// What it's doing while it works.
    public var line: String?
    /// Its own branch, and whether that was merged or discarded.
    public var branch: String?
    public var finished: String?
    /// The tool call that started it: side_start, or the offer or proposal you answered.
    public var from: String?

    public init(id: String, title: String, state: String, line: String? = nil, branch: String? = nil, finished: String? = nil, from: String? = nil) {
        self.id = id; self.title = title; self.state = state; self.line = line; self.branch = branch; self.finished = finished; self.from = from
    }

    /// Done on a branch nobody merged or discarded yet.
    var unmerged: Bool { state == "done" && branch != nil && finished == nil }
}

/// What the side links in the transcript do; the conversation's page acts on them (SideOffers).
public enum SideActionKind {
    public static let open = "side-open", start = "side-start", dismiss = "side-dismiss", merge = "side-merge", discard = "side-discard"
}

// Side conversations in the transcript (docs/spec/24 §6, option B): starting one is process, so it's a grey line
// that keeps saying where it stands; only what needs you is a card (a proposal to start, a side waiting on an
// approval). A finished side's branch gets Merge · Discard on its line.
extension ItemRenderer {
    func side(from callId: String) -> SideInfo? { sides.first { $0.from == callId } }

    /// "Side conversation · Fix sidebar clipping · running tests", from side_start or an answered offer.
    func sideStarted(_ t: ToolItem) -> NSAttributedString {
        let title = t.args?["title"]?.stringValue ?? "Side conversation"
        if t.status == .running || t.status == .pendingApproval { return note("Starting a side conversation · \(title)") }
        // Started before sides kept where they came from: its title alone, as it was.
        guard let s = side(from: t.callId) ?? sides.first(where: { t.output?.contains($0.id) == true }) else { return note("Started a side conversation · \(title)") }
        return sideLine(s)
    }

    /// A proposal (side_propose): a card with Start and Dismiss while it's open; its side's line once started.
    /// Laid out as the grey approval card (docs/design/grey build-approval): the title, and what it is on the right;
    /// the model's reason; Dismiss on the left and Start on the right. It's Piopio's idea, not something waiting on
    /// you, so it has no blue dot.
    func sideProposal(_ t: ToolItem) -> NSAttributedString {
        let title = t.args?["title"]?.stringValue ?? ""
        if let s = side(from: t.callId) { return sideLine(s) }
        guard let expires = openProposals[t.callId] else { return note("Proposed a side conversation · \(title) · closed") }
        // Tabs would catch the right tab stop that places the meta and Start.
        func flat(_ s: String?) -> String { (s ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        let meta = NSFont.systemFont(ofSize: 12)
        let m = NSMutableAttributedString()
        m.append(NSAttributedString(string: flat(title), attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: DS.fg]))
        let project = flat(t.args?["project"]?.stringValue)
        let until = expires == .distantFuture ? nil : "until \(expires.formatted(.dateTime.day().month(.abbreviated)))"
        let what = ["Proposed", project.isEmpty ? nil : "in \(project)", until].compactMap { $0 }.joined(separator: " · ")
        m.append(NSAttributedString(string: "\t" + what, attributes: [.font: meta, .foregroundColor: DS.fg3]))
        let why = flat(t.args?["why"]?.stringValue)
        if !why.isEmpty { m.append(NSAttributedString(string: lineSeparator + why, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg2])) }
        // A thin line of air above the buttons, as in the approval card.
        m.append(NSAttributedString(string: lineSeparator, attributes: [.font: NSFont.systemFont(ofSize: 5)]))
        m.append(NSAttributedString(string: lineSeparator, attributes: [.font: small]))
        m.append(NSAttributedString(string: "Dismiss", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: DS.fg2,
            .link: TranscriptAction.offer(kind: SideActionKind.dismiss, callId: t.callId).url, .toolTip: "Drop this proposal",
        ]))
        m.append(NSAttributedString(string: "\t", attributes: [.font: small]))
        let start = NSMutableAttributedString(attributedString: pill("Start", .offer(kind: SideActionKind.start, callId: t.callId), .primary))
        start.addAttribute(.toolTip, value: "Start it as its own conversation", range: NSRange(location: 0, length: start.length))
        m.append(start)
        let out = NSMutableAttributedString(attributedString: card(m, .approval, lineHeight: 1.6))
        // The right tab sits so Start's capsule (it overhangs its text by 5) ends where the text's left inset begins.
        out.addAttribute(.piopioRightTab, value: NSNumber(value: Double(CardLayoutFragment.padding + 2 + 5)), range: NSRange(location: 0, length: out.length))
        return out
    }

    /// One or more `[Side]` reports: a card while the side still waits on you, else a grey line that opens to the
    /// report, and its branch's Merge · Discard while nobody chose.
    func sideReports(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for r in Self.sideReportParts(text) {
            let now = sides.first { $0.id == r.id }
            let name = now?.title ?? r.name
            if r.needsYou, now?.state == "needs_you" {
                let m = NSMutableAttributedString()
                m.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: DS.accent, .baselineOffset: 1.5]))
                m.append(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: DS.fg]))
                m.append(NSAttributedString(string: " needs you", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3]))
                m.append(NSAttributedString(string: lineSeparator + "It's waiting for an approval there.", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg2]))
                m.append(NSAttributedString(string: lineSeparator, attributes: [.font: small]))
                m.append(pill("Open", .offer(kind: SideActionKind.open, callId: r.id), .primary))
                out.append(card(m, .approval, lineHeight: 1.6))
                continue
            }
            let verb = r.needsYou ? "needed you" : r.verb
            if r.body.isEmpty {
                out.append(note("\(name) · \(verb)"))
            } else {
                let c = DisclosureCard(kind: .thinking, title: "\(name) · \(verb)", body: r.body)
                c.action = ("Open", .offer(kind: SideActionKind.open, callId: r.id))
                c.failed = r.verb == "failed"
                out.append(thinkingCard(c))
            }
            // Its branch, while it waits for your choice; the side's line says merged or discarded after.
            if let now, now.unmerged, let branch = now.branch {
                let m = NSMutableAttributedString(string: "\(branch) · ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3])
                m.append(link("Merge", .merge, now.id, strong: true))
                m.append(NSAttributedString(string: " · ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3]))
                m.append(link("Discard", .discard, now.id))
                out.append(grey(m))
            }
        }
        return out
    }

    /// The side's grey line: its title (opens it) and where it stands now.
    func sideLine(_ s: SideInfo) -> NSAttributedString {
        let m = NSMutableAttributedString()
        if s.state == "needs_you" { m.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: DS.accent, .baselineOffset: 1.5])) }
        m.append(NSAttributedString(string: "Side conversation · ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3]))
        m.append(link(s.title, .open, s.id))
        let state: String = switch s.state {
        case "queued": "queued"
        case "working": s.line.map { $0.isEmpty ? "working" : $0 } ?? "working"
        case "needs_you": "needs you"
        case "done": s.finished.map { $0 } ?? "done"
        case "failed": "failed"
        default: "stopped"
        }
        m.append(NSAttributedString(string: " · \(state)", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3]))
        if s.unmerged {
            m.append(NSAttributedString(string: " · ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3]))
            m.append(link("Merge", .merge, s.id, strong: true))
            m.append(NSAttributedString(string: " · ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: DS.fg3]))
            m.append(link("Discard", .discard, s.id))
        }
        return grey(m)
    }

    private enum SideLink { case open, merge, discard }

    private func link(_ text: String, _ kind: SideLink, _ id: String, strong: Bool = false) -> NSAttributedString {
        let action: String = switch kind {
        case .open: SideActionKind.open
        case .merge: SideActionKind.merge
        case .discard: SideActionKind.discard
        }
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: strong ? .medium : .regular),
            .foregroundColor: strong ? DS.fg : DS.fg2,
            .link: TranscriptAction.offer(kind: action, callId: id).url,
            .toolTip: kind == .open ? "Open it" : kind == .merge ? "Merge its branch" : "Discard its branch",
        ])
    }

    /// A grey line like `note`, with links of its own.
    private func grey(_ m: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: line(m, paragraph(spacing: 14, before: 6)))
        out.addAttribute(.piopioCard, value: CardStyle.note.rawValue, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// `[Side] “Title” (id) finished. …\n\n> answer` (several joined by a blank line), in parts.
    static func sideReportParts(_ text: String) -> [(id: String, name: String, verb: String, needsYou: Bool, body: String)] {
        sideNotes(text).enumerated().map { i, n in
            let raw = text.components(separatedBy: "[Side] ").dropFirst().dropFirst(i).first ?? ""
            let first = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
            var id = "", name = "", verb = ""
            if let open = first.firstIndex(of: "“"), let close = first[open...].firstIndex(of: "”") {
                name = String(first[first.index(after: open)..<close])
                var rest = String(first[first.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("("), let end = rest.firstIndex(of: ")") {
                    id = String(rest[rest.index(after: rest.startIndex)..<end])
                    rest = String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespaces)
                }
                verb = rest.split(whereSeparator: { $0 == "." || $0 == ":" }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? rest
            }
            let needsYou = verb.hasPrefix("needs")
            return (id, name.isEmpty ? n.title : name, needsYou ? "needs you" : verb, needsYou, n.body)
        }
    }
}
