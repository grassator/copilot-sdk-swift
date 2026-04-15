# Copilot Swift SDK

Swift SDK for programmatic control of GitHub Copilot CLI via JSON-RPC.

## Features

- Async/await native API
- stdio and TCP transports
- Session create/resume/list/delete helpers
- Streaming session event subscriptions
- Custom tools, permissions, user input, hooks, commands, and elicitation callbacks
- MCP, skills, custom agents, BYOK provider config, infinite sessions, telemetry, and session filesystem support
- Generic session RPC access for advanced APIs

## Quick start

```swift
import CopilotSDK

let client = CopilotClient()
let session = try await client.createSession(SessionConfiguration(
    model: "gpt-4.1",
    onPermissionRequest: PermissionHandlers.approveAll
))

let response = try await session.sendAndWait(MessageOptions(prompt: "What is 2 + 2?"))
print(response?.data["content"]?.stringValue ?? "")

try await client.stop()
```

## Build and test

```bash
cd swift
swift test
swift build
```
