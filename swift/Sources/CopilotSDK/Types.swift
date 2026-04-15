import Foundation

public enum ConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case error
}

public struct TelemetryConfiguration: Sendable, Equatable {
    public var otlpEndpoint: String?
    public var filePath: String?
    public var exporterType: String?
    public var sourceName: String?
    public var captureContent: Bool?

    public init(
        otlpEndpoint: String? = nil,
        filePath: String? = nil,
        exporterType: String? = nil,
        sourceName: String? = nil,
        captureContent: Bool? = nil
    ) {
        self.otlpEndpoint = otlpEndpoint
        self.filePath = filePath
        self.exporterType = exporterType
        self.sourceName = sourceName
        self.captureContent = captureContent
    }
}

public struct SessionFileSystemConfiguration: Sendable, Equatable {
    public enum Conventions: String, Sendable, Codable {
        case posix
        case windows
    }

    public var initialCwd: String
    public var sessionStatePath: String
    public var conventions: Conventions

    public init(initialCwd: String, sessionStatePath: String, conventions: Conventions) {
        self.initialCwd = initialCwd
        self.sessionStatePath = sessionStatePath
        self.conventions = conventions
    }
}

public struct ClientOptions: Sendable {
    public var cliPath: String?
    public var cliArgs: [String]
    public var cwd: String?
    public var port: Int?
    public var useStdio: Bool?
    public var cliURL: String?
    public var logLevel: String
    public var autoStart: Bool
    public var environment: [String: String]?
    public var githubToken: String?
    public var useLoggedInUser: Bool?
    public var onListModels: (@Sendable () async throws -> [ModelInfo])?
    public var sessionFileSystem: SessionFileSystemConfiguration?
    public var telemetry: TelemetryConfiguration?

    public init(
        cliPath: String? = nil,
        cliArgs: [String] = [],
        cwd: String? = nil,
        port: Int? = nil,
        useStdio: Bool? = nil,
        cliURL: String? = nil,
        logLevel: String = "info",
        autoStart: Bool = true,
        environment: [String: String]? = nil,
        githubToken: String? = nil,
        useLoggedInUser: Bool? = nil,
        onListModels: (@Sendable () async throws -> [ModelInfo])? = nil,
        sessionFileSystem: SessionFileSystemConfiguration? = nil,
        telemetry: TelemetryConfiguration? = nil
    ) {
        self.cliPath = cliPath
        self.cliArgs = cliArgs
        self.cwd = cwd
        self.port = port
        self.useStdio = useStdio
        self.cliURL = cliURL
        self.logLevel = logLevel
        self.autoStart = autoStart
        self.environment = environment
        self.githubToken = githubToken
        self.useLoggedInUser = useLoggedInUser
        self.onListModels = onListModels
        self.sessionFileSystem = sessionFileSystem
        self.telemetry = telemetry
    }
}

public struct SectionOverride: Sendable {
    public enum Action: String, Sendable, Codable {
        case replace
        case remove
        case append
        case prepend
        case transform
    }

    public var action: Action
    public var content: String?
    public var transform: (@Sendable (String) async throws -> String)?

    public init(action: Action, content: String? = nil, transform: (@Sendable (String) async throws -> String)? = nil) {
        self.action = action
        self.content = content
        self.transform = transform
    }
}

public struct SystemMessageConfiguration: Sendable {
    public enum Mode: String, Sendable, Codable {
        case append
        case replace
        case customize
    }

    public var mode: Mode
    public var content: String?
    public var sections: [String: SectionOverride]

    public init(mode: Mode = .append, content: String? = nil, sections: [String: SectionOverride] = [:]) {
        self.mode = mode
        self.content = content
        self.sections = sections
    }
}

public struct ProviderConfiguration: Codable, Equatable, Sendable {
    public struct Azure: Codable, Equatable, Sendable {
        public var apiVersion: String?

        public init(apiVersion: String? = nil) {
            self.apiVersion = apiVersion
        }
    }

    public var type: String?
    public var wireAPI: String?
    public var baseURL: String
    public var apiKey: String?
    public var bearerToken: String?
    public var azure: Azure?

    public init(type: String? = nil, wireAPI: String? = nil, baseURL: String, apiKey: String? = nil, bearerToken: String? = nil, azure: Azure? = nil) {
        self.type = type
        self.wireAPI = wireAPI
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.bearerToken = bearerToken
        self.azure = azure
    }

