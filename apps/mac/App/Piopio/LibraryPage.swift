import AppKit
import PiopioKit
import PiopioTranscript
import QuickLookThumbnailing
import SwiftUI

/// The Library (docs/spec/35 §4): everything Piopio and your agents made, listed where it already lives. A shelf of
/// pins, then everything by day; kinds, places and search; a preview that says where each one came from. It never moves
/// a file: Remove hides an item, and Move to Trash is its own, confirmed step.
struct LibraryPage: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var kind: String?
    @State private var place: LibraryPlace?
    @State private var query = ""
    @State private var selected: String?
    @State private var trashing: LibraryEntry?
    @State private var problem: String?

    private var shown: [LibraryEntry] {
        engine.library.filter { i in
            (kind == nil || LibraryKind.filter(i.kind) == kind)
                && (place == nil || LibraryPlace.of(i) == place)
                && (query.isEmpty || LibraryText.matches(i, query))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if engine.library.isEmpty {
                        if engine.libraryLoaded { empty }
                    } else {
                        filters
                        let pins = engine.pinnedLibrary.filter { p in shown.contains { $0.id == p.id } }
                        if !pins.isEmpty { shelf(pins) }
                        if shown.isEmpty {
                            Text("Nothing matches.").font(.system(size: 13)).foregroundStyle(Color.dsFg3).padding(.top, 8)
                        } else {
                            ForEach(LibraryText.groups(shown), id: \.0) { title, items in group(title, items) }
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 44)
                .padding(.bottom, 90)
                .frame(maxWidth: 1080)
                .frame(maxWidth: .infinity)
            }
            if let id = selected, let picked = engine.library.first(where: { $0.id == id }) {
                LibraryPreview(engine: engine, item: picked, actions: actions) { selected = nil }
                    .frame(width: 300)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.dsLine).frame(width: 0.5) }
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color.dsWin)
        .animation(.easeOut(duration: 0.15), value: selected)
        .task { if !engine.libraryLoaded { await engine.loadLibrary() } }
        .onReceive(NotificationCenter.default.publisher(for: .showLibraryItem)) { note in
            if let id = note.object as? String { selected = id }
        }
        .alert("Move “\(trashing?.name ?? "")” to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })) {
            Button("Move to Trash", role: .destructive) { if let t = trashing { trash(t) }; trashing = nil }
            Button("Cancel", role: .cancel) { trashing = nil }
        } message: {
            Text("The file goes to the Finder's Trash and leaves the Library. You can put it back from the Trash.")
        }
        .alert("Couldn't do that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Library").font(.system(size: 28, weight: .bold)).tracking(-0.6).foregroundStyle(Color.dsFg)
                Text("What Piopio and your agents made: files where they live, and visuals in their conversations.")
                    .font(.system(size: 14)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !engine.library.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                    TextField("Search the Library", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10).frame(width: 220, height: 28)
                .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
                .padding(.top, 4)
            }
        }
    }

    private var filters: some View {
        let kinds = LibraryKind.filters.filter { f in engine.library.contains { LibraryKind.filter($0.kind) == f } }
        return HStack(spacing: 6) {
            chip(nil, "All")
            ForEach(kinds, id: \.self) { f in chip(f, LibraryKind.plural(f)) }
            Spacer(minLength: 12)
            Menu {
                Button("All places") { place = nil }
                let places = LibraryPlace.all(engine.library)
                if !places.isEmpty { Divider() }
                ForEach(places, id: \.self) { p in Button(p.label(engine)) { place = p } }
            } label: {
                Text(place?.label(engine) ?? "All places").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Show what one project, agent or the free conversations made")
        }
    }

    private func chip(_ id: String?, _ title: String) -> some View {
        let on = id == kind
        return Button { kind = id } label: {
            Text(title)
                .font(.system(size: 12.5)).foregroundStyle(on ? Color.dsInvFg : Color.dsFg)
                .padding(.horizontal, 11).frame(height: 26)
                .background(Capsule().fill(on ? Color.dsInv : Color.dsChip))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func shelf(_ pins: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pinned").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.dsFg3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), alignment: .leading, spacing: 12) {
                ForEach(pins) { p in
                    LibraryTile(item: p, selected: selected == p.id) { open(p) } select: { selected = p.id }
                        .contextMenu { menu(p) }
                }
            }
        }
    }

    private func group(_ title: String, _ items: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.dsFg3)
                .padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(items) { i in
                LibraryRow(engine: engine, item: i, selected: selected == i.id, compact: selected != nil, actions: actions) {
                    selected = selected == i.id ? nil : i.id
                }
                .contextMenu { menu(i) }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 0) {
            Image(systemName: "books.vertical")
                .font(.system(size: 21)).foregroundStyle(Color.dsFg2)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.dsChip))
                .accessibilityHidden(true)
            Text("Nothing made yet").font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.dsFg).padding(.top, 14)
            Text("When Piopio or an agent hands you a file, writes a document in a chat or draws a visual, it shows here, with where it came from.")
                .font(.system(size: 13.5)).foregroundStyle(Color.dsFg2).multilineTextAlignment(.center)
                .frame(maxWidth: 420).padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    // MARK: Actions

    private var actions: LibraryActions {
        LibraryActions(
            open: open,
            pin: { i in run { try await engine.pinLibrary(i.id, i.pinned != true) } },
            reveal: { i in i.path.map { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) } },
            conversation: openConversation,
            locate: locate,
            remove: { i in
                if selected == i.id { selected = nil }
                run { try await engine.removeFromLibrary(i.id) }
            },
            trash: { trashing = $0 }
        )
    }

    @ViewBuilder private func menu(_ i: LibraryEntry) -> some View {
        LibraryMenu(item: i, actions: actions)
    }

    private func open(_ i: LibraryEntry) {
        LibraryOpen.open(i, engine: engine) { item = $0 } missing: { selected = i.id }
    }

    private func openConversation(_ i: LibraryEntry) {
        if let target = LibraryOpen.conversation(i, engine: engine) { item = target }
        else { problem = "The conversation it came from isn't here any more." }
    }

    private func locate(_ i: LibraryEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Where is “\(i.name)” now?"
        panel.prompt = "Locate"
        if let path = i.path { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try await engine.relocateLibraryItem(i.id, to: url.path) }
    }

    private func trash(_ i: LibraryEntry) {
        guard let path = i.path else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            problem = error.localizedDescription
            return
        }
        if selected == i.id { selected = nil }
        run { try await engine.removeFromLibrary(i.id) }
    }

    private func run(_ f: @escaping () async throws -> Void) {
        Task {
            do { try await f() } catch { problem = error.localizedDescription }
        }
    }
}

