import AppKit
import PiopioKit
import SwiftUI

// /learn's card (docs/spec/14 M5, docs/design/learn, design A): what the conversation taught, grouped by where it goes
// and shown as it will be written: the project's rules as added lines under their section, facts about you as lines.
// The card answers itself (a proposal doesn't stop the agent): Not now and Edit… as text, Save in black. Written past,
// not now, saved or dismissed, it folds to one line. Built from the grey tokens, as the side-conversation offer is.

public final class LearnCardModel: @unchecked Sendable {
    enum Content {
        /// Waiting for you.
        case card(callId: String, file: String?, items: [LearnItem])
        /// One line: what it says, the links in it, and the choices on the right.
        case folded(callId: String, text: String, links: [(String, TranscriptAction)], actions: [(String, TranscriptAction)])
    }

    let content: Content
    var onAction: (@MainActor (TranscriptAction) -> Void)?

    init(_ content: Content) { self.content = content }

    static let padding: CGFloat = 16
    static let top: CGFloat = 13
    static let eyebrow: CGFloat = 18
    static let groupHeader: CGFloat = 18
    static let footerHeight: CGFloat = 46
    static let rowHeight: CGFloat = 40
    static let ruleInset: CGFloat = 8
    nonisolated(unsafe) static let ruleFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    nonisolated(unsafe) static let factFont = NSFont.systemFont(ofSize: 13)
    nonisolated(unsafe) static let whyFont = NSFont.systemFont(ofSize: 11.5)

    /// The rules grouped by section, in the order they came.
    static func sections(_ items: [LearnItem]) -> [(String, [LearnItem])] {
        var out: [(String, [LearnItem])] = []
        for item in items where item.to == .project {
            let name = item.section?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "Lessons"
            if let i = out.firstIndex(where: { $0.0.lowercased() == name.lowercased() }) { out[i].1.append(item) } else { out.append((name, [item])) }
        }
        return out
    }

    func height(width: CGFloat) -> CGFloat {
        guard case .card(_, _, let items) = content else { return Self.rowHeight }
        let inner = max(160, width - Self.padding * 2)
        var total = Self.top + Self.eyebrow + 6
        let rules = Self.sections(items)
        if !rules.isEmpty {
            total += 8 + Self.groupHeader + 6
            for (_, list) in rules {
                total += 17
                for item in list { total += Self.measure("+ " + item.text, Self.ruleFont, inner - Self.ruleInset * 2) + 2 }
            }
            let whys = items.filter { $0.to == .project }.compactMap(\.why)
            if !whys.isEmpty { total += 4 + Self.measure(whys.joined(separator: "; "), Self.whyFont, inner) }
        }
        let facts = items.filter { $0.to == .aboutMe }
        if !facts.isEmpty {
            total += 8 + 0.5 + 8 + Self.groupHeader + 6
            for item in facts { total += Self.measure(item.text, Self.factFont, inner) + 3 }
            let whys = facts.compactMap(\.why)
            if !whys.isEmpty { total += 2 + Self.measure(whys.joined(separator: "; "), Self.whyFont, inner) }
        }
        let skills = items.filter { $0.to == .skill }
        for (i, item) in skills.enumerated() { total += Self.skillHeight(item, inner) - (i == 0 && rules.isEmpty && facts.isEmpty ? 8.5 : 0) }
        return ceil(total + 12 + 0.5 + Self.footerHeight)
    }

    nonisolated(unsafe) static let skillNameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    nonisolated(unsafe) static let usedWhenFont = NSFont.systemFont(ofSize: 12.5)
    static let previewLines = 3

    /// A skill's first steps as the card shows them, and how many lines are left out.
    static func preview(_ body: String) -> (String, Int) {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (lines.prefix(previewLines).joined(separator: "\n"), max(0, lines.count - previewLines))
    }

