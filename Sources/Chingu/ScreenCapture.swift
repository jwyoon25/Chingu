import AppKit
import ScreenCaptureKit

/// Screenshot capture for CP2 (see `docs/CP2-SPEC.md`).
///
/// Grabs the active display *minus Chingu's own windows* via ScreenCaptureKit and
/// returns it as a base64 PNG ready for a Claude `image` content block. The panel is
/// never moved or hidden: `SCContentFilter(display:excludingWindows:)` composites the
/// screen *behind* the overlay, and because the panel is non-activating (see
/// `ChinguPanel`) the app underneath stays active during capture — no flicker, no
/// focus change.
enum ScreenCapture {
    /// Longest-edge cap (px) applied at capture time. Screen text/UI is fully legible
    /// to the model well under this; capping bounds payload size, latency, and the
    /// per-turn vision-token cost (the image is re-sent in history every turn).
    /// See `docs/CP2-SPEC.md` §5.
    static let maxLongEdge = 1568

    enum CaptureError: LocalizedError {
        case permissionDenied
        case noDisplay
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Chingu needs Screen Recording permission — enable it in "
                    + "System Settings › Privacy & Security › Screen Recording, then "
                    + "quit and reopen Chingu."
            case .noDisplay:
                return "Couldn't find a display to capture."
            case .encodingFailed:
                return "Couldn't encode the screenshot."
            }
        }
    }

    /// Capture the active display as a PNG, excluding Chingu's own windows. Awaited on
    /// the Enter that starts a turn (CP2-SPEC §1). `async` but non-blocking: it
    /// suspends, it never freezes the UI.
    @MainActor
    static func capture() async throws -> CapturedImage {
        // Fetching shareable content is also the Screen Recording permission gate: if
        // access isn't granted this throws, and we surface a clear, actionable message.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.permissionDenied
        }

        // Shoot the display the user is actually on; fall back to the first display.
        guard let display = activeDisplay(in: content) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Exclude every window owned by *our* process. Robust (catches any Chingu
        // window) and needs no reference into the panel/AppDelegate (CP2-SPEC §4.1).
        let myPID = ProcessInfo.processInfo.processIdentifier
        let chinguWindows = content.windows.filter {
            $0.owningApplication?.processID == myPID
        }

        let filter = SCContentFilter(display: display, excludingWindows: chinguWindows)

        let config = SCStreamConfiguration()
        let (width, height) = downscaledPixelSize(of: filter)
        config.width = width
        config.height = height
        config.showsCursor = false   // cursor adds nothing for screen Q&A

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)

        guard let base64 = pngBase64(from: cgImage) else {
            throw CaptureError.encodingFailed
        }
        return CapturedImage(base64: base64, mediaType: "image/png")
    }

    /// The `SCDisplay` matching the active `NSScreen`, paired by `CGDirectDisplayID`.
    /// Pinning the display avoids photographing the wrong monitor on a multi-display
    /// setup.
    @MainActor
    private static func activeDisplay(in content: SCShareableContent) -> SCDisplay? {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        return content.displays.first { $0.displayID == displayID }
    }

    /// Native pixel size of the filtered content, scaled down so the long edge is at
    /// most `maxLongEdge` (aspect preserved). SCScreenshotManager renders to this size.
    private static func downscaledPixelSize(of filter: SCContentFilter) -> (Int, Int) {
        let pointSize = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        let nativeW = pointSize.width * scale
        let nativeH = pointSize.height * scale
        let longEdge = max(nativeW, nativeH)
        guard longEdge > 0 else { return (maxLongEdge, maxLongEdge) }
        let factor = longEdge > CGFloat(maxLongEdge) ? CGFloat(maxLongEdge) / longEdge : 1
        return (Int((nativeW * factor).rounded()), Int((nativeH * factor).rounded()))
    }

    /// `CGImage` → PNG → base64 with **no** newlines (the Claude image block requires
    /// unwrapped base64). Default `base64EncodedString()` options don't line-wrap.
    private static func pngBase64(from cgImage: CGImage) -> String? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return data.base64EncodedString()
    }
}

// MARK: - AppDelegate capture wiring (CP2)
//
// Lives here, in CP2's own file, so it never collides with CP4's AppDelegate extension
// (see docs/PARALLEL-CP2-CP4.md §3c). `applicationDidFinishLaunching` gains exactly one
// line: `setupCapture()`.

extension AppDelegate {
    /// Wire up screen capture.
    ///
    /// **Build-order steps 1–2 (debug):** for now this takes a one-shot screenshot a
    /// beat after launch, writes it to a temp file (step 1: eyeball that Chingu's
    /// overlay is excluded), and sends it to Claude with a describe-the-screen prompt,
    /// logging the reply (step 2: confirm the vision round-trip works). This debug path
    /// is replaced by the Enter-key flow in `ChatViewModel.send()` in step 3.
    func setupCapture() {
        Task { @MainActor in
            // Let the panel render first, so we can confirm it's excluded from the shot.
            try? await Task.sleep(for: .seconds(2))
            do {
                let shot = try await ScreenCapture.capture()
                let data = Data(base64Encoded: shot.base64) ?? Data()
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("chingu-capture.png")
                try data.write(to: url)
                NSLog("Chingu CP2: debug capture (\(data.count) bytes) → \(url.path)")
                await Self.debugVisionRoundTrip(shot)
            } catch {
                NSLog("Chingu CP2: capture failed — \(error.localizedDescription)")
            }
        }
    }

    /// Step-2 check: send the captured screenshot to Claude and log the reply, proving
    /// the `image` content block reaches the model. Throwaway — removed when step 3
    /// drives capture from the composer.
    private static func debugVisionRoundTrip(_ shot: CapturedImage) async {
        let client = AnthropicClient()
        var reply = ""
        for await event in await client.send(
            "In one short sentence, describe what's shown on this screen.", image: shot) {
            switch event {
            case let .textDelta(delta): reply += delta
            case let .failed(error): reply += "[failed: \(error.errorDescription ?? "?")]"
            default: break
            }
        }
        NSLog("Chingu CP2 vision test → \(reply)")
    }
}
