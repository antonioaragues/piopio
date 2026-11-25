import AppKit
import CryptoKit
import Observation
import PiopioKit
import WebKit

/// Piopio's browser (docs/spec/22, W1: reading). The engine asks for each browser tool with `app.tool` and the
/// conversation's ref; this keeps that conversation's tabs, all in one profile that holds the user's sign-ins (BW5), and
/// answers with what the model reads (and screenshots). A conversation's tabs show in its Browser panel; while no panel
/// shows them they live in a transparent window on screen, so pages keep running at full speed (W0: a window off
/// screen or never shown is throttled to one frame a second). A tab nobody has used for `restAfter` leaves that window
/// and WebKit slows it down; the next tool call puts it back.
@MainActor @Observable
final class BrowserCenter {
    static let shared = BrowserCenter()

    /// The profile your conversations share: cookies, storage, sign-ins (spec 22 §7). Fixed, so it persists.
    static let profileID = UUID(uuidString: "B5A0B5E2-22A0-4000-8000-0000000000B1")!
    let store = WKWebsiteDataStore(forIdentifier: BrowserCenter.profileID)
    let world = WKContentWorld.world(name: "piopio")

    private(set) var sessions: [String: BrowserSession] = [:]
    /// Conversations whose Browser panel is open (chats), and a count bumped when the model first browses (Build).
    var openPanels: Set<String> = []
    private(set) var reveals: [String: Int] = [:]