    enum CodingKeys: String, CodingKey {
        case type
        case wireAPI = "wireApi"
        case baseURL = "baseUrl"
        case apiKey
        case bearerToken
        case azure
    }
}

public struct InfiniteSessionConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var backgroundCompactionThreshold: Double?
    public var bufferExhaustionThreshold: Double?

    public init(enabled: Bool? = nil, backgroundCompactionThreshold: Double? = nil, bufferExhaustionThreshold: Double? = nil) {
        self.enabled = enabled
        self.backgroundCompactionThreshold = backgroundCompactionThreshold
        self.bufferExhaustionThreshold = bufferExhaustionThreshold
    }
}

public enum MCPServerConfiguration: Encodable, Equatable, Sendable {
    public struct Stdio: Encodable, Equatable, Sendable {
        public var tools: [String]
        public var timeout: Int?
        public var command: String
        public var args: [String]
        public var environment: [String: String]?
        public var cwd: String?

        public init(tools: [String] = [], timeout: Int? = nil, command: String, args: [String] = [], environment: [String: String]? = nil, cwd: String? = nil) {
            self.tools = tools
            self.timeout = timeout
            self.command = command
            self.args = args
            self.environment = environment
            self.cwd = cwd
        }

        enum CodingKeys: String, CodingKey {
            case type
            case tools
            case timeout
            case command
            case args
            case environment = "env"
            case cwd
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("stdio", forKey: .type)
            try container.encode(tools, forKey: .tools)
            try container.encodeIfPresent(timeout, forKey: .timeout)
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encodeIfPresent(environment, forKey: .environment)
            try container.encodeIfPresent(cwd, forKey: .cwd)
        }
    }

    public struct HTTP: Encodable, Equatable, Sendable {
        public var tools: [String]
        public var timeout: Int?
        public var url: String
        public var headers: [String: String]?

        public init(tools: [String] = [], timeout: Int? = nil, url: String, headers: [String: String]? = nil) {
            self.tools = tools
            self.timeout = timeout
            self.url = url
            self.headers = headers
        }

        enum CodingKeys: String, CodingKey {
            case type
            case tools
            case timeout
            case url
            case headers
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("http", forKey: .type)
            try container.encode(tools, forKey: .tools)
            try container.encodeIfPresent(timeout, forKey: .timeout)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(headers, forKey: .headers)
        }
    }

    case stdio(Stdio)
    case http(HTTP)

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .stdio(value): try value.encode(to: encoder)
        case let .http(value): try value.encode(to: encoder)
        }
    }
}

public struct CustomAgentConfiguration: Encodable, Equatable, Sendable {
    public var name: String
    public var displayName: String?
    public var description: String?
    public var tools: [String]?
    public var prompt: String
    public var mcpServers: [String: MCPServerConfiguration]?
    public var infer: Bool?

    public init(name: String, displayName: String? = nil, description: String? = nil, tools: [String]? = nil, prompt: String, mcpServers: [String: MCPServerConfiguration]? = nil, infer: Bool? = nil) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.tools = tools
        self.prompt = prompt
        self.mcpServers = mcpServers
        self.infer = infer
    }
}

public struct Attachment: Codable, Equatable, Sendable {
    public var type: String
    public var path: String?
    public var displayName: String?
    public var lineRange: JSONObject?
    public var filePath: String?
    public var text: String?
    public var selection: JSONObject?
    public var number: Int?
    public var title: String?
    public var referenceType: String?
    public var state: String?
    public var url: String?
    public var data: String?
    public var mimeType: String?

    public init(type: String, path: String? = nil, displayName: String? = nil, lineRange: JSONObject? = nil, filePath: String? = nil, text: String? = nil, selection: JSONObject? = nil, number: Int? = nil, title: String? = nil, referenceType: String? = nil, state: String? = nil, url: String? = nil, data: String? = nil, mimeType: String? = nil) {
        self.type = type
        self.path = path
        self.displayName = displayName
        self.lineRange = lineRange
        self.filePath = filePath
        self.text = text
        self.selection = selection
        self.number = number
        self.title = title
        self.referenceType = referenceType
        self.state = state
        self.url = url
        self.data = data
        self.mimeType = mimeType
    }
}

