import AppKit
import PiopioKit
import SwiftUI
import WebKit

// Visuals (docs/spec/25, V2): the model's `show_visual` drawn as live HTML in the transcript. Each visual is a web view
// with no network (a CSP in the page and a content rule list behind it), Piopio's design tokens as CSS variables, the
// bundled libraries at piopio-lib://, and one way back: `piopio.send(text)`, honoured only right after the user clicked
// or typed in it. Its height follows its content, up to a limit; a few web views stay alive and the rest come back from
// a picture of themselves until they're drawn again.

// MARK: Libraries

/// Serves the bundled libraries (Chart.js, d3, three.js, KaTeX) at `piopio-lib://<path>`, from the package's
/// VisualLibraries folder. Used by visuals and by HTML files in the viewer.
public final class VisualLibrary: NSObject, WKURLSchemeHandler {
    public static let scheme = "piopio-lib"
    @MainActor public static let shared = VisualLibrary()

    private static let root: URL? = Bundle.module.url(forResource: "VisualLibraries", withExtension: nil)?.standardizedFileURL

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.file(for: url), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        // CORS for modules (three.js) and fonts: the page's origin isn't this scheme's.
        let headers = ["Content-Type": Self.mime(file.pathExtension), "Access-Control-Allow-Origin": "*", "Content-Length": "\(data.count)"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// `piopio-lib://chart.js` → VisualLibraries/chart.js; `piopio-lib://katex/fonts/X.woff2` → …/katex/fonts/X.woff2.
    /// Nothing outside the folder.
    static func file(for url: URL) -> URL? {
        guard let root, url.scheme == scheme else { return nil }
        let parts = ((url.host() ?? "") + url.path()).split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        let file = parts.reduce(root) { $0.appending(path: $1) }.standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "woff2": "font/woff2"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }

    /// Blocks every load but the library, the page itself and inline data, for a web view showing HTML the user didn't
    /// write (visuals) or a file (the viewer, which adds `file`).
    @MainActor public static func offlineRules(allowing schemes: [String]) async -> WKContentRuleList? {
        let key = schemes.sorted().joined(separator: "+")
        if let list = compiled[key] { return list }
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},"# + schemes
            .map { #"{"trigger":{"url-filter":"^\#($0):"},"action":{"type":"ignore-previous-rules"}}"# }.joined(separator: ",") + "]"
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "piopio.offline.\(key)", encodedContentRuleList: rules)
        compiled[key] = list
        return list
    }

    @MainActor private static var compiled: [String: WKContentRuleList?] = [:]
}

// MARK: The page

/// The page a visual is drawn in: its HTML inside Piopio's head (CSP, tokens, base styles, the import map, the bridge).
public enum VisualPage {
    /// The page's own origin; nothing is served there.
    static let baseURL = URL(string: "piopio-visual://visual/")!

    static let csp = "default-src 'none'; script-src 'unsafe-inline' piopio-lib:; style-src 'unsafe-inline' piopio-lib:; img-src data: blob: piopio-lib:; font-src data: piopio-lib:; media-src data: blob:; connect-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'"

    static let importMap = #"<script type="importmap">{"imports":{"three":"piopio-lib://three.js","three/addons/":"piopio-lib://three/addons/"}}</script>"#

    /// What `piopio.send` and `piopio.prefill`, the height and the problems (script errors, failed and blocked loads) go
    /// through. Line numbers count from the model's HTML (the offset is filled in by `html`). A saved file has a stub.
    static let lineOffsetMark = "__PIOPIO_LINE_OFFSET__"
    static let bridge = """
    <script>(() => {
      const post = (m) => { try { window.webkit.messageHandlers.piopio.postMessage(m); } catch (e) {} };
      const offset = \(lineOffsetMark);
      window.piopio = Object.freeze({
        send: (text) => post({ type: "send", text: String(text) }),
        prefill: (text) => post({ type: "prefill", text: String(text) }),
      });
      let last = -1;
      const report = () => {
        if (!document.body) return;
        const h = Math.ceil(document.body.getBoundingClientRect().height);
        if (h !== last) { last = h; post({ type: "height", value: h }); }
      };
      addEventListener("DOMContentLoaded", () => { new ResizeObserver(report).observe(document.body); report(); });
      addEventListener("load", report);
      const problem = (text) => post({ type: "error", text: String(text).slice(0, 300) });
      addEventListener("error", (e) => {
        const t = e.target;
        if (t && t !== window && (t.src || t.href)) problem("Couldn't load " + (t.src || t.href));
        else problem((e.message || "Script error") + (e.lineno ? " (line " + Math.max(1, e.lineno - offset) + " of the HTML)" : ""));
      }, true);
      addEventListener("unhandledrejection", (e) => problem("Unhandled promise rejection: " + ((e.reason && e.reason.message) || e.reason)));
      addEventListener("securitypolicyviolation", (e) => problem("Blocked by the sandbox: " + (e.blockedURI || e.violatedDirective)));
      const consoleError = console.error.bind(console);
      console.error = (...args) => { problem("console.error: " + args.map(String).join(" ")); consoleError(...args); };
    })();</script>
    """