    @ObservationIgnored private lazy var parking: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.orderFrontRegardless()
        return window
    }()

    // MARK: Local addresses

    /// Hosts of this Mac and private networks, as WebKit's URL filters write them (no "|": one rule each).
    static let localHosts = [
        #"localhost[:/]"#, #"[^/]*\.localhost[:/]"#, #"[^/]*\.local[:/]"#, #"0\."#, #"127\."#, #"10\."#, #"192\.168\."#, #"169\.254\."#,
        #"172\.1[6-9]\."#, #"172\.2[0-9]\."#, #"172\.3[01]\."#,
        #"100\.6[4-9]\."#, #"100\.[7-9][0-9]\."#, #"100\.1[01][0-9]\."#, #"100\.12[0-7]\."#,
        #"\[::1\]"#, #"\[::ffff:"#, #"\[f[cd]"#, #"\[fe80"#,
    ]

    /// Every load to those hosts blocked, whatever asks for it: an iframe, a page's fetch or WebSocket, an image, a redirect.
    static var noLocalRules: String {
        let rules = localHosts.map { ["trigger": ["url-filter": "^[a-z]+://([^/@]*@)?\($0)"], "action": ["type": "block"]] }
        // Encoded, not spliced: the filters' backslashes have to be escaped in JSON.
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    @ObservationIgnored private var noLocal: WKContentRuleList?
    @ObservationIgnored private var guarded: Set<ObjectIdentifier> = []

    /**
     * Keeps a browser tab's pages off this Mac and private networks (audit H5): a page the model opens could otherwise
     * reach a project's dev server or the router's admin page from an iframe or a script, which the check on the page's
     * own address doesn't see. The project preview, whose job is a local address, has its own profile and none of this.
     * False when WebKit didn't take the rules: the tab then loads nothing.
     */
    func keepOffLocal(_ view: WKWebView) async -> Bool {
        if noLocal == nil {
            noLocal = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "piopio.browser.no-local", encodedContentRuleList: Self.noLocalRules)
        }
        guard let noLocal else { return false }
        let controller = view.configuration.userContentController
        if guarded.insert(ObjectIdentifier(controller)).inserted { controller.add(noLocal) }
        return true
    }

    func session(_ id: String) -> BrowserSession {
        if let s = sessions[id] { return s }
        let s = BrowserSession(id: id, center: self)
        sessions[id] = s
        return s
    }

    func existing(_ id: String) -> BrowserSession? { sessions[id] }

    /// A web view no panel shows: into the transparent window, at a desktop size.
    func park(_ view: WKWebView) {
        guard let content = parking.contentView else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        parkedAt[ObjectIdentifier(view)] = .now
        startResting()
    }

    // MARK: Resting

    /// How long a parked tab keeps running at full speed with nobody using it. Every tab ever opened stayed in the
    /// transparent window at full speed for as long as Piopio ran (re-audit 2026-11-25 §5.2).
    static let restAfter: Duration = .seconds(600)
    @ObservationIgnored private var parkedAt: [ObjectIdentifier: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var resting: Task<Void, Never>?

    private func startResting() {
        guard resting == nil else { return }
        resting = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.rest()
            }
        }
    }

    /// Takes the parked tabs nobody used for `restAfter` out of the window: WebKit slows a page in no window (W0).
    func rest(now: ContinuousClock.Instant = .now) {
        let parked = parking.contentView?.subviews ?? []
        parkedAt = parkedAt.filter { id, _ in parked.contains { ObjectIdentifier($0) == id } }
        for view in parked {
            guard let since = parkedAt[ObjectIdentifier(view)], now - since > Self.restAfter, (view as? WKWebView)?.isLoading != true else { continue }
            view.removeFromSuperview()
            parkedAt[ObjectIdentifier(view)] = nil
        }
    }

    /// Before a tool call: the conversation's tabs no panel shows go back to the window, at full speed, from now.
    private func wake(_ session: BrowserSession) {
        for tab in session.tabs where tab.view.superview == nil || tab.view.superview === parking.contentView { park(tab.view) }
    }

    /// An agent's own profile (`agent:<id>`, spec 22 §7 and W3): created empty, kept between launches. Nil: yours.
    static func profileID(_ profile: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("piopio.profile:\(profile)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    @ObservationIgnored private var profiles: [String: WKWebsiteDataStore] = [:]

    func store(for profile: String?) -> WKWebsiteDataStore {
        guard let profile else { return store }
        if let s = profiles[profile] { return s }
        let s = WKWebsiteDataStore(forIdentifier: Self.profileID(profile))
        profiles[profile] = s
        return s
    }

    func makeWebView(_ configuration: WKWebViewConfiguration? = nil, profile: String? = nil) -> WKWebView {
        let config = configuration ?? {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = store(for: profile)
            // Look like Safari: some sites refuse a WebKit they don't recognise (spec 22 §12).
            c.applicationNameForUserAgent = "Version/27.0 Safari/605.1.15"
            c.userContentController.addUserScript(WKUserScript(source: BrowserScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
            return c
        }()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        view.allowsBackForwardNavigationGestures = true
        #if DEBUG
        // Not in releases: Web Inspector would open the signed-in pages to anything that can drive Safari's tools.
        view.isInspectable = true
        #endif
        park(view)
        return view
    }

    /// The model is browsing in this conversation: open its panel.
    func reveal(_ id: String) {
        // An agent browses on its own: Watch on its page opens the panel (spec 22 §5).
        if sessions[id]?.isAgent == true { return }
        openPanels.insert(id)
        reveals[id, default: 0] += 1
    }

    /// Closes a conversation's tabs.
    func close(_ id: String) {
        sessions.removeValue(forKey: id)?.tabs.forEach { $0.close() }
        openPanels.remove(id)
        reveals[id] = nil
    }

    /// A conversation or agent that was deleted (the catalog's `removed`): its tabs closed, and an agent's own profile
    /// (its sign-ins and storage) deleted with it, as the engine deletes its memory and files. Both stayed before.
    func forget(_ ref: ContainerRef) {
        close(ref.id)
        guard ref.kind == .agent else { return }
        let profile = "agent:\(ref.id)"
        profiles[profile] = nil
        let id = Self.profileID(profile)
        Task {
            // WebKit refuses while a closed tab's web view is still going away: once more, a moment later.
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                do { return try await WKWebsiteDataStore.remove(forIdentifier: id) } catch {}
            }
        }
    }

    // MARK: app.tool

    func handle(_ params: JSONValue) async -> JSONValue {
        let name = params["name"]?.stringValue ?? ""
        let args = params["args"] ?? .object([:])
        guard params["groups"]?.arrayValue?.contains(where: { $0.stringValue == "browser" }) == true,
              let id = params["ref"]?["id"]?.stringValue else {
            return Self.reply(ok: false, "The browser is for conversations, Build sessions and agents.")
        }
        let session = session(id)
        wake(session)
        // An agent's tabs live in its own profile unless its Setup says yours (W3). Changing it starts its tabs afresh.
        let profile = params["profile"]?.stringValue
        if session.profile != profile {
            session.tabs.forEach { session.closeTab($0) }
            session.profile = profile
        }
        if params["ref"]?["kind"]?.stringValue == "agent" { session.isAgent = true }
        let sites = params["sites"]?.arrayValue?.compactMap(\.stringValue) ?? []
        do {
            let r = try await session.run(name, args, sites: sites, preview: BrowserPreview(params["preview"]))
            return Self.reply(ok: true, r.text, images: r.images)
        } catch let need as NeedsSite {
            var o: [String: JSONValue] = ["ok": .bool(false), "output": .string("Acting on \(need.site) needs the user's permission.")]
            o["needsSite"] = .string(need.site)
            return .object(o)
        } catch let error as BrowserError {
            return Self.reply(ok: false, error.message)
        } catch {
            return Self.reply(ok: false, error.localizedDescription)
        }
    }

    static func reply(ok: Bool, _ output: String, images: [(mime: String, data: String)] = []) -> JSONValue {
        var o: [String: JSONValue] = ["ok": .bool(ok), "output": .string(output)]
        if !images.isEmpty { o["images"] = .array(images.map { .object(["mimeType": .string($0.mime), "data": .string($0.data)]) }) }
        return .object(o)
    }
}

struct BrowserError: Error { let message: String }
/// Acting on this site needs the user's permission first (the engine asks, then calls again).
struct NeedsSite: Error { let site: String }

/// The registrable domain of a URL ("mail.example.com" → "example.com"): what a permission is for (spec 22 §4.1).
/// A short list of two-part public suffixes stands in for the full Public Suffix List.
func browserSite(of url: URL?) -> String? {
    guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
    if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) || host.contains(":") { return host }
    let labels = host.split(separator: ".").map(String.init)
    guard labels.count > 2 else { return labels.joined(separator: ".") }
    let lastTwo = labels.suffix(2).joined(separator: ".")
    let twoPart: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp", "ne.jp", "or.jp",
                                "com.br", "com.mx", "com.ar", "co.in", "co.za", "com.tr", "com.cn", "com.hk", "com.sg", "co.kr", "com.es", "gob.es",
                                "com.pt", "github.io", "herokuapp.com", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "web.app",
                                "firebaseapp.com", "blogspot.com", "azurewebsites.net", "cloudfront.net", "onrender.com", "fly.dev"]
    return twoPart.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
}

