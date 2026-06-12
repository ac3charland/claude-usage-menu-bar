import Foundation

public enum TokenRefresher {
    /// Refresh margin: if expiresAt is within this many minutes of now, trigger a refresh.
    public static let refreshMarginMinutes: TimeInterval = 30

    /// Hard timeout for the `claude` ping subprocess.
    public static let cliTimeoutSeconds: TimeInterval = 30

    /// Minimum spacing between CLI ping attempts for the *same* unrefreshed token.
    /// Without it, a token sitting inside the 30-min refresh margin gets pinged on every
    /// 2-min poll — ~14 redundant `claude` spawns per token cycle (and a Keychain
    /// re-read after each), since the CLI only actually swaps the token near real expiry.
    public static let pingCooldownSeconds: TimeInterval = 10 * 60

    /// Expiry (ms) we last pinged for, plus when. A successful refresh advances the
    /// expiry past the margin so the next poll returns early; this guard only bites when
    /// the previous ping did *not* refresh (token still valid, or no usable refreshToken).
    private static var lastPingedExpiryMs: Double?
    private static var lastPingAt: Date?

    /// Returns true if a refresh attempt was made.
    /// The caller is expected to re-read the Keychain afterwards if true.
    @discardableResult
    public static func refreshIfNeeded(currentExpiresAtMs: Double, now: Date = Date()) async -> Bool {
        let expiresAt = Date(timeIntervalSince1970: currentExpiresAtMs / 1000)
        let marginSec = refreshMarginMinutes * 60
        if expiresAt.timeIntervalSince(now) > marginSec {
            return false
        }
        if lastPingedExpiryMs == currentExpiresAtMs,
           let last = lastPingAt, now.timeIntervalSince(last) < pingCooldownSeconds {
            // Already pinged this exact token recently and it hasn't been refreshed.
            // Re-spawning `claude` every poll won't help — wait out the cooldown.
            return false
        }
        Log.info("Token expires in \(Int(expiresAt.timeIntervalSince(now) / 60))min — refreshing via CLI ping")
        lastPingedExpiryMs = currentExpiresAtMs
        lastPingAt = now
        await spawnPing()
        return true
    }

    /// Forces a refresh regardless of expiry. Useful when we get a 401 from the usage endpoint.
    public static func forceRefresh() async {
        Log.info("Forcing token refresh via CLI ping")
        await spawnPing()
    }

    /// Auth-override env vars the CLI prefers over Keychain OAuth. If any leak into
    /// the ping subprocess (e.g. the app was `open`ed from a shell that exported
    /// CLAUDE_CODE_OAUTH_TOKEN), the CLI authenticates with them, exits 0, and never
    /// touches the Keychain entry we're trying to refresh — so we strip them.
    private static let authOverrideEnvVars = [
        "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
    ]

    private static func spawnPing() async {
        guard let claudePath = locateClaudeBinary() else {
            Log.error("Cannot refresh — `claude` binary not found. Set CLAUDE_BIN to override.")
            return
        }
        let nonce = UUID().uuidString.prefix(8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = ["-p", "ping \(nonce)", "--model", "haiku"]
        var env = ProcessInfo.processInfo.environment
        for key in authOverrideEnvVars where env[key] != nil {
            env.removeValue(forKey: key)
            Log.warn("Stripping \(key) from CLI ping env — it would bypass the Keychain refresh")
        }
        proc.environment = env
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        let started = Date()
        do {
            try proc.run()
        } catch {
            Log.error("CLI ping spawn failed: \(error)")
            return
        }

        let deadline = started.addingTimeInterval(cliTimeoutSeconds)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if proc.isRunning {
            Log.warn("CLI ping exceeded \(Int(cliTimeoutSeconds))s — terminating")
            proc.terminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if proc.isRunning { proc.interrupt() }
        }
        let elapsed = Date().timeIntervalSince(started)
        let code = proc.terminationStatus
        if code == 0 {
            Log.info("CLI ping exited code=0 after \(String(format: "%.1f", elapsed))s")
        } else {
            // Most common cause in practice: the keychain entry has an empty refreshToken,
            // so the CLI can't swap it and exits non-zero. Surface this loudly — the engine
            // will also detect the unchanged expiry and route to .refreshFailed.
            Log.warn("CLI ping exited code=\(code) after \(String(format: "%.1f", elapsed))s — token likely not refreshed")
        }
    }

    private static func locateClaudeBinary() -> String? {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_BIN"], !env.isEmpty { return env }
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSString(string: "~/.local/bin/claude").expandingTildeInPath,
            NSString(string: "~/.claude/local/claude").expandingTildeInPath,
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