    /// The model's HTML as a page. `scrolls`: the sheet scrolls; in the transcript the card is as tall as the content.
    public static func html(_ content: String, title: String, scrolls: Bool = false, standalone: Bool = false) -> String {
        let head = [
            #"<meta charset="utf-8">"#,
            #"<meta http-equiv="Content-Security-Policy" content="\#(standalone ? portableCSP : csp)">"#,
            #"<meta name="viewport" content="width=device-width">"#,
            "<title>\(escape(title))</title>",
            "<style>\(tokens())\(baseStyle(scrolls: scrolls))</style>",
            importMap,
            standalone ? "<script>window.piopio = { send: () => {}, prefill: () => {} };</script>" : bridge,
        ].joined(separator: "\n")
        let headLines = head.filter { $0 == "\n" }.count
        // A whole document keeps its own head, after ours (so its styles win and our CSP still comes first).
        if content.range(of: "<html", options: .caseInsensitive) != nil {
            var page = content.replacingOccurrences(of: #"<!doctype[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            if let headTag = page.range(of: #"<head[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
                page.insert(contentsOf: "\n" + head, at: headTag.upperBound)
            } else if let htmlTag = page.range(of: #"<html[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
                page.insert(contentsOf: "<head>\n\(head)\n</head>", at: htmlTag.upperBound)
            }
            // Our doctype line and the lines of our head, inserted before most of theirs (close enough for scripts).
            return ("<!doctype html>\n" + page).replacingOccurrences(of: lineOffsetMark, with: "\(headLines + 2)")
        }
        // The fragment starts after the doctype, <html><head>, our head and </head><body>: that many lines down.
        return "<!doctype html>\n<html><head>\n\(head)\n</head><body>\n\(content)\n</body></html>".replacingOccurrences(of: lineOffsetMark, with: "\(headLines + 4)")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Chart series: distinct in both modes (a Tableau-like set, lighter in dark mode).
    static let series: [(light: UInt32, dark: UInt32)] = [
        (0x4E79A7, 0x7AA6D4), (0xF28E2B, 0xF7A85A), (0x59A14F, 0x7DC274), (0xE15759, 0xEF8486),
        (0x76B7B2, 0x95CEC9), (0xEDC948, 0xF2D774), (0xB07AA1, 0xC99BBC), (0x9C755F, 0xBB9884),
    ]

    /// The design tokens as CSS variables, light and dark (`prefers-color-scheme` follows the app).
    static func tokens() -> String {
        func vars(dark: Bool) -> String {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            func css(_ color: NSColor) -> String {
                var out = ""
                appearance.performAsCurrentDrawingAppearance {
                    let c = color.usingColorSpace(.sRGB) ?? color
                    out = String(format: "rgba(%d,%d,%d,%.3f)", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()), c.alphaComponent)
                }
                return out
            }
            let named: [(String, NSColor)] = [
                ("fg", DS.fg), ("fg2", DS.fg2), ("fg3", DS.fg3), ("line", DS.line), ("card", DS.card), ("bubble", DS.bubble),
                ("chip", DS.chip), ("accent", DS.accent), ("green", DS.green), ("amber", DS.amber), ("red", DS.red), ("win", DS.win),
            ]
            let colors = named.map { "--\($0.0):\(css($0.1));" }.joined()
            let chart = series.enumerated().map { i, c in
                let hex = dark ? c.dark : c.light
                return String(format: "--c%d:#%06X;", i + 1, hex)
            }.joined()
            return colors + chart
        }
        return ":root{color-scheme:light dark;--radius:8px;--radius-card:12px;--font:-apple-system,BlinkMacSystemFont,\"SF Pro Text\",system-ui,sans-serif;--font-mono:ui-monospace,\"SF Mono\",Menlo,monospace;\(vars(dark: false))}"
            + "@media (prefers-color-scheme: dark){:root{\(vars(dark: true))}}"
    }

