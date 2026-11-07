import PiopioKit
import PiopioTranscript
import SwiftUI

// Start pages (docs/design/start-pages): each sidebar + opens a page for that kind in the main window. One layout for
// all of them: the kind, a title, one sentence, the composer card with the main action at its bottom right, then a
// "start from…" section and hints. Nothing is created until you start; what you type is kept as a draft.

// MARK: Drafts

/// What each start page holds while you write, saved under the engine home so it survives a relaunch.
@MainActor @Observable final class StartDrafts {
    static let shared = StartDrafts()

    struct Draft: Codable, Equatable {
        /// The message (chat), the question (debate) or the instructions (agent).
        var text = ""
        /// An agent's name.
        var name = ""
        var criteria = ""
        var instructions = ""
        var avatar = ""
        var template: String?
        /// Before docs/spec/18 phase 2: chats to bring into a new notebook (read from old drafts, unused).
        var threads: [String] = []
        /// An agent's schedule as a cron; empty for none.
        var schedule = ""

        init() {}

        /// Missing fields keep their defaults, so a draft saved by another version still opens.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            criteria = try c.decodeIfPresent(String.self, forKey: .criteria) ?? ""
            instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
            avatar = try c.decodeIfPresent(String.self, forKey: .avatar) ?? ""
            template = try c.decodeIfPresent(String.self, forKey: .template)
            threads = try c.decodeIfPresent([String].self, forKey: .threads) ?? []
            schedule = try c.decodeIfPresent(String.self, forKey: .schedule) ?? ""
        }
    }

    private var drafts: [String: Draft] = [:]
    private let url: URL

    init(home: URL = EngineClient.defaultHome()) {
        url = home.appending(path: "drafts/start.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Draft].self, from: data) { drafts = saved }
    }

    /// The draft key for a new session in a project.
    static func sessionKey(_ projectId: String) -> String { "session:" + projectId }

    subscript(kind: StartKind) -> Draft { self[key: kind.rawValue] }
    subscript(key key: String) -> Draft { drafts[key] ?? Draft() }

    func update(_ kind: StartKind, _ change: (inout Draft) -> Void) { update(key: kind.rawValue, change) }
    func update(key: String, _ change: (inout Draft) -> Void) {
        var draft = self[key: key]
        change(&draft)
        guard draft != self[key: key] else { return }
        drafts[key] = draft == Draft() ? nil : draft
        save()
    }

    func binding(_ kind: StartKind, _ field: WritableKeyPath<Draft, String>) -> Binding<String> { binding(key: kind.rawValue, field) }
    func binding(key: String, _ field: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(get: { self[key: key][keyPath: field] }, set: { value in self.update(key: key) { $0[keyPath: field] = value } })
    }

    func clear(_ kind: StartKind) { clear(key: kind.rawValue) }
    func clear(key: String) {
        guard drafts[key] != nil else { return }
        drafts[key] = nil
        save()
    }

    /// Something typed, so the sidebar keeps a draft row for it.
    func hasContent(_ kind: StartKind) -> Bool { hasContent(key: kind.rawValue) }
    func hasContent(key: String) -> Bool {
        let d = self[key: key]
        return !(d.text + d.name + d.criteria + d.instructions).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The draft row's title: the name typed so far, or the kind's.
    func title(_ kind: StartKind) -> String {
        let name = self[kind].name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? kind.title : name
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(drafts).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {}
    }
}

extension StartKind {
    var title: String {
        switch self {
        case .chat: "New chat"
        case .debate: "New debate"
        case .agent: "New agent"
        case .project: "New project"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left"
        case .debate: "person.2"
        case .agent: "smallcircle.circle"
        case .project: "folder"
        }
    }
}

// MARK: Tokens (the handoff's, mapped onto the grey-ink ones; light and dark)

private enum StartStyle {
    static let column: CGFloat = 720
    static let gap: CGFloat = 28
    /// The dashed outline of the drop zone and of "Attach a file".
    static let dash = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.22) : NSColor(srgbRed: 0.81, green: 0.80, blue: 0.77, alpha: 1)
    })
    /// The kind tile and selected things: a soft wash of the accent.
    static let accentWash = Color.accentColor.opacity(0.12)
    static let accentFaint = Color.accentColor.opacity(0.06)
    /// The debate's settings strip.
    static let strip = Color.dsBubble
    /// The two debaters' badges.
    static let sideA = Color.accentColor
    static let sideB = Color.orange
}

