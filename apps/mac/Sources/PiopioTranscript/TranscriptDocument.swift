import AppKit
import PiopioKit
import SwiftUI

/// A session's transcript as one windowed TextKit 2 document (docs/spikes/s2).
///
/// - Holds the newest `windowSize` items; older history is prepended in `pageSize` pages, built off the
///   main thread, when the viewport nears the top. The visible text stays anchored.
/// - Applies engine events as minimal edits. A streaming answer re-renders only its open markdown block;
///   everything else is appended at the end, which is cheap (inserting costs O(text after the insert)).
/// - Follows the bottom while the user is there ("following"); scrolling up stops following.
@MainActor
public final class TranscriptDocument {
    public let scrollView: NSScrollView
    let textView: NSTextView
    private let layoutDelegate = CardLayoutDelegate()
    private var renderer: ItemRenderer
    private let windowSize: Int
    private let pageSize: Int

    /// Every item of the session, oldest first; `items[windowStart...]` are in the document.
    public private(set) var items: [TimelineItem] = [] {
        didSet {
            // A subagent's transcript: its first message is Piopio's brief (docs/spec/37).
            if renderer.briefFrom != nil { renderer.briefId = items.first { if case .user = $0 { true } else { false } }?.id }
        }
    }
    /// Who wrote this conversation's first message, when it isn't you: a subagent's is Piopio's brief.
    public var briefFrom: String? {
        get { renderer.briefFrom }
        set { renderer.briefFrom = newValue }
    }
    private var windowStart = 0
    /// Document order and rendered length of each item in the window.
    private(set) var documentIDs: [String] = []
    private var lengths: [String: Int] = [:]
    private var streams: [String: StreamingItem] = [:]

    private var loading = false
    private var pendingEvents: [SessionEvent] = []
    private var prefetched: (text: SendableText, lengths: [Int], ids: [String])?
    private var prefetching = false
    /// The scroll view's notifications. A block observer stays in NotificationCenter until it's removed, so they go
    /// when the document does (as VisualCard's do): each closed conversation left three behind.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private let hover = HoverTracker()
    private var hoveredItem: String?
    /// The action row under each message, by item (shown on hover).
    private var actionRows: [String: MessageActions] = [:]
    private var columnWidth: CGFloat = 0
    private var laidOutWidth: CGFloat = 0
    /// Extra space at the bottom so the floating composer never covers the last line.
    /// It follows the composer's height as you type: only the scroll inset moves, the text is not laid out again.
    public var bottomInset: CGFloat = 24 {
        didSet {
            guard abs(bottomInset - oldValue) > 0.5 else { return }
            scrollView.contentInsets.bottom = bottomInset
        }
    }
    /// Widest the reading column gets (`DS.column`), with at least 32 on each side.
    public var maxColumnWidth: CGFloat = DS.column
    private let minimumInset: CGFloat = 32

    /// "Ask next" (chat v3, 14e): suggestions after the last answer, as the document's last segment.
    public let askNext = AskNextModel()
    private var tailLength = 0

    /// Build: what rewinding to before a message changes, and doing it (`files`: the files too).
    public var rewindPreview: ((String) async -> RewindPreview?)?
    public var rewind: ((String, Bool) async -> Void)?

    /// Clicks on action links (edit, regenerate, fork, branch switch, settings, error details).
    public var onAction: ((TranscriptAction) -> Void)?
    private let links = LinkHandler()

    public private(set) var isFollowing = true {
        didSet { if oldValue != isFollowing { onFollowingChange?(isFollowing) } }
    }
    public var onFollowingChange: ((Bool) -> Void)?
    /// The visible height last seen: a change is a resize (a panel opening above, the terminal drawer), not a scroll.
    private var followHeight: CGFloat = 0
    /// Set while the transcript scrolls itself to keep the end in view, so that scroll doesn't count as yours.
    private var keepingEnd = false
    /// Where Remember this saves ("About me", "Daily briefing's memory"); nil hides it (Quick Chat).
    public var rememberDestination: String?
    /// Select and ask: the bar over selected text (Ask about this, Remember, Copy).
    private var selectionBar: ArrowHostingView<SelectionBar>?
    /// Whether a selection is painted (see `paintSelection`).
    fileprivate var paintedSelection = false
    /// Tables the selection runs through, tinted as selected (they're attachments: the painted background misses them).
    private var selectedTables: [TableSelection] = []

