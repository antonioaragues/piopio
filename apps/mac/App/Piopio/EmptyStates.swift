import PiopioKit
import PiopioTranscript
import SwiftUI

/// The shared empty-state pattern (docs/design/grey): a title, one sentence, then real starting points. No mascot.
struct HatchEmpty<Content: View>: View {
    let title: String
    let message: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(title).font(.system(size: 20, weight: .bold))
                Text(message).font(.system(size: 14)).foregroundStyle(Color.dsFg2).multilineTextAlignment(.center)
                    .frame(maxWidth: 420).padding(.top, 6)
                content.padding(.top, 24)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32)
            .padding(.vertical, 72)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Build (11a)

/// No projects yet: a drop zone, the git repos found in the usual folders, and the pi CLI's sessions to import.
struct BuildFirstRun: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var targeted = false
    @State private var found: Found?

    struct Repo: Identifiable, Hashable { let url: URL; var id: String { url.path } }
    struct Found { var folder: String; var repos: [Repo]; var piFolders: [URL]; var piSessions: Int }

    var body: some View {
        HatchEmpty(title: "Point Piopio at some code", message: "Each folder becomes a project. Sessions run with pi inside it, on its branch or in a worktree of their own.") {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 10) {
                    Text("Drop a folder here").font(.system(size: 13)).foregroundStyle(Color.dsFg2)
                    Button("Open Folder… ⌘O") { BuildActions.addProject(engine: engine) { item = .session($0) } }
                        .buttonStyle(PillStyle(kind: .primary))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .background(targeted ? Color.dsAccentSoft : .clear, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(targeted ? Color.dsAccentLine : Color.dsLine, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                if let found, !found.repos.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Found in \(found.folder)")
                        ListCard {
                            ForEach(Array(found.repos.enumerated()), id: \.element) { i, repo in
                                HStack(spacing: 10) {
                                    InitialTile(name: repo.url.lastPathComponent, size: 22)
                                    Text(repo.url.lastPathComponent).font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Button("Add") { Task { await BuildActions.add(repo.url, engine: engine) { item = .session($0) } } }
                                        .buttonStyle(PillStyle(compact: true))
                                }
                                .padding(.horizontal, 12).frame(height: 44)
                                if i < found.repos.count - 1 { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, 44) }
                            }
                        }
                    }
                }
                if let found, found.piSessions > 0 {
                    HStack(spacing: 4) {
                        Text("Using the pi CLI?").foregroundStyle(Color.dsFg3)
                        Button("Import \(found.piSessions) session\(found.piSessions == 1 ? "" : "s") from ~/.pi") { importPi(found.piFolders) }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 480)
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await BuildActions.add(url, engine: engine) { item = .session($0) } }
            }
            return true
        }
        .task { found = await Task.detached { Self.scan() }.value }
    }

    /// Adds every folder the pi CLI has sessions for; its sessions show up under each project.
    private func importPi(_ folders: [URL]) {
        Task {
            for url in folders { _ = await engine.addProject(url, lens: .build) }
            item = .index(.projects)
        }
    }

    /// Git repos directly inside the first of the usual code folders that has any, newest first, and the
    /// working folders of pi's sessions (`~/.pi/agent/sessions/<cwd>/*.jsonl`, whose first line names the cwd).
    nonisolated static func scan() -> Found {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var folder = "", repos: [Repo] = []
        for name in ["Proyectos", "Projects", "Developer", "Code", "code", "src", "dev", "repos"] {
            let dir = home.appendingPathComponent(name)
            guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { continue }
            let git = kids.filter { fm.fileExists(atPath: $0.appendingPathComponent(".git").path) }
            guard !git.isEmpty else { continue }
            let date = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            repos = git.sorted { date($0) > date($1) }.prefix(4).map(Repo.init)
            folder = "~/" + name
            break
        }
        var piFolders: [URL] = [], piSessions = 0
        let sessions = home.appendingPathComponent(".pi/agent/sessions")
        for dir in (try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jsonl" }
            guard let first = files.first, let handle = try? FileHandle(forReadingFrom: first) else { continue }
            let head = (try? handle.read(upToCount: 4096)) ?? Data()
            try? handle.close()
            let line = head.split(separator: UInt8(ascii: "\n")).first.map { Data($0) } ?? head
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let cwd = json["cwd"] as? String,
                  fm.fileExists(atPath: cwd) else { continue }
            piFolders.append(URL(fileURLWithPath: cwd))
            piSessions += files.count
        }
        return Found(folder: folder, repos: repos, piFolders: piFolders, piSessions: piSessions)
    }
}

// MARK: Chat (11b)

/// No chats yet: ask something right here, or start a chat or a notebook.
struct ChatFirstRun: View {
    let engine: EngineController
    @Binding var item: SidebarItem

    var body: some View {
        HatchEmpty(title: "What's on your mind?", message: "Ask anything. Chats keep their own history; notebooks gather a subject's topics, files and memory in one place.") {
            VStack(spacing: 14) {
                AskBox(engine: engine, item: $item)
                HStack(spacing: 10) {
                    tile("New chat", "⌘N", "bubble.left") { NotificationCenter.default.post(name: .newChat, object: nil) }
                    tile("New debate", "⌥⌘N", "person.2.wave.2") { NotificationCenter.default.post(name: .newDebate, object: nil) }
                    tile("New notebook", "⌘⇧N", "book.closed") { NotificationCenter.default.post(name: .newSpace, object: nil) }
                }
                Text("Tip: \(QuickChatShortcut.current.label) opens Quick Chat from any app.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            .frame(maxWidth: 520)
        }
    }

    private func tile(_ title: String, _ shortcut: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Color.accentColor).frame(width: 20)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg)
                Spacer()
                Text(shortcut).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Agents (11c)

/// No agents yet: three templates to hatch in one click, or start from scratch.
struct AgentsFirstRun: View {
    let engine: EngineController
    @Binding var item: SidebarItem
    @State private var templates: [AgentTemplate] = []
    @State private var creating: String?
    @State private var error: String?

    var body: some View {
        HatchEmpty(title: "Hatch your first agent", message: "Agents run on a schedule, remember what you teach them and reach you when something matters. They run on this Mac.") {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(featured) { t in card(t) }
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.dsRed) }
                Button("Start from scratch…") { NotificationCenter.default.post(name: .newAgent, object: nil) }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.accentColor)
            }
        }
        .task { templates = await engine.agentTemplates() }
    }

    /// A briefing, a coach and a watcher first (docs/design v2, 11c).
    private var featured: [AgentTemplate] {
        let order = ["daily-briefing", "habit-coach", "research-watcher"]
        return Array(templates.sorted { (order.firstIndex(of: $0.id) ?? 9) < (order.firstIndex(of: $1.id) ?? 9) }.prefix(3))
    }

    private func card(_ t: AgentTemplate) -> some View {
        Button {
            creating = t.id
            Task {
                do {
                    let ref = try await engine.createAgent(name: t.name, template: t.id, avatar: t.avatar)
                    item = .agent(ref.id)
                } catch {
                    self.error = error.localizedDescription
                }
                creating = nil
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(t.avatar).font(.system(size: 26))
                Text(t.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg)
                Text(t.description).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(creating == t.id ? "Hatching…" : "Use this ›").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
            }
            .padding(14)
            .frame(width: 168, height: 168, alignment: .topLeading)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsLine, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(creating != nil)
    }
}
