# Chingu — Checkpoint 4 Implementation Spec

Detailed build spec for **Checkpoint 4 only** — speech integration (ElevenLabs STT + TTS).
Expands the CP4 section of [`SPEC.md`](SPEC.md). Read [`SPEC.md`](SPEC.md),
[`CP1-SPEC.md`](CP1-SPEC.md), and the parallel-dev contract
[`PARALLEL-CP2-CP4.md`](PARALLEL-CP2-CP4.md) first.

> **Parallel-dev note.** CP4 is built on `cp4-speech`, in parallel with CP2 (screenshots) on
> `cp2-screenshot`. CP4 **wraps** the existing pipeline — voice in → text → [pipeline] →
> text → voice out — and never edits what happens *inside* a turn. Stay in CP4's file lane
> (see `PARALLEL-CP2-CP4.md` §2). The seam contract is already on `main`; you **drive** it, you
> don't reshape it.

> **What changed in this finalize pass (read me).** Three build-blocking realities were
> pinned down before coding:
> 1. **Mic permission crashes a bare `swift run` binary** — macOS TCC needs an
>    `NSMicrophoneUsageDescription` from an `Info.plist`, which a SwiftPM executable doesn't
>    have. We embed one via a linker flag (§4). This is the **one** `Package.swift` edit CP4
>    needs and it requires a human go-ahead.
> 2. **CP4 edits `ChatViewModel.swift` zero times.** Both seams (`submit(text:)` and
>    `onAssistantResponseComplete`) are already `public`, so a new `VoiceController` drives them
>    from outside (§6.3, §6.5). This removes the only HIGH-risk shared-file edit.
> 3. **CP4's only shared-file edit is `ChatView.swift`** (mic button + state). `main.swift`
>    stays untouched (the `VoiceController` is a `@StateObject` inside `ChatView`); the reserved
>    AppDelegate one-liner is optional (§6.6).

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

The two arrows that touch Chingu's code are the **two seams** the contract already reserved.
A new `VoiceController` (§6.3) is the orchestrator that drives them — it owns the mic, the
ElevenLabs calls, and the playback, and it talks to the existing `ChatViewModel` through its
**public** API only:
- **In:** call `model.submit(text: transcript)` — same call a typed question uses.
- **Out:** set `model.onAssistantResponseComplete = { text in speak(text) }`.

Everything between is untouched. **You never edit `AnthropicClient`, the `image` path, or
`ChatViewModel.swift` itself.**

---

## 2. Tech stack (CP4 additions)

| Concern | Choice |
|---|---|
| Mic capture | **AVFoundation** — `AVAudioRecorder` with metering (recommended), or an `AVAudioEngine` input tap if you need finer control |
| STT | **ElevenLabs Speech-to-Text** over `URLSession` (no SDK; raw HTTPS multipart). Model `scribe_v1` |
| TTS | **ElevenLabs Text-to-Speech** over `URLSession`; play with `AVAudioPlayer`. Model `eleven_multilingual_v2` (Korean-capable) |
| Endpointing | silence detection on the recorder's metering (`averagePower(forChannel:)`), with a speech-onset gate + timeout |
| Capture format | **m4a (AAC), 16 kHz, mono** — small, and accepted by ElevenLabs STT |
| Key | `ELEVENLABS_API_KEY` — **already loaded** by `Secrets`/`scripts/run.sh` (CP1 readiness) |
| Permission | **Microphone (TCC)** — requires an embedded `NSMicrophoneUsageDescription` (§4) |

No new SwiftPM **package** dependencies — AVFoundation and `URLSession` are system frameworks.
The one `Package.swift` change is a **linker flag** to embed an `Info.plist` (§4), not a new
dependency. The ElevenLabs key plumbing already exists: `Secrets.value(.elevenLabs)` returns it.

> **macOS ≠ iOS for audio.** `AVAudioSession` is **iOS/tvOS/watchOS only** — do **not** import
> or configure it on macOS; `AVAudioRecorder`/`AVAudioPlayer`/`AVAudioEngine` work without one.
> And you **must retain** the `AVAudioPlayer` (a strong property on `VoiceController`), or it
> deallocates mid-sentence and playback cuts out.

