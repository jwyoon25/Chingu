import Foundation

/// A point Claude asked us to circle on screen, in **screenshot-pixel** space.
///
/// Coordinates are integer pixels in the coordinate space of the screenshot Claude
/// was shown (origin top-left, x right, y down) — the exact space we announce to it in
/// the dimensions note (see `AnthropicClient.userContent`). `PointingController` remaps
/// these to an on-screen point using the turn's `CaptureGeometry`.
struct ParsedPoint: Equatable {
    let x: Int
    let y: Int
    /// A 1–3 word control name ("Bold", "Source Control") to show beside the circle.
    let label: String
}

/// Parses Chingu's pointing tag out of a Claude reply (see `docs/CP3-SPEC.md` §8).
///
/// CP3's pointing protocol (taught in `SystemPrompt`) has the model append, at the very
/// end of its reply, exactly one machine-readable tag:
///
///   • `[POINT:x,y:label]` — circle the control at pixel `x,y`, captioned `label`.
///   • `[POINT:none]`      — pointing wouldn't help; no circle.
///
/// This type is pure and side-effect free so it's trivially testable. It is deliberately
/// **lenient**: a missing or malformed tag yields `(reply, nil)` — a bad tag must never
/// break the chat. The tag is always stripped from the text the user sees and hears, so
/// neither the bubble nor TTS ever renders a coordinate.
enum PointTag {

    /// Split a finished reply into its human-facing text (tag removed, trimmed) and the
    /// parsed point (`nil` for `[POINT:none]`, a malformed tag, or no tag at all).
    ///
    /// Authoritative — call this once per turn in `ChatViewModel`'s `.done` branch.
    static func parse(_ reply: String) -> (clean: String, point: ParsedPoint?) {
        guard let tagRange = trailingTagRange(in: reply) else {
            return (reply.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let tag = String(reply[tagRange])
        let clean = String(reply[reply.startIndex..<tagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, point(from: tag))
    }

    /// Display-only guard against the tag flashing in the bubble while it streams in
    /// character-by-character. Removes a complete trailing tag **or** an unterminated
    /// trailing `[POINT…` fragment, trimming only trailing whitespace (internal text is
    /// untouched). The authoritative strip still happens in `.done` via `parse`.
    static func strippingTrailingTag(_ text: String) -> String {
        if let tagRange = trailingTagRange(in: text) {
            return String(text[text.startIndex..<tagRange.lowerBound])
                .trimmingTrailingWhitespace()
        }
        // An in-progress tag: from the last unmatched `[`, the trailing text is a partial
        // tag if it has no closing `]` yet and is consistent with the marker `[POINT` —
        // i.e. it's a prefix of the marker (e.g. `[POI`) or starts with it (e.g.
        // `[POINT:51`). This guards against any streamed fragment without touching normal
        // bracketed text like `array[0]` (which has a `]`) or `foo[bar` (diverges early).
        if let open = text.range(of: "[", options: .backwards) {
            let suffix = text[open.lowerBound...].lowercased()
            let marker = "[point"
            if !suffix.contains("]"), suffix.hasPrefix(marker) || marker.hasPrefix(suffix) {
                return String(text[text.startIndex..<open.lowerBound])
                    .trimmingTrailingWhitespace()
            }
        }
        return text
    }

    // MARK: - Internals

    /// Range of a complete `[POINT:…]` tag anchored to the end of the string (allowing
    /// trailing whitespace/newlines). `nil` if there's no trailing tag.
    private static func trailingTagRange(in text: String) -> Range<String.Index>? {
        // `[POINT:` then anything but a closing bracket, the bracket, then only
        // whitespace to the end of the string.
        guard let regex = try? NSRegularExpression(
            pattern: #"\[POINT:[^\]]*\]\s*$"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, options: [], range: full) else {
            return nil
        }
        return Range(match.range, in: text)
    }

    /// Parse the contents of a matched tag into a `ParsedPoint`, or `nil` for
    /// `[POINT:none]` and anything malformed.
    private static func point(from tag: String) -> ParsedPoint? {
        // `[POINT:none]` (any case, tolerant of inner spaces) → no point.
        if tag.range(of: #"\[POINT:\s*none\s*\]"#,
                     options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        // `[POINT:x,y:label]` — two ints, then a 1–40 char label (may contain spaces).
        guard let regex = try? NSRegularExpression(
            pattern: #"\[POINT:\s*(\d+)\s*,\s*(\d+)\s*:\s*([^\]]{1,40}?)\s*\]"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = tag as NSString
        guard let m = regex.firstMatch(in: tag, options: [],
                                       range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 4,
              let x = Int(ns.substring(with: m.range(at: 1))),
              let y = Int(ns.substring(with: m.range(at: 2)))
        else { return nil }

        // A label may carry a stray `:screenN` suffix (reserved for a future
        // multi-monitor build); drop it and keep the human-readable name.
        var label = ns.substring(with: m.range(at: 3))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = label.firstIndex(of: ":") {
            label = String(label[label.startIndex..<colon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !label.isEmpty else { return nil }
        return ParsedPoint(x: x, y: y, label: label)
    }
}

private extension String {
    /// Drop trailing spaces/tabs/newlines without touching internal whitespace.
    func trimmingTrailingWhitespace() -> String {
        var s = self[...]
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return String(s)
    }
}
