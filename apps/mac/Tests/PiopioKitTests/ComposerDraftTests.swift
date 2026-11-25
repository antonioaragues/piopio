import Foundation
import Testing
@testable import PiopioKit

@Test func draftsRecoverAttachmentsAndRetryIdentityPerConversation() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let store = DraftStore(home: home)
    let draft = ComposerDraft(text: "Keep this", attachments: [.text(name: "note.txt", mimeType: nil, text: "notes"), .image(name: "image.png", mimeType: "image/png", data: "AAAA")], editItemId: "u1", steer: true)
    try store.save(draft, for: "space:one/topic")
    try store.save(ComposerDraft(text: "Other"), for: "agent:one")
    #expect(try store.load("space:one/topic") == draft)
    #expect(try store.load("agent:one")?.text == "Other")
    try store.save(ComposerDraft(), for: "space:one/topic")
    #expect(try store.load("space:one/topic") == nil)
    #expect(try store.load("agent:one") != nil)
}

/// A draft written with `completeUnlessOpen` couldn't be opened while the Mac was locked (this test failed then), and the
/// empty composer's next save deleted it. Drafts take the default class, and old ones are moved to it when read.
@Test func draftsReadWhileTheMacIsLocked() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let store = DraftStore(home: home)
    try store.save(ComposerDraft(text: "New"), for: "thread:new")
    let plain = home.appending(path: "plain")
    try Data().write(to: plain, options: .atomic)
    func protection(_ file: URL) throws -> FileProtectionType? { try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType }
    #expect(try protection(store.url("thread:new")) == protection(plain))

    let old = store.url("thread:old")
    try JSONEncoder().encode(ComposerDraft(text: "Old")).write(to: old, options: [.atomic, .completeFileProtectionUnlessOpen])
    guard try protection(old) == .completeUnlessOpen else { return } // a volume without data protection classes
    #expect(try store.load("thread:old")?.text == "Old")
    #expect(try protection(old) == protection(plain))
}

@Test func aDraftThatCantBeReadIsKeptAndOneThatDoesntDecodeIsMovedAside() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let store = DraftStore(home: home)
    try store.save(ComposerDraft(text: "Locked away"), for: "thread:a")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.url("thread:a").path)
    #expect(throws: (any Error).self) { try store.load("thread:a") }
    #expect(FileManager.default.fileExists(atPath: store.url("thread:a").path))

    try Data("{not json".utf8).write(to: store.url("thread:b"))
    #expect(try store.load("thread:b") == nil)
    #expect(!FileManager.default.fileExists(atPath: store.url("thread:b").path))
    let aside = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasPrefix(store.url("thread:b").lastPathComponent + ".corrupt-") }
    #expect(aside.count == 1)
    #expect(try store.load("thread:missing") == nil)
}
