# Cursor Handoff — CP4 (Speech) Agent

> Paste everything below the line into Cursor (model: **Claude Opus 4.8**) as your first
> message on the `cp4-speech` branch. Set up the branch first (see "Before you start").

**Before you start (human does this once):**
```sh
git checkout main && git pull
git checkout -b cp4-speech
swift build   # must be green before you begin
```
You'll also need `ELEVENLABS_API_KEY` in `.env` (copy from `.env.example`); it's already wired
through `Secrets` and `scripts/run.sh`.

---

You are implementing **Checkpoint 4 (speech)** of Chingu, a Mac-native AI companion, in this
repo. You are working in parallel with another agent building Checkpoint 2 (screenshots) on a
separate branch — so staying strictly in your file lane is a hard requirement, not a preference.

## Read these first, in order
1. `docs/PARALLEL-CP2-CP4.md` — the parallel-dev contract. **§0 is your hard rules.** §2 is the
   file-ownership map. Obey it.
2. `docs/CP4-SPEC.md` — your detailed build spec. Build from it directly. It was hardened in a
   finalize pass; pay special attention to **§4 (mic permission)** and **§6.3/§6.5
   (VoiceController drives the seams)** — they changed the plan from the original draft.
3. `docs/SPEC.md` (CP4 section) and `docs/CP1-SPEC.md` — product + CP1 context.
4. Skim `Sources/Chingu/`: `ChatViewModel.swift` (the two **public** seams you call — you do NOT
   edit this file), `Secrets.swift` (`ELEVENLABS_API_KEY` already loads here), `ChatView.swift`
   (you add a mic button).

## What CP4 is
Speech in and out: the user speaks → ElevenLabs transcribes → the transcript enters the chat as
**the exact same input a typed question uses** → Claude answers → ElevenLabs speaks the reply
aloud. ElevenLabs does **voice only**; all reasoning/vision/search stays with Claude. You wrap
*around* the existing pipeline — you never change what happens inside a turn.

## Three things the finalize pass pinned down (don't relearn these the hard way)
1. **Mic permission crashes a bare `swift run` binary.** No `.app`/`Info.plist` means no
   `NSMicrophoneUsageDescription`, and TCC **hard-crashes** on the first mic request — before any
   grant/deny. Fix per **CP4-SPEC §4**: add `Sources/Chingu/Info.plist` and a `Package.swift`
   linker flag that embeds it. **Ask the human before editing `Package.swift`.** Do this FIRST.
2. **You edit `ChatViewModel.swift` zero times.** Both seams are already `public`; a new
   `VoiceController` drives them from outside (see below).
3. **Your only shared-file edit is `ChatView.swift`.** `main.swift` stays untouched (the
   `VoiceController` is a `@StateObject` inside `ChatView`).

## Your file lane — edit ONLY these
- **`Sources/Chingu/SpeechService.swift`** (NEW) — ElevenLabs STT + TTS over `URLSession`. Pure
  voice↔text; knows nothing about Claude or the UI. Read the key via `Secrets.value(.elevenLabs)`.
- **`Sources/Chingu/MicCapture.swift`** (NEW) — `AVAudioRecorder` (with metering) mic capture +
  silence/endpoint detection; hands finished `.m4a` audio back for transcription.
- **`Sources/Chingu/VoiceController.swift`** (NEW) — `@MainActor ObservableObject` orchestrator:
  owns `MicCapture` + `SpeechService` + the retained `AVAudioPlayer`, exposes voice state to the
  UI, and **drives the two public seams** on `ChatViewModel`. Holds the optional
  `extension AppDelegate { setupSpeech() }` if you pre-warm permission.
- **`Sources/Chingu/Info.plist`** (NEW) — `NSMicrophoneUsageDescription` (embedded via §4).
- **`Sources/Chingu/ChatView.swift`** — add a mic button + a listening/speaking indicator + an
  error banner; own the `VoiceController` as a `@StateObject` built from `model`. UI only; don't
  touch the message-list internals.
- **`Package.swift`** — ONE linker flag for the Info.plist (§4). **Ask the human first.**
- Optionally flip `isRequiredNow` for `.elevenLabs` in `Secrets.swift` (one line) if you want the
  key required.

## NEVER touch (CP2's lane — causes merge conflicts)
- `Sources/Chingu/AnthropicClient.swift` — do not edit it for any reason. ElevenLabs *network*
  calls go in `SpeechService.swift`, NOT the Anthropic actor.
- `Sources/Chingu/ChatViewModel.swift` — **do not edit at all.** You call its public
  `submit(text:)` and set its public `onAssistantResponseComplete` from `VoiceController`.
- The `image` parameter / `CapturedImage` — CP2 owns those.

## The two seams (your entire intersection with the pipeline) — drive them, don't reshape them
- **In:** call `model.submit(text: transcript)` — leave `image` at its default. Same call a typed
  question uses.
- **Out:** set `model.onAssistantResponseComplete = { reply in /* speak(reply) */ }` (in
  `VoiceController.init`). The view model already invokes this hook with the final reply text — you
  only *set* the closure; do NOT modify the streaming/`.done` logic.

`submit(text:image:)` and `onAssistantResponseComplete` are locked. Don't rename or re-sign them,
and don't move their bodies — call them from your own file.

## Build order (test each before the next) — §4 first, harness next = near-zero merge risk
1. **`Info.plist` + `Package.swift` linker flag (CP4-SPEC §4)** — with human go-ahead. Confirm
   `swift build` green and a mic request no longer crashes.
2. `SpeechService` TTS round-trip: hardcode a string → ElevenLabs TTS → `AVAudioPlayer` → hear it.
   *(validate via a temporary in-app trigger — we are NOT adding a 2nd executable target)*
3. `SpeechService` STT round-trip: record from mic → ElevenLabs STT → `print(transcript)`.
4. `MicCapture` endpointing: record-until-silence → transcribe.
5. `VoiceController` state machine + mic button/indicator/error banner in `ChatView`.
6. **Wire the two seams** in `VoiceController` (transcript → `model.submit(text:)`; set the hook).
   ← the only step with merge exposure (touches no CP2 file). Remove the temporary trigger.
7. Verify the §9 acceptance criteria in `CP4-SPEC.md`. (Optional, last: "야 친구!" wake word.)

## API note
ElevenLabs is **not** the Anthropic API — use **CP4-SPEC §7** (verified shapes) / ElevenLabs'
current docs for STT/TTS. The `/claude-api` skill does NOT cover ElevenLabs and you don't need it:
Claude's request shape is completely untouched by CP4.

## Hard rules (from PARALLEL-CP2-CP4.md §0)
- New logic → new files. The only shared-file edit is the mic UI in `ChatView`; `ChatViewModel`
  and `main.swift` stay untouched.
- `swift build` must stay green before every push.
- **No new SwiftPM *package* dependencies** — AVFoundation + `URLSession` are system frameworks.
  The §4 `Package.swift` change is a linker flag, not a dependency — still, **ask the human before
  editing `Package.swift`.**
- macOS has no `AVAudioSession` (iOS-only); don't import it. Retain the `AVAudioPlayer`.
- **Do not run git commands** unless the human tells you to.
- Read `ELEVENLABS_API_KEY` only via `Secrets.value(.elevenLabs)`; never hardcode/print/commit it.

## Merge note
CP2 (screenshots) merges to `main` first because it touches the request shape. You rebase your
`cp4-speech` branch onto `main` after that lands, and whenever CP2's author pushes. When you
finish, tell the human; don't merge yourself.