// MARK: Motion: the start page's composer becomes the conversation's

/// The namespace the start page's card and the conversation's composer share, so starting moves the card down into
/// place instead of cutting to the new view.
private struct ComposerSpaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
/// Back to where you were before the start page (Esc).
private struct StartBackKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable () -> Void)? = nil }

extension EnvironmentValues {
    var composerSpace: Namespace.ID? {
        get { self[ComposerSpaceKey.self] }
        set { self[ComposerSpaceKey.self] = newValue }
    }
    var startBack: (@MainActor @Sendable () -> Void)? {
        get { self[StartBackKey.self] }
        set { self[StartBackKey.self] = newValue }
    }
}

private struct ComposerMorph: ViewModifier {
    @Environment(\.composerSpace) private var space
    func body(content: Content) -> some View {
        if let space { content.matchedGeometryEffect(id: "composer", in: space, properties: .frame, anchor: .bottom) } else { content }
    }
}

extension View {
    /// Marks the composer whose place the start page's card moves into (one on screen at a time).
    func composerMorph() -> some View { modifier(ComposerMorph()) }
}

enum StartMotion {
    /// Long enough to follow the card down, short enough not to wait for it.
    static let morph = Animation.smooth(duration: 0.42)
}

/// Opens what was just started, moving the composer down into place.
@MainActor private func morph(to target: SidebarItem, _ item: Binding<SidebarItem>) {
    withAnimation(StartMotion.morph) { item.wrappedValue = target }
}

// MARK: Page

/// The start page for one kind. Chat and debate are one page with a mode switch.
struct StartView: View {
    let engine: EngineController
    let kind: StartKind
    @Binding var item: SidebarItem

    var body: some View {
        StartColumn(top: kind == .agent ? 112 : 128) {
            switch kind {
            case .chat, .debate: ChatStart(engine: engine, mode: kind, item: $item)
            case .agent: AgentStart(engine: engine, item: $item)
            case .project: EmptyView() // Home is the start for projects now (docs/spec/18); RootView redirects
            }
        }
        .id(kind == .debate ? StartKind.chat : kind)
    }
}

/// The one centered column every start page uses: 720 wide, 28 between blocks.
private struct StartColumn<Content: View>: View {
    let top: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StartStyle.gap) { content }
                .padding(.horizontal, 32)
                .padding(.top, top)
                .padding(.bottom, 64)
                .frame(maxWidth: StartStyle.column + 64)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Shared parts

/// The 24pt tile with the kind's icon in the accent, and its name (or the project's, for a new session).
private struct KindLabel: View {
    let symbol: String
    let text: String
    init(kind: StartKind) { symbol = kind.symbol; text = kind.title }
    init(symbol: String, text: String) { self.symbol = symbol; self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(StartStyle.accentWash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The kind, the title (text or the name field) and the one-sentence description.
private struct StartHeader<Title: View>: View {
    let kind: StartKind
    let description: String
    @ViewBuilder var title: Title

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KindLabel(kind: kind).padding(.bottom, 4)
            title
            Text(description).font(.system(size: 15)).lineSpacing(4.5).foregroundStyle(Color.dsFg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum TitleFont {
    static let font = Font.system(size: 34, weight: .bold)
    static let tracking: CGFloat = -0.68
}

private struct TitleText: View {
    let text: String
    var body: some View {
        Text(text).font(TitleFont.font).tracking(TitleFont.tracking).foregroundStyle(Color.dsFg)
            .accessibilityAddTraits(.isHeader)
    }
}

/// An agent's name, typed in place as the title: no border, the placeholder in the same style.
private struct TitleField: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<StartField?>.Binding
    let onSubmit: () -> Void

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.dsFg3))
            .textFieldStyle(.plain)
            .font(TitleFont.font)
            .tracking(TitleFont.tracking)
            .foregroundStyle(Color.dsFg)
            .focused(focused, equals: .name)
            .onSubmit(onSubmit)
            .accessibilityLabel(placeholder)
    }
}

enum StartField: Hashable { case name, text, extra }

/// The composer card: the text, anything extra inside it, and a footer with settings on the left and the main action
/// at the bottom right.
private struct ComposerCard<Extra: View, Leading: View, Action: View>: View {
    @ViewBuilder var text: AnyView
    @ViewBuilder var extra: Extra
    @ViewBuilder var leading: Leading
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            text
            extra
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 8)
                action
            }
            .padding(.top, 10).padding(.horizontal, 12).padding(.bottom, 12)
        }
        .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.04), radius: 12, y: 8)
        .composerMorph()
    }
}

