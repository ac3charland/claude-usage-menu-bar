import Foundation

// MARK: - Results

public struct BudgetTrend: Equatable {
    public enum Direction: Equatable { case same, down, up }
    public enum Reading: Equatable { case same, down(Int), up(Int) }
    /// Tooltip sentences, in §3 order.
    public enum Note: Equatable {
        case earlyRead(spanUpperPct: Int)
        case pricesChanged(equalPrices: Reading)
        /// Display names, only when the top model differs (otherwise both nil).
        case modelMixChanged(lastTop: String?, thisTop: String?)
        case cacheReadShareChanged(thisPct: Int, lastPct: Int)
        case partialCoverage(thisPct: Int, lastPct: Int)
    }

    public let direction: Direction
    /// N from reading(r) in §3; 0 for `.same`.
    public let displayPct: Int
    /// Shows "~": N < 20, or an early read.
    public let approximate: Bool
    /// Down, 20% or more, span reaches 50%.
    public let emphasized: Bool
    /// L and S for the tooltip, e.g. 1 and 64.
    public let spanLowerPct: Int
    public let spanUpperPct: Int
    /// Raw k_this / k_last, for logs.
    public let ratio: Double
    public let notes: [Note]

    public init(direction: Direction, displayPct: Int, approximate: Bool, emphasized: Bool,
                spanLowerPct: Int, spanUpperPct: Int, ratio: Double, notes: [Note]) {
        self.direction = direction
        self.displayPct = displayPct
        self.approximate = approximate
        self.emphasized = emphasized
        self.spanLowerPct = spanLowerPct
        self.spanUpperPct = spanUpperPct
        self.ratio = ratio
        self.notes = notes
    }

    public var reading: Reading {
        switch direction {
        case .same: return .same
        case .down: return .down(displayPct)
        case .up: return .up(displayPct)
        }
    }

    // MARK: Copy (§3)

    /// The one line under the Weekly bar.
    public var lineText: String {
        switch direction {
        case .same: return "Usage budget similar to last week"
        case .down: return "Usage budget down \(approximate ? "~" : "")\(displayPct)% from last week"
        case .up: return "Usage budget up \(approximate ? "~" : "")\(displayPct)% from last week"
        }
    }

    static func describe(_ r: Reading) -> String {
        switch r {
        case .same: return "similar"
        case .down(let n): return "down \(n)%"
        case .up(let n): return "up \(n)%"
        }
    }

    /// The hover tooltip: what the line measures, then any notes that apply.
    public var helpText: String {
        let span = spanLowerPct < 1
            ? "over the first \(spanUpperPct)% of each week"
            : "from \(spanLowerPct)% to \(spanUpperPct)% of each week"
        var parts = ["API-price value of the Claude Code usage each 1% of your weekly limit covered, at the prices of the time, this week vs. last week, \(span)."]
        for note in notes {
            switch note {
            case .earlyRead(let s):
                parts.append("Early read: based on the first \(s)% of each week, so it may still move.")
            case .pricesChanged(let equal):
                var s = "API prices changed since last week. With the same prices in both weeks this would read “\(Self.describe(equal))”."
                if equal == .same { s += " In usable work, that's roughly a wash." }
                parts.append(s)
            case .modelMixChanged(let lastTop, let thisTop):
                if let l = lastTop, let t = thisTop {
                    parts.append("Your model mix changed: last week was mostly \(l), this week mostly \(t). That alone can move this number.")
                } else {
                    parts.append("Your model mix changed. That alone can move this number.")
                }
            case .cacheReadShareChanged(let t, let l):
                parts.append("Cache reads were \(t)% of this week's local dollars and \(l)% of last week's. The plan may not count them at list price, and that alone can move this number.")
            case .partialCoverage(let t, let l):
                parts.append("Claude Code was \(t)% of this week's usage and \(l)% of last week's. Only sessions on this Mac are measured; the rest is assumed to count against the limit the same way.")
            }
        }
        return parts.joined(separator: " ")
    }
}

