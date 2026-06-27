import AppKit
import SwiftUI

/// The floating Chingu overlay: a non-activating `NSPanel` that hosts the SwiftUI
/// chat UI and never steals application focus from the app behind it.
///
/// This is the load-bearing architectural choice for the whole app (see docs/SPEC.md
/// CP1 "How it works"): CP2–CP4 — clean screenshots, keeping a target app's menus
/// open while pointing — all depend on showing this panel and typing into it WITHOUT
/// deactivating the frontmost application.
///
/// The crux: a `.nonactivatingPanel` does not activate Chingu's process when it
/// becomes key. So we *do* allow it to become the key window (overriding
/// `canBecomeKey`), which is what routes keystrokes to the text field — but because
/// the panel is non-activating, the app behind it stays active and its window chrome
/// stays focused. Key window (keyboard routing) and active application (process
/// focus) are decoupled here, and that decoupling is the entire point.
final class ChinguPanel: NSPanel {
    init(rootView: some View) {
        super.init(
            // Size is owned by the SwiftUI content; this is just the initial frame.
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [
                .nonactivatingPanel,   // showing/keying the panel never activates our app
                .titled,
                .fullSizeContentView,  // SwiftUI draws the whole surface, incl. the title area
            ],
            backing: .buffered,
            defer: false
        )

        // Become key only when something inside actually needs keyboard input (the
        // text field). Combined with .nonactivatingPanel, this lets us type without
        // activating Chingu or deactivating the app behind it.
        becomesKeyOnlyIfNeeded = true

        // Float above normal windows (and even most utility windows) so the overlay
        // is always reachable on the hotkey. Status level sits above ordinary apps.
        level = .statusBar
        // Show on every Space and over full-screen apps without us taking over.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        isFloatingPanel = true
        hidesOnDeactivate = false        // we never "deactivate" — stay put on the hotkey
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false

        // Chromeless, translucent overlay — the SwiftUI view supplies the visuals.
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Let the panel resize to fit the SwiftUI content's fixed frame.
        contentView = hosting
    }

    // A panel must be allowed to become key for its text field to receive typing.
    // Safe here precisely because the panel is non-activating: becoming key does not
    // change which application is active.
    override var canBecomeKey: Bool { true }

    // Never become *main* — we don't want to be the app's main window or to pull the
    // app forward; we only ever route keyboard input to our text field.
    override var canBecomeMain: Bool { false }
}