public struct MessageOptions: Codable, Equatable, Sendable {
    public var prompt: String
    public var attachments: [Attachment]
    public var mode: String?

    public init(prompt: String, attachments: [Attachment] = [], mode: String? = nil) {
        self.prompt = prompt
        self.attachments = attachments
        self.mode = mode
    }
}

public struct PermissionRequest: Codable, Equatable, Sendable {
    public var kind: String
    public var rawValues: JSONObject

    public init(kind: String, rawValues: JSONObject = [:]) {
        self.kind = kind
        self.rawValues = rawValues
    }

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        let object = value.objectValue ?? [:]
        self.kind = object["kind"]?.stringValue ?? ""
        self.rawValues = object
    }

    public func encode(to encoder: any Encoder) throws {
        try JSONValue.object(rawValues).encode(to: encoder)
    }

    public subscript(key: String) -> JSONValue? { rawValues[key] }
}

public struct PermissionRequestResult: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case approved
        case deniedByRules = "denied-by-rules"
        case deniedNoApprovalRuleAndCouldNotRequestFromUser = "denied-no-approval-rule-and-could-not-request-from-user"
        case deniedInteractivelyByUser = "denied-interactively-by-user"
        case noResult = "no-result"
    }

    public var kind: Kind
    public var rules: [JSONValue]?

    public init(kind: Kind, rules: [JSONValue]? = nil) {
        self.kind = kind
        self.rules = rules
    }
}

public enum PermissionHandlers {
    public static let approveAll: PermissionHandler = { _, _ in
        PermissionRequestResult(kind: .approved)
    }
}

public struct UserInputRequest: Codable, Equatable, Sendable {
    public var question: String
    public var choices: [String]
    public var allowFreeform: Bool?

    public init(question: String, choices: [String] = [], allowFreeform: Bool? = nil) {
        self.question = question
        self.choices = choices
        self.allowFreeform = allowFreeform
    }
}

public struct UserInputResponse: Codable, Equatable, Sendable {
    public var answer: String
    public var wasFreeform: Bool

    public init(answer: String, wasFreeform: Bool = false) {
        self.answer = answer
        self.wasFreeform = wasFreeform
    }
}

public struct ToolBinaryResult: Codable, Equatable, Sendable {
    public var data: String
    public var mimeType: String
    public var type: String
    public var description: String?

    public init(data: String, mimeType: String, type: String, description: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.type = type
        self.description = description
    }
}

public struct ToolResult: Codable, Equatable, Sendable {
    public var textResultForLLM: String
    public var binaryResultsForLLM: [ToolBinaryResult]
    public var resultType: String?
    public var error: String?
    public var sessionLog: String?
    public var toolTelemetry: JSONObject?

    public init(textResultForLLM: String, binaryResultsForLLM: [ToolBinaryResult] = [], resultType: String? = nil, error: String? = nil, sessionLog: String? = nil, toolTelemetry: JSONObject? = nil) {
        self.textResultForLLM = textResultForLLM
        self.binaryResultsForLLM = binaryResultsForLLM
        self.resultType = resultType
        self.error = error
        self.sessionLog = sessionLog
        self.toolTelemetry = toolTelemetry
    }

    enum CodingKeys: String, CodingKey {
        case textResultForLLM = "textResultForLlm"
        case binaryResultsForLLM = "binaryResultsForLlm"
        case resultType
        case error
        case sessionLog
        case toolTelemetry
    }
}

public struct ToolInvocation: Sendable {
    public var sessionID: String
    public var toolCallID: String
    public var toolName: String
    public var arguments: JSONValue

    public init(sessionID: String, toolCallID: String, toolName: String, arguments: JSONValue) {
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.arguments = arguments
    }
}

public struct PermissionInvocation: Sendable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
}

public struct UserInputInvocation: Sendable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
}

public struct HookInvocation: Sendable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
}

public struct CommandContext: Sendable {
    public var sessionID: String
    public var command: String
    public var commandName: String
    public var args: String

    public init(sessionID: String, command: String, commandName: String, args: String) {
        self.sessionID = sessionID
        self.command = command
        self.commandName = commandName
        self.args = args
    }
}

public struct ElicitationContext: Sendable {
    public var sessionID: String
    public var message: String
    public var requestedSchema: JSONObject?
    public var mode: String?
    public var elicitationSource: String?
    public var url: String?

