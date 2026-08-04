import AppKit
import SwiftUI
import ClaudeUsageCore

/// Renders the popover panel across its canonical + degraded states to a PNG for visual QA.
/// Not part of the shipping app — invoked via `--render-popover`. ImageRenderer omits the
/// real `NSVisualEffectView`, so each panel sits on a solid stand-in of the design's
/// rgba(40,40,44,0.92) background.
enum PopoverSampleRenderer {
    private struct Sample {
        let label: String
        let state: EngineState
    }

    private static func snap(sessionPct: Double, sessionResetIn: TimeInterval,
                             weeklyPct: Double, weeklyResetIn: TimeInterval,
                             ahead: Bool,
                             models: [(name: String, pct: Double, ahead: Bool)] = []) -> UsageSnapshot {
        let now = Date()
        let weeklyElapsed = max(0, min(1, (7 * 24 * 3600 - weeklyResetIn) / (7 * 24 * 3600)))
        let resetsAt = now.addingTimeInterval(weeklyResetIn)
        return UsageSnapshot(
            capturedAt: now,
            session: .init(utilizationPct: sessionPct, resetsAt: now.addingTimeInterval(sessionResetIn),
                           elapsedFraction: 0, isAhead: false),
            weekly: .init(utilizationPct: weeklyPct, resetsAt: resetsAt,
                          elapsedFraction: weeklyElapsed, isAhead: ahead),
            weeklyModels: models.map { m in
                .init(label: m.name,
                      state: .init(utilizationPct: m.pct, resetsAt: resetsAt,
                                   elapsedFraction: weeklyElapsed, isAhead: m.ahead))
            }
        )
    }

    private static var samples: [Sample] {
        let h: TimeInterval = 3600, d: TimeInterval = 24 * 3600
        return [
            Sample(label: "Fresh", state: EngineState(
                snapshot: snap(sessionPct: 8, sessionResetIn: 4 * h + 50 * 60, weeklyPct: 12, weeklyResetIn: 6 * d, ahead: false,
                               models: [("Fable", 5, false)]),
                status: .ok, lastSuccess: Date())),
            Sample(label: "Mid · on pace", state: EngineState(
                snapshot: snap(sessionPct: 52, sessionResetIn: 2 * h + 30 * 60, weeklyPct: 44, weeklyResetIn: 4 * d, ahead: false,
                               models: [("Fable", 8, false)]),
                status: .ok, lastSuccess: Date())),
            Sample(label: "Weekly ahead", state: EngineState(
                snapshot: snap(sessionPct: 62, sessionResetIn: 2 * h + 14 * 60, weeklyPct: 78, weeklyResetIn: 3 * d, ahead: true,
                               models: [("Fable", 61, true)]),
                status: .ok, lastSuccess: Date())),
            // Two models — proves the panel scales to however many caps the API returns.
            Sample(label: "Near cap", state: EngineState(
                snapshot: snap(sessionPct: 94, sessionResetIn: 38 * 60, weeklyPct: 92, weeklyResetIn: 1 * d, ahead: true,
                               models: [("Fable", 88, true), ("Opus", 90, true)]),
                status: .ok, lastSuccess: Date())),
            Sample(label: "Offline (stale)", state: EngineState(
                snapshot: snap(sessionPct: 52, sessionResetIn: 2 * h, weeklyPct: 44, weeklyResetIn: 4 * d, ahead: false),
                status: .offline, lastSuccess: Date().addingTimeInterval(-1200))),
            Sample(label: "No token", state: EngineState(snapshot: nil, status: .noToken, lastSuccess: nil)),
        ]
    }

    @MainActor
    static func run(outputDir: String) {
        let sheet = ContactSheet(samples: samples.map { ($0.label, PopoverModel($0.state)) })
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("failed to render popover samples\n".utf8))
            return
        }
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("popover-samples.png")
        do {
            try png.write(to: url)
            print("Wrote \(url.path)")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        }
    }

    private struct ContactSheet: View {
        let samples: [(String, PopoverModel)]
        var body: some View {
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .center, spacing: 28) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    VStack(spacing: 12) {
                        PopoverView(model: sample.1)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(red: 40/255, green: 40/255, blue: 44/255))
                                    .overlay(RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                        Text(sample.0.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.5)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            .padding(40)
            .background(
                LinearGradient(colors: [Color(red: 0.42, green: 0.35, blue: 0.24),
                                        Color(red: 0.16, green: 0.13, blue: 0.09)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
    }
}