/// One conversation's tabs.
@MainActor @Observable
final class BrowserSession {
    let id: String
    @ObservationIgnored unowned let center: BrowserCenter
    private(set) var tabs: [BrowserTab] = []
    var current: BrowserTab?
    @ObservationIgnored private var nextTab = 1
    /// The profile its tabs use: nil is yours; an agent's own is `agent:<id>` (spec 22 W3).
    @ObservationIgnored var profile: String?
    /// An agent's: it browses on its own, so its panel opens only when you Watch (spec 22 §5).
    @ObservationIgnored var isAgent = false

    init(id: String, center: BrowserCenter) {
        self.id = id
        self.center = center
    }

    @discardableResult
    func newTab(_ configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(id: "t\(nextTab)", session: self, view: center.makeWebView(configuration, profile: profile))
        nextTab += 1
        tabs.append(tab)
        current = tab
        return tab
    }

    func closeTab(_ tab: BrowserTab) {
        tab.close()
        tabs.removeAll { $0 === tab }
        if current === tab { current = tabs.last }
    }

    /// Opens a URL the user typed in the panel's address field.
    /// The address as the field shows it: without "https://" or "http://" and a bare trailing "/", so a narrow panel
    /// still shows the host and port ("localhost:5173", not "http://localhost:51").
    static func shown(_ url: URL?) -> String {
        guard var text = url?.absoluteString else { return "" }
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if text.hasSuffix("/"), text.dropLast().firstIndex(of: "/") == nil { text.removeLast() }
        return text
    }

    func go(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // A local address the field showed without its scheme ("localhost:5173") is http, not a search.
        let local = trimmed.wholeMatch(of: /(localhost|127\.0\.0\.1|\[::1\]|[\w.-]+\.localhost)(:\d+)?(\/\S*)?/) != nil
        let url = trimmed.contains("://") ? URL(string: trimmed) : local ? URL(string: "http://\(trimmed)") : trimmed.contains(".") && !trimmed.contains(" ") ? URL(string: "https://\(trimmed)") : URL(string: "https://duckduckgo.com/?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)")
        guard let url else { return }
        let tab = current ?? newTab()
        Task {
            if tab.preview == nil { guard await center.keepOffLocal(tab.view) else { return } }
            tab.view.load(URLRequest(url: url))
        }
    }

    // MARK: Tools

    /// When the model last acted here, for the panel's "Piopio is browsing" bar.
    var acting = false
    var lastActed: Date?

