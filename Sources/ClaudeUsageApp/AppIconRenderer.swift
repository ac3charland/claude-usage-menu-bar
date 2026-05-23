import AppKit

/// Renders a single 1024×1024 PNG suitable for the app icon (Contents/Resources/AppIcon.icns).
/// Not part of the shipping app — invoked via `--render-icon`.
enum AppIconRenderer {
    static func run(outputDir: String) {
        let canvasSize: CGFloat = 1024
        let glyphSize: CGFloat = canvasSize * 0.72

        // "Mid · on pace" state — representative for a static app icon.
        let glyph = DualRingIcon.image(session: 0.52, weekly: 0.44, ahead: false, size: glyphSize)

        let canvas = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
        canvas.lockFocus()

        NSColor(white: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize).fill()

        let offset = (canvasSize - glyphSize) / 2
        tinted(glyph, NSColor(white: 0.12, alpha: 1))
            .draw(in: NSRect(x: offset, y: offset, width: glyphSize, height: glyphSize))

        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("AppIconRenderer: failed to encode PNG\n".utf8))
            return
        }
        let dirURL = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let url = dirURL.appendingPathComponent("AppIcon-1024.png")
        do {
            try png.write(to: url)
            print("Wrote \(url.path)")
        } catch {
            FileHandle.standardError.write(Data("AppIconRenderer: write failed: \(error)\n".utf8))
        }
    }

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
}
