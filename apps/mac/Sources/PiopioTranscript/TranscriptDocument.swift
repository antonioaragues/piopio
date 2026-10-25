import AppKit
import PiopioKit

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
    private let renderer: ItemRenderer
    private let windowSize: Int
    private let pageSize: Int

    /// Every item of the session, oldest first; `items[windowStart...]` are in the document.
    public private(set) var items: [TimelineItem] = []
    private var windowStart = 0
    /// Document order and rendered length of each item in the window.
    private(set) var documentIDs: [String] = []
    private var lengths: [String: Int] = [:]
    private var streams: [String: StreamingItem] = [:]

    private var loading = false
    private var pendingEvents: [SessionEvent] = []
    private var prefetched: (text: SendableText, lengths: [Int], ids: [String])?
    private var prefetching = false
    private var boundsObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var scrollFrameObserver: NSObjectProtocol?
    private let hover = HoverTracker()
    private var hoveredItem: String?
    /// The action row under each message, by item (shown on hover and for the latest answer).
    private var actionRows: [String: MessageActions] = [:]
    private var columnWidth: CGFloat = 0
    private var laidOutWidth: CGFloat = 0
    /// Extra space at the bottom so the floating composer never covers the last line.
    public var bottomInset: CGFloat = 24 { didSet { layoutColumn(force: true) } }
    /// Widest the reading column gets (docs/design chat v3: 680), with at least 40 on each side.
    public var maxColumnWidth: CGFloat = 680
    private let minimumInset: CGFloat = 40

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

    public init(windowSize: Int = 300, pageSize: Int = 10, compact: Bool = false, versions: Bool = true, build: Bool = false, root: String? = nil) {
        renderer = ItemRenderer(compact: compact, versions: versions, build: build, root: root)
        self.windowSize = windowSize
        self.pageSize = pageSize
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 40, height: 24)
        textView.textContainer?.lineFragmentPadding = 0
        precondition(textView.textLayoutManager != nil, "TranscriptDocument needs TextKit 2")
        textView.textLayoutManager!.delegate = layoutDelegate
        // Links style themselves (markdown links blue, actions secondary); the view only adds the hand cursor.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = links
        links.document = self
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutColumn() }
        }
        // The scroll view itself can be resized (an inspector opening) without its clip view posting first.
        scrollView.postsFrameChangedNotifications = true
        scrollFrameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutColumn() }
        }
        textView.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: hover, userInfo: nil))
        hover.document = self
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isFollowing = self.atBottom
                self.loadOlderIfNeeded()
            }
        }
    }

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
        onAction?(action)
    }

    // MARK: Loading

    /// Replaces the document with a snapshot: the newest window is built off the main thread.
    public func load(_ snapshot: Snapshot) async {
        loading = true
        streams = [:]
        prefetched = nil
        items = snapshot.items
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
        if !events.isEmpty { refreshFooters() }
        if follow, !events.isEmpty { textView.scrollToEndOfDocument(nil) }
    }

    private func apply(_ event: SessionEvent) {
        switch event {
        case .itemAdded(let item):
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i] = item
                replace(item)
            } else {
                items.append(item)
                append(item)
            }
        case .itemInserted(let item, let before):
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i] = item
                replace(item)
            } else if let i = items.firstIndex(where: { $0.id == before }) {
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
            if let p = a.parts.lastIndex(where: { $0.type == partType }) { a.parts[p].text += delta } else { a.parts.append(AssistantPart(type: partType, text: delta)) }
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
        // The width, not the column: past 680 the column stays the same while its insets change.
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
        storage.endEditing()
    }

    /// Action rows show for the hovered message and the latest answer.
    private func refreshFooters() {
        var wanted = Set<String>()
        if let hoveredItem { wanted.insert(hoveredItem) }
        if let last = items.last(where: { if case .assistant(let a) = $0 { a.status != .streaming && !a.text.isEmpty } else { false } }) { wanted.insert(last.id) }
        for (id, row) in actionRows where row.visible != wanted.contains(id) { row.visible = wanted.contains(id) }
    }

    // MARK: Ask next

    /// Shows suggestions after the last answer (nil or empty hides them).
    public func showAskNext(_ suggestions: [String]?) {
        let next = suggestions ?? []
        guard next != askNext.items else { return }
        removeTail()
        askNext.items = next
        askNext.highlighted = 0
        if !next.isEmpty, !loading { insertTail() }
    }

    private func insertTail() {
        guard tailLength == 0, !askNext.items.isEmpty else { return }
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
        let thinkingText = a.parts.filter { $0.type == .thinking }.map(\.text).joined()
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

    private func streamDelta(id: String, partType: AssistantPart.PartType, delta: String) {
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
        var location: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: .reverse) { value, range, stop in
            if (value as? DisclosureAttachment)?.card === card { location = range.location; stop.pointee = true }
        }
        guard let location, let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: location),
              let end = content.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return }
        layoutManager.invalidateLayout(for: range)
        layoutManager.textViewportLayoutController.layoutViewport()
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

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, let action = TranscriptAction(url: url) else { return false } // regular links open in the browser
        document?.handle(action)
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
        let p = textView.convert(event.locationInWindow, from: nil)
        let inset = textView.textContainerInset
        document.hover(at: NSPoint(x: p.x - inset.width, y: p.y - inset.height))
    }

    override func mouseExited(with event: NSEvent) {
        document?.hover(at: nil)
    }
}

/// Markdown rendered in the transcript's style, for other views (the Chat lens file preview).
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
