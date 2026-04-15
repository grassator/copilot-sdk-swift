import CopilotSDK
import Foundation

@main
struct ChatSample {
    static func main() async throws {
        let client = CopilotClient()
        let session = try await client.createSession(SessionConfiguration(
            model: "gpt-4.1",
            onPermissionRequest: PermissionHandlers.approveAll
        ))
        defer { Task { try? await client.stop() } }

        if let response = try await session.sendAndWait(MessageOptions(prompt: "What is 2 + 2?")),
           let content = response.data["content"]?.stringValue {
            print(content)
        }
    }
}
