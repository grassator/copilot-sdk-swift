import Foundation
import Testing
@testable import CopilotSDK

@Test func sessionEventDecodesDataPayload() throws {
    let json = """
    {
      "id": "1",
      "timestamp": "2026-01-01T00:00:00Z",
      "type": "assistant.message",
      "data": { "content": "hello" }
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder.copilot.decode(SessionEvent.self, from: json)

    #expect(event.type == "assistant.message")
    #expect(event.data["content"]?.stringValue == "hello")
}
