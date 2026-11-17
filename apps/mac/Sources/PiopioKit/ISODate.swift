import Foundation

/// The engine's ISO times, parsed with shared styles (a new ISO8601DateFormatter per call cost ~0.3 ms,
/// and the sidebar parses one per session on every refresh).
public enum ISODate {
    private static let precise = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    /// With or without fractional seconds; nil when empty or not ISO.
    public static func parse(_ iso: String) -> Date? {
        guard !iso.isEmpty else { return nil }
        return (try? precise.parse(iso)) ?? (try? plain.parse(iso))
    }
}
