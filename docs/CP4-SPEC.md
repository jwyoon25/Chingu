# Chingu — Checkpoint 4 Implementation Spec

Detailed build spec for **Checkpoint 4 only** — speech integration (ElevenLabs STT + TTS).
Expands the CP4 section of [`SPEC.md`](SPEC.md). Read [`SPEC.md`](SPEC.md),
[`CP1-SPEC.md`](CP1-SPEC.md), and the parallel-dev contract
[`PARALLEL-CP2-CP4.md`](PARALLEL-CP2-CP4.md) first.

> **Parallel-dev note.** CP4 is built on `cp4-speech`, in parallel with CP2 (screenshots) on
> `cp2-screenshot`. CP4 **wraps** the existing pipeline — voice in → text → [pipeline] →
> text → voice out — and never edits what happens *inside* a turn. Stay in CP4's file lane
> (see `PARALLEL-CP2-CP4.md` §2). The seam contract must already be on `main` before you branch.

---

## 0. Scope — what CP4 is and is NOT

**CP4 IS (CP1, plus):**
- **Speech-to-text:** the user speaks; ElevenLabs transcribes; the transcript becomes the
  prompt — **the exact same input path as a typed question.**
- **Text-to-speech:** Claude's text reply is spoken aloud via ElevenLabs; the chat text still shows.
- End-of-question detection (silence/endpointing) so Chingu knows when the user finished.
- A button to start/stop the conversation.

**CP4 is NOT (do not build unless explicitly asked):**
- No change to vision, web search, or the screenshot pipeline (those are CP2's lane — don't touch).
- No on-screen pointing (CP3).
- Voice activation ("야 친구!" wake word) is **optional and last** — ship STT+TTS first.
- No new reasoning path — ElevenLabs does voice only; **all** reasoning/vision/search stays Claude.

---

## 1. The boundary (keep it clean)

**ElevenLabs only does voice (audio ↔ text). Claude does everything else.** Swift owns the
mic (AVFoundation) and audio playback. The data flow:

```
mic audio ──▶ ElevenLabs STT ──▶ transcript text ──▶ submit(text:) ──▶ [unchanged pipeline]
                                                                              │
                          spoken audio ◀── ElevenLabs TTS ◀── final reply text ◀┘
```

The two arrows that touch Chingu's code are the **two seams** the contract already reserved:
- **In:** call `ChatViewModel.submit(text: transcript)` — same call a typed question uses.
- **Out:** set `ChatViewModel.onAssistantResponseComplete = { text in speak(text) }`.

Everything between is untouched. **You never edit `AnthropicClient` or the `image` path.**

---

## 2. Tech stack (CP4 additions)

| Concern | Choice |
|---|---|
| Mic capture | **AVFoundation** (`AVAudioEngine` / `AVAudioRecorder`) |
| STT | **ElevenLabs Speech-to-Text** over `URLSession` (no SDK; raw HTTPS) |
| TTS | **ElevenLabs Text-to-Speech** over `URLSession`; play with `AVAudioPlayer` |
| Endpointing | silence detection on the captured audio (RMS threshold + timeout) |
| Key | `ELEVENLABS_API_KEY` — **already loaded** by `Secrets`/`scripts/run.sh` (CP1 readiness) |
| Permission | **Microphone (TCC)** — one-time system prompt |

No new SwiftPM dependencies — AVFoundation and `URLSession` are system frameworks. The
ElevenLabs key plumbing already exists: `Secrets.value(.elevenLabs)` returns it (see
`Secrets.swift`); `scripts/run.sh` already exports it and launch already logs its presence.

> ElevenLabs is **not** an Anthropic API — the `/claude-api` skill does **not** cover it. Use
> the current ElevenLabs API docs for the STT/TTS endpoint shapes; don't guess from memory.
> (Claude's request shape is untouched by CP4, so there's nothing Anthropic-side to change.)

---

## 3. File layout (CP4)

New logic goes in **new files** so it can't merge-conflict with CP2:

```
Sources/Chingu/
  SpeechService.swift   — NEW. ElevenLabs STT + TTS over URLSession. Pure voice↔text;
                          knows nothing about Claude. Owns the extension AppDelegate {
                          setupSpeech/mic-permission } block.
  MicCapture.swift      — NEW. AVFoundation mic capture + silence/endpoint detection;
                          hands finished audio to SpeechService for STT.
  ChatView.swift        — EDIT. Add a mic button + listening/speaking state (UI only).
  ChatViewModel.swift   — EDIT. Set onAssistantResponseComplete (the reserved hook);
                          feed transcripts via submit(text:). NOTHING else.
```

**Files you may touch (CP4 lane):** `SpeechService.swift` (new), `MicCapture.swift` (new),
`ChatView.swift` (mic UI), `ChatViewModel.swift` (the hook + transcript-in only), a separate
`extension AppDelegate` for mic permission/voice-hotkey, and possibly `Secrets.swift`
(flip `.elevenLabs` `isRequiredNow` if you want it required). **Never touch:**
`AnthropicClient.swift`, the `image` path, or `CapturedImage` (CP2's lane).

---

## 4. The de-risking move — build ~80% as a standalone harness FIRST

Most of CP4 has **zero dependency on Chingu's code** and therefore **zero merge risk**. Build
and validate it in a tiny throwaway `main` before you wire anything into `ChatViewModel`:

1. **TTS round-trip:** hardcode a string → ElevenLabs TTS → `AVAudioPlayer` → hear it.
2. **STT round-trip:** record from the mic → ElevenLabs STT → `print(transcript)`.
3. **Endpointing:** record until silence, auto-stop, transcribe.

Only after all three work standalone do you touch `ChatViewModel` (step 5 below). That single
wiring step is the *only* code with merge exposure — everything before it is independent.

---

## 5. Component specs

### 5.1 `SpeechService.swift` (build first, standalone)

**Responsibility:** voice ↔ text via ElevenLabs. No Claude, no UI.

- `func transcribe(_ audio: Data) async throws -> String` — POST audio to ElevenLabs STT,
  return the transcript. Read the key via `Secrets.value(.elevenLabs)`; if nil, surface a
  clear error (don't crash) — mirror CP1's missing-key handling.
- `func synthesize(_ text: String) async throws -> Data` — POST text to ElevenLabs TTS,
  return audio bytes. Pick a voice id (constant for now).
- Errors (no key, non-2xx, network) surface as clear messages, never crashes — same posture
  as `AnthropicError` in CP1.
- **Never log/print the key.**

### 5.2 `MicCapture.swift`

**Responsibility:** capture mic audio (AVFoundation), detect end-of-question, hand audio to
`SpeechService`.

- Request **Microphone** permission (`AVCaptureDevice.requestAccess(for: .audio)` /
  `AVAudioApplication.requestRecordPermission`). Denied → clear in-chat message, no crash.
- Capture to a buffer/file in a format ElevenLabs STT accepts.
- **Endpointing:** simple RMS-based silence detection — when audio stays below a threshold for
  ~N ms, treat the utterance as finished and stop. Tune N (e.g. 800–1200 ms). A follow-up
  begins on the next start (button or wake word).

### 5.3 `ChatView.swift` — mic UI (UI only)

- Add a **mic button** to the composer (start/stop listening). Show a small "listening…" /
  "speaking…" state so the user knows what's happening.
- Keep it minimal and consistent with the existing composer; don't restyle CP1 (working
  agreement: one later polish pass).
- This is the only UI file CP4 edits; it does not change the message-list internals.

### 5.4 `ChatViewModel.swift` — the two seams (and nothing else)

This is the *entire* intersection with the pipeline. Two small edits:

1. **Transcript in (input seam):** when STT returns a transcript, call
   `submit(text: transcript)` — leave `image` at its default. Identical to a typed question.
2. **Speech out (output seam):** set the reserved hook once (e.g. on init or from the view):
   ```swift
   model.onAssistantResponseComplete = { reply in
       Task { try? await speak(reply) }   // SpeechService.synthesize → AVAudioPlayer
   }
   ```
   The VM already invokes this hook in the `.done` branch with the final assistant text (the
   seam the contract reserved). **You do not modify the streaming/`.done` logic** — you only
   *set* the closure.

Do **not** touch `submit`'s image handling, `AnthropicClient`, or `CapturedImage`.

### 5.5 AppDelegate wiring (separate extension)

Put mic-permission setup (and a voice-advance hotkey, if you add one) in
`extension AppDelegate { }` inside a CP4 file, adding at most **one line** (`setupSpeech()`)
to `applicationDidFinishLaunching` — per the split rule in `PARALLEL-CP2-CP4.md` §3c. Don't
refactor the existing AppDelegate body.

### 5.6 (Optional, last) Voice activation "야 친구!"

A wake-word trigger on the same mic stream. Build only after STT+TTS ship and only if time
allows. It's a trigger on top of the existing mic capture — it does **not** change the
pipeline.

---

## 6. The `.env` / key detail

`ELEVENLABS_API_KEY` is already wired through `Secrets` (loaded, trimmed, never logged) and
`scripts/run.sh` (exported, presence-logged at launch). To make it **required** for CP4, flip
`isRequiredNow` for `.elevenLabs` in `Secrets.swift` (a one-line, CP4-owned edit) so the
empty-state "Setup needed" banner names it. `.env.example` already lists the placeholder — no
change needed there.

---

## 7. Acceptance criteria (CP4 "done")

1. Pressing the mic button captures speech; on silence it auto-stops and transcribes.
2. The transcript enters the chat **exactly like a typed question** and gets a normal answer
   (text streams as in CP1, plus the screenshot path still works if CP2 has merged).
3. The assistant's reply is **spoken aloud** via TTS while the text still shows.
4. Missing `ELEVENLABS_API_KEY` or denied Microphone permission shows a clear in-chat message,
   never a crash.
5. STT/TTS code lives entirely in new files; the only `ChatViewModel` edits are the transcript
   call + setting `onAssistantResponseComplete`.
6. `AnthropicClient` and the image path are **untouched**. `swift build` green. Key never logged.

---

## 8. Build order (each tested before the next)

1. `SpeechService` TTS round-trip (hardcoded string → hear it). *(standalone)*
2. `SpeechService` STT round-trip (record → print transcript). *(standalone)*
3. `MicCapture` endpointing (record-until-silence → transcribe). *(standalone)*
4. Mic button + listening/speaking UI in `ChatView`.
5. **Wire the two seams** in `ChatViewModel` (transcript → `submit(text:)`; set the hook). ←
   the only step with merge exposure.
6. Verify acceptance criteria §7. *(Then optional: wake word.)*

---

## 9. Known gotchas

- **ElevenLabs is not the Anthropic API.** Use ElevenLabs' own current docs for STT/TTS
  endpoint shapes; `/claude-api` does not cover them. Claude's request is unchanged by CP4.
- **Don't edit the pipeline.** If you feel the urge to touch `AnthropicClient`,
  `submit`'s image handling, or `CapturedImage`, stop — that's CP2's lane and the source of
  merge conflicts.
- **Two TCC prompts, no overlap.** CP4 triggers **Microphone**; CP2 triggers **Screen
  Recording**. Independent — no shared permission code. Speech Recognition is **not** needed
  (ElevenLabs does STT server-side).
- **The hook fires once per turn, with the final text.** Set it; don't re-implement streaming.
  If you want to speak incrementally later, that's a future enhancement — ship final-text TTS first.
- **Most of CP4 is mergeproof.** Validate STT/TTS/endpointing standalone (§4) before the one
  wiring edit. That keeps ~80% of the work off the conflict surface entirely.
- **Key safety:** read `ELEVENLABS_API_KEY` only via `Secrets.value(.elevenLabs)`; never
  hardcode, print, or commit it.