    public init(windowSize: Int = 300, pageSize: Int = 10, compact: Bool = false, versions: Bool = true, build: Bool = false, root: String? = nil, attachments: URL? = nil) {
        renderer = ItemRenderer(compact: compact, versions: versions, build: build, root: root, attachments: attachments)
        self.windowSize = windowSize
        self.pageSize = pageSize
        // Like NSTextView.scrollableTextView(), with the transcript's own text view (its cursor over cards).
        let text = TranscriptTextView(usingTextLayoutManager: true)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = text
        textView = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: compact ? 18 : 40, height: compact ? 14 : 24)
        textView.textContainer?.lineFragmentPadding = 0
        precondition(textView.textLayoutManager != nil, "TranscriptDocument needs TextKit 2")
        textView.textLayoutManager!.delegate = layoutDelegate
        // Links style themselves (markdown links blue, actions secondary); the view only adds the hand cursor.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = links
        links.document = self
        // ⌘C over a selection that runs through a table: the table's cells, not the attachment's placeholder.
        text.copyOverride = { [weak self] in self?.copySelection() ?? false }
        // On the next turn: the window sets its first responder once the text view has answered.
        text.onFocusChange = { [weak self] in
            Task { @MainActor in
                guard let self, self.paintedSelection else { return }
                self.paintSelection()
            }
        }
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutColumn(); self?.keepEndAfterResize() }
        })
        // The scroll view itself can be resized (an inspector opening) without its clip view posting first.
        scrollView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutColumn(); self?.keepEndAfterResize() }
        })
        textView.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: hover, userInfo: nil))
        hover.document = self
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.keepingEnd else { return }
                self.isFollowing = self.atBottom
                self.loadOlderIfNeeded()
            }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var storage: NSTextStorage { textView.textStorage! }
    private var layoutManager: NSTextLayoutManager { textView.textLayoutManager! }

    /// The document's plain text (tests, copy-all).
    public var text: String { storage.string }

    /// The latest version of an item (in or out of the window).
    public func item(_ id: String) -> TimelineItem? { items.last { $0.id == id } }
    public var lastItem: TimelineItem? { items.last }
    /// Files attached across the thread (header subtitle).
    public var attachmentCount: Int { items.reduce(0) { n, i in if case .user(let u) = i { n + (u.attachments?.count ?? 0) } else { n } } }
    public var lastUser: TimelineItem? { items.last { if case .user = $0 { true } else { false } } }

    func handle(_ action: TranscriptAction) {
        if case .copy(let id) = action {
            let text: String? = switch item(id) {
            case .user(let u): u.text
            case .assistant(let a): a.text
            default: nil
            }
            if let text {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
        if case .copyText(let text) = action {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
        // A folded /learn card opened again (docs/spec/14 M5): drawn whole, here only.
        if case .learn(let kind, let callId) = action, kind == "review" || kind == "none" {
            if kind == "review" { renderer.reviewing.insert(callId); redrawLearn(callId) }
            return
        }
        if case .undoAutomation(let id, let undoId) = action {
            // Its card then reads "Undone … Redo" (docs/spec/27 §4), not "Removed".
            renderer.undoneAutomations.insert(id)
            onAction?(undoId.map { .undoChange(undoId: $0) } ?? .removeAutomation(id: id))
            return
        }
        onAction?(action)
    }

    // MARK: Copy button

    /// A code card's Copy button, and what it reads for a moment after a click. Same length, so the swap leaves the
    /// segments' lengths alone.
    nonisolated static let copyLabel = "\u{2009}Copy\u{2009}"
    nonisolated static let copiedLabel = "Copied"

    /// The Copy button under `index` reads "Copied" for a moment (a code card's header: the pill tagged `.button`).
    func flashCopied(at index: Int) {
        guard index < storage.length,
              storage.attribute(.piopioPill, at: index, effectiveRange: nil) as? String == PillStyle.button.rawValue else { return }
        var range = NSRange()
        _ = storage.attribute(.piopioPill, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
        guard (storage.string as NSString).substring(with: range) == Self.copyLabel else { return }
        // Found again by its token: older messages may load above it while it shows.
        let token = UUID().uuidString
        swapLabel(range, to: Self.copiedLabel, color: DS.fg, token: token)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            var found: NSRange?
            self.storage.enumerateAttribute(.piopioCopyToken, in: NSRange(location: 0, length: self.storage.length)) { value, run, stop in
                if value as? String == token { found = run; stop.pointee = true }
            }
            if let found { self.swapLabel(found, to: Self.copyLabel, color: DS.fg2, token: nil) }
        }
    }

    private func swapLabel(_ range: NSRange, to label: String, color: NSColor, token: String?) {
        guard label.utf16.count == range.length else { return }
        var attrs = storage.attributes(at: range.location, effectiveRange: nil)
        attrs[.foregroundColor] = color
        attrs[.piopioCopyToken] = token
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: label, attributes: attrs))
        storage.endEditing()
    }

    // MARK: Loading

    /// Replaces the document with a snapshot: the newest window is built off the main thread.
    public func load(_ snapshot: Snapshot) async {
        loading = true
        streams = [:]
        prefetched = nil
        items = snapshot.items
        renderer.midTurn = Self.midTurn(items)
        let kept = Self.keptHerePairs(items)
        renderer.keptHere = Set(kept.map(\.offer))
        renderer.hereReplies = Set(kept.map(\.reply))
        windowStart = max(0, items.count - windowSize)
        let window = Array(items[windowStart...])
        let renderer = self.renderer
        let built = await Task.detached(priority: .userInitiated) { () -> (SendableText, [Int]) in
            var lengths: [Int] = []
            let out = NSMutableAttributedString()
            for item in window {
                let r = renderer.render(item)
                lengths.append(r.length)
                out.append(r)
            }
            return (SendableText(value: out), lengths)
        }.value
        storage.setAttributedString(built.0.value)
        tailLength = 0
        actionRows = [:]
        documentIDs = window.map(\.id)
        lengths = Dictionary(uniqueKeysWithValues: zip(documentIDs, built.1))
        for item in window { if case .assistant(let a) = item, a.status == .streaming { startStream(a) } }
        // Captures: PIOPIO_DEMO_SELECT=<text> selects that text once the transcript is in, showing Select and ask.
        if let wanted = ProcessInfo.processInfo.environment["PIOPIO_DEMO_SELECT"] {
            Task { @MainActor [weak self] in
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    let found = (self.storage.string as NSString).range(of: wanted, options: .backwards)
                    // The answer's copy (the last one), once it has finished streaming in.
                    if found.location != NSNotFound, found.location > self.storage.length / 2 {
                        self.textView.setSelectedRange(found)
                        self.selectionChanged()
                        return
                    }
                }
            }
        }
        wireCards(in: NSRange(location: 0, length: storage.length))
        layoutBubbles(in: NSRange(location: 0, length: storage.length))
        refreshFooters()
        if !askNext.items.isEmpty { insertTail() }
        scrollToLatest()
        loading = false
        let queued = pendingEvents
        pendingEvents = []
        apply(queued)
        prefetchOlder()
    }

    /// Scrolls to an item and flashes it (search results, links). Older items are paged in first.
    public func reveal(_ itemId: String) {
        guard !loading, let index = items.lastIndex(where: { $0.id == itemId }) else { return }
        if index < windowStart { extendWindow(from: index) }
        guard let d = documentIDs.firstIndex(of: itemId) else { return }
        let start = offset(ofIndex: d)
        let length = lengths[itemId] ?? 0
        if let content = layoutManager.textContentManager,
           let from = content.location(content.documentRange.location, offsetBy: start),
           let to = content.location(from, offsetBy: length),
           let range = NSTextRange(location: from, end: to) {
            layoutManager.ensureLayout(for: range)
        }
        textView.scrollRangeToVisible(NSRange(location: start, length: min(length, 1)))
        // Flash the first line of the item, skipping attachment characters.
        let ns = storage.string as NSString
        var first = start
        while first < start + length, ns.character(at: first) == 0xFFFC || ns.character(at: first) == 0x0A { first += 1 }
        let lineEnd = ns.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\u{2028}"), options: [], range: NSRange(location: first, length: max(0, start + length - first))).location
        let flashLength = min(120, (lineEnd == NSNotFound ? start + length : lineEnd) - first)
        if flashLength > 0 { textView.showFindIndicator(for: NSRange(location: first, length: flashLength)) }
        isFollowing = atBottom
    }

    /// Synchronously prepends everything from `index` up to the window (rare: jumping to old history).
    private func extendWindow(from index: Int) {
        prefetched = nil
        let page = Array(items[index..<windowStart])
        let rendered = page.map { renderer.render($0) }
        let text = NSMutableAttributedString()
        for r in rendered { text.append(r) }
        storage.insert(text, at: 0)
        wireCards(in: NSRange(location: 0, length: text.length))
        layoutBubbles(in: NSRange(location: 0, length: text.length))
        documentIDs.insert(contentsOf: page.map(\.id), at: 0)
        for (item, r) in zip(page, rendered) { lengths[item.id] = r.length }
        windowStart = index
        prefetchOlder()
    }

    /// A panel opening above the transcript shrinks it by its frame, and no bounds change follows: if the end was in
    /// view, it stays in view (above the composer) instead of sliding under it.
    private func keepEndAfterResize() {
        let height = scrollView.contentView.bounds.height
        guard abs(height - followHeight) > 0.5 else { return }
        followHeight = height
        guard isFollowing else { return }
        DispatchQueue.main.async { [weak self] in self?.showLastLine() }
    }

    /// The last line of text just above the composer. Not `scrollToEndOfDocument`: the text view keeps blank room
    /// below its text, and in a short view (the terminal drawer open, a panel above) the end of the document is that
    /// room alone, with the last line pushed out of sight.
    private func showLastLine() {
        var bottom: CGFloat?
        // An answer's action row (copy, retry) shows on hover only: blank room, not a line to keep in view.
        var looked = 0
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { fragment in
            looked += 1
            let text = (fragment.textElement as? NSTextParagraph)?.attributedString
            var actionsOnly = false
            if let text, text.length > 0 {
                actionsOnly = text.attribute(.attachment, at: 0, effectiveRange: nil) is ActionsAttachment
            }
            if actionsOnly, looked < 6 { return true }
            bottom = fragment.layoutFragmentFrame.maxY
            return false
        }
        guard let bottom else { return textView.scrollToEndOfDocument(nil) }
        let clip = scrollView.contentView
        keepingEnd = true
        defer { keepingEnd = false }
        let y = textView.textContainerOrigin.y + bottom + 16 + scrollView.contentInsets.bottom - clip.bounds.height
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(-scrollView.contentInsets.top, y), textView.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)))
        scrollView.reflectScrolledClipView(clip)
    }

    public func scrollToLatest() {
        textView.scrollToEndOfDocument(nil)
        isFollowing = true
    }

    // MARK: Events

    public func apply(_ events: [SessionEvent]) {
        guard !loading else {
            pendingEvents += events
            return
        }
        let follow = isFollowing
        for (i, event) in events.enumerated() {
            apply(event)
            if loading { // a resnapshot started reloading: the rest of the batch waits for it
                pendingEvents += events[(i + 1)...]
                return
            }
        }
        if !events.isEmpty {
            refreshMidTurn()
            refreshKeptHere()
            refreshFooters()
        }
        if follow, !events.isEmpty { textView.scrollToEndOfDocument(nil) }
    }

    /// The texts in the middle of a turn: more text follows before your next message (a step's "Let me check…").
    static func midTurn(_ items: [TimelineItem]) -> Set<String> {
        var out = Set<String>()
        var lastText: String?
        for item in items {
            switch item {
            case .user: lastText = nil
            case .assistant(let a) where !a.text.isEmpty:
                if let previous = lastText { out.insert(previous) }
                lastText = a.id
            default: break
            }
        }
        return out
    }

    /// Where this conversation's /learn cards stand (docs/spec/14 M5): a card is drawn again when its state changes.
    public func setLearned(_ learned: [String: LearnState]) {
        guard learned != renderer.learned else { return }
        let changed = Set(learned.keys).union(renderer.learned.keys).filter { learned[$0] != renderer.learned[$0] }
        renderer.learned = learned
        for id in changed { renderer.reviewing.remove(id) }
        guard !loading else { return }
        for id in changed { redrawLearn(id) }
    }

    private func redrawLearn(_ callId: String) {
        guard !loading, let item = items.last(where: { if case .tool(let t) = $0 { t.callId == callId && t.tool == "propose_learnings" } else { false } }) else { return }
        replace(item)
    }

    /// Where this conversation's side conversations stand, and its open proposals (docs/spec/24 §6): their lines in
    /// the transcript are drawn again when that changes.
    public func setSides(_ sides: [SideInfo], openProposals: [String: Date]) {
        guard sides != renderer.sides || openProposals != renderer.openProposals else { return }
        renderer.sides = sides
        renderer.openProposals = openProposals
        guard !loading else { return }
        for id in documentIDs {
            guard let item = items.last(where: { $0.id == id }) else { continue }
            switch item {
            case .tool(let t) where t.tool == "side_start" || t.tool == "side_offer" || t.tool == "side_propose": replace(item)
            case .user(let u) where u.text.hasPrefix("[Side] "): replace(item)
            default: break
            }
        }
    }

    /// Where this conversation's subagents stand, and which one is open beside (docs/spec/37): their rows are drawn
    /// again when that changes.
    public func setSubagents(_ subagents: [SubagentInfo], open: String?) {
        guard subagents != renderer.subagents || open != renderer.openSubagent else { return }
        renderer.subagents = subagents
        renderer.openSubagent = open
        guard !loading else { return }
        for id in documentIDs {
            guard let item = items.last(where: { $0.id == id }) else { continue }
            if case .tool(let t) = item, t.tool == "task" { replace(item) }
        }
    }

    /// The automations that exist now (docs/spec/27): a card for one that's gone is drawn again as "Removed".
    public func setAutomations(_ ids: Set<String>) {
        guard ids != renderer.automations else { return }
        renderer.automations = ids
        guard !loading else { return }
        for id in documentIDs {
            guard let item = items.last(where: { $0.id == id }) else { continue }
            switch item {
            case .tool(let t) where t.tool == "automate" || t.tool == "change_automation": replace(item)
            case .result(let r) where r.card.kind == .automation: replace(item)
            default: break
            }
        }
    }

    /// When a turn goes on, its earlier text loses its action row (and the space it took).
    private func refreshMidTurn() {
        let next = Self.midTurn(items)
        let changed = next.symmetricDifference(renderer.midTurn)
        renderer.midTurn = next
        for id in changed {
            if let item = items.last(where: { $0.id == id }) { replace(item) }
        }
    }

    /// The offers you answered with Do it here: the engine sends "Do it here." as your next message (docs/spec/24 §1).
    nonisolated static func keptHere(_ items: [TimelineItem]) -> Set<String> { Set(keptHerePairs(items).map(\.offer)) }

    /// Each offer answered with Do it here, and the message that answered it.
    nonisolated static func keptHerePairs(_ items: [TimelineItem]) -> [(offer: String, reply: String)] {
        var out: [(offer: String, reply: String)] = []
        var offer: String?
        for item in items {
            switch item {
            case .tool(let t) where t.tool == "side_offer": offer = t.callId
            case .user(let u):
                if let o = offer, u.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Do it here." { out.append((o, u.id)) }
                offer = nil
            default: break
            }
        }
        return out
    }

    /// Once you choose Do it here, its card becomes a grey line.
    private func refreshKeptHere() {
        let pairs = Self.keptHerePairs(items)
        let next = Set(pairs.map(\.offer)), replies = Set(pairs.map(\.reply))
        guard next != renderer.keptHere || replies != renderer.hereReplies else { return }
        let changed = next.symmetricDifference(renderer.keptHere)
        let changedReplies = replies.symmetricDifference(renderer.hereReplies)
        renderer.keptHere = next
        renderer.hereReplies = replies
        for item in items {
            if case .tool(let t) = item, changed.contains(t.callId) { replace(item) }
            if case .user(let u) = item, changedReplies.contains(u.id) { replace(item) }
        }
    }

    private func apply(_ event: SessionEvent) {
        switch event {
        case .itemAdded(let item, let before):
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i] = item
                replace(item)
            } else if let before, let i = items.firstIndex(where: { $0.id == before }) {
                items.insert(item, at: i)
                if let d = documentIDs.firstIndex(of: before) { insert(item, at: d) }
            } else {
                items.append(item)
                append(item)
            }
        case .itemUpdated(let item):
            guard let i = items.lastIndex(where: { $0.id == item.id }) else { return }
            items[i] = item
            replace(item)
        case .itemReplaced(let oldId, let item):
            guard let i = items.lastIndex(where: { $0.id == oldId }) else {
                items.append(item)
                append(item)
                return
            }
            items[i] = item
            if let d = documentIDs.firstIndex(of: oldId) {
                documentIDs[d] = item.id
                lengths[item.id] = lengths.removeValue(forKey: oldId)
                streams[item.id] = streams.removeValue(forKey: oldId)
            }
            replace(item)
        case .itemRemoved(let id):
            items.removeAll { $0.id == id }
            if let d = documentIDs.firstIndex(of: id) {
                edit(NSRange(location: offset(ofIndex: d), length: lengths[id] ?? 0), with: NSAttributedString())
                documentIDs.remove(at: d)
                lengths[id] = nil
                streams[id] = nil
            }
        case .itemDelta(let id, _, let partType, let delta):
            guard let i = items.lastIndex(where: { $0.id == id }), case .assistant(var a) = items[i] else { return }
            if let p = a.parts.lastIndex(where: { $0.isThinking == (partType == .thinking) }) { a.parts[p] = a.parts[p].appending(delta) } else { a.parts.append(partType == .thinking ? .thinking(text: delta) : .text(delta)) }
            items[i] = .assistant(a)
            streamDelta(id: id, partType: partType, delta: delta)
        case .resnapshot(let snapshot):
            // Queue what follows until the new snapshot is in place (it would be lost otherwise).
            loading = true
            Task { await load(snapshot) }
        case .state, .unknown:
            break
        }
    }

    // MARK: Segments

    private func offset(ofIndex index: Int) -> Int {
        documentIDs[..<index].reduce(0) { $0 + (lengths[$1] ?? 0) }
    }

    private func append(_ item: TimelineItem) {
        let text = renderer.render(item)
        documentIDs.append(item.id)
        lengths[item.id] = text.length
        edit(NSRange(location: storage.length - tailLength, length: 0), with: text)
        if case .assistant(let a) = item, a.status == .streaming { startStream(a) }
    }

    /// Renders an item before the document's `index`-th item.
    private func insert(_ item: TimelineItem, at index: Int) {
        let text = renderer.render(item)
        let location = offset(ofIndex: index)
        documentIDs.insert(item.id, at: index)
        lengths[item.id] = text.length
        edit(NSRange(location: location, length: 0), with: text)
    }

    /// Re-renders an item in place. A finished answer replaces its streamed rendering with the final one.
    private func replace(_ item: TimelineItem) {
        guard let d = documentIDs.firstIndex(of: item.id) else { return } // outside the window: data only
        if case .assistant(let a) = item, a.status == .streaming, streams[item.id] != nil { return } // deltas drive it
        streams[item.id] = nil
        let range = NSRange(location: offset(ofIndex: d), length: lengths[item.id] ?? 0)
        let text = renderer.render(item)
        // A running tool updates often: its cards keep whatever the reader opened or closed.
        let before = cards(in: range)
        for (old, new) in zip(before, cards(in: text)) where old.toggledByReader || old.showAll {
            new.expanded = old.expanded
            new.toggledByReader = old.toggledByReader
            new.showAll = old.showAll
        }
        actionRows[item.id] = nil // the new rendering brings its own row, or none (mid-turn)
        edit(range, with: text)
        lengths[item.id] = text.length
        if case .assistant(let a) = item, a.status == .streaming { startStream(a) }
    }

    private func edit(_ range: NSRange, with text: NSAttributedString) {
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        storage.endEditing()
        wireCards(in: NSRange(location: range.location, length: text.length))
        layoutBubbles(in: NSRange(location: range.location, length: text.length))
    }

    // MARK: Column, bubbles, footers

    /// Centers the reading column and re-fits user bubbles when the width changes.
    func layoutColumn(force: Bool = false) {
        let width = scrollView.contentView.bounds.width
        guard width > 0 else { return }
        let inset = max(minimumInset, (width - maxColumnWidth) / 2)
        let column = width - 2 * inset
        // The width, not the column: past the widest column it stays the same while its insets change.
        guard force || abs(width - laidOutWidth) > 0.5 else { return }
        laidOutWidth = width
        columnWidth = column
        textView.textContainerInset = NSSize(width: inset, height: 24)
        if let tv = textView.enclosingScrollView { tv.contentInsets.bottom = bottomInset }
        layoutBubbles(in: NSRange(location: 0, length: storage.length))
    }

    /// User bubbles hug their text on the right: indent = column − text width (at most 480 wide, chat v3).
    private func layoutBubbles(in range: NSRange) {
        let column = columnWidth > 0 ? columnWidth : (textView.textContainer?.size.width ?? 600)
        guard range.length > 0, column > 100 else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.piopioBubbleWidth, in: range) { value, run, _ in
            guard let natural = (value as? NSNumber).map({ CGFloat($0.doubleValue) }),
                  let style = (storage.attribute(.paragraphStyle, at: run.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            let pad = CardLayoutFragment.bubblePadH
            let indent = max(56, column - pad - min(natural, min(480 - 2 * pad, column * 0.78)))
            guard abs(style.headIndent - indent) > 0.5 else { return }
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            storage.addAttribute(.paragraphStyle, value: style, range: run)
        }
        // Code cards: the Copy button sits at the right edge, on a right tab stop fitted to the column.
        storage.enumerateAttribute(.piopioRightTab, in: range) { value, run, _ in
            guard let inset = (value as? NSNumber).map({ CGFloat($0.doubleValue) }),
                  let style = (storage.attribute(.paragraphStyle, at: run.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            let location = column - inset
            guard style.tabStops.count != 1 || abs(style.tabStops[0].location - location) > 0.5 else { return }
            style.tabStops = [NSTextTab(textAlignment: .right, location: location)]
            storage.addAttribute(.paragraphStyle, value: style, range: run)
        }
        storage.endEditing()
    }

    /// Action rows show only for the hovered message (the latest answer too).
    private func refreshFooters() {
        var wanted = Set<String>()
        if let hoveredItem { wanted.insert(hoveredItem) }
        // Captures: PIOPIO_DEMO_SHOW_ROWS=1 shows every row, as if hovered.
        if ProcessInfo.processInfo.environment["PIOPIO_DEMO_SHOW_ROWS"] == "1" { wanted = Set(actionRows.keys) }
        for (id, row) in actionRows where row.visible != wanted.contains(id) { row.visible = wanted.contains(id) }
        // Your messages are read once an answer to them starts (the model that took them up, for the tooltip).
        var readBy: String?
        for item in items.reversed() {
            switch item {
            case .assistant(let a): readBy = a.model.map(ItemRenderer.modelName) ?? "the model"
            case .user(let u):
                if let row = actionRows[u.id], row.readBy != readBy { row.readBy = readBy }
                readBy = nil
            default: break
            }
        }
    }

    // MARK: Ask next

    /// Shows suggestions after the last answer (nil or empty hides them).
    public func showAskNext(_ suggestions: [String]?) {
        let next = suggestions ?? []
        guard next != askNext.items else { return }
        removeTail()
        askNext.items = next
        askNext.highlighted = 0
        if !loading { insertTail() }
    }

    /// The /learn offer after you corrected the agent (docs/spec/14 M5), at the top of the same tail (nil hides it).
    public func showLearnOffer(_ text: String?) {
        guard text != askNext.learnOffer else { return }
        removeTail()
        askNext.learnOffer = text
        if !loading { insertTail() }
    }

    private func insertTail() {
        guard tailLength == 0, !askNext.items.isEmpty || askNext.learnOffer != nil else { return }
        let s = NSMutableAttributedString(attachment: AskNextAttachment(model: askNext))
        s.append(NSAttributedString(string: "\n"))
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 4
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        storage.beginEditing()
        storage.insert(s, at: storage.length)
        storage.endEditing()
        tailLength = s.length
        if isFollowing { textView.scrollToEndOfDocument(nil) }
    }

    private func removeTail() {
        guard tailLength > 0, storage.length >= tailLength else { tailLength = 0; return }
        storage.beginEditing()
        storage.deleteCharacters(in: NSRange(location: storage.length - tailLength, length: tailLength))
        storage.endEditing()
        tailLength = 0
    }

    func hover(at point: NSPoint?) {
        var id: String?
        if let point, let fragment = layoutManager.textLayoutFragment(for: point), let content = layoutManager.textContentManager {
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            var start = 0
            for docId in documentIDs {
                let end = start + (lengths[docId] ?? 0)
                if offset >= start, offset < end { id = docId; break }
                start = end
            }
        }
        guard id != hoveredItem else { return }
        hoveredItem = id
        refreshFooters()
    }

    // MARK: Streaming

    /// Rendering state of an answer that is still streaming. Its segment is `[thinking card][closed blocks][open block]`.
    private final class StreamingItem {
        var markdown = MarkdownStream()
        var renderedClosed = 0
        var thinking: DisclosureCard?
        var thinkingLength = 0
        var closedLength = 0
    }

    private func startStream(_ a: AssistantItem) {
        let s = StreamingItem()
        // An item that already has content (snapshot mid-answer) was rendered whole; restart its segment.
        streams[a.id] = s
        guard let d = documentIDs.firstIndex(of: a.id) else { return }
        let range = NSRange(location: offset(ofIndex: d), length: lengths[a.id] ?? 0)
        let thinkingText = a.parts.filter { $0.isThinking }.map(\.text).joined()
        let out = NSMutableAttributedString()
        if !thinkingText.isEmpty {
            let card = DisclosureCard(kind: .thinking, title: "Thinking…", body: thinkingText)
            card.working = a.text.isEmpty
            s.thinking = card
            let t = renderer.thinkingCard(card)
            s.thinkingLength = t.length
            out.append(t)
        }
        s.markdown.append(a.text)
        let closed = renderer.render(s.markdown.closed)
        s.renderedClosed = s.markdown.closed.count
        s.closedLength = closed.length
        out.append(closed)
        if let open = s.markdown.open { out.append(renderer.render(open)) }
        edit(range, with: out)
        lengths[a.id] = out.length
    }

    private func streamDelta(id: String, partType: SessionEvent.PartType, delta: String) {
        guard let s = streams[id], let d = documentIDs.firstIndex(of: id) else { return }
        let start = offset(ofIndex: d)
        let length = lengths[id] ?? 0
        if partType == .thinking {
            if let card = s.thinking {
                card.body += delta
                if card.expanded { relayout(card) }
            } else {
                let card = DisclosureCard(kind: .thinking, title: "Thinking…", body: delta)
                card.working = true
                s.thinking = card
                let t = renderer.thinkingCard(card)
                edit(NSRange(location: start, length: 0), with: t)
                s.thinkingLength = t.length
                lengths[id] = length + t.length
            }
            return
        }
        if let card = s.thinking, card.working {
            // The answer started: the thought stops spinning.
            card.working = false
            card.title = "Thought"
        }
        s.markdown.append(delta)
        let tailStart = start + s.thinkingLength + s.closedLength
        let tail = NSMutableAttributedString()
        tail.append(renderer.render(s.markdown.closed[s.renderedClosed...]))
        let newlyClosed = tail.length
        if let open = s.markdown.open { tail.append(renderer.render(open)) }
        edit(NSRange(location: tailStart, length: start + length - tailStart), with: tail)
        s.closedLength += newlyClosed
        s.renderedClosed = s.markdown.closed.count
        lengths[id] = s.thinkingLength + s.closedLength + (tail.length - newlyClosed)
    }

    // MARK: Paging older history

    private var atBottom: Bool {
        scrollView.contentView.bounds.maxY >= textView.frame.height - 30
    }

    private func prefetchOlder() {
        guard !prefetching, prefetched == nil, windowStart > 0 else { return }
        prefetching = true
        let slice = Array(items[max(0, windowStart - pageSize)..<windowStart])
        let renderer = self.renderer
        Task {
            let (text, lengths) = await Task.detached(priority: .userInitiated) { () -> (SendableText, [Int]) in
                let out = NSMutableAttributedString()
                var lengths: [Int] = []
                for item in slice {
                    let r = renderer.render(item)
                    lengths.append(r.length)
                    out.append(r)
                }
                return (SendableText(value: out), lengths)
            }.value
            prefetched = (text, lengths, slice.map(\.id))
            prefetching = false
            loadOlderIfNeeded()
        }
    }

    func loadOlderIfNeeded(force: Bool = false) {
        let clip = scrollView.contentView
        guard !loading, force || clip.bounds.minY < 4000, let next = prefetched else { return }
        prefetched = nil
        let page = Array(items[(windowStart - next.ids.count)..<windowStart])
        guard page.map(\.id) == next.ids else {
            prefetchOlder() // history changed while prefetching
            return
        }
        let heightBefore = textView.frame.height
        let y0 = clip.bounds.minY
        storage.insert(next.text.value, at: 0)
        wireCards(in: NSRange(location: 0, length: next.text.value.length))
        layoutBubbles(in: NSRange(location: 0, length: next.text.value.length))
        documentIDs.insert(contentsOf: next.ids, at: 0)
        for (id, length) in zip(next.ids, next.lengths) { lengths[id] = length }
        windowStart -= next.ids.count
        if let content = layoutManager.textContentManager,
           let end = content.location(content.documentRange.location, offsetBy: next.text.value.length),
           let inserted = NSTextRange(location: content.documentRange.location, end: end) {
            layoutManager.ensureLayout(for: inserted)
        }
        layoutManager.textViewportLayoutController.layoutViewport()
        clip.scroll(to: NSPoint(x: 0, y: y0 + textView.frame.height - heightBefore))
        scrollView.reflectScrolledClipView(clip)
        prefetchOlder()
    }

    /// Test hooks.
    var renderedLength: Int { documentIDs.reduce(0) { $0 + (lengths[$1] ?? 0) } }
    func actionRow(_ itemId: String) -> MessageActions? { actionRows[itemId] }
    var hasPrefetchedPage: Bool { prefetched != nil }

    // MARK: Cards

    private func wireCards(in range: NSRange) {
        guard range.length > 0 else { return }
        storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
            (value as? DisclosureAttachment)?.card.onToggle = { [weak self] card in self?.relayout(card) }
            (value as? DisclosureAttachment)?.card.onAction = { [weak self] action in self?.handle(action) }
            (value as? FileCardAttachment)?.model.onAction = { [weak self] action in self?.handle(action) }
            (value as? UserImagesAttachment)?.model.onAction = { [weak self] action in self?.handle(action) }
            (value as? AutomationCardAttachment)?.model.onAction = { [weak self] action in self?.handle(action) }
            (value as? SideOfferAttachment)?.model.onAction = { [weak self] action in self?.handle(action) }
            (value as? LearnCardAttachment)?.model.onAction = { [weak self] action in self?.handle(action) }
            (value as? SubagentRowAttachment)?.model.onAction = { [weak self] action in self?.handle(action) }
            if let visual = (value as? VisualAttachment)?.model {
                visual.onAction = { [weak self] action in self?.handle(action) }
                visual.onResize = { [weak self] model in self?.relayout { ($0 as? VisualAttachment)?.model === model } }
            }
            if let row = (value as? ActionsAttachment)?.actions {
                row.document = self
                actionRows[row.itemId] = row
            }
        }
    }

    private func cards(in range: NSRange) -> [DisclosureCard] {
        cards(in: storage, range: range)
    }

    private func cards(in text: NSAttributedString) -> [DisclosureCard] {
        cards(in: text, range: NSRange(location: 0, length: text.length))
    }

    private func cards(in text: NSAttributedString, range: NSRange) -> [DisclosureCard] {
        var found: [DisclosureCard] = []
        guard range.length > 0, NSMaxRange(range) <= text.length else { return found }
        text.enumerateAttribute(.attachment, in: range) { value, _, _ in
            if let card = (value as? DisclosureAttachment)?.card { found.append(card) }
        }
        return found
    }

    private func relayout(_ card: DisclosureCard) {
        relayout { ($0 as? DisclosureAttachment)?.card === card }
    }

    /// Lays out again the line of the attachment that matches (a card that changed height).
    private func relayout(_ matches: (NSTextAttachment) -> Bool) {
        var location: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: .reverse) { value, range, stop in
            if let a = value as? NSTextAttachment, matches(a) { location = range.location; stop.pointee = true }
        }
        guard let location, let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: location),
              let end = content.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return }
        layoutManager.invalidateLayout(for: range)
        layoutManager.textViewportLayoutController.layoutViewport()
    }
}

