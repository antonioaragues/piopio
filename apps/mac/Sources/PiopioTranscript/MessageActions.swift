import AppKit
import Observation
import PiopioKit
import SwiftUI

// Under each message (docs/design chat v3, 14a–14b): small icon buttons for answers (Copy, Retry, Fork from here) with
// the model's name and when it answered ("3 min ago", the exact time on hover), and, under your own messages, when you
// sent it with a sent/read mark (✓, then ✓✓ once the model takes it up), Copy, Edit and Rewind to here. Only the
// turn's last answer has a row; the texts before it in the same turn don't. They're a SwiftUI row in
// the text (an attachment), shown on hover only. Rewind opens a popover that says what
// goes back before doing it. "Ask next" suggestions sit at the end of the thread, after the last answer.

/// The row under one message. Built with the item; the document shows or hides it and gives it somewhere to act.
@Observable
public final class MessageActions: @unchecked Sendable {
    public enum Role: Sendable { case user, answer }
    let itemId: String
    let role: Role
    /// Answers: what was copied. Users: the text.
    let text: String
    var canEdit = false
    var canRetry = false
    var canFork = false
    var canRewind = false
    /// A thread's message versions: "‹ 2 / 3 ›".
    var branch: BranchInfo?
    /// "direct" (a notebook topic message typed there).
    var note: String?
    /// "Haiku 5.5", with the full model, cost and tokens in its tooltip.
    var meta = ""
    var metaHelp: String?
    /// When the message was sent or the answer written.
    var at: Date?
    /// Your messages: the model that took it up ("Haiku 5.5"); nil while it waits (sent, not read yet).
    var readBy: String?
    var visible = false
    var copied = false
    @ObservationIgnored weak var document: TranscriptDocument?

    init(itemId: String, role: Role, text: String) {
        self.itemId = itemId
        self.role = role
        self.text = text
    }

    static let height: CGFloat = 26
}

final class ActionsAttachment: NSTextAttachment, @unchecked Sendable {
    let actions: MessageActions

    init(actions: MessageActions) {
        self.actions = actions
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = ActionsViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class ActionsViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let actions = (textAttachment as! ActionsAttachment).actions
        view = MainActor.assumeIsolated { NSHostingView(rootView: ActionsRow(actions: actions)) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        CGRect(x: 0, y: -8, width: textContainer?.size.width ?? proposedLineFragment.width, height: MessageActions.height)
    }
}

struct ActionsRow: View {
    let actions: MessageActions
    @State private var rewinding = false

    var body: some View {
        HStack(spacing: 0) {
            if actions.role == .user {
                Spacer(minLength: 0)
                if actions.visible {
                    HStack(spacing: 5) {
                        ReadMark(read: actions.readBy != nil).help(actions.readBy.map { "Read by \($0)" } ?? "Sent")
                        if let at = actions.at { MessageTime(date: at) }
                        Text("·").foregroundStyle(Color(nsColor: DS.fg3))
                    }
                    .font(.system(size: 11.5))
                    .padding(.trailing, 4)
                    .transition(.opacity)
                }
            }
            if actions.visible || actions.copied { buttons.transition(.opacity) }
            if actions.role == .answer {
                if actions.visible {
                    HStack(spacing: 5) {
                        if !actions.meta.isEmpty { Text(actions.meta).foregroundStyle(Color(nsColor: DS.fg3)).help(actions.metaHelp ?? "") }
                        if !actions.meta.isEmpty, actions.at != nil { Text("·").foregroundStyle(Color(nsColor: DS.fg3)) }
                        if let at = actions.at { MessageTime(date: at) }
                    }
                    .font(.system(size: 11.5))
                    .padding(.leading, 6)
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: MessageActions.height)
        .animation(.easeOut(duration: 0.12), value: actions.visible)
    }

    @ViewBuilder private var buttons: some View {
        if let note = actions.note { Text(note).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: DS.fg3)).padding(.trailing, 6) }
        if let b = actions.branch, actions.role == .user { branchSwitcher(b) }
        IconButton(symbol: actions.copied ? "checkmark" : "doc.on.doc", help: "Copy") { copy() }
        if actions.role == .user {
            if actions.canEdit { IconButton(symbol: "pencil", help: actions.canRewind ? "Edit: rewinds the chat to here and puts your message in the composer" : "Edit and resend (keeps this version)") { act(.edit(itemId: actions.itemId)) } }
            if actions.canRewind {
                Button { rewinding = true } label: {
                    Label("Rewind to here", systemImage: "arrow.uturn.backward").font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg2))
                        .padding(.horizontal, 9).frame(height: 24).background(Color(nsColor: DS.chip), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .help("Go back to before this message")
                .popover(isPresented: $rewinding, arrowEdge: .bottom) {
                    RewindPopover(itemId: actions.itemId, document: actions.document) { rewinding = false }
                }
            }
        } else {
            if actions.canRetry { IconButton(symbol: "arrow.clockwise", help: "Retry") { act(.regenerate(itemId: actions.itemId)) } }
            if actions.canFork { IconButton(symbol: "arrow.triangle.branch", help: "Fork from here") { act(.fork(itemId: actions.itemId)) } }
        }
    }