public enum HiddenReason: Equatable, CustomStringConvertible {
    case noRecords
    case noPreviousWindow                                   // G1
    case belowGate(this: Int, last: Int)                    // G3
    case tooFewTicks(this: Int, last: Int)                  // G4
    case tooManyGapTicks(this: Double, last: Double)        // G5
    case noShare                                            // G6
    case lowShare(this: Double, last: Double)               // G6
    case tooFewClaudeCodePoints(this: Double, last: Double) // G6
    case unpriced(this: Double, last: Double, model: String?) // G7
    case fastMode(this: Double, last: Double)               // G8
    case sanity(String)                                     // G10
    case stalePrices(lastSuccessAt: Date?)                  // G12
    case unstable(r: Double, rShort: Double?)               // G13

    public var description: String {
        func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
        func f2(_ v: Double) -> String { String(format: "%.2f", v) }
        switch self {
        case .noRecords: return "no records"
        case .noPreviousWindow: return "no back-to-back previous window"
        case .belowGate(let t, let l): return "below gate (this \(t)%, last \(l)%)"
        case .tooFewTicks(let t, let l): return "too few ticks in span (\(t)/\(l))"
        case .tooManyGapTicks(let t, let l): return "too many gap ticks (\(pct(t))/\(pct(l)))"
        case .noShare: return "no Claude Code share"
        case .lowShare(let t, let l): return "Claude Code share too low (\(pct(t))/\(pct(l)))"
        case .tooFewClaudeCodePoints(let t, let l): return "too few Claude Code points in span (\(f2(t))/\(f2(l)))"
        case .unpriced(let t, let l, let m): return "unpriced requests (\(pct(t))/\(pct(l)))\(m.map { ", model \($0)" } ?? "")"
        case .fastMode(let t, let l): return "fast-mode spend (\(pct(t))/\(pct(l)))"
        case .sanity(let s): return "sanity: \(s)"
        case .stalePrices(let d): return "stale prices (last fetch \(d.map { "\($0)" } ?? "never"))"
        case .unstable(let r, let s): return "unstable (r \(f2(r)), \(s.map(f2) ?? "n/a") ten points earlier)"
        }
    }
}

public enum BudgetComparison: Equatable {
    case trend(BudgetTrend)
    case hidden(HiddenReason)

    public var trend: BudgetTrend? {
        if case .trend(let t) = self { return t }
        return nil
    }
}

/// Everything the log line (AC10) and the shadow reading (§6.4) need, computed as far as the
/// data allows even when a gate hides the line.
public struct BudgetDiagnostics: Equatable {
    public var spanLower: Double?
    public var spanUpper: Double?
    public var kThis: Double?
    public var kLast: Double?
    public var ratio: Double?
    public var ratioEqualPrices: Double?
    public var ratioNonRead: Double?
    public var ratioAtMinus10: Double?
    public var ccPointsThis: Double?
    public var ccPointsLast: Double?
    public var localDollarsThis: Double?
    public var localDollarsLast: Double?
    public var readShareThis: Double?
    public var readShareLast: Double?
    public var shareThis: Double?
    public var shareLast: Double?
    public var mixTVD: Double?
    public var ticksThis: Int?
    public var ticksLast: Int?
    public var gapShareThis: Double?
    public var gapShareLast: Double?
    /// `effectiveFrom` of the latest price entry used.
    public var priceEntry: Date?
    public var equalPriceReading: BudgetTrend.Reading?

    public init() {}
}

public struct BudgetEvaluation: Equatable {
    public let comparison: BudgetComparison
    public let diagnostics: BudgetDiagnostics
}

// MARK: - Estimator

/// Pure: no I/O, clock, or global state (spec §6.5). The price history and `now` are passed in.
public enum CapEstimator {
    public struct Config: Equatable {
        public var minMaxPct: Int = 30                     // G3
        public var minTicks: Int = 30                      // G4
        public var maxGapShare: Double = 0.25              // G5
        public var minShare: Double = 0.25                 // G6
        public var minCcPoints: Double = 15                // G6
        public var coverageNoteBelow: Double = 0.90        // G6 note
        public var maxUnpricedShare: Double = 0.01         // G7
        public var maxFastShare: Double = 0.05             // G8
        public var fastPriceMultiplier: Double = 2         // G8
        public var mixNoteTVD: Double = 0.20               // G9
        public var minLocalDollars: Double = 25            // G10
        public var maxPriceAgeSec: TimeInterval = 7 * 24 * 3600 // G12
        public var stabilityTolerance: Double = 0.10       // G13
        public var stabilityShortenPts: Double = 10        // G13
        public var applyStability: Bool = true             // G13: recorded, not applied, in shadow
        public var similarBand: Double = 1.10              // §3
        public var clearChangePct: Int = 20                // §3
        public var earlyReadBelow: Double = 49.5           // §3/§4.4: hi < this → early read
        public var readNoteDelta: Double = 0.10            // §4.4
        public var backToBackToleranceSec: TimeInterval = 3600 // G1
        public var blockTicks: Int = 5                     // §4.4
        public var gapStep: Int = 2                        // §4.3: step > 2 points is a gap