    func run(_ name: String, _ a: JSONValue, sites: [String] = [], preview: BrowserPreview? = nil) async throws -> (text: String, images: [(mime: String, data: String)]) {
        // The project preview (22 §6): its tab follows the engine's latest list of the project's addresses.
        if let preview, let tab = tabs.first(where: { $0.preview?.profile == preview.profile }) { tab.preview = preview }
        if ["browser_console", "browser_requests", "browser_eval"].contains(name) { return (try await previewTool(name, a), []) }
        if ["browser_click", "browser_type", "browser_select", "browser_key"].contains(name) {
            let tab = try active()
            // The page actually showing (the user may have gone elsewhere in the panel), checked against the grants.
            guard let site = browserSite(of: tab.view.url) else { throw BrowserError(message: "No page is open: use browser_open first.") }
            guard sites.contains(site) else { throw NeedsSite(site: site) }
            acting = true
            center.reveal(id)
            defer { acting = false; lastActed = Date() }
            return (try await tab.act(name, a), [])
        }
        switch name {
        case "browser_open":
            guard let raw = a["url"]?.stringValue, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw BrowserError(message: "The browser opens only http and https addresses.")
            }
            // A local address opens in the project preview, when the engine says it's the project's.
            if let target = BrowserPreview.target(url) {
                guard let preview, preview.local.contains(target) else {
                    throw BrowserError(message: "\(target) is a local address: it opens only as the project preview of a Build session.")
                }
                let tab = previewTab(preview)
                current = tab
                center.reveal(id)
                try await tab.load(url)
                return (try await tab.summary(map: true), [])
            }
            // Other sites never open in the preview's profile.
            let tab = (a["newTab"] == .bool(true) || current == nil || current?.preview != nil) ? newTab() : current!
            current = tab
            center.reveal(id)
            try await tab.load(url)
            return (try await tab.summary(map: true), [])
        case "browser_read":
            let tab = try active()
            let r = try await tab.call("return __piopio.read(selector)", ["selector": a["selector"]?.stringValue ?? NSNull()])
            if let error = r["error"]?.stringValue { throw BrowserError(message: error) }
            var text = "\(tab.header)\n\n\(r["text"]?.stringValue ?? "")"
            if r["truncated"] == .bool(true) { text += "\n\n(cut here: the page goes on; read a part with `selector`)" }
            return (tab.withDialogs(text), [])
        case "browser_map":
            let tab = try active()
            let filter = a["filter"]?.stringValue == "all" ? "all" : "viewport"
            return (tab.withDialogs("\(tab.header)\n\n\(try await tab.map(filter))"), [])
        case "browser_find":
            let tab = try active()
            let text = (a["text"]?.stringValue ?? "").lowercased()
            guard !text.isEmpty else { throw BrowserError(message: "Say what to find.") }
            let lines = try await tab.map("all").split(separator: "\n").filter { $0.hasPrefix("[e") && $0.lowercased().contains(text) }
            return (lines.isEmpty ? "Nothing on the page is named like “\(text)”. Try browser_read, or other words." : lines.prefix(40).joined(separator: "\n"), [])
        case "browser_screenshot":
            let tab = try active()
            let image = try await tab.screenshot(ref: a["ref"]?.stringValue, fullPage: a["fullPage"] == .bool(true))
            return ("\(tab.header)\nThe screenshot is attached.", [("image/jpeg", image)])
        case "browser_scroll":
            let tab = try active()
            var args: [String: Any] = ["ref": a["ref"]?.stringValue ?? NSNull(), "by": NSNull()]
            if let by = a["by"]?.numberValue { args["by"] = by }
            let r = try await tab.call("return __piopio.scroll(by, ref)", args)
            if r["error"] != nil { throw BrowserError(message: "That element isn't on the page any more: map the page again.") }
            try await Task.sleep(for: .milliseconds(400))
            let y = Int(r["y"]?.numberValue ?? 0), h = Int(r["height"]?.numberValue ?? 0)
            return (tab.withDialogs("Scrolled to \(y) of \(h) px.\n\n\(try await tab.map("viewport"))"), [])
        case "browser_back":
            let tab = try active()
            guard tab.view.canGoBack else { throw BrowserError(message: "There's no page to go back to in this tab.") }
            try await tab.navigate { $0.goBack() }
            return (try await tab.summary(map: true), [])
        case "browser_tabs":
            let op = a["op"]?.stringValue ?? "list"
            if op != "list" {
                guard let tid = a["tab"]?.stringValue, let tab = tabs.first(where: { $0.id == tid }) else { throw BrowserError(message: "No tab with that id; list them first.") }
                if op == "close" { closeTab(tab) } else { current = tab }
            }
            if tabs.isEmpty { return ("No tabs open.", []) }
            return (tabs.map { "\($0.id) · \($0.view.title ?? "") · \($0.view.url?.absoluteString ?? "about:blank")\($0 === current ? " (current)" : "")" }.joined(separator: "\n"), [])
        case "browser_wait":
            let tab = try active()
            let text = a["text"]?.stringValue ?? ""
            let gone = a["gone"] == .bool(true)
            let deadline = Date().addingTimeInterval(min(60, max(1, a["timeout"]?.numberValue ?? 10)))
            while Date() < deadline {
                let has = (try? await tab.call("return __piopio.hasText(text)", ["text": text]).boolValue) ?? false
                if has != gone { return (tab.withDialogs(gone ? "“\(text)” is gone." : "“\(text)” is on the page."), []) }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw BrowserError(message: gone ? "“\(text)” is still there after waiting." : "“\(text)” didn't appear in time.")
        default:
            throw BrowserError(message: "Unknown browser tool \(name).")
        }
    }

