import Dispatch
import Foundation

public final class CopilotSession: @unchecked Sendable {
    public let sessionID: String
    public private(set) var workspacePath: String
    public private(set) var capabilities: SessionCapabilities

    private let connection: JSONRPCConnection
    private let queue: DispatchQueue
    private var eventHandlers: [UUID: SessionEventHandler] = [:]
    private var tools: [String: Tool] = [:]
    private var commands: [String: CommandDefinition] = [:]
    private var permissionHandler: PermissionHandler?
    private var userInputHandler: UserInputHandler?
    private var hooks: SessionHooks?
    private var transformCallbacks: [String: @Sendable (String) async throws -> String] = [:]
    private var sessionFileSystemHandler: SessionFileSystemHandler?
    private var elicitationHandler: ElicitationHandler?

    init(sessionID: String, workspacePath: String = "", capabilities: SessionCapabilities = SessionCapabilities(), connection: JSONRPCConnection) {
        self.sessionID = sessionID
        self.workspacePath = workspacePath
        self.capabilities = capabilities
        self.connection = connection
        self.queue = DispatchQueue(label: "CopilotSession.\(sessionID)")
    }

    func configure(from configuration: SessionConfiguration) {
        queue.sync {
            tools = Dictionary(uniqueKeysWithValues: configuration.tools.map { ($0.name, $0) })
            commands = Dictionary(uniqueKeysWithValues: configuration.commands.map { ($0.name, $0) })
            permissionHandler = configuration.onPermissionRequest
            userInputHandler = configuration.onUserInputRequest
            hooks = configuration.hooks
            sessionFileSystemHandler = configuration.sessionFileSystemHandler
            elicitationHandler = configuration.onElicitationRequest
            eventHandlers.removeAll(keepingCapacity: true)
            if let onEvent = configuration.onEvent {
                eventHandlers[UUID()] = onEvent
            }
            transformCallbacks = configuration.systemMessage?.sections.reduce(into: [:], { partialResult, item in
                if let transform = item.value.transform {
                    partialResult[item.key] = transform
                }
            }) ?? [:]
        }
    }

    func configure(from configuration: ResumeSessionConfiguration) {
        queue.sync {
            tools = Dictionary(uniqueKeysWithValues: configuration.tools.map { ($0.name, $0) })
            commands = Dictionary(uniqueKeysWithValues: configuration.commands.map { ($0.name, $0) })
            permissionHandler = configuration.onPermissionRequest
            userInputHandler = configuration.onUserInputRequest
            hooks = configuration.hooks
            sessionFileSystemHandler = configuration.sessionFileSystemHandler
            elicitationHandler = configuration.onElicitationRequest
            eventHandlers.removeAll(keepingCapacity: true)
            if let onEvent = configuration.onEvent {
                eventHandlers[UUID()] = onEvent
            }
            transformCallbacks = configuration.systemMessage?.sections.reduce(into: [:], { partialResult, item in
                if let transform = item.value.transform {
                    partialResult[item.key] = transform
                }
            }) ?? [:]
        }
    }

    func updateMetadata(workspacePath: String, capabilities: SessionCapabilities?) {
        queue.sync {
            self.workspacePath = workspacePath
            if let capabilities {
                self.capabilities = capabilities
            }
        }
    }

    public func on(_ handler: @escaping SessionEventHandler) -> @Sendable () -> Void {
        let id = UUID()
        queue.sync { eventHandlers[id] = handler }
        return { [weak self] in
            _ = self?.queue.sync { self?.eventHandlers.removeValue(forKey: id) }
        }
    }

    public func send(_ options: MessageOptions) async throws -> String {
        let result = try await request("session.send", params: [
            "sessionId": .string(sessionID),
            "prompt": .string(options.prompt),
            "attachments": .array(try options.attachments.map(JSONValue.encode)),
            "mode": options.mode.map(JSONValue.string) ?? .null,
        ])
        return result["messageId"]?.stringValue ?? ""
    }

