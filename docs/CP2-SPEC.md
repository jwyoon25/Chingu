# Chingu — Checkpoint 2 Implementation Spec

Detailed build spec for **Checkpoint 2 only** — the screenshot feature. Expands the CP2
section of [`SPEC.md`](SPEC.md). Read [`SPEC.md`](SPEC.md), [`CP1-SPEC.md`](CP1-SPEC.md), and
the parallel-dev contract [`PARALLEL-CP2-CP4.md`](PARALLEL-CP2-CP4.md) first.

> **Parallel-dev note.** CP2 is built on `cp2-screenshot`, in parallel with CP4 (speech) on
> `cp4-speech`. Stay inside CP2's file lane (see `PARALLEL-CP2-CP4.md` §2). The seam contract
> (`ChatViewModel.submit(text:image:)`) must already be on `main` before you branch.

---

## 0. Scope — what CP2 is and is NOT

**CP2 IS (CP1, plus):**
- A screenshot captured **the instant the user presses Enter**, excluding Chingu's own overlay.
- That screenshot sent to Claude as an `image` content block alongside the question.
- Contextual questions answered ("what does this mean?", "summarize my screen").
- Follow-ups that keep the screenshot context (it's in the message history).

**CP2 is NOT (do not build):**
- No on-screen pointing / circles / Accessibility API (CP3).
- No speech / mic / TTS (CP4 — separate branch, separate owner).
- No separate OCR/VLM pre-pass — Claude reasons over the pixels directly (`SPEC.md` §CP2).
- No two-call YES/NO text router — **always attach** the screenshot; the model uses or ignores it.
- No screenshot history UI, no per-message thumbnails (a tiny "📷 attached" hint is the most you add).
- No persistence of images to disk beyond what's in memory for the session.

---

## 1. The capture contract (state it to the user)

**The screen Chingu sees is the screen at the moment you press Enter.** Capture happens
synchronously on send, before the request goes out. This removes all ambiguity about *what*
Chingu is looking at. At capture time Chingu only grabs the image — no analysis.

---

## 2. Tech stack (CP2 additions)

| Concern | Choice |
|---|---|
| Capture | **ScreenCaptureKit** — `SCScreenshotManager.captureImage(contentFilter:configuration:)` |
| Overlay exclusion | `SCContentFilter(display:excludingWindows:)` — pass Chingu's panel window |
| Image encoding | `CGImage` → PNG via `NSBitmapImageRep` → base64 (no newlines) |
| Vision call | Same Messages API, `claude-opus-4-8` (already multimodal), add an `image` content block |
| Permission | **Screen Recording (TCC)** — one-time system prompt, expected |

Minimum target stays **macOS 14+** (`Package.swift` already declares `.macOS(.v14)`;
ScreenCaptureKit's modern API path needs 14). No new SwiftPM dependencies — ScreenCaptureKit
is a system framework.

> When unsure of the exact current Anthropic request shape for images, use the **`claude-api`
> skill** (`/claude-api`) — do not guess from memory. The verified shape is in §5 below.

---

## 3. File layout (CP2)

New logic goes in **new files** so it can't merge-conflict with CP4:

```
Sources/Chingu/
  ScreenCapture.swift   — NEW. ScreenCaptureKit wrapper: capture the active display,
                          exclude Chingu's panel, return a CapturedImage. Owns the
                          extension AppDelegate { setupCapture/permission } block too.
  ChatViewModel.swift   — EDIT. Flesh out CapturedImage; fill the `image` arg in submit();
                          pass it to the client.
  AnthropicClient.swift — EDIT. Accept an optional image on the send path; add the image
                          content block to the user message.
```

**Files you may touch (CP2 lane):** `ScreenCapture.swift` (new), `ChatViewModel.swift`
(image slot only), `AnthropicClient.swift`, and a read of the panel window from `main.swift` /
`ChinguPanel`. **Never touch:** `onAssistantResponseComplete`, any speech file (CP4's lane).

---

## 4. Component specs

### 4.1 `ScreenCapture.swift` (build first, in isolation)

**Responsibility:** capture the current screen as a `CapturedImage`, excluding Chingu's panel,
without moving or hiding the panel and without stealing focus.

**`CapturedImage`** — flesh out the seam stub from `ChatViewModel`:
```swift
struct CapturedImage {
    let base64: String      // PNG bytes, base64, NO newlines
    let mediaType: String   // "image/png"
}
```

**Capture flow:**
1. `let content = try await SCShareableContent.current` — get displays + windows.
2. Pick the display under the panel (or `SCShareableContent`'s main display).
3. Find Chingu's `SCWindow` by matching `windowID` to the panel's `windowNumber`
   (the AppDelegate owns `panel`; read `panel.windowNumber`).
4. `let filter = SCContentFilter(display: display, excludingWindows: [chinguWindow])`.
5. `let config = SCStreamConfiguration()` — set `width`/`height` to the display's pixel size
   (`display.width * scale`); keep `showsCursor` per taste (cursor not needed for Q&A).
6. `let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)`.
7. Encode: `NSBitmapImageRep(cgImage:)` → `.representation(using: .png, properties: [:])` →
   `.base64EncodedString()`. Return `CapturedImage(base64:, mediaType: "image/png")`.

**Why this excludes the overlay cleanly:** `excludingWindows:` composites the display *minus*
Chingu's window, so we photograph what's *behind* the overlay without hiding it. Because the
panel is non-activating (CP1), the app behind stays active at capture time — no flicker, no
focus change.

**Permission (Screen Recording / TCC):**
- First capture triggers the system prompt. Handle the not-yet-authorized path: if
  `SCShareableContent.current` throws / returns nothing, surface a clear in-chat message
  ("Chingu needs Screen Recording permission — enable it in System Settings › Privacy &
  Security › Screen Recording, then try again") instead of crashing.
- This is a CP2-only TCC prompt, distinct from CP4's Microphone prompt — no shared code.

### 4.2 `AnthropicClient.swift` — add the image content block

The user message currently sends one text block. Add an optional image:
- Thread an optional `image: CapturedImage?` down the `send` path (e.g.
  `func send(_ userText: String, image: CapturedImage? = nil)`).
- In `encodeRequestBody()` / where the user `WireMessage` is built, when `image != nil`,
  build the content array with the **image block first, then text** (vision best practice):
  ```swift
  // user content blocks when an image is attached
  [
    .object(["type": .string("image"),
             "source": .object([
               "type": .string("base64"),
               "media_type": .string(image.mediaType),   // "image/png"
               "data": .string(image.base64),
             ])]),
    .object(["type": .string("text"), "text": .string(userText)]),
  ]
  ```
- When `image == nil`, behavior is exactly today's (text-only) — so a follow-up without a new
  capture still works, and CP4's `submit(text:)` path is unaffected.
- Model stays `claude-opus-4-8`. Web search tool stays declared — a question can need both
  the screen and the web; the model decides.

> **History note.** The captured image lives in the assistant/user `history` like any other
> content block, so follow-ups naturally retain the screenshot context (stateless API, full
> thread resent — same as CP1). Don't re-capture on follow-ups unless the user presses Enter
> on a new question; each Enter is a fresh capture per the contract (§1).

### 4.3 `ChatViewModel.swift` — fill the image slot

This is the seam the contract reserved. Minimal edit:
- In `submit(text:image:)`, when sending, pass `image` to the client (`client.send(text, image:)`).
- The composer path captures the screen on Enter: `send()` (no-arg) calls
  `ScreenCapture.capture()` then `submit(text: trimmed, image: shot)`. If capture fails
  (permission), either submit text-only with an inline note, or block with the permission
  message — pick one; text-only-with-note is the gentler default.
- Optionally set `ChatMessage` to carry a small "📷 screen attached" flag for the user bubble
  (cosmetic; keep it tiny — full visual polish is a later pass, per the working agreement).

Do **not** touch `onAssistantResponseComplete` (CP4's slot).

### 4.4 AppDelegate wiring (separate extension)

Put any capture setup in `extension AppDelegate { }` inside `ScreenCapture.swift`, and add at
most **one line** to `applicationDidFinishLaunching` (e.g. `setupCapture()`), per the
`main.swift` split rule in `PARALLEL-CP2-CP4.md` §3c. The capture code needs the panel's
window reference — the AppDelegate already holds `panel`; expose `panel.windowNumber` to the
capture call. Don't restructure the panel.

---

## 5. Verified Anthropic request shape (from `/claude-api`)

One `user` message, image block **before** the text block, base64 with **no newlines**:

```json
{
  "role": "user",
  "content": [
    {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "<b64>"}},
    {"type": "text",  "text": "What does this mean in English?"}
  ]
}
```

- `media_type` ∈ `image/png` (what we encode), also accepts `image/jpeg`, `image/gif`, `image/webp`.
- Vision is on `claude-opus-4-8` with **no beta header** and no model change.
- Keep `max_tokens` at 4096 and `stream: true` — unchanged from CP1.
- Always attach (no router) — `SPEC.md` §CP2: one round-trip, model uses or ignores the image.

---

## 6. Acceptance criteria (CP2 "done")

1. Pressing Enter captures the screen **at that instant**, excluding Chingu's overlay, without
   hiding the panel or deactivating the app behind it.
2. A contextual question ("summarize my screen") returns an answer that clearly used the
   screenshot.
3. A non-screen question ("what is 49 × 52 + 10?") still answers correctly (model ignores the
   attached image) — one round-trip, no router.
4. A current-info question still triggers web search (CP1 capability intact).
5. Missing Screen Recording permission shows a clear in-chat message, never a crash.
6. Follow-ups retain prior screenshot context; a fresh Enter captures fresh.
7. No CP3/CP4 features. `swift build` green. No key/image logged or committed.

---

## 7. Build order (each tested before the next)

1. `ScreenCapture.swift` standalone — capture → encode → write the PNG to the scratchpad and
   eyeball it (verify the overlay is excluded).
2. `AnthropicClient` image block — send a hardcoded test image, confirm a vision answer.
3. Wire `ChatViewModel.submit(text:image:)` → capture on Enter.
4. Permission-denied path.
5. Verify acceptance criteria §6.

---

## 8. Known gotchas

- **`excludingWindows:` needs the right `SCWindow`.** Match on the panel's `windowNumber`;
  if you exclude the wrong window you'll either photograph the overlay or miss content.
- **TCC permission is async and sticky.** The first run prompts; subsequent runs are silent.
  Test the denied state by toggling the permission off in System Settings.
- **Base64 must have no newlines** — `base64EncodedString()` with default options is fine;
  don't use line-wrapping options.
- **Image-first ordering** — put the image block before the text block in `content`.
- **Don't re-capture on every request** — capture on the Enter that starts a turn; follow-ups
  reuse history. Re-capturing on a follow-up the user didn't trigger breaks the §1 contract.
- **For the API shape, use `/claude-api`** — never guess vision/SSE format from memory.
