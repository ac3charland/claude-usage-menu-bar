import XCTest
@testable import ClaudeUsageCore

/// Weekly per-model caps (e.g. Fable) are reported inside the response's `limits` array as
/// `weekly_scoped` entries, each scoped to a model — not as top-level windows. These tests pin
/// that we surface *all* of them dynamically, in order, and none when the API reports none.
final class WeeklyModelUsageTests: XCTestCase {

    /// Response body mirroring the real endpoint: five_hour + seven_day windows plus a `limits`
    /// array. `models` appends one `weekly_scoped` entry per (name, percent); an empty list
    /// means no per-model caps (older API / none in use).
    private func body(models: [(name: String, percent: Int)],
                      resetsAt: String = "2026-08-07T18:59:59.720162+00:00") -> Data {
        var limits = [
            #"{"kind":"session","group":"session","percent":39,"resets_at":"2026-08-04T21:59:59.719850+00:00","scope":null,"is_active":true}"#,
            #"{"kind":"weekly_all","group":"weekly","percent":25,"resets_at":"2026-08-07T18:59:59.719877+00:00","scope":null,"is_active":false}"#,
        ]
        for m in models {
            limits.append(
                #"{"kind":"weekly_scoped","group":"weekly","percent":\#(m.percent),"resets_at":"\#(resetsAt)","scope":{"model":{"id":null,"display_name":"\#(m.name)"},"surface":null},"is_active":false}"#
            )
        }
        let json = """
        {"five_hour":{"utilization":39.0,"resets_at":"2026-08-04T21:59:59.719850+00:00"},
         "seven_day":{"utilization":25.0,"resets_at":"2026-08-07T18:59:59.719877+00:00"},
         "seven_day_opus":null,
         "limits":[\(limits.joined(separator: ","))]}
        """
        return Data(json.utf8)
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)!
    }

    func testDecodesSingleModelFromLimitsArray() throws {
        let response = try UsagePoller.decodeResponse(from: body(models: [("Fable", 8)]))
        let limits = response.weeklyModelLimits
        XCTAssertEqual(limits.count, 1)
        let fable = try XCTUnwrap(limits.first)
        XCTAssertEqual(fable.name, "Fable")
        XCTAssertEqual(fable.window.utilization, 8, accuracy: 0.0001)
        XCTAssertEqual(fable.window.resetsAt, date("2026-08-07T18:59:59.720162+00:00"))
    }

    func testDecodesMultipleModelsInOrder() throws {
        let response = try UsagePoller.decodeResponse(from: body(models: [("Fable", 8), ("Opus", 90)]))
        let names = response.weeklyModelLimits.map(\.name)
        XCTAssertEqual(names, ["Fable", "Opus"], "All scoped models surface, in API order")

        let snapshot = UsageSnapshot.from(response, now: date("2026-08-04T18:59:59.720162+00:00"))
        XCTAssertEqual(snapshot.weeklyModels.map(\.label), ["Fable", "Opus"])
        XCTAssertEqual(snapshot.weeklyModels.map { $0.state.utilizationPct }, [8, 90])
    }

    func testModelWindowGetsWeeklyPaceOnPace() throws {
        let response = try UsagePoller.decodeResponse(from: body(models: [("Fable", 8)]))
        // 4 of 7 days elapsed → ~0.571; 8% used is well under pace → on pace.
        let now = date("2026-08-04T18:59:59.720162+00:00")
        let model = try XCTUnwrap(UsageSnapshot.from(response, now: now).weeklyModels.first)
        XCTAssertEqual(model.state.elapsedFraction, 4.0 / 7.0, accuracy: 0.001)
        XCTAssertFalse(model.state.isAhead, "8% used against 57% elapsed is on pace, not ahead")
    }

    func testModelFlagsAheadWhenBurningFasterThanPace() throws {
        let response = try UsagePoller.decodeResponse(from: body(models: [("Fable", 80)]))
        // Only 1 of 7 days elapsed (~0.143) but 80% used → ahead of pace.
        let now = date("2026-08-01T18:59:59.720162+00:00")
        let model = try XCTUnwrap(UsageSnapshot.from(response, now: now).weeklyModels.first)
        XCTAssertTrue(model.state.isAhead, "80% used against 14% elapsed should read as ahead of pace")
    }

    func testNoModelsYieldsEmptyListButKeepsWeekly() throws {
        let response = try UsagePoller.decodeResponse(from: body(models: []))
        XCTAssertTrue(response.weeklyModelLimits.isEmpty)

        let snapshot = UsageSnapshot.from(response, now: date("2026-08-04T18:59:59.720162+00:00"))
        XCTAssertTrue(snapshot.weeklyModels.isEmpty, "No scoped models in the payload → no model rows")
        let weekly = try XCTUnwrap(snapshot.weekly, "Weekly window must still parse when no models are present")
        XCTAssertEqual(weekly.utilizationPct, 25, accuracy: 0.0001)
    }

    func testCachedSnapshotWithoutWeeklyModelsStillDecodes() throws {
        // A snapshot cached before the `weeklyModels` field existed must still load (→ empty),
        // not fail the whole read.
        let legacy = Data(#"{"capturedAt":776000000,"session":null,"weekly":null}"#.utf8)
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: legacy)
        XCTAssertTrue(snapshot.weeklyModels.isEmpty)
    }
}
