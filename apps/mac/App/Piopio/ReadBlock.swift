import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// Read (docs/design/read, option A): what the answer is based on, the same block in a chat's column and a project's.
/// Folded: "2 you gave · 9 files · 4 pages". Open (remembered for every conversation), one list with a subheading per
/// source: **You gave** (attachments, then the paths you @mentioned), **Files** (what it opened with its read tool;
/// projects only), **Pages** (what it fetched, and what its searches found). Six of each, then "and N more". A click
/// opens the thing itself; only "Show in Files ›", at the end in a project, goes to another panel.
/// Commands aren't here: they're actions, not sources (the timeline, and Background while they run).
struct ReadBlock: View {
    let thread: ThreadModel
    /// The project's folder; nil in a chat, which has no Files.
    let cwd: String?
    /// A file of the project, in the preview beside the conversation (a path relative to `cwd`).
    var openFile: ((String) -> Void)? = nil
    /// The Files panel on what it touched.
    var showInFiles: (() -> Void)? = nil
    @AppStorage("readOpen") private var open = true
    @State private var all: Set<String> = []

    private static let shortList = 6

    var body: some View {
        // The document isn't observed: reading `revision` refreshes this block on every event batch.
        let _ = thread.revision
        let found = SessionDigest.inputs(items: thread.document.items, cwd: cwd, exists: exists)
        let files = cwd == nil ? [] : found.read
        VStack(alignment: .leading, spacing: 0) {
            if found.attachments.isEmpty && found.mentions.isEmpty && files.isEmpty && found.pages.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Read").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("Nothing yet").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                }
            } else {
                BlockFold(title: "Read", line: Self.line(gave: found.attachments.count + found.mentions.count, files: files.count, pages: found.pages.count),
                          open: $open, help: open ? "Hide what it read" : "What you gave it, and the files and pages it read")
                if open { list(found, files: files).padding(.top, 2) }
            }
        }
    }

    private func list(_ found: SessionDigest.Inputs, files: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !found.attachments.isEmpty || !found.mentions.isEmpty {
                BlockSubheading("You gave")
                ForEach(found.attachments, id: \.name) { file in
                    ReadRow(icon: "paperclip", title: file.name, detail: nil, trailing: Self.kind(file),
                            help: file.stored == nil ? "Sent before Piopio kept copies of files" : "Open \(file.name)") {
                        if let stored = file.stored { thread.handle(.openAttachment(stored: stored)) }
                    }
                    .disabled(file.stored == nil)
                }
                ForEach(found.mentions, id: \.self) { path in
                    let folder = path.hasSuffix("/")
                    ReadRow(icon: folder ? "folder" : "at", title: path, detail: nil, trailing: folder ? nil : Self.kind(path),
                            help: folder ? "Show \(path) in Finder" : "Open \(path)") { openMention(path) }
                }
            }
            if !files.isEmpty {
                BlockSubheading("Files")
                ForEach(shown(files, "files"), id: \.self) { path in
                    let (dir, name) = Self.split(path)
                    ReadRow(icon: "doc", title: name, detail: dir, trailing: Self.kind(path), help: "Open \(path)") { openRead(path) }
                }
                more(files.count, "files")
            }
            if !found.pages.isEmpty {
                BlockSubheading("Pages")
                ForEach(shown(found.pages, "pages"), id: \.url) { page in
                    ReadRow(icon: "globe", title: page.untitled ? page.host : page.title, detail: page.untitled ? page.path : page.host,
                            trailing: nil, help: page.url) {
                        if let url = URL(string: page.url) { NSWorkspace.shared.open(url) }
                    }
                }
                more(found.pages.count, "pages")
            }
            if let showInFiles, !files.isEmpty {
                SummaryLink("Show in Files ›", action: showInFiles)
                    .help("The project's tree, with what it read and changed")
                    .padding(.top, 10)
            }
        }
    }

    private func shown<T>(_ list: [T], _ group: String) -> [T] {
        all.contains(group) ? list : Array(list.prefix(Self.shortList))
    }

    @ViewBuilder private func more(_ count: Int, _ group: String) -> some View {
        if count > Self.shortList {
            let expanded = all.contains(group)
            SummaryLink(expanded ? "Show fewer" : "and \(count - Self.shortList) more") {
                withAnimation(.easeOut(duration: 0.15)) { if expanded { all.remove(group) } else { all.insert(group) } }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Opening

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~/") { return (path as NSString).expandingTildeInPath }
        return cwd.map { ($0 as NSString).appendingPathComponent(path) } ?? path
    }

    /// Whether an @mention names a file or folder (one that doesn't is prose).
    private func exists(_ path: String) -> Bool {
        let p = absolute(path)
        return p.hasPrefix("/") && FileManager.default.fileExists(atPath: p)
    }

    /// A file in the project opens in the preview; a folder, or anything outside the project, shows in Finder.
    private func openMention(_ path: String) {
        if !path.hasSuffix("/") && !path.hasPrefix("/") && !path.hasPrefix("~"), let openFile { openFile(path) }
        else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolute(path))]) }
    }

    private func openRead(_ path: String) {
        if !path.hasPrefix("/"), let openFile { openFile(path) }
        else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolute(path))]) }
    }

    // MARK: Words

    /// "2 you gave · 9 files · 4 pages".
    static func line(gave: Int, files: Int, pages: Int) -> String {
        var parts: [String] = []
        if gave > 0 { parts.append("\(gave) you gave") }
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        if pages > 0 { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        return parts.joined(separator: " · ")
    }

    /// "src/money/" and "cart.ts".
    static func split(_ path: String) -> (dir: String?, name: String) {
        let name = (path as NSString).lastPathComponent
        let dir = String(path.dropLast(name.count))
        return (dir.isEmpty ? nil : dir, name)
    }

    /// "PDF", "Image", "File".
    static func kind(_ file: AttachmentInfo) -> String {
        file.kind == .image ? "Image" : kind(file.name)
    }

    /// "TS", "SWIFT", "File".
    static func kind(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty || ext.count > 5 ? "File" : ext.uppercased()
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
                    Text(title).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1).truncationMode(.middle)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.middle)
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
