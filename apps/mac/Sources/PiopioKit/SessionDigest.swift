import Foundation

/// What Build's Summary column sorts a session into (docs/design/summary/ia.html): what it made (files it wrote, files
/// it changed) and what it worked from (files you gave it, files it read, commands it ran).
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
        /// Commands it ran (denied ones and those waiting for you don't count).
        public var commands = 0
        public init() {}
    }

    /// - Parameters:
    ///   - cwd: the session's folder; paths under it are shown relative to it.
    ///   - exists: whether a path (relative to `cwd`, or absolute) is a file or folder; mentions that aren't are prose.
    public static func inputs(items: [TimelineItem], cwd: String?, exists: (String) -> Bool) -> Inputs {
        var out = Inputs()
        var seenNames = Set<String>(), seenMentions = Set<String>(), seenRead = Set<String>()
        func tool(_ t: ToolItem) {
            switch t.tool {
            case "read":
                guard let raw = t.args?["path"]?.stringValue, t.status != .denied else { return }
                let path = relative(raw, cwd: cwd)
                if seenRead.insert(path).inserted { out.read.append(path) }
            case "bash":
                if t.status != .denied && t.status != .pendingApproval { out.commands += 1 }
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
