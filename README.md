# Chingu — Your AI Companion in the Notch

> *Press a hotkey. Ask anything. Chingu sees what you see.*

Chingu is a Mac-native AI companion that lives just below the notch. One global hotkey summons a floating chat overlay — no window switching, no tab juggling, no copy-pasting screenshots. It watches your screen, understands what you're looking at, and can point at the exact button you need to click.

---

## Demo

**You're in Adobe Premiere Pro and stuck on a transition.**

- Old way: ⌘Tab → browser → take screenshot → paste → type context → wait.
- With Chingu: press **⌃⌥⌘Space**, ask *"How do I add a fading transition between scene 1 and scene 2?"*, press Enter.

Chingu captures your screen the moment you press Enter, sends it to Claude, and answers in the notch — with a circle drawn over the exact button to click. Say *"what's next"* and it guides you through the rest.

---

## Features

| | Checkpoint | What it unlocks |
|---|---|---|
| ✅ | **CP1 — Chat** | Hotkey overlay, streaming Claude chat, web search |
| ✅ | **CP2 — Vision** | Screenshot on Enter, screen-aware answers |
| ✅ | **CP3 — Pointing** | Circle drawn over the exact control to click, multi-step guidance |
| ✅ | **CP4 — Voice** | Speak your question, hear the answer; say "what's next" hands-free |

### Why it doesn't steal focus

The overlay is a **non-activating `NSPanel`** — it floats over your apps without ever becoming the active window. That's what makes CP3 work: the overflow menu you just opened stays open while Chingu draws a circle over it, because Chingu never interrupted the app behind it.

---

## Tech Stack

| Layer | Technology |
|---|---|
| App | Swift 6, SwiftUI + AppKit, macOS 14+ |
| Brain | Claude (`claude-haiku-4-5`) — reasoning, vision, web search |
| Screenshot | ScreenCaptureKit — captures display, excludes Chingu's own window |
| Pointing | Pure vision — Claude reports pixel coords; app remaps + draws a click-through circle |
| Voice | ElevenLabs STT + TTS; AVFoundation mic capture |
| Hotkey | Carbon `RegisterEventHotKey` wrapper |

No third-party Swift packages. System frameworks only.

---

## Running

Requires **macOS 14+** and a recent Swift toolchain. No Xcode project — this is a Swift Package.

### 1. Set your API keys

```sh
cp .env.example .env
# Edit .env:
#   ANTHROPIC_API_KEY=sk-ant-...
#   ELEVENLABS_API_KEY=...      # required for CP4 voice
```

### 2. Build & run

```sh
./scripts/run.sh
```

The script loads `.env`, exports the keys, and runs `swift run Chingu`. Build only: `./scripts/run.sh build`.

### 3. Use it

| Hotkey | Action |
|---|---|
| **⌃⌥⌘Space** | Toggle the notch overlay |
| **⌃⌥⌘K** | Push-to-talk (voice input) |
| **Enter** | Send message (captures a screenshot) |
| **Advance hotkey** | Step to the next pointed control (CP3b, no-focus-change) |

The app starts without a key and shows a setup banner until `ANTHROPIC_API_KEY` is present. Keys are never hardcoded, never logged, and never committed.

---

## Architecture

```
main.swift              NSApplication bootstrap, panel positioning, hotkey wiring
ChinguPanel.swift       Non-activating NSPanel — the load-bearing piece
ChatView.swift          SwiftUI chat UI (hosted in the panel via NSHostingView)
ChatViewModel.swift     @MainActor view model; locked seam: submit(text:image:)
AnthropicClient.swift   actor: builds requests, streams SSE, handles web search
ScreenCapture.swift     ScreenCaptureKit capture, excludes Chingu's window
ScreenArtifactFilter.swift  Content filter for clean captures
PointTag.swift          Parses [POINT:x,y:label] tags out of Claude's reply
PointingController.swift    Remaps pixel → screen point, manages circle lifecycle
PointerOverlay.swift    Click-through NSPanel that draws the circle
SpeechService.swift     ElevenLabs STT/TTS over URLSession
MicCapture.swift        AVFoundation mic capture, streams audio to ElevenLabs
VoiceController.swift   Orchestrates push-to-talk, silence detection, TTS playback
GlobalHotKey.swift      Carbon hotkey wrapper
Secrets.swift           Centralized key loading from environment
SystemPrompt.swift      Chingu's system prompt
```

### How pointing works

When Claude answers a "how do I…" question, it appends a single tag to its reply:

```
[POINT:842,156:Effects panel]
```

The app strips the tag before showing the text or reading it aloud, remaps the pixel coordinate to a screen point using the captured display's geometry, and draws a large forgiving circle in a click-through overlay that sits *over* the target app without blocking the click underneath. No Accessibility API, no OCR — pure vision.

### How parallel development worked

CP2 (screenshots) and CP4 (voice) were built simultaneously on separate branches off `main`. They meet at exactly two locked seams defined before either branch was cut:

- **Input:** `ChatViewModel.submit(text:image:)` — typed questions, voice transcripts, and screenshot attachment all flow through here.
- **Output:** `ChatViewModel.onAssistantResponseComplete` — fired with the final assistant text; CP4 hooks this to drive TTS.

New capabilities live in new files. Merge order: CP2 first (it touches the request shape), then CP4 rebases.

---

## What's next (after the hackathon)

- **Accessibility API fallback** for pixel-exact pointing on standard controls (the pure-vision path is a known approximation).
- **Persistence** — today's session erases on quit; a lightweight SQLite log would make Chingu a longer-term companion.
- **Proxy server** — keys bundled in a distributed Mac app are extractable; the real fix is a server-side proxy.
- **Wake word** — *"야 친구!"* ("Hey Chingu!") for truly hands-free activation.

---

*Built at Cursor Hackathon Seoul by Team PlsDonateTokens.  
Claude is the brain. ElevenLabs is the voice. Swift is the glue.*
