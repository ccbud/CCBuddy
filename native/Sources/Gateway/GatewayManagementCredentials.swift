import Foundation
import Security

/// Thread-safe management endpoint shared by the gateway supervisor and monitor client.
///
/// The helper asks the kernel for a private management port on every launch. The supervisor
/// publishes the port only after parsing the helper's authenticated ready event, while retained
/// clients resolve a fresh snapshot for every request.
final class GatewayManagementEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBaseURL = URL(string: "http://127.0.0.1:1")!

    var baseURL: URL {
        lock.lock()
        defer { lock.unlock() }
        return storedBaseURL
    }

    func update(port: Int) {
        guard (1...65_535).contains(port),
              let url = URL(string: "http://127.0.0.1:\(port)") else { return }
        lock.lock()
        storedBaseURL = url
        lock.unlock()
    }

    func reset() {
        lock.lock()
        storedBaseURL = URL(string: "http://127.0.0.1:1")!
        lock.unlock()
    }
}

/// Process-local bearer credential for the helper's management listener.
struct GatewayManagementCredentials: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let bearerToken: String
    let endpoint: GatewayManagementEndpoint

    var authorizationHeader: String { "Bearer \(bearerToken)" }
    var description: String { "GatewayManagementCredentials(<redacted>)" }
    var debugDescription: String { description }

    static func generate() -> GatewayManagementCredentials {
        var random = [UInt8](repeating: 0, count: 32)
        let token: String
        if SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess {
            token = random.map { String(format: "%02x", $0) }.joined()
        } else {
            token = (UUID().uuidString + UUID().uuidString)
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
        }
        return GatewayManagementCredentials(
            bearerToken: token,
            endpoint: GatewayManagementEndpoint()
        )
    }
}
