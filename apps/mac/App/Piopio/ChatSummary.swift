import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// A chat's Summary column, made of Build's blocks (docs/design/chat-summary, option B): **Tools** (web search, apps
/// and MCP servers, a switch each for this chat), **Skills**, and **Read** (the files you gave it and the pages it
/// opened or found), open by default because it's what a chat has to show. Context and cost are in the footer every
/// panel shares. The model is in the composer; what it's doing now is in the transcript.
struct ChatSummaryPanel: View {
    let engine: EngineController
    let thread: ThreadModel
    let summary: SessionSummary

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ToolsBlock(engine: engine, thread: thread, summary: summary, web: true).inspectorBlock()
                    SkillsBlock(thread: thread).inspectorBlock()
                    ChatReadBlock(thread: thread).inspectorBlock(last: true)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }
            InspectorFooter(thread: thread)
        }
    }
}

/// Read: "4 pages · 1 file ›". Open (remembered for every chat), the files you gave it, then each page: its title, or
/// its site when it has none, with the site or the rest of the address in grey below. Five, then "and N more".
struct ChatReadBlock: View {
    let thread: ThreadModel
    @AppStorage("chatReadOpen") private var open = true
    @State private var all = false

    private static let shortList = 5

    var body: some View {
        // The document isn't observed: reading `revision` refreshes this block on every event batch.
        let _ = thread.revision
        let found = ChatResults(items: thread.document.items)
        VStack(alignment: .leading, spacing: 0) {
            if found.files.isEmpty && found.pages.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Read").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("Nothing yet").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                }
            } else {
                BlockFold(title: "Read", line: Self.line(found), open: $open,
                          help: open ? "Hide what it read" : "The files you gave it and the pages it read")
                if open { list(found).padding(.top, 10) }
            }
        }
    }

    private func list(_ found: ChatResults) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !found.files.isEmpty {
                BlockSubheading("You gave")
                ForEach(found.files, id: \.name) { file in
                    ReadRow(icon: "paperclip", title: file.name, detail: nil, trailing: Self.kind(file),
                            help: file.stored == nil ? "Sent before Piopio kept copies of files" : "Open \(file.name)") {
                        if let stored = file.stored { thread.handle(.openAttachment(stored: stored)) }
                    }
                    .disabled(file.stored == nil)
                }
                if !found.pages.isEmpty { BlockSubheading("Pages") }
            }
            ForEach(all ? found.pages : Array(found.pages.prefix(Self.shortList)), id: \.url) { page in
                let untitled = page.title == page.url
                ReadRow(icon: "doc", title: untitled ? page.host : page.title, detail: untitled ? page.path : page.host,
                        trailing: nil, help: page.url) {
                    if let url = URL(string: page.url) { NSWorkspace.shared.open(url) }
                }
            }
            if found.pages.count > Self.shortList {
                SummaryLink(all ? "Show fewer" : "and \(found.pages.count - Self.shortList) more") {
                    withAnimation(.easeOut(duration: 0.15)) { all.toggle() }
                }
                .padding(.top, 6)
            }
        }
    }

    /// "4 pages · 1 file".
    static func line(_ found: ChatResults) -> String {
        var parts: [String] = []
        if !found.pages.isEmpty { parts.append(found.pages.count == 1 ? "1 page" : "\(found.pages.count) pages") }
        if !found.files.isEmpty { parts.append(found.files.count == 1 ? "1 file" : "\(found.files.count) files") }
        return parts.joined(separator: " · ")
    }

    /// "PDF", "Image", "File".
    static func kind(_ file: AttachmentInfo) -> String {
        if file.kind == .image { return "Image" }
        let ext = (file.name as NSString).pathExtension
        return ext.isEmpty || ext.count > 4 ? "File" : ext.uppercased()
    }
}

/// A row of Read: an icon, the name with a grey line below, and what it is on the right (↗ on hover for pages).
private struct ReadRow: View {
    let icon: String
    let title: String
    let detail: String?
    let trailing: String?
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                } else {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dsFg3)
                        .opacity(hovering ? 1 : 0)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.05) : .clear))
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// What a chat produced and used: the files you attached, and the pages it opened or found while searching.
struct ChatResults {
    struct Page: Hashable {
        let url: String
        let title: String
        /// "jobs.ashbyhq.com", without www.
        var host: String { URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url }
        /// The rest of the address after the site ("/acme/7c1e…"), for a page with no title.
        var path: String {
            guard let parts = URLComponents(string: url) else { return "" }
            let rest = parts.path + (parts.query.map { "?\($0)" } ?? "")
            return rest == "/" ? "" : rest
        }
    }
    var files: [AttachmentInfo] = []
    var pages: [Page] = []

    init(items: [TimelineItem]) {
        var seenFiles = Set<String>(), seenPages = Set<String>()
        func add(_ tool: ToolItem) {
            switch tool.tool {
            case "web_fetch":
                let url = tool.details?["url"]?.stringValue ?? tool.args?["url"]?.stringValue
                if let url, seenPages.insert(url).inserted { pages.append(Page(url: url, title: tool.details?["title"]?.stringValue ?? url)) }
            case "web_search":
                for result in tool.details?["results"]?.arrayValue ?? [] {
                    guard let url = result["url"]?.stringValue, seenPages.insert(url).inserted else { continue }
                    pages.append(Page(url: url, title: result["title"]?.stringValue ?? url))
                }
            default: break
            }
        }
        for item in items {
            switch item {
            case .user(let u):
                // The latest copy of a file sent more than once.
                for a in u.attachments ?? [] {
                    if seenFiles.insert(a.name).inserted { files.append(a) } else if let i = files.firstIndex(where: { $0.name == a.name }), a.stored != nil { files[i] = a }
                }
            case .tool(let t): add(t)
            case .steps(let s): s.tools.forEach(add)
            default: break
            }
        }
        pages = Array(pages.prefix(30))
    }
}
