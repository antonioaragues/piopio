import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI
import UniformTypeIdentifiers

// Build mode (docs/spec/05-build, docs/design 2a): projects with their sessions in the sidebar, and a
// session view with tool cards. Approvals, checkpoints, the inspector and git arrive in milestones 2.2–2.4.

/// Sidebar: Projects (folders) with nested sessions, newest first.
struct BuildSidebarList: View {
    let engine: EngineController
    @Binding var selection: String?
    @State private var collapsed: Set<String> = []
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""

    var body: some View {
        HStack {
            SectionLabel("Projects")
            Spacer()
            Button { BuildActions.addProject(engine: engine) { selection = $0 } } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            .buttonStyle(.plain)
            .help("Add a project folder (⌘O)")
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        if engine.projects.isEmpty {
            Text("Folders you open appear here.").font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.horizontal, 8)
        }
        ForEach(engine.projects) { project in
            projectRow(project)
            if !collapsed.contains(project.id) {
                ForEach(engine.sessions(in: project), id: \.ref.id) { session in
                    sessionRow(session)
                }
            }
        }
        Button { BuildActions.addProject(engine: engine) { selection = $0 } } label: {
            Label("Add project", systemImage: "plus").font(.system(size: 12.5)).foregroundStyle(Color.dsFg3)
                .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let session = renaming { Task { await engine.rename(session.ref, to: newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func projectRow(_ project: ProjectInfo) -> some View {
        let open = !collapsed.contains(project.id)
        let hasSelection = engine.sessions(in: project).contains { $0.ref.id == selection }
        return Button {
            if open { collapsed.insert(project.id) } else { collapsed.remove(project.id) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.dsFg3)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(hasSelection ? Color.accentColor : Color.dsFg3.opacity(0.55))
                    .frame(width: 14, height: 11)
                Text(project.name).font(.system(size: 13, weight: .medium)).foregroundStyle(project.missing == true ? Color.dsFg3 : Color.dsFg).lineLimit(1)
                Spacer(minLength: 4)
                if project.missing == true {
                    Text("missing").font(.system(size: 11)).foregroundStyle(Color.dsRed)
                } else if open, let branch = project.branch {
                    Text(branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dsFg3).lineLimit(1)
                } else if !open {
                    let count = engine.sessions(in: project).count
                    if count > 0 { Text("\(count)").font(.system(size: 11)).foregroundStyle(Color.dsFg3).monospacedDigit() }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("New Session") { Task { if let ref = await engine.createBuildSession(in: project) { selection = ref.id } } }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
            Divider()
            Button("Remove from Piopio") {
                if engine.sessions(in: project).contains(where: { $0.ref.id == selection }) { selection = nil }
                Task { await engine.removeProject(project) }
            }
        }
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        let selected = selection == session.ref.id
        return Button { selection = session.ref.id } label: {
            HStack(spacing: 8) {
                StatusDot(status: dot(session), size: 6).frame(width: 10)
                Text(session.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(Color.dsFg)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(selected ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") {
                newTitle = session.title
                renaming = session
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                if selection == session.ref.id { selection = nil }
                Task { await engine.delete(session.ref) }
            }
        }
    }

    /// amber = waiting on you, spinner = running, red = failed, grey = idle (docs/design 2a).
    private func dot(_ session: SessionSummary) -> StatusDot.Status {
        switch engine.liveStatus[session.ref.id] {
        case .running?: .running
        case .waitingApproval?: .waiting
        case .error?: .failed
        default: .idle
        }
    }
}

@MainActor
enum BuildActions {
    /// Asks for a folder, adds it as a project, and starts a session in it when it has none.
    static func addProject(engine: EngineController, select: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a folder to work on. Sessions run with pi-coding-agent inside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await add(url, engine: engine, select: select) }
    }

    static func add(_ url: URL, engine: EngineController, select: (String) -> Void) async {
        guard let project = await engine.addProject(url) else { return }
        if let latest = engine.sessions(in: project).first {
            select(latest.ref.id)
        } else if let ref = await engine.createBuildSession(in: project) {
            select(ref.id)
        }
    }
}

/// A Build session (docs/design 2a): header with the project and branch, transcript with tool cards, composer.
struct BuildSessionView: View {
    let engine: EngineController
    let session: ThreadModel
    let summary: SessionSummary

    private var project: ProjectInfo? { engine.projects.first { $0.path == summary.cwd } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottom) {
                TranscriptView(document: session.document)
                VStack(spacing: 8) {
                    if !session.isFollowing {
                        Button { session.scrollToLatest() } label: {
                            Label("Jump to latest", systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(PillStyle(kind: .toolbar, compact: true))
                    }
                    Composer(engine: engine, thread: session)
                        .frame(maxWidth: 636)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }
            }
        }
        .task { await session.open() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dsFg).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.dsFg3).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let branch = project?.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12, design: .monospaced))
                    .labelStyle(BranchLabelStyle())
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.dsPill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 0.5))
                    .help("Current branch of \(project?.name ?? "the project")")
            }
            if let cwd = summary.cwd {
                Menu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) }
                    Button("Open in Terminal") { openTerminal(cwd) }
                    Divider()
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cwd, forType: .string)
                    }
                } label: {
                    Image(systemName: "folder").font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(PillStyle(kind: .toolbar))
                .menuIndicator(.hidden)
                .fixedSize()
                .help(cwd)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 60)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var subtitle: String {
        var parts = [project?.name ?? URL(fileURLWithPath: summary.cwd ?? "").lastPathComponent]
        parts.append("started \(Self.relative(summary.createdAt))")
        if let usage = session.state?.usage, usage.costUsd > 0 {
            parts.append(usage.costUsd < 0.01 ? String(format: "$%.4f", usage.costUsd) : String(format: "$%.2f", usage.costUsd))
        }
        if session.state?.status == .running { parts.append("working…") }
        return parts.joined(separator: " · ")
    }

    static func relative(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func openTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct BranchLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 10, weight: .medium)).foregroundStyle(Color.dsFg3)
            configuration.title.lineLimit(1)
        }
    }
}

/// Build with no session selected: open a folder (button, ⌘O or drop), or start a session in a project.
struct BuildEmptyState: View {
    let engine: EngineController
    @Binding var selection: String?
    @State private var targeted = false

    var body: some View {
        EmptyState(label: "Build", title: engine.projects.isEmpty ? "Open a folder to start building" : "Pick a session, or start one", message: "Each folder becomes a Project. Sessions run with pi-coding-agent inside it, and sessions you start with the pi CLI show up here too.") {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    Text("Drop a folder here").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                    Button("Open Folder… ⌘O") { BuildActions.addProject(engine: engine) { selection = $0 } }
                        .buttonStyle(PillStyle(kind: .primary))
                }
                .frame(width: 360, height: 110)
                .background(targeted ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(targeted ? Color.dsAccentLine : Color.dsLine, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in await BuildActions.add(url, engine: engine) { selection = $0 } }
                    }
                    return true
                }
                if !engine.projects.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(engine.projects.prefix(4)) { project in
                            Button("New session in \(project.name)") {
                                Task { if let ref = await engine.createBuildSession(in: project) { selection = ref.id } }
                            }
                            .buttonStyle(PillStyle())
                        }
                    }
                }
            }
        }
    }
}
