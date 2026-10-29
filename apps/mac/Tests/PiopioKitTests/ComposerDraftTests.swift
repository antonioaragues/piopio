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
    #expect(store.load("space:one/topic") == draft)
    #expect(store.load("agent:one")?.text == "Other")
    try store.save(ComposerDraft(), for: "space:one/topic")
    #expect(store.load("space:one/topic") == nil)
    #expect(store.load("agent:one") != nil)
}