        public init() {}

        public static let display = Config()
        public static let shadow: Config = {
            var c = Config()
            c.minMaxPct = 20
            c.minTicks = 20
            c.applyStability = false
            return c
        }()
    }

    // MARK: Reading (§3)

    /// The single place the shown reading is derived from r, so "~" and N can never disagree.
    public static func reading(_ r: Double, config: Config = .display) -> BudgetTrend.Reading {
        guard r > 0, r.isFinite else { return .same }
        // A hair inside the band edge, so r = 1.10 and r = 1/1.10 both leave it regardless of rounding.
        if abs(log(r)) < log(config.similarBand) - 1e-9 { return .same }
        let n = max(10, 5 * Int((abs(r - 1) * 100 / 5 + 0.5).rounded(.down)))
        return r < 1 ? .down(n) : .up(n)
    }

    // MARK: Series

    struct Tick {
        let x: Double          // utilization crossed
        let y: Double          // cost interpolated across the gap
        let share: Double?     // Claude Code share at the crossing
        let gap: Bool          // inferred across a step of more than `gapStep` points
        let recordIndex: Int   // the record whose step produced this tick
        var xcc: Double? { share.map { x * $0 } }
    }

    struct Series {
        let windowStart: Date
        let records: [CalibrationRecord]
        var cost: [Double] = []          // c_i, time-of-use prices
        var costEqual: [Double] = []     // c′_i, latest prices for every increment
        var costNonRead: [Double] = []   // cnr_i
        var costRead: [Double] = []      // cache-read dollars only
        var costFast: [Double] = []      // fast-mode dollars at the estimate multiplier
        var requests: [Int] = []
        var unpricedRequests: [Int] = []
        var unpricedModel: String?
        var deltaByModel: [[String: Double]] = []
        var ticks: [Tick] = []
        var maxPct: Int = 0
    }

    /// Pick one writer's series (§4.2): the app's, or else the writer with the most records.
    static func selectWriter(_ records: [CalibrationRecord]) -> [CalibrationRecord] {
        let byWriter = Dictionary(grouping: records, by: \.writer)
        let chosen = byWriter["app"] ?? byWriter.values.max { $0.count < $1.count } ?? []
        var seen = Set<Date>()
        return chosen.sorted { $0.capturedAt < $1.capturedAt }.filter { seen.insert($0.capturedAt).inserted }
    }

