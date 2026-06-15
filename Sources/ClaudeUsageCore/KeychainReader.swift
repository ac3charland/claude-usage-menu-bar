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
    case userCanceled
    case secStatus(OSStatus)
    case malformedPayload

    public var description: String {
        switch self {
        case .notFound: return "Keychain item 'Claude Code-credentials' not found"
        case .interactionRequired: return "Keychain access needs authorization but UI could not be shown"
        case .userCanceled: return "User dismissed the Keychain authorization prompt"
        case .secStatus(let s): return "Keychain SecItemCopyMatching failed: \(s)"
        case .malformedPayload: return "Keychain payload did not contain expected claudeAiOauth fields"
        }
    }
}

public enum KeychainReader {
    private static let service = "Claude Code-credentials"

    /// macOS returns this (un-named in the SDK) when a read would need to show the
    /// authorization UI but the machine is in dark wake — e.g. a background poll fired
    /// by a network-reconnect or system-wake event. There is no display to host the modal,
    /// so even an interactive read can't prompt here.
    private static let errSecInDarkWake: OSStatus = -25320

    /// Read the `Claude Code-credentials` item.
    ///
    /// - Parameter allowInteraction: when `true`, a lapsed ACL grant pops the macOS
    ///   "enter your login password / Always Allow" modal — the user grants access on the
    ///   spot and polling resumes. This is the default behavior: the widget asks for the
    ///   password when it needs it, rather than deferring behind a menu item.
    ///   When `false`, the read is forced *silent* (no modal); a lapsed grant throws
    ///   `.interactionRequired`. We use silent reads only briefly, to avoid re-popping the
    ///   modal right after the user has dismissed it (see the prompt cooldown in `UsageEngine`).
    ///
    ///   Two non-success outcomes are distinguished so the engine can react sensibly:
    ///   `.userCanceled` (the user dismissed the prompt — back off, don't nag) vs.
    ///   `.interactionRequired` (no UI could be shown, e.g. dark wake — just retry later).
    public static func read(allowInteraction: Bool = true) throws -> OAuthCredentials {
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
        // The user actively dismissed the password / Always-Allow modal. Surface it as its
        // own case so the engine can back off instead of re-popping the modal on the very
        // next poll.
        if status == errSecUserCanceled { throw KeychainError.userCanceled }
        // "Couldn't show the authorization UI at all": dark wake (-25320) or
        // errSecInteractionNotAllowed (-25308, raised by our own UI suppression on silent
        // reads). On a silent read a lapsed grant can also surface as errSecAuthFailed
        // (-25293) — the legacy keychain's way of saying "I'd need to authenticate you and
        // I'm not allowed to show UI." None of these are a real auth failure; they just mean
        // we couldn't prompt right now, so let the engine retry on a later poll. (On an
        // interactive read, -25293 is a genuine wrong-password and falls through to .secStatus.)
        let couldNotPrompt = status == errSecInteractionNotAllowed
            || status == errSecInDarkWake
            || (!allowInteraction && status == errSecAuthFailed)
        if couldNotPrompt {
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
