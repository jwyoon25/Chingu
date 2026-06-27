# Cursor Handoff — CP2 (Screenshots) Agent

> Paste everything below the line into Cursor (model: **Claude Opus 4.8**) as your first
> message on the `cp2-screenshot` branch. Set up the branch first (see "Before you start").

**Before you start (human does this once):**
```sh
git checkout main && git pull
git checkout -b cp2-screenshot
swift build   # must be green before you begin
```

---

You are implementing **Checkpoint 2 (screenshots)** of Chingu, a Mac-native AI companion, in
this repo. You are working in parallel with another agent building Checkpoint 4 (speech) on a
separate branch — so staying strictly in your file lane is a hard requirement, not a
preference.

## Read these first, in order
1. `docs/PARALLEL-CP2-CP4.md` — the parallel-dev contract. **§0 is your hard rules.** §2 is the
   file-ownership map. Obey it.
2. `docs/CP2-SPEC.md` — your detailed build spec. Build from it directly.
3. `docs/SPEC.md` (CP2 section) and `docs/CP1-SPEC.md` — product + CP1 context.
4. Skim `Sources/Chingu/` to learn the existing code: `ChatViewModel.swift` (has the seam you
   fill), `AnthropicClient.swift` (you add the image block here), `ChinguPanel.swift` /
   `main.swift` (you read the panel window to exclude it from the screenshot).

## What CP2 is
Capture a screenshot the instant the user presses Enter, excluding Chingu's own overlay, and
send it to Claude as an `image` content block alongside the question. The model answers
contextual questions ("summarize my screen") and ignores the image for ones that don't need it.
**Always attach** — no YES/NO router, one round-trip.

## Your file lane — edit ONLY these
- **`Sources/Chingu/ScreenCapture.swift`** (NEW) — ScreenCaptureKit capture via
  `SCScreenshotManager.captureImage`, with `SCContentFilter(display:excludingWindows:)` to keep
  the panel out of the shot. Encode the `CGImage` → PNG → base64. Also put your
  `extension AppDelegate { setupCapture/permission }` here.
- **`Sources/Chingu/ChatViewModel.swift`** — flesh out the `CapturedImage` placeholder struct
  (add `base64: String` + `mediaType: String`); in `submit(text:image:)` pass `image` to the
  client; in `send()` capture the screen before calling `submit`. **Edit only the image-related
  lines.**
- **`Sources/Chingu/AnthropicClient.swift`** — thread an optional `CapturedImage` down the send
  path; add the image content block to the user message (verified shape below).
- You may **read** `panel.windowNumber` from `main.swift`/`ChinguPanel` to exclude the overlay.
  Don't restructure the panel.

## NEVER touch (CP4's lane — causes merge conflicts)
- `onAssistantResponseComplete` (the TTS hook in `ChatViewModel`) — leave it completely alone.
- Any speech file (`SpeechService.swift`, `MicCapture.swift`) — they may appear when CP4 merges.
- Don't edit `AnthropicClient` for anything except the image block.

## The seam is a contract — do not reshape it
The entry point `ChatViewModel.submit(text:image:)` is locked. Fill the `image` parameter; do
**not** rename or re-sign the function. `send()` stays a no-arg composer wrapper so `ChatView`
needs zero edits.

## Verified Anthropic request shape (image block) — do not guess
Model stays `claude-opus-4-8` (already multimodal, no model change, no beta header). One `user`
message, **image block before text block**, base64 with **no newlines**:
```json
{
  "role": "user",
  "content": [
    {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "<b64>"}},
    {"type": "text",  "text": "<the user's question>"}
  ]
}
```
`AnthropicClient` already builds content arrays with its `JSONValue` enum — add one more block
when an image is attached. If you need any other Anthropic API detail, invoke the **`/claude-api`
skill** — never guess the API shape from memory.

## Build order (test each before the next)
1. `ScreenCapture.swift` standalone: capture → encode → write the PNG to a temp file and verify
   the overlay is excluded.
2. `AnthropicClient` image block: send a test image, confirm a vision answer.
3. Wire `submit(text:image:)` → capture on Enter.
4. Screen Recording permission-denied path → clear in-chat message, no crash.
5. Verify the §6 acceptance criteria in `CP2-SPEC.md`.

## Hard rules (from PARALLEL-CP2-CP4.md §0)
- New logic → new files. Don't grow shared files beyond the image slot.
- AppDelegate additions → your own `extension AppDelegate { }`, plus at most ONE line
  (`setupCapture()`) in `applicationDidFinishLaunching`. Don't refactor the AppDelegate body.
- `swift build` must stay green before every push. A broken `main`/branch blocks the other agent.
- **No new SwiftPM dependencies** — ScreenCaptureKit is a system framework. If you think you need
  a package, stop and ask the human.
- **Do not run git commands** (commit/branch/push) unless the human tells you to. The humans own
  the branch/merge protocol.
- Never log, print, or commit the API key or raw image data.

## When you finish
Tell the human: CP2 is built, `swift build` is green, summarize the files you changed, and note
that CP2 merges to `main` first (before CP4 rebases). Don't merge yourself.