    public init(sessionID: String, message: String, requestedSchema: JSONObject? = nil, mode: String? = nil, elicitationSource: String? = nil, url: String? = nil) {
        self.sessionID = sessionID
        self.message = message
        self.requestedSchema = requestedSchema
        self.mode = mode
        self.elicitationSource = elicitationSource
        self.url = url
    }
}

public struct ElicitationResult: Codable, Equatable, Sendable {
    public var action: String
    public var content: JSONObject?

    public init(action: String, content: JSONObject? = nil) {
        self.action = action
        self.content = content
    }
}

public struct CommandDefinition: Sendable {
    public var name: String
    public var description: String?
    public var handler: CommandHandler?

    public init(name: String, description: String? = nil, handler: CommandHandler? = nil) {
        self.name = name
        self.description = description
        self.handler = handler
    }
}

public struct Tool: Sendable {
    public var name: String
    public var description: String?
    public var parameters: JSONObject?
    public var overridesBuiltInTool: Bool
    public var skipPermission: Bool
    public var handler: ToolHandler?

    public init(name: String, description: String? = nil, parameters: JSONObject? = nil, overridesBuiltInTool: Bool = false, skipPermission: Bool = false, handler: ToolHandler? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.overridesBuiltInTool = overridesBuiltInTool
        self.skipPermission = skipPermission
        self.handler = handler
    }
}

public enum SessionHookType: String, CaseIterable, Sendable {
    case preToolUse
    case postToolUse
    case userPromptSubmitted
    case sessionStart
    case sessionEnd
    case errorOccurred
}

public struct SessionHooks: Sendable {
    public var onPreToolUse: SessionHookHandler?
    public var onPostToolUse: SessionHookHandler?
    public var onUserPromptSubmitted: SessionHookHandler?
    public var onSessionStart: SessionHookHandler?
    public var onSessionEnd: SessionHookHandler?
    public var onErrorOccurred: SessionHookHandler?

    public init(
        onPreToolUse: SessionHookHandler? = nil,
        onPostToolUse: SessionHookHandler? = nil,
        onUserPromptSubmitted: SessionHookHandler? = nil,
        onSessionStart: SessionHookHandler? = nil,
        onSessionEnd: SessionHookHandler? = nil,
        onErrorOccurred: SessionHookHandler? = nil
    ) {
        self.onPreToolUse = onPreToolUse
        self.onPostToolUse = onPostToolUse
        self.onUserPromptSubmitted = onUserPromptSubmitted
        self.onSessionStart = onSessionStart
        self.onSessionEnd = onSessionEnd
        self.onErrorOccurred = onErrorOccurred
    }

    public var hasHandlers: Bool {
        onPreToolUse != nil || onPostToolUse != nil || onUserPromptSubmitted != nil || onSessionStart != nil || onSessionEnd != nil || onErrorOccurred != nil
    }

    func handler(for type: SessionHookType) -> SessionHookHandler? {
        switch type {
        case .preToolUse: onPreToolUse
        case .postToolUse: onPostToolUse
        case .userPromptSubmitted: onUserPromptSubmitted
        case .sessionStart: onSessionStart
        case .sessionEnd: onSessionEnd
        case .errorOccurred: onErrorOccurred
        }
    }
}

public typealias ToolHandler = @Sendable (ToolInvocation) async throws -> ToolResult
public typealias PermissionHandler = @Sendable (PermissionRequest, PermissionInvocation) async throws -> PermissionRequestResult
public typealias UserInputHandler = @Sendable (UserInputRequest, UserInputInvocation) async throws -> UserInputResponse
public typealias SessionHookHandler = @Sendable (JSONValue, HookInvocation) async throws -> JSONValue?
public typealias CommandHandler = @Sendable (CommandContext) async throws -> Void
public typealias ElicitationHandler = @Sendable (ElicitationContext) async throws -> ElicitationResult
public typealias SessionEventHandler = @Sendable (SessionEvent) -> Void
public typealias SessionFileSystemHandler = @Sendable (SessionFileSystemRequest) async throws -> JSONValue

public struct SessionFileSystemRequest: Sendable {
    public var method: String
    public var sessionID: String
    public var params: JSONValue

