# Chingu — Product Spec

This is the specification for Chingu. It expands on the [README](../README.md) with the
product idea, the problem/solution, and a detailed treatment of each checkpoint — with the
technical decisions for each capability folded into the checkpoint that introduces it.

**Platform:** Swift — **SwiftUI for all visual UI**, **AppKit for window / panel / hotkey /
system behavior**. The chat UI renders in SwiftUI via `NSHostingView`, hosted inside a
non-activating AppKit `NSPanel`. This split is the standard, simplest path.

**AI provider:** **Claude** (`claude-opus-4-8` — multimodal: brain, vision, and web search)
via the Anthropic Messages API.

**Speech provider:** **ElevenLabs** for speech-to-text (STT) and text-to-speech (TTS), used in
CP4.

**Division of labor:** Claude is the brain (reasoning, vision, web search); ElevenLabs is the
voice (STT + TTS); Swift owns the mic, UI, and overlay.

**API keys:** In development, read keys from environment variables
(`ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]`, and `ELEVENLABS_API_KEY` for CP4).
For the local demo, keys live in a gitignored `.env` that `scripts/run.sh` loads before
`swift run` (so the app reads them via `ProcessInfo`); `.env.example` documents the format. When
shipping, move to the macOS Keychain. Never hard-code, print, or commit a key — secrets and build
artifacts are covered by `.gitignore`. (Note: any key bundled in a distributed Mac app is
extractable; a proxy server is the only real fix, but that's out of scope for the hackathon.)

---

## The Idea

Chingu is an AI companion that lives on your MacBook (Mac-native). It pops up as a chat overlay
that answers your questions. The main user-facing product is a floating, top-center overlay that
appears at the top of your screen, just below the notch, at the press of a hotkey.

There is **one chat thread** — no "new chat," no context-refresh, one session. Quitting the app
erases the session and resets context. The UI is fixed in height and width; the chat history
scrolls.

## Problem & Solution

As students, we use LLMs constantly. We waste time switching between tabs, taking screenshots,
explaining the situation in text, and feeding context to the LLM.

Chingu cuts out this "middleman effort" by seeing what you see. It watches your screen, and when
you have a question, you just ask — no screenshots, no context-prompting. Ask, and get your
answer.

Chingu also has a **pointer interface** for instructional questions, guiding you exactly where
to click. (For the demo, this is limited to button-map navigation.)

## Hackathon Strategy: Checkpoints

To hedge against not finishing, we develop in **checkpoints**. If a checkpoint isn't completed,
we film the demo using the last working checkpoint as a fallback. Each checkpoint is
independently demoable, and each later checkpoint builds strictly on the previous one.

---

## Checkpoint 1 — Groundwork + working UI on Mac *(most important)*

The foundation: the overlay, the hotkey, and a working chat thread. No screenshots yet.

### Behavior

- Press a **global hotkey** to activate Chingu; the notch overlay appears with a text input and
  an Enter-to-send action.
- The text box shows placeholder guidance (e.g. *"Write your question/prompt here"*) that
  disappears when the user starts typing.
- The user sends questions and follow-ups and receives LLM responses in a chat thread.
- **One chat thread only** — no "new chat" or "clear context." A single back-and-forth thread,
  scrollable, fixed size.
- No real Chingu-specific prompt layer yet — only a **placeholder** system prompt is wired in
  (plumbing for the future persona/behavior layer); CP1 is otherwise plain LLM chat in the notch.
- **Must support web search.**

### How it works

- **The overlay is a non-activating `NSPanel`** (`.nonactivatingPanel` style mask,
  `becomesKeyOnlyIfNeeded`). This is the single most important architectural choice in the whole
  app: the panel can show UI and accept input *without becoming the key window and without
  deactivating the app behind it*. Everything in CP2–CP4 (clean screenshots, keeping menus open
  while pointing) depends on this. We get it right in CP1.
- **The chat UI is SwiftUI**, hosted in the panel via `NSHostingView`. The panel is positioned
  top-center, just below the notch, at a high window level so it floats above other apps.
- **The hotkey is a global hotkey** registered through AppKit/Carbon (`RegisterEventHotKey`, or a
  small wrapper like the `HotKey` package).
- **LLM + web search:** Claude (`claude-opus-4-8`) via the **Anthropic Messages API with the
  server-side `web_search` tool** (`web_search_20260209`). We declare the tool; Claude decides
  when to search, runs it on Anthropic's infrastructure, and returns a cited answer — no
  client-side search loop, least code, fastest to ship. (We deliberately avoid wiring our own
  search backend; not worth the plumbing for the hackathon.) Setting this up in CP1 also makes
  CP2's routing trivial, since the same call can decide to search.

---

## Checkpoint 2 — Rudimentary screenshot feature

CP1, plus a screenshot captured the moment the user presses Enter.

### Behavior

- The user can ask contextual questions such as *"What does this mean in English?"* or
  *"Summarize what's going on on my screen."*
- Chingu answers in the popup; the user can ask follow-ups.
- Chingu does **not** give on-screen point-outs yet (that's CP3).
- Chingu decides, **per question, whether it needs to see the screenshot** to answer.

### The capture contract

We tell the user explicitly: **the screen Chingu sees is the screen at the moment you press
Enter.** This removes all ambiguity about *what* Chingu is looking at. At capture time, Chingu
only saves the screenshot — it runs no analysis (no LLM/VLM/OCR) yet.

### How it works

- **Capture without the overlay in the shot:** Use **ScreenCaptureKit** (`SCScreenshotManager` /
  `SCStream`). Build an `SCContentFilter` that captures the full display but passes Chingu's
  window into `excludingWindows:`. The composited image excludes our overlay, so we get a clean
  picture of what's *behind* it — without moving or hiding the panel. Because the panel is
  non-activating (from CP1), the app behind it stays active and unchanged at capture time. One
  one-time cost: the Screen Recording (TCC) permission prompt — standard and expected.
- **No separate OCR/VLM pre-pass.** Claude is multimodal — we send `screenshot + question` in a
  single call (the image as an `image` content block) and it reasons over the pixels directly. A
  separate OCR/VLM step to produce a "screenshot summary" adds latency, cost, and a second
  failure point for zero accuracy gain on Q&A. One multimodal call does it.
- **YES/NO routing — always attach the screenshot.** The screenshot is already captured at Enter
  (cheap, instant); the only decision is whether to *send* it. We **always attach it** and let
  the model use or ignore it. The model naturally ignores the image for questions like
  "what's 49 × 52 + 10," and this keeps us at one round-trip per question — snappier than a
  two-call text-router approach. (A text-only router call first would save vision tokens on NO
  questions but adds a round-trip of latency; revisit only if cost ever matters.)

  - **Route "NO"** — *e.g. "What time is it in Boston?"* — treated as a plain query (with web
    search if needed); response in the notch.
  - **Route "YES"** — *e.g. "How do I add a fading transition?"* — question + screenshot to the
    model; answer in the notch.

---

## Checkpoint 3 — On-screen pointing

### Checkpoint 3a — single-step pointing

Chingu gives specific instructions and shows the user exactly where to click (pointer, circle).
Useful for *"How do I bold this text?"* or *"How do I insert a transition?"*

- It guides the user to click only the **first** control (one circle, the immediate next click).
- For a multi-step path, the user clicks, then asks *"what's next"* — Chingu re-captures and
  points at the next control (CP3b). It does not draw multiple circles at once.

#### How it works — pure vision (Hey-Clicky-style)

**Claude eyeballs the screenshot and reports the pixel coordinate by eye; the app trusts it and
draws a circle there.** There is **no Accessibility API, no OCR, no UI-element lookup** in the
live path — accuracy is entirely the vision model's spatial accuracy. The flow:

- **Tell Claude the exact pixel space.** The screenshot already captured on Enter (CP2) is sent
  with a short note of its exact pixel dimensions. Because `claude-opus-4-8` is on Anthropic's
  high-resolution vision tier (≤ 2576 px long edge), our 1568-px-capped image is **not**
  re-downscaled server-side, so the coordinates Claude reports are in the space we announce.
- **Claude points in a tag.** The system prompt teaches Claude to append, at the very end of its
  reply, exactly one tag: `[POINT:x,y:label]` (integer pixels, origin top-left; `label` is a 1–3
  word control name) — or `[POINT:none]` when pointing wouldn't help. The spoken sentence names
  the control ("the Bold button"); it never says the numbers.
- **The app parses, strips, remaps, and draws.** When the turn completes, the app splits the tag
  off the text (so neither the bubble nor TTS ever shows or speaks a coordinate), scales the
  pixel coordinate to a screen point using the captured display's geometry, and draws a circle
  there. The app does **no** verification that a control is actually there — it trusts the number.
- **Accuracy hedge.** Because the model can be off by tens of pixels, the circle is **large and
  forgiving** (it points "around here," not at one pixel), and the prompt steers Claude toward
  clearly identifiable, non-edge targets.

The circle is a **separate, click-through, non-activating overlay** (it sets `ignoresMouseEvents`),
so it floats over the target app's menus, never steals focus, and never blocks the very click it's
pointing at — the user clicks the real control underneath it.

> **Why not the Accessibility API?** An earlier design split "which" (Claude) from "where" (the
> macOS `AXUIElement` tree, for ground-truth rects). We deliberately dropped it: pure vision is
> zero-infrastructure and good enough with a forgiving circle. A ground-truth element lookup
> (AX or Computer-Use) remains the known upgrade path if pixel-exact pointing is ever needed —
> see `CP3-SPEC.md` §13.

### Checkpoint 3b — multi-step pointing

The multi-step version of 3a. To guide through an overflow menu with a sequence of clicks:

1. Place a circle over the first button; instruct the user to ask "what's next" after clicking
   it.
2. The user clicks the button (which opens more buttons), signals "what's next," and the loop
   runs again with a fresh capture and the next circle.

#### The focus-stealing trap and its solution

Naively, to ask "what's next" the user would click Chingu's text field — which would
**activate Chingu, deactivate the target app, and close the overflow menu they just opened**,
putting them back at square zero. We also can't have the LLM watch the screen frame-by-frame to
detect the click; the click completion must be **explicitly signaled**.

Solution — **never take focus to advance:**

- The **non-activating panel** (from CP1) means the circle and step text are shown *without ever
  becoming the key window* — the menu behind it stays open.
- **Advance via a focus-preserving signal, not a click into Chingu.** After clicking the
  highlighted control, the user signals "what's next" by **voice** (when CP4 is present — the
  cleanest, zero-focus-change path) or a **dedicated advance hotkey**. On that signal Chingu
  re-captures the screen, sees the new menu state, and draws the next circle. No click into
  Chingu → focus never leaves the target app. **The signal *is* the "I clicked, what's next."**
- **Typing is still available** when the user wants to *refine or change* the question
  (e.g. "no, I meant the audio transition"). Typing steals focus and closes the menu — but that's
  acceptable, because at that point the user is abandoning the current step anyway, and Chingu
  re-captures fresh on the next Enter.

The rule: **a focus-preserving signal (voice or hotkey) to advance without disrupting; typing
available when you're done with the current menu.** Voice (CP4) makes the advance seamless; absent
voice, CP3b ships on the advance hotkey + text input.

---

## Checkpoint 4 — Speech integration

Speech makes conversation fluid and removes the need to move the mouse and type — especially
useful while following on-screen instructions, and the cleanest way to advance steps in CP3b.

### Behavior

- Chingu automatically detects when the user has finished asking a question, and when they're
  asking a follow-up, via speech.
- *(Optional)* Voice activation — *"야 친구!"* ("Hey Chingu!"), like "Hey Siri."
- There's still a button to end the conversation.
- Chingu has **text-to-speech** to deliver its responses as speech.

### How it works

- **Speech-to-text:** **ElevenLabs STT** transcribes the user's spoken question. Swift owns the
  microphone capture (AVFoundation) and streams audio to ElevenLabs; the transcript becomes the
  prompt text fed to Claude — the exact same input path as a typed question, so the CP1–CP3
  pipeline is unchanged downstream.
- **Text-to-speech:** **ElevenLabs TTS** turns Claude's text response into spoken audio, which
  Swift plays back. The chat thread still shows the text; speech is layered on top.
- **End-of-question / follow-up detection:** silence/endpointing on the captured audio decides
  when the user has finished speaking and when a follow-up begins. Voice activation
  (*"야 친구!"*) is a wake-word trigger on the same mic stream — optional and last.
- **Boundary:** ElevenLabs only does voice (audio ↔ text). All reasoning, vision, and web search
  stay with Claude. Voice in → text → Claude → text → voice out.

### Relationship to CP3b

Speaking "what's next" advances a step with **zero focus change at all** — no hotkey, no typing,
no risk of disturbing the open menu. This is the cleanest version of the CP3b advance mechanism,
which is why CP3b and CP4 are natural partners. CP3b works without it (hotkey + text); CP4 makes
it seamless.

---

## Parallel development (CP2 ∥ CP4)

CP2 (screenshots) and CP4 (speech) are built **in parallel by two developers** off `main`.
This is safe because the checkpoints are architecturally orthogonal: **CP4 wraps the
pipeline** (`voice in → text → [pipeline] → text → voice out` — the transcript enters via the
same path as a typed question, see CP4 above), while **CP2 reaches inside the call** (it adds
a screenshot to one Claude turn). One wraps, one reaches inside; they meet only at two seams.

To keep those seams conflict-free, the chat entry point and response output are locked as a
**contract on `main` before either developer branches:**

- **Input seam:** `ChatViewModel.submit(text:image:)` — the single entry for every question.
  Typed and transcribed questions both call `submit(text:)`; CP2 fills the optional `image`.
  (The image-carrying superset is locked deliberately so CP2 never has to re-sign it.)
- **Output seam:** `ChatViewModel.onAssistantResponseComplete` — a hook fired with the final
  assistant text when a turn completes; CP4 sets it to drive TTS.

**Topology:** CP2→CP3 are sequential (CP3 needs CP2's screenshot pipeline; same owner); only
CP4 runs truly parallel. **Merge order:** CP2 first (it touches the request shape), then CP4
rebases onto it. New capabilities live in **new files** (`ScreenCapture.swift` for CP2;
`SpeechService.swift` / `MicCapture.swift` for CP4); AppDelegate additions go in **separate
`extension AppDelegate` blocks**.

Full coordination rules, the file-ownership map, and agent instructions live in
[`PARALLEL-CP2-CP4.md`](PARALLEL-CP2-CP4.md). The per-checkpoint build specs are
[`CP2-SPEC.md`](CP2-SPEC.md) and [`CP4-SPEC.md`](CP4-SPEC.md).

---

## End-to-end example (Adobe Premiere Pro)

You're in Premiere and ask Chingu: *"How do I add a fading transition between scene 1 and scene
2?"*

1. Chingu captures a screenshot the moment you press Enter (ScreenCaptureKit, excluding the
   overlay), along with its exact pixel dimensions. It only saves the image — no analysis yet.
2. Chingu sends question + screenshot (+ a note of its pixel size) to Claude, which uses the
   screen to answer.
3. The model answers in plain speech and decides the answer needs a **circle**.
4. The model reports the target's pixel coordinate in a `[POINT:x,y:label]` tag; Chingu strips
   the tag from the spoken text, remaps the pixel to a screen point, and draws a circle there in
   the click-through overlay (the user clicks the real control under it).
5. For a multi-step path, the user clicks, then says "what's next" (CP4) or presses the advance
   hotkey, and Chingu re-captures and points to the next control.

---

## Decision quick-reference

| Area | Decision | Introduced in |
|------|----------|---------------|
| Overlay window | Non-activating `NSPanel` (SwiftUI inside via `NSHostingView`) | CP1 |
| Hotkey | Global hotkey (AppKit/Carbon) | CP1 |
| LLM + web search | Claude (`claude-opus-4-8`) Messages API + `web_search_20260209` tool | CP1 |
| Screenshot capture | ScreenCaptureKit with `excludingWindows:` | CP2 |
| OCR/VLM pre-pass | None — single multimodal Claude call | CP2 |
| YES/NO routing | Always attach screenshot; Claude uses or ignores | CP2 |
| On-screen pointing | Pure vision — Claude reports pixel coords in a `[POINT:x,y:label]` tag; app trusts + remaps to a click-through circle (no Accessibility API) | CP3a |
| Pointer accuracy hedge | Large forgiving circle + exact-dims note + prompt steers to clear, non-edge targets | CP3a |
| Multi-step advance | Focus-preserving signal (voice "what's next" w/ CP4, else advance hotkey); typing to refine | CP3b |
| Speech | ElevenLabs STT (end-of-question) + ElevenLabs TTS responses; voice advance | CP4 |
| Parallel-dev seam | Locked contract: `submit(text:image:)` input + `onAssistantResponseComplete` output; CP2∥CP4 off `main`, merge CP2→CP4 (see `PARALLEL-CP2-CP4.md`) | CP2/CP4 |