// MARK: Select and ask

extension TranscriptDocument {
    /// Shows the bar above a selection of text (in answers or your messages), hides it when the selection goes.
    func selectionChanged() {
        paintSelection()
        let range = textView.selectedRange()
        guard range.length > 1, NSMaxRange(range) <= storage.length, let window = textView.window else { return hideSelectionBar() }
        let selected = selectionText(range)
        guard selected.ask.contains(where: \.isLetter) else { return hideSelectionBar() }
        let onScreen = textView.firstRect(forCharacterRange: range, actualRange: nil)
        let rect = textView.convert(window.convertFromScreen(onScreen), from: nil)
        let bar = SelectionBar(remember: rememberDestination, act: { [weak self] choice in self?.selectionAction(choice, text: selected) })
        let host = selectionBar ?? ArrowHostingView(rootView: bar)
        host.rootView = bar
        let size = host.fittingSize
        // Above the selection's first line; below it when there's no room above.
        let y = rect.minY - size.height - 6 >= textView.visibleRect.minY ? rect.minY - size.height - 6 : rect.maxY + 6
        // Inside the reading column: from its left edge to its right edge.
        let left = textView.textContainerInset.width
        let right = left + (textView.textContainer?.size.width ?? textView.bounds.width - 2 * left)
        let x = min(max(rect.minX, left), max(left, right - size.width))
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if host.superview == nil { textView.addSubview(host) }
        selectionBar = host
    }

