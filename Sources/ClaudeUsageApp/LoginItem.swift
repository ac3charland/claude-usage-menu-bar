import Foundation
import ClaudeUsageCore

/// Manages "Open at Login" via a per-user LaunchAgent plist in `~/Library/LaunchAgents`.
///
/// We deliberately avoid `SMAppService.mainApp`, which requires the bundle to be
/// code-signed (at least ad-hoc) and silently fails on the unsigned local builds this
/// project ships. A LaunchAgent plist needs no signing: at login, launchd automatically
/// loads every plist in `~/Library/LaunchAgents`, and `RunAtLoad` starts the agent.
///
/// Enabling only *writes* the plist — it does not `launchctl load` it — so we don't spawn
/// a second copy alongside the already-running app; it takes effect at the next login.
/// Disabling only *removes* the plist; we never `bootout`, because when the app was itself
/// launched by this agent the running process *is* the launchd job, and booting it out
/// would terminate the app.
enum LoginItem {
    /// LaunchAgent label and plist filename stem. `isAvailable` gates callers to the case
    /// where a bundle identifier exists; the fallback only guards against a nil unwrap.
    private static var label: String {
        Bundle.main.bundleIdentifier ?? "com.alexcharland.ClaudeUsageMenuBar"
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Whether the toggle can work in the current run context. We require a real `.app`
    /// bundle so the login launch inherits `LSUIElement` (no Dock icon) and points at a
    /// stable install path rather than a throwaway `.build` binary.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? install() : remove()
    }

    /// Call once at launch. On first run (when available) enables open-at-login as the
    /// default; on later runs, rewrites the plist if still enabled so a moved `.app`
    /// keeps launching. A user who turns the toggle off is never re-enabled.
    static func configureAtLaunch() {
        guard isAvailable else { return }
        if !Preferences.didInitializeLoginItem {
            setEnabled(true)
            Preferences.didInitializeLoginItem = true
        } else if isEnabled {
            install()  // refresh the executable path in case the bundle moved
        }
    }

    @discardableResult
    private static func install() -> Bool {
        guard let executable = Bundle.main.executableURL?.path else {
            Log.error("Login-item install failed: no executable path")
            return false
        }
        // Always rewrite with the current executable path so re-toggling self-heals a
        // stale plist if the .app was moved since it was last enabled.
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            Log.info("Wrote login-item LaunchAgent at \(plistURL.path)")
            return true
        } catch {
            Log.error("Login-item install failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func remove() -> Bool {
        guard isEnabled else { return true }
        do {
            try FileManager.default.removeItem(at: plistURL)
            Log.info("Removed login-item LaunchAgent")
            return true
        } catch {
            Log.error("Login-item removal failed: \(error.localizedDescription)")
            return false
        }
    }
}
