import XCTest
@testable import ClaudeUsageCore

/// The estimator (CLU-4 §4–§5) on synthetic weeks: readings, the block-mean span rate, every
/// hiding gate, the tooltip notes, the stability replica, and repricing.
final class CapEstimatorTests: XCTestCase {
    // MARK: - Synthetic weeks

    /// A week's records: one per utilization value in `points`, in order. Cumulative tokens at a
    /// record are the sum of `tokensPerPoint(p)` for every point p below the highest utilization
    /// reached so far (so a dip adds nothing). `capturedAt` advances with utilization so a
    /// price entry effective mid-week lands at a known point.
    struct Week {
        var start: Date
        var points: [Int]
        var writer = "app"
        var share: (Int) -> Double? = { _ in 100 }
        var tokensPerPoint: (Int) -> [String: TokenCounts]
        var extraUsage: (Int) -> [String: ModelUsage] = { _ in [:] }

        func records() -> [CalibrationRecord] {
            var out: [CalibrationRecord] = []
            var reached = 0
            var cumulative: [String: TokenCounts] = [:]
            var requests: [String: Int] = [:]
            for (i, u) in points.enumerated() {
                while reached < u {
                    for (m, t) in tokensPerPoint(reached) {
                        cumulative[m] = (cumulative[m] ?? .zero) + t
                        requests[m, default: 0] += 1
                    }
                    reached += 1
                }
                var usage = cumulative.mapValues { ModelUsage(tokens: $0, requests: 0) }
                for (m, _) in usage { usage[m]?.requests = requests[m] ?? 0 }
                for (m, extra) in extraUsage(u) { usage[m] = extra }
                // Time advances with the highest utilization reached (plus the record's index), so
                // a dip still comes later than the poll before it.
                let capturedAt = start.addingTimeInterval(TimeInterval(reached) * UsageSnapshot.weeklyWindowSec / 100 + TimeInterval(i))
                out.append(CalibrationRecord(capturedAt: capturedAt, writer: writer, windowStart: start,
                                             weeklyPct: u, surfaceShares: share(u).map { ["claude_code": $0, "cowork": 100 - $0] },
                                             usage: usage))
            }
            return out
        }
    }

    let thisStart = ISO8601DateFormatter().date(from: "2026-10-02T19:00:00Z")!
    var lastStart: Date { thisStart.addingTimeInterval(-UsageSnapshot.weeklyWindowSec) }
    var now: Date { thisStart.addingTimeInterval(4 * 86400) }
    /// Prices fetched today, so G12 passes unless a test says otherwise.
    var prices: PriceHistory { PriceHistory(entries: [PriceHistory.builtInEntry], lastSuccessAt: now) }

    /// Opus 5 input tokens worth `dollars` at the built-in $5/MTok.
    func opusTokens(_ dollars: Double) -> TokenCounts { TokenCounts(input: Int((dollars / 5 * 1_000_000).rounded())) }

    /// A week whose local spend is `dollarsPerPoint(p)` for point p, all Opus 5 input tokens.
    func dollarWeek(start: Date, maxPct: Int = 80, points: [Int]? = nil, share: Double? = 100,
                    dollarsPerPoint: @escaping (Int) -> Double) -> Week {
        Week(start: start, points: points ?? Array(0...maxPct), share: { _ in share },
             tokensPerPoint: { ["claude-opus-5": self.opusTokens(dollarsPerPoint($0))] })
    }

    func evaluate(this: Week, last: Week, prices: PriceHistory? = nil, config: CapEstimator.Config = .display) -> BudgetEvaluation {
        CapEstimator.evaluateDetailed(this: this.records(), last: last.records(), prices: prices ?? self.prices, config: config, now: now)
    }

    func trend(_ e: BudgetEvaluation, file: StaticString = #filePath, line: UInt = #line) -> BudgetTrend? {
        guard case .trend(let t) = e.comparison else {
            XCTFail("expected a trend, got \(e.comparison)", file: file, line: line)
            return nil
        }
        return t
    }