    /// The transcript's fragments draw its selection (`NSTextLayoutFragment.drawSelection`), so it shows over card fills
    /// and stays inside your bubbles: the selected text gets the selection colour as a background rendering attribute.
    func paintSelection() {
        (textView as? TranscriptTextView)?.hideSystemSelection()
        guard let content = layoutManager.textContentManager else { return }
        if paintedSelection {
            layoutManager.removeRenderingAttribute(.backgroundColor, for: layoutManager.documentRange)
            paintedSelection = false
        }
        let active = textView.window?.isKeyWindow == true && textView.window?.firstResponder === textView
        let color = active ? (textView.selectedTextAttributes[.backgroundColor] as? NSColor ?? .selectedTextBackgroundColor) : .unemphasizedSelectedTextBackgroundColor
        for value in textView.selectedRanges {
            let selection = value.rangeValue
            guard selection.length > 0, NSMaxRange(selection) <= storage.length,
                  let start = content.location(content.documentRange.location, offsetBy: selection.location),
                  let end = content.location(start, offsetBy: selection.length),
                  let range = NSTextRange(location: start, end: end) else { continue }
            layoutManager.addRenderingAttribute(.backgroundColor, value: color, for: range)
            paintedSelection = true
        }
        var tables: [TableSelection] = []
        for value in textView.selectedRanges where value.rangeValue.length > 0 && NSMaxRange(value.rangeValue) <= storage.length {
            storage.enumerateAttribute(.attachment, in: value.rangeValue) { a, _, _ in
                if let a = a as? TableAttachment { tables.append(a.selection) }
            }
        }
        for t in selectedTables where !tables.contains(where: { $0 === t }) { t.color = nil }
        for t in tables { t.color = color }
        selectedTables = tables
    }