    private func branchSwitcher(_ b: BranchInfo) -> some View {
        HStack(spacing: 4) {
            Button { if let p = b.previous { act(.switchBranch(p)) } } label: { Image(systemName: "chevron.left") }.disabled(b.previous == nil).help("Previous version")
            Text("\(b.index + 1) / \(b.count)").monospacedDigit()
            Button { if let n = b.next { act(.switchBranch(n)) } } label: { Image(systemName: "chevron.right") }.disabled(b.next == nil).help("Next version")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5))
        .foregroundStyle(Color(nsColor: DS.fg3))
        .padding(.trailing, 8)
    }

    private func act(_ action: TranscriptAction) {
        MainActor.assumeIsolated { actions.document?.handle(action) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(actions.text, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { actions.copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeInOut(duration: 0.15)) { actions.copied = false }
        }
    }
}

/// A 28×26 icon button that fills on hover (13 pt symbol, fg3).
/// "now", "3 min ago", "2 h ago", "Yesterday, 23:56", "26 Oct, 23:56"; the exact date and time on hover. Updates
/// itself every half minute.
struct MessageTime: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.relative(date, now: context.date)).foregroundStyle(Color(nsColor: DS.fg3)).monospacedDigit()
        }
        .help(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()))
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return seconds < 6 * 3600 ? "\(Int(seconds / 3600)) h ago" : time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday, \(time)" }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return "\(date.formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())), \(time)"
    }
}

