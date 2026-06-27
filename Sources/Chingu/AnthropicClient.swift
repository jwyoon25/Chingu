import Foundation

// MARK: - Errors

enum AnthropicError: LocalizedError {
    case missingAPIKey
    case badStatus(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            // Reuse the centralized setup copy so the .env / run.sh instructions
            // live in one place.
            return Secrets.setupMessage(for: [.anthropic])
        case let .badStatus(code, body):
            return "Anthropic API returned HTTP \(code). \(body)"
        case let .transport(message):
            return "Network error talking to Anthropic: \(message)"
        }
    }
}

// MARK: - Wire model
//
// We hand-roll the request/response JSON rather than depend on an SDK: Anthropic
// ships no Swift SDK, and the Messages API shape is small. Request/response shapes
// follow the current Messages API (model claude-haiku-4-5, streaming SSE, the
// server-side web_search_20260209 tool). See docs/SPEC.md (CP1) and the claude-api skill.

/// One message in the single chat thread. `content` holds API content blocks as
/// raw JSON so we can faithfully echo assistant turns (text + server tool use +
/// web-search results) back on the next request — required for multi-turn and for
/// resuming a paused server-tool turn.
struct WireMessage {
    let role: String          // "user" | "assistant"
    let content: [JSONValue]  // array of content blocks
}

/// Minimal JSON value used to build request bodies and stash response blocks verbatim.
indirect enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .number(n): try c.encode(n)
        case let .bool(b): try c.encode(b)
        case .null: try c.encodeNil()
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    // Convenience accessors for parsing streamed events.
    var stringValue: String? { if case let .string(s) = self { return s } else { return nil } }
    subscript(_ key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] } else { return nil }
    }
}

// MARK: - Client