    static func baseStyle(scrolls: Bool) -> String {
        """
        *,*::before,*::after{box-sizing:border-box}
        html,body{margin:0;padding:0;background:transparent}
        html{overflow:\(scrolls ? "auto" : "hidden")}
        body{padding:12px 14px;font:13px/1.45 var(--font);color:var(--fg);-webkit-font-smoothing:antialiased;display:flow-root}
        h1,h2,h3,h4{margin:0 0 8px;font-weight:600;line-height:1.25}h1{font-size:17px}h2{font-size:15px}h3,h4{font-size:13.5px}
        p{margin:0 0 8px}a{color:var(--accent)}code,pre{font-family:var(--font-mono);font-size:12px}
        button{font:inherit;font-size:12.5px;color:var(--fg);background:var(--card);border:1px solid var(--line);border-radius:var(--radius);padding:5px 12px;cursor:pointer}
        button:hover{background:var(--chip)}button:active{opacity:.8}
        input,select,textarea{font:inherit;color:var(--fg);background:var(--card);border:1px solid var(--line);border-radius:6px;padding:4px 8px}
        input[type=range]{padding:0;accent-color:var(--accent)}
        table{border-collapse:collapse;font-size:12.5px}th,td{border-bottom:1px solid var(--line);padding:6px 10px;text-align:left}th{color:var(--fg2);font-weight:600}
        svg{max-width:100%}canvas{max-width:100%}
        """
    }

    /// A page that works anywhere: no network, and the libraries inline, as `data:` URLs for modules.
    static let portableCSP = "default-src 'none'; script-src 'unsafe-inline' data:; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"

    /// A visual as a file (Save…) or inside an export: the page with `send` and `prefill` doing nothing, and every
    /// library it uses inlined, so it draws in any browser with no network and nothing from Piopio.
    @MainActor public static func portable(_ content: String, title: String, scrolls: Bool = true) -> String {
        var page = html(content, title: title, scrolls: scrolls, standalone: true)
        // Classic scripts: <script src="piopio-lib://chart.js"></script> → the script itself.
        page = page.replacing(/<script([^>]*?)\s+src="piopio-lib:\/\/([^"]+)"([^>]*)>\s*<\/script>/) { m in
            guard let js = library(String(m.output.2)) else { return String(m.output.0) }
            return "<script\(m.output.1)\(m.output.3)>\(String(decoding: js, as: UTF8.self).replacingOccurrences(of: "</script", with: "<\\/script"))</script>"
        }
        // Stylesheets (KaTeX), with their fonts as data URLs.
        page = page.replacing(/<link[^>]*href="piopio-lib:\/\/([^"]+\.css)"[^>]*>/) { m in
            let path = String(m.output.1)
            guard let css = library(path).map({ String(decoding: $0, as: UTF8.self) }) else { return String(m.output.0) }
            let folder = (path as NSString).deletingLastPathComponent
            let inlined = css.replacing(/url\((fonts\/[^)]+\.woff2)\)/) { f in
                guard let font = library(folder.isEmpty ? String(f.output.1) : "\(folder)/\(f.output.1)") else { return String(f.output.0) }
                return "url(data:font/woff2;base64,\(font.base64EncodedString()))"
            }
            return "<style>\(inlined)</style>"
        }
        // three.js: the import map points at data URLs, and only when the visual imports it (it's 650 KB).
        let usesThree = content.contains("\"three") || content.contains("'three")
        let map = usesThree ? threeImportMap() : ""
        return page.replacingOccurrences(of: importMap, with: map)
    }

    @MainActor static func library(_ path: String) -> Data? {
        guard let url = URL(string: "piopio-lib://\(path)"), let file = VisualLibrary.file(for: url) else { return nil }
        return try? Data(contentsOf: file)
    }

    @MainActor static func threeImportMap() -> String {
        func module(_ path: String) -> String? { library(path).map { "data:text/javascript;base64,\($0.base64EncodedString())" } }
        var imports: [String: String] = [:]
        if let three = module("three.js") { imports["three"] = three }
        if let orbit = module("three/addons/controls/OrbitControls.js") { imports["three/addons/controls/OrbitControls.js"] = orbit }
        guard let json = try? JSONSerialization.data(withJSONObject: ["imports": imports], options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return #"<script type="importmap">"# + String(decoding: json, as: UTF8.self) + "</script>"
    }
}

// MARK: Export

/// Visuals in exports (docs/spec/25 §8). The engine can't draw, so its export leaves the title and a marker with the
/// tool call's id (base64url); this puts the visual there: in HTML, a sandboxed frame with the portable page, as tall
/// as the visual; in Markdown, a picture of it as a data URL. Copying as Markdown keeps just the title.
@MainActor public enum VisualExport {
    /// The width an export's column gives a visual (760 pt, less the page's padding).
    static let width: CGFloat = 728

