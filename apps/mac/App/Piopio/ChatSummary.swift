import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// A chat's Summary column (docs/design/summary/ia.html), the same groups as Build's in style A (SummaryCard.swift):
/// **Now** (while it answers or waits on you), **Context** (how full; You gave · Read), **Setup** (Uses: the web,
/// apps and MCP servers, a switch each for this chat; Knows: skills), and the cost. Chats keep no plan and write no
/// files, so they have no Plan or Made. The model is in the composer.
struct ChatSummaryPanel: View {
    let engine: EngineController
    let thread: ThreadModel
    let summary: SessionSummary
    @State private var allPages = false

    private static let shortList = 5

    var body: some View {
        let found = ChatResults(items: thread.document.items)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    now
                    contextGroup(found)
                    VStack(alignment: .leading, spacing: 9) {
                        GroupHeader("Setup") { EmptyView() }
                        UsesRow(engine: engine, thread: thread, summary: summary, web: true)
                        SkillsRow(thread: thread)
                    }
                    .padding(.vertical, 14)
                }
                .padding(.horizontal, 16)
            }
            // Context and cost live in the footer every panel shares (docs/design/inspector §4).
            InspectorFooter(thread: thread)
        }
    }

    // MARK: Now

    @ViewBuilder private var now: some View {
        let status = thread.state?.status
        if status == .running || status == .waitingApproval {
            NowGroup(waiting: status == .waitingApproval, title: Self.activity(thread.document.items),
                     detail: status == .waitingApproval ? "It's asking in the conversation" : nil)
        }
    }

    /// What the running turn is doing: searching, reading a page, using an app, or answering.
    static func activity(_ items: [TimelineItem]) -> String {
        for item in items.reversed() {
            let tools: [ToolItem]
            switch item {
            case .tool(let t): tools = [t]
            case .steps(let s): tools = s.tools
            case .user: return "Answering"
            default: continue
            }
            guard let running = tools.last(where: { $0.status == .running }) else { continue }
            return switch running.tool {
            case "web_search": "Searching the web"
            case "web_fetch": "Reading a page"
            default: "Using \(running.tool.replacingOccurrences(of: "_", with: " "))"
            }
        }
        return "Answering"
    }

    // MARK: Context

    @ViewBuilder private func contextGroup(_ found: ChatResults) -> some View {
        if !found.files.isEmpty || !found.pages.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                GroupHeader("Context") { EmptyView() }
                if !found.files.isEmpty {
                    CardRow("You gave") {
                        ForEach(found.files, id: \.name) { file in
                            ItemButton(title: file.name, help: file.stored == nil ? "Sent before Piopio kept copies of files" : "Open \(file.name)") {
                                if let stored = file.stored { thread.handle(.openAttachment(stored: stored)) }
                            } trailing: {
                                Text(file.kind == .image ? "image" : "file").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                            }
                            .disabled(file.stored == nil)
                        }
                    }
                }
                if !found.pages.isEmpty {
                    CardRow("Read") {
                        ForEach(allPages ? found.pages : Array(found.pages.prefix(Self.shortList)), id: \.url) { page in
                            // A page without a title reads as its address, without the scheme.
                            let untitled = page.title == page.url
                            let address = page.url.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
                            ItemButton(title: untitled ? address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : page.title, help: page.url) {
                                if let url = URL(string: page.url) { NSWorkspace.shared.open(url) }
                            } trailing: {
                                if !untitled { Text(page.host).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1) }
                            }
                        }
                        if found.pages.count > Self.shortList {
                            SummaryLink(allPages ? "Show fewer" : "and \(found.pages.count - Self.shortList) more") {
                                withAnimation(.easeOut(duration: 0.15)) { allPages.toggle() }
                            }
                        }
                    }
                }
            }
            .summaryGroup()
        }
    }
}

/// What a chat produced and used: the files you attached, and the pages it opened or found while searching.
struct ChatResults {
    struct Page: Hashable { let url: String; let title: String; var host: String { URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? "" } }
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
