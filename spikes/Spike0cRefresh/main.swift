// Spike 0c — Token refresh path.
//
// Strategy:
//   1. Read current expiresAt from the Keychain item.
//   2. Spawn `claude -p "ping <nonce>" --model haiku` and wait for it to finish.
//   3. Re-read expiresAt; check whether the timestamp moved forward.
//
// This validates the proven CLI-ping backstop. The preferred direct OAuth refresh
// (POST refresh_token to the discovered endpoint with the discovered client_id)
// is intentionally NOT spiked here — we'd need to network-trace Claude Code to
// pull those values cleanly, which is Phase 1 work. If CLI ping refreshes
// reliably, the gate is satisfied per the spec.

import Foundation
import Security

struct OAuthEnvelope: Decodable {
    struct Inner: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double
    }
    let claudeAiOauth: Inner
}

func readExpiresAt() -> Double? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return (try? JSONDecoder().decode(OAuthEnvelope.self, from: data))?.claudeAiOauth.expiresAt
}

// `claude` is typically at /Users/<u>/.local/bin/claude; not always on /usr/bin's PATH
// in a GUI context. Find it via `which` (interactive shells) but allow override.
func locateClaudeBinary() -> String? {
    if let env = ProcessInfo.processInfo.environment["CLAUDE_BIN"], !env.isEmpty { return env }
    let candidates = [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        NSString(string: "~/.local/bin/claude").expandingTildeInPath,
        NSString(string: "~/.claude/local/claude").expandingTildeInPath,
    ]
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
}

guard let before = readExpiresAt() else {
    print("[0c] FAIL — could not read current expiresAt")
    exit(1)
}
let beforeDate = Date(timeIntervalSince1970: before / 1000)
print("[0c] expiresAt before: \(Int64(before))  (\(beforeDate))")
let minutesUntilExpiry = Int((before / 1000 - Date().timeIntervalSince1970) / 60)
print("[0c] token expires in ~\(minutesUntilExpiry) min")
if minutesUntilExpiry > 30 {
    print("[0c] NOTE — token is fresh; CLI may decide not to refresh it. The spike still proves the spawn path.")
}

guard let claudePath = locateClaudeBinary() else {
    print("[0c] FAIL — claude CLI not found. Set CLAUDE_BIN=/abs/path or install Claude Code.")
    exit(1)
}
print("[0c] Using claude binary: \(claudePath)")

let nonce = UUID().uuidString.prefix(8)
let proc = Process()
proc.executableURL = URL(fileURLWithPath: claudePath)
proc.arguments = ["-p", "ping \(nonce)", "--model", "haiku"]
proc.standardOutput = Pipe()
proc.standardError = Pipe()

let startedAt = Date()
do {
    try proc.run()
} catch {
    print("[0c] FAIL — could not spawn: \(error)")
    exit(1)
}
proc.waitUntilExit()
let elapsedSec = Date().timeIntervalSince(startedAt)
print("[0c] claude exited code=\(proc.terminationStatus) (after \(String(format: "%.1f", elapsedSec))s)")

// Give the CLI a beat to flush the Keychain write if it happens post-exit.
Thread.sleep(forTimeInterval: 0.5)

guard let after = readExpiresAt() else {
    print("[0c] FAIL — could not re-read expiresAt after CLI ping")
    exit(1)
}
let afterDate = Date(timeIntervalSince1970: after / 1000)
print("[0c] expiresAt after:  \(Int64(after))  (\(afterDate))")

if after > before {
    let deltaMin = Int((after - before) / 1000 / 60)
    print("[0c] OK — expiresAt advanced by ~\(deltaMin) min. CLI-ping refresh confirmed.")
    exit(0)
} else {
    print("[0c] expiresAt unchanged.")
    print("[0c]   If token was fresh, CLI may have skipped the refresh. Re-run after expiresAt is within 30 min.")
    print("[0c]   Gate not yet proved.")
    exit(2)
}
