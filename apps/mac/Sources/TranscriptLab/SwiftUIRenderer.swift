import AppKit
import Observation
import PiopioKit
import PiopioTranscript
import SwiftUI

// Candidate A: SwiftUI ScrollView + LazyVStack, one view per timeline item, one view per markdown block.
// Blocks are rendered to AttributedStrings once (when the message is built); the streaming message
// re-renders only its open tail block. Views only lay out prepared text.

/// A markdown block with its inline markup already resolved.
enum RenderedBlock: Equatable {
    struct Item: Equatable { var marker: String; var indent: Int; var text: AttributedString }
    case heading(level: Int, AttributedString)
    case paragraph(AttributedString)
    case quote(AttributedString)
    case list([Item])
    case code(language: String?, AttributedString)
    case table(header: [AttributedString], rows: [[AttributedString]])
    case rule

    init(_ block: MarkdownBlock) {
        switch block {
        case .heading(let level, let text): self = .heading(level: level, Inline.attributed(text))
        case .paragraph(let text): self = .paragraph(Inline.attributed(text))
        case .quote(let text): self = .quote(Inline.attributed(text))
        case .list(let items):
            self = .list(items.enumerated().map { i, item in
                Item(marker: item.task.map { $0 ? "☑︎" : "☐" } ?? (item.ordered ? "\(item.number ?? i + 1)." : "•"), indent: item.indent, text: Inline.attributed(item.text))
            })
        case .code(let language, let code, _): self = .code(language: language, Self.highlight(code))
        case .table(let header, _, let rows): self = .table(header: header.map(Inline.attributed), rows: rows.map { $0.map(Inline.attributed) })
        case .rule: self = .rule
        }
    }

    static func highlight(_ code: String) -> AttributedString {
        var a = AttributedString(code)
        for (range, token) in Highlighter.tokens(code) {
            guard let r = Range(range, in: code), let ar = Range(r, in: a) else { continue }
            a[ar].foregroundColor = Color(nsColor: Highlighter.color(token))
        }
        return a
    }
}

@MainActor @Observable
final class MessageModel: Identifiable {
    let id: String
    let role: Role
    var expanded = false   // tool cards (kept here: @State needs Xcode's SwiftUI macro plugin)
    private(set) var blocks: [RenderedBlock]
    @ObservationIgnored private var stream: MarkdownStream?
    @ObservationIgnored private var renderedClosed = 0

    enum Role { case user, assistant, tool(name: String, output: String), system }

    init(id: String, role: Role, text: String, streaming: Bool = false) {
        self.id = id
        self.role = role
        if streaming {
            stream = MarkdownStream()
            blocks = []
        } else {
            blocks = MarkdownStream(text: text).blocks.map(RenderedBlock.init)
        }
    }

    func append(_ delta: String) {
        guard var s = stream else { return }
        s.append(delta)
        stream = s
        publish(s)
    }

    func finish() {
        guard var s = stream else { return }
        s.finish()
        publish(s)
        stream = nil
    }

    /// Renders newly closed blocks once, and the open tail block again.
    private func publish(_ s: MarkdownStream) {
        var next = Array(blocks.prefix(renderedClosed))
        next += s.closed[renderedClosed...].map(RenderedBlock.init)
        renderedClosed = s.closed.count
        if let open = s.open { next.append(RenderedBlock(open)) }
        blocks = next
    }
}

@MainActor @Observable
final class TranscriptModel {
    var messages: [MessageModel] = []
}

struct TranscriptView: View {
    let model: TranscriptModel
    let useList: Bool

    var body: some View {
        if useList {
            // List is backed by NSTableView on macOS (cell reuse, AppKit scrolling).
            List(model.messages) { message in
                MessageView(message: message)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .defaultScrollAnchor(.bottom)
        } else {
            stack
        }
    }

    private var stack: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.messages) { message in
                    MessageView(message: message)
                }
            }
            .padding(20)
        }
        .defaultScrollAnchor(.bottom)
    }
}

struct MessageView: View {
    let message: MessageModel

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .leading, spacing: 6) { blocks }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) { blocks }
        case .tool(let name, let output):
            ToolCardView(message: message, name: name, output: output)
        case .system:
            VStack(alignment: .leading) { blocks }.foregroundStyle(.secondary)
        }
    }

    private var blocks: some View {
        ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
            BlockView(block: block).equatable()
        }
    }
}

struct ToolCardView: View {
    let message: MessageModel
    let name: String
    let output: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { message.expanded.toggle() } label: {
                Label("\(name) · done", systemImage: "gearshape").font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if message.expanded {
                Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}

struct BlockView: View, Equatable {
    let block: RenderedBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text).font(level <= 2 ? .title2.bold() : .headline)
        case .paragraph(let text):
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(.tertiary).frame(width: 3)
                Text(text).foregroundStyle(.secondary)
            }
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).foregroundStyle(.secondary)
                        Text(item.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 8)
                }
            }
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language { Text(language).font(.caption).foregroundStyle(.secondary) }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, h in Text(h).bold() } }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, c in Text(c) } }
                }
            }
            .padding(10)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }
}

@MainActor
final class SwiftUIRenderer: LabRenderer {
    let name: String
    private let model = TranscriptModel()
    private let useList: Bool
    private(set) lazy var view: NSView = NSHostingView(rootView: TranscriptView(model: model, useList: useList))

    init(list: Bool = false) {
        useList = list
        name = list ? "swiftui-list" : "swiftui"
    }
    private var streaming: MessageModel?
    private var counter = 0

    func load(_ items: [TimelineItem]) {
        model.messages = items.map(Self.message(for:))
    }

    func beginStreaming() {
        counter += 1
        let m = MessageModel(id: "stream\(counter)", role: .assistant, text: "", streaming: true)
        streaming = m
        model.messages.append(m)
    }

    func append(_ delta: String) { streaming?.append(delta) }

    func finishStreaming() {
        streaming?.finish()
        streaming = nil
    }

    func scrollView() -> NSScrollView? { view.firstDescendant(of: NSScrollView.self) }

    static func message(for item: TimelineItem) -> MessageModel {
        switch item {
        case .user(let u): MessageModel(id: u.id, role: .user, text: u.text)
        case .assistant(let a): MessageModel(id: a.id, role: .assistant, text: a.text)
        case .tool(let t): MessageModel(id: t.id, role: .tool(name: t.tool, output: t.output ?? ""), text: "")
        case .system(let s): MessageModel(id: s.id, role: .system, text: s.text)
        case .compaction(let c): MessageModel(id: c.id, role: .system, text: c.summary)
        case .checkpoint(let c): MessageModel(id: c.id, role: .system, text: c.label)
        case .routing(let r): MessageModel(id: r.id, role: .system, text: r.topicTitle)
        case .memory(let m): MessageModel(id: m.id, role: .system, text: m.added.joined(separator: ", "))
        case .steps(let s): MessageModel(id: s.id, role: .system, text: "\(s.tools.count) steps")
        }
    }
}