    func reason(_ e: BudgetEvaluation, file: StaticString = #filePath, line: UInt = #line) -> HiddenReason? {
        guard case .hidden(let r) = e.comparison else {
            XCTFail("expected hidden, got \(e.comparison)", file: file, line: line)
            return nil
        }
        return r
    }

    /// last week at $8/pt, this week at `thisRate`/pt, both to 80%.
    func pair(thisRate: Double, lastRate: Double = 8, maxPct: Int = 80) -> (Week, Week) {
        (dollarWeek(start: thisStart, maxPct: maxPct) { _ in thisRate },
         dollarWeek(start: lastStart, maxPct: maxPct) { _ in lastRate })
    }

    // MARK: - Readings (§3)

    func testEqualRatesReadSimilar() {
        let (t, l) = pair(thisRate: 8)
        let tr = trend(evaluate(this: t, last: l))
        XCTAssertEqual(tr?.direction, .same)
        XCTAssertEqual(tr?.lineText, "Usage budget similar to last week")
        XCTAssertFalse(tr?.emphasized ?? true)
        XCTAssertEqual(tr?.ratio ?? 0, 1, accuracy: 1e-9)
    }

    func testTwentyFivePercentDropIsEmphasized() {
        let (t, l) = pair(thisRate: 6)
        let tr = trend(evaluate(this: t, last: l))
        XCTAssertEqual(tr?.reading, .down(25))
        XCTAssertTrue(tr?.emphasized ?? false)
        XCTAssertFalse(tr?.approximate ?? true)
        XCTAssertEqual(tr?.lineText, "Usage budget down 25% from last week")
        XCTAssertEqual(tr?.spanLowerPct, 0)
        XCTAssertEqual(tr?.spanUpperPct, 80)
        XCTAssertTrue(tr?.helpText.hasPrefix("API-price value of the Claude Code usage each 1% of your weekly limit covered, at the prices of the time, this week vs. last week, over the first 80% of each week.") ?? false)
    }

    func testTwentyPercentRiseIsNotEmphasized() {
        let (t, l) = pair(thisRate: 9.6)
        let tr = trend(evaluate(this: t, last: l))
        XCTAssertEqual(tr?.reading, .up(20))
        XCTAssertFalse(tr?.emphasized ?? true)
        XCTAssertEqual(tr?.lineText, "Usage budget up 20% from last week")
    }

    func testSmallerChangesAreApproximate() {
        XCTAssertEqual(trend(evaluate(this: pair(thisRate: 6.8).0, last: pair(thisRate: 6.8).1))?.lineText,
                       "Usage budget down ~15% from last week")
        XCTAssertEqual(trend(evaluate(this: pair(thisRate: 7.04).0, last: pair(thisRate: 7.04).1))?.lineText,
                       "Usage budget down ~10% from last week")
        XCTAssertEqual(trend(evaluate(this: pair(thisRate: 6.16).0, last: pair(thisRate: 6.16).1))?.lineText,
                       "Usage budget down 25% from last week", "23% rounds to 25")
    }

    func testTildeFollowsNAtTheTwentyPercentBoundary() {
        let clear = trend(evaluate(this: pair(thisRate: 8 * 0.8249).0, last: pair(thisRate: 8).1))
        XCTAssertEqual(clear?.reading, .down(20))
        XCTAssertTrue(clear?.emphasized ?? false)
        let approx = trend(evaluate(this: pair(thisRate: 8 * 0.8251).0, last: pair(thisRate: 8).1))
        XCTAssertEqual(approx?.reading, .down(15))
        XCTAssertTrue(approx?.approximate ?? false)
    }

    func testSimilarBandIsSymmetric() {
        XCTAssertEqual(CapEstimator.reading(1.10), .up(10))
        XCTAssertEqual(CapEstimator.reading(1 / 1.10), .down(10))
        XCTAssertEqual(CapEstimator.reading(1.09), .same)
        XCTAssertEqual(CapEstimator.reading(1 / 1.09), .same)
        // Swapping the weeks at the band edge leaves it in both directions.
        let (t, l) = pair(thisRate: 8.8)
        XCTAssertEqual(trend(evaluate(this: t, last: l))?.reading, .up(10))
        let swapped = (dollarWeek(start: thisStart) { _ in 8 }, dollarWeek(start: lastStart) { _ in 8.8 })
        XCTAssertEqual(trend(evaluate(this: swapped.0, last: swapped.1))?.reading, .down(10))
    }

