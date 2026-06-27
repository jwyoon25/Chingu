import AppKit
import Carbon.HIToolbox
import SwiftUI

/// App entry point. We drive `NSApplication` manually (no SwiftUI `App` lifecycle)
/// because Chingu is an agent-style overlay: no Dock icon, no main window, a
/// non-activating panel toggled by a global hotkey.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ChatViewModel()
    private var panel: ChinguPanel!
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: lives in the menu-bar layer, shows no Dock icon, and never
        // becomes the active app on its own — matching the non-activating overlay.
        NSApp.setActivationPolicy(.accessory)

        panel = ChinguPanel(rootView: ChatView(model: model))
        positionBelowNotch()

        // Global hotkey: ⌥⌘Space toggles the overlay from any app. Avoids ⌘Space
        // (Spotlight) and ⌃Space (input source switch).
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            self?.togglePanel()
        }

        // Show on launch so the first run is obviously alive; the hotkey hides/shows
        // it thereafter.
        showPanel()
    }

    private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        positionBelowNotch()
        // orderFrontRegardless shows the panel without activating our app. We then
        // make it key so the text field can receive typing — safe because the panel
        // is non-activating (see ChinguPanel), so the app behind stays active.
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Place the panel horizontally centered on the active screen, with its top edge
    /// just below the menu bar / notch.
    private func positionBelowNotch() {
        guard let screen = NSScreen.main else { return }
        let full = screen.frame
        let visible = screen.visibleFrame

        // Height of the top inset (menu bar, and the notch region on notched Macs).
        let topInset = full.maxY - visible.maxY
        let gapBelowNotch: CGFloat = 8

        let size = panel.frame.size
        let originX = full.midX - size.width / 2
        let originY = full.maxY - topInset - gapBelowNotch - size.height

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

// Manual app bootstrap (replaces @main / @NSApplicationMain for an accessory app).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
