import Foundation

/// Orchestrates the CLU-4 pipeline around each poll (spec §6.6): keeps the price history
/// current, scans transcripts, appends calibration records, and evaluates the week-over-week
/// budget comparison. Every failure is logged and leaves the trend unchanged; nothing here
/// touches `EngineStatus`, the back-off, or the snapshot.
@MainActor
public final class BudgetTracker {
    public let writer: String
    private let scanner: TranscriptScanner
    private let log: CalibrationLog
    private let priceStore: PriceHistoryStore
    private var prices: PriceHistory

    /// The comparison currently on screen (`.trend`) or the reason it is hidden.
    public private(set) var lastDisplay: BudgetComparison?
    public var trend: BudgetTrend? { lastDisplay?.trend }
    private var lastShadow: ShadowReading?
    private var warnedWindow: Date?
    private var loggedPricingRejectionDay: Date?

    public init(writer: String = "app",
                scanner: TranscriptScanner? = nil,
                log: CalibrationLog? = nil,
                priceStore: PriceHistoryStore? = nil) {
        self.writer = writer
        self.scanner = scanner ?? TranscriptScanner()
        self.log = log ?? CalibrationLog(directory: CalibrationLog.defaultDirectory)
        self.priceStore = priceStore ?? PriceHistoryStore(directory: PriceHistoryStore.defaultDirectory)
        self.prices = self.priceStore.load()
        self.lastShadow = self.log.lastReading()
    }

    /// Evaluate from the calibration files on disk so the line paints on first publish, like the
    /// cached snapshot. No transcript scan is needed for this.
    @discardableResult
    public func loadInitial(now: Date = Date()) -> BudgetTrend? {
        let (current, previous) = log.currentAndPrevious(now: now)
        guard let current else { return nil }
        let this = log.records(windowStart: current)
        let last = previous.map { log.records(windowStart: $0) } ?? []
        let result = CapEstimator.evaluateDetailed(this: this, last: last, prices: prices, config: .display, now: now)
        lastDisplay = result.comparison
        Log.info("Budget trend at launch: \(Self.describe(result))")
        return result.comparison.trend
    }

    /// Run after a successful poll has been published. Returns true when the displayed trend
    /// changed and the engine should publish again.
    public func afterPoll(response: UsageResponse, snapshot: UsageSnapshot, now: Date = Date()) async -> Bool {
        guard let resetsAt = response.sevenDay?.resetsAt else { return false }
        let windowStart = CalibrationRecord.windowKey(resetsAt: resetsAt)

        // Cross-check against the endpoint's own window start (settles CLU-3 open question 5).
        if let reported = response.sevenDayBreakdown?.windowStartedAt,
           abs(reported.timeIntervalSince(windowStart)) > 60, warnedWindow != windowStart {
            warnedWindow = windowStart
            Log.warn("Weekly window start from resets_at − 7d (\(windowStart)) differs from window_started_at (\(reported)) by more than 60 s — using resets_at")
        }

        await refreshPricesIfDue(now: now)

        guard let usage = await scanner.usage(since: windowStart, upTo: snapshot.capturedAt, prices: prices) else {
            return false
        }
        let record = CalibrationRecord(
            capturedAt: snapshot.capturedAt,
            writer: writer,
            windowStart: windowStart,
            weeklyPct: Int((response.sevenDay?.utilization ?? 0).rounded()),
            surfaceShares: response.surfaceShares,
            scopedPct: Dictionary(uniqueKeysWithValues: snapshot.weeklyModels.map { ($0.label, $0.state.utilizationPct) }),
            usage: usage.models
        )
        guard log.observe(record) else { return false }

        // Ticks change only on writes, so only then re-evaluate.
        let (_, previous) = log.currentAndPrevious(now: now)
        let this = log.records(windowStart: windowStart)
        let last = previous.map { log.records(windowStart: $0) } ?? []

        let display = CapEstimator.evaluateDetailed(this: this, last: last, prices: prices, config: .display, now: now)
        var changed = false
        if display.comparison != lastDisplay {
            lastDisplay = display.comparison
            changed = true
            Log.info("Budget trend: \(Self.describe(display))")
        }

        let shadow = CapEstimator.evaluateDetailed(this: this, last: last, prices: prices, config: .shadow, now: now)
        let reading = Self.shadowReading(shadow, windowStart: windowStart, now: now)
        if lastShadow.map({ !$0.sameReading(as: reading) }) ?? true {
            lastShadow = reading
            log.appendReading(reading)
        }
        return changed
    }