    /// The selection as text, with each table it runs through as its cells: `ask` (tables as Markdown, for the model
    /// and Remember), `plain` (tables tab-separated, so a spreadsheet splits them into cells) and `html` (real tables
    /// for Numbers, Notes, Mail and Pages; only when there's a table).
    func selectionText(_ range: NSRange) -> (ask: String, plain: String, html: String?) {
        var ask = "", plain = "", html = "", tables = 0
        let clean = { (s: String) in s.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: lineSeparator, with: "\n") }
        storage.enumerateAttribute(.attachment, in: range) { value, r, _ in
            if let table = (value as? TableAttachment)?.table {
                tables += 1
                ask += "\n\n" + table.markdown + "\n\n"
                plain += "\n\n" + table.tsv + "\n\n"
                html += table.html
            } else {
                let text = clean((storage.string as NSString).substring(with: r))
                ask += text
                plain += text
                for p in text.components(separatedBy: "\n\n") where !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    html += "<p>" + TableContent.escape(p.trimmingCharacters(in: .whitespacesAndNewlines)).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
                }
            }
        }
        let trim = { (s: String) in s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (trim(ask), trim(plain), tables > 0 ? TableContent.htmlDocument(html) : nil)
    }

    /// ⌘C when the selection runs through a table; false leaves the copy to the text view.
    func copySelection() -> Bool {
        let range = textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        var hasTable = false
        storage.enumerateAttribute(.attachment, in: range) { a, _, stop in
            if a is TableAttachment { hasTable = true; stop.pointee = true }
        }
        guard hasTable else { return false }
        let text = selectionText(range)
        TableContent.write(plain: text.plain, html: text.html)
        return true
    }

    func hideSelectionBar() {
        selectionBar?.removeFromSuperview()
        selectionBar = nil
    }

    private func selectionAction(_ choice: SelectionBar.Choice, text: (ask: String, plain: String, html: String?)) {
        switch choice {
        case .ask: handle(.quote(text: text.ask))
        case .remember: handle(.remember(text: text.ask))
        case .copy: TableContent.write(plain: text.plain, html: text.html)
        }
        // A beat for the check mark, then the selection and the bar go.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(choice == .ask ? 0 : 700))
            guard let self else { return }
            self.textView.setSelectedRange(NSRange(location: self.textView.selectedRange().location, length: 0))
            self.hideSelectionBar()
        }
    }
}

