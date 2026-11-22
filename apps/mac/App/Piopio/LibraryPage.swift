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
    /// The item just removed, for Undo (a few seconds).
    @State private var undoing: LibraryEntry?
    @State private var showsRemoved = false
    /// The pin a dragged pin is over: it lights up where the dragged one will land.
    @State private var dropTarget: String?

    private var filtering: Bool { kind != nil || place != nil || !query.isEmpty }

    /// The preview shows only what the list shows (or what's in Removed while it's open).
    private var picked: LibraryEntry? {
        guard let selected else { return nil }
        return shown.first { $0.id == selected } ?? (showsRemoved ? engine.libraryRemoved.first { $0.id == selected } : nil)
    }

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
                    if engine.libraryFailed {
                        failed
                    } else if engine.library.isEmpty && engine.libraryRemoved.isEmpty {
                        if engine.libraryLoaded { empty }
                    } else {
                        filters
                        let pins = engine.pinnedLibrary.filter { p in shown.contains { $0.id == p.id } }
                        if !pins.isEmpty { shelf(pins) }
                        if shown.isEmpty {
                            HStack(spacing: 10) {
                                Text(filtering ? "Nothing matches." : "Everything here was removed.").font(.system(size: 13)).foregroundStyle(Color.dsFg3)
                                if filtering { Button("Clear Filters", action: clearFilters).buttonStyle(PillStyle(compact: true)) }
                            }
                            .padding(.top, 8)
                        } else {
                            ForEach(LibraryText.groups(shown), id: \.0) { title, items in group(title, items) }
                        }
                        if !engine.libraryRemoved.isEmpty { removed }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 44)
                .padding(.bottom, 90)
                .frame(maxWidth: 1080)
                .frame(maxWidth: .infinity)
            }
            if let picked {
                LibraryPreview(engine: engine, item: picked, actions: actions) { selected = nil }
                    .frame(width: 300)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.dsLine).frame(width: 0.5) }
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color.dsWin)
        .animation(.easeOut(duration: 0.15), value: selected)
        // Read again when you come back: a file moved or edited in Finder meanwhile shows as it is now.
        .task { await engine.loadLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await engine.loadLibrary() }
        }
        .overlay(alignment: .bottom) {
            if let undoing {
                LibraryUndoToast(name: undoing.name) {
                    let id = undoing.id
                    self.undoing = nil
                    run { try await engine.restoreLibraryItem(id) }
                } dismiss: { self.undoing = nil }
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(undoing.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: undoing?.id)
        .onAppear(perform: takeFocus)
        .onChange(of: engine.libraryFocus) { takeFocus() }
        .onChange(of: engine.library) { takeFocus() }
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
                Button("Add File…", action: addFiles).buttonStyle(OutlineButtonStyle()).padding(.top, 4)
                    .help("Add any file to the Library; it stays where it is")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(Color.dsFg3)
                    TextField("Search the Library", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10).frame(minWidth: 120, idealWidth: 220, maxWidth: 220).frame(height: 28)
                .background(Color.dsChip, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
                .padding(.top, 4)
            }
        }
    }

    private var filters: some View {
        // The kinds there are, and the one you picked even when nothing of it is left.
        let kinds = LibraryKind.filters.filter { f in f == kind || engine.library.contains { LibraryKind.filter($0.kind) == f } }
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
                    LibraryTile(engine: engine, item: p, selected: selected == p.id) { open(p) } select: { selected = p.id }
                        .contextMenu { menu(p) }
                        // Drag a pin onto another to change their order (the sidebar follows).
                        .draggable(LibraryPinDrag.text(p.id)) { LibraryDragPreview(item: p) }
                        .modifier(LibraryDropTarget(targeted: dropTarget == p.id, radius: DS.Radius.card - 2))
                        .dropDestination(for: String.self) { drops, _ in
                            dropTarget = nil
                            guard let id = LibraryPinDrag.id(drops) else { return false }
                            Task { await engine.movePin(id, onto: p.id) }
                            return true
                        } isTargeted: { on in
                            if on { dropTarget = p.id } else if dropTarget == p.id { dropTarget = nil }
                        }
                }
            }
            // Pins slide into their new places when one is dropped on another.
            .animation(.easeOut(duration: 0.22), value: pins.map(\.id))
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
            Button("Add File…", action: addFiles).buttonStyle(OutlineButtonStyle()).padding(.top, 16)
                .help("Add a file you already have; it stays where it is")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The Library couldn't be read.").font(.system(size: 13.5)).foregroundStyle(Color.dsFg2)
            Button("Retry") { Task { await engine.loadLibrary() } }.buttonStyle(PillStyle(kind: .primary, compact: true))
        }
        .padding(.top, 8)
    }

    /// What you removed, folded at the end, each with Put Back.
    private var removed: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { showsRemoved.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(showsRemoved ? 90 : 0))
                    Text("Removed · \(engine.libraryRemoved.count)")
                }
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.dsFg3)
                .padding(.horizontal, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsRemoved {
                ForEach(engine.libraryRemoved) { r in
                    HStack(spacing: 12) {
                        LibraryThumb(engine: engine, item: r, size: CGSize(width: 40, height: 32), corner: 5).opacity(0.6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).font(.system(size: 13.5)).foregroundStyle(Color.dsFg2).lineLimit(1)
                            LibraryPlaceLabel(engine: engine, item: r, interactive: false)
                        }
                        Spacer()
                        Button("Put Back") { run { try await engine.restoreLibraryItem(r.id) } }.buttonStyle(PillStyle(compact: true))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        }
        .padding(.top, 10)
    }

    private func clearFilters() {
        kind = nil; place = nil; query = ""
    }

    /// Add File…: any files you have, listed where they are.
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Add to the Library. Files stay where they are."
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let paths = panel.urls.map(\.path)
        run {
            var last: LibraryEntry?
            for path in paths { last = try await engine.addToLibrary(path) }
            if let last { engine.libraryFocus = last.id }
        }
    }

    // MARK: Actions

    /// What a pin, ⌘K or Show in Library asked to select, once it's in the list.
    private func takeFocus() {
        guard let id = engine.libraryFocus, engine.library.contains(where: { $0.id == id }) else { return }
        engine.libraryFocus = nil
        kind = nil; place = nil; query = ""
        selected = id
    }

    private var actions: LibraryActions {
        LibraryActions(
            open: open,
            pin: { i in run { try await engine.pinLibrary(i.id, i.pinned != true) } },
            reveal: { i in i.path.map { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) } },
            conversation: openConversation,
            locate: locate,
            remove: { i in
                if selected == i.id { selected = nil }
                run {
                    try await engine.removeFromLibrary(i.id)
                    undoing = i
                    try? await Task.sleep(for: .seconds(6))
                    if undoing?.id == i.id { undoing = nil }
                }
            },
            trash: { trashing = $0 },
            filterPlace: { place = $0 }
        )
    }

    @ViewBuilder private func menu(_ i: LibraryEntry) -> some View {
        LibraryMenu(item: i, actions: actions)
    }

    private func open(_ i: LibraryEntry) {
        LibraryOpen.open(i, engine: engine) { item = $0 } missing: { selected = i.id }
    }

    private func openConversation(_ i: LibraryEntry) {
        if let target = LibraryOpen.reveal(i, engine: engine) { item = target }
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

/// A pin being dragged to a new place: its id as text with a prefix, so other text dropped on a pin is ignored.
enum LibraryPinDrag {
    static let prefix = "piopio-library-pin:"
    static func text(_ id: String) -> String { prefix + id }
    static func id(_ dropped: [String]) -> String? {
        dropped.first.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
    }
}

/// Where a dragged pin will land: the pin under it gets the accent outline and a tint, and grows a little.
struct LibraryDropTarget: ViewModifier {
    let targeted: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.dsAccentSoft.opacity(targeted ? 0.6 : 0))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).opacity(targeted ? 1 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(targeted ? 1.02 : 1)
            .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

/// What follows the pointer while a pin is dragged.
struct LibraryDragPreview: View {
    let item: LibraryEntry
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: LibraryKind.symbol(item.kind)).foregroundStyle(Color.dsFg3)
            Text(item.name).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.dsWin, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
    }
}

