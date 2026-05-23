import Foundation
import ServiceManagement
import ClaudeUsageCore

/// Thin wrapper over `SMAppService.mainApp` for the "Open at Login" toggle.
///
/// Requires the executable to be running from a real `.app` bundle registered with
/// launchd; from a bare SwiftPM binary the calls throw, which we surface to the caller
/// so the menu can show the control as unavailable rather than silently failing.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether the login-item API can work in the current run context (i.e. we are an
    /// app bundle, not a loose executable).
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                Log.info("Registered as login item")
            } else {
                try SMAppService.mainApp.unregister()
                Log.info("Unregistered login item")
            }
            return true
        } catch {
            Log.error("Login-item update failed: \(error.localizedDescription)")
            return false
        }
    }
}