    public static func callId(fromMarker id: String) -> String? {
        var base64 = id.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `visual(callId)` finds the visual's title and HTML in the conversation.
    public static func fill(_ content: String, html: Bool, visual: (String) -> (title: String, html: String)?) async -> String {
        let markers = html ? content.matches(of: /<div data-piopio-visual="([A-Za-z0-9_-]+)"><\/div>/).map { ($0.range, String($0.output.1)) }
            : content.matches(of: /<!-- piopio-visual:([A-Za-z0-9_-]+) -->/).map { ($0.range, String($0.output.1)) }
        guard !markers.isEmpty else { return content }
        var out = "", at = content.startIndex
        for (range, id) in markers {
            out += content[at..<range.lowerBound]
            at = range.upperBound
            guard let callId = callId(fromMarker: id), let v = visual(callId) else { continue }
            out += html ? await frame(v.title, v.html, key: callId) : await picture(v.title, v.html)
        }
        return out + content[at...]
    }

    /// Copy as Markdown: the visual's title line stays, its marker goes.
    public static func strip(_ markdown: String) -> String {
        markdown.replacing(/\n*<!-- piopio-visual:[A-Za-z0-9_-]+ -->\n*/, with: "\n\n")
    }

    static func frame(_ title: String, _ html: String, key: String) async -> String {
        var height = VisualStore.shared.heights[key] ?? 0
        if height <= 0 { height = await VisualChecker.check(html: html, title: title, look: false, width: width).height }
        let page = VisualPage.portable(html, title: title, scrolls: false)
        let shown = Int(min(max(height, 40), VisualCardModel.maxContentHeight)) + 2
        return #"<iframe title="\#(attribute(title))" sandbox="allow-scripts" loading="lazy" style="display:block;width:100%;height:\#(shown)px;border:1px solid rgba(128,128,128,.3);border-radius:12px;margin:8px 0" srcdoc="\#(attribute(page))"></iframe>"#
    }

    static func picture(_ title: String, _ html: String) async -> String {
        guard let jpeg = await VisualChecker.check(html: html, title: title, look: true, width: width).jpeg else { return "" }
        return "![\(title.replacingOccurrences(of: "]", with: ")"))](data:image/jpeg;base64,\(jpeg.base64EncodedString()))"
    }

    static func attribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: Web view

/// A visual's web view: the wheel scrolls the conversation, not the page, and the page can send only right after the
/// user clicked in it or typed while it had focus. Clicks and keys are watched app-wide: WebKit takes them in its own
/// views, so overriding `mouseDown` here sees nothing.
public final class VisualWebView: WKWebView {
    /// When this page last sent, so one click sends once.
    var lastSent = Date.distantPast
    /// The card showing it now (cards are made again when the transcript renders; the web view stays).
    weak var card: VisualCardView?
    /// Every message from the page, for the check (§3.2).
    var observer: (@MainActor (String, [String: Any]) -> Void)?
    var key = ""
    var loaded = false
    /// When false (the sheet), the page scrolls itself.
    var forwardsScroll = true

    public override func scrollWheel(with event: NSEvent) {
        if forwardsScroll { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    /// The last click and key press anywhere in the app.
    @MainActor private static var lastClick: (at: Date, window: NSWindow?, point: NSPoint)?
    @MainActor private static var lastKey: (at: Date, window: NSWindow?)?
    @MainActor private static var monitor: Any?
    /// The transcript's own gesture recognizers, paused while the mouse is down in a visual.
    @MainActor private static var paused: [NSGestureRecognizer] = []

    @MainActor private static func watchInput() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { event in
            MainActor.assumeIsolated {
                switch event.type {
                case .leftMouseDown:
                    lastClick = (.now, event.window, event.locationInWindow)
                    letClickThrough(event)
                case .leftMouseUp:
                    // After this event is delivered: the text view's selection works again everywhere else.
                    guard !paused.isEmpty else { break }
                    DispatchQueue.main.async {
                        paused.forEach { $0.isEnabled = true }
                        paused = []
                    }
                default:
                    lastKey = (.now, event.window)
                }
            }
            return event
        }
    }

    /// The transcript is a text view, and its selection gestures hold a mouse-down back until they know it isn't a
    /// double click or a drag, which can swallow a click meant for a page inside it. While the mouse is down in a
    /// visual, those gestures (only the text view's) are paused, so the click goes straight to the page.
    @MainActor private static func letClickThrough(_ event: NSEvent) {
        guard let frame = event.window?.contentView?.superview else { return }
        var view = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
        while let v = view, !(v is VisualWebView) { view = v.superview }
        guard view != nil else { return }
        while let v = view?.superview {
            if v is NSTextView {
                for g in v.gestureRecognizers where g.isEnabled && g.delaysPrimaryMouseButtonEvents {
                    g.isEnabled = false
                    paused.append(g)
                }
            }
            view = v
        }
    }

    /// True when, in the last few seconds and since it last sent, the user clicked inside this visual or pressed a key
    /// while it had focus.
    @MainActor var userJustActed: Bool {
        guard let window else { return false }
        let recent = { (at: Date) in Date.now.timeIntervalSince(at) < 3 && at > self.lastSent }
        if let c = Self.lastClick, recent(c.at), c.window === window, bounds.contains(convert(c.point, from: nil)) { return true }
        if let k = Self.lastKey, recent(k.at), k.window === window, let responder = window.firstResponder as? NSView, responder === self || responder.isDescendant(of: self) { return true }
        return false
    }

    @MainActor static func make(scrolls: Bool) -> VisualWebView {
        watchInput()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(VisualLibrary.shared, forURLScheme: VisualLibrary.scheme)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = VisualWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), configuration: config)
        view.forwardsScroll = !scrolls
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.navigationDelegate = VisualNavigation.shared
        view.uiDelegate = VisualNavigation.shared
        config.userContentController.add(VisualBridge(view), name: "piopio")
        return view
    }

    /// Loads the page once the offline rules are in (before the first load, or its first requests would go out).
    @MainActor func show(_ content: String, title: String, scrolls: Bool) {
        Task { @MainActor in
            if let rules = await VisualLibrary.offlineRules(allowing: [VisualLibrary.scheme, "piopio-visual", "about", "data", "blob"]) {
                configuration.userContentController.removeAllContentRuleLists()
                configuration.userContentController.add(rules)
            }
            loadHTMLString(VisualPage.html(content, title: title, scrolls: scrolls), baseURL: VisualPage.baseURL)
        }
    }
}