// MARK: - Pieces

/// What a row, a tile, the preview and the menus can do with an item.
struct LibraryActions {
    var open: (LibraryEntry) -> Void
    var pin: (LibraryEntry) -> Void
    var reveal: (LibraryEntry) -> Void
    var conversation: (LibraryEntry) -> Void
    var locate: (LibraryEntry) -> Void
    var remove: (LibraryEntry) -> Void
    var trash: (LibraryEntry) -> Void
}

/// The ⋯ menu and the context menu: the same items.
struct LibraryMenu: View {
    let item: LibraryEntry
    let actions: LibraryActions

    var body: some View {
        if item.missing == true {
            Button("Locate…") { actions.locate(item) }
        } else {
            Button("Open") { actions.open(item) }
        }
        Button(item.pinned == true ? "Unpin" : "Pin") { actions.pin(item) }
        Divider()
        if item.path != nil, item.missing != true { Button("Show in Finder") { actions.reveal(item) } }
        if item.origin != nil { Button("Open the Conversation") { actions.conversation(item) } }
        if let path = item.path {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
        Divider()
        Button("Remove from Library") { actions.remove(item) }
        if item.path != nil, item.missing != true { Button("Move to Trash…", role: .destructive) { actions.trash(item) } }
    }
}

private struct LibraryRow: View {
    let engine: EngineController
    let item: LibraryEntry
    let selected: Bool
    /// The preview is open: the "By" column goes.
    let compact: Bool
    let actions: LibraryActions
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            LibraryThumb(item: item, size: CGSize(width: 34, height: 26), corner: 5)
            HStack(spacing: 7) {
                Text(item.name).font(.system(size: 13.5)).foregroundStyle(item.missing == true ? Color.dsFg3 : Color.dsFg).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                Text(LibraryKind.label(item.kind)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize()
                if item.missing == true { LibraryBadge(text: "File missing") }
                else if item.kind == "visual", !compact { LibraryBadge(text: "in a conversation") }
                if item.pinned == true {
                    Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(Color.dsFg3).accessibilityLabel("Pinned")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(LibraryText.place(item, engine)).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(1).truncationMode(.middle)
                .frame(width: 180, alignment: .leading)
            if !compact {
                Text(item.by).font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(1).frame(width: 110, alignment: .leading)
            }
            ZStack(alignment: .trailing) {
                Text(LibraryText.time(item.at)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).opacity(hovering ? 0 : 1)
                if hovering {
                    HStack(spacing: 2) {
                        if item.missing == true { small("Locate…") { actions.locate(item) } }
                        else { small("Open") { actions.open(item) } }
                        small(item.pinned == true ? "Unpin" : "Pin") { actions.pin(item) }
                        Menu { LibraryMenu(item: item, actions: actions) } label: {
                            Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Color.dsFg2).frame(width: 22, height: 20)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.dsChip : hovering ? Color.dsSide : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { item.missing == true ? actions.locate(item) : actions.open(item) }
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open") { actions.open(item) }
    }

    private func small(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color.dsFg2).padding(.horizontal, 6).frame(height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LibraryBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Color.dsFg3).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.dsFg3.opacity(0.6), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])))
    }
}

private struct LibraryTile: View {
    let item: LibraryEntry
    let selected: Bool
    let open: () -> Void
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryThumb(item: item, size: CGSize(width: 300, height: 96), corner: 0)
                .frame(height: 96).frame(maxWidth: .infinity).clipped()
                .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 0.5) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg).lineLimit(1).truncationMode(.middle)
                Text("\(LibraryKind.label(item.kind)) · \(LibraryText.changed(item))").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(Color.dsWin)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card - 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card - 2, style: .continuous).strokeBorder(selected || hovering ? Color.dsFg3 : Color.dsLine, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open", open)
    }
}