/// "Removed … from the Library · Undo", at the foot of the page for a few seconds.
private struct LibraryUndoToast: View {
    let name: String
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Removed “\(name)” from the Library").font(.system(size: 13)).foregroundStyle(Color.dsInvFg).lineLimit(1)
            Button("Undo", action: undo).buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsInvFg)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.dsInvFg.opacity(0.7)) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16).frame(height: 38)
        .background(Capsule().fill(Color.dsInv))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

/// What a row, a tile, the preview and the menus can do with an item.
struct LibraryActions {
    var open: (LibraryEntry) -> Void
    var pin: (LibraryEntry) -> Void
    var reveal: (LibraryEntry) -> Void
    var conversation: (LibraryEntry) -> Void
    var locate: (LibraryEntry) -> Void
    var remove: (LibraryEntry) -> Void
    var trash: (LibraryEntry) -> Void
    /// Show only one place (a click on a row's place).
    var filterPlace: (LibraryPlace) -> Void
}

/// Where an item lives, as the sidebar says it: a project's folder, an agent's tile, a conversation's bubble.
struct LibraryPlaceLabel: View {
    let engine: EngineController
    let item: LibraryEntry
    let interactive: Bool
    /// A narrow window: the icon alone (the name is in the tooltip).
    var iconOnly = false
    @State private var hovering = false