/// The card's text: 16pt, no border, a placeholder. Return submits when `returnSubmits`; ⇧↩ adds a line; ⌘↩ always
/// submits.
private struct CardText: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<StartField?>.Binding
    var field: StartField = .text
    var returnSubmits = false
    var minHeight: CGFloat = 56
    var escape: (() -> Void)?
    let submit: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).font(.system(size: 16)).foregroundStyle(Color.dsFg3).padding(.leading, 5).allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .focused(focused, equals: field)
                .frame(minHeight: minHeight, maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(placeholder)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) || (returnSubmits && press.modifiers.isEmpty) { submit(); return .handled }
                    return .ignored
                }
                .onKeyPress(.escape) {
                    guard let escape else { return .ignored }
                    escape()
                    return .handled
                }
        }
        .padding(.horizontal, 20 - 5)
        .padding(.top, 18)
    }
}

/// The page's main action: dark, 36pt, radius 10, the label with its shortcut. Grey while it can't run yet.
private struct MainAction: View {
    let title: String
    var busy = false
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini) }
                Text(title)
            }
        }
        .buttonStyle(MainActionStyle(enabled: enabled && !busy))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!enabled || busy)
    }
}

private struct MainActionStyle: ButtonStyle {
    let enabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(enabled ? Color.dsInvFg : Color.dsFg2)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(enabled ? Color.dsInv : Color.dsTrack, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// A 36pt icon-only button in the card's footer; `bordered` draws its outline (the new-session attach button).
private struct FooterIcon: View {
    let symbol: String
    let label: String
    var bordered = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15)) }
            .buttonStyle(IconButtonStyle(size: 36))
            .overlay { if bordered { RoundedRectangle(cornerRadius: DS.Radius.selector, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1).allowsHitTesting(false) } }
            .help(label).accessibilityLabel(label)
    }
}

/// The round 36pt send button: dark once there is something to send (the same on Chat and New session).
private struct SendCircle: View {
    let enabled: Bool
    var busy = false
    var label = "Send"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)) }
            }
            .foregroundStyle(enabled ? Color.dsInvFg : Color.dsFg2)
            .frame(width: 36, height: 36)
            .background(enabled ? Color.dsInv : Color.dsTrack, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(label)
        .help("\(label) (↩)")
    }
}

/// A footer selector: an icon, its value and a small chevron; a grey fill on hover.
private struct FooterSelector: View {
    let symbol: String?
    let title: String
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12)) }
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.dsFg3)
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.dsFg2)
        .frame(height: 36)
    }
}

/// "Section title" in 13/600, with something on the right.
private struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsFg2).accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// The page's hints, 13pt muted, separated by dots.
private struct Hints: View {
    let items: [String]
    var body: some View {
        Text(items.joined(separator: "   ·   ")).font(.system(size: 13)).foregroundStyle(Color.dsFg2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What went wrong, and that nothing was lost.
private struct StartError: View {
    let text: String?
    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action).buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.accentColor)
    }
}

/// A list in a card: rows divided by hairlines.
private struct CardList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "36 min", "5 d", "now".
private func age(_ iso: String) -> String {
    let seconds = Date().timeIntervalSince(MainSidebar.date(iso))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min" }
    if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
    return "\(Int(seconds / 86_400)) d"
}

// MARK: Chat and debate

/// New chat, with a Chat | Debate switch in the composer. The text stays when you switch.
private struct ChatStart: View {
    let engine: EngineController
    let mode: StartKind
    @Binding var item: SidebarItem
    private var drafts: StartDrafts { .shared }
    @State private var attachments: [PendingAttachment] = []
    @State private var model: ModelRef?
    @State private var showModels = false
    /// What the chat is about: a project (a chat in its folder).
    @State private var context: Context?
    @State private var sending = false
    @State private var error: String?
    /// The chat made for a message that then failed to send, so Retry doesn't make another.
    @State private var pending: ContainerRef?
    // Debate
    @State private var author: ModelRef?
    @State private var reviewer: ModelRef?
    @AppStorage("debate.rounds") private var rounds = 6
    @AppStorage("debate.reviewer") private var lastReviewer = ""
    @State private var picking: DebateRole?
    @FocusState private var focus: StartField?

