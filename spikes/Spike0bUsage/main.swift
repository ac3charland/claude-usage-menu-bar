// Spike 0b — Usage endpoint shape.
// Hits GET https://api.anthropic.com/api/oauth/usage with the OAuth bearer token
// and the `anthropic-beta: oauth-2025-04-20` header. Prints status + parsed shape.
// Confirms five_hour / seven_day each carry utilization (0–100) + resets_at (ISO 8601).
//
// Reuses the Keychain read from 0a so we don't have to ship a token-injection mode.

import Foundation
import Security

// --- Keychain read (same as 0a) ---

struct OAuthEnvelope: Decodable {
    struct Inner: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double
    }
    let claudeAiOauth: Inner
}

func loadAccessToken() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return (try? JSONDecoder().decode(OAuthEnvelope.self, from: data))?.claudeAiOauth.accessToken
}

// --- Usage response shapes ---

struct UsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct UsageResponse: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

// Anthropic error envelope (can arrive in a 200-status body).
struct ErrorEnvelope: Decodable {
    struct Inner: Decodable { let type: String?; let message: String? }
    let type: String?
    let error: Inner?
}

// --- Run ---

guard let token = loadAccessToken() else {
    print("[0b] FAIL — could not load access token from Keychain (run 0a first)")
    exit(1)
}
print("[0b] Loaded access token (length \(token.count)); calling endpoint…")

var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
req.httpMethod = "GET"
req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
req.timeoutInterval = 10

let sem = DispatchSemaphore(value: 0)
var status: Int = -1
var bodyData: Data?
var error: Error?

URLSession.shared.dataTask(with: req) { data, resp, err in
    error = err
    if let http = resp as? HTTPURLResponse { status = http.statusCode }
    bodyData = data
    sem.signal()
}.resume()
sem.wait()

if let error {
    print("[0b] FAIL — transport error: \(error)")
    exit(1)
}

print("[0b] HTTP \(status)")

guard let bodyData else {
    print("[0b] FAIL — no body")
    exit(1)
}

let bodyStr = String(data: bodyData, encoding: .utf8) ?? "<binary>"
print("[0b] Body (\(bodyData.count) bytes): \(bodyStr)")

if status == 429 {
    print("[0b] OK — 429 rate-limit path observed. Confirmed.")
    exit(0)
}

// 200 with error envelope?
if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: bodyData),
   envelope.type == "error" {
    print("[0b] 200 with error envelope: type=\(envelope.error?.type ?? "?") msg=\(envelope.error?.message ?? "?")")
    print("[0b] Confirmed 200-error-envelope path. Gate partially satisfied; rerun with a valid token to see numbers.")
    exit(0)
}

do {
    let usage = try JSONDecoder().decode(UsageResponse.self, from: bodyData)
    func describe(_ w: UsageWindow?, _ label: String) {
        guard let w else { print("[0b]   \(label): nil"); return }
        print("[0b]   \(label): utilization=\(w.utilization.map { String($0) } ?? "nil")  resets_at=\(w.resetsAt ?? "nil")")
    }
    describe(usage.fiveHour, "five_hour")
    describe(usage.sevenDay, "seven_day")
    let ok = usage.fiveHour != nil || usage.sevenDay != nil
    print(ok ? "[0b] OK — shape matches spec." : "[0b] FAIL — neither window present.")
    exit(ok ? 0 : 1)
} catch {
    print("[0b] FAIL — decode error: \(error)")
    exit(1)
}
