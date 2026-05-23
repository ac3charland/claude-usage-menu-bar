import AppKit
import SwiftUI
import ClaudeUsageCore

/// Owns the `NSPopover` and its SwiftUI content, rendered on a `.behindWindow`
/// `NSVisualEffectView` for true desktop-sampling vibrancy.
@MainActor
final class PopoverController {
    private let popover = NSPopover()
    private let hosting: NSHostingController<PopoverView>
    private var model = PopoverModel(.empty)

    var isShown: Bool { popover.isShown }

    init() {
        hosting = NSHostingController(rootView: PopoverView(model: PopoverModel(.empty)))
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let vc = NSViewController()
        vc.view = effect

        popover.contentViewController = vc
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
    }

    /// Update the rendered content from engine state (whether shown or not).
    func update(_ state: EngineState) {
        model = PopoverModel(state)
        hosting.rootView = PopoverView(model: model)
    }

    func toggle(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            hosting.rootView = PopoverView(model: model)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            // Bring the transient popover forward so outside-clicks dismiss it.
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
    }
}
