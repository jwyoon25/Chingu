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
2. `docs/CP4-SPEC.md` — your detailed build spec. Build from it directly. (§4 explains the
   standalone test-harness strategy — do that first; it carries near-zero merge risk.)
3. `docs/SPEC.md` (CP4 section) and `docs/CP1-SPEC.md` — product + CP1 context.
4. Skim `Sources/Chingu/`: `ChatViewModel.swift` (has the two seams you use),
   `Secrets.swift` (`ELEVENLABS_API_KEY` already loads here), `ChatView.swift` (you add a mic
   button).

## What CP4 is
Speech in and out: the user speaks → ElevenLabs transcribes → the transcript enters the chat as
**the exact same input a typed question uses** → Claude answers → ElevenLabs speaks the reply
aloud. ElevenLabs does **voice only**; all reasoning/vision/search stays with Claude. You wrap
*around* the existing pipeline — you never change what happens inside a turn.

## Your file lane — edit ONLY these
- **`Sources/Chingu/SpeechService.swift`** (NEW) — ElevenLabs STT + TTS over `URLSession`. Pure
  voice↔text; knows nothing about Claude. Read the key via `Secrets.value(.elevenLabs)`. Put your
  `extension AppDelegate { setupSpeech/mic-permission }` here too.
- **`Sources/Chingu/MicCapture.swift`** (NEW) — AVFoundation mic capture + silence/endpoint
  detection; hands finished audio to `SpeechService` for transcription.
- **`Sources/Chingu/ChatView.swift`** — add a mic button + a listening/speaking state indicator.
  UI only; don't touch the message-list internals.
- **`Sources/Chingu/ChatViewModel.swift`** — TWO small edits and nothing else: (1) feed
  transcripts in via `submit(text: transcript)`; (2) set `onAssistantResponseComplete` to drive
  TTS. **Do not touch the image path, `submit`'s image handling, or `CapturedImage`.**
- Optionally flip `isRequiredNow` for `.elevenLabs` in `Secrets.swift` if you want the key
  required (one line).

## NEVER touch (CP2's lane — causes merge conflicts)
- `Sources/Chingu/AnthropicClient.swift` — do not edit it for any reason. If you feel you need an
  ElevenLabs *network* call, it goes in `SpeechService.swift`, NOT the Anthropic actor.
- The `image` parameter / `CapturedImage` in `ChatViewModel` — CP2 owns those.

## The two seams (your entire intersection with the pipeline) — do not reshape them
- **In:** call `ChatViewModel.submit(text: transcript)` — leave `image` at its default. Same call
  a typed question uses.
- **Out:** set `model.onAssistantResponseComplete = { reply in /* speak(reply) */ }`. The view
  model already invokes this hook with the final reply text — you only *set* the closure; do NOT
  modify the streaming/`.done` logic.

`submit(text:image:)` and `onAssistantResponseComplete` are locked. Don't rename or re-sign them.

## Build order (test each before the next) — harness first = near-zero merge risk
1. `SpeechService` TTS round-trip: hardcode a string → ElevenLabs TTS → `AVAudioPlayer` → hear it.
   *(standalone, no Chingu code)*
2. `SpeechService` STT round-trip: record from mic → ElevenLabs STT → `print(transcript)`.
   *(standalone)*
3. `MicCapture` endpointing: record-until-silence → transcribe. *(standalone)*
4. Mic button + listening/speaking UI in `ChatView`.
5. **Wire the two seams** in `ChatViewModel` (transcript → `submit(text:)`; set the hook). ← the
   ONLY step with merge exposure. Do it last.
6. Verify the §7 acceptance criteria in `CP4-SPEC.md`. (Optional, last: "야 친구!" wake word.)

## API note
ElevenLabs is **not** the Anthropic API — use ElevenLabs' own current docs for STT/TTS endpoint
shapes. The `/claude-api` skill does NOT cover ElevenLabs and you don't need it: Claude's request
shape is completely untouched by CP4.

## Hard rules (from PARALLEL-CP2-CP4.md §0)
- New logic → new files. The only edits to shared files are the mic button (`ChatView`) and the
  two seams (`ChatViewModel`).
- AppDelegate additions → your own `extension AppDelegate { }`, plus at most ONE line
  (`setupSpeech()`) in `applicationDidFinishLaunching`. Don't refactor the AppDelegate body.
- `swift build` must stay green before every push.
- **No new SwiftPM dependencies** — AVFoundation + `URLSession` are system frameworks. If you
  think you need a package, stop and ask the human.
- **Do not run git commands** unless the human tells you to.
- Read `ELEVENLABS_API_KEY` only via `Secrets.value(.elevenLabs)`; never hardcode/print/commit it.

## Merge note
CP2 (screenshots) merges to `main` first because it touches the request shape. You rebase your
`cp4-speech` branch onto `main` after that lands, and whenever CP2's author pushes. When you
finish, tell the human; don't merge yourself.