    static func skillHeight(_ item: LearnItem, _ inner: CGFloat) -> CGFloat {
        let (shown, more) = preview(item.body ?? "")
        var h = 8 + 0.5 + 8 + groupHeader + 6 + measure(item.name ?? "", skillNameFont, inner) + 2 + measure(item.text, usedWhenFont, inner) + 4
        h += measure(shown, ruleFont, inner - ruleInset * 2) + 4
        if more > 0 { h += 16 }
        if let why = item.why { h += 2 + measure(why, whyFont, inner) }
        return h
    }

    static func measure(_ text: String, _ font: NSFont, _ width: CGFloat) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

final class LearnCardAttachment: NSTextAttachment, @unchecked Sendable {
    let model: LearnCardModel

    init(model: LearnCardModel) {
        self.model = model
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = LearnCardViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class LearnCardViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let model = (textAttachment as! LearnCardAttachment).model
        view = MainActor.assumeIsolated { ArrowHostingView(rootView: LearnCardView(model: model)) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let model = (textAttachment as! LearnCardAttachment).model
        let width = textContainer?.size.width ?? proposedLineFragment.width
        return CGRect(x: 0, y: -6, width: width, height: model.height(width: width))
    }
}

struct LearnCardView: View {
    let model: LearnCardModel

    var body: some View {
        switch model.content {
        case .card(let callId, let file, let items): card(callId, file, items)
        case .folded(_, let text, let links, let actions): row(text, links, actions)
        }
    }

