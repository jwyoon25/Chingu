import AppKit
import SwiftUI

/// The on-screen pointing circle (CP3). A **separate** window from the chat panel: it
/// covers the whole target display, floats above everything (including the target app's
/// open menus), and — crucially — **lets every click through** so the user can press the
/// control it's pointing at.
///
/// Like `ChinguPanel` it is non-activating, so showing it never steals focus from the
/// app underneath. Unlike the chat panel it has nothing to type into, so it never becomes
/// key and sets `ignoresMouseEvents = true`. Because it's owned by our process, CP2's
/// capture (which excludes all of Chingu's windows) keeps it out of the next screenshot
/// for free — so the circle never photobombs a multi-step re-capture.
@MainActor
final class PointerOverlay {
    private var panel: PointerOverlayPanel?
    private let content = PointerContent()

    /// Show the circle at `localPoint` (points, top-left origin within `displayFrame`),
    /// captioned `label`. `displayFrame` is the captured display's frame in AppKit global
    /// coordinates; the overlay window is sized to cover exactly that display so SwiftUI's
    /// top-left origin lines up with the screenshot's — no manual Y-flip needed.
    func show(atLocalPoint localPoint: CGPoint, label: String, onDisplay displayFrame: CGRect) {
        let panel = ensurePanel()
        // Re-cover the (possibly changed) display each time we show.
        panel.setFrame(displayFrame, display: false)
        content.show(point: localPoint, label: label, canvasSize: displayFrame.size)
        panel.orderFrontRegardless()   // show without activating Chingu
    }

    /// Hide the circle (animated fade handled by the view; the window orders out after).
    func hide() {
        content.clear()
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> PointerOverlayPanel {
        if let panel { return panel }
        let created = PointerOverlayPanel(content: content)
        panel = created
        return created
    }
}

// MARK: - Observable circle state

/// The pointer view's state. A fresh `id` per `show` restarts the appear animation even
/// when the circle moves between two points without hiding in between.
@MainActor
final class PointerContent: ObservableObject {
    struct Target: Equatable {
        let point: CGPoint
        let label: String
        let canvasSize: CGSize
        let id: UUID
    }
    @Published var target: Target?

    func show(point: CGPoint, label: String, canvasSize: CGSize) {
        target = Target(point: point, label: label, canvasSize: canvasSize, id: UUID())
    }
    func clear() { target = nil }
}

// MARK: - The window

final class PointerOverlayPanel: NSPanel {
    init(content: PointerContent) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Purely visual: every click/scroll/hover passes straight through to the app
        // beneath, so the overlay can never eat the click it's telling the user to make.
        ignoresMouseEvents = true

        // Float above the chat panel (.statusBar) and the target app's menus.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        let hosting = NSHostingView(rootView: PointerCircleView(content: content))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    // Never key, never main — the circle takes no input and never pulls focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - The circle

/// The pointing circle and its label, drawn at the target point in a full-display canvas.
private struct PointerCircleView: View {
    @ObservedObject var content: PointerContent

    /// Deliberately large so it absorbs the vision model's typical localization error —
    /// the circle points "around here," not at a single pixel.
    private let diameter: CGFloat = 100

    var body: some View {
        ZStack {
            if let target = content.target {
                circle(for: target)
                    .id(target.id)   // restart the appear animation on each re-point
            }
        }
        .frame(
            width: content.target?.canvasSize.width,
            height: content.target?.canvasSize.height,
            alignment: .topLeading
        )
        .allowsHitTesting(false)
    }

    private func circle(for target: PointerContent.Target) -> some View {
        Marker(diameter: diameter, label: target.label)
            .position(x: target.point.x, y: target.point.y)
            .transition(.opacity)
    }
}

/// A pulsing ring with a small label caption beneath it.
private struct Marker: View {
    let diameter: CGFloat
    let label: String

    @State private var appeared = false
    @State private var pulsing = false

    var body: some View {
        ZStack {
            // Pulsing halo.
            Circle()
                .stroke(Color.accentColor.opacity(0.5), lineWidth: 3)
                .frame(width: diameter, height: diameter)
                .scaleEffect(pulsing ? 1.18 : 0.92)
                .opacity(pulsing ? 0.0 : 0.8)

            // Solid ring.
            Circle()
                .stroke(Color.accentColor, lineWidth: 4)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
                .frame(width: diameter, height: diameter)

            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
                    .fixedSize()
                    .offset(y: diameter / 2 + 16)
            }
        }
        .scaleEffect(appeared ? 1 : 0.6)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { appeared = true }
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}
