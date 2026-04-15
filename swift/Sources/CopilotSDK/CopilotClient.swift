import Dispatch
import Foundation

public final class CopilotClient: @unchecked Sendable {
    private let minimumProtocolVersion = 2
    private let maximumProtocolVersion = 3

    public private(set) var state: ConnectionState = .disconnected
    public private(set) var actualPort: Int?

    private let options: ClientOptions
    private var process: Process?
    private var connection: JSONRPCConnection?
    private var sessions: [String: CopilotSession] = [:]
    private var modelsCache: [ModelInfo]?
    private var lifecycleHandlers: [UUID: @Sendable (JSONValue) -> Void] = [:]
    private let queue = DispatchQueue(label: "CopilotClient.state")

    public init(options: ClientOptions = ClientOptions()) {
        self.options = options
    }

    public func start() async throws {
        if state == .connected { return }
        state = .connecting
        do {
            let handles: (reader: FileHandle, writer: FileHandle)
            if let cliURL = options.cliURL {
                let parsed = try Self.parseCLIURL(cliURL)
                actualPort = parsed.port
                let connected = try TCPConnector.connect(host: parsed.host, port: parsed.port)
                handles = (connected.reader, connected.writer)
            } else {
                handles = try startSubprocess()
            }

            let connection = JSONRPCConnection(reader: handles.reader, writer: handles.writer) { [weak self] in
                self?.state = .disconnected
            }
            self.connection = connection
            await registerHandlers(on: connection)
            await connection.start()
            try await verifyProtocolVersion()
            if let sessionFileSystem = options.sessionFileSystem {
                _ = try await connection.request("sessionFs.setProvider", params: .object([
                    "initialCwd": .string(sessionFileSystem.initialCwd),
                    "sessionStatePath": .string(sessionFileSystem.sessionStatePath),
                    "conventions": .string(sessionFileSystem.conventions.rawValue),
                ]))
            }
            state = .connected
        } catch {
            state = .error
            throw error
        }
    }

    public func stop() async throws {
        let currentConnection = connection
        connection = nil
        let activeSessions = queue.sync { Array(sessions.values) }
        queue.sync {
            sessions.removeAll()
            lifecycleHandlers.removeAll()
            modelsCache = nil
        }
        for session in activeSessions {
            try? await session.disconnect()
        }
        await currentConnection?.stop()
        if let process {
            if process.isRunning { process.terminate() }
            self.process = nil
        }
        actualPort = nil
        state = .disconnected
    }

    public func onLifecycle(_ handler: @escaping @Sendable (JSONValue) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        queue.sync { lifecycleHandlers[id] = handler }
        return { [weak self] in
            _ = self?.queue.sync { self?.lifecycleHandlers.removeValue(forKey: id) }
        }
    }

    public func createSession(_ configuration: SessionConfiguration) async throws -> CopilotSession {
        guard configuration.onPermissionRequest != nil else { throw CopilotSDKError.missingPermissionHandler }
        if options.sessionFileSystem != nil, configuration.sessionFileSystemHandler == nil {
            throw CopilotSDKError.missingSessionFileSystemHandler
        }
        try await ensureConnected()
        guard let connection else { throw CopilotSDKError.clientNotConnected }
        let sessionID = configuration.sessionID ?? UUID().uuidString.lowercased()
        let session = CopilotSession(sessionID: sessionID, connection: connection)
        session.configure(from: configuration)
        queue.sync { sessions[sessionID] = session }
        do {
            let response = try await connection.request("session.create", params: .object(buildCreateSessionPayload(sessionID: sessionID, configuration: configuration)))
            let decoded = try response.decode(CreateOrResumeSessionResponse.self)
            session.updateMetadata(workspacePath: decoded.workspacePath, capabilities: decoded.capabilities)
            return session
        } catch {
            _ = queue.sync { sessions.removeValue(forKey: sessionID) }
            throw error
        }
    }

    public func resumeSession(id sessionID: String, configuration: ResumeSessionConfiguration) async throws -> CopilotSession {
        guard configuration.onPermissionRequest != nil else { throw CopilotSDKError.missingPermissionHandler }
        if options.sessionFileSystem != nil, configuration.sessionFileSystemHandler == nil {
            throw CopilotSDKError.missingSessionFileSystemHandler
        }
        try await ensureConnected()
        guard let connection else { throw CopilotSDKError.clientNotConnected }
        let session = CopilotSession(sessionID: sessionID, connection: connection)
        session.configure(from: configuration)
        queue.sync { sessions[sessionID] = session }
        do {
            let response = try await connection.request("session.resume", params: .object(buildResumeSessionPayload(sessionID: sessionID, configuration: configuration)))
            let decoded = try response.decode(CreateOrResumeSessionResponse.self)
            session.updateMetadata(workspacePath: decoded.workspacePath, capabilities: decoded.capabilities)
            return session
        } catch {
            _ = queue.sync { sessions.removeValue(forKey: sessionID) }
            throw error
        }
    }