/// Messages from the page, held weakly (the user content controller keeps its handlers).
final class VisualBridge: NSObject, WKScriptMessageHandler {
    private weak var view: VisualWebView?

    init(_ view: VisualWebView) { self.view = view }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let view, message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "height":
                if let value = body["value"] as? Double { view.card?.contentHeightChanged(CGFloat(value), from: view) ?? VisualStore.shared.noteHeight(CGFloat(value), key: view.key) }
            case "send", "prefill":
                // Only the user's own click or key press sends; a page can't write in their name on its own.
                guard view.userJustActed, let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
                view.lastSent = .now
                let clipped = String(text.prefix(2000)), sends = type == "send"
                if let card = view.card { card.answer(clipped, send: sends) } else { VisualSheetSender.current?(clipped, sends) }
            default:
                break
            }
            view.observer?(type, body)
        }
    }
}

/// Where `piopio.send` (true) and `piopio.prefill` (false) go from the sheet (set by the app while a visual is open).
@MainActor public enum VisualSheetSender {
    public static var current: ((String, Bool) -> Void)?
}

/// Navigation for every visual: the page itself loads; a link the user clicks opens in their browser; nothing else.
final class VisualNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    @MainActor static let shared = VisualNavigation()

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        // The page itself (loadHTMLString's base URL), anchors in it, and about:blank / srcdoc frames.
        var bare = URLComponents(url: url, resolvingAgainstBaseURL: false)
        bare?.fragment = nil
        if url.scheme == "about" || bare?.url == VisualPage.baseURL { return .allow }
        if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard let view = webView as? VisualWebView else { return }
            view.loaded = true
            view.card?.pageLoaded(view)
        }
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            guard let view = webView as? VisualWebView else { return }
            VisualStore.shared.drop(view.key)
            view.card?.failed()
        }
    }
}

// MARK: Store

/// Web views, heights and pictures of visuals, by tool call: a transcript renders its items again often, and a visual
/// shouldn't reload or jump each time. At most `maxLive` web views are kept; the others come back from their picture.
@MainActor final class VisualStore {
    static let shared = VisualStore()
    static let maxLive = 6

    private(set) var heights: [String: CGFloat] = [:]
    /// The width cards were last laid out at: the check draws at it.
    var columnWidth: CGFloat = 720
    private(set) var pictures: [String: NSImage] = [:]
    private var live: [(key: String, view: VisualWebView)] = []

    func noteHeight(_ height: CGFloat, key: String) { heights[key] = height }
    func notePicture(_ image: NSImage, key: String) { pictures[key] = image }

    /// The web view for a visual: the one kept, or a new one (`fresh`), which the caller loads.
    func webView(_ key: String) -> (view: VisualWebView, fresh: Bool) {
        if let i = live.firstIndex(where: { $0.key == key }) {
            let entry = live.remove(at: i)
            live.append(entry)
            return (entry.view, false)
        }
        let view = VisualWebView.make(scrolls: false)
        view.key = key
        live.append((key, view))
        trim()
        return (view, true)
    }

    func drop(_ key: String) { live.removeAll { $0.key == key } }

