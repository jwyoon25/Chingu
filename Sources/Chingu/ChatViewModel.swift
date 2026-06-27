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
}

/// A screenshot to attach to a question. **CP2 placeholder** (the parallel-dev seam).
///
/// CP2 fleshes this out with the base64-encoded PNG and its media type for the Claude
/// `image` content block — see `docs/CP2-SPEC.md`. It exists now (empty) only so the
/// `submit(text:image:)` signature is locked once and never has to be reshaped later
/// (see `docs/PARALLEL-CP2-CP4.md`). CP1/CP4 ignore it; passing `nil` is text-only.
struct CapturedImage: Equatable {
    // CP2: let base64: String; let mediaType: String   // e.g. "image/png"
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

    private let client = AnthropicClient()

    /// Fired once per turn with the assistant's final text when the turn completes
    /// cleanly. **CP4 output seam** (the parallel-dev hook): CP4 sets this to drive
    /// text-to-speech — see `docs/CP4-SPEC.md`. Default `nil` = no-op, so CP1/CP2
    /// behave exactly as before. Invoked on the main actor, after the empty-bubble guard.
    var onAssistantResponseComplete: ((String) -> Void)?

    var canSend: Bool {
        !isResponding && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Composer entry point (Enter key / Send button). Reads and trims `input`, clears
    /// the field, then hands off to `submit(text:image:)`. Kept no-arg so `ChatView`'s
    /// `.onSubmit`/Button bindings don't change.
    ///
    /// CP2 will capture a screenshot here before calling `submit` — see `docs/CP2-SPEC.md`.
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        input = ""
        submit(text: text)
    }

    /// The single entry point for every question — typed (`send()`), transcribed (CP4
    /// calls `submit(text:)`), or screen-attached (CP2 fills `image`). Appends the user
    /// bubble and a streaming assistant bubble, then folds in deltas as they arrive.
    ///
    /// **Parallel-dev seam (`docs/PARALLEL-CP2-CP4.md`):** the `image` superset is locked
    /// once so neither checkpoint reshapes the signature. `image` is accepted but **not yet
    /// sent** — the client takes text only today; CP2 wires it through to the request.
    func submit(text rawText: String, image: CapturedImage? = nil) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        isResponding = true

        messages.append(ChatMessage(role: .user, text: text))
        let assistantID = appendStreamingAssistant()

        Task {
            for await event in await client.send(text) {
                switch event {
                case let .textDelta(delta):
                    update(assistantID) {
                        $0.text += delta
                        $0.isSearching = false
                    }
                case .searching:
                    update(assistantID) { $0.isSearching = true }
                case let .failed(error):
                    update(assistantID) {
                        // Surface the error in-bubble; never crash on a missing key.
                        let prefix = $0.text.isEmpty ? "" : $0.text + "\n\n"
                        $0.text = prefix + "⚠️ " + (error.errorDescription ?? "Something went wrong.")
                        $0.isStreaming = false
                        $0.isSearching = false
                    }
                case .done:
                    update(assistantID) {
                        $0.isStreaming = false
                        $0.isSearching = false
                        // An empty assistant turn (e.g. immediate refusal) shouldn't
                        // leave a blank bubble.
                        if $0.text.isEmpty { $0.text = "(no response)" }
                    }
                    // CP4 output seam: hand the final reply to any registered listener
                    // (e.g. text-to-speech). No-op when unset.
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
