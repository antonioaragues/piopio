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
