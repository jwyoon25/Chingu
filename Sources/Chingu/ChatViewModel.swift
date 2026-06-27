import Foundation
import SwiftUI

/// A single rendered chat bubble in the thread.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    /// True while this assistant message is still streaming in.
    var isStreaming: Bool = false
    /// True while Claude is running a server-side web search for this message.
    var isSearching: Bool = false
    /// True when a screenshot was attached to this (user) turn — drives the small
    /// "screen attached" hint on the bubble. CP2.
    var hasImage: Bool = false
}

/// A screenshot to attach to a question. **CP2 placeholder** (the parallel-dev seam).
///
/// CP2 fleshes this out with the base64-encoded PNG and its media type for the Claude
/// `image` content block — see `docs/CP2-SPEC.md`. It exists now (empty) only so the
/// `submit(text:image:)` signature is locked once and never has to be reshaped later
/// (see `docs/PARALLEL-CP2-CP4.md`). CP1/CP4 ignore it; passing `nil` is text-only.
struct CapturedImage: Equatable, Sendable {
    /// PNG bytes, base64-encoded with **no** newlines — the `data` of the Claude
    /// `image` content block.
    let base64: String
    /// IANA media type for the block's `source` — "image/png".
    let mediaType: String
    /// Pixel dimensions of the encoded PNG — the exact coordinate space Claude is told
    /// about and reports pointing coordinates in (CP3; see `docs/CP3-SPEC.md` §5a).
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Drives the chat UI. Owns the rendered message list and bridges the
/// `AnthropicClient` actor's async stream into observable SwiftUI state on the
/// main actor. One thread only — no clear/reset surfaced.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var input: String = ""
    /// Disables the composer while a turn is in flight (one outstanding turn at a time).
    @Published private(set) var isResponding: Bool = false
    /// Set when a turn couldn't attach the screen (e.g. Screen Recording permission is
    /// off). The UI surfaces it as a banner; cleared on the next successful capture. CP2.
    @Published private(set) var captureNotice: String?

    private let client = AnthropicClient()

    /// Fired once per turn with the assistant's final text when the turn completes
    /// cleanly. **CP4 output seam** (the parallel-dev hook): CP4 sets this to drive
    /// text-to-speech — see `docs/CP4-SPEC.md`. Default `nil` = no-op, so CP1/CP2
    /// behave exactly as before. Invoked on the main actor, after the empty-bubble guard.
    var onAssistantResponseComplete: ((String) -> Void)?

    /// Fired as the assistant reply streams in, with the cumulative text so far.
    /// CP4 uses this for incremental TTS so speech starts before the turn finishes.
    var onAssistantTextUpdate: ((String) -> Void)?

    /// Fired once per turn with the parsed pointing tag (`nil` = clear) and the geometry
    /// of the screenshot it refers to. **CP3 pointing seam:** `PointingController` sets
    /// this to remap the coordinate and draw the on-screen circle — see
    /// `docs/CP3-SPEC.md` §8. Default `nil` = no-op; coordinates are never shown/spoken.
    var onPointing: ((ParsedPoint?, CaptureGeometry?) -> Void)?

    /// This turn's screenshot geometry, stashed by `send()` between capture and `submit`
    /// (CP3). A voice/text-only turn leaves it `nil`. Consumed once per `submit`.
    private var pendingGeometry: CaptureGeometry?

    var canSend: Bool {
        !isResponding && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Composer entry point (Enter key / Send button). Reads and trims `input`, clears
    /// the field, then hands off to `submit(text:image:)`. Kept no-arg so `ChatView`'s
    /// `.onSubmit`/Button bindings don't change.
    ///
    /// CP2: the screen Chingu sees is the screen at the moment of Enter (CP2-SPEC §1).
    /// Capture is async, so we clear the field instantly, await the shot, then submit.
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        input = ""   // clear immediately so the composer feels responsive
        Task {
            let shot = await captureScreen()
            submit(text: text, image: shot)
        }
    }

