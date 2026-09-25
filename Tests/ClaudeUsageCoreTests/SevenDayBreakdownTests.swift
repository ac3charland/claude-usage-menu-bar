import XCTest
@testable import ClaudeUsageCore

/// `seven_day_breakdown` (CLU-4 §6.1): the per-surface split of the weekly window, decoded
/// from the CLU-3 §2 payload. A payload without it must still decode.
final class SevenDayBreakdownTests: XCTestCase {
    static let clu3Payload = Data("""
    {
      "five_hour":  { "utilization": 8.0,  "resets_at": "2026-09-21T20:50:00Z",
                      "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
      "seven_day":  { "utilization": 48.0, "resets_at": "2026-09-25T19:00:00Z",
                      "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
      "seven_day_breakdown": {
        "as_of":             "2026-09-21T17:34:17Z",
        "window_started_at": "2026-09-18T19:00:00Z",
        "rows": [
          { "key": "claude_code", "display_name": "Claude Code", "percent": 94 },
          { "key": "chat",        "display_name": "Chats",       "percent":  0 },
          { "key": "cowork",      "display_name": "Cowork",      "percent":  6 },
          { "key": "other",       "display_name": "Other",       "percent":  0 }
        ]
      },
      "extra_usage": { "is_enabled": false, "monthly_limit": 2000, "used_credits": 442.0,
                       "utilization": 22.1, "currency": "USD", "decimal_places": 2,
                       "disabled_reason": "out_of_credits" },
      "limits": [
        { "kind": "session",       "group": "session", "percent":  8, "is_active": false },
        { "kind": "weekly_all",    "group": "weekly",  "percent": 48, "is_active": true  },
        { "kind": "weekly_scoped", "group": "weekly",  "percent": 19, "is_active": false,
          "scope": { "model": { "display_name": "Fable" } } }
      ]
    }
    """.utf8)

    func testDecodesSharesAndWindowStart() throws {
        let r = try UsagePoller.decodeResponse(from: Self.clu3Payload)
        let b = try XCTUnwrap(r.sevenDayBreakdown)
        XCTAssertEqual(b.windowStartedAt, ISO8601DateFormatter().date(from: "2026-09-18T19:00:00Z"))
        XCTAssertEqual(r.surfaceShares, ["claude_code": 94, "chat": 0, "cowork": 6, "other": 0])
        // The window key derived from resets_at agrees with the endpoint's own start.
        let key = CalibrationRecord.windowKey(resetsAt: try XCTUnwrap(r.sevenDay?.resetsAt))
        XCTAssertEqual(key, b.windowStartedAt)
    }

    func testPayloadWithoutBreakdownStillDecodes() throws {
        let json = Data("""
        {"five_hour":{"utilization":39.0,"resets_at":"2026-08-04T21:59:59.719850+00:00"},
         "seven_day":{"utilization":25.0,"resets_at":"2026-08-07T18:59:59.719877+00:00"},
         "seven_day_opus":null,
         "limits":[]}
        """.utf8)
        let r = try UsagePoller.decodeResponse(from: json)
        XCTAssertNil(r.sevenDayBreakdown)
        XCTAssertNil(r.surfaceShares)
        XCTAssertEqual(r.sevenDay?.utilization, 25)
    }

    func testWindowKeyRoundsJitterToTheMinute() throws {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let a = CalibrationRecord.windowKey(resetsAt: f.date(from: "2026-08-07T18:59:59.720Z")!)
        let b = CalibrationRecord.windowKey(resetsAt: f.date(from: "2026-08-07T18:59:59.719Z")!)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, ISO8601DateFormatter().date(from: "2026-07-31T19:00:00Z"))
    }
}
