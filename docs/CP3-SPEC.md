# Chingu — Checkpoint 3 Implementation Spec

Detailed build spec for **Checkpoint 3 only** — on-screen pointing. Expands the CP3 section of
[`SPEC.md`](SPEC.md). Read [`SPEC.md`](SPEC.md), [`CP1-SPEC.md`](CP1-SPEC.md), and
[`CP2-SPEC.md`](CP2-SPEC.md) first — CP3 builds directly on CP2's screenshot pipeline.

> **Topology note.** CP3 is **not** part of the CP2 ∥ CP4 parallel phase. It is **sequential
> after CP2** (same owner), and branches off `main` once CP2 has landed (see
> [`PARALLEL-CP2-CP4.md`](PARALLEL-CP2-CP4.md) §0). It therefore has more freedom to edit shared
> files than CP2/CP4 did — but it must still keep the locked seam
> (`submit(text:image:)` / `onAssistantResponseComplete`) intact, keep `swift build` green, and
> not break CP4's voice path when the two are merged.

> **⚠️ This spec pivots the CP3 approach.** `SPEC.md`'s CP3 section describes a **two-stage**
> design: *Claude picks the target, the **Accessibility API** (`AXUIElement`) measures its exact
> rect.* **This spec replaces that with a pure-vision design** inspired by *Hey Clicky*: Claude
> looks at the screenshot and **reports the pixel coordinates by eye**; the app trusts the number,
> remaps it to a screen position, and draws a **circle** there. **There is no Accessibility tree,
> no OCR, no `AXUIElement` query in the live path.** Accuracy is entirely the vision model's
> spatial accuracy — which is why we (a) tell Claude the exact pixel space, (b) draw a forgiving,
> large circle rather than a pixel-precise dot, and (c) nudge Claude toward clearly identifiable,
> non-edge targets in the prompt. `SPEC.md` §CP3 must be updated to match once this is approved.

---

## 0. Scope — what CP3 is and is NOT

**CP3 IS (CP1 + CP2, plus):**
- A **circle overlay** drawn on screen, over the target app, pointing at the single control the
  user should click next — *e.g. "How do I bold this?" → a circle lands on the Bold button.*
- Coordinates come **purely from Claude's vision** (it reports `x,y` pixels in the screenshot's
  coordinate space). The app **trusts** the number and converts it to an on-screen position.
- The circle is shown in a **non-activating, click-through overlay** — it never steals focus and
  never blocks the click; the user clicks the real button underneath it.
- A short text **label** (1–3 words, e.g. "Bold") rendered with the circle, matching the spoken
  sentence.
- **CP3a (single-step)** is the core deliverable. **CP3b (multi-step "what's next")** is a thin
  layer on top — covered in §9, scoped per the question below.

**CP3 is NOT (do not build):**
- **No clicking, typing, dragging, or any UI actuation.** Chingu points and narrates; the **human
  performs every action.** (This is the load-bearing safety boundary — same as Hey Clicky.)
- **No Accessibility API / `AXUIElement` / Computer-Use element detection** in the live path. (A
  rigorous detector could be a *future* upgrade — see §13 — but it is explicitly out of scope.)
- No OCR / VLM pre-pass — the one multimodal Claude call already in CP2 does the seeing.
- No verification that a control is actually at the reported coordinate — we trust Claude (this is
  the known accuracy trade-off; the large circle is the hedge).
- No persistent pointing UI, settings, or per-app calibration.

---

## 1. The pointing model (how Chingu "knows" which button)

Borrowed from *Hey Clicky*, adapted to a circle. The honest one-liner: **Chingu knows which
button purely because Claude eyeballs the screenshot and guesses its pixel location, formatted as
a tag the app trusts and converts to a screen position.** The full sequence:

1. **Ask.** The user summons Chingu (⌃⌥⌘K) and asks — typed (CP1/CP2) or, once CP4 is merged,
   spoken. Pressing Enter (or finishing a voice turn) is the trigger.
2. **Capture.** CP2 already screenshots the active display the instant the turn starts, excluding
   Chingu's own windows. CP3 additionally records the screenshot's **pixel dimensions** and the
   captured **display's frame** (its coordinate geometry) for that turn (§4).
