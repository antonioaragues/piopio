import AppKit
import PiopioKit
import SwiftUI
import UniformTypeIdentifiers

/// An agent's kept files (docs/spec/06-agents §14 FL5): what you sent it, and what you added here or in its folder.
/// Each row opens the file, says what it is (a note you or the agent wrote), and can be revealed, dragged out or
/// deleted. Add… and dropping files keep them the way a sent one is (a PDF's text is read here, as for attachments).
struct AgentFilesView: View {
    let engine: EngineController
    let summary: SessionSummary
    /// The count changed (the Setup row shows it).
    var changed: (Int) -> Void = { _ in }
    @State private var files: [AgentFile] = []
    @State private var folder: String?
    @State private var problem: String?
    @State private var notes: [String: String] = [:]
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(files.isEmpty ? "Nothing kept yet." : "\(files.count) file\(files.count == 1 ? "" : "s")").font(.system(size: 12.5)).foregroundStyle(Color.dsFg2)
                Spacer()
                if let folder {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
                        .buttonStyle(PillStyle(compact: true))
                }
                Button("Add…") { pick() }.buttonStyle(PillStyle(compact: true))
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Color.dsWarn) }
            if files.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 22)).foregroundStyle(Color.dsFg3)
                    Text("Send \(summary.title) a file in its chat, or drop one here, and it keeps it to read later.")
                        .font(.system(size: 12.5)).foregroundStyle(Color.dsFg3).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(files) { f in row(f) }
            }
        }
        .padding(16)
        .overlay {
            if dropping { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2).padding(6) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task { await add(await urls(providers)) }
            return true
        }
        .task(id: summary.updatedAt) { await load() }
    }

    private func row(_ f: AgentFile) -> some View {
        let url = URL(fileURLWithPath: f.path)
        return HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Button(f.name) { NSWorkspace.shared.open(url) }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dsFg)
                    .help("Open")
                TextField("What is it?", text: Binding(get: { notes[f.name] ?? f.note ?? "" }, set: { notes[f.name] = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.dsFg2)
                    .onSubmit { saveNote(f) }
                Text([ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file), BuildSessionView.relative(f.addedAt), f.readable ? nil : "it can't read this one yet: send it in the chat"].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(f.readable ? Color.dsFg3 : Color.dsAmber)
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Reveal in Finder")
            Button { delete(f) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Delete")
        }
        .padding(.vertical, 3)
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }

    private func load() async {
        guard let result = await engine.agentFiles(summary.ref) else { return }
        files = result.files
        folder = result.folder
        changed(files.count)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Keep"
        guard panel.runModal() == .OK else { return }
        Task { await add(panel.urls) }
    }

    private func add(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        var attachments: [Attachment] = []
        var failed: [String] = []
        for url in urls {
            do { attachments.append(try AttachmentLoader.load(url).attachment) } catch { failed.append(url.lastPathComponent) }
        }
        problem = failed.isEmpty ? nil : "Couldn't keep \(failed.joined(separator: ", ")): only images, PDFs and text files for now."
        guard !attachments.isEmpty else { return }
        do {
            _ = try await engine.addAgentFiles(summary.ref, attachments)
        } catch {
            problem = (error as? EngineError)?.message ?? error.localizedDescription
        }
        await load()
    }

    private func saveNote(_ f: AgentFile) {
        guard let note = notes[f.name], note != (f.note ?? "") else { return }
        Task {
            try? await engine.noteAgentFile(summary.ref, name: f.name, note: note)
            notes[f.name] = nil
            await load()
        }
    }

    private func delete(_ f: AgentFile) {
        Task {
            do { try await engine.deleteAgentFile(summary.ref, name: f.name) } catch { problem = (error as? EngineError)?.message ?? error.localizedDescription }
            await load()
        }
    }

    private func urls(_ providers: [NSItemProvider]) async -> [URL] {
        var out: [URL] = []
        for p in providers {
            if let url = await withCheckedContinuation({ (c: CheckedContinuation<URL?, Never>) in
                _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
            }) { out.append(url) }
        }
        return out
    }
}