    static func buildSeries(_ input: [CalibrationRecord], prices: PriceHistory, config: Config) -> Series? {
        let records = selectWriter(input)
        guard let first = records.first else { return nil }
        var s = Series(windowStart: first.windowStart, records: records)
        var prevTokens: [String: TokenCounts] = [:]
        var prevRequests: [String: Int] = [:]
        var cum = (cost: 0.0, equal: 0.0, nonRead: 0.0, read: 0.0, fast: 0.0, req: 0, unpriced: 0)

        for r in records {
            var byModel: [String: Double] = [:]
            for (model, mu) in r.usage {
                let dTok = mu.tokens.delta(from: prevTokens[model] ?? .zero)
                let dReq = max(0, mu.requests - (prevRequests[model] ?? 0))
                prevTokens[model] = mu.tokens
                prevRequests[model] = mu.requests
                cum.req += dReq
                let rates = prices.rates(model, at: r.capturedAt)
                if model.hasSuffix("/fast") {
                    if let rates {
                        cum.fast += PriceHistory.cost(dTok, rates) * config.fastPriceMultiplier
                    } else {
                        cum.unpriced += dReq
                        if dReq > 0 { s.unpricedModel = model }
                    }
                    continue
                }
                guard let rates else {
                    cum.unpriced += dReq
                    if dReq > 0 || !dTok.isZero { s.unpricedModel = model }
                    continue
                }
                let c = PriceHistory.cost(dTok, rates)
                let nr = PriceHistory.cost(dTok.withoutCacheRead, rates)
                cum.cost += c
                cum.nonRead += nr
                cum.read += c - nr
                cum.equal += PriceHistory.cost(dTok, prices.latestRates(model) ?? rates)
                if c > 0 { byModel[model, default: 0] += c }
            }
            s.cost.append(cum.cost)
            s.costEqual.append(cum.equal)
            s.costNonRead.append(cum.nonRead)
            s.costRead.append(cum.read)
            s.costFast.append(cum.fast)
            s.requests.append(cum.req)
            s.unpricedRequests.append(cum.unpriced)
            s.deltaByModel.append(byModel)
            s.maxPct = max(s.maxPct, r.weeklyPct)
        }

        // Ticks (§4.3): each crossed point between consecutive records becomes one tick. Shares
        // carry forward when a record lacks the breakdown.
        var M = records[0].weeklyPct
        var lastShare = records[0].claudeCodeShare
        for i in 1..<records.count {
            let u = records[i].weeklyPct
            if let sh = records[i].claudeCodeShare { lastShare = sh }
            guard u > M else { continue }
            let step = u - M
            for j in 1...step {
                let x = Double(M) + Double(j) - 0.5
                let y = s.cost[i - 1] + (Double(j) - 0.5) / Double(step) * (s.cost[i] - s.cost[i - 1])
                s.ticks.append(Tick(x: x, y: y, share: lastShare, gap: step > config.gapStep, recordIndex: i))
            }
            M = u
        }
        return s
    }

    /// Block-mean span rate (§4.4) against Claude Code points, over ticks with lo ≤ x ≤ hi.
    /// Returns nil when the span is too short for two non-overlapping blocks or a share is missing.
    struct SpanRate {
        let k: Double
        let ccPoints: Double
        let dollars: Double     // mean(tail.y) − mean(head.y)
    }