/// ✓ sent, ✓✓ read (the model took it up), drawn from two checkmarks.
struct ReadMark: View {
    let read: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
            if read { Image(systemName: "checkmark").offset(x: 4.5) }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Color(nsColor: read ? DS.fg2 : DS.fg3))
        .frame(width: read ? 15 : 11, alignment: .leading)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .regular)).foregroundStyle(Color(nsColor: hovering ? DS.fg2 : DS.fg3))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 22)
                .background(hovering ? Color(nsColor: DS.chip) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: Rewind (14b)

/// What going back to before a message changes.
public struct RewindPreview: Sendable {
    /// "removes RESUMEN.md", "reverts parser.py".
    public var files: [String]
    public var turns: Int
    public init(files: [String], turns: Int) { self.files = files; self.turns = turns }
}

/// "Rewind to before this message?": chat and files (default) or chat only; the message goes back to the composer.
public struct RewindPopover: View {
    let itemId: String
    let preview: ((String) async -> RewindPreview?)?
    let perform: ((String, Bool) async -> Void)?
    let close: () -> Void
    @State private var files = true
    @State private var loaded: RewindPreview?
    @State private var working = false

    public init(itemId: String, preview: ((String) async -> RewindPreview?)?, perform: ((String, Bool) async -> Void)?, close: @escaping () -> Void) {
        self.itemId = itemId
        self.preview = preview
        self.perform = perform
        self.close = close
    }

    init(itemId: String, document: TranscriptDocument?, close: @escaping () -> Void) {
        self.init(itemId: itemId, preview: document?.rewindPreview, perform: document?.rewind, close: close)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rewind to before this message?").font(.system(size: 13.5, weight: .semibold))
            option(true, "Chat and files", filesDetail)
            option(false, "Chat only", "keep the files as they are")
            Text("Your message goes back into the composer so you can edit it.").font(.system(size: 11.5)).foregroundStyle(Color(nsColor: DS.fg3))
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(working ? "Rewinding…" : "Rewind") {
                    working = true
                    Task { @MainActor in
                        await perform?(itemId, files)
                        working = false
                        close()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(working)
            }
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 360)
        .task { loaded = await preview?(itemId) }
    }

    private var filesDetail: String {
        guard let loaded else { return "…" }
        let turns = loaded.turns == 1 ? "drops 1 turn" : "drops \(loaded.turns) turns"
        if loaded.files.isEmpty { return "no files changed since · \(turns)" }
        let shown = loaded.files.prefix(2).joined(separator: ", ")
        return "\(shown)\(loaded.files.count > 2 ? " +\(loaded.files.count - 2)" : ""), \(turns)"
    }

    private func option(_ value: Bool, _ title: String, _ detail: String) -> some View {
        Button { files = value } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: files == value ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13)).foregroundStyle(files == value ? Color.accentColor : Color(nsColor: DS.fg3))
                Text(title).font(.system(size: 13)).foregroundStyle(Color(nsColor: DS.fg))
                Text("· \(detail)").font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg3)).lineLimit(2)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Ask next (14e, option A)

/// Suggested next messages, in the thread after the last answer. Tab puts the highlighted one in the composer.
@Observable
public final class AskNextModel: @unchecked Sendable {
    public internal(set) var items: [String] = []
    public var highlighted = 0
    /// Sends a suggestion; hides the list for this chat.
    @ObservationIgnored public var onSend: (@MainActor (String) -> Void)?
    @ObservationIgnored public var onDismiss: (@MainActor () -> Void)?

    public var current: String? { items.indices.contains(highlighted) ? items[highlighted] : nil }

    public func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlighted = (highlighted + delta + items.count) % items.count
    }

    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 37
    var height: CGFloat { Self.headerHeight + CGFloat(items.count) * Self.rowHeight + 8 }
}

final class AskNextAttachment: NSTextAttachment, @unchecked Sendable {
    let model: AskNextModel

    init(model: AskNextModel) {
        self.model = model
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = AskNextViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class AskNextViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let model = (textAttachment as! AskNextAttachment).model
        view = MainActor.assumeIsolated { NSHostingView(rootView: AskNextView(model: model)) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let model = (textAttachment as! AskNextAttachment).model
        return CGRect(x: 0, y: -4, width: textContainer?.size.width ?? proposedLineFragment.width, height: model.height)
    }
}

struct AskNextView: View {
    let model: AskNextModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ask next").font(.system(size: 11.5)).foregroundStyle(Color(nsColor: DS.fg3))
                Spacer()
                Button { MainActor.assumeIsolated { model.onDismiss?() } } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(nsColor: DS.fg3)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide suggestions in this chat")
            }
            .frame(height: AskNextModel.headerHeight)
            ForEach(Array(model.items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(Color(nsColor: DS.line)).frame(height: 0.5).padding(.leading, 34) }
                Button { MainActor.assumeIsolated { model.onSend?(item) } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(Color(nsColor: DS.fg3)).frame(width: 14)
                        Text(item).font(.system(size: 14)).foregroundStyle(Color(nsColor: DS.fg)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        if model.highlighted == i { Text("Tab").font(.system(size: 11)).foregroundStyle(Color(nsColor: DS.fg3)) }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: AskNextModel.rowHeight - 0.5)
                    .background(model.highlighted == i ? Color(nsColor: DS.chip) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { model.highlighted = i } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
