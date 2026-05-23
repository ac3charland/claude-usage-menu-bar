import Foundation

public struct UsageSnapshot: Codable {
    public let capturedAt: Date
    public let session: WindowState?
    public let weekly: WindowState?

    public struct WindowState: Codable {
        public let utilizationPct: Double
        public let resetsAt: Date
        public let elapsedFraction: Double
        public let isAhead: Bool

        public init(utilizationPct: Double, resetsAt: Date, elapsedFraction: Double, isAhead: Bool) {
            self.utilizationPct = utilizationPct
            self.resetsAt = resetsAt
            self.elapsedFraction = elapsedFraction
            self.isAhead = isAhead
        }
    }

    public init(capturedAt: Date, session: WindowState?, weekly: WindowState?) {
        self.capturedAt = capturedAt
        self.session = session
        self.weekly = weekly
    }

    /// 5-hour session window length.
    public static let sessionWindowSec: TimeInterval = 5 * 3600
    /// 7-day weekly window length.
    public static let weeklyWindowSec: TimeInterval = 7 * 24 * 3600

    public static func from(_ response: UsageResponse, now: Date = Date()) -> UsageSnapshot {
        return UsageSnapshot(
            capturedAt: now,
            session: response.fiveHour.map { compute(window: $0, lengthSec: sessionWindowSec, now: now) },
            weekly: response.sevenDay.map { compute(window: $0, lengthSec: weeklyWindowSec, now: now) }
        )
    }

    private static func compute(window: UsageWindow, lengthSec: TimeInterval, now: Date) -> WindowState {
        let start = window.resetsAt.addingTimeInterval(-lengthSec)
        let rawElapsed = now.timeIntervalSince(start) / lengthSec
        let elapsed = min(max(rawElapsed, 0), 1)
        let isAhead = (window.utilization / 100.0) > elapsed
        return WindowState(
            utilizationPct: window.utilization,
            resetsAt: window.resetsAt,
            elapsedFraction: elapsed,
            isAhead: isAhead
        )
    }

    public var shortDescription: String {
        func describe(_ w: WindowState?, _ label: String) -> String {
            guard let w else { return "\(label)=nil" }
            let mark = w.isAhead ? "↑ahead" : "·on-pace"
            return "\(label)=\(String(format: "%.1f", w.utilizationPct))% (elapsed \(String(format: "%.1f", w.elapsedFraction * 100))% \(mark))"
        }
        return "\(describe(session, "session"))  \(describe(weekly, "weekly"))"
    }
}
