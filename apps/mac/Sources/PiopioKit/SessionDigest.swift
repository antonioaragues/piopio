import Foundation

/// What the Summary column sorts a conversation into: what it made (files it wrote, files it changed) and what it worked
/// from, Read (docs/design/read): the files you gave it, the files it opened, and the pages it read.
public enum SessionDigest {
    // MARK: Made

    /// Files you open and read rather than review as a diff: documents, PDFs, images, data. A new code or text file in
    /// the project is a change, not something it wrote.
    public static func isDocument(_ path: String) -> Bool { kind(of: path) != nil }

    /// "PDF", "Markdown", "Image"… for a document; nil for code and plain text.
    public static func kind(of path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        for (label, exts) in kinds where exts.contains(ext) { return label }
        return nil
    }

    private static let kinds: [(String, Set<String>)] = [
        ("PDF", ["pdf"]),
        ("Markdown", ["md", "markdown", "mdx"]),
        ("Document", ["docx", "doc", "rtf", "odt", "pages", "epub"]),
        ("Spreadsheet", ["xlsx", "xls", "ods", "numbers"]),
        ("Table", ["csv", "tsv"]),
        ("Slides", ["pptx", "ppt", "key", "odp"]),
        ("Image", ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "svg"]),
        ("Audio", ["mp3", "wav", "m4a", "aiff", "flac"]),
        ("Video", ["mp4", "mov", "m4v", "webm"]),
    ]

    /// New documents are what it wrote; everything else (code, text, edits, deletions) is what it changed.
    public static func split(_ files: [FileChange]) -> (wrote: [FileChange], changed: [FileChange]) {
        var wrote: [FileChange] = [], changed: [FileChange] = []
        for file in files {
            if file.status == .added && isDocument(file.path) { wrote.append(file) } else { changed.append(file) }
        }
        return (wrote, changed)
    }

    // MARK: Context

    public struct Inputs: Equatable, Sendable {
        /// Files sent with a message (images, text), latest copy of each name.
        public var attachments: [AttachmentInfo] = []
        /// Paths you @mentioned (typed, picked or dropped) that exist, relative to the project when inside it.
        public var mentions: [String] = []
        /// Files it read itself, relative to the project, first read first.
        public var read: [String] = []
        /// Files it wrote or edited with its own tools (not through commands), relative to the project.
        public var edited: [String] = []
        /// Pages it fetched (that loaded) and the sources its web searches returned (the search's summary is written from them), first
        /// seen first, at most `maxPages`.
        public var pages: [Page] = []
        public init() {}
    }

    public static let maxPages = 30

    /// A page it read: its address and its title (the address when it has none).
    public struct Page: Equatable, Hashable, Sendable {
        public let url: String
        public let title: String
        public init(url: String, title: String) { self.url = url; self.title = title }
        public var untitled: Bool { title == url }
        /// "jobs.ashbyhq.com", without www.
        public var host: String { URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url }
        /// The rest of the address after the site ("/acme/7c1e…"), for a page with no title.
        public var path: String {
            guard let parts = URLComponents(string: url) else { return "" }
            let rest = parts.path + (parts.query.map { "?\($0)" } ?? "")
            return rest == "/" ? "" : rest
        }
    }

    /// - Parameters:
    ///   - cwd: the session's folder; paths under it are shown relative to it.
    ///   - exists: whether a path (relative to `cwd`, or absolute) is a file or folder; mentions that aren't are prose.
    public static func inputs(items: [TimelineItem], cwd: String?, exists: (String) -> Bool) -> Inputs {
        var out = Inputs()
        var seenNames = Set<String>(), seenMentions = Set<String>(), seenRead = Set<String>(), seenEdited = Set<String>()
        var seenPages = Set<String>()
        func page(_ url: String?, _ title: String?) {
            guard let url, out.pages.count < maxPages, seenPages.insert(url).inserted else { return }
            out.pages.append(Page(url: url, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? url))
        }
        func tool(_ t: ToolItem) {
            switch t.tool {
            case "read":
                // A file it failed to read wasn't read.
                guard let raw = t.args["path"]?.stringValue, t.status != .denied, t.status != .error else { return }
                let path = relative(raw, cwd: cwd)
                if seenRead.insert(path).inserted { out.read.append(path) }
            case "edit", "write":
                guard t.status == .done, let raw = t.args["path"]?.stringValue else { return }
                let path = relative(raw, cwd: cwd)
                if seenEdited.insert(path).inserted { out.edited.append(path) }
            case "web_fetch":
                // A page that didn't load wasn't read. (The engine sends no details for web tools, so no titles or
                // search results: docs/spec/03 §4 plans "web" and "page" details.)
                guard t.status == .done else { return }
                page(t.args["url"]?.stringValue, nil)
            default: break
            }
        }
        for item in items {
            switch item {
            case .user(let u):
                for a in u.attachments ?? [] {
                    if seenNames.insert(a.name).inserted { out.attachments.append(a) }
                    else if a.stored != nil, let i = out.attachments.firstIndex(where: { $0.name == a.name }) { out.attachments[i] = a }
                }
                for path in mentions(in: u.text, cwd: cwd, exists: exists) where seenMentions.insert(path).inserted {
                    out.mentions.append(path)
                }
            case .tool(let t): tool(t)
            case .steps(let s): s.tools.forEach(tool)
            default: break
            }
        }
        return out
    }

    /// Paths you gave in a message: "@src/app.swift", "@docs/" (typed, picked or dropped; the composer writes them
    /// all with @). A file named in prose ("see README.md") isn't one. Mentions only count when they exist.
    static func mentions(in text: String, cwd: String?, exists: (String) -> Bool) -> [String] {
        var out: [String] = []
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            var word = String(token)
            while let first = word.first, "([{\"'`".contains(first) { word.removeFirst() }
            guard word.hasPrefix("@") else { continue }
            word.removeFirst()
            while let last = word.last, ",.;:!?)]}\"'`".contains(last) { word.removeLast() }
            guard !word.isEmpty, word != ".", word != "..", !word.contains("://") else { continue }
            let path = relative(word, cwd: cwd)
            if exists(path) { out.append(path) }
        }
        return out
    }

    /// "/Users/me/p/src/a.swift" → "src/a.swift" when the session works in /Users/me/p.
    static func relative(_ path: String, cwd: String?) -> String {
        var p = path
        if p.hasPrefix("./") { p.removeFirst(2) }
        if let cwd, p.hasPrefix(cwd + "/") { return String(p.dropFirst(cwd.count + 1)) }
        return p
    }
}
