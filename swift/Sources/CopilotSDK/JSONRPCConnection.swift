import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum JSONRPCID: Hashable, Sendable {
    case int(Int)
    case string(String)

    var jsonValue: JSONValue {
        switch self {
        case let .int(value): .number(Double(value))
        case let .string(value): .string(value)
        }
    }

    init?(_ value: JSONValue) {
        if let intValue = value.intValue {
            self = .int(intValue)
        } else if let stringValue = value.stringValue {
            self = .string(stringValue)
        } else {
            return nil
        }
    }
}

private struct JSONRPCErrorPayload: Codable, Sendable {
    let code: Int
    let message: String
}

private struct PortSelectionError: Error {}

actor JSONRPCConnection {
    typealias RequestHandler = @Sendable (JSONValue?) async throws -> JSONValue?
    typealias NotificationHandler = @Sendable (JSONValue?) async -> Void

    private let reader: FileHandle
    private let writer: FileHandle
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var requestHandlers: [String: RequestHandler] = [:]
    private var notificationHandlers: [String: NotificationHandler] = [:]
    private var nextID = 1
    private var readTask: Task<Void, Never>?
    private var isClosed = false
    private let onClose: @Sendable () -> Void

    init(reader: FileHandle, writer: FileHandle, onClose: @escaping @Sendable () -> Void) {
        self.reader = reader
        self.writer = writer
        self.onClose = onClose
    }

    func start() {
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            guard let self else { return }
            await self.runReadLoop()
        }
    }

    func stop() async {
        if isClosed { return }
        isClosed = true
        readTask?.cancel()
        pending.values.forEach { $0.resume(throwing: CopilotSDKError.connectionClosed) }
        pending.removeAll()
        try? reader.close()
        try? writer.close()
        onClose()
    }

    func registerRequestHandler(_ method: String, handler: @escaping RequestHandler) {
        requestHandlers[method] = handler
    }

    func registerNotificationHandler(_ method: String, handler: @escaping NotificationHandler) {
        notificationHandlers[method] = handler
    }

    func request(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        let id = JSONRPCID.int(nextID)
        nextID += 1
        let payload = makeRequestPayload(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(payload)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func notify(_ method: String, params: JSONValue? = nil) throws {
        try send(makeRequestPayload(id: nil, method: method, params: params))
    }

    private func makeRequestPayload(id: JSONRPCID?, method: String, params: JSONValue?) -> JSONObject {
        var object: JSONObject = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let id { object["id"] = id.jsonValue }
        if let params { object["params"] = params }
        return object
    }

    private func makeResponsePayload(id: JSONRPCID, result: JSONValue? = nil, error: JSONRPCErrorPayload? = nil) throws -> JSONObject {
        var object: JSONObject = [
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
        ]
        if let result {
            object["result"] = result
        } else if let error {
            object["error"] = try JSONValue.encode(error)
        } else {
            object["result"] = .null
        }
        return object
    }

    private func send(_ object: JSONObject) throws {
        let body = try JSONEncoder.copilot.encode(JSONValue.object(object))
        guard let header = "Content-Length: \(body.count)\r\n\r\n".data(using: .utf8) else {
            throw CopilotSDKError.invalidResponse("Unable to encode JSON-RPC header")
        }
        writer.write(header)
        writer.write(body)
    }

    private func runReadLoop() async {
        var buffer = Data()
        do {
            while !Task.isCancelled {
                guard let chunk = try reader.read(upToCount: 4096), !chunk.isEmpty else { break }
                buffer.append(chunk)
                while let body = Self.extractFrame(from: &buffer) {
                    await handleMessageData(body)
                }
            }
        } catch {
            // handled by close path below
        }
        await stop()
    }

    private static func extractFrame(from buffer: inout Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else { return nil }
        let headerData = buffer[..<headerRange.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        var contentLength: Int?
        header.split(separator: "\n").forEach { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("content-length:") {
                contentLength = Int(trimmed.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "")
            }
        }
        guard let contentLength else { return nil }
        let bodyStart = headerRange.upperBound
        let totalLength = bodyStart + contentLength
        guard buffer.count >= totalLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<totalLength)
        buffer.removeSubrange(0..<totalLength)
        return body
    }

    private func handleMessageData(_ data: Data) async {
        guard let message = try? JSONDecoder.copilot.decode(JSONValue.self, from: data), let object = message.objectValue else {
            return
        }

        if let idValue = object["id"], object["method"] == nil {
            guard let id = JSONRPCID(idValue) else { return }
            if let errorValue = object["error"], let errorObject = errorValue.objectValue {
                let code = errorObject["code"]?.intValue ?? -32000
                let message = errorObject["message"]?.stringValue ?? "Unknown RPC error"
                pending.removeValue(forKey: id)?.resume(throwing: CopilotSDKError.rpcError(code: code, message: message))
                return
            }
            pending.removeValue(forKey: id)?.resume(returning: object["result"] ?? .null)
            return
        }

        guard let method = object["method"]?.stringValue else { return }
        let params = object["params"]
        let id = object["id"].flatMap(JSONRPCID.init)

        if let id {
            let handler = requestHandlers[method]
            do {
                let result = try await handler?(params)
                let response = try makeResponsePayload(id: id, result: result ?? .null, error: nil)
                try send(response)
            } catch {
                let rpcError = JSONRPCErrorPayload(code: -32000, message: String(describing: error.localizedDescription))
                if let response = try? makeResponsePayload(id: id, result: nil, error: rpcError) {
                    try? send(response)
                }
            }
        } else {
            await notificationHandlers[method]?(params)
        }
    }
}

struct TCPConnectionHandles {
    let reader: FileHandle
    let writer: FileHandle
}

enum TCPConnector {
    static func connect(host: String, port: Int) throws -> TCPConnectionHandles {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: Int32(SOCK_STREAM.rawValue),
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_addr: nil,
            ai_canonname: nil,
            ai_next: nil
        )
        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &resultPointer)
        guard status == 0, let resultPointer else {
            throw CopilotSDKError.invalidCLIURL("\(host):\(port)")
        }
        defer { freeaddrinfo(resultPointer) }

        var current: UnsafeMutablePointer<addrinfo>? = resultPointer
        while let currentNode = current {
            let socketFD = socket(currentNode.pointee.ai_family, Int32(currentNode.pointee.ai_socktype), currentNode.pointee.ai_protocol)
            if socketFD >= 0 {
                let connectResult: Int32
                #if canImport(Darwin)
                connectResult = Darwin.connect(socketFD, currentNode.pointee.ai_addr, currentNode.pointee.ai_addrlen)
                #else
                connectResult = Glibc.connect(socketFD, currentNode.pointee.ai_addr, currentNode.pointee.ai_addrlen)
                #endif
                if connectResult == 0 {
                    let readHandle = FileHandle(fileDescriptor: socketFD, closeOnDealloc: true)
                    let writeHandle = FileHandle(fileDescriptor: dup(socketFD), closeOnDealloc: true)
                    return TCPConnectionHandles(reader: readHandle, writer: writeHandle)
                }
                _ = close(socketFD)
            }
            current = currentNode.pointee.ai_next
        }

        throw CopilotSDKError.invalidCLIURL("\(host):\(port)")
    }
}
