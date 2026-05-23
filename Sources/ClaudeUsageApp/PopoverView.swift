import SwiftUI
import ClaudeUsageCore

/// View model derived from an `EngineState`, decoupling SwiftUI from the engine types.
struct PopoverModel: Equatable {
    var sessionPct: Double?
    var sessionResetsAt: Date?
    var weeklyPct: Double?
    var weeklyResetsAt: Date?
    var weeklyElapsed: Double
    var weeklyAhead: Bool
    var reason: String?

    init(_ state: EngineState) {
        sessionPct = state.snapshot?.session?.utilizationPct
        sessionResetsAt = state.snapshot?.session?.resetsAt
        weeklyPct = state.snapshot?.weekly?.utilizationPct
        weeklyResetsAt = state.snapshot?.weekly?.resetsAt
        weeklyElapsed = state.snapshot?.weekly?.elapsedFraction ?? 0
        weeklyAhead = state.snapshot?.weekly?.isAhead ?? false
        reason = state.status.reason
    }

    var hasData: Bool { sessionPct != nil || weeklyPct != nil }
}

/// The dropdown panel. Geometry/type transcribed from the settled design (`popover.jsx`):
/// 280px wide, padding 14/16/16/16, white-on-translucent, two progress rows mirroring the
/// icon's solid/hollow pace language.
struct PopoverView: View {
    let model: PopoverModel

    static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.hasData {
                content
            } else {
                emptyState
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        // Session — always solid (a 5h window has no "pace" concept).
        ProgressRow(
            label: "Session",
            pct: (model.sessionPct ?? 0) / 100,
            ahead: false,
            paceMark: nil,
            footer: { SessionFootnote(resetsAt: model.sessionResetsAt) }
        )

        Divider()
            .frame(height: 1)
            .overlay(Color.white.opacity(0.08))
            .padding(.vertical, 14)

        // Weekly — solid when on pace, hollow when ahead; pace mark at elapsed fraction.
        ProgressRow(
            label: "Weekly",
            pct: (model.weeklyPct ?? 0) / 100,
            ahead: model.weeklyAhead,
            paceMark: model.weeklyElapsed,
            footer: { PaceFootnote(ahead: model.weeklyAhead, resetsAt: model.weeklyResetsAt) }
        )

        if let reason = model.reason {
            reasonLine(reason)
        }
    }

    @ViewBuilder private var emptyState: some View {
        Text("No usage data")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
        if let reason = model.reason {
            Text(reason)
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.55))
                .padding(.top, 4)
        }
    }

    @ViewBuilder private func reasonLine(_ reason: String) -> some View {
        HStack(spacing: 6) {
            Text(reason)
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.top, 12)
    }
}

/// Label + big percent, a bar, and a footnote — the repeated row unit.
private struct ProgressRow<Footer: View>: View {
    let label: String
    let pct: Double
    let ahead: Bool
    let paceMark: Double?
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                PercentLabel(value: Int((pct * 100).rounded()))
            }
            UsageBar(pct: pct, ahead: ahead, paceMark: paceMark)
            footer()
        }
    }
}

private struct PercentLabel: View {
    let value: Int
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .tracking(-0.3)
                .foregroundColor(.white)
            Text("%")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
    }
}

/// 6px track. Solid white fill on pace; 1.5px hollow outline when ahead. Optional
/// 10px hollow pace marker sitting on the bar at the expected-pace fraction.
private struct UsageBar: View {
    let pct: Double
    let ahead: Bool
    let paceMark: Double?

    private let height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillW = max(0, min(1, pct)) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))

                if ahead {
                    Capsule()
                        .strokeBorder(Color.white, lineWidth: 1.5)
                        .frame(width: max(fillW, height))
                } else {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: fillW)
                }

                if let mark = paceMark {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 1.5)
                        .background(Circle().fill(Color(red: 40/255, green: 40/255, blue: 44/255)))
                        .frame(width: 10, height: 10)
                        .offset(x: max(0, min(1, mark)) * w - 5)
                }
            }
        }
        .frame(height: height)
    }
}

private struct SessionFootnote: View {
    let resetsAt: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 6) {
                ClockGlyph()
                Text("Resets in \(Self.remaining(until: resetsAt, now: ctx.date))")
            }
            .font(.system(size: 11.5))
            .foregroundColor(.white.opacity(0.55))
            .padding(.top, 1)
        }
    }

    static func remaining(until date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        let h = secs / 3600, m = (secs % 3600) / 60
        if h <= 0 && m <= 0 { return "under 1m" }
        if h <= 0 { return "\(m)m" }
        if m <= 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

private struct PaceFootnote: View {
    let ahead: Bool
    let resetsAt: Date?
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                if ahead { ArrowUpRightGlyph() } else { CheckGlyph() }
                Text(ahead ? "Ahead of pace" : "On pace")
            }
            .foregroundColor(ahead ? .white : .white.opacity(0.55))
            .fontWeight(ahead ? .medium : .regular)

            Text("·").foregroundColor(.white.opacity(0.4))
            Text(Self.formatReset(resetsAt)).foregroundColor(.white.opacity(0.55))
        }
        .font(.system(size: 11.5))
        .padding(.top, 1)
    }

    static func formatReset(_ date: Date?) -> String {
        guard let date else { return "—" }
        let df = DateFormatter()
        df.dateFormat = "EEE"
        let day = df.string(from: date)
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        return "Resets \(day) at \(tf.string(from: date))"
    }
}

// MARK: - Glyphs (transcribed from popover.jsx SVGs)

private struct ClockGlyph: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.7), lineWidth: 1.1).frame(width: 9.4, height: 9.4)
            Path { p in
                p.move(to: CGPoint(x: 6, y: 3.4))
                p.addLine(to: CGPoint(x: 6, y: 6))
                p.addLine(to: CGPoint(x: 7.7, y: 7))
            }
            .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            .frame(width: 12, height: 12)
        }
        .frame(width: 11, height: 11)
    }
}

private struct ArrowUpRightGlyph: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 2.5, y: 7.5))
            p.addLine(to: CGPoint(x: 7.5, y: 2.5))
            p.move(to: CGPoint(x: 4, y: 2.5))
            p.addLine(to: CGPoint(x: 7.5, y: 2.5))
            p.addLine(to: CGPoint(x: 7.5, y: 6))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        .frame(width: 10, height: 10)
    }
}

private struct CheckGlyph: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 2, y: 5.2))
            p.addLine(to: CGPoint(x: 4, y: 7.2))
            p.addLine(to: CGPoint(x: 8, y: 3))
        }
        .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        .frame(width: 10, height: 10)
    }
}