/// The small floating bar over selected text.
struct SelectionBar: View {
    enum Choice { case ask, remember, copy }
    let remember: String?
    let act: (Choice) -> Void
    @State private var done: Choice?

    var body: some View {
        HStack(spacing: 2) {
            item(.ask, "Ask about this", "text.bubble")
            if let remember { item(.remember, done == .remember ? "Remembered" : "Remember", done == .remember ? "checkmark" : "brain", help: "Save it to \(remember)") }
            item(.copy, done == .copy ? "Copied" : "Copy", done == .copy ? "checkmark" : "doc.on.doc")
        }
        .padding(3)
        .background(Color(nsColor: DS.card), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: DS.line), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .fixedSize()
    }

    private func item(_ choice: Choice, _ title: String, _ symbol: String, help: String? = nil) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { done = choice }
            act(choice)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: DS.fg))
                .padding(.horizontal, 10).frame(height: 26)
                .contentShape(Capsule())
        }
        .buttonStyle(SelectionBarButtonStyle())
        .help(help ?? title)
    }
}

private struct SelectionBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(nsColor: DS.chip) : .clear, in: Capsule())
    }
}

extension ItemRenderer {
    func render(_ blocks: some Sequence<MarkdownBlock>) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for b in blocks { out.append(render(b)) }
        return out
    }
}