    enum Context: Hashable { case project(String) }

    private var debate: Bool { mode == .debate }
    private var text: String { drafts[mode].text }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !sending && !trimmed.isEmpty && (!debate || (author != nil && reviewer != nil)) }

    var body: some View {
        StartHeader(kind: mode, description: debate
            ? "One model answers, the other critiques it, round by round, until they agree. You get the agreed answer and any points they never settled."
            : "A conversation keeps its own history. Move it into a project whenever it grows into a subject.") {
            TitleText(text: debate ? "What should they work out?" : "What's on your mind?")
        }
        VStack(alignment: .leading, spacing: 12) {
            ComposerCard {
                AnyView(CardText(placeholder: debate ? "A question or decision worth a second opinion…" : "Ask anything…", text: drafts.binding(mode, \.text), focused: $focus, returnSubmits: true, submit: send))
            } extra: {
                if !attachments.isEmpty { attachmentTiles.padding(.horizontal, 20).padding(.top, 8) }
                if debate { debateStrip.padding(.horizontal, 12).padding(.top, 12) }
            } leading: {
                if !debate { AttachButton(pick: attach, size: 36) }
                ModeSwitch(mode: mode) { switchMode(to: $0) }
            } action: {
                if debate {
                    MainAction(title: "Start debate ↩", busy: sending, enabled: canSend, action: send)
                } else {
                    modelSelector
                    sendButton
                }
            }
            StartError(text: error)
        }
        if debate {
            if let author, let reviewer, family(author) == family(reviewer) {
                Label("Models from different makers catch more of each other's blind spots.", systemImage: "lightbulb")
                    .font(.system(size: 13)).foregroundStyle(Color.dsFg2)
            }
            Hints(items: ["Each round runs both models, so a debate uses more than a chat" + (estimate.map { " (about \($0) at most)" } ?? "") + ".", "You can step in between rounds."])
        } else {
            contextSection
            Hints(items: ["\(QuickChatShortcut.current.label) Quick Chat from any app", "↩ send", "⇧↩ new line"])
        }
        Color.clear.frame(height: 0)
            .onAppear {
                defaults()
                focus = .text
            }
            .onChange(of: text) { _, t in
                // "/debate" switches to Debate, with what follows as the question.
                if !debate, t.hasPrefix("/debate") {
                    drafts.update(.chat) { $0.text = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                    switchMode(to: .debate)
                }
            }
    }

    // MARK: Chat

    private var modelSelector: some View {
        Button { showModels = true } label: { FooterSelector(symbol: nil, title: modelLabel(model ?? engine.preferredModel)) }
            .buttonStyle(SelectorStyle())
            .help("The model for this chat")
            .popover(isPresented: $showModels, arrowEdge: .bottom) {
                ModelPicker(engine: engine, selected: model ?? engine.preferredModel) { m in model = m; showModels = false }
            }
    }

    private var sendButton: some View {
        SendCircle(enabled: canSend, busy: sending, action: send)
    }

    private var attachmentTiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { a in
                    HStack(spacing: 6) {
                        Image(systemName: a.isImage ? "photo" : "doc").font(.system(size: 11)).foregroundStyle(Color.dsFg3)
                        Text(a.name).font(.system(size: 12.5)).foregroundStyle(Color.dsFg).lineLimit(1)
                        Button { attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.dsFg3) }
                            .buttonStyle(.plain).accessibilityLabel("Remove attachment \(a.name)")
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
                }
            }
        }
    }

    /// Projects to talk about, and a file to attach.
    @ViewBuilder private var contextSection: some View {
        let areas = Areas.shared.set
        let projects = areas.showsProjects ? Array(engine.projects.prefix(6)) : []
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Talk about something you already have")
            FlowLayout(spacing: 8) {
                ForEach(projects) { p in
                    ContextChip(symbol: "folder", title: p.name, on: context == .project(p.id), help: "Chat in \(p.name): it can read the folder's files") {
                        context = context == .project(p.id) ? nil : .project(p.id)
                    }
                }
                ContextChip(symbol: "paperclip", title: "Attach a file", on: false, dashed: true, help: "Images, PDFs or text files", action: attach)
            }
            if let context { Text(contextNote(context)).font(.system(size: 13)).foregroundStyle(Color.dsFg2) }
        }
    }

    private func contextNote(_ context: Context) -> String {
        switch context {
        case .project(let id): "The chat opens in \(engine.projects.first { $0.id == id }?.name ?? "the project") and can read its files. It's listed under the project."
        }
    }

    // MARK: Debate

    /// [A · model] vs [B · model] ⇄ · Until they agree · max N rounds.
    private var debateStrip: some View {
        HStack(spacing: 8) {
            side(.author, badge: "A", tint: StartStyle.sideA, $author)
            Text("vs").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
            side(.reviewer, badge: "B", tint: StartStyle.sideB, $reviewer)
            Button { (author, reviewer) = (reviewer, author) } label: { Image(systemName: "arrow.left.arrow.right").font(.system(size: 12)) }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Swap who answers and who critiques").accessibilityLabel("Swap models")
            Spacer(minLength: 8)
            Menu {
                ForEach(2...12, id: \.self) { n in Button("Up to \(n) rounds") { rounds = n } }
            } label: {
                FooterSelector(symbol: "checkmark", title: "Until they agree · max \(rounds) rounds")
            }
            .menuStyle(.button).buttonStyle(SelectorStyle()).menuIndicator(.hidden).fixedSize()
            .help("It stops as soon as they agree")
        }
        .padding(.horizontal, 8)
        .background(StartStyle.strip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func side(_ role: DebateRole, badge: String, tint: Color, _ model: Binding<ModelRef?>) -> some View {
        Button { picking = role } label: {
            HStack(spacing: 6) {
                Text(badge).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                FooterSelector(symbol: nil, title: modelLabel(model.wrappedValue))
            }
        }
        .buttonStyle(SelectorStyle())
        .help(role == .author ? "A answers first and revises" : "B critiques each answer until it agrees")
        .accessibilityLabel("\(badge): \(modelLabel(model.wrappedValue))")
        .popover(isPresented: Binding(get: { picking == role }, set: { if !$0 { picking = nil } }), arrowEdge: .bottom) {
            ModelPicker(engine: engine, selected: model.wrappedValue) { m in model.wrappedValue = m; picking = nil }
        }
    }

    private func modelLabel(_ ref: ModelRef?) -> String {
        engine.model(ref).map(ModelChip.short) ?? ref?.id ?? "Choose a model"
    }

    /// The maker: "anthropic" in "anthropic/claude-…", else the provider.
    private func family(_ m: ModelRef) -> String {
        m.id.contains("/") ? String(m.id.split(separator: "/")[0]) : m.provider
    }

    /// The Chat model answers; the last reviewer critiques, or a model from another maker.
    private func defaults() {
        author = author ?? engine.preferredModel
        guard reviewer == nil else { return }
        let parts = lastReviewer.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2, engine.model(ModelRef(provider: parts[0], id: parts[1])) != nil {
            reviewer = ModelRef(provider: parts[0], id: parts[1])
        } else if let author {
            let other = engine.models.first { family(ModelRef(provider: $0.provider, id: $0.id)) != family(author) && $0.provider != "faux" }
            reviewer = other.map { ModelRef(provider: $0.provider, id: $0.id) } ?? author
        }
    }

    /// Up to `rounds` rounds of a one-page answer: each side's context grows by one exchange a round.
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

    // MARK: Actions

    /// The text moves with you; the draft you leave goes, so no stray draft row is left behind.
    private func switchMode(to target: StartKind) {
        guard target != mode else { return }
        let carried = drafts[mode].text
        drafts.clear(mode)
        if !carried.isEmpty { drafts.update(target) { $0.text = carried } }
        error = nil
        item = .start(target)
    }

    /// The +: files, or a folder's readable files (as the conversation's + does), from one panel.
    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if url.hasDirectoryPath {
                let (files, note) = AttachmentLoader.folder(url)
                attachments.append(contentsOf: files)
                if let note { error = note }
                continue
            }
            do { attachments.append(try AttachmentLoader.load(url)) } catch { self.error = error.localizedDescription }
        }
    }

    private func send() {
        guard canSend else { return }
        error = nil
        sending = true
        Task {
            defer { sending = false }
            if debate { await startDebate() } else { await sendChat() }
        }
    }

    private func sendChat() async {
        let message = trimmed
        let created: ContainerRef?
        if let pending { created = pending } else {
            switch context {
            case .project(let id):
                guard let project = engine.projects.first(where: { $0.id == id }) else { error = "That project isn't available any more. Pick another, or none."; return }
                created = try? await engine.createBuildSession(in: project, workOn: .current, mode: nil, model: model, profile: .chat)
            case nil:
                created = await engine.createThread(model: model)
            }
        }
        guard let ref = created else {
            error = "Couldn't start the chat because the engine isn't connected. Nothing was created, and your message is kept."
            return
        }
        pending = ref
        let thread = engine.thread(ref)
        await thread.open()
        guard await thread.send(message, attachments: attachments.map(\.attachment)) else {
            error = (thread.error ?? "Couldn't send.") + " Your message is kept; try again."
            return
        }
        try? await engine.refreshCatalog()
        switch ref.kind {
        case .build: morph(to: .session(ref.id), $item)
        default: morph(to: .chat(ref.id), $item)
        }
        // Cleared once the page has moved on, so it doesn't flash empty first.
        drafts.clear(.chat)
        attachments = []
        pending = nil
    }

    private func startDebate() async {
        guard let author, let reviewer else { return }
        let config = DebateConfig(goal: trimmed, criteria: nil, participants: [.init(role: .author, model: author), .init(role: .reviewer, model: reviewer)], maxRounds: rounds)
        do {
            let ref = try await engine.createDebate(config)
            lastReviewer = "\(reviewer.provider)|\(reviewer.id)"
            drafts.clear(.debate)
            morph(to: .chat(ref.id), $item)
        } catch {
            self.error = ((error as? EngineError)?.message ?? error.localizedDescription) + " Nothing was started, and your question is kept."
        }
    }
}