/// The preview beside the list: a picture, the note, where the file is, the conversation that made it, who and when.
private struct LibraryPreview: View {
    let engine: EngineController
    let item: LibraryEntry
    let actions: LibraryActions
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsFg3).frame(width: 22, height: 22) }
                        .buttonStyle(.plain).help("Close the preview")
                }
                LibraryThumb(item: item, size: CGSize(width: 264, height: 160), corner: 8)
                    .frame(height: 160).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dsFg).textSelection(.enabled)
                    Text(item.note ?? LibraryText.what(item)).font(.system(size: 13)).foregroundStyle(Color.dsFg2).fixedSize(horizontal: false, vertical: true)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    row("Kind", "\(LibraryKind.label(item.kind))\(item.size.map { " · \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? "")")
                    if let path = item.path {
                        GridRow {
                            Text("File").foregroundStyle(Color.dsFg3)
                            Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(item.missing == true ? Color.dsRed : Color.dsFg).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        row("File", "Not saved: it's in its conversation")
                    }
                    if let origin = item.origin {
                        GridRow {
                            Text("Made in").foregroundStyle(Color.dsFg3)
                            Button { actions.conversation(item) } label: { Text(origin.title).foregroundStyle(Color.accentColor).lineLimit(2).multilineTextAlignment(.leading) }
                                .buttonStyle(.plain).help("Open the conversation it came from")
                        }
                    }
                    row("By", item.by)
                    row(item.how == "added" ? "Added" : "Made", LibraryText.long(item.at))
                    if let changed = item.changedAt, changed > item.at, LibraryText.long(changed) != LibraryText.long(item.at) { row("Changed", LibraryText.long(changed)) }
                }
                .font(.system(size: 12.5))
                if item.missing == true {
                    Text("The file isn't where it was. Find it, or remove it from the Library.").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                }
                HStack(spacing: 8) {
                    if item.missing == true {
                        Button("Locate…") { actions.locate(item) }.buttonStyle(PillStyle(kind: .primary))
                        Button("Remove") { actions.remove(item) }.buttonStyle(PillStyle())
                    } else {
                        Button("Open") { actions.open(item) }.buttonStyle(PillStyle(kind: .primary))
                        Button(item.pinned == true ? "Unpin" : "Pin") { actions.pin(item) }.buttonStyle(PillStyle())
                        if item.path != nil { Button("Show in Finder") { actions.reveal(item) }.buttonStyle(PillStyle()) }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(Color.dsWin)
    }

    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(Color.dsFg3)
            Text(value).foregroundStyle(Color.dsFg).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A picture of the item: Quick Look's thumbnail for a file, its kind's glyph otherwise (a visual, a file that's gone).
struct LibraryThumb: View {
    let item: LibraryEntry
    let size: CGSize
    let corner: CGFloat
    @State private var image: NSImage?

    var body: some View {
        // The field fills what it's offered and the picture fills the field, cropped: a wide page never spills out.
        Color.dsCardField
            .overlay(alignment: .top) {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: LibraryKind.symbol(item.kind))
                        .font(.system(size: min(size.height * 0.42, 26))).foregroundStyle(Color.dsFg3)
                }
            }
            .clipped()
            .frame(width: size.width < 100 ? size.width : nil, height: size.width < 100 ? size.height : nil)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            if corner > 0 { RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5) }
        }
        .task(id: "\(item.path ?? "")|\(item.changedAt ?? "")|\(Int(size.width))") {
            image = nil
            guard let path = item.path, item.missing != true, LibraryThumbnails.pictured(path) else { return }
            image = await LibraryThumbnails.image(path: path, changed: item.changedAt, size: size)
        }
    }
}

