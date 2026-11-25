import Foundation

/// A recoverable local draft. A retry keeps its request id until the payload changes or is acknowledged.
public struct ComposerDraft: Codable, Sendable, Equatable {
    public var text: String
    public var attachments: [Attachment]
    public var requestId: String
    public var editItemId: String?
    public var destination: ContainerRef?
    public var steer: Bool
    public init(text: String = "", attachments: [Attachment] = [], requestId: String = UUID().uuidString, editItemId: String? = nil, steer: Bool = false, destination: ContainerRef? = nil) {
        self.text = text; self.attachments = attachments; self.requestId = requestId; self.editItemId = editItemId; self.steer = steer; self.destination = destination
    }
}

/// Separate files keep attachment payloads out of preferences. Atomic writes also survive interruption.
///
/// Drafts take the system's default protection class, as the conversations and attachments they belong to do. A
/// stricter class (`completeUnlessOpen`, used until 2026-11-25) can't be opened while the Mac is locked, and a draft read
/// then looked like no draft: the empty composer's next save deleted it. Files of that class are moved to the default
/// the first time they're read.
public struct DraftStore: Sendable {
    public let directory: URL
    public init(home: URL) { directory = home.appending(path: "drafts") }
    /// Where the draft for `key` is stored.
    public func url(_ key: String) -> URL {
        directory.appending(path: Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".json")
    }
    /// The draft saved for `key`, or nil when there's none. A file that can't be read now throws and stays as it is, for
    /// the next try; one that doesn't decode is moved aside (`<file>.corrupt-<time>`), as the engine does with its
    /// stores, so a later save doesn't write over it.
    public func load(_ key: String) throws -> ComposerDraft? {
        let file = url(key)
        let data: Data
        do { data = try Data(contentsOf: file) } catch CocoaError.fileReadNoSuchFile { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        if let protection = attributes?[.protectionKey] as? FileProtectionType, protection == .completeUnlessOpen {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        }
        do { return try JSONDecoder().decode(ComposerDraft.self, from: data) } catch {
            let aside = file.appendingPathExtension("corrupt-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))")
            try? FileManager.default.moveItem(at: file, to: aside)
            return nil
        }
    }
    public func save(_ draft: ComposerDraft, for key: String) throws {
        let file = url(key)
        if draft.text.isEmpty && draft.attachments.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(draft).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Serialization runs off the UI actor, in order, so large image drafts don't block typing.
public actor DraftWriter {
    private let store: DraftStore
    public init(store: DraftStore) { self.store = store }
    public func save(_ draft: ComposerDraft, for key: String) throws {
        try Task.checkCancellation()
        try store.save(draft, for: key)
    }
}
