import Foundation
import Testing
@testable import PiopioKit

@Test func backupRestoresExternalAgentAndSessionWithoutTouchingOriginals() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source"), agent = root.appending(path: "external-agent")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    try Data("persona".utf8).write(to: agent.appending(path: "instructions.md"))
    let session = root.appending(path: "external.jsonl")
    try Data("{\"id\":\"one\"}\n".utf8).write(to: session)
    let entries: [[String: Any]] = [["ref": ["kind": "agent", "id": "a"], "agentFolder": agent.path, "file": source.appending(path: "a.sqlite").path], ["ref": ["kind": "build", "id": "b"], "sessionFile": session.path, "cwd": "/external/project"]]
    try JSONSerialization.data(withJSONObject: entries).write(to: source.appending(path: "sessions.json"))
    try Data("database".utf8).write(to: source.appending(path: "a.sqlite"))
    try Data("secret".utf8).write(to: source.appending(path: "engine.token"))
    let archive = root.appending(path: "backup.piopiobackup"), restored = root.appending(path: "restored")
    let manifest = try BackupArchive.create(home: source, at: archive)
    #expect(manifest.relocated.count == 2)
    #expect(!FileManager.default.fileExists(atPath: archive.appending(path: "data/engine.token").path))
    try BackupArchive.restore(archive, to: restored)
    let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: restored.appending(path: "sessions.json"))) as! [[String: Any]]
    #expect((catalog[0]["agentFolder"] as? String)?.hasPrefix(restored.path) == true)
    #expect(catalog[1]["cwd"] as? String == "/external/project")
    #expect(try String(contentsOf: agent.appending(path: "instructions.md"), encoding: .utf8) == "persona")
    try Data("tampered".utf8).write(to: archive.appending(path: "data/a.sqlite"))
    #expect(throws: (any Error).self) { try BackupArchive.inspect(archive) }
    #expect(throws: (any Error).self) { try BackupArchive.restore(archive, to: root.appending(path: "bad")) }
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "bad").path))
}

@Test func backupRefusesLiveEngineAndSymbolicLinks() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appending(path: "engine.sock"))
    #expect(throws: (any Error).self) { try BackupArchive.create(home: root, at: root.appendingPathExtension("backup")) }
    try FileManager.default.removeItem(at: root.appending(path: "engine.sock"))
    try FileManager.default.createSymbolicLink(atPath: root.appending(path: "link").path, withDestinationPath: "/etc/passwd")
    #expect(throws: (any Error).self) { try BackupArchive.create(home: root, at: root.appendingPathExtension("backup")) }
}

// Re-audit 2026-11-25: temporary chats (meant to be gone in a day) and the webhook signing key were copied into backups.
@Test func backupLeavesOutTemporaryChatsAndTheWebhookKey() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let home = root.appending(path: "home")
    let chats = home.appending(path: "chats"), scratch = home.appending(path: "scratch/t1"), attachments = home.appending(path: "attachments/t1")
    for dir in [chats, scratch, attachments, home.appending(path: "scratch/k1")] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
    try Data("{\"id\":\"t\"}\n".utf8).write(to: chats.appending(path: "t1.jsonl"))
    try Data("{\"id\":\"k\"}\n".utf8).write(to: chats.appending(path: "k1.jsonl"))
    try Data("plan".utf8).write(to: scratch.appending(path: "notes.md"))
    try Data("photo".utf8).write(to: attachments.appending(path: "a.png"))
    try Data("key".utf8).write(to: home.appending(path: "hooks.key"))
    let entries: [[String: Any]] = [
        ["ref": ["kind": "thread", "id": "t1"], "title": "My medical results", "temporary": ["expiresAt": "2026-11-26T00:00:00Z"], "sessionFile": chats.appending(path: "t1.jsonl").path, "cwd": scratch.path],
        ["ref": ["kind": "thread", "id": "k1"], "title": "Kitchen", "sessionFile": chats.appending(path: "k1.jsonl").path, "cwd": home.appending(path: "scratch/k1").path],
    ]
    try JSONSerialization.data(withJSONObject: entries).write(to: home.appending(path: "sessions.json"))
    let paths = [chats.appending(path: "t1.jsonl").path, scratch.path, attachments.path, home.appending(path: "chats/t1.jsonl-wal").path]
    try JSONSerialization.data(withJSONObject: ["conversations": ["t1"], "paths": paths]).write(to: home.appending(path: "backup-exclude.json"))

    let archive = root.appending(path: "b.piopiobackup")
    try BackupArchive.create(home: home, at: archive)
    let data = archive.appending(path: "data")
    for gone in ["chats/t1.jsonl", "scratch/t1", "attachments/t1", "hooks.key", "backup-exclude.json"] {
        #expect(!fm.fileExists(atPath: data.appending(path: gone).path), "\(gone) is in the backup")
    }
    #expect(fm.fileExists(atPath: data.appending(path: "chats/k1.jsonl").path))
    let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: data.appending(path: "sessions.json"))) as! [[String: Any]]
    #expect(catalog.compactMap { ($0["ref"] as? [String: Any])?["id"] as? String } == ["k1"])
    #expect(!String(decoding: try Data(contentsOf: data.appending(path: "sessions.json")), as: UTF8.self).contains("medical"))
    // The backup still verifies and restores.
    try BackupArchive.restore(archive, to: root.appending(path: "restored"))

    // An unreadable list fails the backup instead of keeping what was meant to go.
    try Data("{".utf8).write(to: home.appending(path: "backup-exclude.json"))
    #expect(throws: (any Error).self) { try BackupArchive.create(home: home, at: root.appending(path: "c.piopiobackup")) }
}