3. **Tell Claude the coordinate space.** The request carries the image **plus a short text note of
   its exact pixel dimensions** ("the screenshot is `W×H` pixels, origin top-left") so Claude
   anchors its coordinates to the image it actually sees (§5).
4. **Claude points in the prompt.** The system prompt (§5) teaches Claude that it has a circle it
   can place on screen, to point whenever it would help, and to append a machine-readable tag at
   the **very end** of its reply: `[POINT:x,y:label]` (or `[POINT:none]` when pointing wouldn't
   help). `x,y` are integer pixels in the screenshot's space; `label` is a 1–3 word control name.
5. **Stream text + tag.** Claude streams the spoken sentence and the tag in one response, e.g.
   *"See the Bold button in the toolbar? Click that."* `[POINT:512,96:Bold]`.
6. **Parse + strip.** When the turn completes, the app pulls the tag off the end with a regex,
   splits the **spoken/displayed text** (tag removed, so the coordinate is never shown or read
   aloud) from the parsed `(x, y, label)` (§8).
7. **Remap.** The app converts the screenshot-pixel coordinate into an on-screen point: scale from
   screenshot pixels to display points, place it within the captured display, and offset for
   multi-monitor (§6). The app does **no** verification that a control is actually there.
8. **Show the circle.** A non-activating, click-through overlay window animates a circle onto the
   target and shows the label; if CP4 is present, the (tag-stripped) sentence is also spoken.
9. **The user clicks.** Chingu's job ends at pointing + narration; the human does the click.

**Why this is feasible without an element lookup:** the circle is **forgiving** — sized to absorb
the vision model's typical error (often tens of pixels) — and the prompt steers Claude toward
large, unambiguous, non-edge targets. We accept the occasional slightly-off landing as the cost of
a zero-infrastructure pointer.

---

## 2. Tech stack (CP3 additions)

| Concern | Choice |
|---|---|
| Pointer overlay | A second **non-activating `NSPanel`** (borderless), full-display, **`ignoresMouseEvents = true`** (click-through), high window level. SwiftUI circle hosted via `NSHostingView`. |
| Circle visuals | SwiftUI `Circle().stroke(...)` with a pop/pulse animation + a small label caption. |
| Coordinate source | **Claude vision only** — the `[POINT:x,y:label]` tag. No ScreenCaptureKit element APIs, no Accessibility. |
| Capture geometry | Extend CP2's `ScreenCapture` to also return screenshot pixel size + the captured `NSScreen`/display frame. |
| Permissions | **None new.** Screen Recording (CP2) is the only TCC prompt. **Accessibility permission is NOT needed** (we never read the UI tree or post events). |

**No new SwiftPM dependencies** — AppKit + SwiftUI + ScreenCaptureKit (already in use) cover it.
Minimum target stays **macOS 14+**.

> The Anthropic request shape is unchanged from CP2 except for the small dimensions text block
> (§5). If unsure of the exact image/text content-block shape, use the **`/claude-api` skill** —
> don't guess from memory.

---

## 3. File layout & ownership (CP3)

New logic goes in **new files**; shared-file edits are kept tight and explained.

```
Sources/Chingu/
  PointerOverlay.swift    — NEW. The click-through overlay window (non-activating NSPanel) +
                            the SwiftUI circle/label view + the show/hide/animate API. Also
                            holds `extension AppDelegate { setupPointer() }` if any launch
                            wiring is needed.
  PointingController.swift — NEW. @MainActor ObservableObject. Parses the [POINT] tag, remaps
                            the coordinate to screen points (§6), and drives PointerOverlay.
                            Owns the circle's lifecycle (show, dismiss, re-point).
  PointTag.swift          — NEW (optional). The tag grammar + regex parser as a pure, testable
                            function: String -> (clean: String, point: ParsedPoint?).
  SystemPrompt.swift      — EDIT. Add the pointing protocol + few-shot examples (§5). This is the
                            first real (non-placeholder) system-prompt content.
  ScreenCapture.swift     — EDIT. Return capture geometry (pixel size + display frame) alongside
                            the CapturedImage so coordinates can be remapped (§4).
  ChatViewModel.swift     — EDIT. Carry the turn's capture geometry; in the .done branch, strip
                            the tag from the final text (so neither the bubble nor TTS shows it)
                            and hand the parsed point + geometry to the PointingController (§8).
  AnthropicClient.swift   — EDIT. Append the "(image is W×H pixels…)" text block after the image
                            block, using dimensions carried on CapturedImage (§5).
  ChatView.swift          — EDIT (small). Own the PointingController; optional UI affordance to
                            dismiss the circle. No message-list changes.
```

