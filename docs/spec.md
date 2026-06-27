# Chingu — Technical Spec (Resolved Open Questions)

This document resolves the open technical questions raised in the [README](../README.md).
It is the source of truth for *decisions*; end-to-end architecture is designed separately
(after these are approved).

**Platform decision:** Swift, using **SwiftUI for all visual UI** and **AppKit for window /
panel / hotkey / system behavior**. The chat UI renders in SwiftUI via `NSHostingView`,
hosted inside a non-activating AppKit `NSPanel`. This split is the standard, simplest path —
not over-engineering.

**LLM provider:** OpenAI (GPT-4o, multimodal) via the Responses API.

---

## Q1 — Capture the screenshot *without* the Chingu overlay in it

**Decision:** Use **ScreenCaptureKit** (`SCScreenshotManager` / `SCStream`). Build an
`SCContentFilter` that captures the full display but passes Chingu's window into
`excludingWindows:`. The composited capture excludes our overlay, so we get a clean image of
what's *behind* it — without moving or hiding the panel.

- The panel is a **non-activating `NSPanel`**, so the app behind it stays active and unchanged
  at the moment of capture.
- One-time cost: Screen Recording permission (TCC) prompt. Standard and expected.

**No workaround needed — this is a first-class native capability.**

---

## Q2 — Do we need separate OCR/VLM analysis before the LLM?

**Decision: No.** GPT-4o is multimodal — send `screenshot + question` in a single call and it
reasons over the pixels directly. A separate OCR/VLM pre-pass to produce a "screenshot summary"
adds latency, cost, and a second failure point for zero accuracy gain on Q&A.

**Exception:** CP3 coordinate-finding is a *different* task (see Q4) and gets help from the
Accessibility API — but that is **not** a generic OCR pre-pass.

**Verdict: single multimodal call for CP2.**

---

## Q3 — The CP3b "click closes the menu" focus-stealing problem

**The trap:** To type "what's next," the user clicks Chingu's text field → focus leaves the
target app → the overflow menu they just opened **closes** → the circle now points at nothing.

**Root cause:** Clicking the input *activates* Chingu and *deactivates* the target app.

**Decision — never take focus, and never require the user to touch Chingu's text field to
advance.** Three layers, used together:

1. **Non-activating `NSPanel`** (`.nonactivatingPanel` style mask, `becomesKeyOnlyIfNeeded`).
   The overlay shows text and circles without ever becoming the key window — the menu behind it
   stays open.
2. **Advance via global hotkey, not a click.** The user opens the menu, then presses a hotkey
   (the Chingu hotkey or a dedicated "next step" key). On that press, Chingu re-captures the
   screen, sees the new menu state, and draws the next circle. No click into Chingu → focus
   never leaves the target app. **The hotkey press *is* the "I clicked, what's next" signal.**
3. **Voice "what's next" (CP4 pulled forward).** Speaking advances the step with zero focus
   change — the cleanest version. This is why CP3b and CP4 are natural partners.

**Verdict: non-activating panel + hotkey-to-advance (+ voice later). No continuous
frame-by-frame screen-watching.**

---

## Q4 — CP3 coordinate accuracy (finding *where* the button is)

**The risk:** VLMs (including GPT-4o) are **unreliable at exact pixel coordinates** — often off
by 50–150 px, which is fatal for a circle overlay. This is the biggest *reliability* risk in the
project.

**Decision — split "which" from "where":**

- **VLM picks the target (reasoning):** GPT-4o decides *which* control the user needs (e.g.
  "they want Effects → Video Transitions → Cross Dissolve").
- **Accessibility API locates it (measurement):** Use the macOS **Accessibility API**
  (`AXUIElement`) to query the focused app's UI tree and read the **exact frame** of named
  buttons/menu items — real coordinates straight from the OS, not a guess. For the demo app
  (Premiere), map the named control → its `AXUIElement` → its precise rect → draw the circle
  dead-on. This is the README's "button-map navigation for demo" hedge, made concrete.
- **Fallback** when AX can't resolve a control: use VLM coordinates with a deliberately **large**
  circle that tolerates the error, plus a text label.

**Verdict: VLM picks the target, Accessibility API supplies the coordinates. Never trust VLM
pixels for the overlay.**

---

## Q5 — Web search (CP1 requirement)

**Decision:** Use the **OpenAI Responses API with the built-in `web_search` tool**. The model
decides when to search, runs it server-side, and returns a cited answer — least code, fastest to
ship. This also makes the CP2 YES/NO routing cleaner: the same call can decide to search *or*
lean on the screenshot.

(Alternative — function-calling to our own search backend — is more control but more plumbing;
not worth it for the hackathon.)

**Verdict: OpenAI Responses API + built-in web_search tool.**

---

## Q6 — How is the YES/NO screenshot routing decided?

**Key fact:** The screenshot is already captured at Enter (cheap, instant). The decision is only
whether to *send* it.

**Decision — Option A: always attach the screenshot; let the model use or ignore it.**

- One round-trip, simplest. The model naturally ignores the image for questions like
  "what's 49 × 52 + 10."
- Slightly more vision tokens per call, but negligible at demo scale, and **faster end-to-end**
  than a two-call router.
- (Option B — a text-only router call first, then a second call with/without the image — saves
  vision tokens on NO questions but adds a round-trip of latency. Revisit only if cost matters.)

**Verdict: capture-at-Enter always; attach the screenshot on every call. Snappier demo.**

---

## Summary of decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Screenshot without overlay | ScreenCaptureKit `excludingWindows:` |
| 2 | Separate OCR/VLM pre-pass? | No — single multimodal call |
| 3 | CP3b focus-stealing | Non-activating panel + hotkey/voice to advance |
| 4 | CP3 coordinate accuracy | VLM picks target, Accessibility API locates it |
| 5 | Web search | OpenAI Responses API built-in `web_search` |
| 6 | YES/NO routing | Always attach screenshot (Option A) |

**Next step:** end-to-end architecture + tech stack, designed so each checkpoint slots in
without re-planning.
