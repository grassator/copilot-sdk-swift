import Foundation
import Testing
@testable import CopilotSDK

@Test func jsonValueRoundTripsNestedObjects() throws {
    let original: JSONValue = .object([
        "name": .string("copilot"),
        "enabled": .bool(true),
        "items": .array([.number(1), .object(["nested": .string("value")])]),
    ])

    let encoded = try JSONEncoder.copilot.encode(original)
    let decoded = try JSONDecoder.copilot.decode(JSONValue.self, from: encoded)

    #expect(decoded == original)
}
