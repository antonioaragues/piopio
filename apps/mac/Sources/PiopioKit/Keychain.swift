import Foundation
import Security

/// Generic-password items under service "Piopio", account = secret name (e.g. provider.openrouter.apiKey).
/// The app owns secrets; the engine asks for them with `secrets.get`.
///
/// Reading a secret's value can make macOS ask for the login keychain password (always, for a build it hasn't been
/// allowed for), so each value is read at most once per launch and kept in memory, and `exists` checks for an item
/// without reading its value, which never asks.
public enum Keychain {
    /// `PIOPIO_KEYCHAIN_SERVICE` keeps captures and experiments out of the real items.
    public static let service = ProcessInfo.processInfo.environment["PIOPIO_KEYCHAIN_SERVICE"] ?? "Piopio"

    /// Values read or written this launch; `.some(nil)` remembers that there is none.
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    /// Whether there's an item, without reading its value (no password prompt).
    public static func exists(_ account: String) -> Bool {
        if let cached = lock.withLock({ cache[account] }) { return cached != nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public static func read(_ account: String) -> String? {
        if let cached = lock.withLock({ cache[account] }) { return cached }
        let value = readItem(account)
        // A missing item isn't remembered: it may be added by another copy of the app.
        if let value { lock.withLock { cache[account] = .some(value) } }
        return value
    }

    private static func readItem(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func write(_ account: String, value: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            lock.withLock { _ = cache.removeValue(forKey: account) }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        lock.withLock { cache[account] = .some(value) }
    }
}

extension Keychain {
    public static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        lock.withLock { cache[account] = .some(nil) }
    }
}
