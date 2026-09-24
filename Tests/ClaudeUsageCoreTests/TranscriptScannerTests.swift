import XCTest
@testable import ClaudeUsageCore

/// The transcript scanner (CLU-4 §6.3) against temp-dir fixtures shaped like real Claude Code
/// transcript rows. Nothing here touches the real `~/.claude`.
final class TranscriptScannerTests: XCTestCase {
    private var root: URL!
    private let windowStart = ISO8601DateFormatter().date(from: "2026-09-18T19:00:00Z")!
    private let upTo = ISO8601DateFormatter().date(from: "2026-09-25T19:00:00Z")!
    private var prices: PriceHistory { PriceHistory.builtIn }

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transcripts-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("-Users-me-proj"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// One transcript row, shaped like the real thing (content fields included so the decoder
    /// has to ignore them). `cw5m`/`cw1h` nil → no `cache_creation` block (flat fallback path).
    private func row(ts: String = "2026-09-20T12:00:00.000Z", req: String? = "req_1", session: String = "sess_1",
                     msg: String = "msg_1", model: String = "claude-opus-5", input: Int = 100, flatCacheWrite: Int = 0,
                     cw5m: Int? = nil, cw1h: Int? = nil, read: Int = 0, output: Int = 10, web: Int = 0,
                     speed: String = "standard", type: String = "assistant") -> String {
        let reqField = req.map { "\"requestId\":\"\($0)\"," } ?? ""
        let cacheCreation: String
        if let cw5m, let cw1h {
            cacheCreation = ",\"cache_creation\":{\"ephemeral_5m_input_tokens\":\(cw5m),\"ephemeral_1h_input_tokens\":\(cw1h)}"
        } else {
            cacheCreation = ""
        }
        return """
        {"parentUuid":"p","isSidechain":false,"userType":"external","cwd":"/Users/me/proj","sessionId":"\(session)","version":"2.1.278","gitBranch":"main","type":"\(type)","uuid":"u-\(UUID().uuidString)","timestamp":"\(ts)",\(reqField)"message":{"id":"\(msg)","type":"message","role":"assistant","model":"\(model)","content":[{"type":"text","text":"secret prompt content that must never be kept"}],"stop_reason":null,"usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(flatCacheWrite),"cache_read_input_tokens":\(read),"output_tokens":\(output),"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_search_requests":\(web),"web_fetch_requests":0},"service_tier":"standard"\(cacheCreation),"speed":"\(speed)"}}}
        """
    }

    private func write(_ lines: [String], to relative: String = "-Users-me-proj/session-a.jsonl", trailingNewline: Bool = true) {
        let url = root.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try! text.write(to: url, atomically: false, encoding: .utf8)
    }

    private func append(_ lines: [String], to relative: String = "-Users-me-proj/session-a.jsonl", trailingNewline: Bool = true) {
        let url = root.appendingPathComponent(relative)
        let h = try! FileHandle(forWritingTo: url)
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        h.write(Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8))
    }

    private func scan(_ scanner: TranscriptScanner, prices: PriceHistory? = nil) async -> WindowUsage {
        await scanner.usage(since: windowStart, upTo: upTo, prices: prices ?? self.prices) ?? WindowUsage()
    }

    // MARK: Tests

