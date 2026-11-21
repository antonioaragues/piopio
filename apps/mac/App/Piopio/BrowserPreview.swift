import CryptoKit
import Foundation
import PiopioKit
import WebKit

/// The project preview (docs/spec/22 §6, roadmap PAR3): a Build session's dev-server pages, in a tab of their own with
/// the project's own empty profile (never your sign-ins). Local addresses open there when the engine says they're the
/// project's (its commands' ports, or ones you allowed). A small script in the page keeps its console and its own
/// fetch/XMLHttpRequest calls for `browser_console` and `browser_requests`; `browser_eval` runs a script there.
struct BrowserPreview: Equatable {
    /// Names the project's profile (its folder).
    let profile: String
    /// Local addresses its pages may open ("localhost:5173").
    var local: Set<String>

    init?(_ value: JSONValue?) {
        guard let value, let profile = value["profile"]?.stringValue else { return nil }
        self.profile = profile
        local = Set(value["local"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    init(profile: String, local: Set<String>) {
        self.profile = profile
        self.local = local
    }

    /// "localhost:5173" for a local URL, nil for anything else.
    @MainActor static func target(_ url: URL?) -> String? {
        guard let url, let host = url.host(), BrowserTab.isLocal(host) else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        return "\(host == "0.0.0.0" ? "localhost" : host):\(port)"
    }

    /// A fixed profile id per project, so its cookies and storage last between launches.
    static func profileID(_ profile: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("piopio.preview:\(profile)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Kept in the page itself (so it runs before the page's own scripts): console, errors and its own requests.
    static let captureScript = #"""
(() => {
	if (window.__piopioPreview) return;
	const MAX = 300, log = [], reqs = [];
	const push = (list, entry) => { list.push(entry); if (list.length > MAX) list.shift(); };
	const show = (v) => {
		try {
			if (v instanceof Error) return v.stack || String(v);
			if (typeof v === "object" && v !== null) return JSON.stringify(v).slice(0, 2000);
			return String(v);
		} catch { return String(v); }
	};
	for (const level of ["log", "info", "warn", "error", "debug"]) {
		const original = console[level];
		console[level] = function (...args) {
			push(log, { level, text: args.map(show).join(" ").slice(0, 4000), at: Date.now() });
			return original.apply(this, args);
		};
	}
	addEventListener("error", (e) => push(log, { level: "error", text: (e.error && e.error.stack) || `${e.message} (${e.filename}:${e.lineno})`, at: Date.now() }));
	addEventListener("unhandledrejection", (e) => push(log, { level: "error", text: "Unhandled rejection: " + show(e.reason), at: Date.now() }));
	const originalFetch = window.fetch;
	window.fetch = async function (input, init) {
		const start = Date.now();
		const method = (init && init.method) || (input && input.method) || "GET";
		const url = String((input && input.url) || input);
		try {
			const r = await originalFetch.apply(this, arguments);
			push(reqs, { method, url, status: r.status, ms: Date.now() - start });
			return r;
		} catch (error) {
			push(reqs, { method, url, error: String(error), ms: Date.now() - start });
			throw error;
		}
	};
	const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
	XMLHttpRequest.prototype.open = function (method, url) { this.__piopio = { method, url: String(url) }; return open.apply(this, arguments); };
	XMLHttpRequest.prototype.send = function () {
		const p = this.__piopio || { method: "GET", url: "" }, start = Date.now();
		this.addEventListener("loadend", () => push(reqs, { method: p.method, url: p.url, status: this.status || undefined, error: this.status ? undefined : "network error", ms: Date.now() - start }));
		return send.apply(this, arguments);
	};
	Object.defineProperty(window, "__piopioPreview", { value: { log, reqs }, enumerable: false });
})();
"""#
}

extension BrowserCenter {
    /// A preview tab's configuration: the project's profile, the page map and the recorder.
    func previewConfiguration(_ preview: BrowserPreview) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = WKWebsiteDataStore(forIdentifier: BrowserPreview.profileID(preview.profile))
        c.applicationNameForUserAgent = "Version/27.0 Safari/605.1.15"
        c.userContentController.addUserScript(WKUserScript(source: BrowserScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        c.userContentController.addUserScript(WKUserScript(source: BrowserPreview.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        return c
    }
}

extension BrowserSession {
    /// The project's preview tab, made when first needed; its local addresses follow the engine's latest list.
    func previewTab(_ preview: BrowserPreview) -> BrowserTab {
        if let tab = tabs.first(where: { $0.preview?.profile == preview.profile }) {
            tab.preview = preview
            return tab
        }
        let tab = newTab(center.previewConfiguration(preview))
        tab.preview = preview
        return tab
    }

    /// Opens a local address in the project preview, from the app (the terminal drawer's address).
    func openPreview(_ url: URL, profile: String) {
        guard let target = BrowserPreview.target(url) else { return }
        var preview = tabs.first(where: { $0.preview?.profile == profile })?.preview ?? BrowserPreview(profile: profile, local: [])
        preview.local.insert(target)
        let tab = previewTab(preview)
        current = tab
        tab.view.load(URLRequest(url: url))
        center.reveal(id)
    }

    /// `browser_console`, `browser_requests` and `browser_eval`, on the preview tab showing a local page.
    func previewTool(_ name: String, _ a: JSONValue) async throws -> String {
        guard let tab = current, tab.preview != nil, BrowserPreview.target(tab.view.url) != nil else {
            throw BrowserError(message: "The project preview isn't open: start the dev server with bash `background: true` and browser_open the address it prints.")
        }
        switch name {
        case "browser_console":
            let level = a["level"]?.stringValue ?? "all"
            let r = try await tab.page("""
                const p = window.__piopioPreview; if (!p) return [];
                const out = p.log.filter((e) => level === "all" || e.level === level || (level === "warn" && e.level === "error"));
                if (clear) p.log.length = 0;
                return out;
                """, ["level": level, "clear": a["clear"] == .bool(true)])
            let entries = (r as? [[String: Any]]) ?? []
            if entries.isEmpty { return "\(tab.header)\nThe console is empty\(level == "all" ? "" : " at that level")." }
            return "\(tab.header)\n" + entries.suffix(150).map { "[\($0["level"] as? String ?? "log")] \($0["text"] as? String ?? "")" }.joined(separator: "\n")
        case "browser_requests":
            let r = try await tab.page("""
                const p = window.__piopioPreview; if (!p) return [];
                const out = p.reqs.filter((e) => (!failed || e.error || e.status >= 400) && (!filter || e.url.includes(filter)));
                if (clear) p.reqs.length = 0;
                return out;
                """, ["failed": a["failed"] == .bool(true), "filter": a["filter"]?.stringValue ?? "", "clear": a["clear"] == .bool(true)])
            let entries = (r as? [[String: Any]]) ?? []
            if entries.isEmpty { return "\(tab.header)\nNo requests\(a["failed"] == .bool(true) ? " failed" : " yet")." }
            return "\(tab.header)\n" + entries.suffix(150).map { e in
                let status = (e["status"] as? Int).map(String.init) ?? (e["error"] as? String ?? "?")
                return "\(e["method"] as? String ?? "GET") \(status) \(e["url"] as? String ?? "") (\(e["ms"] as? Int ?? 0) ms)"
            }.joined(separator: "\n")
        case "browser_eval":
            let script = a["script"]?.stringValue ?? ""
            let r = try await tab.page("const result = await (async () => {\n\(script)\n})();\nreturn JSON.stringify(result === undefined ? null : result);", [:])
            let text = (r as? String) ?? "null"
            return "\(tab.header)\n\(text.count > 20_000 ? String(text.prefix(20_000)) + "\n(cut at 20,000 characters)" : text)"
        default:
            throw BrowserError(message: "Unknown browser tool \(name).")
        }
    }
}

extension BrowserTab {
    /// Runs an async function body in the page's own world (where the recorder lives).
    func page(_ body: String, _ args: [String: Any]) async throws -> Any? {
        do {
            return try await view.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
        } catch {
            throw BrowserError(message: "The script failed: \(error.localizedDescription)")
        }
    }
}