    public func listSessions(filter: JSONObject? = nil) async throws -> [SessionMetadata] {
        let result = try await request("session.list", params: filter.map { ["filter": .object($0)] } ?? [:])
        return try result["sessions"]?.decode([SessionMetadata].self) ?? []
    }

    public func getSessionMetadata(id: String) async throws -> SessionMetadata? {
        let result = try await request("session.getMetadata", params: ["sessionId": .string(id)])
        return try result["session"]?.decode(SessionMetadata.self)
    }

    public func deleteSession(id: String) async throws -> Bool {
        let result = try await request("session.delete", params: ["sessionId": .string(id)])
        return result["success"]?.boolValue ?? false
    }

    public func getLastSessionID() async throws -> String? {
        let result = try await request("session.getLastId")
        return result["sessionId"]?.stringValue
    }

    public func getForegroundSessionID() async throws -> String? {
        let result = try await request("session.getForeground")
        return result["sessionId"]?.stringValue
    }

    public func setForegroundSessionID(_ sessionID: String) async throws -> Bool {
        let result = try await request("session.setForeground", params: ["sessionId": .string(sessionID)])
        return result["success"]?.boolValue ?? false
    }

    public func ping(_ message: String = "") async throws -> PingResponse {
        try await request("ping", params: ["message": .string(message)]).decode(PingResponse.self)
    }

    public func getStatus() async throws -> StatusResponse {
        try await request("status.get").decode(StatusResponse.self)
    }

    public func getAuthStatus() async throws -> AuthStatusResponse {
        try await request("auth.getStatus").decode(AuthStatusResponse.self)
    }

    public func listModels() async throws -> [ModelInfo] {
        if let models = queue.sync(execute: { modelsCache }) { return models }
        if let onListModels = options.onListModels {
            let models = try await onListModels()
            queue.sync { modelsCache = models }
            return models
        }
        let result = try await request("models.list")
        let models = try result["models"]?.decode([ModelInfo].self) ?? []
        queue.sync { modelsCache = models }
        return models
    }

    private func ensureConnected() async throws {
        if connection != nil { return }
        if options.autoStart {
            try await start()
        } else {
            throw CopilotSDKError.clientNotConnected
        }
    }

    private func request(_ method: String, params: JSONObject = [:]) async throws -> JSONValue {
        try await ensureConnected()
        guard let connection else { throw CopilotSDKError.clientNotConnected }
        return try await connection.request(method, params: params.isEmpty ? nil : .object(params))
    }

    private func verifyProtocolVersion() async throws {
        let ping = try await ping()
        guard let version = ping.protocolVersion else {
            throw CopilotSDKError.unsupportedProtocolVersion(server: nil, supported: minimumProtocolVersion...maximumProtocolVersion)
        }
        guard (minimumProtocolVersion...maximumProtocolVersion).contains(version) else {
            throw CopilotSDKError.unsupportedProtocolVersion(server: version, supported: minimumProtocolVersion...maximumProtocolVersion)
        }
    }