**Seam discipline (still applies):** do **not** rename or re-sign `submit(text:image:)` or
`onAssistantResponseComplete`. CP3's `ChatViewModel` edits are *additive* (carry geometry, strip
the tag, fire a new pointing hook) and must leave CP4's TTS hook working — when CP4 is merged, TTS
must receive the **tag-stripped** text (§8).

---

## 4. Capture geometry — the coordinate space (extend CP2)

Coordinate remapping needs three numbers that CP2's `capture()` currently throws away: the
screenshot's **pixel** size (Claude's `x,y` space) and the captured **display's frame in points**
(where the circle goes, in AppKit global coordinates). Extend `ScreenCapture` to return them.

```swift
/// Geometry of the screenshot used for a turn — everything needed to map a
/// screenshot-pixel coordinate back to an on-screen point.
struct CaptureGeometry: Equatable, Sendable {
    let pixelWidth: Int        // screenshot width  in px  (Claude's x-axis, 0…pixelWidth)
    let pixelHeight: Int       // screenshot height in px  (Claude's y-axis, 0…pixelHeight)
    let displayFrame: CGRect   // captured display's frame in AppKit points (global, bottom-left origin)
    // (multi-monitor only) let displayID: CGDirectDisplayID; let screenIndex: Int
}
```

- `ScreenCapture.capture()` becomes `capture() async throws -> (CapturedImage, CaptureGeometry)`
  (or returns one combined struct). `pixelWidth/Height` are the **downscaled** dimensions actually
  encoded (CP2 already computes these in `downscaledPixelSize`); `displayFrame` is the captured
  `NSScreen.frame` (points).
- **Also add the pixel size to `CapturedImage`** (`pixelWidth`, `pixelHeight`) so `AnthropicClient`
  can emit the dimensions note (§5) without reaching for geometry.

> **Critical accuracy invariant — keep "what we tell Claude" == "what Claude sees."** Anthropic
> resizes images server-side if they exceed the model's tier limits (long edge **and** a
> visual-token/megapixel cap), and Claude reports coordinates **relative to the image it sees
> after any resize**. If we announce dims that don't match, every point lands off.
>
> **Verified (Anthropic vision docs, 2026-06):** `claude-opus-4-8` is on the **high-resolution
> tier — ≤ 2576 px long edge, ≈ 3.75 MP, automatic (no beta header).** CP2's existing **1568 px**
> long-edge cap therefore produces images **well under both** limits (e.g. 1568×980 ≈ 1.54 MP),
> so Anthropic does **not** re-downscale them — the dims CP2 computes in `downscaledPixelSize`
> (and `cgImage.width/height`) are **exactly** the space Claude reports in. **As built:** we keep
> the 1568 cap, report `cgImage.width/height` verbatim in the note, and rely on this invariant.
> (Raising the cap toward 2576 would sharpen text/localization at ~3× the vision-token cost — an
> option, not needed for v1.) *The earlier worry about a ~1.15 MP standard-tier cap does not
> apply to Opus 4.8.*

---

## 5. The pointing protocol (system prompt + tag)

This is where "which button" actually lives — in **prompt instructions**, not an algorithm.

### 5a. The dimensions note (so coordinates are anchored)

When an image is attached, the user turn carries, in order: **image block → dimensions text →
the question.** The dimensions block is built from `CapturedImage.pixelWidth/Height`:

```jsonc
{
  "role": "user",
  "content": [
    {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "<b64>"}},
    {"type": "text",  "text": "(The screenshot above is 1568x980 pixels. Coordinate origin is top-left; x increases right, y increases down.)"},
    {"type": "text",  "text": "How do I make this bold?"}
  ]
}
```

`AnthropicClient.userContent(text:image:)` adds the middle block only when `image != nil`. Text-only
turns (voice without a screen, follow-ups) are unchanged.

