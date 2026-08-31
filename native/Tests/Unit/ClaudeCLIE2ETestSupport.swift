import Darwin
import Foundation

struct ClaudeCLIProcessResult {
    var terminationStatus: Int32
    var standardOutput: String
    var standardError: String
}

enum ClaudeCLIE2ETestSupport {
    enum ProcessError: LocalizedError {
        case timedOut(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .timedOut(let seconds):
                return "Claude CLI did not exit within \(Int(seconds)) seconds"
            }
        }
    }

    static func claudeExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let repositoryPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/test-tools/claude").path
        return executable(
            override: environment["CCBUD_CLAUDE_BINARY"],
            name: "claude",
            environment: environment,
            fallbacks: [
                repositoryPath,
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/claude").path,
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ]
        )
    }

    static func bifrostExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let repositoryPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/bifrost-http").path
        return executable(
            override: environment["CCBUD_BIFROST_BINARY"],
            name: "bifrost-http",
            environment: environment,
            fallbacks: [repositoryPath]
        )
    }

    static func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw posixError() }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { throw posixError() }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        timeout: TimeInterval = 45
    ) async throws -> ClaudeCLIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let gate = ProcessCompletionGate()
            process.terminationHandler = { process in
                gate.complete {
                    continuation.resume(returning: process.terminationStatus)
                }
            }
            do {
                try process.run()
            } catch {
                gate.complete { continuation.resume(throwing: error) }
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.complete {
                    if process.isRunning {
                        process.terminate()
                        let identifier = process.processIdentifier
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                            if process.isRunning { _ = Darwin.kill(identifier, SIGKILL) }
                        }
                    }
                    continuation.resume(throwing: ProcessError.timedOut(timeout))
                }
            }
        }

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        return ClaudeCLIProcessResult(
            terminationStatus: status,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }

    private static func executable(
        override: String?,
        name: String,
        environment: [String: String],
        fallbacks: [String]
    ) -> String? {
        var candidates: [String] = []
        if let override, !override.isEmpty { candidates.append(override) }
        candidates.append(contentsOf: fallbacks)
        candidates.append(contentsOf: (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name).path })
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private final class ProcessCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func complete(_ action: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        action()
    }
}

struct ClaudeCLIAnthropicRequest {
    var method: String
    var target: String
    var headers: [String: String]
    var body: [String: Any]
}

final class ClaudeCLIAnthropicMock: @unchecked Sendable {
    static let firstMarker = "CCBUD_CLAUDE_CLI_FIRST"
    static let secondMarker = "CCBUD_CLAUDE_CLI_SECOND"

    let port: Int
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "dev.ccbud.tests.claude-cli-anthropic")
    private let lock = NSLock()
    private var stopped = false
    private var recordedRequests: [ClaudeCLIAnthropicRequest] = []
    private var messageCount = 0

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.posixError() }
        var closeOnFailure = true
        defer { if closeOnFailure { close(descriptor) } }

        var reuse: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout.size(ofValue: reuse))
        ) == 0 else { throw Self.posixError() }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { throw Self.posixError() }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { throw Self.posixError() }

        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
        closeOnFailure = false
    }

    var requests: [ClaudeCLIAnthropicRequest] {
        lock.withLock { recordedRequests }
    }

    var messageRequests: [ClaudeCLIAnthropicRequest] {
        requests.filter { normalizedTarget($0.target) == "/v1/messages" }
    }

    func start() {
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }

    private func acceptLoop() {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            configure(client)
            handle(client)
            close(client)
        }
    }

    private func configure(_ client: Int32) {
        var noSignal: Int32 = 1
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
    }

    private func handle(_ client: Int32) {
        guard let raw = readRequest(from: client), let request = parse(raw) else {
            sendJSON(["error": ["message": "invalid mock request"]], status: 400, to: client)
            return
        }
        let path = normalizedTarget(request.target)
        let ordinal: Int? = lock.withLock {
            recordedRequests.append(request)
            guard path == "/v1/messages" else { return nil }
            messageCount += 1
            return messageCount
        }

        switch path {
        case "/v1/messages":
            let marker = ordinal == 1 ? Self.firstMarker : Self.secondMarker
            if request.body["stream"] as? Bool == true {
                sendStream(marker: marker, ordinal: ordinal ?? 1, to: client)
            } else {
                sendMessage(marker: marker, ordinal: ordinal ?? 1, to: client)
            }
        case "/v1/messages/count_tokens":
            sendJSON(["input_tokens": 64], to: client)
        case "/v1/models":
            sendJSON([
                "data": [[
                    "id": "glm-5.2",
                    "type": "model",
                    "display_name": "Mock Anthropic",
                    "created_at": "2026-01-01T00:00:00Z",
                ]],
                "has_more": false,
                "first_id": "glm-5.2",
                "last_id": "glm-5.2",
            ], to: client)
        default:
            sendJSON(["error": ["message": "unexpected target \(path)"]], status: 404, to: client)
        }
    }

    private func parse(_ raw: Data) -> ClaudeCLIAnthropicRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: delimiter) else { return nil }
        let headerText = String(decoding: raw[..<range.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        let data = raw.subdata(in: range.upperBound..<raw.endIndex)
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ClaudeCLIAnthropicRequest(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            headers: headers,
            body: body
        )
    }

    private func readRequest(from client: Int32) -> Data? {
        var data = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while data.count < 8 * 1_024 * 1_024 {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(client, $0.baseAddress, $0.count, 0)
            }
            guard count > 0 else { return data.isEmpty ? nil : data }
            data.append(contentsOf: buffer.prefix(count))
            guard let headerRange = data.range(of: delimiter) else { continue }
            let headers = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
            let contentLength = headers.components(separatedBy: "\r\n").compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }.first ?? 0
            if data.count >= headerRange.upperBound + contentLength {
                return data.subdata(in: data.startIndex..<headerRange.upperBound + contentLength)
            }
        }
        return nil
    }

    private func sendMessage(marker: String, ordinal: Int, to client: Int32) {
        sendJSON([
            "id": "msg_ccbud_cli_\(ordinal)",
            "type": "message",
            "role": "assistant",
            "model": "glm-5.2",
            "content": [["type": "text", "text": marker]],
            "stop_reason": "end_turn",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 64, "output_tokens": 8],
        ], to: client)
    }

    private func sendStream(marker: String, ordinal: Int, to client: Int32) {
        let events = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_ccbud_cli_\(ordinal)","type":"message","role":"assistant","model":"glm-5.2","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":64,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\(marker)"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":8}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        send(Data(events.utf8), contentType: "text/event-stream", status: 200, to: client)
    }

    private func sendJSON(_ object: [String: Any], status: Int = 200, to client: Int32) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        send(data, contentType: "application/json", status: status, to: client)
    }

    private func send(_ body: Data, contentType: String, status: Int, to client: Int32) {
        let reason = status == 200 ? "OK" : (status == 400 ? "Bad Request" : "Not Found")
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "request-id: req_ccbud_mock\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        response.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.send(client, cursor, remaining, 0)
                guard written > 0 else { return }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
    }

    private func normalizedTarget(_ target: String) -> String {
        String(target.split(separator: "?", maxSplits: 1).first ?? Substring(target))
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