    private func card(_ callId: String, _ file: String?, _ items: [LearnItem]) -> some View {
        let rules = LearnCardModel.sections(items)
        let facts = items.filter { $0.to == .aboutMe }
        let skills = items.filter { $0.to == .skill }
        let count = items.count
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    glyph("sparkles")
                    Text("Learned · \(count) thing\(count == 1 ? "" : "s")").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: DS.fg2))
                    Text("from this conversation").font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3))
                    Spacer(minLength: 6)
                    Circle().fill(Color(nsColor: DS.amber)).frame(width: 6, height: 6)
                    Text("Waiting for you").font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3))
                }
                .frame(height: LearnCardModel.eyebrow)
                .padding(.bottom, 6)
                if !rules.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        groupHeader("doc.text", file ?? "AGENTS.md", "in this project", "+\(rules.reduce(0) { $0 + $1.1.count }) line\(rules.reduce(0) { $0 + $1.1.count } == 1 ? "" : "s")")
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rules.enumerated()), id: \.offset) { _, section in
                                Text("## \(section.0)").font(Font(LearnCardModel.ruleFont)).foregroundStyle(Color(nsColor: DS.fg3))
                                    .frame(height: 17, alignment: .leading).padding(.horizontal, LearnCardModel.ruleInset)
                                ForEach(section.1) { item in
                                    Text("+ " + item.text).font(Font(LearnCardModel.ruleFont)).foregroundStyle(Color(nsColor: DS.green))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, LearnCardModel.ruleInset)
                                        .background(Color(nsColor: DS.green).opacity(0.09))
                                        .padding(.bottom, 2)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        why(items.filter { $0.to == .project })
                    }
                    .padding(.top, 8)
                }
                if !facts.isEmpty {
                    if !rules.isEmpty { Rectangle().fill(Color(nsColor: DS.line)).frame(height: 0.5).padding(.top, 8) }
                    VStack(alignment: .leading, spacing: 3) {
                        groupHeader("person", "About me", nil, "+\(facts.count)")
                        ForEach(facts) { item in
                            Text(item.text).font(Font(LearnCardModel.factFont)).foregroundStyle(Color(nsColor: DS.fg))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        why(facts)
                    }
                    .padding(.top, 8)
                }
                ForEach(Array(skills.enumerated()), id: \.offset) { i, item in
                    if i > 0 || !rules.isEmpty || !facts.isEmpty { Rectangle().fill(Color(nsColor: DS.line)).frame(height: 0.5).padding(.top, 8) }
                    skill(item)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LearnCardModel.padding)
            .padding(.top, LearnCardModel.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(Color(nsColor: DS.line)).frame(height: 0.5)
            HStack(spacing: 6) {
                TextButton(title: "Not now", help: "Fold it; save it later from here") { act(.learn(kind: "later", callId: callId)) }
                TextButton(title: "Edit…", help: "Change, move or drop what it keeps") { act(.learn(kind: "edit", callId: callId)) }
                Spacer(minLength: 8)
                DarkButton(title: "Save", help: "Write it: \(rules.isEmpty ? "" : (file ?? "AGENTS.md"))\(!rules.isEmpty && !facts.isEmpty ? " and " : "")\(facts.isEmpty ? "" : "About me")") {
                    act(.learn(kind: "save", callId: callId))
                }
            }
            .padding(.leading, 8).padding(.trailing, 12)
            .frame(height: LearnCardModel.footerHeight)
            .background(Color(nsColor: DS.win))
        }
        .background(Color(nsColor: DS.card))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color(nsColor: DS.line), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Learned \(count) things, waiting for you")
    }

    private func row(_ text: String, _ links: [(String, TranscriptAction)], _ actions: [(String, TranscriptAction)]) -> some View {
        HStack(spacing: 8) {
            glyph("sparkles")
            Text(text).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(nsColor: DS.fg)).lineLimit(1)
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                Text("·").foregroundStyle(Color(nsColor: DS.fg3))
                if case .learn = link.1 {
                    Text(link.0).font(.system(size: 12.5)).foregroundStyle(Color(nsColor: DS.fg2)).lineLimit(1)
                } else {
                    Button(link.0) { act(link.1) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color(nsColor: DS.accent)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                TextButton(title: a.0) { act(a.1) }
            }
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: DS.card), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color(nsColor: DS.line), lineWidth: 0.5))
    }

    /// A skill (docs/spec/40 SH0): new or added to one of yours, its name, when it's used, its first steps.
    private func skill(_ item: LearnItem) -> some View {
        let (shown, more) = LearnCardModel.preview(item.body ?? "")
        return VStack(alignment: .leading, spacing: 0) {
            groupHeader("text.book.closed", item.addTo == nil ? "New skill" : "Add to a skill", item.projectOnly == true ? "this project only" : "every project", "")
            Text(item.addTo ?? item.name ?? "").font(Font(LearnCardModel.skillNameFont)).foregroundStyle(Color(nsColor: DS.fg))
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
            Text(item.text).font(Font(LearnCardModel.usedWhenFont)).foregroundStyle(Color(nsColor: DS.fg2))
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
            Text(shown).font(Font(LearnCardModel.ruleFont)).foregroundStyle(Color(nsColor: item.addTo == nil ? DS.fg : DS.green))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LearnCardModel.ruleInset)
                .background(item.addTo == nil ? Color(nsColor: DS.chip).opacity(0.6) : Color(nsColor: DS.green).opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.bottom, 4)
            if more > 0 { Text("\(more) more line\(more == 1 ? "" : "s") · Edit… shows them").font(.system(size: 11.5)).foregroundStyle(Color(nsColor: DS.fg3)).frame(height: 16, alignment: .leading) }
            why([item])
        }
        .padding(.top, 8)
    }

    private func groupHeader(_ symbol: String, _ title: String, _ place: String?, _ count: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Color(nsColor: DS.fg3))
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: DS.fg))
            if let place { Text(place).font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg2)) }
            Spacer(minLength: 6)
            Text(count).font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3))
        }
        .frame(height: LearnCardModel.groupHeader)
        .padding(.bottom, 6)
    }

    @ViewBuilder private func why(_ items: [LearnItem]) -> some View {
        let whys = items.compactMap(\.why)
        if !whys.isEmpty {
            Text(whys.joined(separator: "; ").prefix(1).uppercased() + whys.joined(separator: "; ").dropFirst() + ".")
                .font(Font(LearnCardModel.whyFont)).foregroundStyle(Color(nsColor: DS.fg3))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(nsColor: DS.fg3)).frame(width: 16)
    }

    private func act(_ action: TranscriptAction) {
        MainActor.assumeIsolated { model.onAction?(action) }
    }
}