/// Quick Look thumbnails, kept for the session by file, change and size.
@MainActor
enum LibraryThumbnails {
    private static var cache: [String: NSImage] = [:]

    /// Kinds whose Quick Look picture says something: images, pages, PDFs, slides. Text, data and Word files come out
    /// as a blank page at these sizes, so they keep their glyph.
    nonisolated static func pictured(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "html", "htm", "pdf", "key", "pptx"].contains((path as NSString).pathExtension.lowercased())
    }

    static func image(path: String, changed: String?, size: CGSize) async -> NSImage? {
        let key = "\(path)|\(changed ?? "")|\(Int(size.width))x\(Int(size.height))"
        if let hit = cache[key] { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size, scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        if cache.count > 300 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

// MARK: - Words and places

enum LibraryKind {
    /// The kind filters, in order (Apps come with docs/spec/35 L2).
    static let filters = ["app", "document", "page", "visual", "image", "data"]

    /// Which filter an item falls under; slides go with documents, other files only under All.
    static func filter(_ kind: String) -> String? {
        switch kind {
        case "slides": "document"
        case "file": nil
        default: kind
        }
    }

    static func plural(_ kind: String) -> String {
        switch kind {
        case "app": "Apps"
        case "document": "Documents"
        case "page": "Pages"
        case "visual": "Visuals"
        case "image": "Images"
        case "data": "Data"
        default: "Other"
        }
    }

    static func label(_ kind: String) -> String {
        switch kind {
        case "app": "App"
        case "document": "Document"
        case "page": "Page"
        case "visual": "Visual"
        case "image": "Image"
        case "data": "Data"
        case "slides": "Slides"
        default: "File"
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "app": "square.grid.2x2"
        case "document": "doc.text"
        case "page": "globe"
        case "visual": "rectangle.3.group"
        case "image": "photo"
        case "data": "tablecells"
        case "slides": "rectangle.on.rectangle"
        default: "doc"
        }
    }
}

/// Where an item came from, as the place filter groups them: a project, an agent, or the free conversations.
enum LibraryPlace: Hashable {
    case project(String)
    case agent(String)
    case conversations
    case added

    static func of(_ item: LibraryEntry) -> LibraryPlace {
        guard let origin = item.origin else { return .added }
        if let project = origin.project { return .project(project) }
        if origin.ref.kind == .agent { return .agent(origin.ref.id) }
        return .conversations
    }

    static func all(_ items: [LibraryEntry]) -> [LibraryPlace] {
        var seen = Set<LibraryPlace>()
        return items.map(of).filter { seen.insert($0).inserted }
    }

    @MainActor func label(_ engine: EngineController) -> String {
        switch self {
        case .project(let path): engine.projects.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent
        case .agent(let id): engine.agents.first { $0.ref.id == id }?.title ?? "An agent"
        case .conversations: "Conversations"
        case .added: "Added by you"
        }
    }
}

enum LibraryText {
    @MainActor static func place(_ item: LibraryEntry, _ engine: EngineController) -> String {
        guard let origin = item.origin else { return "Added by you" }
        switch LibraryPlace.of(item) {
        case .project:
            let name = LibraryPlace.of(item).label(engine)
            return origin.title == name ? name : "\(name) › \(origin.title)"
        default:
            return origin.title
        }
    }

    static func matches(_ item: LibraryEntry, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [item.name, item.note, item.origin?.title, item.by, item.path].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// Today, Yesterday, Earlier this week, then by month.
    static func groups(_ items: [LibraryEntry], now: Date = Date()) -> [(String, [LibraryEntry])] {
        let cal = Calendar.current
        var out: [(String, [LibraryEntry])] = []
        for item in items {
            let date = ISODate.parse(item.at) ?? now
            let title: String
            if cal.isDate(date, inSameDayAs: now) { title = "Today" }
            else if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { title = "Yesterday" }
            else if let week = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now)), date >= week { title = "Earlier this week" }
            else { title = date.formatted(.dateTime.month(.wide).year()) }
            if out.last?.0 == title { out[out.count - 1].1.append(item) } else { out.append((title, [item])) }
        }
        return out
    }

    /// "10:44" today, "Sat" this week, "12 Nov" before.
    static func time(_ iso: String, now: Date = Date()) -> String {
        guard let date = ISODate.parse(iso) else { return "" }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)), date >= week { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func long(_ iso: String) -> String {
        guard let date = ISODate.parse(iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// For a tile: "changed 10:44", or when it was made.
    static func changed(_ item: LibraryEntry) -> String {
        if let c = item.changedAt, c > item.at { return "changed \(time(c))" }
        return time(item.at)
    }

    static func what(_ item: LibraryEntry) -> String {
        switch item.how {
        case "visual": "A visual \(item.by) drew in a conversation."
        case "written": "A file \(item.by) wrote in a chat."
        case "added": "A file you added."
        default: "A file \(item.by) handed over."
        }
    }
}

/// Opening an item: a file in the viewer, a visual in its conversation, a missing file in the Library's preview.
@MainActor
enum LibraryOpen {
    static func open(_ item: LibraryEntry, engine: EngineController, go: (SidebarItem) -> Void, missing: () -> Void) {
        if item.missing == true { missing(); return }
        if let path = item.path {
            NotificationCenter.default.post(name: .viewFile, object: URL(fileURLWithPath: path))
        } else if let target = conversation(item, engine: engine) {
            go(target)
        }
    }

    /// The conversation that made it (an agent's opens the agent).
    static func conversation(_ item: LibraryEntry, engine: EngineController) -> SidebarItem? {
        guard let ref = item.origin?.ref else { return nil }
        return engine.item(for: ref.id)
    }
}

extension Notification.Name {
    /// Select an item in the Library's preview (its id is the object): a missing pin from the sidebar.
    static let showLibraryItem = Notification.Name("piopio.showLibraryItem")
}
