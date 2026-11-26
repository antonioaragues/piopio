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
        let title = t.args["title"]?.stringValue ?? "Side conversation"
        if t.status == .running || t.status == .pendingApproval { return note("Starting a side conversation · \(title)") }
        // Started before sides kept where they came from: its title alone, as it was.
        guard let s = side(from: t.callId) ?? sides.first(where: { t.output?.contains($0.id) == true }) else { return note("Started a side conversation · \(title)") }
        return sideLine(s)
    }

    /// An offer (side_offer, docs/design/side-conversations 1a): the card while it waits; the side's row once New
    /// conversation started it; the question and your answer, boxed, once you chose Do it here.
    func sideOffer(_ t: ToolItem) -> NSAttributedString {
        let title = t.args["title"]?.stringValue ?? ""
        if let s = side(from: t.callId) { return attachmentParagraph(SideOfferAttachment(model: SideOfferModel(.side(s))), spacing: 14) }
        let project = t.args["project"]?.stringValue ?? ""
        if keptHere.contains(t.callId) {
            return answeredCard(context: ["This looks like its own task", project.isEmpty ? nil : "in \(project)"].compactMap { $0 }.joined(separator: " · "),
                                question: title, answer: "Do it here")
        }
        let model = SideOfferModel(.offer(callId: t.callId, title: title, brief: t.args["brief"]?.stringValue ?? "", project: project.isEmpty ? nil : project))
        return attachmentParagraph(SideOfferAttachment(model: model), spacing: 14)
    }

    /// A proposal (side_propose): a card with Start and Dismiss while it's open; its side's line once started.
    /// Laid out as the grey approval card (docs/design/grey build-approval): the title, and what it is on the right;
    /// the model's reason; Dismiss on the left and Start on the right. It's Piopio's idea, not something waiting on
    /// you, so it has no blue dot.
    func sideProposal(_ t: ToolItem) -> NSAttributedString {
        let title = t.args["title"]?.stringValue ?? ""
        if let s = side(from: t.callId) { return sideLine(s) }
        guard let expires = openProposals[t.callId] else { return note("Proposed a side conversation · \(title) · closed") }
        let project = t.args["project"]?.stringValue ?? ""
        let until = expires == .distantFuture ? nil : "until \(expires.formatted(.dateTime.day().month(.abbreviated)))"
        let what = ["Proposed", project.isEmpty ? nil : "in \(project)", until].compactMap { $0 }.joined(separator: " · ")
        return actionCard(dot: false, title: title, meta: what, lines: [(t.args["why"]?.stringValue ?? "", DS.fg2)],
                          secondary: [CardButton(title: "Dismiss", action: .offer(kind: SideActionKind.dismiss, callId: t.callId), help: "Drop this proposal")],
                          primary: CardButton(title: "Start", action: .offer(kind: SideActionKind.start, callId: t.callId), help: "Start it as its own conversation"))
    }

    /// One or more `[Side]` reports: a card while the side still waits on you, else a grey line that opens to the
    /// report, and its branch's Merge · Discard while nobody chose.
    func sideReports(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for r in Self.sideReportParts(text) {
            let now = sides.first { $0.id == r.id }
            let name = now?.title ?? r.name
            if r.needsYou, now?.state == "needs_you" {
                out.append(actionCard(title: name, after: " needs you", lines: [("It's waiting for an approval there.", DS.fg2)],
                                      primary: CardButton(title: "Open", action: .offer(kind: SideActionKind.open, callId: r.id))))
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
        let state = SideOfferModel.state(s)
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