    func testEarlyReadIsApproximateAndNoted() {
        let (t, l) = pair(thisRate: 6, maxPct: 40)
        let tr = trend(evaluate(this: t, last: l))
        XCTAssertEqual(tr?.reading, .down(25))
        XCTAssertTrue(tr?.approximate ?? false)
        XCTAssertFalse(tr?.emphasized ?? true)
        XCTAssertEqual(tr?.lineText, "Usage budget down ~25% from last week")
        XCTAssertEqual(tr?.notes, [.earlyRead(spanUpperPct: 40)])
        XCTAssertTrue(tr?.helpText.contains("Early read: based on the first 40% of each week, so it may still move.") ?? false)
    }

    // MARK: - Estimator (§4.3–4.4)

    func testSpanRateEqualsTrueSpanAverageWhenRateTriplesMidSpan() {
        // $4/pt below 60, $12/pt from 60: the true average from x = 2.5 to 77.5 is
        // (57.5·4 + 17.5·12) / 75 ≈ $5.87/pt.
        let t = dollarWeek(start: thisStart) { $0 < 60 ? 4 : 12 }
        let l = dollarWeek(start: lastStart) { _ in 8 }
        let e = evaluate(this: t, last: l)
        let trueAverage = (57.5 * 4 + 17.5 * 12) / 75
        XCTAssertEqual(e.diagnostics.kThis ?? 0, trueAverage, accuracy: 1e-6)
        XCTAssertEqual(e.diagnostics.kLast ?? 0, 8, accuracy: 1e-6)
        // An OLS slope over the same ticks weights the middle and would not give 8.
        let ticks = CapEstimator.buildSeries(t.records(), prices: prices, config: .display)!.ticks
        let xs = ticks.map(\.x), ys = ticks.map(\.y)
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let ols = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        XCTAssertGreaterThan(abs(ols - trueAverage), 0.5)
    }

    func testHeadAndTailAreFiveTickBlockMeans() {
        // A quadratic week: $ (p + 1) at point p. Expected k from the explicit 5-tick means.
        let t = dollarWeek(start: thisStart) { Double($0 + 1) }
        let l = dollarWeek(start: lastStart) { _ in 8 }
        let series = CapEstimator.buildSeries(t.records(), prices: prices, config: .display)!
        let head = series.ticks.filter { $0.x <= 4.5 }, tail = series.ticks.filter { $0.x >= 75.5 }
        XCTAssertEqual(head.count, 5)
        XCTAssertEqual(tail.count, 5)
        let mean = { (v: [Double]) in v.reduce(0, +) / Double(v.count) }
        let expected = (mean(tail.map(\.y)) - mean(head.map(\.y))) / (mean(tail.map(\.x)) - mean(head.map(\.x)))
        XCTAssertEqual(evaluate(this: t, last: l).diagnostics.kThis ?? 0, expected, accuracy: 1e-9)
        // Tick y is the midpoint of the two polls: C(u−1) + rate(u−1)/2.
        XCTAssertEqual(series.ticks[2].x, 2.5)
        XCTAssertEqual(series.ticks[2].y, 1 + 2 + 1.5, accuracy: 1e-9)
    }

