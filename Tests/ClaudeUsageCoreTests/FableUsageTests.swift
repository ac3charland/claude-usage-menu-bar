import XCTest
@testable import ClaudeUsageCore

/// Fable is a weekly per-model cap the usage endpoint reports inside the `limits` array as a
/// `weekly_scoped` entry scoped to the Fable model — not as a top-level window. These tests
/// pin how we pull it out and shape it into a pace-aware window.
final class FableUsageTests: XCTestCase {

    /// Response body mirroring the real endpoint: five_hour + seven_day windows plus a `limits`
    /// array whose weekly_scoped entry carries the Fable percentage. `fablePercent == nil`
    /// omits the Fable entry entirely (older API / no Fable usage).
    private func body(fablePercent: Int?, resetsAt: String = "2026-08-07T18:59:59.720162+00:00") -> Data {
        var limits = """
        {"kind":"session","group":"session","percent":39,"resets_at":"2026-08-04T21:59:59.719850+00:00","scope":null,"is_active":true},
        {"kind":"weekly_all","group":"weekly","percent":25,"resets_at":"2026-08-07T18:59:59.719877+00:00","scope":null,"is_active":false}
        """
        if let fablePercent {
            limits += """
            ,{"kind":"weekly_scoped","group":"weekly","percent":\(fablePercent),"resets_at":"\(resetsAt)","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
            """
        }
        let json = """
        {"five_hour":{"utilization":39.0,"resets_at":"2026-08-04T21:59:59.719850+00:00"},
         "seven_day":{"utilization":25.0,"resets_at":"2026-08-07T18:59:59.719877+00:00"},
         "seven_day_opus":null,
         "limits":[\(limits)]}
        """
        return Data(json.utf8)
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)!
    }

    func testDecodesFableFromLimitsArray() throws {
        let response = try UsagePoller.decodeResponse(from: body(fablePercent: 8))
        let fable = try XCTUnwrap(response.fableWeekly, "Fable limit should be extracted from the limits array")
        XCTAssertEqual(fable.utilization, 8, accuracy: 0.0001)
        XCTAssertEqual(fable.resetsAt, date("2026-08-07T18:59:59.720162+00:00"))
    }

    func testSnapshotExposesFableWindowWithWeeklyPace() throws {
        let response = try UsagePoller.decodeResponse(from: body(fablePercent: 8))
        // 4 of 7 days elapsed → ~0.571; 8% utilization is well under pace → on pace.
        let now = date("2026-08-04T18:59:59.720162+00:00")
        let snapshot = UsageSnapshot.from(response, now: now)

        let fable = try XCTUnwrap(snapshot.fable)
        XCTAssertEqual(fable.utilizationPct, 8, accuracy: 0.0001)
        XCTAssertEqual(fable.elapsedFraction, 4.0 / 7.0, accuracy: 0.001)
        XCTAssertFalse(fable.isAhead, "8% used against 57% elapsed is on pace, not ahead")
    }

    func testFableFlagsAheadWhenBurningFasterThanPace() throws {
        let response = try UsagePoller.decodeResponse(from: body(fablePercent: 80))
        // Only 1 of 7 days elapsed (~0.143) but 80% used → ahead of pace.
        let now = date("2026-08-01T18:59:59.720162+00:00")
        let snapshot = UsageSnapshot.from(response, now: now)

        let fable = try XCTUnwrap(snapshot.fable)
        XCTAssertTrue(fable.isAhead, "80% used against 14% elapsed should read as ahead of pace")
    }

    func testAbsentFableYieldsNilWindowButKeepsWeekly() throws {
        let response = try UsagePoller.decodeResponse(from: body(fablePercent: nil))
        XCTAssertNil(response.fableWeekly)

        let snapshot = UsageSnapshot.from(response, now: date("2026-08-04T18:59:59.720162+00:00"))
        XCTAssertNil(snapshot.fable, "No Fable limit in the payload should surface no Fable window")
        let weekly = try XCTUnwrap(snapshot.weekly, "Weekly window must still parse when Fable is absent")
        XCTAssertEqual(weekly.utilizationPct, 25, accuracy: 0.0001)
    }
}
