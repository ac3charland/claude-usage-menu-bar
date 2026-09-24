import XCTest
@testable import ClaudeUsageCore

/// The calibration log's write policy, file naming, and round trip (CLU-4 §6.4).
final class CalibrationLogTests: XCTestCase {
    private var dir: URL!
    private var log: CalibrationLog!
    private let start = ISO8601DateFormatter().date(from: "2026-09-25T19:00:00Z")!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("calib-\(UUID().uuidString)")
        log = CalibrationLog(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func record(minute: Int, pct: Int, share: Double? = 94, windowStart: Date? = nil,
                        tokens: Int = 1000) -> CalibrationRecord {
        CalibrationRecord(capturedAt: (windowStart ?? start).addingTimeInterval(TimeInterval(minute * 60)),
                          writer: "app", windowStart: windowStart ?? start, weeklyPct: pct,
                          surfaceShares: share.map { ["claude_code": $0, "cowork": 100 - $0] },
                          scopedPct: ["Fable": 19],
                          usage: ["claude-opus-5": ModelUsage(tokens: TokenCounts(input: tokens), requests: 3, cost: 0.005)])
    }

    func testFileNameFormat() {
        XCTAssertEqual(CalibrationLog.fileName(for: start), "2026-09-25T1900Z.jsonl")
        XCTAssertEqual(CalibrationLog.windowStart(fromFileName: "2026-09-25T1900Z.jsonl"), start)
        XCTAssertNil(CalibrationLog.windowStart(fromFileName: "readings.jsonl"))
    }

    func testStepWritesPendingPlusCurrent() {
        XCTAssertTrue(log.observe(record(minute: 0, pct: 10)), "First observation is written")
        XCTAssertFalse(log.observe(record(minute: 2, pct: 10)), "Same point: held as pending")
        XCTAssertFalse(log.observe(record(minute: 4, pct: 10)), "Newest replaces pending")
        XCTAssertTrue(log.observe(record(minute: 6, pct: 11)), "Step: flush pending, then write")
        let written = log.records(windowStart: start)
        XCTAssertEqual(written.map(\.weeklyPct), [10, 10, 11])
        XCTAssertEqual(written.map { Int($0.capturedAt.timeIntervalSince(start) / 60) }, [0, 4, 6],
                       "The poll before the step (minute 4) and the poll at the step (minute 6)")
    }

    func testSteadyStateWritesHeartbeatEveryThirtyMinutes() {
        log.observe(record(minute: 0, pct: 10))
        for m in stride(from: 2, through: 28, by: 2) {
            XCTAssertFalse(log.observe(record(minute: m, pct: 10)), "minute \(m)")
        }
        XCTAssertTrue(log.observe(record(minute: 30, pct: 10)), "Heartbeat at 30 minutes")
        XCTAssertFalse(log.observe(record(minute: 32, pct: 10)))
        XCTAssertTrue(log.observe(record(minute: 60, pct: 10)))
        XCTAssertEqual(log.records(windowStart: start).map { Int($0.capturedAt.timeIntervalSince(start) / 60) }, [0, 30, 60])
    }

    func testSharesChangeWrites() {
        log.observe(record(minute: 0, pct: 10, share: 94))
        XCTAssertFalse(log.observe(record(minute: 2, pct: 10, share: 94)))
        XCTAssertTrue(log.observe(record(minute: 4, pct: 10, share: 93)))
        XCTAssertEqual(log.records(windowStart: start).count, 3, "pending + the changed record")
    }

    func testWindowChangeWritesToNewFile() {
        log.observe(record(minute: 0, pct: 90))
        XCTAssertFalse(log.observe(record(minute: 2, pct: 90)))
        let next = start.addingTimeInterval(UsageSnapshot.weeklyWindowSec)
        XCTAssertTrue(log.observe(record(minute: 0, pct: 0, windowStart: next)))
        XCTAssertEqual(log.records(windowStart: start).count, 2, "Pending flushed into the old window's file")
        XCTAssertEqual(log.records(windowStart: next).count, 1)
        XCTAssertEqual(log.recordedWindows(), [start, next])
        let (current, previous) = log.currentAndPrevious(now: next.addingTimeInterval(3600))
        XCTAssertEqual(current, next)
        XCTAssertEqual(previous, start)
    }

    func testPreviousWindowMustBeBackToBack() {
        log.observe(record(minute: 0, pct: 50))
        let later = start.addingTimeInterval(2 * UsageSnapshot.weeklyWindowSec)
        log.observe(record(minute: 0, pct: 5, windowStart: later))
        let (current, previous) = log.currentAndPrevious(now: later.addingTimeInterval(3600))
        XCTAssertEqual(current, later)
        XCTAssertNil(previous, "A skipped week means no honest last week")
    }

    func testRoundTripAndCorruptLineSkipped() throws {
        let r = record(minute: 0, pct: 48)
        log.observe(r)
        let url = log.fileURL(for: start)
        var text = try String(contentsOf: url)
        XCTAssertTrue(text.contains("\"v\":1"))
        XCTAssertTrue(text.contains("\"writer\":\"app\""))
        XCTAssertTrue(text.contains("\"claude_code\":94"))
        text += "{\"v\":1,\"capturedAt\":\"2026-09-25T19:0"   // partial last line after a crash
        try text.write(to: url, atomically: true, encoding: .utf8)
        let loaded = log.records(windowStart: start)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, r)
        XCTAssertEqual(loaded.first?.usage["claude-opus-5"]?.input, 1000)
        XCTAssertEqual(loaded.first?.scopedPct["Fable"], 19)
    }

    func testResumesPolicyFromDiskAtLaunch() {
        log.observe(record(minute: 0, pct: 10))
        // A fresh instance (relaunch) reads the last written record back, so an identical
        // observation is held rather than re-written.
        let relaunched = CalibrationLog(directory: dir)
        XCTAssertFalse(relaunched.observe(record(minute: 2, pct: 10)))
        XCTAssertTrue(relaunched.observe(record(minute: 4, pct: 11)))
        XCTAssertEqual(log.records(windowStart: start).count, 3)
    }

    func testShadowReadingsAppend() {
        var a = ShadowReading(evaluatedAt: start, windowStart: start, shown: false)
        a.hiddenReason = "below gate"
        log.appendReading(a)
        var b = a
        b.evaluatedAt = start.addingTimeInterval(60)
        XCTAssertTrue(a.sameReading(as: b), "Only the clock differs")
        b.ratio = 0.8
        XCTAssertFalse(a.sameReading(as: b))
        log.appendReading(b)
        XCTAssertEqual(log.lastReading(), b)
    }
}
