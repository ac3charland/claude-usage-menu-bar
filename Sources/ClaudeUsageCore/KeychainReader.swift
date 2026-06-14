import Foundation
import Security

public struct OAuthCredentials {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAtMs: Double
}

public enum KeychainError: Error, CustomStringConvertible {
    case notFound
    case interactionRequired
    case secStatus(OSStatus)
    case malformedPayload

    public var description: String {
        switch self {
        case .notFound: return "Keychain item 'Claude Code-credentials' not found"
        case .interactionRequired: return "Keychain access needs authorization (silent read denied)"
        case .secStatus(let s): return "Keychain SecItemCopyMatching failed: \(s)"
        case .malformedPayload: return "Keychain payload did not contain expected claudeAiOauth fields"
        }
    }
}

public enum KeychainReader {
    private static let service = "Claude Code-credentials"

    /// macOS returns this (un-named in the SDK) when a read would need to show the
    /// authorization UI but the machine is in dark wake — e.g. a background poll fired
    /// by a network-reconnect or system-wake event. It is functionally the same problem
    /// as `errSecInteractionNotAllowed`: we don't have *silent* access to the item.
    private static let errSecInDarkWake: OSStatus = -25320

    /// Read the `Claude Code-credentials` item.
    ///
    /// - Parameter allowInteraction: when `false` (the default for background polls), the
    ///   read is forced *silent*: macOS will NOT pop the "enter your login password /
    ///   authenticity cannot be verified" modal. If we lack silent access it throws
    ///   `.interactionRequired` instead of blocking on a prompt the user never asked for
    ///   (and which can't even be answered in dark wake). Pass `true` only from an explicit,
    ///   user-initiated action (the "Authorize Keychain Access…" menu item), where a single
    ///   intentional prompt is acceptable.
    public static func read(allowInteraction: Bool = false) throws -> OAuthCredentials {
        // Belt-and-suspenders UI suppression. `Claude Code-credentials` lives in the
        // legacy file keychain (login.keychain-db), whose ACL prompt is gated by the
        // process-wide SecKeychainSetUserInteractionAllowed flag — kSecUseAuthenticationUI
        // alone (a data-protection-keychain knob) does not reliably suppress it.
        if !allowInteraction {
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer { if !allowInteraction { SecKeychainSetUserInteractionAllowed(true) } }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        // A silently-denied read does not always surface as the clean
        // errSecInteractionNotAllowed / dark-wake codes. When the standing ACL grant has
        // lapsed (rebuild/reinstall/refresh boundary) a UI-suppressed read can come back as
        // errSecAuthFailed (-25293) — the legacy keychain's way of saying "I'd have to
        // authenticate you and I'm not allowed to show UI." Same root cause: we lack silent
        // access. Route it to the on-demand authorization path so the app shows
        // `needsAuthorization` (with the "Authorize Keychain Access…" menu item) instead of
        // the dead-end `noToken` ("Sign in to Claude Code") state. We only reinterpret it on
        // a silent read; an interactive read returning errSecAuthFailed is a genuine
        // wrong-password failure and authorizeNow() handles it as such.
        let silentlyDenied = status == errSecInteractionNotAllowed
            || status == errSecInDarkWake
            || (!allowInteraction && status == errSecAuthFailed)
        if silentlyDenied {
            throw KeychainError.interactionRequired
        }
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
