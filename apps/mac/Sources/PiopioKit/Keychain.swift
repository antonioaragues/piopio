import Foundation
import OSLog
import Security

/// Generic-password items under service "Piopio", account = secret name (e.g. provider.openrouter.apiKey).
/// The app owns secrets; the engine asks for them with `secrets.get`.
///
/// Two stores, picked once per process:
/// - **Data protection keychain** (iOS-style), when the build is signed by the team with a keychain access group:
///   access goes by the app's Team ID, so macOS never asks for a password. Items stay on this Mac
///   (`…ThisDeviceOnly`: no iCloud sync, not in backups) and are readable after the first unlock, for background agents.
///   An item left in the login keychain by an older build moves over the first time it's read (one last prompt).
/// - **Login keychain**, for ad hoc builds and `piopio-cli` (no provisioning profile, so no access group). Reading a
///   value can make macOS ask for the login keychain password (always, for a build it hasn't been allowed for), so
///   each value is read at most once per launch and kept in memory, and `exists` never reads a value.
public enum Keychain {
    /// `PIOPIO_KEYCHAIN_SERVICE` keeps captures and experiments out of the real items.
    public static let service = ProcessInfo.processInfo.environment["PIOPIO_KEYCHAIN_SERVICE"] ?? "Piopio"

    /// Whether this process can use the data protection keychain (a team-signed build with a keychain access group).
    /// Probed with a delete of an item that never exists: without the entitlement a lookup just finds nothing, while
    /// a delete (like an add) fails with `errSecMissingEntitlement`.
    public static let usesDataProtection: Bool = {
        let status = SecItemDelete(item("piopio.probe", dataProtection: true) as CFDictionary)
        log.notice("keychain: \(status == errSecMissingEntitlement ? "login keychain" : "data protection keychain", privacy: .public) (probe \(status))")
        return status != errSecMissingEntitlement
    }()

    /// Item statuses other than success and not-found, by account (never values): `log stream --predicate 'subsystem == "app.piopio"'`.
    private static let log = Logger(subsystem: "app.piopio", category: "keychain")
    private static func check(_ status: OSStatus, _ what: String, _ account: String, dataProtection: Bool) {
        guard status != errSecSuccess, status != errSecItemNotFound else { return }
        log.error("keychain: \(what, privacy: .public) \(account, privacy: .public) in the \(dataProtection ? "data protection" : "login", privacy: .public) keychain failed: \(status)")
    }

    /// Values read or written this launch; `.some(nil)` remembers that there is none.
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    /// Whether there's an item, without reading its value (no password prompt).
    public static func exists(_ account: String) -> Bool {
        if let cached = lock.withLock({ cache[account] }) { return cached != nil }
        if usesDataProtection, has(account, dataProtection: true) { return true }
        return has(account, dataProtection: false)
    }

    public static func read(_ account: String) -> String? {
        if let cached = lock.withLock({ cache[account] }) { return cached }
        let value = usesDataProtection ? readOrMigrate(account) : value(account, dataProtection: false)
        log.info("keychain: read \(account, privacy: .public): \(value == nil ? "missing" : "found", privacy: .public)")
        // A missing item isn't remembered: it may be added by another copy of the app.
        if let value { lock.withLock { cache[account] = .some(value) } }
        return value
    }

    public static func write(_ account: String, value: String) throws {
        // An older copy in the login keychain would come back if this build ever lost its access group. It goes first:
        // a delete without `kSecUseDataProtectionKeychain` reaches the data protection keychain too, so afterwards it
        // would take the new item with it.
        if usesDataProtection { remove(account, dataProtection: false) }
        let status = add(account, value: value, dataProtection: usesDataProtection)
        guard status == errSecSuccess else {
            lock.withLock { _ = cache.removeValue(forKey: account) }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        lock.withLock { cache[account] = .some(value) }
    }

    public static func delete(_ account: String) {
        if usesDataProtection { remove(account, dataProtection: true) }
        remove(account, dataProtection: false)
        lock.withLock { cache[account] = .some(nil) }
    }

    // MARK: - Items

    private static func readOrMigrate(_ account: String) -> String? {
        if let value = value(account, dataProtection: true) { return value }
        guard has(account, dataProtection: false), let legacy = value(account, dataProtection: false) else { return nil }
        // Old copy out first (see `write`); back in if the move fails.
        remove(account, dataProtection: false)
        if add(account, value: legacy, dataProtection: true) != errSecSuccess { _ = add(account, value: legacy, dataProtection: false) }
        return legacy
    }

    private static func item(_ account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private static func has(_ account: String, dataProtection: Bool) -> Bool {
        var query = item(account, dataProtection: dataProtection)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func value(_ account: String, dataProtection: Bool) -> String? {
        var query = item(account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        check(status, "read", account, dataProtection: dataProtection)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func add(_ account: String, value: String, dataProtection: Bool) -> OSStatus {
        remove(account, dataProtection: dataProtection)
        var add = item(account, dataProtection: dataProtection)
        add[kSecValueData as String] = Data(value.utf8)
        if dataProtection { add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
        let status = SecItemAdd(add as CFDictionary, nil)
        check(status, "add", account, dataProtection: dataProtection)
        return status
    }

    private static func remove(_ account: String, dataProtection: Bool) {
        SecItemDelete(item(account, dataProtection: dataProtection) as CFDictionary)
    }
}