> ElevenLabs is **not** an Anthropic API — the `/claude-api` skill does **not** cover it. Use
> §7's reference (verified against ElevenLabs docs) and re-confirm against current docs if the
> API has moved. Claude's request shape is untouched by CP4.

---

## 3. File layout & ownership (CP4)

New logic goes in **new files** so it can't merge-conflict with CP2:

```
Sources/Chingu/
  SpeechService.swift   — NEW. ElevenLabs STT + TTS over URLSession. Pure voice↔text;
                          knows nothing about Claude or the UI.
  MicCapture.swift      — NEW. AVFoundation mic capture + silence/endpoint detection;
                          hands finished audio (m4a Data) back to its caller.
  VoiceController.swift  — NEW. @MainActor ObservableObject. The orchestrator: owns
                          MicCapture + SpeechService + the AVAudioPlayer, exposes voice
                          state to the UI, and drives the two public seams on ChatViewModel.
                          Also holds the optional `extension AppDelegate { setupSpeech() }`.
  Info.plist            — NEW. Carries NSMicrophoneUsageDescription (embedded via §4).
  ChatView.swift        — EDIT (CP4's ONLY shared-file edit). Add a mic button + a
                          listening/speaking indicator + an error banner. UI only. Owns the
                          VoiceController as a @StateObject built from `model`.
  Package.swift         — EDIT (one linker flag; §4). Requires a human go-ahead.
  Secrets.swift         — OPTIONAL one-line edit: flip `.elevenLabs` isRequiredNow if you want
                          a missing key to show in the empty-state "Setup needed" banner.
```

**Files you may touch (CP4 lane):** the three new `.swift` files, `Info.plist` (new),
`ChatView.swift` (mic UI), `Package.swift` (the §4 linker flag, with approval), and optionally
`Secrets.swift`. **Never touch:** `AnthropicClient.swift`, the `image` path, `CapturedImage`,
or `ChatViewModel.swift` (CP2's lane / the locked seam — and you don't need to edit the VM at
all).

> **Why no `ChatViewModel.swift` edit?** The post-seam `ChatViewModel` already exposes
> `func submit(text:image:)` and `var onAssistantResponseComplete` as `public`/internal members.
> `VoiceController` holds a reference to the `model` and uses them directly. Moving these two
> lines out of the VM and into your own file drops CP4's footprint in the highest-conflict file
> to **zero** — strictly safer than the original "two small edits," and fully faithful to the
> contract's intent (CP4 still *sets the hook* and *calls submit*, just from outside).

---

## 4. Microphone permission on a non-bundled binary (do this before any mic code)

**The problem.** Chingu runs as a bare SwiftPM executable (`swift run Chingu`) — there is **no
`.app` bundle and no `Info.plist`**. macOS TCC requires an `NSMicrophoneUsageDescription` string
(read from a plist) *before* it will show the mic prompt. With no plist, the first
`requestRecordPermission` / `AVCaptureDevice.requestAccess(for: .audio)` call **hard-crashes the
process** with: *"This app has crashed because it attempted to access privacy-sensitive data
without a usage description."* You never reach the grant/deny path — so handling "denied"
gracefully is **not enough**; you must supply the usage string first.

> CP2's Screen Recording does **not** hit this (it's gated by the system list, no usage-string
> key), so this is a **CP4-only** requirement.

**The fix — embed an `Info.plist` into the executable via a linker flag.** No `.app` bundle, no
new run script.