    public init(method: String, sessionID: String, params: JSONValue) {
        self.method = method
        self.sessionID = sessionID
        self.params = params
    }
}

public struct SessionConfiguration: Sendable {
    public var sessionID: String?
    public var clientName: String?
    public var model: String?
    public var reasoningEffort: String?
    public var configDirectory: String?
    public var enableConfigDiscovery: Bool
    public var tools: [Tool]
    public var systemMessage: SystemMessageConfiguration?
    public var availableTools: [String]
    public var excludedTools: [String]
    public var onPermissionRequest: PermissionHandler?
    public var onUserInputRequest: UserInputHandler?
    public var hooks: SessionHooks?
    public var workingDirectory: String?
    public var streaming: Bool
    public var provider: ProviderConfiguration?
    public var modelCapabilities: JSONObject?
    public var mcpServers: [String: MCPServerConfiguration]
    public var customAgents: [CustomAgentConfiguration]
    public var agent: String?
    public var skillDirectories: [String]
    public var disabledSkills: [String]
    public var infiniteSessions: InfiniteSessionConfiguration?
    public var onEvent: SessionEventHandler?
    public var sessionFileSystemHandler: SessionFileSystemHandler?
    public var commands: [CommandDefinition]
    public var onElicitationRequest: ElicitationHandler?

    public init(
        sessionID: String? = nil,
        clientName: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        configDirectory: String? = nil,
        enableConfigDiscovery: Bool = false,
        tools: [Tool] = [],
        systemMessage: SystemMessageConfiguration? = nil,
        availableTools: [String] = [],
        excludedTools: [String] = [],
        onPermissionRequest: PermissionHandler? = nil,
        onUserInputRequest: UserInputHandler? = nil,
        hooks: SessionHooks? = nil,
        workingDirectory: String? = nil,
        streaming: Bool = false,
        provider: ProviderConfiguration? = nil,
        modelCapabilities: JSONObject? = nil,
        mcpServers: [String: MCPServerConfiguration] = [:],
        customAgents: [CustomAgentConfiguration] = [],
        agent: String? = nil,
        skillDirectories: [String] = [],
        disabledSkills: [String] = [],
        infiniteSessions: InfiniteSessionConfiguration? = nil,
        onEvent: SessionEventHandler? = nil,
        sessionFileSystemHandler: SessionFileSystemHandler? = nil,
        commands: [CommandDefinition] = [],
        onElicitationRequest: ElicitationHandler? = nil
    ) {
        self.sessionID = sessionID
        self.clientName = clientName
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.configDirectory = configDirectory
        self.enableConfigDiscovery = enableConfigDiscovery
        self.tools = tools
        self.systemMessage = systemMessage
        self.availableTools = availableTools
        self.excludedTools = excludedTools
        self.onPermissionRequest = onPermissionRequest
        self.onUserInputRequest = onUserInputRequest
        self.hooks = hooks
        self.workingDirectory = workingDirectory
        self.streaming = streaming
        self.provider = provider
        self.modelCapabilities = modelCapabilities
        self.mcpServers = mcpServers
        self.customAgents = customAgents
        self.agent = agent
        self.skillDirectories = skillDirectories
        self.disabledSkills = disabledSkills
        self.infiniteSessions = infiniteSessions
        self.onEvent = onEvent
        self.sessionFileSystemHandler = sessionFileSystemHandler
        self.commands = commands
        self.onElicitationRequest = onElicitationRequest
    }
}

public struct ResumeSessionConfiguration: Sendable {
    public var clientName: String?
    public var model: String?
    public var tools: [Tool]
    public var systemMessage: SystemMessageConfiguration?
    public var availableTools: [String]
    public var excludedTools: [String]
    public var provider: ProviderConfiguration?
    public var modelCapabilities: JSONObject?
    public var reasoningEffort: String?
    public var onPermissionRequest: PermissionHandler?
    public var onUserInputRequest: UserInputHandler?
    public var hooks: SessionHooks?
    public var workingDirectory: String?
    public var configDirectory: String?
    public var enableConfigDiscovery: Bool
    public var streaming: Bool
    public var mcpServers: [String: MCPServerConfiguration]
    public var customAgents: [CustomAgentConfiguration]
    public var agent: String?
    public var skillDirectories: [String]
    public var disabledSkills: [String]
    public var infiniteSessions: InfiniteSessionConfiguration?
    public var disableResume: Bool
    public var onEvent: SessionEventHandler?
    public var sessionFileSystemHandler: SessionFileSystemHandler?
    public var commands: [CommandDefinition]
    public var onElicitationRequest: ElicitationHandler?

