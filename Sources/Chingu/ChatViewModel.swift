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

    var canSend: Bool {
        !isResponding && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send the current composer text. Clears the field, appends the user bubble and a
    /// streaming assistant bubble, then folds in deltas as they arrive.
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        input = ""
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