    /// Lets go of the oldest web views no card shows.
    private func trim() {
        while live.count > Self.maxLive, let i = live.firstIndex(where: { $0.view.window == nil }) {
            let gone = live.remove(at: i).view
            gone.card = nil
            gone.stopLoading()
        }
    }
}

// MARK: Attachment

/// A visual in the transcript (the document wires `onAction` and `onResize`, as it does the other cards).
public final class VisualCardModel: @unchecked Sendable {
    /// The item, for Open.
    let itemId: String
    /// The tool call: the store keeps its web view, height and picture under it.
    let key: String
    let title: String
    let html: String
    /// The conversation's folder, where Save… starts.
    let root: String?
    var onAction: (@MainActor (TranscriptAction) -> Void)?
    var onResize: (@MainActor (VisualCardModel) -> Void)?

    init(itemId: String, key: String, title: String, html: String, root: String?) {
        self.itemId = itemId
        self.key = key
        self.title = title.isEmpty ? "Visual" : title
        self.html = html
        self.root = root
    }

    static let headerHeight: CGFloat = 34
    static let placeholderHeight: CGFloat = 180
    static let maxContentHeight: CGFloat = 900
    static let minContentHeight: CGFloat = 40

    /// The card's height: the header and the content as tall as it says, within limits.
    @MainActor var height: CGFloat { Self.headerHeight + contentHeight + 1 }

    @MainActor var contentHeight: CGFloat {
        guard let h = VisualStore.shared.heights[key] else { return Self.placeholderHeight }
        return min(Self.maxContentHeight, max(Self.minContentHeight, h))
    }

    @MainActor var clipped: Bool { (VisualStore.shared.heights[key] ?? 0) > Self.maxContentHeight }
}

final class VisualAttachment: NSTextAttachment, @unchecked Sendable {
    let model: VisualCardModel

    init(model: VisualCardModel) {
        self.model = model
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = VisualViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class VisualViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let model = (textAttachment as! VisualAttachment).model
        view = MainActor.assumeIsolated { VisualCardView(model: model) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = textContainer?.size.width ?? proposedLineFragment.width
        let model = (textAttachment as! VisualAttachment).model
        let height = MainActor.assumeIsolated { model.height }
        return CGRect(x: 0, y: -6, width: width, height: height)
    }
}

// MARK: Card

/// The card: a header (title, Open, Save…, Copy HTML, Reload) over the visual, in a hairline frame. The visual is the
/// store's web view while it's live, its picture while it's being drawn again, and "Drawing…" before either exists.
public final class VisualCardView: NSView, ArrowCursorArea {
    let model: VisualCardModel
    private var header: NSView!
    private let content = NSView()
    private var webView: VisualWebView?
    private var picture: NSImageView?
    private var placeholder: NSTextField?
    private var settle: DispatchWorkItem?