    static func spanRate(_ ticks: [Tick], lo: Double, hi: Double, y: (Tick) -> Double, config: Config) -> SpanRate? {
        let sub = ticks.filter { $0.x >= lo - 1e-9 && $0.x <= hi + 1e-9 }
        let b = Double(config.blockTicks - 1)
        let head = sub.filter { $0.x <= lo + b + 1e-9 }
        let tail = sub.filter { $0.x >= hi - b - 1e-9 }
        guard sub.count >= 2 * config.blockTicks, !head.isEmpty, !tail.isEmpty,
              head.allSatisfy({ $0.share != nil }), tail.allSatisfy({ $0.share != nil }) else { return nil }
        func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }
        let dy = mean(tail.map(y)) - mean(head.map(y))
        let dx = mean(tail.map { $0.xcc! }) - mean(head.map { $0.xcc! })
        guard dx != 0 else { return nil }
        return SpanRate(k: dy / dx, ccPoints: dx, dollars: dy)
    }

    // MARK: Evaluate

    public static func evaluate(this: [CalibrationRecord], last: [CalibrationRecord],
                                prices: PriceHistory, config: Config = .display,
                                now: Date = Date()) -> BudgetComparison {
        evaluateDetailed(this: this, last: last, prices: prices, config: config, now: now).comparison
    }

    public static func evaluateDetailed(this: [CalibrationRecord], last: [CalibrationRecord],
                                        prices: PriceHistory, config: Config = .display,
                                        now: Date = Date()) -> BudgetEvaluation {
        var d = BudgetDiagnostics()
        d.priceEntry = prices.latestEntry.effectiveFrom
        func hidden(_ r: HiddenReason) -> BudgetEvaluation { BudgetEvaluation(comparison: .hidden(r), diagnostics: d) }

        guard let tw = buildSeries(this, prices: prices, config: config) else { return hidden(.noRecords) }
        // G1: previous window recorded and back to back.
        guard let lw = buildSeries(last, prices: prices, config: config),
              abs(lw.windowStart.addingTimeInterval(UsageSnapshot.weeklyWindowSec).timeIntervalSince(tw.windowStart))
                <= config.backToBackToleranceSec else {
            return hidden(.noPreviousWindow)
        }

        // G3: both windows reached the gate.
        guard tw.maxPct >= config.minMaxPct, lw.maxPct >= config.minMaxPct else {
            return hidden(.belowGate(this: tw.maxPct, last: lw.maxPct))
        }

        // Matched span (§4.4).
        guard let tFirst = tw.ticks.first, let tLast = tw.ticks.last,
              let lFirst = lw.ticks.first, let lLast = lw.ticks.last else {
            return hidden(.tooFewTicks(this: tw.ticks.count, last: lw.ticks.count))
        }
        let lo = max(tFirst.x, lFirst.x)
        let hi = min(tLast.x, lLast.x)
        d.spanLower = lo
        d.spanUpper = hi
        let tSpan = tw.ticks.filter { $0.x >= lo && $0.x <= hi }
        let lSpan = lw.ticks.filter { $0.x >= lo && $0.x <= hi }
        let tMeasured = tSpan.filter { !$0.gap }.count
        let lMeasured = lSpan.filter { !$0.gap }.count
        d.ticksThis = tMeasured
        d.ticksLast = lMeasured
        d.gapShareThis = tSpan.isEmpty ? nil : Double(tSpan.count - tMeasured) / Double(tSpan.count)
        d.gapShareLast = lSpan.isEmpty ? nil : Double(lSpan.count - lMeasured) / Double(lSpan.count)
        d.shareThis = tSpan.last?.share
        d.shareLast = lSpan.last?.share

        // Span sums for the diagnostics that are ratios over the span.
        func spanSums(_ s: Series, _ span: [Tick]) -> (cost: Double, read: Double, fast: Double, req: Int, unpriced: Int, byModel: [String: Double]) {
            guard let a = span.first?.recordIndex, let b = span.last?.recordIndex, a > 0 else {
                return (0, 0, 0, 0, 0, [:])
            }
            let lo = a - 1, hi = b
            var byModel: [String: Double] = [:]
            for i in (lo + 1)...hi { for (m, c) in s.deltaByModel[i] { byModel[m, default: 0] += c } }
            return (s.cost[hi] - s.cost[lo], s.costRead[hi] - s.costRead[lo], s.costFast[hi] - s.costFast[lo],
                    s.requests[hi] - s.requests[lo], s.unpricedRequests[hi] - s.unpricedRequests[lo], byModel)
        }
        let tSums = spanSums(tw, tSpan)
        let lSums = spanSums(lw, lSpan)
        if let a = tSpan.first, let b = tSpan.last { d.localDollarsThis = b.y - a.y }
        if let a = lSpan.first, let b = lSpan.last { d.localDollarsLast = b.y - a.y }
        d.readShareThis = tSums.cost > 0 ? tSums.read / tSums.cost : nil
        d.readShareLast = lSums.cost > 0 ? lSums.read / lSums.cost : nil
        let mix = modelMix(tSums.byModel, lSums.byModel)
        d.mixTVD = mix.tvd

        // Rates, computed whenever the span allows so shadow readings still carry the ratio.
        let tRate = spanRate(tw.ticks, lo: lo, hi: hi, y: \.y, config: config)
        let lRate = spanRate(lw.ticks, lo: lo, hi: hi, y: \.y, config: config)
        d.kThis = tRate?.k
        d.kLast = lRate?.k
        d.ccPointsThis = tRate?.ccPoints
        d.ccPointsLast = lRate?.ccPoints
        var ratio: Double?
        if let t = tRate, let l = lRate, l.k > 0 { ratio = t.k / l.k }
        d.ratio = ratio
        if let t = spanRate(tw.ticks, lo: lo, hi: hi, y: { interpolate(tw.costEqual, tw, $0) }, config: config),
           let l = spanRate(lw.ticks, lo: lo, hi: hi, y: { interpolate(lw.costEqual, lw, $0) }, config: config),
           l.k > 0 {
            d.ratioEqualPrices = t.k / l.k
        }
        if let t = spanRate(tw.ticks, lo: lo, hi: hi, y: { interpolate(tw.costNonRead, tw, $0) }, config: config),
           let l = spanRate(lw.ticks, lo: lo, hi: hi, y: { interpolate(lw.costNonRead, lw, $0) }, config: config),
           l.k > 0 {
            d.ratioNonRead = t.k / l.k
        }
        var ratioShort: Double?
        if let t = spanRate(tw.ticks, lo: lo, hi: hi - config.stabilityShortenPts, y: \.y, config: config),
           let l = spanRate(lw.ticks, lo: lo, hi: hi - config.stabilityShortenPts, y: \.y, config: config),
           l.k > 0 {
            ratioShort = t.k / l.k
        }
        d.ratioAtMinus10 = ratioShort
        if let r = d.ratioEqualPrices { d.equalPriceReading = reading(r, config: config) }

        // G4: non-gap ticks in the matched span, per week.
        guard tMeasured >= config.minTicks, lMeasured >= config.minTicks else {
            return hidden(.tooFewTicks(this: tMeasured, last: lMeasured))
        }
        // G5: share of gap ticks.
        if let gt = d.gapShareThis, let gl = d.gapShareLast, gt > config.maxGapShare || gl > config.maxGapShare {
            return hidden(.tooManyGapTicks(this: gt, last: gl))
        }
        // G6: share present, share at hi, Claude Code points across the span.
        guard let shareThis = d.shareThis, let shareLast = d.shareLast,
              tSpan.allSatisfy({ $0.share != nil }), lSpan.allSatisfy({ $0.share != nil }) else {
            return hidden(.noShare)
        }
        guard shareThis >= config.minShare, shareLast >= config.minShare else {
            return hidden(.lowShare(this: shareThis, last: shareLast))
        }
        guard let tR = tRate, let lR = lRate else {
            return hidden(.tooFewTicks(this: tMeasured, last: lMeasured))
        }
        guard tR.ccPoints >= config.minCcPoints, lR.ccPoints >= config.minCcPoints else {
            return hidden(.tooFewClaudeCodePoints(this: tR.ccPoints, last: lR.ccPoints))
        }
        // G7: unpriced requests over the span.
        let tUnpriced = tSums.req > 0 ? Double(tSums.unpriced) / Double(tSums.req) : 0
        let lUnpriced = lSums.req > 0 ? Double(lSums.unpriced) / Double(lSums.req) : 0
        guard tUnpriced <= config.maxUnpricedShare, lUnpriced <= config.maxUnpricedShare else {
            return hidden(.unpriced(this: tUnpriced, last: lUnpriced, model: tw.unpricedModel ?? lw.unpricedModel))
        }
        // G8: fast-mode spend.
        let tFast = (tSums.cost + tSums.fast) > 0 ? tSums.fast / (tSums.cost + tSums.fast) : 0
        let lFast = (lSums.cost + lSums.fast) > 0 ? lSums.fast / (lSums.cost + lSums.fast) : 0
        guard tFast <= config.maxFastShare, lFast <= config.maxFastShare else {
            return hidden(.fastMode(this: tFast, last: lFast))
        }
        // G10: sanity.
        guard tR.k > 0, lR.k > 0 else { return hidden(.sanity("k not positive (\(tR.k), \(lR.k))")) }
        guard let dt = d.localDollarsThis, let dl = d.localDollarsLast,
              dt >= config.minLocalDollars, dl >= config.minLocalDollars else {
            return hidden(.sanity(String(format: "local $ over span %.2f/%.2f below $%.0f",
                                         d.localDollarsThis ?? 0, d.localDollarsLast ?? 0, config.minLocalDollars)))
        }
        if let bad = firstDecreasingXcc(tSpan) ?? firstDecreasingXcc(lSpan) {
            return hidden(.sanity("Claude Code points decrease at \(bad)%"))
        }
        // G12: prices are current.
        guard let fetched = prices.lastSuccessAt, now.timeIntervalSince(fetched) <= config.maxPriceAgeSec else {
            return hidden(.stalePrices(lastSuccessAt: prices.lastSuccessAt))
        }
        guard let r = ratio else { return hidden(.sanity("ratio not computable")) }
        // G13: stable reading.
        if config.applyStability {
            guard let rs = ratioShort, abs(r - rs) <= config.stabilityTolerance else {
                return hidden(.unstable(r: r, rShort: ratioShort))
            }
        }

        // Reading and notes (§3, §4.4).
        let read = reading(r, config: config)
        let earlyRead = hi < config.earlyReadBelow
        let spanLowerPct = Int(lo.rounded(.down))
        let spanUpperPct = Int(hi.rounded(.up))
        var notes: [BudgetTrend.Note] = []
        if earlyRead { notes.append(.earlyRead(spanUpperPct: spanUpperPct)) }
        let modelsUsed = Set(tSums.byModel.keys).union(lSums.byModel.keys)
        if let equal = d.equalPriceReading, equal != read,
           prices.priceChanged(models: modelsUsed, since: lw.windowStart) {
            notes.append(.pricesChanged(equalPrices: equal))
        }
        if mix.tvd > config.mixNoteTVD {
            let differ = mix.thisTop != mix.lastTop
            notes.append(.modelMixChanged(lastTop: differ ? displayName(mix.lastTop, prices) : nil,
                                          thisTop: differ ? displayName(mix.thisTop, prices) : nil))
        }
        if let rt = d.readShareThis, let rl = d.readShareLast, abs(rt - rl) > config.readNoteDelta {
            notes.append(.cacheReadShareChanged(thisPct: Int((rt * 100).rounded()), lastPct: Int((rl * 100).rounded())))
        }
        if min(shareThis, shareLast) < config.coverageNoteBelow {
            notes.append(.partialCoverage(thisPct: Int((shareThis * 100).rounded()), lastPct: Int((shareLast * 100).rounded())))
        }

        let direction: BudgetTrend.Direction
        let n: Int
        switch read {
        case .same: direction = .same; n = 0
        case .down(let v): direction = .down; n = v
        case .up(let v): direction = .up; n = v
        }
        let approximate = direction != .same && (n < config.clearChangePct || earlyRead)
        let trend = BudgetTrend(direction: direction, displayPct: n, approximate: approximate,
                                emphasized: direction == .down && !approximate,
                                spanLowerPct: spanLowerPct, spanUpperPct: spanUpperPct,
                                ratio: r, notes: notes)
        return BudgetEvaluation(comparison: .trend(trend), diagnostics: d)
    }

    // MARK: Helpers

    /// Interpolate an alternative cumulative series at a tick, using the same fraction of the
    /// gap the tick's cost used.
    static func interpolate(_ series: [Double], _ s: Series, _ t: Tick) -> Double {
        let i = t.recordIndex
        let c0 = s.cost[i - 1], c1 = s.cost[i]
        let frac = c1 - c0 > 1e-12 ? (t.y - c0) / (c1 - c0) : 0.5
        return series[i - 1] + frac * (series[i] - series[i - 1])
    }

    /// Total-variation distance of cost share by model, and each week's top model by cost.
    static func modelMix(_ a: [String: Double], _ b: [String: Double]) -> (tvd: Double, thisTop: String?, lastTop: String?) {
        let ta = a.values.reduce(0, +), tb = b.values.reduce(0, +)
        guard ta > 0, tb > 0 else { return (0, nil, nil) }
        var tvd = 0.0
        for m in Set(a.keys).union(b.keys) {
            tvd += abs((a[m] ?? 0) / ta - (b[m] ?? 0) / tb)
        }
        return (tvd / 2, a.max { $0.value < $1.value }?.key, b.max { $0.value < $1.value }?.key)
    }

    static func displayName(_ model: String?, _ prices: PriceHistory) -> String? {
        guard let m = model else { return nil }
        return prices.latestRates(m)?.name ?? m
    }

    /// The x of the first tick whose Claude Code points fall below the previous tick's, beyond
    /// share rounding (0.5% of weeklyPct). `nil` when non-decreasing.
    static func firstDecreasingXcc(_ span: [Tick]) -> Double? {
        var prev: Double?
        for t in span {
            guard let x = t.xcc else { continue }
            if let p = prev, x < p - 0.005 * t.x - 1e-9 { return t.x }
            prev = x
        }
        return nil
    }
}
