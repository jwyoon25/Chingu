import Foundation

/// Centralized, read-only access to API keys loaded from the environment.
///
/// Keys are supplied via environment variables (loaded from a gitignored `.env`
/// by `scripts/run.sh`, or exported in the shell). They are **never** hardcoded,
/// **never** printed or logged, and only read through `ProcessInfo`.
///
/// CP1 needs `ANTHROPIC_API_KEY`. `ELEVENLABS_API_KEY` is read and reported here so
/// it's ready for speech in CP4, but nothing consumes it yet.
enum Secrets {
    /// An API key the app expects from the environment.
    enum Key: String, CaseIterable {
        case anthropic = "ANTHROPIC_API_KEY"
        case elevenLabs = "ELEVENLABS_API_KEY"

        /// Whether the app needs this key to function *right now* (this checkpoint).
        var isRequiredNow: Bool {
            switch self {
            case .anthropic: return true       // chat + web search (CP1)
            case .elevenLabs: return false     // speech (CP4) — not wired up yet
            }
        }

        var humanName: String {
            switch self {
            case .anthropic: return "Anthropic (Claude)"
            case .elevenLabs: return "ElevenLabs (speech, CP4)"
            }
        }
    }

    /// Returns the value for a key, or `nil` if unset/empty. Trims whitespace so a
    /// stray newline in `.env` doesn't produce an "invalid key" round-trip.
    static func value(_ key: Key) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key.rawValue] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isPresent(_ key: Key) -> Bool { value(key) != nil }

    /// Keys that are required for the current checkpoint but missing.
    static var missingRequiredKeys: [Key] {
        Key.allCases.filter { $0.isRequiredNow && !isPresent($0) }
    }

    /// A clear, user-facing setup message naming exactly which required keys are
    /// missing and how to provide them. Never includes any key value.
    static func setupMessage(for missing: [Key]) -> String {
        let names = missing.map(\.rawValue).joined(separator: ", ")
        return """
        Missing required API key(s): \(names).

        Add them to a local .env file and launch with the run script:
          1. cp .env.example .env
          2. open .env and paste your key(s)
          3. ./scripts/run.sh

        (Or export them in your shell before `swift run`, e.g.
          export \(missing.first?.rawValue ?? "ANTHROPIC_API_KEY")="…")

        Chingu launches without keys; this message stays until they're set.
        """
    }
}