    init(model: VisualCardModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: model.height))
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.card
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        layer?.borderColor = DS.line.cgColor
        header = ArrowHostingView(rootView: VisualHeader(title: model.title, clipped: model.clipped) { [weak self] command in self?.run(command) })
        addSubview(header)
        content.wantsLayer = true
        addSubview(content)
        // A group VoiceOver reads by its title, with the visual's own contents inside it.
        setAccessibilityRole(.group)
        setAccessibilityLabel("Visual: \(model.title)")
        if let image = VisualStore.shared.pictures[model.key] { showPicture(image) } else { showPlaceholder("Drawing…") }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = DS.line.cgColor }
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        if bounds.width > 200 { VisualStore.shared.columnWidth = bounds.width }
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: VisualCardModel.headerHeight)
        content.frame = NSRect(x: 0, y: VisualCardModel.headerHeight + 1, width: bounds.width, height: max(0, bounds.height - VisualCardModel.headerHeight - 1))
        webView?.frame = content.bounds
        picture?.frame = content.bounds
        placeholder?.sizeToFit()
        if let p = placeholder { p.frame.origin = NSPoint(x: (content.bounds.width - p.frame.width) / 2, y: (content.bounds.height - p.frame.height) / 2) }
    }

    public override func draw(_ dirtyRect: NSRect) {
        DS.line.setFill()
        NSRect(x: 0, y: VisualCardModel.headerHeight, width: bounds.width, height: 1).fill()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { adopt() }
    }

    /// Takes the store's web view for this visual into the card (loading it when it's new).
    private func adopt() {
        let (view, fresh) = VisualStore.shared.webView(model.key)
        view.card = self
        webView = view
        view.removeFromSuperview()
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        // Under the picture until it has drawn, so a visual coming back doesn't flash empty.
        content.addSubview(view, positioned: .below, relativeTo: picture ?? placeholder)
        if fresh { view.show(model.html, title: model.title, scrolls: false) } else if view.loaded { pageLoaded(view) }
    }

    func pageLoaded(_ view: VisualWebView) {
        guard view === webView else { return }
        // The first height usually arrives before this; let the page draw, then show it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.webView === view else { return }
            self.removePicture()
            self.placeholder?.removeFromSuperview()
            self.placeholder = nil
            self.scheduleSettle()
        }
    }

    func contentHeightChanged(_ height: CGFloat, from view: VisualWebView) {
        let before = model.contentHeight
        VisualStore.shared.noteHeight(height, key: model.key)
        if abs(model.contentHeight - before) >= 1 {
            (header as? ArrowHostingView<VisualHeader>)?.rootView = VisualHeader(title: model.title, clipped: model.clipped) { [weak self] command in self?.run(command) }
            model.onResize?(model)
        }
        scheduleSettle()
    }

    /// Once it stops changing, a picture of it, for when it's drawn again.
    private func scheduleSettle() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let view = self.webView, view.window != nil, view.loaded else { return }
            let key = self.model.key
            view.takeSnapshot(with: nil) { image, _ in
                if let image { MainActor.assumeIsolated { VisualStore.shared.notePicture(image, key: key) } }
            }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func failed() {
        webView?.removeFromSuperview()
        webView = nil
        removePicture()
        showPlaceholder("This visual stopped. Reload to draw it again.")
    }

    func answer(_ text: String, send: Bool) {
        model.onAction?(send ? .reply(text: text) : .prefill(text: text))
    }

    private func showPicture(_ image: NSImage) {
        let view = NSImageView(image: image)
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignTopLeft
        content.addSubview(view)
        picture = view
    }

    private func removePicture() {
        picture?.removeFromSuperview()
        picture = nil
    }

    private func showPlaceholder(_ text: String) {
        placeholder?.removeFromSuperview()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = DS.fg3
        content.addSubview(label)
        placeholder = label
        needsLayout = true
    }

    enum Command { case open, save, copy, reload }

    private func run(_ command: Command) {
        switch command {
        case .open:
            model.onAction?(.openVisual(itemId: model.itemId))
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.html, forType: .string)
        case .reload:
            VisualStore.shared.drop(model.key)
            webView?.removeFromSuperview()
            webView = nil
            removePicture()
            showPlaceholder("Drawing…")
            adopt()
        case .save:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = Self.fileName(model.title)
            panel.allowedContentTypes = [.html]
            if let root = model.root { panel.directoryURL = URL(fileURLWithPath: root, isDirectory: true) }
            let page = VisualPage.portable(model.html, title: model.title)
            let done: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                try? page.write(to: url, atomically: true, encoding: .utf8)
            }
            if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
        }
    }

    /// "Usage card: three options" → "Usage card - three options.html".
    static func fileName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: ":", with: " -").replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Visual" : String(cleaned.prefix(80))) + ".html"
    }
}

