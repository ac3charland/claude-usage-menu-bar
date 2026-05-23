// Spike 0c (forced) — drive the CLI-ping refresh by injecting a near-expiry
// `expiresAt` into the Keychain payload, then verify the CLI rewrote it.
//
// Safety:
//   - Original payload is held in memory and restored on any failure path.
//   - Only `expiresAt` is mutated. accessToken / refreshToken are preserved, so
//     Claude Code itself keeps working even if we abort mid-spike.
//   - If the CLI successfully refreshes (post-expiresAt > injected), we keep the
//     new payload — restoring would clobber the freshly-issued tokens.

import Foundation
import Security

let service = "Claude Code-credentials"

let readQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
]

let updateMatchQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
]

func readPayload() -> Data? {
    var r: CFTypeRef?
    let s = SecItemCopyMatching(readQuery as CFDictionary, &r)
    guard s == errSecSuccess else { return nil }
    return r as? Data
}

func expiresAtIn(_ data: Data) -> Double? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let inner = json["claudeAiOauth"] as? [String: Any] else { return nil }
    if let v = inner["expiresAt"] as? Double { return v }
    if let v = inner["expiresAt"] as? Int { return Double(v) }
    return nil
}

func writePayload(_ data: Data) -> OSStatus {
    let attrs: [String: Any] = [kSecValueData as String: data]
    return SecItemUpdate(updateMatchQuery as CFDictionary, attrs as CFDictionary)
}

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

// 1. Snapshot original.
guard let original = readPayload() else {
    print("[0c-force] FAIL — could not read Keychain item")
    exit(1)
}
guard let originalExpires = expiresAtIn(original) else {
    print("[0c-force] FAIL — original payload has no expiresAt")
    exit(1)
}
print("[0c-force] original expiresAt: \(Int64(originalExpires))  (\(Date(timeIntervalSince1970: originalExpires/1000)))")

// 2. Build modified payload: expiresAt = now + 60s (under the 30-min refresh margin).
guard var rootJson = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
      var inner = rootJson["claudeAiOauth"] as? [String: Any] else {
    print("[0c-force] FAIL — payload shape not as expected")
    exit(1)
}
let injectedExpires = (Date().timeIntervalSince1970 + 60) * 1000
inner["expiresAt"] = injectedExpires
rootJson["claudeAiOauth"] = inner
guard let modified = try? JSONSerialization.data(withJSONObject: rootJson) else {
    print("[0c-force] FAIL — could not re-serialize payload")
    exit(1)
}
print("[0c-force] injected expiresAt: \(Int64(injectedExpires))  (\(Date(timeIntervalSince1970: injectedExpires/1000)))")

// 3. Write injected payload. After this point, we own the cleanup.
var ownRestore = true
func restore(reason: String) {
    guard ownRestore else { return }
    let s = writePayload(original)
    print("[0c-force] restore (\(reason)) status: \(s)")
    if s != errSecSuccess {
        print("[0c-force] !! WARNING — restore failed. Keychain payload may have an injected near-expiry timestamp.")
        print("[0c-force] !! The token itself is unchanged; running `claude` once should refresh on its own.")
    }
}

let writeStatus = writePayload(modified)
guard writeStatus == errSecSuccess else {
    print("[0c-force] FAIL — SecItemUpdate refused injected payload: \(writeStatus)")
    exit(1)
}
print("[0c-force] injected payload written. Spawning claude ping…")

// 4. Spawn CLI ping.
guard let claudePath = locateClaudeBinary() else {
    restore(reason: "claude not found")
    exit(1)
}
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
    restore(reason: "spawn failed: \(error)")
    exit(1)
}
proc.waitUntilExit()
let elapsed = Date().timeIntervalSince(startedAt)
print("[0c-force] claude exited code=\(proc.terminationStatus) (after \(String(format: "%.1f", elapsed))s)")

// 5. Give the CLI a beat to flush any post-exit writes, then inspect result.
Thread.sleep(forTimeInterval: 0.5)

guard let after = readPayload(), let afterExpires = expiresAtIn(after) else {
    restore(reason: "could not re-read")
    exit(1)
}
print("[0c-force] post expiresAt:     \(Int64(afterExpires))  (\(Date(timeIntervalSince1970: afterExpires/1000)))")

if afterExpires > injectedExpires + 1000 {
    let advanceMin = (afterExpires - Date().timeIntervalSince1970 * 1000) / 1000 / 60
    print("[0c-force] OK — CLI refreshed token. New expiresAt is ~\(Int(advanceMin)) min from now.")
    print("[0c-force] NOT restoring — fresh tokens are the right state.")
    ownRestore = false
    exit(0)
}

if abs(afterExpires - injectedExpires) < 1 {
    print("[0c-force] CLI did not rewrite the keychain (expiresAt still equals injected).")
} else {
    print("[0c-force] Unexpected state: post-expiresAt differs from injected by \(Int64(afterExpires - injectedExpires)) ms but did not advance past it.")
}
restore(reason: "no refresh observed")
exit(2)
