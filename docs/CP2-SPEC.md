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

**The screen Chingu sees is the screen at the moment you press Enter.** ScreenCaptureKit's
capture API is `async`, so capture is *awaited* on send: the composer field clears instantly,
then the (sub-100ms) capture completes and the request goes out with the image already attached.
The user never sees a half-sent turn. This removes all ambiguity about *what* Chingu is looking
at. At capture time Chingu only grabs the image — no analysis.

---

## 2. Tech stack (CP2 additions)

| Concern | Choice |
|---|---|
| Capture | **ScreenCaptureKit** — `SCScreenshotManager.captureImage(contentFilter:configuration:)` (async) |
| Overlay exclusion | `SCContentFilter(display:excludingWindows:)` — exclude **all** windows owned by Chingu's own process (match `SCWindow.owningApplication?.processID` to our PID), not one tracked window |
| Image encoding | downscale to a **long edge ≤ 1568px** (aspect preserved), then `CGImage` → PNG via `NSBitmapImageRep` → base64 (no newlines) |
| Image limits | direct Claude API: **≤ 10 MB base64 / image**. `claude-opus-4-8` is the high-res tier (long edge ≤ 2576px), but the image is re-sent in `history` every turn, so we cap at 1568px to bound payload + per-turn vision tokens |
| Vision call | Same Messages API, `claude-opus-4-8` (already multimodal), add an `image` content block |
| Permission | **Screen Recording (TCC)** — one-time system prompt; first grant may need an app relaunch |

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
                          exclude Chingu's own windows (by PID), return a CapturedImage. Owns
                          the extension AppDelegate { setupCapture/permission } block too.
  ChatViewModel.swift   — EDIT. Flesh out CapturedImage; fill the `image` arg in submit();
                          pass it to the client.
  AnthropicClient.swift — EDIT. Accept an optional image on the send path; add the image
                          content block to the user message.