    func testRateIsMeasuredAgainstClaudeCodePointsNotCumulativeShare() {
        // F4: share 50% at 40 rising to 70% at 70, spend $6 per utilization point.
        let t = Week(start: thisStart, points: Array(40...70),
                     share: { u in 50 + 20 * Double(u - 40) / 30 },
                     tokensPerPoint: { _ in ["claude-opus-5": self.opusTokens(6)] })
        let l = dollarWeek(start: lastStart) { _ in 8 }
        let e = evaluate(this: t, last: l)
        XCTAssertEqual(e.diagnostics.spanLower, 40.5)
        XCTAssertEqual(e.diagnostics.spanUpper, 69.5)
        let series = CapEstimator.buildSeries(t.records(), prices: prices, config: .display)!
        let head = series.ticks.filter { $0.x <= 44.5 }, tail = series.ticks.filter { $0.x >= 65.5 }
        let mean = { (v: [Double]) in v.reduce(0, +) / Double(v.count) }
        let dxcc = mean(tail.map { $0.xcc! }) - mean(head.map { $0.xcc! })
        let expected = (mean(tail.map(\.y)) - mean(head.map(\.y))) / dxcc
        XCTAssertEqual(e.diagnostics.kThis ?? 0, expected, accuracy: 1e-9)
        XCTAssertEqual(e.diagnostics.ccPointsThis ?? 0, dxcc, accuracy: 1e-9)
        // Dividing by the cumulative share at hi (0.70) would overstate the rate.
        XCTAssertLessThan(e.diagnostics.kThis ?? 0, 6 / 0.70 * 0.9)
    }

    func testMultiPointStepInterpolatesGapTicks() {
        let t = dollarWeek(start: thisStart, points: [0, 1, 2, 6]) { _ in 8 }
        let series = CapEstimator.buildSeries(t.records(), prices: prices, config: .display)!
        XCTAssertEqual(series.ticks.map(\.x), [0.5, 1.5, 2.5, 3.5, 4.5, 5.5])
        XCTAssertEqual(series.ticks.map(\.gap), [false, false, true, true, true, true])
        // y across the gap lies on the straight line between the two polls: C(2)=16 → C(6)=48.
        XCTAssertEqual(series.ticks[2].y, 16 + 0.5 / 4 * 32, accuracy: 1e-9)
        XCTAssertEqual(series.ticks[5].y, 16 + 3.5 / 4 * 32, accuracy: 1e-9)
    }

    func testUtilizationDipEmitsNoTicks() {
        let t = dollarWeek(start: thisStart, points: [0, 5, 10, 8, 12]) { _ in 8 }
        let series = CapEstimator.buildSeries(t.records(), prices: prices, config: .display)!
        XCTAssertEqual(series.ticks.count, 12)
        XCTAssertEqual(series.ticks.map(\.x).last, 11.5)
        XCTAssertEqual(series.ticks.filter { $0.recordIndex == 3 }.count, 0, "The dip record emits nothing")
    }

    func testMatchedSpanTruncatesToTheShorterWeek() {
        let t = dollarWeek(start: thisStart, maxPct: 80) { _ in 8 }
        let l = dollarWeek(start: lastStart, maxPct: 60) { _ in 8 }
        let e = evaluate(this: t, last: l)
        XCTAssertEqual(e.diagnostics.spanUpper, 59.5)
        XCTAssertEqual(trend(e)?.spanUpperPct, 60)
    }

    // MARK: - Gates (§5)

    func testG1NoBackToBackPreviousWindowHides() {
        let t = dollarWeek(start: thisStart) { _ in 8 }
        let twoWeeksAgo = dollarWeek(start: lastStart.addingTimeInterval(-UsageSnapshot.weeklyWindowSec)) { _ in 8 }
        XCTAssertEqual(reason(evaluate(this: t, last: twoWeeksAgo)), .noPreviousWindow)
        XCTAssertEqual(CapEstimator.evaluate(this: t.records(), last: [], prices: prices, now: now), .hidden(.noPreviousWindow))
        XCTAssertEqual(CapEstimator.evaluate(this: [], last: [], prices: prices, now: now), .hidden(.noRecords))
    }

    func testG3BelowGateHides() {
        let t = dollarWeek(start: thisStart, maxPct: 80) { _ in 8 }
        let l = dollarWeek(start: lastStart, maxPct: 25) { _ in 8 }
        XCTAssertEqual(reason(evaluate(this: t, last: l)), .belowGate(this: 80, last: 25))
    }

