import Foundation
import ClaudeUsageCore

/// UserDefaults-backed settings. Deliberately minimal: per the design's fixed visual
/// bands (open question 4), there is no user-configurable near-cap threshold — only the
/// poll cadence is exposed.
enum Preferences {
    private static let intervalKey = "pollIntervalSec"
    private static let loginItemInitKey = "didInitializeLoginItem"

    /// Tracks whether the open-at-login default has been applied. Set once on first
    /// launch so re-applying the default never overrides a user who turned it off.
    static var didInitializeLoginItem: Bool {
        get { UserDefaults.standard.bool(forKey: loginItemInitKey) }
        set { UserDefaults.standard.set(newValue, forKey: loginItemInitKey) }
    }

    /// Selectable poll cadences shown in the menu.
    static let intervalOptions: [(label: String, seconds: TimeInterval)] = [
        ("Fast (1 min)", 60),
        ("Normal (2 min)", 120),
        ("Relaxed (5 min)", 300),
    ]

    static var pollIntervalSec: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: intervalKey)
            return v > 0 ? v : UsageEngine.defaultBaseIntervalSec
        }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }
}
