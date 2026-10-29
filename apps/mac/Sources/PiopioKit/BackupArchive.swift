import CryptoKit
import Foundation

/// A verified directory archive. The caller must stop the engine before creating or restoring one.
/// External project folders and Keychain secrets are never copied or overwritten.
public enum BackupArchive {
    public struct Manifest: Codable, Sendable {
        public let version: Int
        public let createdAt: Date
        public let originalHome: String
        public var files: [String: String]
        public var relocated: [String: String]
    }
    public enum Failure: LocalizedError {
        case invalid(String)
        public var errorDescription: String? { switch self { case .invalid(let message): message } }
    }
    private static var fm: FileManager { FileManager() }
    private static let excluded: Set<String> = ["engine.sock", "engine.token", "engine.lock", "logs", "search.db", "search.db-wal", "search.db-shm"]
    private static func directory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private static func inside(_ url: URL, _ root: URL) -> Bool {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        return p == r || p.hasPrefix(r + "/")
    }
    private static func checkStopped(_ home: URL) throws {
        guard !fm.fileExists(atPath: home.appending(path: "engine.sock").path) else { throw Failure.invalid("Stop the engine before working with a backup.") }
    }
    private static func copyTree(_ source: URL, _ target: URL, top: Bool = false) throws {
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw Failure.invalid("Backup contains a symbolic link: \(source.lastPathComponent). Copy its target into Piopio first.") }
        if values.isDirectory == true {
            try directory(target)
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                if top && excluded.contains(child.lastPathComponent) { continue }
                try copyTree(child, target.appending(path: child.lastPathComponent))
            }
        } else if values.isRegularFile == true {
            try directory(target.deletingLastPathComponent())
            try fm.copyItem(at: source, to: target)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } else { throw Failure.invalid("Unsupported file in backup: \(source.lastPathComponent)") }
    }
    private static func relativePath(_ file: URL, in root: URL) -> String {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        return String(path.dropFirst(base.count + 1))
    }
    private static func regularFiles(_ root: URL) throws -> [URL] {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var result: [URL] = []
        for case let file as URL in walker {
            let v = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v.isSymbolicLink != true else { throw Failure.invalid("Symbolic links are not allowed in backup archives.") }
            if v.isRegularFile == true { result.append(file) }
        }
        return result
    }
    private static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    @discardableResult public static func create(home: URL, at target: URL, preferences: Data? = nil) throws -> Manifest {
        try checkStopped(home)
        guard !inside(target.resolvingSymlinksInPath(), home.resolvingSymlinksInPath()), !fm.fileExists(atPath: target.path) else { throw Failure.invalid("Choose a new backup folder outside Piopio's data folder.") }
        let stage = target.deletingLastPathComponent().appending(path: ".piopio-backup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        try directory(stage)
        let data = stage.appending(path: "data")
        try copyTree(home, data, top: true)
        var manifest = Manifest(version: 1, createdAt: .now, originalHome: home.path, files: [:], relocated: [:])
        let catalog = home.appending(path: "sessions.json")
        if fm.fileExists(atPath: catalog.path) {
            let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [[String: Any]] ?? []
            for (index, entry) in entries.enumerated() {
                for key in ["agentFolder", "sessionFile", "file"] {
                    guard let path = entry[key] as? String else { continue }
                    let source = URL(fileURLWithPath: path)
                    guard !inside(source, home) else { continue }
                    let relative = "recovered/\(index)/\(key)/\(source.lastPathComponent)"
                    let destination = data.appending(path: relative)
                    if key == "sessionFile" {
                        // A CLI may also write this file. Never archive an incomplete JSONL record.
                        let bytes = try Data(contentsOf: source)
                        for line in bytes.split(separator: 10) where !line.isEmpty { _ = try JSONSerialization.jsonObject(with: Data(line)) }
                        try directory(destination.deletingLastPathComponent())
                        try bytes.write(to: destination, options: .atomic)
                    } else {
                        try copyTree(source, destination)
                        if key == "file" {
                            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
                                try copyTree(URL(fileURLWithPath: path + suffix), URL(fileURLWithPath: destination.path + suffix))
                            }
                        }
                    }
                    manifest.relocated[path] = relative
                }
            }
        }
        if let preferences { try preferences.write(to: stage.appending(path: "preferences.plist"), options: .atomic) }
        for file in try regularFiles(stage) {
            let relative = relativePath(file, in: stage)
            manifest.files[relative] = try digest(file)
        }
        try JSONEncoder().encode(manifest).write(to: stage.appending(path: "manifest.json"), options: .atomic)
        try fm.moveItem(at: stage, to: target)
        return manifest
    }
    public static func inspect(_ archive: URL) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: archive.appending(path: "manifest.json")))
        guard manifest.version == 1 else { throw Failure.invalid("This backup version is not supported.") }
        let files = try regularFiles(archive)
        let actual = Set(files.map { relativePath($0, in: archive) }.filter { $0 != "manifest.json" })
        guard actual == Set(manifest.files.keys), manifest.files.keys.contains("data/sessions.json") || !manifest.files.isEmpty else { throw Failure.invalid("The backup is incomplete or contains unexpected files. Missing: \(Set(manifest.files.keys).subtracting(actual).sorted()); unexpected: \(actual.subtracting(manifest.files.keys).sorted())") }
        for (relative, checksum) in manifest.files {
            let file = archive.appending(path: relative)
            guard !relative.hasPrefix("/"), inside(file, archive), try digest(file) == checksum else { throw Failure.invalid("Backup verification failed for \(relative).") }
        }
        for relative in manifest.relocated.values {
            guard !relative.hasPrefix("/"), inside(archive.appending(path: "data").appending(path: relative), archive.appending(path: "data")) else { throw Failure.invalid("Invalid relocated file path.") }
        }
        return manifest
    }
    /// Restores into a new folder. The app swaps it into place only after verification succeeds.
    public static func restore(_ archive: URL, to target: URL) throws {
        let manifest = try inspect(archive)
        guard !fm.fileExists(atPath: target.path), !inside(target, archive) else { throw Failure.invalid("Restore needs a new folder outside the backup.") }
        do {
            try copyTree(archive.appending(path: "data"), target)
            func relocated(_ string: String) -> String {
                if let relative = manifest.relocated[string] { return target.appending(path: relative).path }
                if string == manifest.originalHome { return target.path }
                if string.hasPrefix(manifest.originalHome + "/") { return target.path + string.dropFirst(manifest.originalHome.count) }
                return string
            }
            func remap(_ object: Any) -> Any {
                if let dict = object as? [String: Any] { return dict.mapValues { remap($0) } }
                if let array = object as? [Any] { return array.map { remap($0) } }
                if let string = object as? String { return relocated(string) }
                return object
            }
            for name in ["sessions.json", "projects.json"] {
                let file = target.appending(path: name)
                if fm.fileExists(atPath: file.path) {
                    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
                    var mapped = remap(object)
                    if name == "sessions.json", var entries = mapped as? [[String: Any]], let originals = object as? [[String: Any]] {
                        for index in entries.indices {
                            if let original = originals[index]["sessionFile"] as? String, manifest.relocated[original] != nil {
                                entries[index]["restoredFromSessionFile"] = originals[index]["restoredFromSessionFile"] ?? original
                            }
                        }
                        mapped = entries
                    }
                    try JSONSerialization.data(withJSONObject: mapped, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
                }
            }
        } catch { try? fm.removeItem(at: target); throw error }
    }
    /// Rebase the staged catalog after moving a verified restore to its final home.
    public static func rebase(home: URL, from old: URL) throws {
        for name in ["sessions.json", "projects.json"] {
            let file = home.appending(path: name)
            guard fm.fileExists(atPath: file.path) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            // JSON serialization escapes slashes on some OS releases; normalize through an object first.
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
            func visit(_ value: Any) -> Any {
                if let d = value as? [String: Any] { return d.mapValues { visit($0) } }
                if let a = value as? [Any] { return a.map { visit($0) } }
                if let s = value as? String, s == old.path || s.hasPrefix(old.path + "/") { return home.path + s.dropFirst(old.path.count) }
                return value
            }
            try JSONSerialization.data(withJSONObject: visit(object), options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        }
    }
}
