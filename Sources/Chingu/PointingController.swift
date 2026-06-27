import AppKit
import Combine
import Foundation

/// Drives the on-screen pointing circle (CP3), wrapping the chat pipeline from the
/// outside the same way `VoiceController` does for speech. It owns a `PointerOverlay`,
/// sets `ChatViewModel.onPointing` in `init`, and on each turn remaps Claude's
/// screenshot-pixel coordinate to a real screen point before showing the circle.
///
/// ElevenLabs/Claude are untouched: this only consumes the parsed `[POINT]` tag and the
/// turn's `CaptureGeometry` that `ChatViewModel` hands it.
@MainActor
final class PointingController: ObservableObject {
    private let model: ChatViewModel
    private let overlay = PointerOverlay()
    private var fadeTask: Task<Void, Never>?
    private var escMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    /// A circle lingers this long before auto-fading, in case nothing else dismisses it
    /// (the user walked away). It also clears on a new turn, on Chingu dismiss, and on Esc.
    private let autoFade: Duration = .seconds(5)

    init(model: ChatViewModel) {
        self.model = model

        // POINTING SEAM — fired once per turn with the parsed point (nil ⇒ clear) and the
        // geometry of the screenshot it refers to. We set the closure; the VM stays
        // decoupled from us (mirrors CP4's onAssistantResponseComplete pattern).
        model.onPointing = { [weak self] point, geometry in
            self?.handle(point: point, geometry: geometry)
        }

        // Chingu hidden via the global hotkey → drop the circle (same signal CP4 uses).
        NotificationCenter.default.publisher(for: .chinguDeactivateVoice)
            .sink { [weak self] _ in Task { @MainActor in self?.clear() } }
            .store(in: &cancellables)

        // Esc dismisses the circle while the chat panel has key focus. (When the target
        // app is focused instead, the new-turn / dismiss / auto-fade paths cover it.)
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {                       // 53 = Escape
                Task { @MainActor in self?.clear() }
            }
            return event
        }
    }

    private func handle(point: ParsedPoint?, geometry: CaptureGeometry?) {
        // No point, or a point with no geometry to remap it (e.g. a voice/text-only turn
        // with no screenshot) → just clear any existing circle.
        guard let point, let geometry else {
            clear()
            return
        }
        let local = Self.localPoint(for: point, in: geometry)
        let sx = geometry.contentRect.width / CGFloat(max(geometry.pixelWidth, 1))
        let sy = geometry.contentRect.height / CGFloat(max(geometry.pixelHeight, 1))

        // #region agent log
        AgentDebugLog.write(
            location: "PointingController.swift:handle",
            message: "point remap",
            hypothesisId: "B,C",
            data: [
                "claudeX": point.x,
                "claudeY": point.y,
                "label": point.label,
                "localX": local.x,
                "localY": local.y,
                "sx": sx,
                "sy": sy,
                "scaleUniform": abs(sx - sy) < 0.001,
                "pixelW": geometry.pixelWidth,
                "pixelH": geometry.pixelHeight,
                "contentW": geometry.contentRect.width,
                "contentH": geometry.contentRect.height,
                "contentOriginX": geometry.contentRect.origin.x,
                "contentOriginY": geometry.contentRect.origin.y,
                "displayW": geometry.displayFrame.width,
                "displayH": geometry.displayFrame.height,
                "contentVsDisplayWDelta": geometry.contentRect.width - geometry.displayFrame.width,
                "contentVsDisplayHDelta": geometry.contentRect.height - geometry.displayFrame.height,
            ]
        )
        // #endregion

        overlay.show(atLocalPoint: local, label: point.label, onDisplay: geometry.contentRect)
        scheduleAutoFade()
    }

    private func clear() {
        fadeTask?.cancel()
        fadeTask = nil
        overlay.hide()
    }

    private func scheduleAutoFade() {
        fadeTask?.cancel()
        fadeTask = Task { [weak self, autoFade] in
            try? await Task.sleep(for: autoFade)
            guard !Task.isCancelled else { return }
            self?.overlay.hide()
        }
    }

    /// Remap a screenshot-pixel coordinate to a point in the captured **contentRect's**
    /// top-left space (which the full-display overlay's SwiftUI canvas uses directly — see
    /// `docs/CP3-SPEC.md` §6). Clamp to the image, then scale pixels → points using
    /// `contentRect` (the same region ScreenCaptureKit photographed).
    static func localPoint(for point: ParsedPoint, in geometry: CaptureGeometry) -> CGPoint {
        let clampedX = min(max(point.x, 0), geometry.pixelWidth)
        let clampedY = min(max(point.y, 0), geometry.pixelHeight)
        let sx = geometry.contentRect.width / CGFloat(max(geometry.pixelWidth, 1))
        let sy = geometry.contentRect.height / CGFloat(max(geometry.pixelHeight, 1))
        return CGPoint(x: CGFloat(clampedX) * sx, y: CGFloat(clampedY) * sy)
    }
}