/// Streaming client for the Anthropic Messages API. Owns no UI; callers drive it
/// and receive deltas through the async `send` stream.
actor AnthropicClient {
    static let model = "claude-haiku-4-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let anthropicVersion = "2023-06-01"
    static let maxTokens = 4096

    /// The single conversation thread. Persisted only in memory — quitting erases it
    /// (one session, no "new chat"), exactly as the spec requires.
    private var history: [WireMessage] = []

    /// Reads the key fresh each call from the environment. Never logged, never stored.
    private var apiKey: String? {
        Secrets.value(.anthropic)
    }

    /// Events surfaced to the UI as a Claude turn streams in.
    enum StreamEvent {
        case textDelta(String)            // incremental assistant text
        case searching                    // a server-side web search started
        case failed(AnthropicError)       // terminal error; nothing more will arrive
        case done                         // turn finished cleanly
    }

    /// Append a user message and stream the assistant's reply. Yields text deltas as
    /// they arrive. The full assistant turn is committed to `history` when complete so
    /// follow-ups keep context. Handles the server-tool `pause_turn` by re-requesting.
    ///
    /// When `image` is set (CP2), an `image` content block is prepended to the user
    /// turn — and because it lands in `history`, follow-ups keep the screenshot context
    /// for free. `image == nil` is byte-for-byte today's text-only behaviour.
    func send(_ userText: String, image: CapturedImage? = nil) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                guard let key = self.apiKey else {
                    continuation.yield(.failed(.missingAPIKey))
                    continuation.finish()
                    return
                }

                self.history.append(WireMessage(
                    role: "user",
                    content: Self.userContent(text: userText, image: image)))

                do {
                    // Loop to follow `pause_turn`: the server-side web-search loop can
                    // pause mid-turn; we resend with the partial assistant turn appended
                    // and the server resumes. Bounded so a misbehaving turn can't spin.
                    var continuations = 0
                    while true {
                        let (assistantBlocks, stopReason) =
                            try await self.streamOnce(key: key, continuation: continuation)

                        // Commit whatever the assistant produced this round.
                        self.history.append(
                            WireMessage(role: "assistant", content: assistantBlocks))

                        if stopReason == "pause_turn", continuations < 3 {
                            continuations += 1
                            continue  // resend; history now ends with the partial turn
                        }
                        break
                    }
                    continuation.yield(.done)
                } catch let error as AnthropicError {
                    continuation.yield(.failed(error))
                } catch {
                    continuation.yield(.failed(.transport(error.localizedDescription)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Builds the user turn's content blocks. With an image attached, the `image`
    /// block comes **first**, then the text (vision best practice). Without one, it's a
    /// single text block — identical to the pre-CP2 request. Base64 is sent verbatim
    /// (the encoder already produces unwrapped base64, no newlines).
    private static func userContent(text: String, image: CapturedImage?) -> [JSONValue] {
        var blocks: [JSONValue] = []
        if let image {
            blocks.append(.object([
                "type": .string("image"),
                "source": .object([
                    "type": .string("base64"),
                    "media_type": .string(image.mediaType),
                    "data": .string(image.base64),
                ]),
            ]))
            // CP3: tell Claude the screenshot's exact pixel space so any [POINT:x,y:…]
            // tag it emits is anchored to the image it actually sees (no server-side
            // resize on the high-res tier — see docs/CP3-SPEC.md §4/§5a). Image block
            // first, then this note, then the question.
            blocks.append(.object([
                "type": .string("text"),
                "text": .string(
                    "(The screenshot above is \(image.pixelWidth)x\(image.pixelHeight) "
                    + "pixels. Coordinates use this exact space: origin top-left, x "
                    + "increases right, y increases down.)"),
            ]))
        }
        blocks.append(.object(["type": .string("text"), "text": .string(text)]))
        return blocks
    }

    /// Performs one streaming request over the current `history` and returns the
    /// assistant content blocks it produced plus the stop reason. Text deltas are
    /// forwarded to `continuation` live as they arrive.
    private func streamOnce(
        key: String,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) async throws -> (blocks: [JSONValue], stopReason: String?) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try self.encodeRequestBody()

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw AnthropicError.transport(error.localizedDescription)
        }

        // Non-2xx: the body is a JSON error, not an SSE stream. Drain it for the message.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            let detail = Self.extractErrorMessage(from: raw)
            throw AnthropicError.badStatus(http.statusCode, detail)
        }

        // Accumulate content blocks by index as the stream arrives. We keep the
        // start block (which carries type + any server_tool_use fields) and fold in
        // deltas (text_delta, input_json_delta) so the committed assistant turn is
        // faithful enough to resend on a follow-up or a pause_turn resume.
        var assembler = StreamAssembler()
        var stopReason: String?

        for try await line in bytes.lines {
            // SSE frames are "event:" and "data:" lines separated by blank lines.
            // Only the data payload matters here; the event name is redundant with
            // the JSON's own "type" field.
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { continue }

            switch event["type"]?.stringValue {
            case "content_block_start":
                if let index = event["index"].flatMap(Self.intValue),
                   let block = event["content_block"] {
                    assembler.startBlock(at: index, block: block)
                    if block["type"]?.stringValue == "server_tool_use" {
                        continuation.yield(.searching)
                    }
                }
            case "content_block_delta":
                if let index = event["index"].flatMap(Self.intValue),
                   let delta = event["delta"] {
                    if let text = delta["text"]?.stringValue,
                       delta["type"]?.stringValue == "text_delta" {
                        continuation.yield(.textDelta(text))
                    }
                    assembler.applyDelta(at: index, delta: delta)
                }
            case "message_delta":
                if let reason = event["delta"]?["stop_reason"]?.stringValue {
                    stopReason = reason
                }
            case "error":
                // Mid-stream error event from the API.
                let message = event["error"]?["message"]?.stringValue ?? "stream error"
                throw AnthropicError.transport(message)
            default:
                break  // message_start, content_block_stop, ping, message_stop
            }
        }

        return (assembler.blocks(), stopReason)
    }

    private static func intValue(_ v: JSONValue) -> Int? {
        if case let .number(n) = v { return Int(n) }
        return nil
    }

    /// Pulls a human-readable message out of an Anthropic error body, falling back to
    /// the raw text. Never surfaces the API key (it isn't in the body anyway).
    private static func extractErrorMessage(from data: Data) -> String {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           let message = value["error"]?["message"]?.stringValue {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "(no response body)"
    }

    /// Builds the Messages API request body: model, streaming, the conversation, and
    /// the server-side web search tool.
    private func encodeRequestBody() throws -> Data {
        let messages: [JSONValue] = history.map { msg in
            .object([
                "role": .string(msg.role),
                "content": .array(msg.content),
            ])
        }
        var fields: [String: JSONValue] = [
            "model": .string(Self.model),
            "max_tokens": .number(Double(Self.maxTokens)),
            "stream": .bool(true),
            "messages": .array(messages),
            "tools": .array([
                .object([
                    "type": .string("web_search_20260209"),
                    "name": .string("web_search"),
                    // Haiku 4.5 lacks programmatic tool calling; the 20260209 search
                    // tool defaults to code-execution callers for dynamic filtering.
                    // Direct-only keeps web search working on the fast model.
                    "allowed_callers": .array([.string("direct")]),
                ])
            ]),
            // Automatic prompt caching: a top-level breakpoint that the API rolls
            // forward as the thread grows, so the conversation prefix — crucially the
            // prior screenshots (CP2) — is read from cache instead of re-prefilled
            // every turn. That re-prefill is what made multi-turn latency balloon.
            // Adding the newest image only invalidates from that block on; older images
            // stay cached. Safe with our always-declared web_search (only *toggling* it
            // would invalidate). See docs/CP2-SPEC.md §9.
            "cache_control": .object(["type": .string("ephemeral")]),
        ]
        // Attach the (placeholder) system prompt only when non-empty — an empty
        // prompt omits the field entirely, so behaviour matches "no system prompt".
        let systemPrompt = SystemPrompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            fields["system"] = .string(systemPrompt)
        }
        return try JSONEncoder().encode(JSONValue.object(fields))
    }

    /// Clears the in-memory thread. (Not surfaced in CP1 UI — no "new chat" — but
    /// handy for tests/teardown.)
    func reset() {
        history.removeAll()
    }
}