@MainActor
private final class LinkHandler: NSObject, NSTextViewDelegate {
    weak var document: TranscriptDocument?

    func textViewDidChangeSelection(_ notification: Notification) {
        document?.selectionChanged()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, let action = TranscriptAction(url: url) else { return false } // regular links open in the browser
        document?.handle(action)
        if case .copyText = action { document?.flashCopied(at: charIndex) }
        return true
    }
}

/// Receives mouse moves over the transcript to reveal message actions.
@MainActor
private final class HoverTracker: NSResponder {
    weak var document: TranscriptDocument?

    override func mouseMoved(with event: NSEvent) {
        guard let document else { return }
        let textView = document.textView
        (textView as? TranscriptTextView)?.arrowIfNeeded(event)
        let p = textView.convert(event.locationInWindow, from: nil)
        let inset = textView.textContainerInset
        document.hover(at: NSPoint(x: p.x - inset.width, y: p.y - inset.height))
    }

    override func mouseExited(with event: NSEvent) {
        document?.hover(at: nil)
        // Leaving for the sidebar or a panel: views there that set no cursor of their own would keep the I-beam.
        (document?.textView as? TranscriptTextView)?.arrowIfNeeded(event)
    }
}

extension TranscriptDocument {
    /// For DebugAutomation: opens every activity line, as a click would.
    public func debugOpenActivity() {
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let card = (value as? DisclosureAttachment)?.card, card.kind == .activity, !card.expanded else { return }
            card.expanded = true
            card.toggledByReader = true
            card.onToggle?(card)
        }
    }

    /// For DebugAutomation: the cursor after a mouse move to this window point ("arrow", "ibeam" or "other").
    public func debugCursor(at point: NSPoint) -> String {
        guard let window = textView.window,
              let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return "none" }
        // Hovering first reveals a message's buttons, as the real mouse would.
        let p = textView.convert(point, from: nil)
        hover(at: NSPoint(x: p.x - textView.textContainerInset.width, y: p.y - textView.textContainerInset.height))
        textView.layoutSubtreeIfNeeded()
        NSCursor.iBeam.set()
        textView.mouseMoved(with: event)
        let current = NSCursor.current
        return current == .arrow ? "arrow" : current == .iBeam ? "ibeam" : "other"
    }
}

/// Markdown rendered in the transcript's style, for other views (the file viewer).
public enum MarkdownRendering {
    /// Files are hard-wrapped: lines of one paragraph join with a space, as Markdown reads them.
    public static func attributed(_ markdown: String) -> NSAttributedString {
        let blocks = MarkdownStream(text: markdown).blocks.map { block -> MarkdownBlock in
            if case .paragraph(let text) = block { return .paragraph(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")) }
            return block
        }
        return ItemRenderer().render(blocks)
    }
}
