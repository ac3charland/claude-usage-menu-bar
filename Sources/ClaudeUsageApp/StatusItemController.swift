import AppKit
import ClaudeUsageCore

/// Owns the `NSStatusItem`, keeps its button image in sync with engine state, and routes
/// clicks: left-click toggles the popover, right-click (or control-click) shows a menu.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popoverController = PopoverController()
    private var currentState: EngineState = .empty

    /// Wired by the app delegate to reach the engine.
    var onRefreshNow: (() -> Void)?
    var onSetInterval: ((TimeInterval) -> Void)?
    var onAuthorize: (() -> Void)?

    /// Icon opacity when data is degraded (stale / offline / error). Per the spec's
    /// proposal for open question 2: dim the glyph rather than change its shape.
    private static let degradedAlpha: CGFloat = 0.4
    static let staleThresholdSec: TimeInterval = 10 * 60

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = DualRingIcon.emptyImage()
            button.imageScaling = .scaleNone
            button.toolTip = "Claude usage"
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Apply a new engine state: redraw the icon, adjust dimming, refresh popover content.
    func update(_ state: EngineState) {
        currentState = state
        if let button = statusItem.button {
            button.image = DualRingIcon.image(for: state)
            button.alphaValue = isDimmed(state) ? Self.degradedAlpha : 1.0
            button.toolTip = toolTip(for: state)
        }
        popoverController.update(state)
    }

    // MARK: - Click routing

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isRight {
            showContextMenu(from: sender)
        } else {
            popoverController.toggle(from: sender)
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        popoverController.close()
        let menu = NSMenu()
        let reading: String
        if let snap = currentState.snapshot {
            let s = Int((snap.session?.utilizationPct ?? 0).rounded())
            let w = Int((snap.weekly?.utilizationPct ?? 0).rounded())
            reading = "Session \(s)%   ·   Weekly \(w)%"
        } else {
            reading = "No usage data yet"
        }
        let readingItem = NSMenuItem(title: reading, action: nil, keyEquivalent: "")
        readingItem.isEnabled = false
        menu.addItem(readingItem)
        if let reason = currentState.status.reason {
            let reasonItem = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            reasonItem.isEnabled = false
            menu.addItem(reasonItem)
        }
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNowAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        // Surfaced only when a silent read was denied: lets the user trigger the ONE
        // intentional Keychain prompt on their own terms, instead of it ambushing them.
        if currentState.status == .needsAuthorization {
            let authorize = NSMenuItem(title: "Authorize Keychain Access…",
                                       action: #selector(authorizeAction), keyEquivalent: "")
            authorize.target = self
            menu.addItem(authorize)
        }

        // Poll cadence submenu.
        let intervalItem = NSMenuItem(title: "Update Frequency", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        let current = Preferences.pollIntervalSec
        for option in Preferences.intervalOptions {
            let item = NSMenuItem(title: option.label, action: #selector(setIntervalAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.seconds
            item.state = (option.seconds == current) ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        // Launch at login.
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItemAction), keyEquivalent: "")
        login.target = self
        if LoginItem.isAvailable {
            login.state = LoginItem.isEnabled ? .on : .off
        } else {
            login.isEnabled = false
            login.toolTip = "Available when running the packaged .app"
        }
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Usage",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    @objc private func refreshNowAction() { onRefreshNow?() }

    @objc private func authorizeAction() { onAuthorize?() }

    @objc private func setIntervalAction(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        Preferences.pollIntervalSec = seconds
        onSetInterval?(seconds)
    }

    @objc private func toggleLoginItemAction() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    // MARK: - Helpers

    private func isDimmed(_ state: EngineState) -> Bool {
        if state.status.isDegraded { return true }
        if let last = state.lastSuccess, Date().timeIntervalSince(last) > Self.staleThresholdSec {
            return true
        }
        return false
    }

    private func toolTip(for state: EngineState) -> String {
        guard let snap = state.snapshot else { return state.status.reason ?? "Claude usage" }
        let s = Int((snap.session?.utilizationPct ?? 0).rounded())
        let w = Int((snap.weekly?.utilizationPct ?? 0).rounded())
        var tip = "Session \(s)% · Weekly \(w)%"
        if let reason = state.status.reason { tip += " — \(reason)" }
        return tip
    }
}