### 5b. The system prompt (replace the placeholder)

`SystemPrompt.text` is currently a stub. CP3 makes it real. It must teach Claude to:

- Know it has a **circle** it can place on screen to point at one control, and to **point whenever
  it would help** the user act (finding a button, menu, field) — but **not** for general-knowledge
  or non-screen questions.
- Append, at the **very end** of the reply, exactly one tag:
  - `[POINT:x,y:label]` — `x,y` integer **pixels in the screenshot's coordinate space** (the dims
    it was told), `label` a **1–3 word** control name. (Multi-monitor adds `:screenN`; omit for the
    single-display build — see the open question.)
  - `[POINT:none]` — when pointing wouldn't help.
- **Point at the center** of a clearly identifiable, reasonably large control; **avoid screen edges
  and tiny/ambiguous targets** (the circle is forgiving but not infinitely so).
- Write the spoken sentence so it **refers to the control by name/appearance** ("the Bold button in
  the toolbar"), never by raw coordinates — the user never hears or sees numbers.
- Point at **one** control (the immediate next click). For a multi-step path, point at the **first**
  step and tell the user what to do, then they ask "what's next" (§9).

Include a couple of **few-shot examples** (Hey Clicky does this), e.g.:

> *User:* "How do I commit in Xcode?" *(screenshot 1440×900)*
> *Assistant:* "Open the Source Control menu at the top, then choose Commit." `[POINT:286,11:Source Control]`

Keep web-search behavior intact — the prompt addition is *additive*; a question can still need the
web and/or the screen, and Claude decides.

> Put the literal prompt text in `SystemPrompt.swift`. Keep it tight; over-long prompts dilute the
> instruction. The tag grammar must be stated **exactly** so the §8 regex matches it.

---

## 6. Coordinate remapping (screenshot pixels → screen point)

Given a parsed `(x, y)` in screenshot-pixel space and the turn's `CaptureGeometry`:

1. **Clamp** to the image bounds: `x ∈ [0, pixelWidth]`, `y ∈ [0, pixelHeight]`.
2. **Scale** pixels → points using the captured display:
   `sx = displayFrame.width / pixelWidth`, `sy = displayFrame.height / pixelHeight`.
   `localX = x * sx` (points from the display's left), `localTopY = y * sy` (points from the
   display's **top**).
3. **Place on the display.** Two equivalent framings — pick by overlay strategy (§7):
   - **Full-display SwiftUI overlay (recommended):** make the overlay window exactly cover
     `displayFrame`, host a SwiftUI view whose origin is **top-left**. Then the circle's SwiftUI
     position is simply `(localX, localTopY)` — **no Y-flip needed**, because SwiftUI's top-left
     origin already matches the screenshot's. The Y-flip is absorbed by the window covering the
     display.
   - **Small window positioned globally (AppKit):** convert to AppKit's bottom-left global space:
     `globalX = displayFrame.minX + localX`, `globalY = displayFrame.minY + (displayFrame.height - localTopY)`,
     then center the small circle window there.

The recommended full-display SwiftUI overlay avoids manual Y-flips and makes the circle trivial to
position and animate. **The app trusts the number completely** — no "is a button really here?"
check.

---

## 7. The pointer overlay window (the circle)

A **separate** window from the chat panel — the chat panel is a fixed 520×520 card below the
notch; the circle must be able to appear **anywhere** on the display, over any app, and **must let
clicks through** so the user can press the button it's pointing at.

**`PointerOverlayPanel: NSPanel`** (in `PointerOverlay.swift`) — mirrors the focus discipline of
`ChinguPanel` but adds click-through:

- Style mask `[.borderless, .nonactivatingPanel]` — never activates Chingu, never takes focus.
- **`ignoresMouseEvents = true`** — the single most important property: the circle is purely
  visual; every click, scroll, and hover passes straight through to the app beneath. (Without this,
  the overlay would eat the very click it's telling the user to make.)
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`.
- `level` **above** `.statusBar` (e.g. `.screenSaver` or `CGWindowLevel(for: .maximumWindow)`) so
  the circle floats above the target app's open menus too.
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`.
- `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`.
- Frame = the captured display's `frame`; content = `NSHostingView` of the circle view.
- Shown with `orderFrontRegardless()` — **never** `makeKey`/`activate` (it has nothing to type
  into, and must not steal focus).

**Self-exclusion from re-capture is free.** CP2's `ScreenCapture` excludes **all windows owned by
our PID**, so this overlay is automatically kept out of the next screenshot — essential for the
multi-step "what's next" re-capture (§9): the circle never photobombs the shot Claude reasons over.

**`PointerCircleView` (SwiftUI):**
- A stroked `Circle` (≈ **90–110 pt** diameter — deliberately large to absorb vision error),
  accent-tinted, semi-transparent fill, with a subtle **pulse** animation so the eye finds it.
- An optional short **label** caption (the tag's `label`) beside/below the circle.
- A brief **appear** animation (scale-in / pop). A "fly-in" arc like Hey Clicky's cursor is a nice
  polish but not required for a circle — list it under future polish.
- Positioned at `(localX, localTopY)` from §6 via `.position(x:y:)` in the full-display overlay.

**Lifecycle / dismissal:** the circle persists until one of: a **new turn** starts (next question →
new capture → re-point or clear), the panel is **dismissed** (⌃⌥⌘K hides Chingu → also hide the
circle), or the user presses **Esc** while the panel is focused. We **cannot** reliably detect the
actual click without an event tap (a CP3-out-of-scope Accessibility/event-tap concern), so we do
**not** auto-dismiss on click — matching Hey Clicky ("its job ends at pointing"). A gentle
**Confirmed:** the circle **also auto-fades after a timeout (~5 s)** so a stale circle doesn't
linger if the user walks away or ignores it.

---

## 8. Parsing & integration (where the tag is handled)

The tag is always at the **very end** of the reply, so it can only be parsed reliably once the turn
is **complete**. The single chokepoint is `ChatViewModel`'s `.done` branch — which is *also* where
CP4's `onAssistantResponseComplete` fires. Handle the tag **there, before** setting the visible
bubble text and **before** the TTS hook, so neither shows or speaks the coordinate.

### 8a. The parser (`PointTag.swift`)

A pure function, easy to unit-test:

```swift
struct ParsedPoint: Equatable { let x: Int; let y: Int; let label: String /*; let screen: Int?*/ }

enum PointTag {
    /// Splits a reply into its human text (tag removed) and the parsed point (nil for
    /// [POINT:none] or no tag). Anchored to the end of the string.
    static func parse(_ reply: String) -> (clean: String, point: ParsedPoint?)
}
```

- Match `[POINT:none]` (case-insensitive, tolerant of spaces) → `(reply minus tag, nil)`.
- Match `[POINT:<int>,<int>:<label>]` → `(reply minus tag, ParsedPoint)`. Suggested regex
  (anchored to end, allowing trailing whitespace):
  `\[POINT:\s*(\d+)\s*,\s*(\d+)\s*:\s*([^\]:]{1,40}?)\s*\]\s*$`
  (add an optional `(?::screen(\d+))?` group before the closing `]` for the multi-monitor build).
- No tag → `(reply, nil)` (be lenient — a missing/malformed tag must never break the chat).
- Trim trailing whitespace/newline left behind after removing the tag.

### 8b. Wiring in `ChatViewModel` (.done branch)

Additive edits, leaving the seam intact:

1. **Carry geometry for the turn.** `send()` already captures on Enter; have it stash the
   turn's `CaptureGeometry` (e.g. a transient `currentGeometry`), and pass the geometry through (or
   keep it on the VM, since one turn is in flight at a time).
2. In `.done`, after assembling `finalText`:
   - `let (clean, point) = PointTag.parse(finalText)`
   - Set the bubble text to **`clean`** (so the tag never renders).
   - Call `onAssistantResponseComplete?(clean)` — **CP4 speaks the clean text** (no "open bracket
     POINT" read aloud).
   - Fire a **new pointing hook**: `onPointing?(point, currentGeometry)`. The `PointingController`
     sets this closure (same outside-in pattern CP4 uses for TTS) — it remaps + shows/clears the
     circle. `point == nil` ⇒ clear any existing circle.

```swift
/// CP3 pointing hook — fired once per turn with the parsed point (nil = clear) and the
/// geometry of the screenshot it refers to. The PointingController sets this. Default nil = no-op.
var onPointing: ((ParsedPoint?, CaptureGeometry?) -> Void)?
```

> **Streaming flash (polish).** Because the tag streams in char-by-char at the end, a partial
> `[POINT:51` can briefly flash in the bubble before `.done` strips it. v1 may accept the brief
> flash; the clean fix is a small **tail-guard** in the delta handler: once the streamed text
> contains an unterminated `[POINT`, hold the tail back from the visible bubble until `.done`.
> List as a refinement, not a blocker.

### 8c. `ChatView` ownership

`ChatView` already owns `VoiceController` as a `@StateObject` built from `model`. Add the
`PointingController` the same way (`@StateObject private var pointer = PointingController(model:)`),
so `main.swift` needs no change. The controller sets `model.onPointing` in its `init`.

---

## 9. CP3a (single-step) and CP3b (multi-step)

### CP3a — single-step pointing (the core)
Everything above. One question → one circle on the immediate next control (or `[POINT:none]`). This
is the full, demoable deliverable and where the build effort goes.

### CP3b — multi-step "what's next"
The genius of the vision approach: **multi-step mostly falls out of CP2 + CP3a + follow-ups.** To
walk a user through a sequence (e.g. an overflow menu):

1. Chingu points at the **first** control and tells the user to click it and then ask "what's next".
2. The user clicks (opening the next menu state), then **signals** they're ready.
3. On that signal Chingu **re-captures** (the menu is now open; our overlay is excluded from the
   shot by PID), Claude sees the new state, and the circle moves to the next control.

**The focus-stealing trap (from `SPEC.md` §CP3b):** clicking into Chingu's text field to type
"what's next" would **activate Chingu, deactivate the target app, and close the open menu.** So the
advance signal must **not** take focus. Options (this is the open question below):

- **Voice "what's next" (cleanest; needs CP4):** zero focus change. The voice path must capture a
  screen before submitting (today CP4's voice path skips `send()`/capture — see the gotcha in §14).
- **A dedicated advance hotkey:** on press, re-capture + auto-submit "what's next" *without*
  showing/hiding the panel. Focus-preserving. (The main ⌃⌥⌘K currently toggles the panel + voice,
  so a *separate* combo, or a press-while-circle-visible behavior, is needed.)
- **Typing (always available, focus-breaking):** acceptable when the user is *abandoning* the
  current step to refine the question — Chingu re-captures fresh on the next Enter anyway.

The rule, straight from `SPEC.md`: **a focus-preserving signal (voice or hotkey) to advance; typing
available when you're done with the current menu.**

---

## 10. Component specs (per file)

### 10.1 `PointTag.swift` (build first — pure, testable)
The grammar + `parse(_:)` from §8a. No UI, no state. Build and unit-test against real and malformed
replies (`[POINT:none]`, no tag, extra spaces, a label with spaces, a trailing newline) before
anything else — it's the contract between Claude's output and the overlay.

### 10.2 `PointerOverlay.swift` (build second — in isolation)
The `PointerOverlayPanel` (§7) + `PointerCircleView` + a tiny imperative API:
```swift
@MainActor final class PointerOverlay {
    func show(atLocalPoint p: CGPoint, label: String, onDisplay frame: CGRect)
    func hide()
}
```
Validate standalone with **hardcoded** points (e.g. screen center, each corner) before any Claude
wiring: confirm the circle lands where expected, sits above menus, and **clicks pass through** to
the app underneath.

### 10.3 `PointingController.swift` (the orchestrator)
`@MainActor ObservableObject`. Holds a `PointerOverlay`, a reference to the `ChatViewModel`, and
sets `model.onPointing` in `init` (outside-in, like `VoiceController`). On each fire:
- `nil` point → `overlay.hide()`.
- non-nil → remap via §6 using the passed `CaptureGeometry` → `overlay.show(...)`.
- Also hide on Chingu dismiss (observe the same `.chinguDeactivateVoice` notification, or a new
  `.chinguHidden`, that `main.swift` already posts on hide) and on Esc.

### 10.4 `SystemPrompt.swift` (the prompt)
Replace the placeholder with the §5b prompt. This is intentional: CP3 is the checkpoint that gives
Chingu a real instruction layer. Keep web-search and plain Q&A behavior; the pointing protocol is
additive.

### 10.5 `ScreenCapture.swift` / `AnthropicClient.swift` / `ChatViewModel.swift` / `ChatView.swift`
The edits described in §4, §5a, §8b, §8c respectively. All additive; the locked seam keeps its
signature.

---

## 11. Acceptance criteria (CP3 "done")

1. A "where do I click" question over a real app draws a **circle on the correct control** (within
   the circle's tolerance), with a matching label, over the live app.
2. The circle is **click-through**: the user clicks the button under it and it actuates normally;
   Chingu never intercepts the click and never steals focus from the target app.
3. The **coordinate/tag is never shown** in the chat bubble nor (with CP4) **spoken** — only the
   clean sentence is.
4. A non-screen / general-knowledge question yields **`[POINT:none]`** → no circle, normal answer.
5. Web search (CP1) and screenshot Q&A (CP2) still work unchanged.
6. **No new permission** beyond CP2's Screen Recording; no Accessibility prompt. No crash if a tag
   is malformed or absent (graceful: just no circle).
7. The circle clears on a new turn / on Chingu dismiss / on Esc.
8. `swift build` green. No key, image bytes, or coordinates logged or committed.
9. *(If CP3b in scope)* After clicking the first control and signaling "what's next", Chingu
   re-captures and moves the circle to the next control **without** closing the open menu.

---

## 12. Build order (each tested before the next)

1. `PointTag.swift` + tests (parse/strip, including malformed input).
2. `PointerOverlay.swift` standalone: hardcoded points; verify placement, layering over menus, and
   **click-through**.
3. `ScreenCapture` geometry return + `CapturedImage` pixel dims.
4. `AnthropicClient` dimensions text block; `SystemPrompt` pointing protocol. Ask a "where do I
   click" question and confirm Claude emits a sane `[POINT:x,y:label]`.
5. Wire `ChatViewModel.onPointing` + tag-strip in `.done`; `PointingController` remaps and shows the
   circle. Verify §11 1–8.
6. *(If in scope)* CP3b advance signal (voice and/or hotkey) + re-capture loop. Verify §11.9.
7. Update `SPEC.md` §CP3 to the vision-based design; refresh the decision table.

---

## 13. Future upgrade (explicitly out of scope) — verified clicking

Hey Clicky ships a **dormant** Computer-Use / element-detector path it never calls; the original
`SPEC.md` CP3 envisioned the **Accessibility API** measuring exact rects. Either could later make
pointing **ground-truth accurate** (and even enable actuation), by resolving Claude's chosen target
to a real `AXUIElement` frame instead of trusting the pixel guess. **CP3 deliberately does not build
this** — the vision-only circle is the hackathon-right trade-off. Note it as the known upgrade path
if accuracy ever needs to be exact.

---

## 14. Known gotchas

- **Click-through is non-negotiable.** `ignoresMouseEvents = true` on the overlay, or it eats the
  click it's pointing at. Test by actually clicking the circled button.
- **Coordinate-space mismatch is the #1 accuracy killer (§4).** If Anthropic re-resizes the image,
  the dims you told Claude no longer match what it saw. Cap to Anthropic's limits and report the
  exact dims. **Verify limits via `/claude-api`.**
- **Don't Y-flip twice.** With the recommended full-display SwiftUI overlay, SwiftUI's top-left
  origin already matches the screenshot — place at `(localX, localTopY)` directly. Only the
  AppKit/global-window strategy needs the `displayHeight − y` flip.
- **Strip the tag before display *and* TTS (§8).** Do it once in `.done` so the bubble shows clean
  text and CP4 speaks clean text. Never read coordinates aloud.
- **Voice turns don't capture today.** CP4's voice path calls `submit(text:)` without a screenshot,
  so a spoken question currently has no image to point at. For voice-driven pointing/advance, the
  voice path must capture a screen before submit — a CP3∩CP4 integration item (§9, and the merge
  question below).
- **The overlay must not photobomb re-captures.** It won't — CP2 excludes all our PID's windows —
  but verify after adding the window (especially if it's ever spawned under a different process
  context).
- **No Accessibility permission.** We never read the UI tree or post events, so don't request it
  (and don't accidentally pull in an AX call "for accuracy" — that's the §13 upgrade, not CP3).
- **Keep the prompt tag grammar and the regex in lockstep.** If you change the tag format in
  `SystemPrompt`, change `PointTag` too. Be lenient on parse failure.
- **Multi-monitor (if built):** the `:screenN` tag must map to the same display indexing you label
  the screenshots with, and each display needs its own geometry. Easy to get the index mapping
  subtly wrong — test on two monitors.

---

## 15. Decision quick-reference

| Area | CP3 decision |
|---|---|
| Pointer | A **circle** in a click-through, non-activating overlay (not a cursor/triangle) |
| Coordinate source | **Claude vision only** — `[POINT:x,y:label]` tag (no Accessibility, no OCR) |
| Accuracy hedge | Large forgiving circle + prompt steers to clear, non-edge targets + exact dims note |
| Actuation | **None** — Chingu points + narrates; the human clicks |
| Tag handling | Parse + strip in `ChatViewModel.done`; never displayed or spoken |
| Overlay self-capture | Auto-excluded by CP2's PID window filter |
| Permissions | Reuses CP2 Screen Recording; **no** Accessibility |
| Multi-step (CP3b) | Re-capture on a focus-preserving signal (voice/hotkey); typing to refine |
| New files | `PointerOverlay.swift`, `PointingController.swift`, `PointTag.swift` |
| Seam | Unchanged signatures; additive `onPointing` hook + geometry carry |

---

## 16. Confirmed decisions (locked with the human — 2026-06-27)

The questions in the original draft have been answered. **Build to these; do not re-litigate them.**
One item (#5) is still open pending the human's merge work.

1. **Accessibility API — DROPPED. Pure vision only.** ✅ Confirmed. Claude reports the pixel
   coordinate; the app trusts it. No `AXUIElement`/OCR/Computer-Use in the live path. **Also
   confirmed: rewrite `SPEC.md` §CP3 to the vision-based design** — but that rewrite is a
   *build-time* task (build order §12 step 7), **not yet done** (build is on hold).
2. **Scope — CP3a now, CP3b gated.** ✅ Confirmed. **Build CP3a (single circle) solidly.** CP3b
   (multi-step "what's next") is **specced (§9) but its build is gated** behind #4 / the CP4 merge.
3. **Single display only.** ✅ Confirmed. Capture/point on the **active display** (matches CP2).
   The tag **reserves `:screenN`** for a future multi-monitor pass, but the v1 build is single-display
   — no all-screen capture, no `screenN` routing yet.
4. **CP3b advance signal — voice-or-hotkey.** ✅ Confirmed. Use **voice "what's next" when CP4 is
   present**; otherwise a **dedicated advance hotkey**. Both are focus-preserving. (Reminder: the
   voice path must capture a screen before submitting — see §9 / §14.) Typing stays available only
   for *refining/abandoning* the current step.
5. **Branch base & CP4 interaction — RESOLVED.** ✅ The partner's merges landed: `main` now has
   **CP1 + CP2 + CP4** together (plus a real persona system prompt and prompt caching). CP3 is
   built on a `cp3-pointing` branch off this merged `main`. The `.done` tag-strip runs **before**
   `onAssistantResponseComplete`, so CP4's TTS already receives clean, tag-free text. (Voice-driven
   *advance* — capturing a screen on a voice turn — remains the gated CP3b item, see #4 / §9.)
6. **Circle dismissal & label — persist + auto-fade, with label.** ✅ Confirmed. The circle
   **persists until** the next turn / Chingu dismiss / Esc, **and additionally auto-fades after a
   timeout (~5 s)**. **Show the short text label** beside the circle. No click-detection.

> **Status: CP3a built (2026-06-27).** All code landed on `cp3-pointing` and `swift build` is
> green; the `PointTag` parser is validated (18 checks). `SPEC.md` §CP3 has been rewritten to this
> vision-based design. **Remaining:** manual GUI acceptance tests (§11) on a real screen, and the
> gated **CP3b** advance flow (§9) — not yet built.




