import AppKit
import ClaudeUsageCore

// Hidden QA mode: `ClaudeUsageApp --render-samples <dir>` renders the icon's canonical
// states to PNGs and exits, without starting the menu bar app. Used to eyeball geometry.
if let idx = CommandLine.arguments.firstIndex(of: "--render-samples") {
    let dir = CommandLine.arguments.indices.contains(idx + 1)
        ? CommandLine.arguments[idx + 1] : NSTemporaryDirectory()
    IconSampleRenderer.run(outputDir: dir)
    exit(0)
}
if let idx = CommandLine.arguments.firstIndex(of: "--render-popover") {
    let dir = CommandLine.arguments.indices.contains(idx + 1)
        ? CommandLine.arguments[idx + 1] : NSTemporaryDirectory()
    MainActor.assumeIsolated { PopoverSampleRenderer.run(outputDir: dir) }
    exit(0)
}

// Menu bar agent: no Dock icon, no main menu bar presence beyond the status item.
// `.accessory` is the programmatic equivalent of LSUIElement for a SwiftPM executable.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Top-level code runs on the main thread; AppDelegate is main-actor isolated.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