    public func sendAndWait(_ options: MessageOptions, timeout: Duration = .seconds(60)) async throws -> SessionEvent? {
        final class Box: @unchecked Sendable { var event: SessionEvent? }
        let box = Box()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let unsubscribe = on { event in
            switch event.type {
            case "assistant.message":
                box.event = event
            case "session.idle", "session.error":
                continuation.finish()
            default:
                break
            }
        }
        defer { unsubscribe() }
        _ = try await send(options)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in stream { return } }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CopilotSDKError.timedOut("session.idle")
            }
            _ = try await group.next()
            group.cancelAll()
        }
        return box.event
    }

    public func getMessages() async throws -> [SessionEvent] {
        let result = try await request("session.getMessages", params: ["sessionId": .string(sessionID)])
        return try result["events"]?.decode([SessionEvent].self) ?? []
    }

    public func disconnect() async throws {
        _ = try await request("session.destroy", params: ["sessionId": .string(sessionID)])
        queue.sync {
            eventHandlers.removeAll()
            tools.removeAll()
            commands.removeAll()
            permissionHandler = nil
            userInputHandler = nil
            hooks = nil
            transformCallbacks.removeAll()
            sessionFileSystemHandler = nil
            elicitationHandler = nil
        }
    }

    public func abort() async throws {
        _ = try await request("session.abort", params: ["sessionId": .string(sessionID)])
    }

    public func rpc(_ method: String, params: JSONObject = [:]) async throws -> JSONValue {
        var payload = params
        payload["sessionId"] = .string(sessionID)
        return try await request(method, params: payload)
    }

    public func confirm(_ message: String) async throws -> Bool {
        let result = try await rpc("session.ui.elicitation", params: [
            "message": .string(message),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "confirmed": .object([
                        "type": .string("boolean"),
                        "default": .object(["bool": .bool(true)]),
                    ])
                ]),
                "required": .array([.string("confirmed")]),
            ]),
        ])
        return result["action"]?.stringValue == "accept" && result["content"]?["confirmed"]?["bool"]?.boolValue == true
    }

    public func select(_ message: String, options: [String]) async throws -> String? {
        let result = try await rpc("session.ui.elicitation", params: [
            "message": .string(message),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "selection": .object([
                        "type": .string("string"),
                        "enum": .array(options.map(JSONValue.string)),
                    ])
                ]),
                "required": .array([.string("selection")]),
            ]),
        ])
        guard result["action"]?.stringValue == "accept" else { return nil }
        return result["content"]?["selection"]?["string"]?.stringValue
    }

    public func input(_ message: String, title: String? = nil, description: String? = nil, defaultValue: String? = nil) async throws -> String? {
        var field: JSONObject = ["type": .string("string")]
        if let title { field["title"] = .string(title) }
        if let description { field["description"] = .string(description) }
        if let defaultValue { field["default"] = .string(defaultValue) }
        let result = try await rpc("session.ui.elicitation", params: [
            "message": .string(message),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object(["value": .object(field)]),
                "required": .array([.string("value")]),
            ]),
        ])
        guard result["action"]?.stringValue == "accept" else { return nil }
        return result["content"]?["value"]?["string"]?.stringValue
    }

    func dispatch(_ event: SessionEvent) {
        handleBroadcastEvent(event)
        let handlers = queue.sync { Array(eventHandlers.values) }
        handlers.forEach { $0(event) }
    }

    func handleUserInputRequest(_ request: UserInputRequest) async throws -> UserInputResponse {
        let handler = queue.sync { userInputHandler }
        guard let handler else {
            throw CopilotSDKError.unsupportedFeature("No user input handler registered.")
        }
        return try await handler(request, UserInputInvocation(sessionID: sessionID))
    }

    func handleHook(type: SessionHookType, input: JSONValue) async throws -> JSONValue? {
        let handler = queue.sync { hooks?.handler(for: type) }
        return try await handler?(input, HookInvocation(sessionID: sessionID))
    }

    func handleSystemMessageTransform(_ sections: JSONObject) async -> JSONObject {
        let callbacks = queue.sync { transformCallbacks }
        var transformed: JSONObject = [:]
        for (sectionID, value) in sections {
            let currentContent = value["content"]?.stringValue ?? ""
            if let callback = callbacks[sectionID], let updated = try? await callback(currentContent) {
                transformed[sectionID] = .object(["content": .string(updated)])
            } else {
                transformed[sectionID] = .object(["content": .string(currentContent)])
            }
        }
        return transformed
    }

    func handleSessionFileSystemRequest(method: String, params: JSONValue) async throws -> JSONValue {
        let handler = queue.sync { sessionFileSystemHandler }
        guard let handler else {
            throw CopilotSDKError.unsupportedFeature("No session filesystem handler registered.")
        }
        return try await handler(SessionFileSystemRequest(method: method, sessionID: sessionID, params: params))
    }

    func runLegacyTool(_ invocation: ToolInvocation) async throws -> ToolResult {
        let handler = queue.sync { tools[invocation.toolName]?.handler }
        guard let handler else {
            return ToolResult(textResultForLLM: "Tool '\(invocation.toolName)' is not supported by this client instance.", resultType: "failure", error: "tool '\(invocation.toolName)' not supported", toolTelemetry: [:])
        }
        return try await handler(invocation)
    }

    func runLegacyPermission(_ request: PermissionRequest) async throws -> PermissionRequestResult {
        let handler = queue.sync { permissionHandler }
        guard let handler else {
            return PermissionRequestResult(kind: .deniedNoApprovalRuleAndCouldNotRequestFromUser)
        }
        return try await handler(request, PermissionInvocation(sessionID: sessionID))
    }

    private func handleBroadcastEvent(_ event: SessionEvent) {
        switch event.type {
        case "external_tool.requested":
            guard
                let requestID = event.data["requestId"]?.stringValue,
                let toolName = event.data["toolName"]?.stringValue,
                let toolCallID = event.data["toolCallId"]?.stringValue
            else { return }
            let arguments = event.data["arguments"] ?? .object([:])
            Task {
                do {
                    let result = try await runLegacyTool(ToolInvocation(sessionID: sessionID, toolCallID: toolCallID, toolName: toolName, arguments: arguments))
                    var toolCallResult = try JSONValue.encode(result).objectValue ?? [:]
                    if toolCallResult["resultType"] == nil {
                        toolCallResult["resultType"] = .string(result.error == nil ? "success" : "failure")
                    }
                    _ = try await request("session.tools.handlePendingToolCall", params: [
                        "sessionId": .string(sessionID),
                        "requestId": .string(requestID),
                        "result": .object(["toolCallResult": .object(toolCallResult)]),
                    ])
                } catch {
                    _ = try? await request("session.tools.handlePendingToolCall", params: [
                        "sessionId": .string(sessionID),
                        "requestId": .string(requestID),
                        "error": .string(String(describing: error)),
                    ])
                }
            }
        case "permission.requested":
            guard let requestID = event.data["requestId"]?.stringValue, let permissionPayload = event.data["permissionRequest"] else { return }
            if event.data["resolvedByHook"]?.boolValue == true { return }
            Task {
                do {
                    let permissionRequest = try permissionPayload.decode(PermissionRequest.self)
                    let decision = try await runLegacyPermission(permissionRequest)
                    if decision.kind == .noResult { return }
                    _ = try await request("session.permissions.handlePendingPermissionRequest", params: [
                        "sessionId": .string(sessionID),
                        "requestId": .string(requestID),
                        "result": try JSONValue.encode(decision),
                    ])
                } catch {
                    _ = try? await request("session.permissions.handlePendingPermissionRequest", params: [
                        "sessionId": .string(sessionID),
                        "requestId": .string(requestID),
                        "result": .object(["kind": .string(PermissionRequestResult.Kind.deniedNoApprovalRuleAndCouldNotRequestFromUser.rawValue)]),
                    ])
                }
            }
        case "command.execute":
            guard let requestID = event.data["requestId"]?.stringValue, let commandName = event.data["commandName"]?.stringValue else { return }
            let command = queue.sync { commands[commandName] }
            guard let handler = command?.handler else { return }
            let commandText = event.data["command"]?.stringValue ?? "/\(commandName)"
            let args = event.data["args"]?.stringValue ?? ""
            Task {
                do {
                    try await handler(CommandContext(sessionID: sessionID, command: commandText, commandName: commandName, args: args))
                    _ = try await request("session.commands.handlePendingCommand", params: [
                        "sessionId": .string(sessionID),
                        "requestId": .string(requestID),
                    ])
                } catch {
                    _ = try? await request("session.commands.handlePendingCommand", params: [
                        "sessionId": .string(sessionID),
                        "requestId": .string(requestID),
                        "error": .string(String(describing: error)),
                    ])
                }
            }
        case "elicitation.requested":
            guard let requestID = event.data["requestId"]?.stringValue, let message = event.data["message"]?.stringValue else { return }
            let handler = queue.sync { elicitationHandler }
            guard let handler else { return }
            Task {
                do {
                    let result = try await handler(ElicitationContext(
                        sessionID: sessionID,
                        message: message,
                        requestedSchema: event.data["requestedSchema"]?.objectValue,
                        mode: event.data["mode"]?.stringValue,
                        elicitationSource: event.data["elicitationSource"]?.stringValue,
                        url: event.data["url"]?.stringValue
                    ))
                    _ = try await request("session.ui.handlePendingElicitation", params: [
                        "sessionId": .string(sessionID),
                        "requestId": .string(requestID),
                        "result": try JSONValue.encode(result),
                    ])
                } catch {
                    _ = try? await request("session.ui.handlePendingElicitation", params: [
                        "sessionId": .string(sessionID),
                        "requestId": .string(requestID),
                        "result": .object(["action": .string("cancel")]),
                    ])
                }
            }
        case "capabilities.changed":
            queue.sync { capabilities = SessionCapabilities(ui: SessionCapabilities.UI(elicitation: event.data["ui"]?["elicitation"]?.boolValue)) }
        default:
            break
        }
    }

    private func request(_ method: String, params: JSONObject) async throws -> JSONValue {
        try await connection.request(method, params: .object(params))
    }
}
