import Foundation

public struct UsageSnapshot: Codable {
    public let capturedAt: Date
    public let session: WindowState?
    public let weekly: WindowState?
    /// Per-model weekly caps (e.g. Fable), each shaped like `weekly` (same 7-day window +
    /// pace math) and labeled by the model's display name. Rendered dynamically: whatever the
    /// API reports, in order. Empty when the API reports no per-model caps.
    public let weeklyModels: [WeeklyModel]

    public struct WindowState: Codable, Equatable {
        public let utilizationPct: Double
        /// Nil when the window is empty/fully reset and the API reports no reset time.
        public let resetsAt: Date?
        public let elapsedFraction: Double
        public let isAhead: Bool

        public init(utilizationPct: Double, resetsAt: Date?, elapsedFraction: Double, isAhead: Bool) {
            self.utilizationPct = utilizationPct
            self.resetsAt = resetsAt
            self.elapsedFraction = elapsedFraction
            self.isAhead = isAhead
        }
    }

    /// A named weekly per-model window (label + its pace-aware state).
    public struct WeeklyModel: Codable, Equatable {
        public let label: String
        public let state: WindowState

        public init(label: String, state: WindowState) {
            self.label = label
            self.state = state
        }
    }

    public init(capturedAt: Date, session: WindowState?, weekly: WindowState?, weeklyModels: [WeeklyModel] = []) {
        self.capturedAt = capturedAt
        self.session = session
        self.weekly = weekly
        self.weeklyModels = weeklyModels
    }

    enum CodingKeys: String, CodingKey {
        case capturedAt, session, weekly, weeklyModels
    }

    // Custom decode so snapshots cached before `weeklyModels` existed still load (missing key
    // → empty list) rather than failing the whole read and forcing a cold first paint.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        session = try c.decodeIfPresent(WindowState.self, forKey: .session)
        weekly = try c.decodeIfPresent(WindowState.self, forKey: .weekly)
        weeklyModels = try c.decodeIfPresent([WeeklyModel].self, forKey: .weeklyModels) ?? []
    }

    /// 5-hour session window length.
    public static let sessionWindowSec: TimeInterval = 5 * 3600
    /// 7-day weekly window length.
    public static let weeklyWindowSec: TimeInterval = 7 * 24 * 3600

    public static func from(_ response: UsageResponse, now: Date = Date()) -> UsageSnapshot {
        return UsageSnapshot(
            capturedAt: now,
            session: response.fiveHour.map { compute(window: $0, lengthSec: sessionWindowSec, now: now) },
            weekly: response.sevenDay.map { compute(window: $0, lengthSec: weeklyWindowSec, now: now) },
            weeklyModels: response.weeklyModelLimits.map {
                WeeklyModel(label: $0.name, state: compute(window: $0.window, lengthSec: weeklyWindowSec, now: now))
            }
        )
    }

    private static func compute(window: UsageWindow, lengthSec: TimeInterval, now: Date) -> WindowState {
        // With no reset time the window is empty/fresh, so treat it as 0% elapsed.
        // Any non-zero utilization then reads as "ahead", which is the safe direction.
        let elapsed: Double
        if let resetsAt = window.resetsAt {
            let start = resetsAt.addingTimeInterval(-lengthSec)
            let rawElapsed = now.timeIntervalSince(start) / lengthSec
            elapsed = min(max(rawElapsed, 0), 1)
        } else {
            elapsed = 0
        }
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
        var parts = [describe(session, "session"), describe(weekly, "weekly")]
        parts += weeklyModels.map { describe($0.state, $0.label.lowercased()) }
        return parts.joined(separator: "  ")
    }
}
