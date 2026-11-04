import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// A chat's Summary column (docs/design/session-panel, step 4): the model and context, web search, connectors and MCP
/// for this conversation, then its results (the files you shared and the pages it read), and what it cost.
struct ChatSummaryPanel: View {
    let engine: EngineController
    let thread: ThreadModel
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    model
                    tools
                    results
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
            Rectangle().fill(Color.dsLine).frame(height: 0.5)
            HStack {
                Text("This chat").font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                Spacer()
                let cost = thread.state?.usage.costUsd ?? 0
                Text(cost > 0 && cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)).font(.system(size: 12).monospacedDigit())
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: Model and context

    private var model: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Model").padding(.bottom, 2)
            HStack(spacing: 9) {
                Image(systemName: "cpu").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).frame(width: 18)
                Text(engine.model(summary.model).map(ModelChip.short) ?? summary.model?.id ?? "Default model").font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 26)
            if let context = thread.state?.context {
                let fraction = min(1, (context.tokens ?? 0) / max(1, context.window))
                HStack(spacing: 8) {
                    Text("Context").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                    Spacer()
                    Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.dsFg2)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.dsLine)
                        Capsule().fill(Color.dsFg2).frame(width: max(3, 46 * fraction))
                    }
                    .frame(width: 46, height: 4)
                }
                .padding(.leading, 27)
            }
        }
    }

    // MARK: Tools

    private var tools: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "globe").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).frame(width: 18)
                Text("Web search").font(.system(size: 13))
                Spacer()
                Toggle("", isOn: Binding(get: { thread.webEnabled }, set: { on in Task { await thread.setWeb(on) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityLabel("Web search in this chat")
            }
            .frame(minHeight: 26)
            ToolChoicesSection(engine: engine, thread: thread, summary: summary)
        }
    }

    // MARK: Results

    private var results: some View {
        let found = ChatResults(items: thread.document.items)
        return VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Results").padding(.bottom, 4)
            if found.files.isEmpty && found.pages.isEmpty {
                Text("Files you share and pages it reads show up here.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(found.files, id: \.name) { file in
                Button {
                    if let stored = file.stored { thread.handle(.openAttachment(stored: stored)) }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "paperclip").font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 18)
                        Text(file.name).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("shared").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                    }
                    .frame(minHeight: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(file.stored == nil)
                .help(file.stored == nil ? "Sent before Piopio kept copies of files" : "Open \(file.name)")
            }
            ForEach(found.pages, id: \.url) { page in
                Button { if let url = URL(string: page.url) { NSWorkspace.shared.open(url) } } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "link").font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 18)
                        Text(page.title).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(page.host).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
                    }
                    .frame(minHeight: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(page.url)
            }
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