    private func registerHandlers(on connection: JSONRPCConnection) async {
        await connection.registerNotificationHandler("session.event") { [weak self] params in
            guard let self, let params, let sessionID = params["sessionId"]?.stringValue, let eventValue = params["event"] else { return }
            guard let event = try? eventValue.decode(SessionEvent.self) else { return }
            let session = self.queue.sync { self.sessions[sessionID] }
            session?.dispatch(event)
        }
        await connection.registerNotificationHandler("session.lifecycle") { [weak self] params in
            guard let self, let params else { return }
            let handlers = self.queue.sync { Array(self.lifecycleHandlers.values) }
            handlers.forEach { $0(params) }
        }
        await connection.registerRequestHandler("tool.call") { [weak self] params in
            guard let self, let params, let sessionID = params["sessionId"]?.stringValue, let toolName = params["toolName"]?.stringValue, let toolCallID = params["toolCallId"]?.stringValue else {
                throw CopilotSDKError.invalidResponse("Invalid tool.call request")
            }
            guard let session = self.queue.sync(execute: { self.sessions[sessionID] }) else {
                throw CopilotSDKError.invalidResponse("Unknown session \(sessionID)")
            }
            let result = try await session.runLegacyTool(ToolInvocation(sessionID: sessionID, toolCallID: toolCallID, toolName: toolName, arguments: params["arguments"] ?? .object([:])))
            return .object(["result": try JSONValue.encode(result)])
        }
        await connection.registerRequestHandler("permission.request") { [weak self] params in
            guard let self, let params, let sessionID = params["sessionId"]?.stringValue, let requestValue = params["permissionRequest"] else {
                throw CopilotSDKError.invalidResponse("Invalid permission.request payload")
            }
            guard let session = self.queue.sync(execute: { self.sessions[sessionID] }) else {
                throw CopilotSDKError.invalidResponse("Unknown session \(sessionID)")
            }
            let result = try await session.runLegacyPermission(try requestValue.decode(PermissionRequest.self))
            if result.kind == .noResult {
                throw CopilotSDKError.unsupportedFeature("permission handlers cannot return 'no-result' when connected to a protocol v2 server")
            }
            return .object(["result": try JSONValue.encode(result)])
        }
        await connection.registerRequestHandler("userInput.request") { [weak self] params in
            guard let self, let params, let sessionID = params["sessionId"]?.stringValue else {
                throw CopilotSDKError.invalidResponse("Invalid userInput.request payload")
            }
            guard let session = self.queue.sync(execute: { self.sessions[sessionID] }) else {
                throw CopilotSDKError.invalidResponse("Unknown session \(sessionID)")
            }
            let request = try JSONValue.object([
                "question": params["question"] ?? .string(""),
                "choices": params["choices"] ?? .array([]),
                "allowFreeform": params["allowFreeform"] ?? .null,
            ]).decode(UserInputRequest.self)
            return try JSONValue.encode(try await session.handleUserInputRequest(request))
        }
        await connection.registerRequestHandler("hooks.invoke") { [weak self] params in
            guard let self, let params, let sessionID = params["sessionId"]?.stringValue, let typeName = params["hookType"]?.stringValue, let hookType = SessionHookType(rawValue: typeName) else {
                throw CopilotSDKError.invalidResponse("Invalid hooks.invoke payload")
            }
            guard let session = self.queue.sync(execute: { self.sessions[sessionID] }) else {
                throw CopilotSDKError.invalidResponse("Unknown session \(sessionID)")
            }
            let output = try await session.handleHook(type: hookType, input: params["input"] ?? .object([:]))
            return .object(output.map { ["output": $0] } ?? [:])
        }
        await connection.registerRequestHandler("systemMessage.transform") { [weak self] params in
            guard let self, let params, let sessionID = params["sessionId"]?.stringValue, let sections = params["sections"]?.objectValue else {
                throw CopilotSDKError.invalidResponse("Invalid systemMessage.transform payload")
            }
            guard let session = self.queue.sync(execute: { self.sessions[sessionID] }) else {
                throw CopilotSDKError.invalidResponse("Unknown session \(sessionID)")
            }
            return .object(["sections": .object(await session.handleSystemMessageTransform(sections))])
        }
        for method in [
            "sessionFs.readFile", "sessionFs.writeFile", "sessionFs.appendFile", "sessionFs.exists", "sessionFs.stat",
            "sessionFs.mkdir", "sessionFs.readdir", "sessionFs.readdirWithTypes", "sessionFs.rm", "sessionFs.rename",
        ] {
            await connection.registerRequestHandler(method) { [weak self] params in
                guard let self, let params, let sessionID = params["sessionId"]?.stringValue else {
                    throw CopilotSDKError.invalidResponse("Invalid \(method) payload")
                }
                guard let session = self.queue.sync(execute: { self.sessions[sessionID] }) else {
                    throw CopilotSDKError.invalidResponse("Unknown session \(sessionID)")
                }
                return try await session.handleSessionFileSystemRequest(method: method, params: params)
            }
        }
    }

    private func startSubprocess() throws -> (reader: FileHandle, writer: FileHandle) {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = options.cwd.map(URL.init(fileURLWithPath:))

        let cliPath = options.cliPath ?? ProcessInfo.processInfo.environment["COPILOT_CLI_PATH"] ?? "copilot"
        if cliPath.hasSuffix(".js") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", cliPath] + buildCLIArguments()
        } else {
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = buildCLIArguments()
        }

