# ChinguPlan

## Hackathon Project Idea

**Chingu** is an AI companion that lives on your MacBook (Mac-native). It pops up as a chat overlay that can answer your questions. The main user-facing product is a floating, top-center overlay that appears at the top of your screen (just below the notch) at the press of a hotkey.

There is only **one chat thread** — no "new chat" option, no context-refresh option, and only one session. If you quit the app, the session is erased and the context resets. The UI is a fixed height and width, and you can scroll through the chat history.

## Problem & Solution

As students, we use LLMs constantly. We often find ourselves switching between tabs, taking screenshots, explaining the situation in text, and ultimately wasting time feeding context to the LLM.

Chingu cuts out this "middleman effort" by seeing what you see. It watches your screen, and when you have a question, you just ask — no screenshots, no context-prompting. Ask your question and get your answer.

Chingu also has a **pointer interface** for instructional questions, guiding you exactly where to click to do something on your computer. (For the demo, this is limited to button-map navigation.)

## Hackathon Strategy: Checkpoints

To hedge against the risk of not having a finished product, we develop in **checkpoints**. If we don't complete a checkpoint, we film the demo using the last working checkpoint as a fallback. Each checkpoint is independently demoable.

## Tech Stack

- **Swift** — the app itself: mic capture, UI, and the notch overlay (SwiftUI for visuals, AppKit for window/panel/hotkey/system behavior).
- **Claude** (`claude-opus-4-8`) — the brain: reasoning, vision (screenshot understanding), and web search.
- **ElevenLabs** — the voice: speech-to-text and text-to-speech (Checkpoint 4).

See [`docs/SPEC.md`](docs/SPEC.md) for the per-checkpoint technical decisions, and
[`docs/CP1-SPEC.md`](docs/CP1-SPEC.md) for the Checkpoint 1 implementation detail.

## Running (Checkpoint 1)

Chingu (CP1) is a Swift Package — no Xcode project needed. Requires macOS 14+ and a recent Swift
toolchain.

1. **Add your API key** to a local `.env` (gitignored — never committed):
   ```sh
   cp .env.example .env
   # then edit .env and set:  ANTHROPIC_API_KEY=sk-ant-...
   ```
   `ELEVENLABS_API_KEY` is for speech (Checkpoint 4) and can be left blank for now.

2. **Build & run** with the helper script (loads `.env`, then `swift run`):
   ```sh
   ./scripts/run.sh
   ```
   Or build only: `./scripts/run.sh build` (equivalently `swift build` / `swift run`).

3. **Use it:** press **⌃⌥⌘Space** (Control-Option-Command-Space) to toggle the overlay below the notch.
   Press **⌃⌥⌘K** to ask by voice. Type a question and press Enter. Try a plain question (*"What is 49 × 52 + 10?"*) and a
   current-info one (*"What's the latest stable macOS version?"*) to see web search.

The app builds and launches **without** a key — it shows a "Setup needed" banner until
`ANTHROPIC_API_KEY` is set. Keys are read at runtime via `ProcessInfo`, never hard-coded, and
never printed in logs.

### Checkpoint 1 — Groundwork + working UI on Mac *(most important)*

No screenshots yet. Get the core UI working:

- Press a hotkey to activate Chingu, which opens the notch overlay with a text input area and an Enter-to-send action.
- The text box shows placeholder guidance (e.g. *"Write your question/prompt here"*) that disappears when the user starts typing.
- The user can send questions and follow-ups and receive LLM responses in a chat thread.
- One chat thread only — no "new chat" or "clear context" option. A single back-and-forth thread.
- The LLM has no Chingu-specific prompt layer yet — it's just LLM chat and responses in your notch.
- **Must support web search.**

### Checkpoint 2 — Rudimentary screenshot feature

Checkpoint 1, plus a screenshot captured when the user presses Enter.

- The user can ask contextual questions such as *"What does this mean in English?"* or *"Summarize what's going on on my screen."*
- Chingu answers in the popup, and the user can ask follow-ups.
- Chingu does **not** give specific on-screen point-outs yet.
- Chingu must determine, per question, **whether it needs to see the screenshot** to answer.

### Checkpoint 3 — On-screen pointing

**Checkpoint 3a:** Chingu gives specific instructions and shows the user exactly where to click (pointer, circle, etc.). Useful for questions like *"How do I bold this text?"* or *"How do I insert a transition?"*

- It guides the user to click only the **first** button.
- If there's an overflow menu with multiple steps, it outputs the remaining steps as a text tree for the user to follow.

**Checkpoint 3b:** Multi-step version of 3a. To guide through an overflow menu with a sequence of clicks:

1. Place a circle over the first button and instruct the user to ask "what's next" after clicking it.
2. The user clicks the button (which opens more buttons), then asks "what's next," and the loop runs again.

This is tricky: to type "what's next" into the chat, the user would normally click Chingu's text field — which steals focus and closes the menu they just opened, putting them back at square zero. We also can't have the LLM watch the screen frame-by-frame to detect the click. The click completion needs to be **explicitly signaled**. (See `docs/spec.md` for the solution.)

### Checkpoint 4 — Speech integration

- Chingu automatically detects when the user has finished asking a question and when they're asking a follow-up, via speech.
- *(Optional)* Voice activation — *"야 친구!"* ("Hey Chingu!"), like "Hey Siri."
- There's still a button to end the conversation.
- Chingu also has text-to-speech to deliver its responses as speech.

This makes conversation more fluid and removes the need to move the mouse and type — especially useful while following on-screen instructions.

## Example Scenario

You're using Adobe Premiere Pro and have a question. Traditionally, you'd take a screenshot, write context in the prompt, and ask in a web chat interface. With Chingu, you just ask — Chingu captures your screen when you ask, removing the context-prompting middleman.

**Demo:** You have Premiere Pro open and ask Chingu: *"How do I add a fading transition between scene 1 and scene 2?"*

1. Chingu captures a screenshot the moment you press Enter. (We tell the user explicitly: the screen Chingu sees is the screen at the moment you press Enter — so they know how to use it.) At capture time, Chingu only saves the screenshot; it runs no analysis (no LLM/VLM/OCR) yet.
2. Chingu reads the prompt and decides whether it needs to see the screenshot.

This is where the workflow diverges:

**Route "NO"** — *e.g. "What time is it in Boston right now?"* or *"What is 49 × 52 + 10?"*
The question doesn't need screen context. Chingu treats it as a plain LLM query (with web search if needed) and outputs the response in the notch chat thread.

**Route "YES"** — *e.g. "How do I add a fading transition between scene 1 and scene 2?"*
Chingu feeds the question and screenshot to the LLM and provides an answer.

Within Route "YES," Chingu then decides whether the response needs a **cursor overlay** (e.g. guiding the user to click a specific button). If so, it feeds the screenshot to the LLM to identify the target control, locates its exact coordinates, and overlays a circle there.

---

See [`docs/spec.md`](docs/spec.md) for resolved technical decisions on each of the open questions above.