    private func active() throws -> BrowserTab {
        guard let current else { throw BrowserError(message: "No page is open: use browser_open first.") }
        return current
    }
}

/// One tab: a web view, how its last load went, and what dialogs the page showed.
@MainActor @Observable
final class BrowserTab: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let id: String
    @ObservationIgnored unowned let session: BrowserSession
    let view: WKWebView
    var title = ""
    var url: URL?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    /// The project preview's tab (22 §6): the project's profile and the local addresses it may open.
    var preview: BrowserPreview?
    @ObservationIgnored private var status: Int?
    @ObservationIgnored private var navError: String?
    @ObservationIgnored private var dialogs: [String] = []
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    init(id: String, session: BrowserSession, view: WKWebView) {
        self.id = id
        self.session = session
        self.view = view
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        observers = [
            view.observe(\.title) { [weak self] v, _ in MainActor.assumeIsolated { self?.title = v.title ?? "" } },
            view.observe(\.url) { [weak self] v, _ in MainActor.assumeIsolated { self?.url = v.url } },
            view.observe(\.isLoading) { [weak self] v, _ in MainActor.assumeIsolated { self?.isLoading = v.isLoading } },
            view.observe(\.canGoBack) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoBack = v.canGoBack } },
            view.observe(\.canGoForward) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoForward = v.canGoForward } },
        ]
    }

    func close() {
        observers = []
        view.stopLoading()
        view.removeFromSuperview()
    }

    var header: String { "\(view.title ?? "") · \(view.url?.absoluteString ?? "")" }

    // MARK: Loading

    @ObservationIgnored private var loadingNow = false

    func load(_ url: URL) async throws {
        if preview == nil, await !session.center.keepOffLocal(view) {
            throw BrowserError(message: "The browser can't open pages right now: Piopio couldn't keep them off local addresses. Quitting and reopening Piopio usually fixes it.")
        }
        try await navigate { $0.load(URLRequest(url: url)) }
    }

    func navigate(_ start: (WKWebView) -> Void) async throws {
        status = nil
        navError = nil
        loadingNow = true
        start(view)
        let deadline = Date().addingTimeInterval(30)
        while loadingNow && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if loadingNow { loadingNow = false; navError = navError ?? "The page took more than 30 seconds to load." }
        // Let the page's scripts draw what they draw after load.
        try await Task.sleep(for: .milliseconds(800))
        if let navError, view.url == nil || view.url?.absoluteString == "about:blank" { throw BrowserError(message: navError) }
    }

    func summary(map: Bool) async throws -> String {
        var text = header
        if let status, status >= 400 { text += "\nThe site answered \(status)." }
        if let navError { text += "\n\(navError)" }
        if map { text += "\n\n" + (try await self.map("viewport")) }
        return withDialogs(text)
    }

    func withDialogs(_ text: String) -> String {
        guard !dialogs.isEmpty else { return text }
        defer { dialogs = [] }
        return text + "\n\nThe page showed (Piopio dismissed them): " + dialogs.joined(separator: " · ")
    }

    // MARK: Acting (W2)

    func act(_ name: String, _ a: JSONValue) async throws -> String {
        let before = try await map("viewport")
        let beforeURL = view.url
        var said: String
        switch name {
        case "browser_click":
            if let ref = a["ref"]?.stringValue {
                let p = try await target(ref)
                if p["covered"] == .bool(true) {
                    throw BrowserError(message: "\(ref) is covered by \(p["coveredBy"]?.stringValue ?? "something") (a banner or a dialog?): close that first, or scroll.")
                }
                click(x: p["x"]?.numberValue ?? 0, y: p["y"]?.numberValue ?? 0, count: a["double"] == .bool(true) ? 2 : 1)
                said = "Clicked \(ref) \(p["role"]?.stringValue ?? "") “\(p["name"]?.stringValue ?? "")”."
            } else if let x = a["x"]?.numberValue, let y = a["y"]?.numberValue {
                click(x: x, y: y, count: a["double"] == .bool(true) ? 2 : 1)
                said = "Clicked at (\(Int(x)), \(Int(y)))."
            } else {
                throw BrowserError(message: "Say what to click: a ref from the map, or x and y.")
            }
        case "browser_type":
            guard let ref = a["ref"]?.stringValue, let text = a["text"]?.stringValue else { throw BrowserError(message: "Say which field (ref) and the text.") }
            let p = try await target(ref)
            if p["secret"] == .bool(true) { throw Self.handOff }
            if p["covered"] == .bool(true) { throw BrowserError(message: "\(ref) is covered by \(p["coveredBy"]?.stringValue ?? "something"): close that first.") }
            click(x: p["x"]?.numberValue ?? 0, y: p["y"]?.numberValue ?? 0, count: 1)
            try await Task.sleep(for: .milliseconds(150))
            // A click can move focus elsewhere (a sign-in pop-up's password field): never type into a secret field.
            if (try? await call("return __piopio.secretAtFocus()").boolValue) == true { throw Self.handOff }
            if a["append"] != .bool(true) { _ = try await call("return __piopio.selectContents(ref)", ["ref": ref]) }
            keys(text)
            try await Task.sleep(for: .milliseconds(200))
            var read = try await call("return __piopio.value(ref)", ["ref": ref])
            var how = ""
            let expected = a["append"] == .bool(true) ? nil : text
            if let expected, read["value"]?.stringValue != expected {
                read = try await call("return __piopio.setValue(ref, text)", ["ref": ref, "text": text])
                how = " (the page didn't take the keys, so Piopio set the value)"
            }
            said = "Typed into \(ref) “\(p["name"]?.stringValue ?? "")”\(how). It now reads: “\(read["value"]?.stringValue ?? "")”."
            if a["submit"] == .bool(true) {
                press("Enter")
                said += " Pressed Return."
            }
        case "browser_select":
            guard let ref = a["ref"]?.stringValue, let wanted = a["value"] else { throw BrowserError(message: "Say which element (ref) and the value.") }
            let p = try await target(ref)
            if case .bool(let on) = wanted {
                let now = try await call("return __piopio.checked(ref)", ["ref": ref])["checked"]?.boolValue ?? false
                if now != on { click(x: p["x"]?.numberValue ?? 0, y: p["y"]?.numberValue ?? 0, count: 1) }
                try await Task.sleep(for: .milliseconds(150))
                let after = try await call("return __piopio.checked(ref)", ["ref": ref])["checked"]?.boolValue ?? false
                said = "\(ref) “\(p["name"]?.stringValue ?? "")” is now \(after ? "checked" : "unchecked")."
            } else {
                let r = try await call("return __piopio.choose(ref, value)", ["ref": ref, "value": wanted.stringValue ?? ""])
                if r["error"]?.stringValue == "no option" {
                    throw BrowserError(message: "No option like “\(wanted.stringValue ?? "")”. The options: \((r["options"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " · "))")
                }
                if r["error"] != nil { throw BrowserError(message: "\(ref) isn't a list to choose from: click it, or type into it.") }
                said = "Chose “\(r["value"]?.stringValue ?? "")” in \(ref)."
            }
        case "browser_key":
            let keys = (a["keys"]?.stringValue ?? "").split(separator: " ").map(String.init)
            guard !keys.isEmpty else { throw BrowserError(message: "Say which keys.") }
            if (try? await call("return __piopio.secretAtFocus()").boolValue) == true, keys.contains(where: { $0.count == 1 }) { throw Self.handOff }
            for key in keys { press(key) }
            said = "Pressed \(keys.joined(separator: " "))."
        default:
            throw BrowserError(message: "Unknown browser tool \(name).")
        }
        return withDialogs(said + "\n\n" + (try await changes(since: before, url: beforeURL)))
    }

    static let handOff = BrowserError(message: "That's a password, code or payment field: the user fills it, never Piopio. Ask them to do it in the Browser panel, and continue when they say it's done.")

    /// Re-resolves a ref to where it is now (scrolled into view).
    private func target(_ ref: String) async throws -> JSONValue {
        let p = try await call("return __piopio.point(ref)", ["ref": ref])
        if p["error"] != nil { throw BrowserError(message: "\(ref) isn't on the page any more: map the page again for fresh refs.") }
        return p
    }

    /// What the action did: a new page, or the map's lines that appeared and went.
    private func changes(since before: String, url: URL?) async throws -> String {
        try await Task.sleep(for: .milliseconds(350))
        let deadline = Date().addingTimeInterval(15)
        while view.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if view.url != url {
            try await Task.sleep(for: .milliseconds(600))
            return "Now on \(header)\n\n\(try await map("viewport"))"
        }
        let after = try await map("viewport")
        let strip = { (line: Substring) in line.replacing(/\ @\(-?\d+,-?\d+\)$/, with: "") }
        let old = Set(before.split(separator: "\n").map(strip)), new = Set(after.split(separator: "\n").map(strip))
        let added = after.split(separator: "\n").filter { !old.contains(strip($0)) }
        let gone = before.split(separator: "\n").filter { !new.contains(strip($0)) }
        if added.isEmpty && gone.isEmpty { return "Nothing on the screen changed. If something should have, wait, or read the page." }
        var lines = ["Page changes:"]
        lines += added.prefix(30).map { "+ \($0)" }
        if added.count > 30 { lines.append("+ (\(added.count - 30) more)") }
        lines += gone.prefix(15).map { "- \(strip($0))" }
        if gone.count > 15 { lines.append("- (\(gone.count - 15) more)") }
        return lines.joined(separator: "\n")
    }

    // Real events, sent straight to the web view: pages see trusted input, in the panel or in the transparent window
    // alike, and nothing depends on which view has the keyboard (W0, spec 22 §13).

    @ObservationIgnored private var eventNumber = 1

    private func click(x: Double, y: Double, count: Int) {
        let point = view.convert(NSPoint(x: x, y: y), to: nil)
        for n in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                eventNumber += 1
                guard let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: eventNumber, clickCount: n, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                if type == .leftMouseDown { view.mouseDown(with: e) } else { view.mouseUp(with: e) }
            }
        }
    }

    private func keys(_ text: String) {
        for ch in text {
            if ch == "\n" { press("Enter"); continue }
            send(characters: String(ch), keyCode: 0, modifiers: [])
        }
    }

    /// One key, by name ("Enter", "ArrowDown", "cmd+a").
    private func press(_ spec: String) {
        var parts = spec.split(separator: "+").map { String($0) }
        let name = parts.removeLast()
        var flags: NSEvent.ModifierFlags = []
        for m in parts {
            switch m.lowercased() {
            case "cmd", "command", "meta": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "option": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: break
            }
        }
        let special: [String: (String, UInt16)] = [
            "enter": ("\r", 36), "return": ("\r", 36), "tab": ("\t", 48), "escape": ("\u{1b}", 53), "esc": ("\u{1b}", 53),
            "backspace": ("\u{7f}", 51), "delete": (String(UnicodeScalar(NSDeleteFunctionKey)!), 117), "space": (" ", 49),
            "arrowleft": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "arrowright": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
            "arrowdown": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "arrowup": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
            "pageup": (String(UnicodeScalar(NSPageUpFunctionKey)!), 116), "pagedown": (String(UnicodeScalar(NSPageDownFunctionKey)!), 121),
            "home": (String(UnicodeScalar(NSHomeFunctionKey)!), 115), "end": (String(UnicodeScalar(NSEndFunctionKey)!), 119),
        ]
        if let (chars, code) = special[name.lowercased()] { send(characters: chars, keyCode: code, modifiers: flags) }
        else { send(characters: name.count == 1 ? name.lowercased() : name, keyCode: 0, modifiers: flags) }
    }

    private func send(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { continue }
            if type == .keyDown {
                // Shortcuts (cmd+a) go through key equivalents first, as the window would send them.
                if !modifiers.intersection([.command, .control]).isEmpty, view.performKeyEquivalent(with: e) { continue }
                view.keyDown(with: e)
            } else {
                view.keyUp(with: e)
            }
        }
    }

    // MARK: Scripts

    /// Runs a function body in the isolated world (the page script is there already; defined again if the page
    /// navigated in between) and returns its JSON.
    func call(_ body: String, _ args: [String: Any] = [:]) async throws -> JSONValue {
        let wrapped = BrowserScript.source + "\nreturn JSON.stringify(await (async () => { \(body) })())"
        let result = try await view.callAsyncJavaScript(wrapped, arguments: args, in: nil, contentWorld: session.center.world)
        guard let s = result as? String, let data = s.data(using: .utf8) else { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    func map(_ filter: String) async throws -> String {
        let text = try await call("return __piopio.map({ filter })", ["filter": filter]).stringValue ?? ""
        return text.isEmpty ? "(nothing to click or type into on this screen)" : text
    }

    func screenshot(ref: String?, fullPage: Bool) async throws -> String {
        let config = WKSnapshotConfiguration()
        if let ref {
            let r = try await call("return __piopio.rect(ref)", ["ref": ref])
            if r["error"] != nil { throw BrowserError(message: "That element isn't on the page any more: map the page again.") }
            try await Task.sleep(for: .milliseconds(300))
            let again = try await call("return __piopio.rect(ref)", ["ref": ref])
            config.rect = CGRect(x: again["x"]?.numberValue ?? 0, y: again["y"]?.numberValue ?? 0, width: max(1, again["width"]?.numberValue ?? 1), height: max(1, again["height"]?.numberValue ?? 1))
        } else if fullPage {
            let h = try await call("return document.documentElement.scrollHeight").numberValue ?? Double(view.bounds.height)
            config.rect = CGRect(x: 0, y: 0, width: view.bounds.width, height: min(h, 12_000))
        }
        config.snapshotWidth = NSNumber(value: min(Double(config.rect.isNull || config.rect.isEmpty ? view.bounds.width : config.rect.width), 1280))
        let image: NSImage = try await withCheckedThrowingContinuation { c in
            view.takeSnapshot(with: config) { image, error in
                if let image { c.resume(returning: image) } else { c.resume(throwing: error ?? BrowserError(message: "The screenshot failed.")) }
            }
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw BrowserError(message: "The screenshot failed.")
        }
        return data.base64EncodedString()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        // Only web pages: links that would open other apps (mailto:, custom schemes) aren't followed (spec 22 §4.1).
        guard ["http", "https", "about", "data", "blob"].contains(scheme) else { return .cancel }
        if navigationAction.targetFrame?.isMainFrame != false, let host = navigationAction.request.url?.host(), Self.isLocal(host),
           !(preview.map { p in BrowserPreview.target(navigationAction.request.url).map { p.local.contains($0) } ?? false } ?? false) {
            dialogs.append("a link to \(host), a local address, was not followed")
            return .cancel
        }
        return navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame { status = (navigationResponse.response as? HTTPURLResponse)?.statusCode }
        // What the browser can't show is a download, and downloads ask (spec 22 §4.1).
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }

    // MARK: WKDownloadDelegate

    /// Asks before saving: the file and the site. Yes saves it in Downloads; it's never opened or run.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        loadingNow = false
        let site = browserSite(of: download.originalRequest?.url) ?? "a site"
        let alert = NSAlert()
        alert.messageText = "Save “\(suggestedFilename)” from \(site)?"
        alert.informativeText = "The browser in Piopio wants to download it. It goes to your Downloads folder and isn't opened."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        guard alert.runModal() == .alertFirstButtonReturn else {
            dialogs.append("a download (\(suggestedFilename)) was not saved: the user said no")
            return nil
        }
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var url = folder.appending(path: suggestedFilename)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        dialogs.append("downloaded \(suggestedFilename) to \(url.path) (the user allowed it)")
        return url
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        dialogs.append("a download failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loadingNow = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navError = "The page crashed."
        loadingNow = false
    }

    private func fail(_ error: Error) {
        // A navigation cancelled by the next one (or by Piopio's own policy) isn't the page failing.
        if (error as NSError).code != NSURLErrorCancelled { navError = error.localizedDescription }
        loadingNow = false
    }

    // MARK: WKUIDelegate

    /// Pop-ups and target=_blank open as tabs of the same conversation.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard session.tabs.count < 8 else { return nil }
        return session.newTab(configuration).view
    }

    /// Dialogs are answered by Piopio, not the page (spec 22 §4.5), and reported to the model.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        dialogs.append("alert “\(message.prefix(200))”")
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        dialogs.append("confirm “\(message.prefix(200))” (answered Cancel)")
        return false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        dialogs.append("prompt “\(prompt.prefix(200))” (answered Cancel)")
        return nil
    }

    /// Choosing a file to upload is always yours: the system's panel, which names the site (spec 22 §4.1).
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.message = "Choose what to upload to \(browserSite(of: frame.request.url) ?? "this site")"
        panel.prompt = "Upload"
        let urls = panel.runModal() == .OK ? panel.urls : nil
        dialogs.append(urls.map { "the user chose \($0.count) file\($0.count == 1 ? "" : "s") to upload" } ?? "the user didn't choose a file to upload")
        return urls
    }

    /// Camera, microphone and the like are denied while the model reads (spec 22 §4.1).
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }

    /// Hosts the browser doesn't open from a page: this Mac and private networks (projects get theirs in W4).
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h == "::1" || h == "0.0.0.0" { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (0, _), (169, 254), (192, 168): return true
        case (172, let b) where (16...31).contains(b): return true
        case (100, let b) where (64...127).contains(b): return true
        default: return false
        }
    }
}

extension JSONValue {
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
}