    /// Grabs the screen for this turn. Returns `nil` (and sets `captureNotice`) when the
    /// shot is unavailable — e.g. Screen Recording permission is off — so the turn still
    /// goes through text-only instead of blocking. Clears the notice on success.
    private func captureScreen() async -> CapturedImage? {
        do {
            let (shot, geometry) = try await ScreenCapture.capture()
            captureNotice = nil
            pendingGeometry = geometry   // CP3: remembered for this turn's pointing remap
            return shot
        } catch {
            pendingGeometry = nil
            captureNotice = (error as? ScreenCapture.CaptureError)?.errorDescription
                ?? "Couldn't capture the screen — answering without it."
            return nil
        }
    }

    /// The single entry point for every question — typed (`send()`), transcribed (CP4
    /// calls `submit(text:)`), or screen-attached (CP2 fills `image`). Appends the user
    /// bubble and a streaming assistant bubble, then folds in deltas as they arrive.
    ///
    /// **Parallel-dev seam (`docs/PARALLEL-CP2-CP4.md`):** the `image` superset is locked
    /// once so neither checkpoint reshapes the signature. CP2 fills `image` (the screen
    /// at Enter); CP4 calls `submit(text:)` and leaves it nil. `nil` ⇒ text-only.
    func submit(text rawText: String, image: CapturedImage? = nil) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        isResponding = true

        // CP3: this turn's screenshot geometry (set by `send()` if it captured). Consume
        // it so it can't leak into a later turn, and clear any existing circle now — we
        // re-point (or clear) once the reply finishes and its [POINT] tag is parsed.
        let geometry = pendingGeometry
        pendingGeometry = nil
        onPointing?(nil, nil)

        messages.append(ChatMessage(role: .user, text: text, hasImage: image != nil))
        let assistantID = appendStreamingAssistant()

        Task {
            for await event in await client.send(text, image: image) {
                switch event {
                case let .textDelta(delta):
                    update(assistantID) {
                        $0.text += delta
                        $0.isSearching = false
                    }
                    if let partial = messages.first(where: { $0.id == assistantID })?.text {
                        onAssistantTextUpdate?(partial)
                    }
                case .searching:
                    update(assistantID) {
                        $0.isSearching = true
                        // Drop any "let me search…" preamble emitted before the tool
                        // call — the real answer streams in after the results. Guarantees
                        // clean output even if the model ignores the no-narration prompt
                        // (and the UI's "Searching…" indicator already covers intent).
                        $0.text = ""
                    }
                case let .failed(error):
                    update(assistantID) {
                        // Surface the error in-bubble; never crash on a missing key.
                        let prefix = $0.text.isEmpty ? "" : $0.text + "\n\n"
                        $0.text = prefix + "⚠️ " + (error.errorDescription ?? "Something went wrong.")
                        $0.isStreaming = false
                        $0.isSearching = false
                    }
                case .done:
                    // CP3: split the machine-readable [POINT:…] tag off the end before
                    // anything sees the text — so neither the bubble nor TTS shows or
                    // speaks a coordinate. `parse` is lenient: no/malformed tag ⇒ no point.
                    let rawFinal = messages.first(where: { $0.id == assistantID })?.text ?? ""
                    let parsed = PointTag.parse(rawFinal)
                    update(assistantID) {
                        $0.isStreaming = false
                        $0.isSearching = false
                        // An empty assistant turn (e.g. immediate refusal) shouldn't
                        // leave a blank bubble.
                        $0.text = parsed.clean.isEmpty ? "(no response)" : parsed.clean
                    }
                    // CP3 pointing seam: remap + draw the circle (or clear if [POINT:none]
                    // / no tag / a turn with no screenshot). No-op when unset.
                    onPointing?(parsed.point, geometry)
                    // CP4 output seam: hand the final (tag-stripped) reply to any
                    // registered listener (e.g. text-to-speech). No-op when unset.
                    if let finalText = messages.first(where: { $0.id == assistantID })?.text {
                        onAssistantResponseComplete?(finalText)
                    }
                }
            }
            isResponding = false
        }
    }

    private func appendStreamingAssistant() -> UUID {
        let message = ChatMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(message)
        return message.id
    }

    private func update(_ id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[index])
    }
}
