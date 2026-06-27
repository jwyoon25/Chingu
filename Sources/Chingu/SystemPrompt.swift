import Foundation

/// Chingu's system prompt.
///
/// **CP1 placeholder.** The CP1 spec calls for "plain chat with no Chingu-specific
/// persona layer," so this is intentionally a stub — the *plumbing* (a top-level
/// `system` field on the Messages API request) is in place, but the content is a
/// minimal placeholder to be replaced in a later checkpoint with the real Chingu
/// persona / behavior / formatting guidance.
///
/// `AnthropicClient` only attaches `system` to the request when `text` is non-empty,
/// so leaving this blank sends no system prompt at all (identical to having none).
enum SystemPrompt {
    /// The active system prompt text. Edit here to give Claude a persona or
    /// formatting rules (e.g. "reply in plain text, no Markdown"). Empty = omitted.
    ///
    /// TODO (post-CP1): replace this placeholder with the real Chingu system prompt.
    static let text = "You are Chingu, a helpful AI companion on macOS. (Placeholder system prompt — to be expanded in a later checkpoint.)"
}
