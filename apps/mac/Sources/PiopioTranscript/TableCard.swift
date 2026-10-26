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

    static var cellFont: NSFont { NSFont.systemFont(ofSize: 13) }
    static var headerFont: NSFont { NSFont.systemFont(ofSize: 12, weight: .semibold) }
    static var firstColumnFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .medium) }
    static let padH: CGFloat = 12
    static let padV: CGFloat = 8

    var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    func cell(_ row: [String], _ c: Int) -> String { row.indices.contains(c) ? row[c] : "" }

    /// Column widths that fill `width`: each column's natural width when they fit, else shares of what's left after a
    /// minimum, in proportion to how much text each column holds.
    func widths(for width: CGFloat) -> [CGFloat] {
        let n = columns
        guard n > 0 else { return [] }
        let natural = (0..<n).map { c in
            ([header] + rows).map { row in Self.textWidth(Self.plain(cell(row, c)), font: c == 0 ? Self.firstColumnFont : Self.cellFont) }.max() ?? 0
        }.map { $0 + 2 * Self.padH }
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
                Self.textHeight(Self.plain(cell(row, c)), font: isHeader ? Self.headerFont : (c == 0 ? Self.firstColumnFont : Self.cellFont), width: widths[c] - 2 * Self.padH)
            }.max() ?? 0
            return ceil(tallest) + 2 * Self.padV
        }
    }

    func height(width: CGFloat) -> CGFloat {
        heights(widths: widths(for: width)).reduce(0, +) + 2
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

final class TableAttachment: NSTextAttachment, @unchecked Sendable {
    let table: TableContent

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
        let table = self.table
        view = MainActor.assumeIsolated { NSHostingView(rootView: TableCardView(table: table)) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = textContainer?.size.width ?? proposedLineFragment.width
        return CGRect(x: 0, y: -4, width: width, height: table.height(width: width))
    }
}

/// The table, at whatever width the text gives it.
struct TableCardView: View {
    let table: TableContent

    var body: some View {
        GeometryReader { geo in
            let widths = table.widths(for: geo.size.width)
            let heights = table.heights(widths: widths)
            VStack(alignment: .leading, spacing: 0) {
                row(table.header, widths: widths, height: heights[0], header: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { r, cells in
                    Rectangle().fill(Color(nsColor: DS.line)).frame(height: 0.5)
                    row(cells, widths: widths, height: heights[r + 1] - 0.5, header: false)
                }
            }
            .background(Color(nsColor: DS.card), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: DS.line), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func row(_ cells: [String], widths: [CGFloat], height: CGFloat, header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(widths.indices, id: \.self) { c in
                Text(Self.inline(table.cell(cells, c)))
                    .font(Font(header ? TableContent.headerFont : c == 0 ? TableContent.firstColumnFont : TableContent.cellFont))
                    .foregroundStyle(Color(nsColor: header ? DS.fg2 : DS.fg))
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, TableContent.padH)
                    .padding(.vertical, TableContent.padV)
                    .frame(width: widths[c], height: height, alignment: .topLeading)
                    .textSelection(.enabled)
            }
        }
        .background(header ? Color(nsColor: DS.chip) : .clear)
    }

    /// **bold**, *italic* and `code` inside a cell.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
