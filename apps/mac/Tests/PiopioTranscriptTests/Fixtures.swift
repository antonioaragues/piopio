import Foundation
@testable import PiopioKit

extension ToolDetails {
    /// A fixture's details written as the engine sends them, read with the protocol's own decoder (so a fixture the
    /// schema doesn't allow fails here, as it would in the app).
    static func decoded(_ json: JSONValue) -> ToolDetails {
        do { return try JSONDecoder().decode(ToolDetails.self, from: JSONEncoder().encode(json)) } catch { fatalError("Not a ToolDetails: \(error)") }
    }
}