1. Add `Sources/Chingu/Info.plist`:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>CFBundleIdentifier</key>
       <string>com.chingu.app</string>
       <key>CFBundleName</key>
       <string>Chingu</string>
       <key>NSMicrophoneUsageDescription</key>
       <string>Chingu listens to your voice so you can ask questions by speaking.</string>
   </dict>
   </plist>
   ```
2. Add the linker flag to the `Chingu` target in `Package.swift` (**ask the human before editing
   `Package.swift`** — it's a shared file, per the hard rules):
   ```swift
   .executableTarget(
       name: "Chingu",
       path: "Sources/Chingu",
       linkerSettings: [
           .unsafeFlags([
               "-Xlinker", "-sectcreate",
               "-Xlinker", "__TEXT",
               "-Xlinker", "__info_plist",
               "-Xlinker", "Sources/Chingu/Info.plist",
           ])
       ]
   )
   ```
   This bakes the plist into the Mach-O's `__TEXT,__info_plist` section, where TCC reads it.

**Caveats to know:**
- `.unsafeFlags` means the package can't be consumed as a *dependency* by another package. Chingu
  is a leaf executable, so this is irrelevant here.
- `Info.plist` lives under `Sources/Chingu/`; exclude it from compilation isn't needed (SwiftPM
  ignores non-Swift files for compilation), but keep it out of any `sources:` list if you add one.
- TCC keys grants by code identity. A bare binary's grant may not persist across rebuilds as
  reliably as a signed `.app`; if the mic prompt stops reappearing but access fails, reset with
  `tccutil reset Microphone` and relaunch. Acceptable for hackathon dev.
- Conflict risk: CP2 does **not** touch `Package.swift`, so this one-line target edit is low-risk
  to merge — but still coordinate, since `Package.swift` edits collide easily.

**Permission request itself** (after the plist is embedded): request lazily on the **first mic
tap** (not at launch) so users who never use voice aren't prompted. Use
`AVAudioApplication.requestRecordPermission(completion:)` (macOS 14+) or
`AVCaptureDevice.requestAccess(for: .audio)`. Denied → set `VoiceController.errorMessage` and
show the banner (§6.4); never crash.

---

## 5. The de-risking move — validate STT/TTS in-app FIRST, with a temporary trigger

Most of CP4 has **zero dependency on Chingu's pipeline** and therefore **zero merge risk**.
Validate it before wiring the seams. (We are **not** adding a second SwiftPM executable target —
that would be a `Package.swift` change for a throwaway. Instead, drive the round-trips from a
**temporary debug trigger** inside the app, e.g. a hidden button or a `#if DEBUG` call in
`VoiceController`, and delete it once green.)

1. **TTS round-trip:** hardcode a string → `SpeechService.synthesize` → `AVAudioPlayer` → hear it.
2. **STT round-trip:** record from the mic → `SpeechService.transcribe` → `print(transcript)`.
3. **Endpointing:** record until silence, auto-stop, transcribe.

Only after all three work do you wire `VoiceController` to the seams (§6.5). That wiring is the
*only* part with any merge exposure — and even it touches no CP2 file.

---

## 6. Component specs

### 6.1 `SpeechService.swift` (build first)

**Responsibility:** voice ↔ text via ElevenLabs. No Claude, no UI, no mic. A `struct` (or
`actor`) of pure async functions. See §7 for the exact endpoint shapes.

- `func synthesize(_ text: String) async throws -> Data` — POST text to ElevenLabs TTS, return
  MP3 bytes. Uses a constant voice id + `eleven_multilingual_v2`.
- `func transcribe(_ audio: Data, filename: String, mimeType: String) async throws -> String` —
  POST a multipart form (`model_id=scribe_v1`, `file=<audio>`) to ElevenLabs STT, return the
  `text` field.