```

**Files you may touch (CP2 lane):** `ScreenCapture.swift` (new), `ChatViewModel.swift`
(image slot only), `AnthropicClient.swift`. **No edit to `main.swift`/`ChinguPanel` is needed** —
excluding by process ID (below) means we never read `panel.windowNumber`. **Never touch:**
`onAssistantResponseComplete`, any speech file (CP4's lane).

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
2. Pick the display to shoot: take the **active screen** (`NSScreen.main`), read its
   `CGDirectDisplayID` from `deviceDescription[.init("NSScreenNumber")]`, and find the matching
   `SCDisplay` (`content.displays.first { $0.displayID == screenNumber }`); fall back to
   `content.displays.first`. Pinning the display avoids shooting the wrong monitor.
3. **Exclude Chingu's own windows by process, not by a tracked window number.** `AppDelegate.panel`
   is `private` (file-scoped) and the capture code lives in a *separate* file, so it can't read
   `panel.windowNumber` — and it doesn't need to:
   ```swift
   let mine = ProcessInfo.processInfo.processIdentifier
   let chinguWindows = content.windows.filter { $0.owningApplication?.processID == mine }
   ```
   This catches every Chingu window and needs no reference into the AppDelegate body.
4. `let filter = SCContentFilter(display: display, excludingWindows: chinguWindows)`.
5. `let config = SCStreamConfiguration()` — set `width`/`height` to the capture size. Compute the
   display's pixel size (`display.width * scale`), then **downscale so the long edge ≤ 1568px**
   (aspect preserved) and pass those dimensions; SCScreenshotManager renders to that size.
   `showsCursor = false` (cursor not needed for Q&A).
6. `let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)`.
7. Encode: `NSBitmapImageRep(cgImage:)` → `.representation(using: .png, properties: [:])` →
   `.base64EncodedString()`. Return `CapturedImage(base64:, mediaType: "image/png")`.

**Why this excludes the overlay cleanly:** `excludingWindows:` composites the display *minus*
Chingu's own windows, so we photograph what's *behind* the overlay without hiding it. Because the
panel is non-activating (CP1), the app behind stays active at capture time — no flicker, no
focus change.

**Permission (Screen Recording / TCC):**
- First capture triggers the system prompt. Handle the not-yet-authorized path: if
  `SCShareableContent.current` throws / returns nothing, surface a clear in-chat message
  ("Chingu needs Screen Recording permission — enable it in System Settings › Privacy &
  Security › Screen Recording, then **quit and reopen Chingu**") instead of crashing.
- macOS often won't apply a *first* Screen Recording grant until the app is relaunched — so the
  message says "reopen," not just "try again." Subsequent runs are silent.
- This is a CP2-only TCC prompt, distinct from CP4's Microphone prompt — no shared code.

### 4.2 `AnthropicClient.swift` — add the image content block

The user message currently sends one text block. Add an optional image:
- Thread an optional `image: CapturedImage?` down the `send` path:
  `func send(_ userText: String, image: CapturedImage? = nil)`.
- **Attach the block where the user `WireMessage` is built — in `send()` (today's lines
  127–129), not in `encodeRequestBody()`.** `encodeRequestBody()` only maps the *existing*
  `history` into JSON; it never constructs the user block. Building the image block at the
  `history.append(WireMessage(role: "user", …))` site is also what puts the image *into history*,
  so follow-ups keep the screenshot context for free (see the History note below).
- When `image != nil`, build the content array with the **image block first, then text** (vision
  best practice):
  ```swift
  // user content blocks when an image is attached (built in send(), at the history.append site)
  [
    .object(["type": .string("image"),
             "source": .object([
               "type": .string("base64"),
               "media_type": .string(image.mediaType),   // "image/png" — must match the bytes exactly
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
  `image` is already a parameter — fill it; do **not** re-sign the function.
- The composer path captures the screen on Enter. Capture is `async`, so `send()` stays no-arg but
  clears the field synchronously (responsive) and awaits the shot before submitting:
  ```swift
  func send() {
      let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, !isResponding else { return }
      input = ""                                       // clear instantly
      Task {
          let shot = try? await ScreenCapture.capture()   // sub-100ms; nil if it fails
          submit(text: text, image: shot)                 // user bubble appears here
      }
  }
  ```
  If capture fails (permission denied), `shot` is `nil` and we submit **text-only** — the gentler
  default over blocking the turn. Optionally surface a tiny UI-only hint that the screen wasn't
  attached; do **not** inject that note into the prompt text sent to Claude. (`submit` runs on the
  MainActor as today.)
- Optionally set `ChatMessage` to carry a small "📷 screen attached" flag for the user bubble
  (cosmetic; keep it tiny — full visual polish is a later pass, per the working agreement).

Do **not** touch `onAssistantResponseComplete` (CP4's slot).

### 4.4 AppDelegate wiring (separate extension)

Put any capture setup in `extension AppDelegate { }` inside `ScreenCapture.swift`, and add at
most **one line** to `applicationDidFinishLaunching` (e.g. `setupCapture()`), per the
`main.swift` split rule in `PARALLEL-CP2-CP4.md` §3c. `setupCapture()` only **pre-warms the
Screen Recording permission** at launch (a throwaway `SCShareableContent.current` call) so the
system prompt appears up front rather than mid-question; the actual capture runs on Enter in
`ChatViewModel.send()`. The capture path needs **no** reference into the AppDelegate body: it
excludes Chingu's windows by process ID (§4.1 step 3), so `panel.windowNumber` is never read and
`main.swift`/`ChinguPanel` stay untouched.

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

- `media_type` ∈ `image/png` (what we encode) — must match the bytes **exactly** (`image/png`,
  not `image/jpg`). The API also accepts `image/jpeg`, `image/gif`, `image/webp`.
- **Limits / cost (verified against the Vision docs).** ≤ 10 MB base64 per image on the direct
  Claude API. `claude-opus-4-8` is the high-res tier (long edge ≤ 2576px), and oversized images
  are downscaled server-side (aspect preserved). Because the image stays in `history` and is
  re-sent every turn, we downscale on capture to **≤ 1568px long edge** (plenty for screen
  text/UI; 2576 only helps dense detail) — this bounds payload, latency, and per-turn vision
  tokens (~1.5k at 1568px vs ~4.8k at full high-res).
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

- **Exclude by process, not a tracked window.** `AppDelegate.panel` is `private` (file-scoped),
  so the capture code in `ScreenCapture.swift` can't read `panel.windowNumber`. Filter
  `content.windows` to those whose `owningApplication?.processID` is our PID and exclude all of
  them — robust, and needs no AppDelegate reference.
- **TCC permission is async, sticky, and may need a relaunch.** The first run prompts; the grant
  often doesn't take effect until Chingu is reopened. Subsequent runs are silent. Test the denied
  state by toggling the permission off in System Settings.
- **Downscale before encoding.** A full-res Retina screenshot is multi-MB and gets downscaled
  server-side anyway — and it's re-sent in `history` every turn. Cap the `SCStreamConfiguration`
  output at a 1568px long edge.
- **Base64 must have no newlines** — `base64EncodedString()` with default options is fine;
  don't use line-wrapping options.
- **Image-first ordering** — put the image block before the text block in `content`.
- **Don't re-capture on every request** — capture on the Enter that starts a turn; follow-ups
  reuse history. Re-capturing on a follow-up the user didn't trigger breaks the §1 contract.
- **For the API shape, use `/claude-api`** — never guess vision/SSE format from memory.

---

## 9. Known limitations & deferred optimizations (CP2 as shipped)

CP2 meets every §6 acceptance criterion (correctness, context retention, permission path). The
items below are **performance**, explicitly *out of CP2's acceptance scope* — tackle them in a
dedicated optimization pass after CP2 merges.

- **Per-turn latency grows with the number of screen questions.** The Messages API is stateless,
  so the full thread — including every prior screenshot — is re-sent each turn, and without
  prompt caching the model **re-prefills every one of those images** each time. Non-screen
  questions also pay image-prefill because we always attach (the no-router design, §0). Observed
  in testing: a fast first turn, then ~40s once several captures had accumulated in history.
  - **This is not a system-prompt issue.** A system prompt cannot make the model skip processing
    an attached image; vision prefill happens regardless. "The model ignores the image" means it
    ignores it in the *answer*, not that it skips reading it.
  - **Deferred fix (in `AnthropicClient`'s request-shape lane):** add `cache_control` prompt
    caching to the image/history blocks so re-sent screenshots are read from cache — this removes
    the compounding cost while **preserving** follow-up context (§6.6). Secondary levers: cap the
    number of retained images, or shrink the long edge below 1568px. JPEG would cut upload bytes
    but not vision-token prefill.
- **Possible over-eager web search.** With the placeholder empty system prompt, the model may
  invoke `web_search` for questions that don't need it, adding a round-trip. A future
  system-prompt pass can steer it to "only search for current/external info" — the one latency
  lever a prompt actually moves.
