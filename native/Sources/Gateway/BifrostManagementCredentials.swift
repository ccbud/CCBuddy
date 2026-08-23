import Foundation
import Security

/// Process-local credentials for Bifrost's management API.
///
/// A supervisor creates one immutable value for its lifetime and writes the same value into
/// Bifrost's private config file on every start. The value deliberately redacts its textual
/// representations so an interpolated diagnostic cannot disclose either credential.
struct BifrostManagementCredentials: Equatable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let username: String
    let password: String

    var basicAuthorizationHeader: String {
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    var description: String { "BifrostManagementCredentials(<redacted>)" }
    var debugDescription: String { description }

    static func generate() -> BifrostManagementCredentials {
        var random = [UInt8](repeating: 0, count: 40)
        if SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess {
            let usernameEntropy = random.prefix(8).map(hexByte).joined()
            let passwordEntropy = random.dropFirst(8).map(hexByte).joined()
            return BifrostManagementCredentials(
                username: "ccbud-admin-\(usernameEntropy)",
                // The prefix guarantees Bifrost's uppercase/lowercase/digit/special policy;
                // the remaining 256 random bits provide the actual password strength.
                password: "Aa1!\(passwordEntropy)"
            )
        }

        // SecRandomCopyBytes failure is exceptional. UUID entropy still gives each supervisor
        // private credentials while the fixed prefix continues to satisfy Bifrost's policy.
        let usernameFallback = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let passwordFallback = (
            UUID().uuidString + UUID().uuidString
        ).replacingOccurrences(of: "-", with: "").lowercased()
        return BifrostManagementCredentials(
            username: "ccbud-admin-\(usernameFallback)",
            password: "Aa1!\(passwordFallback)"
        )
    }

    private static func hexByte(_ byte: UInt8) -> String {
        String(format: "%02x", byte)
    }
}
