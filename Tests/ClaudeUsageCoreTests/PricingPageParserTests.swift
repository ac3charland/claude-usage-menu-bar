import XCTest
@testable import ClaudeUsageCore

/// The model table from the live pricing.md of 2026-09-24 (CLU-4 §6.2), with its footnote
/// markers, links, and "retired" / "limited availability" parentheticals kept verbatim.
final class PricingPageParserTests: XCTestCase {
    static let fixture = """
    # Pricing

    Some prose before the table.

    | Model                                                                                                                                 | Base input tokens     | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens          |
    | :------------------------------------------------------------------------------------------------------------------------------------ | :-------------------- | :-------------- | :-------------- | :----------------------- | :--------------------- |
    | Claude Fable 5.1                                                                                                                      | $10 / MTok            | $12.50 / MTok   | $20 / MTok      | $0.25 / MTok<sup>1</sup> | $50 / MTok             |
    | Claude Mythos 5.1 ([limited availability](https://anthropic.com/glasswing))                                                           | $10 / MTok            | $12.50 / MTok   | $20 / MTok      | $0.25 / MTok<sup>1</sup> | $50 / MTok             |
    | Claude Fable 5                                                                                                                        | $10 / MTok            | $12.50 / MTok   | $20 / MTok      | $1 / MTok                | $50 / MTok             |
    | Claude Mythos 5 ([limited availability](https://anthropic.com/glasswing))                                                             | $10 / MTok            | $12.50 / MTok   | $20 / MTok      | $1 / MTok                | $50 / MTok             |
    | Claude Opus 5.5                                                                                                                       | $4 / MTok             | $5 / MTok       | $8 / MTok       | $0.20 / MTok<sup>2</sup> | $20 / MTok             |
    | Claude Opus 5                                                                                                                         | $5 / MTok             | $6.25 / MTok    | $10 / MTok      | $0.50 / MTok             | $25 / MTok             |
    | Claude Opus 4.8                                                                                                                       | $5 / MTok             | $6.25 / MTok    | $10 / MTok      | $0.50 / MTok             | $25 / MTok             |
    | Claude Opus 4.7                                                                                                                       | $5 / MTok             | $6.25 / MTok    | $10 / MTok      | $0.50 / MTok             | $25 / MTok             |
    | Claude Opus 4.6                                                                                                                       | $5 / MTok             | $6.25 / MTok    | $10 / MTok      | $0.50 / MTok             | $25 / MTok             |
    | Claude Opus 4.5                                                                                                                       | $5 / MTok             | $6.25 / MTok    | $10 / MTok      | $0.50 / MTok             | $25 / MTok             |
    | Claude Opus 4.1 ([retired, except on Bedrock and Google Cloud](https://platform.claude.com/docs/en/about-claude/model-deprecations))  | $15 / MTok            | $18.75 / MTok   | $30 / MTok      | $1.50 / MTok             | $75 / MTok             |
    | Claude Opus 4 ([retired, except on Google Cloud](https://platform.claude.com/docs/en/about-claude/model-deprecations))                | $15 / MTok            | $18.75 / MTok   | $30 / MTok      | $1.50 / MTok             | $75 / MTok             |
    | Claude Sonnet 5                                                                                                                       | $2 / MTok<sup>3</sup> | $2.50 / MTok    | $4 / MTok       | $0.20 / MTok             | $10 / MTok<sup>3</sup> |
    | Claude Sonnet 4.6                                                                                                                     | $3 / MTok             | $3.75 / MTok    | $6 / MTok       | $0.30 / MTok             | $15 / MTok             |
    | Claude Sonnet 4.5                                                                                                                     | $3 / MTok             | $3.75 / MTok    | $6 / MTok       | $0.30 / MTok             | $15 / MTok             |
    | Claude Sonnet 4 ([retired, except on Bedrock and Google Cloud](https://platform.claude.com/docs/en/about-claude/model-deprecations))  | $3 / MTok             | $3.75 / MTok    | $6 / MTok       | $0.30 / MTok             | $15 / MTok             |
    | Claude Haiku 4.5                                                                                                                      | $1 / MTok             | $1.25 / MTok    | $2 / MTok       | $0.10 / MTok             | $5 / MTok              |
    | Claude Haiku 3.5 ([retired, except on Bedrock and Google Cloud](https://platform.claude.com/docs/en/about-claude/model-deprecations)) | $0.80 / MTok          | $1 / MTok       | $1.60 / MTok    | $0.08 / MTok             | $4 / MTok              |

    *<sup>1 Cache hits and refreshes on Claude Fable 5.1 and Claude Mythos 5.1 are priced at 0.025x the base input price.</sup>*

    *<sup>2 Cache hits and refreshes on Claude Opus 5.5 are priced at 0.05x the base input price.</sup>*

    | Other table | Col |
    | :-- | :-- |
    | x | y |
    """