    func testPrefilterNeverRejectsAValidRow() {
        XCTAssertTrue(TranscriptScanner.mightBeAssistantUsageRow(row()))
        // The compact shape Claude Code actually writes, with no spaces after separators.
        let compact = #"{"type":"assistant","timestamp":"2026-09-21T17:32:03.190Z","requestId":"req_x","message":{"id":"m","model":"claude-opus-5","usage":{"input_tokens":2,"output_tokens":1}}}"#
        XCTAssertTrue(TranscriptScanner.mightBeAssistantUsageRow(compact))
        XCTAssertFalse(TranscriptScanner.mightBeAssistantUsageRow(#"{"type":"user","message":{"role":"user","content":"hi"}}"#))
    }

    func testStreamingRowsTakePerFieldMaxNotFirstWins() async {
        write([row(output: 10), row(output: 300), row(output: 120)])
        let u = await scan(TranscriptScanner(root: root))
        let m = u.models["claude-opus-5"]
        XCTAssertEqual(m?.requests, 1)
        XCTAssertEqual(m?.output, 300, "per-field max: the final streaming snapshot wins")
        XCTAssertEqual(m?.input, 100)
    }

    func testSameRequestInTwoFilesCountsOnce() async {
        write([row()], to: "-Users-me-proj/session-a.jsonl")
        write([row(session: "sess_forked")], to: "-Users-me-proj/session-b.jsonl")
        let u = await scan(TranscriptScanner(root: root))
        XCTAssertEqual(u.requests, 1)
    }

    func testNestedSubagentFileIsIncluded() async {
        write([row(req: "req_main", msg: "msg_main")])
        write([row(req: "req_sub", msg: "msg_sub", input: 50)], to: "-Users-me-proj/session-a/subagents/agent-abc.jsonl")
        let u = await scan(TranscriptScanner(root: root))
        XCTAssertEqual(u.requests, 2)
        XCTAssertEqual(u.models["claude-opus-5"]?.input, 150)
    }

    func testSyntheticRowsAreDropped() async {
        write([row(), row(req: "req_syn", msg: "msg_syn", model: "<synthetic>", input: 999)])
        let u = await scan(TranscriptScanner(root: root))
        XCTAssertEqual(u.requests, 1)
        XCTAssertNil(u.models["<synthetic>"])
    }

    func testRowsBeforeWindowStartAreExcluded() async {
        write([row(ts: "2026-09-18T18:59:59.000Z", req: "req_old", msg: "msg_old"), row()])
        let u = await scan(TranscriptScanner(root: root))
        XCTAssertEqual(u.requests, 1)
    }

    func testRowsAfterUpToAreExcludedButRemembered() async {
        write([row(), row(ts: "2026-09-26T00:00:00.000Z", req: "req_late", msg: "msg_late")])
        let scanner = TranscriptScanner(root: root)
        let u = await scan(scanner)
        XCTAssertEqual(u.requests, 1)
        let later = await scanner.usage(since: windowStart, upTo: upTo.addingTimeInterval(86400), prices: prices)
        XCTAssertEqual(later?.requests, 2, "A row past the poll time is picked up once the poll time passes it")
    }

    func testMissingRequestIDFallsBackToSessionScopedKey() async {
        write([row(req: nil, session: "s1", msg: "m1", output: 5), row(req: nil, session: "s1", msg: "m1", output: 50)])
        write([row(req: nil, session: "s2", msg: "m1")], to: "-Users-me-proj/session-b.jsonl")
        let u = await scan(TranscriptScanner(root: root))
        XCTAssertEqual(u.requests, 2, "Same session + message id collapses; a different session does not")
        XCTAssertEqual(u.models["claude-opus-5"]?.output, 60)
    }

    func testLinesAppendedBetweenScansAreCountedOnce() async {
        write([row()])
        let scanner = TranscriptScanner(root: root)
        let first = await scan(scanner)
        XCTAssertEqual(first.requests, 1)
        append([row(req: "req_2", msg: "msg_2")])
        let second = await scan(scanner)
        XCTAssertEqual(second.requests, 2)
        XCTAssertEqual(second.models["claude-opus-5"]?.input, 200)
    }

    func testPartialTrailingLineIsHeldUntilComplete() async {
        write([row()])
        append([row(req: "req_2", msg: "msg_2")], trailingNewline: false)
        let scanner = TranscriptScanner(root: root)
        let first = await scan(scanner)
        XCTAssertEqual(first.requests, 1, "The unterminated line is not a complete row yet")
        append([], trailingNewline: true)
        let second = await scan(scanner)
        XCTAssertEqual(second.requests, 2)
    }

    func testTruncatedFileIsReReadWithoutDoubleCounting() async {
        write([row(req: "req_a", msg: "msg_a"), row(req: "req_b", msg: "msg_b")])
        let scanner = TranscriptScanner(root: root)
        _ = await scan(scanner)
        // Shrunk and rewritten: A again plus a new C.
        write([row(req: "req_a", msg: "msg_a"), row(req: "req_c", msg: "msg_c")])
        let u = await scan(scanner)
        XCTAssertEqual(u.requests, 3, "A, B (still remembered), C — and A is not counted twice")
        XCTAssertEqual(u.models["claude-opus-5"]?.input, 300)
    }

    func testFastRowsGoUnderASeparateKeyAtTwiceTheEstimate() async {
        write([row(), row(req: "req_f", msg: "msg_f", speed: "fast")])
        let u = await scan(TranscriptScanner(root: root))
        let standard = try? XCTUnwrap(u.models["claude-opus-5"])
        let fast = try? XCTUnwrap(u.models["claude-opus-5/fast"])
        XCTAssertEqual(standard?.requests, 1)
        XCTAssertEqual(fast?.requests, 1)
        XCTAssertEqual(fast?.cost ?? 0, (standard?.cost ?? 0) * 2, accuracy: 1e-12)
    }

    func testCacheWriteSplitAndFlatFallback() async {
        write([row(req: "r1", msg: "m1", flatCacheWrite: 1000, cw5m: 300, cw1h: 700),
               row(req: "r2", msg: "m2", flatCacheWrite: 400)])
        let u = await scan(TranscriptScanner(root: root))
        let m = u.models["claude-opus-5"]
        XCTAssertEqual(m?.cacheWrite5m, 700, "300 from the split + 400 flat treated as 5m")
        XCTAssertEqual(m?.cacheWrite1h, 700)
    }

    func testRequestsOnEitherSideOfAPriceChangeArePricedAtTheirOwnTime() async {
        var history = PriceHistory.builtIn
        var rates = PriceHistory.builtInRates
        rates["claude-opus-5"] = ModelRates(name: "Opus 5", input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1, output: 50)
        history.append(rates: rates, fetchedAt: ISO8601DateFormatter().date(from: "2026-09-22T00:00:00Z")!, source: "test")
        write([row(ts: "2026-09-21T12:00:00.000Z", req: "r1", msg: "m1", input: 1_000_000, output: 0),
               row(ts: "2026-09-23T12:00:00.000Z", req: "r2", msg: "m2", input: 1_000_000, output: 0)])
        let u = await scan(TranscriptScanner(root: root), prices: history)
        XCTAssertEqual(u.models["claude-opus-5"]?.cost ?? 0, 5 + 10, accuracy: 1e-9)
    }

    func testModelPricedOnlyInALaterEntryIsUnpricedUntilThen() async {
        write([row(model: "claude-newmodel-6")])
        let scanner = TranscriptScanner(root: root)
        let before = await scan(scanner)
        XCTAssertEqual(before.models["claude-newmodel-6"]?.unpriced, 1)
        XCTAssertEqual(before.models["claude-newmodel-6"]?.cost, 0)

        var history = PriceHistory.builtIn
        var rates = PriceHistory.builtInRates
        rates["claude-newmodel-6"] = ModelRates(name: "New 6", input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5, output: 25)
        history.append(rates: rates, fetchedAt: ISO8601DateFormatter().date(from: "2026-09-24T00:00:00Z")!, source: "test")
        let after = await scan(scanner, prices: history)
        XCTAssertEqual(after.models["claude-newmodel-6"]?.unpriced, 0, "Launch price applies back to first use")
        XCTAssertEqual(after.models["claude-newmodel-6"]?.cost ?? 0, 100 * 5e-6 + 10 * 25e-6, accuracy: 1e-12)
    }

    func testMissingRootReturnsNil() async {
        let scanner = TranscriptScanner(root: root.appendingPathComponent("does-not-exist"))
        let u = await scanner.usage(since: windowStart, upTo: upTo, prices: prices)
        XCTAssertNil(u)
    }

    func testWindowChangeResetsTheMap() async {
        write([row()])
        let scanner = TranscriptScanner(root: root)
        let first = await scan(scanner)
        XCTAssertEqual(first.requests, 1)
        let next = windowStart.addingTimeInterval(UsageSnapshot.weeklyWindowSec)
        let u = await scanner.usage(since: next, upTo: next.addingTimeInterval(86400), prices: prices)
        XCTAssertEqual(u?.requests, 0, "Last week's request is not in the new window")
    }
}
