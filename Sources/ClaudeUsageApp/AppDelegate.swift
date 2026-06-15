import AppKit
import ClaudeUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private let engine = UsageEngine()
    private var engineTask: Task<Void, Never>?
    private var staleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController()
        statusController = controller

        // Apply saved poll cadence before the engine starts.
        engine.baseIntervalSec = Preferences.pollIntervalSec

        // Engine publishes on the main actor; reflect each state into the icon.
        engine.onState = { [weak controller] state in
            controller?.update(state)
        }

        // Menu actions reach back into the engine.
        controller.onRefreshNow = { [weak engine] in engine?.refreshNow() }
        controller.onSetInterval = { [weak engine] seconds in
            engine?.baseIntervalSec = seconds
            engine?.refreshNow()
        }

        engineTask = Task { await engine.run() }

        // Open-at-login is on by default; refreshes a stale plist path on later runs.
        LoginItem.configureAtLaunch()

        // Re-evaluate dimming on a timer: data can age into "stale" between polls
        // (especially during long backoff) without any new engine event.
        staleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statusController?.update(self.engine.state)
            }
        }

        Log.info("Claude Usage launched (menu bar) — logging to \(Log.fileURL.path)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        engineTask?.cancel()
        staleTimer?.invalidate()
    }
}
