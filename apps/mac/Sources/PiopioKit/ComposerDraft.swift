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
public struct DraftStore: Sendable {
    public let directory: URL
    public init(home: URL) { directory = home.appending(path: "drafts") }
    private func url(_ key: String) -> URL {
        directory.appending(path: Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".json")
    }
    public func load(_ key: String) -> ComposerDraft? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(ComposerDraft.self, from: data)
    }
    public func save(_ draft: ComposerDraft, for key: String) throws {
        let file = url(key)
        if draft.text.isEmpty && draft.attachments.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(draft).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
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
