import AppKit
import ClaudeUsageCore

/// Renders the dual-ring menu bar glyph as a monochrome template `NSImage`.
///
/// Geometry is transcribed verbatim from the settled design (`dual-ring.jsx`):
///   - 22×22 viewBox, center (11,11), outer radius R=8, ring stroke 2.
///   - Outer ring track at 0.32 opacity; session arc on top, round cap,
///     starting at 12 o'clock and sweeping clockwise.
///   - Inner disc encodes weekly: radius = innerMin + (innerMax-innerMin)·weekly,
///     solid when on pace, hollow (1.5 stroke) when ahead of pace.
enum DualRingIcon {
    // Design constants in the 22-unit viewBox.
    private static let viewBox: CGFloat = 22
    private static let cx: CGFloat = 11
    private static let cy: CGFloat = 11
    private static let r: CGFloat = 8          // outer ring radius
    private static let ringSW: CGFloat = 2     // outer stroke width
    private static let trackOpacity: CGFloat = 0.32
    private static let innerMin: CGFloat = 1.8
    private static let innerMax: CGFloat = 8 - 2 / 2 - 1.2   // = R - ringSW/2 - 1.2 ≈ 5.8
    private static let aheadStroke: CGFloat = 1.5

    /// Point size of the glyph in the menu bar. 18 matches the design's native size.
    static let pointSize: CGFloat = 18

    /// Full glyph for a usage snapshot. `session`/`weekly` are 0…1; `ahead` flips the
    /// inner disc to a hollow ring. `size` is the rendered point size (defaults to the
    /// menu bar's 18pt; larger values render the same vector crisply for previews).
    static func image(session: Double, weekly: Double, ahead: Bool, size: CGFloat = pointSize) -> NSImage {
        render(size: size) { ctx in
            drawTrack(ctx)
            drawSessionArc(ctx, fraction: clamp(session))
            drawInnerDisc(ctx, weekly: clamp(weekly), ahead: ahead)
        }
    }

    /// "No data" glyph — just the dimmed track ring, no arc or disc. Used when there is
    /// no snapshot at all (e.g. no token found, or first launch before any poll).
    static func emptyImage(size: CGFloat = pointSize) -> NSImage {
        render(size: size) { ctx in drawTrack(ctx) }
    }

    // MARK: - Drawing

    private static func render(size pointSize: CGFloat, _ body: @escaping (CGContext) -> Void) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Map the 22-unit, y-down viewBox onto the point-sized, flipped context.
            let scale = size.width / viewBox
            ctx.scaleBy(x: scale, y: scale)
            body(ctx)
            return true
        }
        image.isTemplate = true   // adapt to light/dark/tinted menu bars automatically
        return image
    }

    private static func drawTrack(_ ctx: CGContext) {
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(trackOpacity).cgColor)
        ctx.setLineWidth(ringSW)
        ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        ctx.strokePath()
    }

    private static func drawSessionArc(_ ctx: CGContext, fraction: Double) {
        guard fraction > 0 else { return }
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(ringSW)
        ctx.setLineCap(.round)

        // Clockwise from 12 o'clock, in the y-down viewBox space:
        //   point(θ) = (cx + R·sinθ, cy − R·cosθ), θ ∈ [0, 2π·fraction].
        let sweep = CGFloat(fraction) * 2 * .pi
        let steps = max(2, Int((CGFloat(fraction) * 360).rounded()))
        let path = CGMutablePath()
        for i in 0...steps {
            let t = sweep * CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: cx + r * sin(t), y: cy - r * cos(t))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.addPath(path)
        ctx.strokePath()
    }

    private static func drawInnerDisc(_ ctx: CGContext, weekly: Double, ahead: Bool) {
        let rInner = innerMin + (innerMax - innerMin) * CGFloat(weekly)
        let rect = CGRect(x: cx - rInner, y: cy - rInner, width: 2 * rInner, height: 2 * rInner)
        if ahead {
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(aheadStroke)
            ctx.strokeEllipse(in: rect)
        } else {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: rect)
        }
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

extension DualRingIcon {
    /// Convenience: build the icon directly from an `EngineState`. Returns the empty
    /// glyph when there is no snapshot.
    static func image(for state: EngineState) -> NSImage {
        guard let snap = state.snapshot else { return emptyImage() }
        let session = (snap.session?.utilizationPct ?? 0) / 100
        let weekly = (snap.weekly?.utilizationPct ?? 0) / 100
        let ahead = snap.weekly?.isAhead ?? false
        return image(session: session, weekly: weekly, ahead: ahead)
    }
}