        var environment = ProcessInfo.processInfo.environment
        options.environment?.forEach { environment[$0.key] = $0.value }
        if let githubToken = options.githubToken {
            environment["COPILOT_SDK_AUTH_TOKEN"] = githubToken
        }
        if let telemetry = options.telemetry {
            environment["COPILOT_OTEL_ENABLED"] = "true"
            if let value = telemetry.otlpEndpoint { environment["OTEL_EXPORTER_OTLP_ENDPOINT"] = value }
            if let value = telemetry.filePath { environment["COPILOT_OTEL_FILE_EXPORTER_PATH"] = value }
            if let value = telemetry.exporterType { environment["COPILOT_OTEL_EXPORTER_TYPE"] = value }
            if let value = telemetry.sourceName { environment["COPILOT_OTEL_SOURCE_NAME"] = value }
            if let value = telemetry.captureContent { environment["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] = value ? "true" : "false" }
        }
        process.environment = environment
        try process.run()
        self.process = process
        actualPort = options.port
        return (stdout.fileHandleForReading, stdin.fileHandleForWriting)
    }

    private func buildCLIArguments() -> [String] {
        var arguments = options.cliArgs
        arguments.append(contentsOf: ["--headless", "--no-auto-update", "--log-level", options.logLevel])
        if resolvedUseStdio {
            arguments.append("--stdio")
        } else if let port = options.port {
            arguments.append(contentsOf: ["--port", String(port)])
        }
        if options.githubToken != nil {
            arguments.append(contentsOf: ["--auth-token-env", "COPILOT_SDK_AUTH_TOKEN"])
        }
        let useLoggedInUser = options.useLoggedInUser ?? (options.githubToken == nil)
        if !useLoggedInUser {
            arguments.append("--no-auto-login")
        }
        return arguments
    }

    private var resolvedUseStdio: Bool {
        if options.cliURL != nil { return false }
        if let useStdio = options.useStdio { return useStdio }
        return options.port == nil
    }

    private static func parseCLIURL(_ value: String) throws -> (host: String, port: Int) {
        let trimmed = value.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
        let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        let host: String
        let portString: String
        if parts.count == 1 {
            host = "localhost"
            portString = parts[0]
        } else {
            host = parts[0].isEmpty ? "localhost" : parts[0]
            portString = parts[1]
        }
        guard let port = Int(portString), (1...65535).contains(port) else {
            throw CopilotSDKError.invalidCLIURL(value)
        }
        return (host, port)
    }

    private func buildCreateSessionPayload(sessionID: String, configuration: SessionConfiguration) -> JSONObject {
        var payload: JSONObject = [
            "sessionId": .string(sessionID),
            "availableTools": .array(configuration.availableTools.map(JSONValue.string)),
            "excludedTools": .array(configuration.excludedTools.map(JSONValue.string)),
            "customAgents": .array(tryOrEmpty(configuration.customAgents)),
            "skillDirectories": .array(configuration.skillDirectories.map(JSONValue.string)),
            "disabledSkills": .array(configuration.disabledSkills.map(JSONValue.string)),
            "commands": .array(configuration.commands.map {
                .object(["name": .string($0.name), "description": $0.description.map(JSONValue.string) ?? .null])
            }),
            "envValueMode": .string("direct"),
            "requestPermission": .bool(true),
        ]
        applySharedSessionFields(&payload,
                                 clientName: configuration.clientName,
                                 model: configuration.model,
                                 reasoningEffort: configuration.reasoningEffort,
                                 configDirectory: configuration.configDirectory,
                                 enableConfigDiscovery: configuration.enableConfigDiscovery,
                                 tools: configuration.tools,
                                 systemMessage: configuration.systemMessage,
                                 workingDirectory: configuration.workingDirectory,
                                 streaming: configuration.streaming,
                                 provider: configuration.provider,
                                 modelCapabilities: configuration.modelCapabilities,
                                 mcpServers: configuration.mcpServers,
                                 agent: configuration.agent,
                                 infiniteSessions: configuration.infiniteSessions,
                                 requestUserInput: configuration.onUserInputRequest != nil,
                                 requestHooks: configuration.hooks?.hasHandlers == true,
                                 requestElicitation: configuration.onElicitationRequest != nil)
        return payload
    }

    private func buildResumeSessionPayload(sessionID: String, configuration: ResumeSessionConfiguration) -> JSONObject {
        var payload: JSONObject = [
            "sessionId": .string(sessionID),
            "availableTools": .array(configuration.availableTools.map(JSONValue.string)),
            "excludedTools": .array(configuration.excludedTools.map(JSONValue.string)),
            "customAgents": .array(tryOrEmpty(configuration.customAgents)),
            "skillDirectories": .array(configuration.skillDirectories.map(JSONValue.string)),
            "disabledSkills": .array(configuration.disabledSkills.map(JSONValue.string)),
            "commands": .array(configuration.commands.map {
                .object(["name": .string($0.name), "description": $0.description.map(JSONValue.string) ?? .null])
            }),
            "envValueMode": .string("direct"),
            "requestPermission": .bool(true),
        ]
        if configuration.disableResume { payload["disableResume"] = .bool(true) }
        applySharedSessionFields(&payload,
                                 clientName: configuration.clientName,
                                 model: configuration.model,
                                 reasoningEffort: configuration.reasoningEffort,
                                 configDirectory: configuration.configDirectory,
                                 enableConfigDiscovery: configuration.enableConfigDiscovery,
                                 tools: configuration.tools,
                                 systemMessage: configuration.systemMessage,
                                 workingDirectory: configuration.workingDirectory,
                                 streaming: configuration.streaming,
                                 provider: configuration.provider,
                                 modelCapabilities: configuration.modelCapabilities,
                                 mcpServers: configuration.mcpServers,
                                 agent: configuration.agent,
                                 infiniteSessions: configuration.infiniteSessions,
                                 requestUserInput: configuration.onUserInputRequest != nil,
                                 requestHooks: configuration.hooks?.hasHandlers == true,
                                 requestElicitation: configuration.onElicitationRequest != nil)
        return payload
    }

    private func applySharedSessionFields(_ payload: inout JSONObject, clientName: String?, model: String?, reasoningEffort: String?, configDirectory: String?, enableConfigDiscovery: Bool, tools: [Tool], systemMessage: SystemMessageConfiguration?, workingDirectory: String?, streaming: Bool, provider: ProviderConfiguration?, modelCapabilities: JSONObject?, mcpServers: [String: MCPServerConfiguration], agent: String?, infiniteSessions: InfiniteSessionConfiguration?, requestUserInput: Bool, requestHooks: Bool, requestElicitation: Bool) {
        if let clientName { payload["clientName"] = .string(clientName) }
        if let model { payload["model"] = .string(model) }
        if let reasoningEffort { payload["reasoningEffort"] = .string(reasoningEffort) }
        if let configDirectory { payload["configDir"] = .string(configDirectory) }
        if enableConfigDiscovery { payload["enableConfigDiscovery"] = .bool(true) }
        if !tools.isEmpty {
            payload["tools"] = .array(tools.map {
                .object([
                    "name": .string($0.name),
                    "description": $0.description.map(JSONValue.string) ?? .null,
                    "parameters": $0.parameters.map(JSONValue.object) ?? .null,
                    "overridesBuiltInTool": .bool($0.overridesBuiltInTool),
                    "skipPermission": .bool($0.skipPermission),
                ])
            })
        }
        if let systemMessage { payload["systemMessage"] = .object(systemMessagePayload(systemMessage)) }
        if let workingDirectory { payload["workingDirectory"] = .string(workingDirectory) }
        if streaming { payload["streaming"] = .bool(true) }
        if let provider, let encoded = try? JSONValue.encode(provider) { payload["provider"] = encoded }
        if let modelCapabilities { payload["modelCapabilities"] = .object(modelCapabilities) }
        if !mcpServers.isEmpty {
            payload["mcpServers"] = .object(Dictionary(uniqueKeysWithValues: mcpServers.map { ($0.key, (try? JSONValue.encode($0.value)) ?? .null) }))
        }
        if let agent { payload["agent"] = .string(agent) }
        if let infiniteSessions, let encoded = try? JSONValue.encode(infiniteSessions) { payload["infiniteSessions"] = encoded }
        if requestUserInput { payload["requestUserInput"] = .bool(true) }
        if requestHooks { payload["hooks"] = .bool(true) }
        if requestElicitation { payload["requestElicitation"] = .bool(true) }
    }

    private func systemMessagePayload(_ configuration: SystemMessageConfiguration) -> JSONObject {
        var payload: JSONObject = ["mode": .string(configuration.mode.rawValue)]
        if let content = configuration.content { payload["content"] = .string(content) }
        if !configuration.sections.isEmpty {
            payload["sections"] = .object(Dictionary(uniqueKeysWithValues: configuration.sections.map { key, value in
                var object: JSONObject = ["action": .string(value.transform == nil ? value.action.rawValue : SectionOverride.Action.transform.rawValue)]
                if let content = value.content { object["content"] = .string(content) }
                return (key, .object(object))
            }))
        }
        return payload
    }

    private func tryOrEmpty<T: Encodable>(_ values: [T]) -> [JSONValue] {
        values.compactMap { try? JSONValue.encode($0) }
    }
}
