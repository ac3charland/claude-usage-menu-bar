import Foundation

/// Health of the data pipeline, surfaced to the UI for the degraded icon + panel reason line.
/// (Resolves open question 2: degraded states.)
public enum EngineStatus: Equatable {
    case ok                 // a fresh poll just succeeded
    case stale              // last good snapshot is older than the stale threshold
    case noToken            // Keychain item missing/unreadable
    case signedOut          // credentials present but blank — the CLI cleared them; needs `claude /login`
    case refreshFailed      // token rejected and a forced refresh did not fix it
    case rateLimited        // HTTP 429
    case offline            // transport error (no network, timeout, DNS, …)
    case error              // any other unexpected failure (HTTP 5xx, decode, error envelope)

    /// One-line, user-facing reason for the panel. `nil` when healthy.
    public var reason: String? {
        switch self {
        case .ok: return nil
        case .stale: return "Data may be out of date"
        case .noToken: return "Sign in to Claude Code to see usage"
        case .signedOut: return "Signed out — run claude /login in a terminal"
        case .refreshFailed: return "Couldn’t refresh login — run claude /login"
        case .rateLimited: return "Rate limited — retrying shortly"
        case .offline: return "Offline — showing last known usage"
        case .error: return "Couldn’t reach Claude — showing last known usage"
        }
    }

    /// Whether the icon should render in its dimmed/degraded form.
    public var isDegraded: Bool { self != .ok }
}

/// Immutable snapshot of what the UI should render right now: the last good data plus health.
public struct EngineState {
    public let snapshot: UsageSnapshot?
    public let status: EngineStatus
    public let lastSuccess: Date?

    public init(snapshot: UsageSnapshot?, status: EngineStatus, lastSuccess: Date?) {
        self.snapshot = snapshot
        self.status = status
        self.lastSuccess = lastSuccess
    }

    public static let empty = EngineState(snapshot: nil, status: .stale, lastSuccess: nil)
}