    public init(
        clientName: String? = nil,
        model: String? = nil,
        tools: [Tool] = [],
        systemMessage: SystemMessageConfiguration? = nil,
        availableTools: [String] = [],
        excludedTools: [String] = [],
        provider: ProviderConfiguration? = nil,
        modelCapabilities: JSONObject? = nil,
        reasoningEffort: String? = nil,
        onPermissionRequest: PermissionHandler? = nil,
        onUserInputRequest: UserInputHandler? = nil,
        hooks: SessionHooks? = nil,
        workingDirectory: String? = nil,
        configDirectory: String? = nil,
        enableConfigDiscovery: Bool = false,
        streaming: Bool = false,
        mcpServers: [String: MCPServerConfiguration] = [:],
        customAgents: [CustomAgentConfiguration] = [],
        agent: String? = nil,
        skillDirectories: [String] = [],
        disabledSkills: [String] = [],
        infiniteSessions: InfiniteSessionConfiguration? = nil,
        disableResume: Bool = false,
        onEvent: SessionEventHandler? = nil,
        sessionFileSystemHandler: SessionFileSystemHandler? = nil,
        commands: [CommandDefinition] = [],
        onElicitationRequest: ElicitationHandler? = nil
    ) {
        self.clientName = clientName
        self.model = model
        self.tools = tools
        self.systemMessage = systemMessage
        self.availableTools = availableTools
        self.excludedTools = excludedTools
        self.provider = provider
        self.modelCapabilities = modelCapabilities
        self.reasoningEffort = reasoningEffort
        self.onPermissionRequest = onPermissionRequest
        self.onUserInputRequest = onUserInputRequest
        self.hooks = hooks
        self.workingDirectory = workingDirectory
        self.configDirectory = configDirectory
        self.enableConfigDiscovery = enableConfigDiscovery
        self.streaming = streaming
        self.mcpServers = mcpServers
        self.customAgents = customAgents
        self.agent = agent
        self.skillDirectories = skillDirectories
        self.disabledSkills = disabledSkills
        self.infiniteSessions = infiniteSessions
        self.disableResume = disableResume
        self.onEvent = onEvent
        self.sessionFileSystemHandler = sessionFileSystemHandler
        self.commands = commands
        self.onElicitationRequest = onElicitationRequest
    }
}

public struct SessionEvent: Codable, Equatable, Sendable {
    public var id: String
    public var timestamp: Date
    public var parentID: String?
    public var ephemeral: Bool?
    public var type: String
    public var data: JSONValue

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case parentID = "parentId"
        case ephemeral
        case type
        case data
    }
}

public struct SessionCapabilities: Codable, Equatable, Sendable {
    public struct UI: Codable, Equatable, Sendable {
        public var elicitation: Bool?
        public init(elicitation: Bool? = nil) { self.elicitation = elicitation }
    }

    public var ui: UI?
    public init(ui: UI? = nil) { self.ui = ui }
}

public struct SessionMetadata: Codable, Equatable, Sendable {
    public var sessionID: String
    public var startTime: String
    public var modifiedTime: String
    public var summary: String?
    public var isRemote: Bool
    public var context: JSONObject?
}

public struct PingResponse: Codable, Equatable, Sendable {
    public var message: String
    public var timestamp: Int64
    public var protocolVersion: Int?
}

public struct StatusResponse: Codable, Equatable, Sendable {
    public var version: String
    public var protocolVersion: Int
}

public struct AuthStatusResponse: Codable, Equatable, Sendable {
    public var isAuthenticated: Bool
    public var authType: String?
    public var host: String?
    public var login: String?
    public var statusMessage: String?
}

public struct ModelInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var capabilities: JSONObject
    public var policy: JSONObject?
    public var billing: JSONObject?
    public var supportedReasoningEfforts: [String]?
    public var defaultReasoningEffort: String?
}

struct CreateOrResumeSessionResponse: Codable, Sendable {
    var sessionID: String
    var workspacePath: String
    var capabilities: SessionCapabilities?
}
