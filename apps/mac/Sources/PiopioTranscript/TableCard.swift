import AppKit
import SwiftUI

// Tables in answers: Markdown tables, and tables a model drew with spaces inside a code block, become real tables
// (a header row, wrapped cells, hairlines between rows) instead of monospaced text that wraps into a mess. The
// layout is computed once per width (column widths from the content, row heights from the wrapped text) and both the
// view and the attachment's height use it, so the text around never overlaps.

/// A table's cells and how to lay them out at a width.
struct TableContent: Sendable {
    let header: [String]
    let rows: [[String]]

    // The header reads at the body's size, not smaller; it's set apart by its fill and weight.
    static var cellFont: NSFont { NSFont.systemFont(ofSize: DS.transcriptSize) }
    static var headerFont: NSFont { NSFont.systemFont(ofSize: DS.transcriptSize, weight: .semibold) }
    static var firstColumnFont: NSFont { NSFont.systemFont(ofSize: DS.transcriptSize, weight: .medium) }
    static let padH: CGFloat = 14
    static let padV: CGFloat = 9
    static let radius: CGFloat = DS.Radius.card
    /// Room kept at the end of the header's last cell for the Copy button, so it never covers a heading.
    static let copyRoom: CGFloat = 24

    /// A cell's padding at its trailing edge.
    func trailingPad(header: Bool, column c: Int) -> CGFloat {
        header && c == columns - 1 ? Self.padH + Self.copyRoom : Self.padH
    }

    var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    func cell(_ row: [String], _ c: Int) -> String { row.indices.contains(c) ? row[c] : "" }

    /// Column widths that fill `width`: each column's natural width when they fit, else shares of what's left after a
    /// minimum, in proportion to how much text each column holds.
    func widths(for width: CGFloat) -> [CGFloat] {
        let n = columns
        guard n > 0 else { return [] }
        let natural = (0..<n).map { c in
            ([header] + rows).enumerated().map { r, row in
                Self.textWidth(Self.plain(cell(row, c)), font: c == 0 ? Self.firstColumnFont : Self.cellFont) + Self.padH + trailingPad(header: r == 0, column: c)
            }.max() ?? 0
        }
        let total = natural.reduce(0, +)
        if total <= width { return natural.map { $0 * width / max(total, 1) } }
        let minimum = min(120, width / CGFloat(n))
        let floors = natural.map { min($0, minimum) }
        let extra = max(0, width - floors.reduce(0, +))
        let wants = zip(natural, floors).map { max(0, $0 - $1) }
        let wanted = max(wants.reduce(0, +), 1)
        return zip(floors, wants).map { $0 + extra * $1 / wanted }
    }

    /// Each row's height at these widths (the header first).
    func heights(widths: [CGFloat]) -> [CGFloat] {
        ([header] + rows).enumerated().map { r, row in
            let isHeader = r == 0
            let tallest = widths.indices.map { c in
                Self.textHeight(Self.plain(cell(row, c)), font: isHeader ? Self.headerFont : (c == 0 ? Self.firstColumnFont : Self.cellFont), width: widths[c] - Self.padH - trailingPad(header: isHeader, column: c))
            }.max() ?? 0
            return ceil(tallest) + 2 * Self.padV
        }
    }

    func height(width: CGFloat) -> CGFloat {
        heights(widths: widths(for: width)).reduce(0, +)
    }