    func testG4TooFewTicksInSpanHides() {
        // Partly recorded this week from 55%: the overlap is 55.5–79.5, 25 ticks.
        let t = dollarWeek(start: thisStart, points: Array(55...80)) { _ in 8 }
        let l = dollarWeek(start: lastStart) { _ in 8 }
        XCTAssertEqual(reason(evaluate(this: t, last: l)), .tooFewTicks(this: 25, last: 25))
    }

    func testGapTicksDoNotCountTowardG4() {
        // 36 ticks in the span, 9 of them inferred across 3-point steps (exactly 25%, so G5
        // passes) — only 27 measured, so G4 fails.
        let points = [44, 47, 50, 53] + Array(54...80)
        let t = dollarWeek(start: thisStart, points: points) { _ in 8 }
        let l = dollarWeek(start: lastStart) { _ in 8 }
        let e = evaluate(this: t, last: l)
        XCTAssertEqual(e.diagnostics.gapShareThis ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(reason(e), .tooFewTicks(this: 27, last: 36))
    }

    func testG5TooManyGapTicksHides() {
        let points = Array(0...40) + stride(from: 44, through: 80, by: 4)
        let t = dollarWeek(start: thisStart, points: points) { _ in 8 }
        let l = dollarWeek(start: lastStart) { _ in 8 }
        XCTAssertEqual(reason(evaluate(this: t, last: l)), .tooManyGapTicks(this: 0.5, last: 0))
    }

    func testG6MissingShareHides() {
        let t = dollarWeek(start: thisStart, share: nil) { _ in 8 }
        let l = dollarWeek(start: lastStart) { _ in 8 }
        XCTAssertEqual(reason(evaluate(this: t, last: l)), .noShare)
    }

    func testG6LowShareHides() {
        let t = dollarWeek(start: thisStart, share: 20) { _ in 8 }
        let l = dollarWeek(start: lastStart, share: 94) { _ in 8 }
        XCTAssertEqual(reason(evaluate(this: t, last: l)), .lowShare(this: 0.20, last: 0.94))
    }

    func testG6ClaudeCodePointsFloor() {
        // 35-point weeks: the block means sit 30 points apart, so share × 30 is the cc points.
        let l = dollarWeek(start: lastStart, maxPct: 35) { _ in 8 }
        let fourteen = dollarWeek(start: thisStart, maxPct: 35, share: 14.0 / 30 * 100) { _ in 8 }
        let r = reason(evaluate(this: fourteen, last: l))
        guard case .tooFewClaudeCodePoints(let this, _)? = r else { return XCTFail("\(String(describing: r))") }
        XCTAssertEqual(this, 14, accuracy: 1e-6)
        let fifteen = dollarWeek(start: thisStart, maxPct: 35, share: 50) { _ in 8 }
        XCTAssertNotNil(trend(evaluate(this: fifteen, last: l)))
    }

    func testG7UnpricedRequestsHide() {
        var t = dollarWeek(start: thisStart) { _ in 8 }
        t.extraUsage = { u in ["claude-unknown-9": ModelUsage(tokens: TokenCounts(input: u * 1000), requests: u, unpriced: u)] }
        let l = dollarWeek(start: lastStart) { _ in 8 }
        let r = reason(evaluate(this: t, last: l))
        guard case .unpriced(_, _, let model)? = r else { return XCTFail("\(String(describing: r))") }
        XCTAssertEqual(model, "claude-unknown-9")
    }

    func testG8FastModeSpendHides() {
        var t = dollarWeek(start: thisStart) { _ in 8 }
        // $1/pt of fast tokens at 2× → $2/pt against $8/pt standard = 20% > 5%.
        t.extraUsage = { u in ["claude-opus-5/fast": ModelUsage(tokens: self.opusTokens(Double(u)), requests: u)] }
        let l = dollarWeek(start: lastStart) { _ in 8 }
        let r = reason(evaluate(this: t, last: l))
        guard case .fastMode(let this, let last)? = r else { return XCTFail("\(String(describing: r))") }
        XCTAssertEqual(this, 0.2, accuracy: 1e-6)
        XCTAssertEqual(last, 0)
    }

    func testG10LocalDollarsFloor() {
        let t = dollarWeek(start: thisStart) { _ in 24.0 / 79 }
        let l = dollarWeek(start: lastStart) { _ in 8 }
        let e = evaluate(this: t, last: l)
        XCTAssertEqual(e.diagnostics.localDollarsThis ?? 0, 24, accuracy: 1e-3)
        guard case .sanity? = reason(e) else { return XCTFail() }
        let ok = dollarWeek(start: thisStart) { _ in 26.0 / 79 }
        XCTAssertNotNil(trend(evaluate(this: ok, last: l)))
    }

    func testG10DecreasingClaudeCodePointsHides() {
        let t = dollarWeek(start: thisStart) { _ in 8 }
        var dropping = t
        dropping.share = { $0 <= 40 ? 90 : 50 }
        let l = dollarWeek(start: lastStart) { _ in 8 }
        guard case .sanity(let why)? = reason(evaluate(this: dropping, last: l)) else { return XCTFail() }
        XCTAssertTrue(why.contains("decrease"), why)
    }

    func testG12StalePricesHide() {
        let (t, l) = pair(thisRate: 8)
        var stale = prices
        stale.lastSuccessAt = now.addingTimeInterval(-8 * 86400)
        XCTAssertEqual(reason(evaluate(this: t, last: l, prices: stale)), .stalePrices(lastSuccessAt: stale.lastSuccessAt))
        var never = prices
        never.lastSuccessAt = nil
        XCTAssertEqual(reason(evaluate(this: t, last: l, prices: never)), .stalePrices(lastSuccessAt: nil))
    }

    /// The §5 replay: this week's local cost per point by 10-point band, against an even last
    /// week at $6.50/pt. G13 must hide it at 30%, 40%, and 50%, and show it at 60% (AC15).
    func testG13StabilityReplicaReproducesTheReplayTable() {
        let bands: [Double] = [0, 0, 7.9, 11.8, 19.2, 4.6, 0.4, 2.0]
        let l = dollarWeek(start: lastStart) { _ in 6.5 }
        func at(_ maxPct: Int) -> BudgetEvaluation {
            evaluate(this: dollarWeek(start: thisStart, maxPct: maxPct) { bands[$0 / 10] }, last: l)
        }
        for pct in [30, 40, 50] {
            let e = at(pct)
            guard case .unstable(let r, let rShort)? = reason(e) else { return XCTFail("\(pct)%: \(e.comparison)") }
            XCTAssertGreaterThan(abs(r - (rShort ?? 0)), 0.10, "\(pct)%")
        }
        let shown = at(60)
        XCTAssertNotNil(trend(shown))
        XCTAssertEqual(shown.diagnostics.kThis ?? 0, 423.5 / 55, accuracy: 1e-6)
        XCTAssertEqual(shown.diagnostics.ratio ?? 0, shown.diagnostics.ratioAtMinus10 ?? 0, accuracy: 0.10)
    }

    // MARK: - Notes (§3, §4.4)

    func testModelMixNoteNamesTheTopModels() {
        // Cost share by model: last 70/30 Opus 5 / Opus 5.5, this 40/60 → TVD 0.3, tops differ.
        func mixed(start: Date, opus5: Double, opus55: Double) -> Week {
            Week(start: start, points: Array(0...80), tokensPerPoint: { _ in
                ["claude-opus-5": self.opusTokens(8 * opus5),
                 "claude-opus-5-5": TokenCounts(input: Int((8 * opus55 / 4 * 1_000_000).rounded()))]
            })
        }
        let e = evaluate(this: mixed(start: thisStart, opus5: 0.4, opus55: 0.6),
                         last: mixed(start: lastStart, opus5: 0.7, opus55: 0.3))
        XCTAssertEqual(e.diagnostics.mixTVD ?? 0, 0.3, accuracy: 1e-9)
        let tr = trend(e)
        XCTAssertEqual(tr?.direction, .same)
        XCTAssertEqual(tr?.notes, [.modelMixChanged(lastTop: "Opus 5", thisTop: "Opus 5.5")])
        XCTAssertTrue(tr?.helpText.contains("last week was mostly Opus 5, this week mostly Opus 5.5") ?? false)
    }

    func testCacheReadShareNote() {
        func withReads(start: Date, readShare: Double) -> Week {
            Week(start: start, points: Array(0...80), tokensPerPoint: { _ in
                var t = self.opusTokens(8 * (1 - readShare))
                t.cacheRead = Int((8 * readShare / 0.5 * 1_000_000).rounded())
                return ["claude-opus-5": t]
            })
        }
        let e = evaluate(this: withReads(start: thisStart, readShare: 0.87), last: withReads(start: lastStart, readShare: 0.63))
        XCTAssertEqual(e.diagnostics.readShareThis ?? 0, 0.87, accuracy: 1e-6)
        XCTAssertEqual(trend(e)?.notes, [.cacheReadShareChanged(thisPct: 87, lastPct: 63)])
        XCTAssertNotNil(e.diagnostics.ratioNonRead)
    }

    func testPartialCoverageNoteShowsRatherThanHides() {
        let t = dollarWeek(start: thisStart, share: 72) { _ in 8 }
        let l = dollarWeek(start: lastStart, share: 94) { _ in 8 }
        let tr = trend(evaluate(this: t, last: l))
        XCTAssertEqual(tr?.notes, [.partialCoverage(thisPct: 72, lastPct: 94)])
        XCTAssertTrue(tr?.helpText.contains("Claude Code was 72% of this week's usage and 94% of last week's.") ?? false)
    }

    // MARK: - Repricing (§4.2)

    func priceEntry(opusInput: Double, effectiveFrom: Date) -> PriceHistory {
        var h = prices
        let scale = opusInput / 5
        h.append(rates: ["claude-opus-5": ModelRates(name: "Opus 5", input: opusInput, cacheWrite5m: 6.25 * scale,
                                                     cacheWrite1h: 10 * scale, cacheRead: 0.5 * scale, output: 25 * scale)],
                 fetchedAt: effectiveFrom, source: "test")
        return h
    }

    func testLatePricedModelIsBackPricedInEveryRecordAndG7Clears() {
        let t = Week(start: thisStart, points: Array(0...80),
                     tokensPerPoint: { _ in ["claude-newmodel-6": TokenCounts(input: 1_600_000)] })
        let l = dollarWeek(start: lastStart) { _ in 8 }
        guard case .unpriced? = reason(evaluate(this: t, last: l)) else { return XCTFail() }
        var h = prices
        h.append(rates: ["claude-newmodel-6": ModelRates(name: "New 6", input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5, output: 25)],
                 fetchedAt: now, source: "test")
        let e = evaluate(this: t, last: l, prices: h)
        XCTAssertEqual(trend(e)?.direction, .same)
        XCTAssertEqual(e.diagnostics.kThis ?? 0, 8, accuracy: 1e-6, "Every record repriced at once, no step in c")
    }

    func testPriceChangeMidWeekRepricesOnlyLaterIncrements() {
        // Tokens per point constant; Opus doubles at the 50% point of this week.
        let change = thisStart.addingTimeInterval(0.5 * UsageSnapshot.weeklyWindowSec)
        let h = priceEntry(opusInput: 10, effectiveFrom: change)
        let (t, l) = pair(thisRate: 8)
        let e = evaluate(this: t, last: l, prices: h)
        // Each increment is priced at its record's time: the record at 50% is the first after
        // the change, so its increment (point 49) is already at the new rate. Head block at
        // $8/pt, tail block at $16/pt: C(77.5) − C(2.5) over 75 points.
        let tailMean: Double = 49 * 8 + 28.5 * 16
        let headMean: Double = 2.5 * 8
        let expected = (tailMean - headMean) / 75
        XCTAssertEqual(e.diagnostics.kThis ?? 0, expected, accuracy: 1e-6)
        XCTAssertEqual(e.diagnostics.kLast ?? 0, 8, accuracy: 1e-6, "Last week was entirely before the change")
    }

    func testInterleavedWritersAreEvaluatedFromOneSeries() {
        let app = dollarWeek(start: thisStart) { _ in 6 }
        var daemon = app
        daemon.writer = "daemon"
        daemon.tokensPerPoint = { _ in ["claude-opus-5": self.opusTokens(12)] }
        let l = dollarWeek(start: lastStart) { _ in 8 }
        let interleaved = zip(app.records(), daemon.records()).flatMap { [$0.0, $0.1] }
        let e = CapEstimator.evaluateDetailed(this: interleaved, last: l.records(), prices: prices, now: now)
        XCTAssertEqual(e, evaluate(this: app, last: l), "The app's series wins; the daemon's is ignored")
        XCTAssertEqual(trend(e)?.reading, .down(25))
    }

    func testShadowConfigReadsWhereDisplayHides() {
        let (t, l) = pair(thisRate: 6, maxPct: 22)
        XCTAssertEqual(reason(evaluate(this: t, last: l)), .belowGate(this: 22, last: 22))
        let shadow = evaluate(this: t, last: l, config: .shadow)
        XCTAssertEqual(trend(shadow)?.reading, .down(25))
        XCTAssertEqual(shadow.diagnostics.ratio ?? 0, 0.75, accuracy: 1e-9)
    }

    // MARK: - The owner's price examples (§2)

    func testListPriceCutWithMatchingPlanCutReadsDownWithAWashNote() {
        // Opus drops 20% at this week's start; tokens per point are unchanged.
        let h = priceEntry(opusInput: 4, effectiveFrom: thisStart)
        let (t, l) = pair(thisRate: 8)
        let tr = trend(evaluate(this: t, last: l, prices: h))
        XCTAssertEqual(tr?.reading, .down(20))
        XCTAssertTrue(tr?.emphasized ?? false)
        XCTAssertEqual(tr?.notes, [.pricesChanged(equalPrices: .same)])
        XCTAssertTrue(tr?.helpText.contains("With the same prices in both weeks this would read “similar”. In usable work, that's roughly a wash.") ?? false)
    }

    func testListPriceCutWithPlanDollarsHeldReadsSimilarWithUpNote() {
        // Price drops 20% but the plan's dollars per point hold: 25% more tokens per point.
        let h = priceEntry(opusInput: 4, effectiveFrom: thisStart)
        let t = Week(start: thisStart, points: Array(0...80), tokensPerPoint: { _ in ["claude-opus-5": self.opusTokens(10)] })
        let l = dollarWeek(start: lastStart) { _ in 8 }
        let tr = trend(evaluate(this: t, last: l, prices: h))
        XCTAssertEqual(tr?.direction, .same)
        XCTAssertEqual(tr?.notes, [.pricesChanged(equalPrices: .up(25))])
        XCTAssertTrue(tr?.helpText.contains("this would read “up 25%”.") ?? false)
        XCTAssertFalse(tr?.helpText.contains("wash") ?? true)
    }

    func testNoPriceChangeNoNote() {
        let (t, l) = pair(thisRate: 6)
        XCTAssertEqual(trend(evaluate(this: t, last: l))?.notes, [])
    }

    // MARK: - Tracker log line

    func testDescribeCarriesKSpanShareTicksAndPrices() {
        let (t, l) = pair(thisRate: 6)
        let e = evaluate(this: t, last: l)
        let s = BudgetTracker.describe(e)
        XCTAssertTrue(s.hasPrefix("down 25% (k $6.00 vs $8.00 per Claude Code point over 0.5–79.5%, share 100%/100%, ticks 80/80, prices built-in)"), s)
        var stale = prices
        stale.lastSuccessAt = nil
        let hidden = BudgetTracker.describe(evaluate(this: t, last: l, prices: stale))
        XCTAssertTrue(hidden.hasPrefix("hidden — stale prices"), hidden)
    }
}
