import XCTest
@testable import ClaudeUsageCore

/// Pins the price table and the dated lookup (CLU-4 §6.2), including the CLU-3 §5 oracle: the
/// one request whose cost Claude Code's own OpenTelemetry metric reported.
final class PriceHistoryTests: XCTestCase {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testOracleRequestCostsExactly() {
        // haiku-4-5: in 10, out 60, cacheRead 13,701, cacheWrite 1h 9,463 → $0.0206061 (CLU-3 §5).
        let tokens = TokenCounts(input: 10, cacheWrite5m: 0, cacheWrite1h: 9_463, cacheRead: 13_701, output: 60)
        let cost = PriceHistory.builtIn.cost(tokens, model: "claude-haiku-4-5", at: Date())
        XCTAssertEqual(try XCTUnwrap(cost), 0.0206061, accuracy: 1e-9)
    }

    func testFable51CacheReadIsQuarterDollar() {
        XCTAssertEqual(PriceHistory.builtIn.rates("claude-fable-5-1", at: Date())?.cacheRead, 0.25)
        XCTAssertEqual(PriceHistory.builtIn.rates("claude-fable-5", at: Date())?.cacheRead, 1.00)
    }

    func testDatedModelIDsNormalize() {
        XCTAssertEqual(PriceHistory.normalize("claude-haiku-4-5-20251001"), "claude-haiku-4-5")
        XCTAssertEqual(PriceHistory.normalize("claude-opus-5"), "claude-opus-5")
        XCTAssertEqual(PriceHistory.normalize("claude-opus-5/fast"), "claude-opus-5")
        XCTAssertEqual(PriceHistory.builtIn.rates("claude-haiku-4-5-20251001", at: Date())?.input, 1)
    }

    func testLookupReturnsEntryInEffectAtTime() {
        var h = PriceHistory.builtIn
        let change = date("2026-10-05T12:00:00Z")
        var rates = PriceHistory.builtInRates
        rates["claude-opus-5"] = ModelRates(name: "Opus 5", input: 4, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.4, output: 20)
        XCTAssertTrue(h.append(rates: rates, fetchedAt: change, source: "test"))
        XCTAssertEqual(h.rates("claude-opus-5", at: change.addingTimeInterval(-1))?.input, 5)
        XCTAssertEqual(h.rates("claude-opus-5", at: change)?.input, 4)
        XCTAssertEqual(h.rates("claude-opus-5", at: change.addingTimeInterval(86400))?.input, 4)
    }

    func testModelMissingFromEntryUsesEarliestLaterEntry() {
        var h = PriceHistory.builtIn
        let launch = date("2026-10-05T12:00:00Z")
        var rates = PriceHistory.builtInRates
        rates["claude-opus-6"] = ModelRates(name: "Opus 6", input: 6, cacheWrite5m: 7.5, cacheWrite1h: 12, cacheRead: 0.6, output: 30)
        h.append(rates: rates, fetchedAt: launch, source: "test")
        // Used before the fetch that first priced it: launch price applies back to first use.
        XCTAssertEqual(h.rates("claude-opus-6", at: launch.addingTimeInterval(-86400))?.input, 6)
    }

    func testUnknownModelReturnsNil() {
        XCTAssertNil(PriceHistory.builtIn.rates("claude-unknown-9", at: Date()))
        XCTAssertNil(PriceHistory.builtIn.cost(TokenCounts(input: 1), model: "claude-unknown-9", at: Date()))
    }

    func testIdenticalFetchAppendsNothing() {
        var h = PriceHistory.builtIn
        XCTAssertFalse(h.append(rates: PriceHistory.builtInRates, fetchedAt: Date(), source: "test"))
        XCTAssertEqual(h.entries.count, 1)
    }

    func testModelMissingFromFetchKeepsLastRates() {
        var h = PriceHistory.builtIn
        var rates = PriceHistory.builtInRates
        rates.removeValue(forKey: "claude-fable-5")
        rates["claude-opus-5-5"] = ModelRates(name: "Opus 5.5", input: 3, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.15, output: 15)
        XCTAssertTrue(h.append(rates: rates, fetchedAt: Date(), source: "test"))
        XCTAssertEqual(h.latestEntry.rates["claude-fable-5"]?.input, 10, "Retired model keeps its last known rates")
        XCTAssertEqual(h.latestEntry.rates["claude-opus-5-5"]?.input, 3)
    }

    func testPriceChangedSince() {
        var h = PriceHistory.builtIn
        let lastWeek = date("2026-10-02T19:00:00Z")
        XCTAssertFalse(h.priceChanged(models: ["claude-opus-5"], since: lastWeek))
        var rates = PriceHistory.builtInRates
        rates["claude-opus-5"] = ModelRates(name: "Opus 5", input: 4, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.4, output: 20)
        h.append(rates: rates, fetchedAt: date("2026-10-06T19:00:00Z"), source: "test")
        XCTAssertTrue(h.priceChanged(models: ["claude-opus-5"], since: lastWeek))
        XCTAssertFalse(h.priceChanged(models: ["claude-sonnet-5"], since: lastWeek), "Only the models used matter")
        XCTAssertFalse(h.priceChanged(models: ["claude-opus-5"], since: date("2026-10-07T00:00:00Z")))
    }

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("price-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PriceHistoryStore(directory: dir)
        var h = store.load()
        XCTAssertEqual(h.entries.count, 1)
        XCTAssertNil(h.lastSuccessAt)
        var rates = PriceHistory.builtInRates
        rates["claude-opus-5"] = ModelRates(name: "Opus 5", input: 4, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.4, output: 20)
        let t = date("2026-10-06T19:00:00Z")
        h.append(rates: rates, fetchedAt: t, source: "test")
        h.lastSuccessAt = t
        h.lastAttemptAt = t
        store.save(h)
        let loaded = store.load()
        XCTAssertEqual(loaded.entries.count, 2)
        XCTAssertEqual(loaded.rates("claude-opus-5", at: t)?.input, 4)
        XCTAssertEqual(loaded.lastSuccessAt, t)
    }

    func testFetchCadence() {
        var h = PriceHistory.builtIn
        let now = date("2026-10-06T19:00:00Z")
        XCTAssertTrue(PricingFetcher.isDue(h, now: now), "Never attempted → due")
        h.lastAttemptAt = now
        h.lastSuccessAt = now
        XCTAssertFalse(PricingFetcher.isDue(h, now: now.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(PricingFetcher.isDue(h, now: now.addingTimeInterval(24 * 3600)))
        // A failure retries after an hour.
        h.lastAttemptAt = now.addingTimeInterval(24 * 3600)
        XCTAssertFalse(PricingFetcher.isDue(h, now: now.addingTimeInterval(24 * 3600 + 1800)))
        XCTAssertTrue(PricingFetcher.isDue(h, now: now.addingTimeInterval(25 * 3600)))
    }
}
