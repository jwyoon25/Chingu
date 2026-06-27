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

        // Log key PRESENCE only (never values) so it's clear at launch what's loaded.
        // ELEVENLABS_API_KEY is read here for CP4 readiness but not yet consumed.
        for key in Secrets.Key.allCases {
            NSLog("Chingu: \(key.rawValue) \(Secrets.isPresent(key) ? "loaded" : "not set")")
        }

        panel = ChinguPanel(rootView: ChatView(model: model))
        positionBelowNotch()

        // Global hotkey: ⌃⌥⌘K toggles the overlay from any app. Three modifiers keep it
        // clear of common system/app shortcuts.
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey | cmdKey)
        ) { [weak self] in
            guard let self else { return }
            // Showing the overlay also starts voice input (hands-free); hiding stops it.
            // The voice loop (CP4) listens for these via NotificationCenter — see
            // VoiceController — so the AppDelegate stays decoupled from it.
            let willShow = !self.panel.isVisible
            self.togglePanel()
            NotificationCenter.default.post(
                name: willShow ? .chinguActivateVoice : .chinguDeactivateVoice, object: nil)
        }

        // Show on launch so the first run is obviously alive; the hotkey hides/shows
        // it thereafter.
        showPanel()

        // CP2: wire screen capture (one-shot debug capture for now — see ScreenCapture.swift).
        setupCapture()
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
