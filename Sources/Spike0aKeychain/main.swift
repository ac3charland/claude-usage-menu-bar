// Spike 0a — Cross-app Keychain read.
// Gate: read the `Claude Code-credentials` generic-password via SecItemCopyMatching
// without an interactive prompt on every launch. One-time "Always Allow" is OK.
//
// What this prints:
//   - OSStatus from SecItemCopyMatching
//   - whether claudeAiOauth.{accessToken,refreshToken,expiresAt} decoded cleanly
//   - access token length + expiresAt (no token value, ever)

import Foundation
import Security

struct OAuthEnvelope: Decodable {
    struct Inner: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double // epoch ms per source doc
    }
    let claudeAiOauth: Inner
}

func osStatusString(_ s: OSStatus) -> String {
    if let msg = SecCopyErrorMessageString(s, nil) as String? {
        return "\(s) (\(msg))"
    }
    return "\(s)"
}

let service = "Claude Code-credentials"

let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
]

let startedAt = Date()
var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)

print("[0a] SecItemCopyMatching status: \(osStatusString(status)) (elapsed \(elapsedMs)ms)")

guard status == errSecSuccess else {
    print("[0a] FAIL — non-success status")
    if status == errSecItemNotFound {
        print("[0a]   Hint: the Keychain item is missing. Run Claude Code and sign in first.")
    } else if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
        print("[0a]   Hint: ACL likely denied this binary. If a dialog appeared, that's the prompt path.")
    }
    exit(1)
}

guard let data = result as? Data else {
    print("[0a] FAIL — kSecReturnData did not yield a Data value")
    exit(1)
}

print("[0a] Payload bytes: \(data.count)")

do {
    let creds = try JSONDecoder().decode(OAuthEnvelope.self, from: data)
    let expiresInMin = Int((creds.claudeAiOauth.expiresAt / 1000 - Date().timeIntervalSince1970) / 60)
    print("[0a] accessToken length: \(creds.claudeAiOauth.accessToken.count)")
    print("[0a] refreshToken length: \(creds.claudeAiOauth.refreshToken.count)")
    print("[0a] expiresAt (ms): \(Int64(creds.claudeAiOauth.expiresAt))  (~\(expiresInMin) min from now)")
    print("[0a] OK — decoded cleanly. No prompt on this run = gate satisfied.")
} catch {
    print("[0a] FAIL — JSON decode error: \(error)")
    if let str = String(data: data, encoding: .utf8) {
        let preview = str.prefix(80)
        print("[0a]   Body prefix (first 80 chars): \(preview)…")
    }
    exit(1)
}
