import AppKit
import PiopioKit

/// Opt-in end-to-end recovery check. It requires an explicit scratch home and the scripted model.
@MainActor enum DebugRecovery {
    static func run(_ engine: EngineController, report: URL) async {
        var checks: [String] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw EngineError(code: "INVALID", message: message) }
            checks.append(message)
        }
        do {
            guard engine.faux, ProcessInfo.processInfo.environment["PIOPIO_HOME"] != nil else { throw EngineError(code: "INVALID", message: "Recovery smoke requires PIOPIO_FAUX=1 and a scratch PIOPIO_HOME.") }
            guard let chat = await engine.createThread() else { throw EngineError(code: "INTERNAL", message: "create chat") }
            let thread = engine.thread(chat)
            await thread.open()
            thread.composerText = "Recovery message"
            thread.composerAttachments = (0..<11).map { PendingAttachment(name: "image\($0).png", attachment: .image(name: "image\($0).png", mimeType: "image/png", data: "AAAA")) }
            let failed = await thread.send(thread.composerText, attachments: thread.composerAttachments.map(\.attachment))
            try require(!failed && thread.composerText == "Recovery message" && thread.composerAttachments.count == 11, "Failed send preserves text and attachments")
            thread.composerAttachments = [PendingAttachment(name: "note.txt", attachment: .text(name: "note.txt", mimeType: nil, text: "Recovery attachment"))]
            try await thread.flushDraft()
            try require(DraftStore(home: engine.home).load("thread:\(chat.key)")?.attachments.count == 1, "Draft and attachment persist to disk")
            let sent = await thread.send(thread.composerText, attachments: thread.composerAttachments.map(\.attachment))
            try require(sent && thread.composerText.isEmpty && thread.composerAttachments.isEmpty, "Acknowledged send clears the draft")
            _ = try await settled(engine, ref: chat)
            thread.composerText = "Keep another draft"
            let direct = await thread.send("A separate entry point")
            try require(direct && thread.composerText == "Keep another draft", "Sending from another entry point preserves an existing draft")
            thread.composerText = ""; try await thread.flushDraft()
            _ = try await settled(engine, ref: chat)
            guard let notebook = await engine.createSpace(name: "Recovery notebook", instructions: ""), let client = engine.client else { throw EngineError(code: "INTERNAL", message: "create notebook") }
            _ = try await client.call("sessions.submit", SubmitParams(ref: notebook, text: "/new Recovery topic\nNotebook recovery marker"), as: SubmitResult.self)
            _ = try await settled(engine, ref: notebook, routed: true)
            let agent = try await engine.createAgent(name: "Recovery agent", template: "personal-assistant", avatar: "🐥")
            let agentThread = engine.thread(agent); await agentThread.open()
            _ = await agentThread.send("Agent recovery marker")
            _ = try await settled(engine, ref: agent)
            let projectFolder = engine.home.deletingLastPathComponent().appending(path: "project")
            try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
            try Data("Keep external project files".utf8).write(to: projectFolder.appending(path: "keep.txt"))
            guard let project = await engine.addProject(projectFolder), let build = await engine.createBuildSession(in: project) else { throw EngineError(code: "INTERNAL", message: "create Build session") }
            let buildThread = engine.thread(build); await buildThread.open()
            _ = await buildThread.send("Build recovery marker")
            _ = try await settled(engine, ref: build)
            let archive = engine.home.deletingLastPathComponent().appending(path: "recovery.piopiobackup")
            try await engine.createBackup(at: archive)
            try require(engine.status == .ready, "Engine reconnects after offline backup")
            _ = try BackupArchive.inspect(archive)
            let previous = try await engine.restoreBackup(from: archive, restorePreferences: false)
            try require(FileManager.default.fileExists(atPath: previous.path), "Restore retains the previous data folder")
            for ref in [chat, notebook, agent, build] {
                guard let client = engine.client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "restore reconnect") }
                let snapshot = try await client.call("sessions.open", RefParams(ref: ref), as: Snapshot.self)
                try require(!snapshot.items.isEmpty, "Restores \(ref.kind.rawValue) history")
            }
            try await engine.refreshCatalog()
            try require(engine.buildSessions.count == 1, "Restored Build history is not duplicated by CLI discovery")
            try require(try String(contentsOf: projectFolder.appending(path: "keep.txt"), encoding: .utf8) == "Keep external project files", "Restore preserves external project files")
            guard let client = engine.client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "search reconnect") }
            let hits = try await client.call("catalog.search", SearchParams(query: "Notebook recovery marker", kind: .space), as: SearchResults.self)
            try require(hits.results.contains { $0.ref.conversationId != nil }, "Search opens restored notebook topic references")
            try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
        }
        NSApp.terminate(nil)
    }
    private static func settled(_ engine: EngineController, ref: ContainerRef, routed: Bool = false) async throws -> Snapshot {
        for _ in 0..<200 {
            guard let client = engine.client else { throw EngineError(code: "ENGINE_UNAVAILABLE", message: "disconnected") }
            let snapshot = try await client.call("sessions.open", RefParams(ref: ref), as: Snapshot.self)
            let finished = snapshot.items.contains { item in
                if routed { if case .routing(let r) = item { return r.status == .replied }; return false }
                if case .assistant(let a) = item { return a.status == .done }; return false
            }
            if snapshot.state.status == .idle && finished { return snapshot }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw EngineError(code: "BUSY", message: "Timed out waiting for \(ref.kind.rawValue)")
    }
}