/// The card's header: a visual's icon and title, and its actions.
struct VisualHeader: View {
    let title: String
    let clipped: Bool
    let act: (VisualCardView.Command) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.3.group").font(.system(size: 11)).foregroundStyle(Color(nsColor: DS.fg3))
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color(nsColor: DS.fg2)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if clipped {
                Button("Show all") { act(.open) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg2))
                    .help("It's taller than the conversation shows; open it whole")
            }
            button("arrow.up.left.and.arrow.down.right", "Open", .open)
            button("square.and.arrow.down", "Save as a file…", .save)
            button("doc.on.doc", "Copy HTML", .copy)
            button("arrow.clockwise", "Reload", .reload)
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func button(_ symbol: String, _ label: String, _ command: VisualCardView.Command) -> some View {
        Button { act(command) } label: {
            Image(systemName: symbol).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: DS.fg3)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: Sheet

/// A visual on its own, larger and scrolling (Open). The app puts it in a sheet.
public struct VisualPreview: NSViewRepresentable {
    let title: String
    let html: String

    public init(title: String, html: String) {
        self.title = title
        self.html = html
    }

    public func makeNSView(context: Context) -> VisualWebView {
        let view = VisualWebView.make(scrolls: true)
        view.show(html, title: title, scrolls: true)
        return view
    }

    public func updateNSView(_ view: VisualWebView, context: Context) {}
}

// MARK: Check

/// Draws a visual the model just made, before anyone looks, and says how it went (docs/spec/25 §3.2): the height it
/// took at the conversation's width, script errors and failed or blocked loads, and with `look`, a picture. It draws in
/// a transparent window on screen (off-screen windows run at one frame a second, docs/spec/22 W0) that ignores the mouse.
@MainActor public enum VisualChecker {
    private static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 2100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.orderFrontRegardless()
        return window
    }()

    /// What the page reported while it was drawn.
    final class Report {
        var height: CGFloat = 0
        var lastChange = Date.now
        var problems: [String] = []
        var loaded = false

        /// A problem, once. A blocked load reports twice (the element's error and the sandbox's): keep the sandbox's.
        func add(_ text: String) {
            let blocked = "Blocked by the sandbox: ", failed = "Couldn't load "
            if text.hasPrefix(failed), problems.contains(blocked + text.dropFirst(failed.count)) { return }
            if text.hasPrefix(blocked) { problems.removeAll { $0 == failed + text.dropFirst(blocked.count) } }
            guard problems.count < 12, !problems.contains(text) else { return }
            problems.append(text)
        }
    }

    public struct Result: Sendable {
        public var width: CGFloat
        public var height: CGFloat
        public var problems: [String]
        public var loaded: Bool
        public var jpeg: Data?
    }

    /// `app.tool` `show_visual` (group `visuals`): `args` are the tool's, plus `callId`.
    public static func handle(_ params: JSONValue) async -> JSONValue {
        let args = params["args"]
        guard let html = args?["html"]?.stringValue, !html.isEmpty else { return reply(ok: false, "Nothing to draw: html is empty.") }
        let title = args?["title"]?.stringValue ?? "Visual"
        let look = args?["look"] == .bool(true)
        let r = await check(html: html, title: title, look: look, width: VisualStore.shared.columnWidth)
        // The card starts at this height instead of its placeholder, unless it has measured itself already.
        if let key = args?["callId"]?.stringValue, r.loaded, r.height > 0, VisualStore.shared.heights[key] == nil { VisualStore.shared.noteHeight(r.height, key: key) }
        return reply(ok: true, summary(r), jpeg: r.jpeg)
    }

    public static func check(html: String, title: String, look: Bool, width: CGFloat) async -> Result {
        let report = Report()
        let view = VisualWebView.make(scrolls: false)
        view.observer = { type, body in
            switch type {
            case "height":
                if let value = body["value"] as? Double, abs(CGFloat(value) - report.height) >= 1 { report.height = CGFloat(value); report.lastChange = .now }
            case "error":
                if let text = body["text"] as? String { report.add(text) }
            default:
                break
            }
        }
        view.frame = NSRect(x: 0, y: 0, width: width, height: VisualCardModel.maxContentHeight)
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }
        view.show(html, title: title, scrolls: false)

        // Loaded (at most 5 s), then quiet: no change of height for half a second (at most 3 s more).
        let start = Date.now
        while !view.loaded, Date.now.timeIntervalSince(start) < 5 { try? await Task.sleep(for: .milliseconds(50)) }
        report.loaded = view.loaded
        let loadedAt = Date.now
        report.lastChange = max(report.lastChange, loadedAt)
        while report.loaded, Date.now.timeIntervalSince(report.lastChange) < 0.5, Date.now.timeIntervalSince(loadedAt) < 3 { try? await Task.sleep(for: .milliseconds(50)) }

        var jpeg: Data?
        if look, report.loaded {
            view.frame.size.height = min(max(report.height, 40), 2000)
            try? await Task.sleep(for: .milliseconds(150))
            if let image = try? await view.takeSnapshot(configuration: nil) { jpeg = Self.jpeg(image, maxWidth: 1280) }
        }
        return Result(width: width, height: report.height, problems: report.problems, loaded: report.loaded, jpeg: jpeg)
    }

    /// What the model reads.
    static func summary(_ r: Result) -> String {
        guard r.loaded else { return "It didn't finish loading in 5 s, so it may show nothing. Make it simpler, or check its scripts." }
        var lines = ["Drawn at \(Int(r.width)) × \(Int(r.height)) px."]
        if r.height > VisualCardModel.maxContentHeight { lines.append("That's taller than the \(Int(VisualCardModel.maxContentHeight)) px the conversation shows; the rest is behind Show all.") }
        if r.height < 24 { lines.append("It looks empty: nothing in it takes up space.") }
        if r.problems.isEmpty { lines.append("No script errors or failed loads.") } else {
            lines.append("Script errors and failed loads (fix them with a new show_visual):")
            lines += r.problems.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    static func reply(ok: Bool, _ output: String, jpeg: Data? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["ok": .bool(ok), "output": .string(output)]
        if let jpeg { o["images"] = .array([.object(["mimeType": .string("image/jpeg"), "data": .string(jpeg.base64EncodedString())])]) }
        return .object(o)
    }

    /// The picture as JPEG, no wider than `maxWidth` pixels.
    static func jpeg(_ image: NSImage, maxWidth: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxWidth / CGFloat(cg.width))
        let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // A visual has no background of its own: put the window's under it, as the conversation does.
        DS.win.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
