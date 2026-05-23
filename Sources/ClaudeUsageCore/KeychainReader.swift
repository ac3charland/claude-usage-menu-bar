import Foundation
import Security

public struct OAuthCredentials {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAtMs: Double
}

public enum KeychainError: Error, CustomStringConvertible {
    case notFound
    case secStatus(OSStatus)
    case malformedPayload

    public var description: String {
        switch self {
        case .notFound: return "Keychain item 'Claude Code-credentials' not found"
        case .secStatus(let s): return "Keychain SecItemCopyMatching failed: \(s)"
        case .malformedPayload: return "Keychain payload did not contain expected claudeAiOauth fields"
        }
    }
}

public enum KeychainReader {
    private static let service = "Claude Code-credentials"

    public static func read() throws -> OAuthCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.secStatus(status) }
        guard let data = result as? Data else { throw KeychainError.malformedPayload }

        struct Envelope: Decodable {
            struct Inner: Decodable {
                let accessToken: String
                let refreshToken: String
                let expiresAt: Double
            }
            let claudeAiOauth: Inner
        }
        do {
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            return OAuthCredentials(
                accessToken: env.claudeAiOauth.accessToken,
                refreshToken: env.claudeAiOauth.refreshToken,
                expiresAtMs: env.claudeAiOauth.expiresAt
            )
        } catch {
            throw KeychainError.malformedPayload
        }
    }
}
