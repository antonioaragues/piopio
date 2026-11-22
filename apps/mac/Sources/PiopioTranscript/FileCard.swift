import AppKit
import PiopioKit
import SwiftUI

// A file the agent handed over (piopio-present): a card with the file's type, its name and what it is, that opens it in
// the viewer. One per file, stacked; a missing file says so and doesn't open.

/// The card's file and somewhere to send "open" (the document wires it, as it does disclosure cards).
public final class FileCardModel: @unchecked Sendable {
    let file: PresentedFile
    /// The path as the conversation shows it (relative to the project).
    let shownPath: String
    var onAction: (@MainActor (TranscriptAction) -> Void)?

    init(file: PresentedFile, shownPath: String) {
        self.file = file
        self.shownPath = shownPath
    }

    static let height: CGFloat = 58
    static let maxWidth: CGFloat = 460

    /// "Markdown · 4 KB", "PDF", "Folder"…
    var kindLine: String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        let kind = Self.kinds[ext] ?? (ext.isEmpty ? "File" : ext.uppercased())
        let size = file.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [kind, size].compactMap { $0 }.joined(separator: " · ")
    }

    var symbol: String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "txt", "rtf": return "doc.text"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return "photo"
        case "csv", "tsv", "xlsx", "numbers": return "tablecells"
        case "html", "htm": return "globe"
        case "json", "yaml", "yml", "toml", "xml": return "curlybraces"
        case "zip", "gz", "tar": return "archivebox"
        case "": return "doc"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private static let kinds = [
        "md": "Markdown", "markdown": "Markdown", "txt": "Text", "rtf": "Rich text", "pdf": "PDF", "html": "HTML", "htm": "HTML",
        "png": "PNG image", "jpg": "JPEG image", "jpeg": "JPEG image", "gif": "GIF", "svg": "SVG", "webp": "WebP image", "heic": "HEIC image",
        "csv": "CSV", "tsv": "TSV", "xlsx": "Excel", "json": "JSON", "yaml": "YAML", "yml": "YAML", "ts": "TypeScript",
        "js": "JavaScript", "swift": "Swift", "py": "Python", "sh": "Shell script", "zip": "ZIP archive",
    ]
}

final class FileCardAttachment: NSTextAttachment, @unchecked Sendable {
    let model: FileCardModel

    init(model: FileCardModel) {
        self.model = model
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewProvider(for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = FileCardViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class FileCardViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let model = (textAttachment as! FileCardAttachment).model
        view = MainActor.assumeIsolated { ArrowHostingView(rootView: FileCardView(model: model)) }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = min(FileCardModel.maxWidth, textContainer?.size.width ?? proposedLineFragment.width)
        return CGRect(x: 0, y: -6, width: width, height: FileCardModel.height)
    }
}

struct FileCardView: View {
    let model: FileCardModel
    @State private var hovering = false

    private var file: PresentedFile { model.file }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: model.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color(nsColor: DS.fg2))
                    .frame(width: 36, height: 36)
                    .background(Color(nsColor: DS.chip), in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Color(nsColor: DS.fg))
                        .lineLimit(1).truncationMode(.middle)
                    Text(file.missing ? "Not found at \(model.shownPath)" : file.description ?? model.kindLine)
                        .font(.system(size: 12)).foregroundStyle(Color(nsColor: DS.fg2)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !file.missing {
                    Text(file.description == nil ? "Open" : model.kindLine)
                        .font(.system(size: 11.5)).foregroundStyle(Color(nsColor: DS.fg3)).lineLimit(1).fixedSize()
                    // Room for the Save button drawn over the card.
                    Color.clear.frame(width: 26, height: 26)
                }
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: hovering && !file.missing ? DS.bubble : DS.card), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color(nsColor: DS.line), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(file.missing)
        .opacity(file.missing ? 0.6 : 1)
        .onHover { hovering = $0 }
        .help(file.missing ? "Not found: \(model.shownPath)" : "Open \(model.shownPath)")
        .accessibilityLabel(file.missing ? "\(file.name), not found" : "Open \(file.name), \(model.kindLine)")
        .overlay(alignment: .trailing) {
            if !file.missing {
                Button { FileSaving.saveCopy(of: url) } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color(nsColor: DS.fg2))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 11)
                .help("Save a copy…")
                .accessibilityLabel("Save a copy of \(file.name)")
            }
        }
        // Drag it to Finder, Mail or another app, as a downloaded file.
        .onDrag { file.missing ? NSItemProvider() : (NSItemProvider(contentsOf: url) ?? NSItemProvider()) }
        .contextMenu {
            if !file.missing {
                Button("Open") { open() }
                Button("Open in Default App") { NSWorkspace.shared.open(url) }
                Button("Save a Copy…") { FileSaving.saveCopy(of: url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button(LibraryMembership.contains(file.path) ? "Show in Library" : "Add to Library") { NotificationCenter.default.post(name: .showInLibrary, object: file.path) }
            }
        }
    }

    private var url: URL { URL(fileURLWithPath: file.path) }

    private func open() {
        guard !file.missing else { return }
        MainActor.assumeIsolated { model.onAction?(.openFile(path: file.path, line: nil)) }
    }
}

/// Whether a file is in the Library (docs/spec/35 §4.2), as the app knows it: "Show in Library" when it is, "Add to
/// Library" when the action adds it.
@MainActor public enum LibraryMembership {
    public static var contains: (String) -> Bool = { _ in false }
}

extension Notification.Name {
    /// Show a file (its path is the object) in the Library (docs/spec/35 §4.2): listed if it wasn't, then selected.
    public static let showInLibrary = Notification.Name("piopio.showInLibrary")
    /// Save… on a visual's card wrote it to a file (`userInfo`: "callId", "path").
    public static let visualSaved = Notification.Name("piopio.visualSaved")
}

/// "Save a copy…" for a file Piopio holds (one an agent or a chat made): a save panel in Downloads, then a copy there.
public enum FileSaving {
    @MainActor public static func saveCopy(of url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url, target.standardizedFileURL != url.standardizedFileURL else { return }
        do {
            // The panel already asked whether to replace a file that's there.
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