    /// The cell's text without Markdown's emphasis marks (what's measured; the view renders the marks).
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
    }

    static func textWidth(_ s: String, font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    static func textHeight(_ s: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !s.isEmpty else { return font.ascender - font.descender }
        let rect = (s as NSString).boundingRect(with: NSSize(width: max(width, 10), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return rect.height + 2
    }

    /// A table drawn with spaces in a code block: three or more lines that all split into the same number (2–8) of
    /// cells at runs of two or more spaces (or tabs). Anything else stays code.
    static func spaced(_ code: String) -> TableContent? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 3 else { return nil }
        let split = lines.map { line in
            line.trimmingCharacters(in: .whitespaces).components(separatedBy: "\t").flatMap { $0.split(using: "  ") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let n = split[0].count
        guard (2...8).contains(n), split.allSatisfy({ $0.count == n }) else { return nil }
        // Box-drawing or dashed rules ("----  -----") are separators, not rows.
        let rows = split.dropFirst().filter { row in !row.allSatisfy { $0.allSatisfy { "-=─—_|+:".contains($0) } } }
        guard rows.count >= 2 else { return nil }
        return TableContent(header: split[0].map(plain), rows: Array(rows))
    }
}

// MARK: Copying

extension TableContent {
    private var allRows: [[String]] { [header] + rows }

    /// A row's cells as they read (no Markdown marks), tab-separated.
    func tsv(_ row: [String]) -> String {
        (0..<columns).map { CopyFormat.inline(cell(row, $0)).replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t")
    }

    /// One row a line, cells tab-separated: a spreadsheet splits it into cells, a text editor lines it up.
    var tsv: String { allRows.map(tsv).joined(separator: "\n") }

    /// The table as the model wrote it.
    var markdown: String {
        func line(_ row: [String]) -> String {
            "| " + (0..<columns).map { cell(row, $0).replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        return ([line(header), "|" + String(repeating: " --- |", count: columns)] + rows.map(line)).joined(separator: "\n")
    }

    /// A real table for Numbers, Excel, Notes, Mail and Pages.
    var html: String {
        func row(_ cells: [String], _ tag: String) -> String {
            "<tr>" + (0..<columns).map { "<\(tag)>\(Self.escape(CopyFormat.inline(cell(cells, $0))))</\(tag)>" }.joined() + "</tr>"
        }
        return "<table><thead>\(row(header, "th"))</thead><tbody>\(rows.map { row($0, "td") }.joined())</tbody></table>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// HTML for the pasteboard: the charset, or accented text reads as mojibake where it's pasted.
    static func htmlDocument(_ body: String) -> String {
        #"<html><head><meta charset="utf-8"></head><body>"# + body + "</body></html>"
    }

    /// Puts text on the pasteboard, with an HTML form beside it when there is one.
    @MainActor static func write(plain: String, html: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let html { pb.setString(html, forType: .html) }
        pb.setString(plain, forType: .string)
    }
}

private extension String {
    /// Splits at runs of `separator` or longer (two spaces: "a  b   c" → ["a", "b", "c"]).
    func split(using separator: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var spaces = 0
        for ch in self {
            if ch == " " {
                spaces += 1
                continue
            }
            if spaces >= separator.count, !current.isEmpty {
                parts.append(current)
                current = ""
            } else if spaces > 0 {
                current += String(repeating: " ", count: spaces)
            }
            spaces = 0
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

/// Whether the transcript's selection runs through a table, and the colour it's drawn in (nil when it doesn't).
@Observable final class TableSelection: @unchecked Sendable {
    var color: NSColor?
}

final class TableAttachment: NSTextAttachment, @unchecked Sendable {
    let table: TableContent
    let selection = TableSelection()

    init(table: TableContent) {
        self.table = table
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = TableViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class TableViewProvider: NSTextAttachmentViewProvider {
    private var table: TableContent { (textAttachment as! TableAttachment).table }

    override func loadView() {
        let table = self.table, selection = (textAttachment as! TableAttachment).selection
        view = MainActor.assumeIsolated {
            ClickThrough.install()
            return TableHostingView(rootView: TableCardView(table: table, selection: selection))
        }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = textContainer?.size.width ?? proposedLineFragment.width
        return CGRect(x: 0, y: -4, width: width, height: table.height(width: width))
    }
}

/// The table's host: its cells take their own drags (each one's text can be selected), and the pointer is the text
/// view's I-beam, not the arrow other cards show.
final class TableHostingView<Content: View>: NSHostingView<Content>, ClickThroughArea {}

/// The table, at whatever width the text gives it.
struct TableCardView: View {
    let table: TableContent
    var selection = TableSelection()
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let widths = table.widths(for: geo.size.width)
            let heights = table.heights(widths: widths)
            let shape = RoundedRectangle(cornerRadius: TableContent.radius, style: .continuous)
            // The header's fill runs to the border and into the first row, with no rule under it; hairlines only
            // between the rows below (each takes its point from the row it sits on).
            ZStack(alignment: .topLeading) {
                Color(nsColor: DS.card)
                // Rounded at the top with the card, square where it meets the first row.
                UnevenRoundedRectangle(topLeadingRadius: TableContent.radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: TableContent.radius, style: .continuous)
                    .fill(Color(nsColor: DS.bubble))
                    .frame(width: geo.size.width, height: heights[0])
                VStack(alignment: .leading, spacing: 0) {
                    row(table.header, widths: widths, height: heights[0], header: true)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { r, cells in
                        if r > 0 { Rectangle().fill(Color(nsColor: DS.line)).frame(height: 1) }
                        row(cells, widths: widths, height: heights[r + 1] - (r > 0 ? 1 : 0), header: false)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipShape(shape)
            // Inside a selection of the transcript: tinted like the text around it, so it shows it goes with a copy.
            .overlay { if let color = selection.color { shape.fill(Color(nsColor: color).opacity(0.55)).allowsHitTesting(false) } }
            .overlay(shape.strokeBorder(Color(nsColor: DS.line), lineWidth: 1))
            // Copy, at the header's end: shown while the pointer is over the table.
            .overlay(alignment: .topTrailing) {
                TableCopyButton(table: table)
                    .frame(height: heights[0])
                    .padding(.trailing, 6)
                    .opacity(hovering ? 1 : 0)
            }
            .onHover { hovering = $0 }
        }
    }

    private func row(_ cells: [String], widths: [CGFloat], height: CGFloat, header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(widths.indices, id: \.self) { c in
                Text(Self.inline(table.cell(cells, c)))
                    .font(Font(header ? TableContent.headerFont : c == 0 ? TableContent.firstColumnFont : TableContent.cellFont))
                    .foregroundStyle(Color(nsColor: DS.fg))
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, TableContent.padH)
                    .padding(.trailing, table.trailingPad(header: header, column: c))
                    .padding(.vertical, TableContent.padV)
                    .frame(width: widths[c], height: height, alignment: .topLeading)
                    .textSelection(.enabled)
                    .contentShape(Rectangle())
                    .contextMenu { menu(cells, c) }
            }
        }
        .background(Color.clear)
    }

    /// Right-click on a cell: it, its row, or the whole table.
    @ViewBuilder private func menu(_ cells: [String], _ c: Int) -> some View {
        Button("Copy Cell") { TableContent.write(plain: CopyFormat.inline(table.cell(cells, c)), html: nil) }
        Button("Copy Row") { TableContent.write(plain: table.tsv(cells), html: nil) }
        Divider()
        Button("Copy Table") { TableContent.write(plain: table.tsv, html: TableContent.htmlDocument(table.html)) }
        Button("Copy Table as Markdown") { TableContent.write(plain: table.markdown, html: nil) }
    }

    /// **bold**, *italic* and `code` inside a cell.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// The table's Copy button: its cells tab-separated (a spreadsheet splits them) with an HTML table beside them (Notes,
/// Mail, Pages). A check mark for a moment after.
struct TableCopyButton: View {
    let table: TableContent
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            TableContent.write(plain: table.tsv, html: TableContent.htmlDocument(table.html))
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11.5))
                .foregroundStyle(Color(nsColor: hovering ? DS.fg2 : DS.fg3))
                .frame(width: 22, height: 22)
                .background(hovering ? Color(nsColor: DS.chip) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(copied ? "Copied" : "Copy table")
        .accessibilityLabel("Copy table")
    }
}
