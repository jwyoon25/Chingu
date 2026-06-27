import Foundation

/// Voice ↔ text via ElevenLabs. **Pure networking** — knows nothing about Claude, the
/// chat thread, or the UI. STT (speech-to-text) and TTS (text-to-speech) over
/// `URLSession`, with hand-rolled JSON / multipart bodies (no SDK), exactly as CP1 does
/// for Anthropic. See `docs/CP4-SPEC.md` §6.1 and the verified endpoint shapes in §7.
///
/// The `ELEVENLABS_API_KEY` is read only via `Secrets.value(.elevenLabs)` and is never
/// logged, printed, or stored. Errors surface as `SpeechError` (clear messages, never a
/// crash) — same posture as `AnthropicError`.
struct SpeechService {

    // MARK: Configuration

    /// ElevenLabs voice id for TTS. Any voice id from the account works; with
    /// `eleven_multilingual_v2` it speaks Korean ("야 친구!") and English alike (premade
    /// English voices carry a slight accent on Korean — swap to a native Korean voice from
    /// the ElevenLabs Voice Library for the final demo if desired). Current pick:
    /// "Jessica — Playful, Bright, Warm".
    static let voiceID = "cgSgspJ2msm6clMCkdW9"

    /// Multilingual TTS model so Korean + English both render correctly.
    static let ttsModelID = "eleven_multilingual_v2"

    /// ElevenLabs speech-to-text model.
    static let sttModelID = "scribe_v1"

    /// MP3 @ 44.1 kHz / 128 kbps — `AVAudioPlayer` plays it directly.
    static let ttsOutputFormat = "mp3_44100_128"

    private static let base = URL(string: "https://api.elevenlabs.io")!

    // MARK: Text-to-speech

    /// POST text to ElevenLabs TTS and return MP3 bytes (play with `AVAudioPlayer`).
    /// Markdown/citation noise is stripped first (CP1 bubbles show raw Markdown), so the
    /// voice doesn't read "asterisk asterisk".
    func synthesize(_ text: String) async throws -> Data {
        let key = try apiKey()
        let speakable = Self.plainSpeech(text)
        guard !speakable.isEmpty else { throw SpeechError.emptyText }

        var url = Self.base.appending(path: "/v1/text-to-speech/\(Self.voiceID)")
        url.append(queryItems: [URLQueryItem(name: "output_format", value: Self.ttsOutputFormat)])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": speakable,
            "model_id": Self.ttsModelID,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        try Self.check(response, data: data)
        return data
    }

    // MARK: Speech-to-text

    /// POST audio (multipart form) to ElevenLabs STT and return the transcript text.
    /// `filename`/`mimeType` describe the captured clip (e.g. `"audio.m4a"`,
    /// `"audio/mp4"`).
    func transcribe(_ audio: Data, filename: String, mimeType: String) async throws -> String {
        let key = try apiKey()
        let url = Self.base.appending(path: "/v1/speech-to-text")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: ["model_id": Self.sttModelID],
            fileField: "file",
            filename: filename,
            mimeType: mimeType,
            fileData: audio
        )

        let (data, response) = try await send(request)
        try Self.check(response, data: data)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw SpeechError.badResponse("ElevenLabs STT response had no \"text\" field.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeechError.emptyTranscript }
        return trimmed
    }

    // MARK: Networking helpers

    private func apiKey() throws -> String {
        guard let key = Secrets.value(.elevenLabs) else { throw SpeechError.missingAPIKey }
        return key
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw SpeechError.transport(error.localizedDescription)
        }
    }

    /// Throws `.badStatus` (with the API's own error message) on a non-2xx response.
    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw SpeechError.badStatus(http.statusCode, errorMessage(from: data))
        }
    }

    /// Pulls a readable message out of an ElevenLabs error body. ElevenLabs returns
    /// `{"detail": {"message": "…"}}` or `{"detail": "…"}`; fall back to raw text.
    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? [String: Any],
               let message = detail["message"] as? String { return message }
            if let detail = object["detail"] as? String { return detail }
        }
        return String(data: data, encoding: .utf8) ?? "(no response body)"
    }

    /// Builds a `multipart/form-data` body: simple text fields plus one file part.
    private static func multipartBody(
        boundary: String,
        fields: [String: String],
        fileField: String,
        filename: String,
        mimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    // MARK: Text hygiene

    /// Strips Markdown / citation noise so TTS reads natural prose. CP1 renders raw
    /// Markdown in bubbles (a known, intentionally-unfixed display bug), so assistant
    /// replies contain `**`, `#`, backticks, `[label](url)`, and `[1]`-style markers.
    static func plainSpeech(_ text: String) -> String {
        var s = text
        // [label](url) -> label
        s = s.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        // Bracketed citation markers like [1], [12]
        s = s.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
        // Markdown emphasis / headers / code / quotes / bullets
        s = s.replacingOccurrences(of: #"[`*_#>]"#, with: "", options: .regularExpression)
        // Collapse runs of spaces/tabs
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Errors from `SpeechService`. Mirrors `AnthropicError`: human-readable, never leaks the
/// key, and surfaced in the UI (a `ChatView` banner) rather than crashing.
enum SpeechError: LocalizedError {
    case missingAPIKey
    case emptyText
    case emptyTranscript
    case badStatus(Int, String)
    case badResponse(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing ELEVENLABS_API_KEY. Add it to .env and relaunch with ./scripts/run.sh."
        case .emptyText:
            return "Nothing to speak."
        case .emptyTranscript:
            return "Didn't catch that — no speech detected. Try again."
        case let .badStatus(code, message):
            return "ElevenLabs returned HTTP \(code). \(message)"
        case let .badResponse(message):
            return message
        case let .transport(message):
            return "Network error talking to ElevenLabs: \(message)"
        }
    }
}
