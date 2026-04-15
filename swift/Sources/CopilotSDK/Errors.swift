import Foundation

public enum CopilotSDKError: Error, LocalizedError, Sendable {
    case clientNotConnected
    case invalidCLIURL(String)
    case missingPermissionHandler
    case missingSessionFileSystemHandler
    case unsupportedProtocolVersion(server: Int?, supported: ClosedRange<Int>)
    case connectionClosed
    case rpcError(code: Int, message: String)
    case invalidResponse(String)
    case timedOut(String)
    case unsupportedFeature(String)

    public var errorDescription: String? {
        switch self {
        case .clientNotConnected:
            return "Client not connected. Call start() first or enable autoStart."
        case let .invalidCLIURL(value):
            return "Invalid cliURL: \(value)"
        case .missingPermissionHandler:
            return "A permission handler is required when creating or resuming a session."
        case .missingSessionFileSystemHandler:
            return "A session filesystem handler is required when session filesystem support is enabled."
        case let .unsupportedProtocolVersion(server, supported):
            if let server {
                return "SDK protocol version mismatch: SDK supports versions \(supported.lowerBound)-\(supported.upperBound), server reports \(server)."
            }
            return "SDK protocol version mismatch: server did not report a protocol version. Supported versions: \(supported.lowerBound)-\(supported.upperBound)."
        case .connectionClosed:
            return "Connection closed."
        case let .rpcError(code, message):
            return "RPC error \(code): \(message)"
        case let .invalidResponse(message):
            return "Invalid response: \(message)"
        case let .timedOut(operation):
            return "Timed out while waiting for \(operation)."
        case let .unsupportedFeature(message):
            return message
        }
    }
}