/// Chat | Debate, as a radio group: click, or ← → once it has focus.
private struct ModeSwitch: View {
    let mode: StartKind
    let pick: (StartKind) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(.chat, "Chat")
            segment(.debate, "Debate")
        }
        .padding(2)
        .background(Color.dsTrack, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { pick(.chat); return .handled }
        .onKeyPress(.rightArrow) { pick(.debate); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }

    private func segment(_ kind: StartKind, _ title: String) -> some View {
        let on = mode == kind
        return Button { pick(kind) } label: {
            Text(title).font(.system(size: 13, weight: on ? .medium : .regular))
                .foregroundStyle(on ? Color.dsFg : Color.dsFg2)
                .padding(.horizontal, 12).frame(height: 30)
                .background(on ? Color.dsSeg : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? Color.dsLine : .clear, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityHint(kind == .debate ? "Two models work on it until they agree" : "One model answers")
    }
}

/// A 36pt pill: an icon and a name. Selected: an accent outline on a faint wash. "Attach a file" is dashed.
private struct ContextChip: View {
    let symbol: String
    let title: String
    let on: Bool
    var dashed = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(on ? Color.accentColor : Color.dsFg2)
                Text(title).font(.system(size: 13.5)).foregroundStyle(Color.dsFg).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(on ? StartStyle.accentFaint : (hovering ? Color.dsChip : Color.dsCard), in: Capsule())
            .overlay {
                if dashed { Capsule().strokeBorder(StartStyle.dash, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                else { Capsule().strokeBorder(on ? Color.accentColor : Color.dsLine, lineWidth: on ? 1.5 : 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

// MARK: Recent folders (Home's project menu)

/// A folder on this Mac that looks like somewhere you work: git repos in the usual places, and folders the pi CLI used.
struct RecentFolder: Identifiable, Hashable, Sendable {
    let url: URL
    let branch: String?
    let modified: Date
    var id: String { url.path }

    /// "~/Proyectos/piopio".
    var path: String { url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }

    nonisolated static func scan() -> [RecentFolder] {
        let found = BuildFirstRun.scan(limit: 40)
        var seen = Set<String>()
        let urls = (found.repos.map(\.url) + found.piFolders).filter { seen.insert($0.standardizedFileURL.path).inserted }
        return urls.map { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return RecentFolder(url: url, branch: branch(url), modified: modified)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// The checked-out branch from .git/HEAD, or nil without git.
    nonisolated static func branch(_ url: URL) -> String? {
        guard let head = try? String(contentsOf: url.appending(path: ".git/HEAD"), encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("ref: refs/heads/") ? String(line.dropFirst(16)) : String(line.prefix(7))
    }
}

// MARK: Agent

/// New agent: icon and name as the title, what it should do in your words, its schedule, and a template to start
/// from. The name and the instructions are required.
private struct AgentStart: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    private var drafts: StartDrafts { .shared }
    @State private var templates: [AgentTemplate] = []
    @State private var creating = false
    @State private var error: String?
    @FocusState private var focus: StartField?

    private var draft: StartDrafts.Draft { drafts[.agent] }
    private var name: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var instructions: String { draft.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { !name.isEmpty && !instructions.isEmpty }

    var body: some View {
        StartHeader(kind: .agent, description: "Runs on a schedule on this Mac, remembers what you teach it, and reaches you only when something matters.") {
            HStack(spacing: 14) {
                AvatarPicker(avatar: drafts.binding(.agent, \.avatar), size: CGSize(width: 44, height: 44))
                TitleField(placeholder: "Name your agent", text: drafts.binding(.agent, \.name), focused: $focus) { focus = .text }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            ComposerCard {
                AnyView(CardText(placeholder: "What should it do? In your own words, e.g. “Every morning, tell me what's on my calendar and which emails need a reply.”", text: drafts.binding(.agent, \.text), focused: $focus, minHeight: 84, submit: create))
            } extra: {
                EmptyView()
            } leading: {
                ScheduleMenu(cron: drafts.binding(.agent, \.schedule))
                HStack(spacing: 5) {
                    Image(systemName: "bell").font(.system(size: 12))
                    Text("Notifies you in Piopio")
                }
                .font(.system(size: 13)).foregroundStyle(Color.dsFg2).padding(.horizontal, 6)
                .help("It writes to you here, with a Mac notification. Other channels come later.")
                Text("Runs on this Mac").font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(.leading, 4)
            } action: {
                MainAction(title: "Create ⌘↩", busy: creating, enabled: canCreate, action: create)
                    .help(name.isEmpty ? "Name the agent first" : instructions.isEmpty ? "Say what it should do first" : "Create the agent")
            }
            StartError(text: error)
        }
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Start from a template")
            TemplateGrid(templates: ordered, selected: draft.template, owner: HomeView.firstName) { pick($0) }
        }
        Color.clear.frame(height: 0)
            .task {
                templates = await engine.agentTemplates()
                focus = name.isEmpty ? .name : .text
            }
    }

    /// From scratch first, then a briefing, a watcher, an assistant, a coach and a helper.
    private var ordered: [AgentTemplate] {
        let order = ["daily-briefing", "research-watcher", "personal-assistant", "habit-coach", "family-helper"]
        return templates.sorted { (order.firstIndex(of: $0.id) ?? 9) < (order.firstIndex(of: $1.id) ?? 9) }
    }

    /// A template sets the schedule, and drafts the name, icon and instructions unless you wrote your own.
    private func pick(_ t: AgentTemplate?) {
        let previous = templates.first { $0.id == draft.template }
        drafts.update(.agent) { d in
            d.template = t?.id
            d.schedule = t?.schedule ?? ""
            if d.name.isEmpty || templates.contains(where: { $0.name == d.name }) { d.name = t?.name ?? "" }
            if d.avatar.isEmpty || templates.contains(where: { $0.avatar == d.avatar }) { d.avatar = t?.avatar ?? "" }
            let untouched = d.text.isEmpty || d.text == previous.map { Self.draft($0) }
            if untouched { d.text = t.map { Self.draft($0) } ?? "" }
        }
    }

    /// A template's instructions with your first name in place of {owner}.
    private static func draft(_ t: AgentTemplate) -> String {
        (t.instructions ?? t.description).replacingOccurrences(of: "{owner}", with: HomeView.firstName)
    }

    private func create() {
        guard canCreate, !creating else { return }
        creating = true
        error = nil
        let schedule: CreateAgentParams.Schedule = draft.schedule.isEmpty ? .none : .cron(draft.schedule)
        Task {
            defer { creating = false }
            do {
                let ref = try await engine.createAgent(name: name, template: draft.template, avatar: draft.avatar.trimmingCharacters(in: .whitespaces), instructions: instructions, schedule: schedule)
                UserDefaults.standard.set("Chat", forKey: "agentTab")
                drafts.clear(.agent)
                morph(to: .agent(ref.id), $item)
            } catch {
                self.error = ((error as? EngineError)?.message ?? String(describing: error)) + " Nothing was created, and what you typed is kept."
            }
        }
    }
}

/// When it runs: days and a time, or only when you message it. Built from and into a cron ("0 8 * * 1-5").
private struct ScheduleMenu: View {
    @Binding var cron: String

    private static let days: [(String, String)] = [("*", "Every day"), ("1-5", "Weekdays"), ("0,6", "Weekends"), ("1", "Mondays")]
    private static let hours = [7, 8, 9, 12, 18, 21]

    var body: some View {
        Menu {
            Section("Days") {
                ForEach(Self.days, id: \.0) { value, title in
                    Button { set(days: value) } label: { if parts?.days == value { Label(title, systemImage: "checkmark") } else { Text(title) } }
                }
                Button { cron = "" } label: { if cron.isEmpty { Label("Only when you message it", systemImage: "checkmark") } else { Text("Only when you message it") } }
            }
            Section("Time") {
                ForEach(Self.hours, id: \.self) { h in
                    Button { set(hour: h) } label: { if parts?.hour == h && parts?.minute == 0 { Label(String(format: "%02d:00", h), systemImage: "checkmark") } else { Text(String(format: "%02d:00", h)) } }
                }
            }
        } label: {
            FooterSelector(symbol: "clock", title: label)
        }
        .menuStyle(.button).buttonStyle(SelectorStyle()).menuIndicator(.hidden).fixedSize()
        .help("When it runs on its own")
        .accessibilityLabel("Schedule: \(label)")
    }

    private var parts: (minute: Int, hour: Int, days: String)? {
        let f = cron.split(separator: " ").map(String.init)
        guard f.count == 5, let m = Int(f[0]), let h = Int(f[1]), f[2] == "*", f[3] == "*" else { return nil }
        return (m, h, f[4])
    }

    /// "Weekdays · 08:00", "When you message it".
    private var label: String {
        if cron.isEmpty { return "When you message it" }
        guard let p = parts else { return cron }
        let days = Self.days.first { $0.0 == p.days }?.1 ?? CronText.describe(cron)
        return "\(days) · \(String(format: "%02d:%02d", p.hour, p.minute))"
    }

    private func set(days: String) {
        let p = parts ?? (0, 8, days)
        cron = "\(p.minute) \(p.hour) * * \(days)"
    }

    private func set(hour: Int) {
        let p = parts ?? (0, hour, "*")
        cron = "0 \(hour) * * \(p.days)"
    }
}

/// Templates as a 3-column radio group of tiles: icon, name, what it does, when it runs.
private struct TemplateGrid: View {
    let templates: [AgentTemplate]
    let selected: String?
    let owner: String
    let pick: (AgentTemplate?) -> Void

    private var all: [AgentTemplate?] { [nil] + templates.map { Optional($0) } }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(all, id: \.?.id) { t in tile(t) }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.downArrow) { move(3) }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.upArrow) { move(-3) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Templates")
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let i = all.firstIndex { $0?.id == selected } ?? 0
        let next = min(max(i + step, 0), all.count - 1)
        pick(all[next])
        return .handled
    }

    private func tile(_ t: AgentTemplate?) -> some View {
        let on = t?.id == selected
        return Button { pick(t) } label: {
            HStack(alignment: .top, spacing: 10) {
                AvatarGlyph(avatar: t?.avatar ?? "symbol:square.and.pencil", size: 15, color: on ? .accentColor : .dsFg2)
                    .frame(width: 28, height: 28)
                    .background(on ? StartStyle.accentWash : Color.dsTrack, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(t?.name ?? "From scratch").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                    Text(t?.description ?? "Instructions you write").font(.system(size: 13)).foregroundStyle(Color.dsFg2).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(t?.schedule.map(CronText.describe) ?? "When you message it").font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(on ? StartStyle.accentFaint : Color.dsCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Color.accentColor : Color.dsLine, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityLabel(t?.name ?? "From scratch")
        .accessibilityHint(t?.description ?? "Instructions you write")
    }
}