// MARK: - SSE block assembly

/// Reassembles streamed content blocks into complete blocks suitable for echoing
/// back to the API. Tracks each block by its stream index and folds in deltas.
private struct StreamAssembler {
    private struct Partial {
        var block: JSONValue            // the content_block_start object
        var textBuffer: String = ""     // accumulated text_delta
        var jsonBuffer: String = ""     // accumulated input_json_delta (partial JSON)
    }
    private var partials: [Int: Partial] = [:]
    private var order: [Int] = []

    mutating func startBlock(at index: Int, block: JSONValue) {
        if partials[index] == nil { order.append(index) }
        partials[index] = Partial(block: block)
    }

    mutating func applyDelta(at index: Int, delta: JSONValue) {
        guard partials[index] != nil else { return }
        switch delta["type"]?.stringValue {
        case "text_delta":
            if let t = delta["text"]?.stringValue { partials[index]!.textBuffer += t }
        case "input_json_delta":
            if let j = delta["partial_json"]?.stringValue { partials[index]!.jsonBuffer += j }
        default:
            break  // citations_delta etc. — not needed to round-trip the turn
        }
    }

    /// Finalizes all blocks in arrival order, materializing accumulated text and
    /// server-tool input into the block objects.
    func blocks() -> [JSONValue] {
        order.compactMap { index in
            guard let partial = partials[index] else { return nil }
            guard case var .object(obj) = partial.block else { return partial.block }

            switch obj["type"]?.stringValue {
            case "text":
                obj["text"] = .string(partial.textBuffer)
            case "server_tool_use":
                // Replace the (empty) streamed input with the assembled JSON object.
                if let data = partial.jsonBuffer.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    obj["input"] = parsed
                } else if obj["input"] == nil {
                    obj["input"] = .object([:])
                }
            default:
                break  // web_search_tool_result and others arrive complete in start
            }
            return .object(obj)
        }
    }
}