    var body: some View {
        let place = LibraryPlace.of(item)
        HStack(spacing: 6) {
            switch place {
            case .agent(let id):
                RunnerTile(engine: engine, runsAs: id, size: 16)
            default:
                Image(systemName: place.symbol).font(.system(size: 11.5)).foregroundStyle(Color.dsFg3).frame(width: 16)
            }
            if !iconOnly {
                Text(place.rowLabel(engine)).font(.system(size: 12.5)).foregroundStyle(hovering ? Color.dsFg : Color.dsFg2)
                    .lineLimit(1).truncationMode(.tail)
                    .underline(hovering, color: Color.dsFg3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = interactive && $0 }
    }
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
    /// The preview is open: the place column narrows.
    let compact: Bool
    let actions: LibraryActions
    let select: () -> Void
    @State private var hovering = false
    /// The row's width: as it narrows, the place gives way first (down to its icon), then the badge; the name last.
    @State private var width: CGFloat = 900

    /// Thumb, gaps, time and padding: what the name and the place share the rest of.
    private static let fixed: CGFloat = 40 + 12 * 3 + 52 + 20
    /// Room the name keeps before the place starts to narrow.
    private static let nameRoom: CGFloat = 260

    private var placeWidth: CGFloat {
        min(compact ? 140 : 170, max(22, width - Self.fixed - Self.nameRoom))
    }

    var body: some View {
        let placeWidth = placeWidth
        let roomy = width - Self.fixed - placeWidth > 340
        HStack(spacing: 12) {
            LibraryThumb(engine: engine, item: item, size: CGSize(width: 40, height: 32), corner: 5)
            // Name, then what it is (its note), so three report.md files tell themselves apart.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(item.name).font(.system(size: 13.5)).foregroundStyle(item.missing == true ? Color.dsFg3 : Color.dsFg).lineLimit(1).truncationMode(.tail)
                        .layoutPriority(1)
                    if item.missing == true { LibraryBadge(text: "File missing") }
                    else if item.kind == "visual", item.path == nil, roomy { LibraryBadge(text: "in a conversation") }
                    if item.pinned == true {
                        Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(Color.dsFg3).accessibilityLabel("Pinned")
                    }
                }
                Text(LibraryText.second(item)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1).truncationMode(.tail)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            // Where it lives, in the sidebar's words; a click shows only that place. The exact conversation is in the
            // tooltip, the preview and Open the Conversation.
            Button { actions.filterPlace(LibraryPlace.of(item)) } label: {
                LibraryPlaceLabel(engine: engine, item: item, interactive: true, iconOnly: placeWidth < 80)
            }
            .buttonStyle(.plain)
            .help(LibraryText.placeHelp(item, engine))
            .frame(width: placeWidth, alignment: .leading)
            Text(LibraryText.time(item.at)).font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                .frame(width: 52, alignment: .trailing)
                .opacity(hovering ? 0 : 1)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        // On hover, the actions float over the end of the row: they don't hold a column of their own.
        .overlay(alignment: .trailing) {
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
                .padding(.leading, 10).padding(.trailing, 8)
                .background(selected ? Color.dsChip : Color.dsSide)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
    let engine: EngineController
    let item: LibraryEntry
    let selected: Bool
    let open: () -> Void
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryThumb(engine: engine, item: item, size: CGSize(width: 300, height: 96), corner: 0)
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
                LibraryThumb(engine: engine, item: item, size: CGSize(width: 264, height: 160), corner: 8)
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
    let engine: EngineController
    let item: LibraryEntry
    let size: CGSize
    let corner: CGFloat
    @State private var image: NSImage?
    /// Markdown's first lines or a CSV's first rows, where Quick Look gives a blank page.
    @State private var sample: LibrarySample?

    var body: some View {
        // The field fills what it's offered and the picture fills the field, cropped: a wide page never spills out.
        Color.dsCardField
            .overlay(alignment: .top) {
                if let image, item.kind == "visual" {
                    // A visual is drawn at a column's width: whole, with a margin, like its card.
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(size.height > 40 ? 10 : 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if let sample, size.height > 60 {
                    LibrarySampleView(sample: sample)
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
        .task(id: "\(item.id)|\(item.changedAt ?? "")|\(item.visual?.version ?? "")|\(Int(size.width))") {
            image = nil
            sample = nil
            if size.height > 60, let path = item.path, item.missing != true, item.kind != "visual" {
                sample = await LibrarySample.read(path)
            }
            if item.kind == "visual" {
                image = await LibraryThumbnails.visual(item.id, version: item.visual?.version, engine: engine)
                return
            }
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
    /// A visual's picture: drawn once off screen as the visual check draws it (docs/spec/25 §3.2), one at a time.
    private static var visuals: [String: Task<NSImage?, Never>] = [:]
    private static var lastVisual: Task<NSImage?, Never>?

    static func visual(_ id: String, version: String?, engine: EngineController) async -> NSImage? {
        let id = "\(id)|\(version ?? "")"
        if let running = visuals[id] { return await running.value }
        let before = lastVisual
        let task = Task<NSImage?, Never> { @MainActor in
            _ = await before?.value
            guard let v = await engine.libraryVisual(String(id.prefix { $0 != "|" })) else { return nil }
            let drawn = await VisualChecker.check(html: v.html, title: v.title, look: true, width: 640)
            return drawn.jpeg.flatMap(NSImage.init(data:))
        }
        visuals[id] = task
        lastVisual = task
        let image = await task.value
        if image == nil { visuals[id] = nil }
        return image
    }

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

/// What a text or data file starts with, drawn in place of a blank Quick Look page: a heading and lines, or a table.
enum LibrarySample: Equatable {
    case text(title: String?, lines: [String])
    case table([[String]])

    /// Markdown, text, CSV, TSV and JSON; nil for anything else or a file that can't be read.
    static func read(_ path: String) async -> LibrarySample? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ["md", "markdown", "txt", "csv", "tsv", "json"].contains(ext) else { return nil }
        return await Task.detached(priority: .utility) { () -> LibrarySample? in
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 4096)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if ext == "csv" || ext == "tsv" {
                let separator: Character = ext == "tsv" ? "\t" : (lines.first?.contains(";") == true && lines.first?.contains(",") == false ? ";" : ",")
                let rows = lines.prefix(6).map { $0.split(separator: separator, omittingEmptySubsequences: false).prefix(5).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) } }
                return rows.isEmpty ? nil : .table(rows)
            }
            var title: String?
            var rest = lines
            if ext != "json", let first = rest.first, first.hasPrefix("#") {
                title = first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                rest.removeFirst()
            }
            let shown = rest.prefix(7).map { $0.replacingOccurrences(of: "^[-*>#]+\\s*", with: "", options: .regularExpression) }
            return title == nil && shown.isEmpty ? nil : .text(title: title, lines: shown)
        }.value
    }
}

struct LibrarySampleView: View {
    let sample: LibrarySample

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch sample {
            case .text(let title, let lines):
                if let title { Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 10.5)).foregroundStyle(Color.dsFg2).lineLimit(1)
                }
            case .table(let rows):
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).font(.system(size: 10.5, weight: index == 0 ? .semibold : .regular, design: .monospaced))
                                    .foregroundStyle(index == 0 ? Color.dsFg : Color.dsFg2).lineLimit(1)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dsWin)
        .accessibilityHidden(true)
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

    var symbol: String {
        switch self {
        case .project: "folder"
        case .agent: "person.crop.circle"
        case .conversations: "bubble.left"
        case .added: "plus.circle"
        }
    }

    /// In a row: one place, so a free conversation is "Conversation".
    @MainActor func rowLabel(_ engine: EngineController) -> String {
        self == .conversations ? "Conversation" : label(engine)
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
    /// The tooltip on a row's place: the exact conversation, and what a click does.
    @MainActor static func placeHelp(_ item: LibraryEntry, _ engine: EngineController) -> String {
        let only = "\(LibraryPlace.of(item).rowLabel(engine)) · click to show only \(LibraryPlace.of(item).label(engine))"
        guard let origin = item.origin else { return only }
        return "Made in “\(origin.title)”. \(only)."
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

    /// A row's second line: its note, or its kind; and who made it when that's an agent the place doesn't name.
    static func second(_ item: LibraryEntry) -> String {
        let what = item.note ?? LibraryKind.label(item.kind)
        let agent = item.by != "Piopio" && item.by != "You" && item.by != item.origin?.title
        return agent ? "\(what) · by \(item.by)" : what
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
    static func open(_ item: LibraryEntry, engine: EngineController, go: @escaping (SidebarItem) -> Void, missing: () -> Void) {
        if item.missing == true { missing(); return }
        if let path = item.path {
            NotificationCenter.default.post(name: .viewFile, object: URL(fileURLWithPath: path))
            return
        }
        // A visual, large, in the visual sheet. Its buttons don't send into a conversation you aren't looking at:
        // what they'd send or fill in goes to that conversation's composer, after anything already there.
        Task {
            guard let v = await engine.libraryVisual(item.id) else {
                if let target = reveal(item, engine: engine) { go(target) }
                return
            }
            let back: @MainActor (String) -> Void = { text in
                guard let target = reveal(item, engine: engine) else { return }
                go(target)
                if let ref = item.origin?.ref, ref.kind != .agent || ref.conversationId == nil {
                    let thread = engine.thread(ref)
                    let had = thread.draft?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    thread.draft = had.isEmpty ? text : had + "\n\n" + text
                }
            }
            let place = item.origin.map { "Its buttons fill in “\($0.title)”" }
            NotificationCenter.default.post(name: .showVisual, object: ShownVisual(title: v.title, html: v.html, send: back, prefill: back, note: place))
        }
    }

    /// The conversation that made it (an agent's opens the agent).
    static func conversation(_ item: LibraryEntry, engine: EngineController) -> SidebarItem? {
        guard let ref = item.origin?.ref else { return nil }
        return engine.item(for: ref.id)
    }

    /// The exact conversation: a chat or Build session scrolled to a visual's card; an agent's page on the run or the
    /// person's conversation it came from.
    static func reveal(_ item: LibraryEntry, engine: EngineController) -> SidebarItem? {
        guard let target = conversation(item, engine: engine), let ref = item.origin?.ref else { return nil }
        if ref.kind == .agent {
            if let conversation = ref.conversationId {
                // The agent's page takes it once it's showing, as Automations opens a run.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NotificationCenter.default.post(name: .openAgentRun, object: conversation) }
            }
        } else if let call = item.visual?.callId {
            engine.thread(ref).reveal("tool:\(call)")
        }
        return target
    }
}

@MainActor
extension EngineController {
    /// Open the Library with an item selected.
    func focusLibrary(_ id: String) {
        libraryFocus = id
        NotificationCenter.default.post(name: .selectItem, object: SidebarItem.library.raw)
    }
}
