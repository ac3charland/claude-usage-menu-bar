import AppKit

/// Renders a contact sheet of the dual-ring icon's canonical states to a PNG for visual QA.
/// Not part of the shipping app — invoked via `--render-samples`.
enum IconSampleRenderer {
    private struct State {
        let label: String
        let session: Double
        let weekly: Double
        let ahead: Bool
    }

    // The four canonical states from the design's hero row.
    private static let states: [State] = [
        State(label: "Fresh",         session: 0.08, weekly: 0.12, ahead: false),
        State(label: "Mid · on pace", session: 0.52, weekly: 0.44, ahead: false),
        State(label: "Weekly ahead",  session: 0.60, weekly: 0.78, ahead: true),
        State(label: "Near cap",      session: 0.94, weekly: 0.90, ahead: true),
    ]

    static func run(outputDir: String) {
        let big: CGFloat = 96
        let pad: CGFloat = 18
        let cols = states.count + 1   // + empty/no-data state
        let labelH: CGFloat = 22
        let cellW = big + pad
        // Rows: light bg (black ink), dark bg (white ink), tinted bg, native 18px on dark.
        let rows: [(name: String, bg: NSColor, ink: NSColor)] = [
            ("Light", NSColor(white: 0.94, alpha: 1), .black),
            ("Dark",  NSColor(white: 0.13, alpha: 1), .white),
            ("Tinted (blue)", NSColor(calibratedRed: 0.18, green: 0.30, blue: 0.55, alpha: 1), .white),
        ]
        let sheetW = cellW * CGFloat(cols) + pad
        let sheetH = (big + labelH + pad) * CGFloat(rows.count) + pad + 60

        let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
        sheet.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()

        for (rowIdx, row) in rows.enumerated() {
            let y = sheetH - (big + labelH + pad) * CGFloat(rowIdx + 1)
            for col in 0..<cols {
                let x = pad + cellW * CGFloat(col)
                let cell = NSRect(x: x, y: y, width: big, height: big)
                row.bg.setFill()
                cell.fill()

                let glyph: NSImage
                let caption: String
                if col < states.count {
                    let s = states[col]
                    glyph = DualRingIcon.image(session: s.session, weekly: s.weekly, ahead: s.ahead, size: big)
                    caption = s.label
                } else {
                    glyph = DualRingIcon.emptyImage(size: big)
                    caption = "No data"
                }
                tinted(glyph, row.ink).draw(in: cell)
                drawCaption(caption, at: NSPoint(x: x, y: y - 16), width: big, color: .white)
            }
            drawCaption(row.name, at: NSPoint(x: sheetW - 150, y: y + big - 14), width: 140, color: .white, right: true)
        }

        // Native 18px strip on a dark menu-bar-like background, magnified context aside.
        let stripY: CGFloat = pad
        let bar = NSRect(x: pad, y: stripY, width: sheetW - 2 * pad, height: 30)
        NSColor(white: 0.16, alpha: 1).setFill()
        bar.fill()
        var sx = pad + 14
        for s in states {
            let g = DualRingIcon.image(session: s.session, weekly: s.weekly, ahead: s.ahead, size: 18)
            tinted(g, .white).draw(in: NSRect(x: sx, y: stripY + 6, width: 18, height: 18))
            sx += 60
        }
        drawCaption("Native 18px (menu bar)", at: NSPoint(x: pad, y: stripY + 32), width: 300, color: .white)

        sheet.unlockFocus()

        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("failed to encode PNG\n".utf8))
            return
        }
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("dual-ring-samples.png")
        do {
            try png.write(to: url)
            print("Wrote \(url.path)")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        }
    }

    /// Recolor a black template glyph to `color`, preserving its alpha shape.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    private static func drawCaption(_ text: String, at point: NSPoint, width: CGFloat, color: NSColor, right: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = right ? .right : .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        (text as NSString).draw(in: NSRect(x: point.x, y: point.y, width: width, height: 16), withAttributes: attrs)
    }
}