    private func refreshPricesIfDue(now: Date) async {
        guard PricingFetcher.isDue(prices, now: now) else { return }
        var updated = prices
        let outcome = await PricingFetcher.refresh(&updated, now: now)
        prices = updated
        priceStore.save(prices)
        switch outcome {
        case .appended:
            Log.info("Pricing page fetched: new price entry recorded (\(prices.latestEntry.rates.count) models)")
        case .unchanged:
            Log.info("Pricing page fetched: prices unchanged")
        case .rejected(let why):
            // Once per day, so a broken page doesn't spam the log on every retry.
            let day = Calendar.current.startOfDay(for: now)
            if loggedPricingRejectionDay != day {
                loggedPricingRejectionDay = day
                Log.warn("Pricing page rejected, keeping last good table: \(why)")
            }
        }
    }

    // MARK: - Formatting

    nonisolated static func describe(_ e: BudgetEvaluation) -> String {
        let d = e.diagnostics
        func money(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "n/a" }
        func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a" }
        func span() -> String {
            guard let lo = d.spanLower, let hi = d.spanUpper else { return "n/a" }
            return String(format: "%.1f–%.1f%%", lo, hi)
        }
        let priceDay = d.priceEntry.map { $0 == .distantPast ? "built-in" : Self.dayFormatter.string(from: $0) } ?? "n/a"
        let detail = "k \(money(d.kThis)) vs \(money(d.kLast)) per Claude Code point over \(span()), share \(pct(d.shareThis))/\(pct(d.shareLast)), ticks \(d.ticksThis ?? 0)/\(d.ticksLast ?? 0), prices \(priceDay)"
        switch e.comparison {
        case .trend(let t):
            var notes: [String] = []
            if let eq = d.equalPriceReading, t.notes.contains(where: { if case .pricesChanged = $0 { return true } else { return false } }) {
                notes.append("prices→\(BudgetTrend.describe(eq))")
            }
            for n in t.notes {
                switch n {
                case .earlyRead: notes.append("early read")
                case .modelMixChanged: notes.append("model mix")
                case .cacheReadShareChanged: notes.append("cache-read share")
                case .partialCoverage: notes.append("coverage")
                case .pricesChanged: break
                }
            }
            let noteText = notes.isEmpty ? "" : "; notes: \(notes.joined(separator: ", "))"
            return "\(BudgetTrend.describe(t.reading))\(t.approximate ? " (approximate)" : "") (\(detail)\(noteText))"
        case .hidden(let reason):
            let eq = d.equalPriceReading.map { ", equal prices \(BudgetTrend.describe($0))" } ?? ""
            return "hidden — \(reason) (\(detail)\(eq))"
        }
    }

    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated static func shadowReading(_ e: BudgetEvaluation, windowStart: Date, now: Date) -> ShadowReading {
        let d = e.diagnostics
        var r = ShadowReading(evaluatedAt: now, windowStart: windowStart, shown: e.comparison.trend != nil)
        r.spanLower = d.spanLower
        r.spanUpper = d.spanUpper
        r.kThis = d.kThis
        r.kLast = d.kLast
        r.ratio = d.ratio
        r.ratioEqualPrices = d.ratioEqualPrices
        r.ratioNonRead = d.ratioNonRead
        r.ratioAtMinus10 = d.ratioAtMinus10
        r.ccPointsThis = d.ccPointsThis
        r.ccPointsLast = d.ccPointsLast
        r.localDollarsThis = d.localDollarsThis
        r.localDollarsLast = d.localDollarsLast
        r.readShareThis = d.readShareThis
        r.readShareLast = d.readShareLast
        r.shareThis = d.shareThis
        r.shareLast = d.shareLast
        r.mixTVD = d.mixTVD
        r.ticksThis = d.ticksThis
        r.ticksLast = d.ticksLast
        r.gapShareThis = d.gapShareThis
        r.gapShareLast = d.gapShareLast
        if case .hidden(let reason) = e.comparison { r.hiddenReason = reason.description }
        return r
    }
}