    func testParsesLiveTableToBuiltInRates() throws {
        let rates = try PricingPageParser.parse(markdown: Self.fixture, known: Set(PriceHistory.builtInRates.keys))
        XCTAssertEqual(rates.count, 18)
        for (id, expected) in PriceHistory.builtInRates {
            XCTAssertEqual(rates[id], expected, "\(id) should match the built-in table")
        }
        XCTAssertEqual(rates["claude-mythos-5-1"]?.cacheRead, 0.25, "Footnote marker stripped from the price cell")
        XCTAssertEqual(rates["claude-opus-4-1"]?.input, 15, "Parenthetical + link stripped from the model cell")
        XCTAssertEqual(rates["claude-haiku-3-5"]?.input, 0.80)
        XCTAssertEqual(rates["claude-sonnet-5"]?.output, 10, "Footnote on the output cell")
        XCTAssertEqual(rates["claude-opus-5-5"]?.name, "Opus 5.5")
    }

    func testModelIDDerivation() {
        XCTAssertEqual(PricingPageParser.modelID(fromName: "Claude Opus 5.5"), "claude-opus-5-5")
        XCTAssertEqual(PricingPageParser.modelID(fromName: "Claude Haiku 4.5"), "claude-haiku-4-5")
        XCTAssertEqual(PricingPageParser.modelID(fromName: "Claude Sonnet 5"), "claude-sonnet-5")
    }

    func testChangedHeaderRejectsFetch() {
        let md = Self.fixture.replacingOccurrences(of: "Cache hits and refreshes", with: "Cache reads")
        XCTAssertThrowsError(try PricingPageParser.parse(markdown: md)) { err in
            XCTAssertEqual(err as? PricingPageParseError, .headerNotFound)
        }
    }

    func testFewerThanFiveRowsRejectsFetch() {
        let lines = Self.fixture.components(separatedBy: "\n")
        let header = lines.firstIndex { $0.contains("| Model") }!
        let md = (lines[...(header + 1)] + lines[(header + 2)..<(header + 6)]).joined(separator: "\n")
        XCTAssertThrowsError(try PricingPageParser.parse(markdown: md)) { err in
            XCTAssertEqual(err as? PricingPageParseError, .tooFewRows(4))
        }
    }

    func testMalformedPriceRejectsFetch() {
        let md = Self.fixture.replacingOccurrences(of: "| $5 / MTok             | $6.25 / MTok", with: "| 5 dollars             | $6.25 / MTok")
        XCTAssertThrowsError(try PricingPageParser.parse(markdown: md)) { err in
            guard case .malformedPrice(let model, _)? = err as? PricingPageParseError else { return XCTFail("\(err)") }
            XCTAssertEqual(model, "Claude Opus 5")
        }
    }

    func testOrderingViolationRejectsFetch() {
        // Cache read priced above input for Opus 5.
        let md = Self.fixture.replacingOccurrences(of: "| $10 / MTok      | $0.50 / MTok             | $25 / MTok", with: "| $10 / MTok      | $6 / MTok                | $25 / MTok")
        XCTAssertThrowsError(try PricingPageParser.parse(markdown: md)) { err in
            XCTAssertEqual(err as? PricingPageParseError, .orderingViolation(model: "Claude Opus 5"))
        }
    }

    func testMoreThanHalfKnownModelsMissingRejectsFetch() {
        let known: Set<String> = ["claude-opus-5", "claude-zeta-1", "claude-zeta-2", "claude-zeta-3"]
        XCTAssertThrowsError(try PricingPageParser.parse(markdown: Self.fixture, known: known)) { err in
            XCTAssertEqual(err as? PricingPageParseError, .tooManyKnownModelsMissing(missing: 3, known: 4))
        }
        // Exactly half missing is tolerated.
        XCTAssertNoThrow(try PricingPageParser.parse(markdown: Self.fixture, known: ["claude-opus-5", "claude-zeta-1"]))
    }

    func testApplyAppendsOnceThenReportsUnchanged() {
        var h = PriceHistory.builtIn
        let now = Date()
        XCTAssertEqual(PricingFetcher.apply(markdown: Self.fixture, to: &h, now: now), .appended,
                       "The live page prices models the built-in table lacks, so it is a new entry")
        XCTAssertEqual(h.entries.count, 2)
        XCTAssertEqual(h.lastSuccessAt, now)
        XCTAssertEqual(PricingFetcher.apply(markdown: Self.fixture, to: &h, now: now.addingTimeInterval(86400)), .unchanged)
        XCTAssertEqual(h.entries.count, 2)
        // A rejected page keeps the table and records only the attempt.
        let before = h
        let outcome = PricingFetcher.apply(markdown: "nothing here", to: &h, now: now.addingTimeInterval(2 * 86400))
        guard case .rejected = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(h.entries, before.entries)
        XCTAssertEqual(h.lastSuccessAt, before.lastSuccessAt)
        XCTAssertEqual(h.lastAttemptAt, now.addingTimeInterval(2 * 86400))
    }
}