- Read the key via `Secrets.value(.elevenLabs)`; if nil, throw a clear `SpeechError.missingAPIKey`
  (don't crash) — mirror CP1's missing-key posture.
- Errors (no key, non-2xx with body, network) surface as clear messages via a `SpeechError:
  LocalizedError` enum, exactly like `AnthropicError`. **Never log/print the key.**

```swift
enum SpeechError: LocalizedError {
    case missingAPIKey
    case badStatus(Int, String)
    case transport(String)
    case emptyTranscript
    // errorDescription: human-readable, never includes the key
}
```

**TTS text hygiene (do this before synth):** CP1 renders **raw Markdown** in bubbles (a known,
intentionally-unfixed bug), so replies contain `**`, `#`, backticks, `[text](url)`, and
web-search citation markers. Strip/normalize these to plain text before synth, or TTS will read
"asterisk asterisk". A small `plainSpeech(_:)` helper is enough.

**TTS length:** a single TTS request has a per-call character ceiling (model-dependent;
exceeding it returns HTTP 422). For long web-search answers, either **truncate** to a safe length
with a spoken "…(truncated)" note (simplest, fine for v1) or **chunk** on sentence boundaries and
queue playback. Ship truncate first; chunking is an enhancement.

### 6.2 `MicCapture.swift`

**Responsibility:** capture mic audio, detect end-of-question, hand back finished audio. No
ElevenLabs, no Claude.

- **Recommended approach — `AVAudioRecorder` with metering:**
  - Settings: `AVFormatIDKey: kAudioFormatMPEG4AAC`, `AVSampleRateKey: 16000`,
    `AVNumberOfChannelsKey: 1`, write to a temp `.m4a` URL. Set `isMeteringEnabled = true`.
  - **Endpointing:** poll on a timer (~50–100 ms): `updateMeters()` then
    `averagePower(forChannel: 0)` (dBFS, roughly −160…0). Logic:
    1. **Speech-onset gate:** don't start the silence timer until power first rises above a
       speech threshold (e.g. > −35 dB) — otherwise the leading silence ends the utterance
       instantly.
    2. **Silence timeout:** once speech has started, if power stays below the threshold for
       ~**900 ms** (tune 800–1200 ms), stop and return the file's `Data`.
    3. **Max-utterance cap** (e.g. 30 s) and a sensible **min length** so a stray click isn't a
       "question."
  - On stop, read the `.m4a` into `Data`, return it with `filename: "audio.m4a"`,
    `mimeType: "audio/mp4"`.
- **Alternative** — `AVAudioEngine` input tap if you want sample-level control: tap the
  `inputNode`, compute RMS per buffer for the same endpointing logic, and write accumulated
  buffers to an `AVAudioFile` (16 kHz mono). More code; only do this if metering proves too
  coarse.
- Microphone permission is requested here (or in `VoiceController`) on first use — see §4.
  Denied → surface via `errorMessage`, no crash. **No `AVAudioSession` on macOS** (§2).

### 6.3 `VoiceController.swift` (the orchestrator)

**Responsibility:** the conversation loop and all UI-facing state. `@MainActor`,
`ObservableObject`. Owns `MicCapture`, `SpeechService`, and the retained `AVAudioPlayer`, and
holds a reference to the existing `ChatViewModel`.

```swift
@MainActor
final class VoiceController: ObservableObject {
    enum State: Equatable { case idle, listening, transcribing, speaking }
    @Published private(set) var state: State = .idle
    @Published var errorMessage: String?          // shown as a banner in ChatView

    private let model: ChatViewModel
    private let speech = SpeechService()
    private let mic = MicCapture()
    private var player: AVAudioPlayer?            // MUST be retained

    init(model: ChatViewModel) {
        self.model = model
        // OUTPUT SEAM — set the reserved hook (drives TTS). No ChatViewModel edit.
        model.onAssistantResponseComplete = { [weak self] reply in
            Task { await self?.speak(reply) }
        }
    }

    func toggleMic() { /* state machine, see below */ }

    private func finishListening(_ audio: Data) async {
        state = .transcribing
        do {
            let transcript = try await speech.transcribe(audio, filename: "audio.m4a",
                                                          mimeType: "audio/mp4")
            // INPUT SEAM — identical to a typed question. No ChatViewModel edit.
            model.submit(text: transcript)
            state = .idle
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription
                                 ?? "Couldn't transcribe."; state = .idle }
    }

    private func speak(_ reply: String) async { /* synthesize → player.play(); state = .speaking */ }
}
```

**State machine / interaction policy (specify so the UI is predictable):**
- `idle → listening` on mic tap (after permission).
- `listening → transcribing` on endpoint (silence) — or on a second tap (manual stop).
- `transcribing → idle`, then the normal pipeline runs (`model.isResponding` drives the chat's
  own streaming UI; `VoiceController` doesn't duplicate it).
- On `onAssistantResponseComplete` → `speak()` → `speaking`, back to `idle` when playback ends
  (`AVAudioPlayerDelegate.audioPlayerDidFinishPlaying`).
- **Mic disabled while `model.isResponding`** (one turn at a time, matching the composer).
- **Barge-in:** tapping the mic while `speaking` stops playback and starts listening; tapping
  while `listening` cancels/stops. (Observe `model.isResponding` via the `@ObservedObject` in the
  view, or read it directly.)

### 6.4 `ChatView.swift` — mic UI (CP4's only shared-file edit, UI only)

- Own the controller as a `@StateObject` built from the injected `model`, so **`main.swift`
  stays untouched**:
  ```swift
  struct ChatView: View {
      @ObservedObject var model: ChatViewModel
      @StateObject private var voice: VoiceController
      init(model: ChatViewModel) {
          self.model = model
          _voice = StateObject(wrappedValue: VoiceController(model: model))
      }
      // ...
  }
  ```
- Add a **mic button** to the composer (start/stop), its symbol/label reflecting
  `voice.state` (idle/listening/transcribing/speaking). Disable it while `model.isResponding`.
- Add a small **error banner** bound to `voice.errorMessage` (mic denied, no key, STT/TTS
  failure). **Errors render as transient `ChatView` state, NOT as chat bubbles** — appending a
  bubble would require a `ChatViewModel` method (a forbidden VM edit). Keep it minimal and
  consistent with the existing composer; don't restyle CP1 (one later polish pass).
- This is the **only** UI file CP4 edits; it does not change the message-list internals.

### 6.5 Driving the two seams (no `ChatViewModel` edit)

This is the *entire* intersection with the pipeline, and it lives in `VoiceController`, not the
VM:

1. **Output seam (in `init`):** `model.onAssistantResponseComplete = { reply in speak(reply) }`.
   The VM already invokes this hook in its `.done` branch with the final assistant text — you
   only *set* the closure; you do **not** modify the streaming/`.done` logic (it's locked on
   `main`).
2. **Input seam (after STT):** `model.submit(text: transcript)` — leave `image` at its default.
   Identical to a typed question.

Do **not** touch `submit`'s image handling, `AnthropicClient`, `CapturedImage`, or
`ChatViewModel.swift` itself.

### 6.6 AppDelegate wiring (optional)

Because `VoiceController` is a `@StateObject` inside `ChatView` and permission is requested
lazily, **`main.swift` needs no edit**. If you later want to **pre-warm** mic permission at
launch, the contract reserves a one-liner: add `extension AppDelegate { func setupSpeech() }` in
`VoiceController.swift` and call `setupSpeech()` once in `applicationDidFinishLaunching` — per
`PARALLEL-CP2-CP4.md` §3c. Don't refactor the existing AppDelegate body.

### 6.7 (Optional, last) Voice activation "야 친구!"

A wake-word trigger on the same mic stream. Build only after STT+TTS ship and only if time
allows. It's a trigger on top of the existing mic capture — it does **not** change the pipeline.

---

## 7. Verified ElevenLabs API reference (do not guess — re-confirm if the API has moved)

> ElevenLabs is **not** the Anthropic API; `/claude-api` does not cover it. The shapes below match
> ElevenLabs' REST docs as of this spec. If a call 4xxs unexpectedly, re-check the current docs
> before improvising.

**Auth header (both endpoints):** `xi-api-key: <ELEVENLABS_API_KEY>` (read via
`Secrets.value(.elevenLabs)`).

**Text-to-Speech**
- `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}`
- Optional query: `?output_format=mp3_44100_128`
- Headers: `xi-api-key`, `Content-Type: application/json`, `Accept: audio/mpeg`
- Body:
  ```json
  {
    "text": "<reply text, markdown stripped>",
    "model_id": "eleven_multilingual_v2",
    "voice_settings": { "stability": 0.5, "similarity_boost": 0.75 }
  }
  ```
- Response: **binary MP3 bytes** → `AVAudioPlayer(data:)`.
- `voice_id`: pick a constant from your ElevenLabs voice library (e.g. a multilingual voice that
  handles Korean for "야 친구!"). Keep it a single named constant in `SpeechService`.

**Speech-to-Text**
- `POST https://api.elevenlabs.io/v1/speech-to-text`
- Headers: `xi-api-key` (+ multipart `Content-Type` with boundary, set by your request builder)
- Body: `multipart/form-data` with:
  - `model_id` = `scribe_v1` (required)
  - `file` = the audio bytes (our 16 kHz mono `.m4a`)
  - optional: `language_code`, `diarize`, `tag_audio_events`
- Response JSON (use `text`):
  ```json
  { "language_code": "kor", "language_probability": 0.98, "text": "전체 transcript", "words": [ ... ] }
  ```
- Accepts common audio formats (mp3, wav, m4a, flac, ogg, …); m4a/AAC is fine.

---

## 8. The `.env` / key detail

`ELEVENLABS_API_KEY` is already wired through `Secrets` (loaded, trimmed, never logged) and
`scripts/run.sh` (exported, presence-logged at launch). To make it **required** for CP4, flip
`isRequiredNow` for `.elevenLabs` in `Secrets.swift` (a one-line, CP4-owned edit) so the
empty-state "Setup needed" banner names it. `.env.example` already lists the placeholder — no
change needed there.

---

## 9. Acceptance criteria (CP4 "done")

1. Pressing the mic button captures speech; on silence it auto-stops and transcribes.
2. The transcript enters the chat **exactly like a typed question** and gets a normal answer
   (text streams as in CP1, plus the screenshot path still works if CP2 has merged).
3. The assistant's reply is **spoken aloud** via TTS while the text still shows.
4. **Mic permission does not crash** — the embedded `Info.plist` (§4) is in place; missing
   `ELEVENLABS_API_KEY` or **denied** Microphone permission shows a clear in-`ChatView` banner,
   never a crash.
5. STT/TTS/orchestration live entirely in new files; **`ChatViewModel.swift` is unedited**; the
   only shared-file edit is `ChatView.swift` (mic UI) plus the §4 `Package.swift`/`Info.plist`.
6. `AnthropicClient` and the image path are **untouched**. `swift build` green. Key never logged.

---

## 10. Build order (each tested before the next)

1. **§4 first:** add `Info.plist` + the `Package.swift` linker flag (with human go-ahead); confirm
   `swift build` still green and a mic request no longer crashes.
2. `SpeechService` TTS round-trip (hardcoded string → hear it). *(temporary in-app trigger)*
3. `SpeechService` STT round-trip (record → print transcript). *(temporary trigger)*
4. `MicCapture` endpointing (record-until-silence → transcribe). *(temporary trigger)*
5. `VoiceController` state machine + mic button/indicator/error banner in `ChatView`.
6. **Wire the two seams** in `VoiceController` (transcript → `model.submit(text:)`; set
   `model.onAssistantResponseComplete`). ← the only step with any merge exposure (touches no CP2
   file). Remove the temporary trigger.
7. Verify acceptance criteria §9. *(Then optional: wake word.)*

---

## 11. Known gotchas

- **Mic crashes without a usage description (§4).** This is the #1 trap and is CP4-specific. Do
  §4 before any mic code, or the first permission request kills the process.
- **`AVAudioSession` is iOS-only.** On macOS it doesn't exist; importing/using it won't build.
  `AVAudioRecorder`/`AVAudioPlayer` need no session. **Retain the `AVAudioPlayer`** (strong
  property) or playback stops early.
- **ElevenLabs is not the Anthropic API.** Use §7 / current ElevenLabs docs; `/claude-api` does
  not cover it. Claude's request is unchanged by CP4.
- **Don't edit the pipeline.** No `AnthropicClient`, no `submit` image handling, no
  `CapturedImage`, **no `ChatViewModel.swift` at all** — drive the public seams from
  `VoiceController`. Touching CP2's lane is the source of merge conflicts.
- **Endpointing needs a speech-onset gate.** Start the silence timer only after audio first rises
  above the speech threshold, or the leading silence ends the utterance immediately. Cap max
  duration; enforce a min length.
- **Strip Markdown before TTS.** CP1 bubbles show raw Markdown (known, unfixed), so replies
  contain `**`, `#`, backticks, links, and citation markers — feed plain text to synth.
- **TTS has a per-request character ceiling.** Long answers 422; truncate (v1) or chunk on
  sentences and queue playback.
- **Errors are `ChatView` state, not chat bubbles.** Appending a bubble would need a forbidden
  `ChatViewModel` edit; bind a banner to `VoiceController.errorMessage` instead.
- **The hook fires once per turn, with the final text.** Set it; don't re-implement streaming.
  Incremental/streaming TTS is a future enhancement — ship final-text TTS first.
- **Most of CP4 is mergeproof.** Validate STT/TTS/endpointing via the in-app temporary trigger
  (§5) before wiring the seams. That keeps ~80% of the work off the conflict surface entirely.
- **Key safety:** read `ELEVENLABS_API_KEY` only via `Secrets.value(.elevenLabs)`; never
  hardcode, print, or commit it.
