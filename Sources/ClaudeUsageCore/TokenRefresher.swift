import Foundation

public enum TokenRefresher {
    /// Refresh margin: if expiresAt is within this many minutes of now, trigger a refresh.
    public static let refreshMarginMinutes: TimeInterval = 30

    /// Hard timeout for the `claude` ping subprocess.
    public static let cliTimeoutSeconds: TimeInterval = 30

    /// Returns true if a refresh attempt was made.
    /// The caller is expected to re-read the Keychain afterwards if true.
    @discardableResult
    public static func refreshIfNeeded(currentExpiresAtMs: Double, now: Date = Date()) async -> Bool {
        let expiresAt = Date(timeIntervalSince1970: currentExpiresAtMs / 1000)
        let marginSec = refreshMarginMinutes * 60
        if expiresAt.timeIntervalSince(now) > marginSec {
            return false
        }
        Log.info("Token expires in \(Int(expiresAt.timeIntervalSince(now) / 60))min — refreshing via CLI ping")
        await spawnPing()
        return true
    }

    /// Forces a refresh regardless of expiry. Useful when we get a 401 from the usage endpoint.
    public static func forceRefresh() async {
        Log.info("Forcing token refresh via CLI ping")
        await spawnPing()
    }

    private static func spawnPing() async {
        guard let claudePath = locateClaudeBinary() else {
            Log.error("Cannot refresh — `claude` binary not found. Set CLAUDE_BIN to override.")
            return
        }
        let nonce = UUID().uuidString.prefix(8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = ["-p", "ping \(nonce)", "--model", "haiku"]
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
        Log.info("CLI ping exited code=\(proc.terminationStatus) after \(String(format: "%.1f", elapsed))s")
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
