# Parallel Development — CP2 (screenshots) ∥ CP4 (speech)

**Goal:** two people build Checkpoint 2 (screenshots) and Checkpoint 4 (speech) at the
same time, off `main`, with **zero merge conflicts**. This doc is the contract both
developers agree to *before* writing code. It is process/coordination only — no
implementation detail of the features themselves (those live in the per-checkpoint specs
when we write them).

- **Owner of CP2 (screenshots):** _Jayden_ — also finishing CP1 cleanup.
- **Owner of CP4 (speech):** _partner_.

> CP3 (on-screen pointing) is **not** being built in this parallel phase. It depends on
> CP2 (a screenshot to reason over) and the panel focus model, so it comes after CP2
> lands. **Topology: CP2→CP3 are sequential (same owner); only CP4 runs truly parallel.**
> Don't start CP3 here.

---

## 0. AGENT INSTRUCTIONS — read this first if you are a coding agent

If you are an AI coding agent working on this repo, **you are working on exactly one
checkpoint.** Determine which from your branch / task, then obey these hard rules. They exist
so two agents editing in parallel never produce a merge conflict.

**Hard rules (do not violate without the human's explicit say-so):**

1. **Stay in your lane — edit only the files your checkpoint owns** (see the ownership map in
   §2). If a change feels like it needs a file owned by the *other* checkpoint, **stop and
   ask the human** instead of editing it.
2. **The seam is a contract, not a suggestion.** The entry point is
   `ChatViewModel.submit(text:image:)` and the output hook is
   `onAssistantResponseComplete`. **Do not rename, re-sign, or restructure them.** Fill your
   designated slot only (§3).
3. **New capability → new file.** Don't grow shared files. CP2 logic → `ScreenCapture.swift`;
   CP4 logic → `SpeechService.swift` / `MicCapture.swift`.
4. **AppDelegate additions go in a separate `extension AppDelegate { }`** (in your own new
   file), and you add **at most one line** to `applicationDidFinishLaunching`
   (`setupCapture()` for CP2, `setupSpeech()` for CP4). Never refactor the existing
   AppDelegate body.
5. **`swift build` must stay green.** Build before you consider the task done. A broken build
   blocks the other agent.
6. **No new `Package.swift` dependencies.** Both checkpoints use only system frameworks. If
   you think you need a package, stop and ask the human.
7. **Don't touch git** (no commits, branches, pushes) unless the human explicitly tells you
   to. The humans own the branch/merge protocol in §4.
8. **For the Anthropic API shape, consult the `claude-api` skill — never guess from memory.**

**If you are the CP2 agent:** your job is in §7 "CP2" and `docs/CP2-SPEC.md`. You may edit
`ChatViewModel.submit` (image slot only), `AnthropicClient.swift` (add the image content
block), `ChinguPanel`/`main.swift` (read the panel window to exclude it). **Never** touch the
`onAssistantResponseComplete` hook or any speech file.

**If you are the CP4 agent:** your job is in §7 "CP4" and `docs/CP4-SPEC.md`. You call
`submit(text:)` (leave `image` at its default) and set `onAssistantResponseComplete`. You may
add a mic button in `ChatView`. **Never** touch `AnthropicClient.swift` or the image path.

---

## 1. Why this is safe to parallelize

The architecture is already orthogonal — this is by design (see `SPEC.md`):

- **CP4 wraps the pipeline.** Voice is `voice in → text → [existing pipeline] → text →
  voice out`. The transcript becomes prompt text "the exact same input path as a typed
  question, so the CP1–CP3 pipeline is unchanged downstream" (`SPEC.md` §CP4). CP4 adds
  an input source (mic→STT) and an output sink (response→TTS). It does **not** change what
  happens *between* them.
- **CP2 reaches inside the call.** It captures a screenshot at Enter and adds an `image`
  content block to the Claude request. It changes the *content* of one turn, not how turns
  are triggered or rendered.

One wraps, one reaches inside. They overlap only at a couple of **seams** in shared files.
Carve those seams once, up front, and you never edit the same lines again.

---

## 2. File ownership map

| File | CP2 (screenshots) | CP4 (speech) | Conflict risk |
|---|---|---|---|
| **New:** `ScreenCapture.swift` | ✅ owns | — | none (new file) |
| **New:** `SpeechService.swift` (ElevenLabs STT+TTS) | — | ✅ owns | none (new file) |
| **New:** `MicCapture.swift` (AVFoundation mic) | — | ✅ owns | none (new file) |
| `AnthropicClient.swift` | ✅ edits (image block) | — does not touch | low (CP2 only) |
| `ChatViewModel.swift` | edits (attach image) | **no edit** — drives the public seams from `VoiceController` | 🟢 low (CP2-only) → seam |
| `main.swift` (AppDelegate) | edits (capture wiring) | **no edit** (optional `setupSpeech()` one-liner) | 🟢 low (CP2-only) |
| `ChatView.swift` | minor (capture indicator) | edits (mic button, listening/TTS state) — CP4's only shared-file edit | 🟡 medium |
| `Package.swift` | no edit | one **linker flag** to embed `Info.plist` (mic usage string) — not a dependency | 🟢 low (CP4-only) |
| `ChinguPanel.swift` | reads `panel.windowNumber` to exclude from capture; no edit expected | — | low |
| `Secrets.swift` | — | reads `.elevenLabs` (key already loaded); optional one-line `isRequiredNow` flip | low |
| `SystemPrompt.swift` | maybe (vision phrasing) | — | low |
| `GlobalHotKey.swift` | — | maybe (reuse for voice-advance) — read, don't rewrite | low |

**Red zones, now neutralized:** `ChatViewModel` and `main.swift`'s `AppDelegate`. Section 3 carved
the seam; the CP4 finalize pass then moved CP4's two seam lines into a new `VoiceController` and
made its AppDelegate wiring optional — so **CP4 no longer edits either file**, and CP2 edits them
alone. (See `CP4-SPEC.md` §6.3/§6.5.)

---

## 3. The seam — do this FIRST, then branch

This is the highest-leverage step. Both developers want to edit the **body of
`ChatViewModel.send()`** and the **AppDelegate**. If we reshape those once, on `main`,
*before* splitting, each person fills a pre-carved slot instead of fighting over one block.

**One person lands this small refactor on `main` and pushes it. Then both branch from it.**

### 3a. `ChatViewModel` — carve two slots

Today: `func send()` reads `input`, appends bubbles, streams the reply. `ChatView` calls
`model.send` from `.onSubmit` (Enter) and the Send button — both **no-arg**.

Reshape to expose **one input seam** (CP2 fills) and **one output seam** (CP4 fills). The
locked names are below — **do not rename them; this is the contract:**

- **Input seam — `submit(text:image:)` (CP2 fills the image):**
  `func submit(text: String, image: CapturedImage? = nil)` — the public entry. The internal
  call passes `image` down to the client. **CP4 calls `submit(text: transcript)`** and leaves
  `image` at its default. **CP2 fills `image`** at capture time. Same call, different
  arguments — no shared lines.
  - We lock the **image-carrying superset** on purpose: if we shipped a bare `submit(text:)`,
    CP2 would have to re-sign it later — re-opening the exact seam this whole doc exists to
    keep closed. Lock it once, with the image slot already there.
  - Keep the existing **no-arg `send()`** as a thin wrapper that reads/trims `input` (today's
    logic) and calls `submit(text: trimmed)`. So `ChatView` needs **zero edits** — `.onSubmit`
    and the Send button still call `model.send`.
- **Output seam — `onAssistantResponseComplete` (CP4 fills the hook):** a closure property
  `var onAssistantResponseComplete: ((String) -> Void)?` (default nil). The VM invokes it in
  the `.done` branch with the final assistant text. **CP4 sets it to drive TTS. CP2 never
  touches it.**

`CapturedImage` is a small placeholder type the seam commit introduces (e.g. an empty
`struct CapturedImage {}` or `typealias CapturedImage = Data`); **CP2 fleshes it out** with
the base64 + media-type the Claude `image` block needs.

Net effect: in `submit(...)`, CP2 only ever edits the *image-attach* lines; CP4 only ever
sets the *hook*. Different, non-adjacent regions.

> Don't over-build the seam. An optional parameter + a single optional closure is enough.
> Resist adding a routing/state machine now — that's feature work, not the seam.

### 3b. `AnthropicClient` — CP2-only, but declare it now

CP2 adds an `image` content block to the request body. CP4 does **not** touch this file.
Because only one side edits it, it won't conflict — but **state it in the contract** so the
CP4 dev knows not to wander in. (If CP4 ever feels the urge to add an ElevenLabs *network*
call here — don't. Speech I/O lives in `SpeechService.swift`, separate from the Anthropic
actor.)

### 3c. `main.swift` AppDelegate — split into separate extensions

Both add to the AppDelegate, for different reasons (CP2: capture wiring; CP4: mic
permission, maybe a voice-advance hotkey). Avoid editing the same method:

- Put **CP2's** additions in `extension AppDelegate { /* capture */ }`.
- Put **CP4's** additions in `extension AppDelegate { /* speech */ }`.
- Swift allows extensions in **separate files** — so CP2's capture extension can live in
  `ScreenCapture.swift` and CP4's in a speech file. Git then treats them as independent
  regions: clean merge even though both "touch the AppDelegate."
- The **one method both may need to touch** is `applicationDidFinishLaunching` (to wire a
  service in). Minimize this: each side adds **one line** (`setupCapture()` /
  `setupSpeech()`) calling into its own extension. One-line additions in the same method
  still merge cleanly far more often than competing multi-line edits — and if they do
  collide, it's a trivial resolution.

---

## 4. Branch & merge protocol

```
main ──●  (seam refactor from §3, pushed first)
       ├── feat/cp2-screenshots   (Jayden)
       └── feat/cp4-speech        (partner)
```

1. **Seam first.** One person lands §3 on `main`, pushes. Both confirm they've pulled it
   before branching. *Nobody branches before the seam is on `main`.*
2. **Branch per checkpoint.** `feat/cp2-screenshots`, `feat/cp4-speech`.
3. **Rebase on `main` often** — at minimum whenever the *other* person pushes anything to
   `main`, and at the start of each work session. Small, frequent rebases beat one big
   merge at the end. `git fetch && git rebase origin/main`.
4. **Merge order: CP2 first, then CP4 rebases onto it.** CP2 is the more invasive change to
   the shared pipeline (it edits `AnthropicClient` and the request shape). Land it, let it
   settle, then CP4 rebases onto a stable pipeline rather than a moving one.
5. **Keep it green.** `swift build` must pass before every push. A broken `main` blocks the
   other person — costly under a time crunch.
6. **CP1 cleanup goes to `main` directly** (or a tiny `fix/cp1-*` branch merged fast),
   *before or alongside* the seam — not tangled into the CP2 feature branch.

---

## 5. Shared resources — coordinate, don't collide

- **`.env` / `.env.example`:** CP4 finally *consumes* `ELEVENLABS_API_KEY` (already loaded
  by `scripts/run.sh` and reported at launch — see `Secrets.swift`). The plumbing exists;
  CP4 just reads `Secrets.value(.elevenLabs)`. If CP4 makes the key required, flip
  `isRequiredNow` for `.elevenLabs` — a one-line edit, CP4-owned. No `.env.example` change
  needed (the placeholder line is already there).
- **`Package.swift`:** both checkpoints use only **system frameworks** —
  ScreenCaptureKit (CP2), AVFoundation (CP4), plus `URLSession` for ElevenLabs HTTP. **No
  new SwiftPM dependencies expected.** If either side thinks they need a package, raise it
  with the other first — `Package.swift` edits conflict easily and a dependency is rarely
  worth it for the hackathon. **One known exception:** CP4 adds a single **linker flag** to embed
  `Info.plist`'s mic usage description (CP4-SPEC §4) — not a dependency. CP2 doesn't touch
  `Package.swift`, so it's low-conflict, but coordinate before landing it.
- **TCC permissions (different prompts, no overlap):** CP2 triggers **Screen Recording**;
  CP4 triggers **Microphone** (and Speech Recognition is *not* needed — ElevenLabs does STT
  server-side). Independent prompts; no shared code. **Note:** CP4's mic prompt additionally
  requires an embedded `NSMicrophoneUsageDescription` or a bare `swift run` binary **crashes** on
  the first request (CP4-SPEC §4); CP2's screen-recording prompt needs no usage-string key.
- **Panel exclusion (CP2 ↔ `ChinguPanel`):** CP2 must exclude Chingu's own window from the
  screenshot (`SCContentFilter` `excludingWindows:`). It needs the panel's
  `windowNumber`/`NSWindow` reference, which the AppDelegate already owns (`panel`). Read it;
  don't restructure the panel. This is the only CP2↔panel touchpoint.

---

## 6. Pre-flight checklist (both devs sign off before coding)

- [ ] Seam refactor (§3) is on `origin/main` and both have pulled it.
- [ ] CP1 display bugs decision is settled and not entangled in either feature branch.
- [ ] Each dev has created their branch off the post-seam `main`.
- [ ] Agreed: new logic → **new files**; AppDelegate additions → **separate extensions**.
- [ ] Agreed: merge order CP2 → CP4; rebase on every cross-push.
- [ ] Agreed: no new `Package.swift` dependencies without a heads-up.
- [ ] `swift build` green on both branches before any push.

---

## 7. One-line summary for each dev

- **CP2 (Jayden):** new `ScreenCapture.swift`; flesh out `CapturedImage` and fill the `image`
  parameter in `submit(text:image:)`; add the `image` content block in `AnthropicClient`;
  exclude the panel from the capture. Don't touch the TTS hook or any speech file.
- **CP4 (partner):** new `SpeechService.swift` + `MicCapture.swift` + `VoiceController.swift`;
  the `VoiceController` drives the **public** seams (`model.submit(text:)` in, set
  `model.onAssistantResponseComplete` out) so **`ChatViewModel` is not edited at all**; add a mic
  button in `ChatView` (CP4's only shared-file edit); embed `Info.plist`'s
  `NSMicrophoneUsageDescription` via a `Package.swift` linker flag (**ask the human first** — mic
  access crashes a bare `swift run` binary without it; CP4-SPEC §4). Don't touch `AnthropicClient`,
  the `image` path, or `ChatViewModel`. **~80% of CP4 (STT/TTS/endpointing) is validated via a
  temporary in-app trigger with zero pipeline dependency — wire the seams only at the end; it
  carries no merge risk.**
