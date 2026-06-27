# Chingu — Checkpoint 1 Implementation Spec

This is the **detailed build spec for Checkpoint 1 only.** It expands the CP1 section of
[`SPEC.md`](SPEC.md) into something an implementing agent can build from directly. Later
checkpoints get their own sub-specs as we pass each one — **do not build CP2–CP4 here.**

Read [`SPEC.md`](SPEC.md) and [`README.md`](../README.md) first for product context. Where this
document and `SPEC.md` overlap, both must agree; `SPEC.md` holds the product decisions, this
document holds the implementation detail.

---

## 0. Scope — what CP1 is and is NOT

**CP1 IS:**
- A Mac-native app with a floating, top-center overlay below the notch.
- A global hotkey that toggles the overlay.
- One chat thread: text input → Claude → streamed response, with follow-ups.
- Web search support (Claude's server-side tool).

**CP1 is NOT (do not build):**
- No screenshots / screen capture (CP2).
- No vision / image input (CP2).
- No on-screen pointing, circles, or Accessibility API (CP3).
- No speech, mic, STT, or TTS (CP4).
- No "new chat" / "clear context" button — **one thread only**.
- No *real* Chingu persona / behavior system prompt — a **placeholder** system prompt is wired in
  (the plumbing), but its content is a stub to be replaced in a later checkpoint. Plain chat for now.
- No persistence — quitting the app erases the session.
- No settings UI, no onboarding, no multi-window.

If a feature isn't explicitly listed under "CP1 IS," it's out of scope. Keep it minimal; this
is a hackathon MVP.

---

## 1. Tech stack (CP1)

| Concern | Choice |
|---|---|
| Language | Swift |
| Visual UI | SwiftUI |
| Window / overlay | AppKit `NSPanel` (non-activating), SwiftUI hosted via `NSHostingView` |
| Global hotkey | Carbon `RegisterEventHotKey` (built — no dependency). The `HotKey` SwiftPM package was an acceptable alternative but wasn't needed. |
| Networking | `URLSession` (native) — **no Alamofire, no third-party HTTP** |
| AI | Claude `claude-opus-4-8`, Anthropic **Messages API**, raw HTTPS (no Swift SDK exists) |
| Streaming | SSE over `URLSession.bytes(for:)` |
| Web search | Server-side tool `web_search_20260209` declared in the request |
| Secret | `ANTHROPIC_API_KEY` from `ProcessInfo.processInfo.environment` |

Minimum target: **macOS 14+** (`Package.swift` declares `.macOS(.v14)`). CP1 alone would run on
13, but we set 14 now so CP2's ScreenCaptureKit requirement doesn't force a later bump. Use a
recent Swift toolchain (built with Swift 6.x).

> **There is no official Anthropic Swift SDK.** You hand-write the JSON request and parse the
> SSE stream with `URLSession`. This is expected and simple. If unsure of the exact current
> request/response shape, invoke the **`claude-api` skill** (`/claude-api`) — it is the
> authoritative, current reference. Do **not** rely on training-prior memory for the API shape.

---

## 2. Project setup

The repo at `/Users/jaydenyoon/Developer/ChinguPlan` had **no Xcode project**.

**What was built: a Swift Package Manager executable target.** `Package.swift` defines an
executable target named `Chingu` (macOS 14+) that builds a real macOS app via `swift build`.
This is the sanctioned fallback from the original brief, chosen because:
- `xcodegen` is not installed and hand-writing a valid `.xcodeproj` from the CLI is fragile,
  whereas `swift build` is deterministic and works headlessly (so an agent can build/run it).
- The non-activating panel + global hotkey want **manual `NSApplication` control** (an accessory
  app bootstrapped from `main.swift`), not the `@main App` SwiftUI lifecycle — so SwiftPM is in
  fact the cleaner fit, not just a fallback.

Notes that still hold:
- **No nested git repository** — the existing repo is reused.
- `.gitignore` covers `xcuserdata/`, `DerivedData/`, `.build/`, and secret files (`.env`,
  `.env.*`), with `!.env.example` so the placeholder template is still tracked.
- Build: `swift build`. Run: `./scripts/run.sh` (loads `.env`, then `swift run`). See §6.

### App lifecycle note
Chingu behaves like a menu-bar / accessory utility, not a standard windowed app:
- **No main window** at launch — the overlay panel is the only surface.
- `main.swift` calls `NSApplication.setActivationPolicy(.accessory)` (no Dock icon) and drives
  `NSApplication` manually. For CP1, `.accessory` + hotkey-to-toggle is the implementation. (A
  `NSStatusItem` with a quit option is a nice-to-have, not built.)

---

## 3. Architecture & file layout

The build keeps responsibilities separate but uses a flat `Sources/Chingu/` layout (SwiftPM
target) rather than nested folders. **As built:**

```
Package.swift              — SwiftPM executable target "Chingu" (macOS 14+)
.env.example               — placeholder secrets template (committed; copy to .env)
scripts/run.sh             — loads .env, then `swift run` (never prints key values)
Sources/Chingu/
  main.swift               — entry point: NSApplication bootstrap (.accessory), creates the
                             panel, positions it below the notch, registers the hotkey, toggles
  ChinguPanel.swift        — the non-activating NSPanel subclass (canBecomeKey/Main, level,
                             collectionBehavior) hosting SwiftUI via NSHostingView
  GlobalHotKey.swift       — Carbon RegisterEventHotKey wrapper, main-actor isolated
  ChatView.swift           — SwiftUI: message list + composer; shows the setup banner when a
                             required key is missing
  ChatViewModel.swift      — @MainActor ObservableObject: holds messages, drives the client
  ChatMessage              — model (id, role, text, isStreaming, isSearching) — in ChatViewModel.swift
  AnthropicClient.swift    — actor: builds the request, streams SSE, yields deltas; also the
                             JSONValue request/response model and SSE block assembler
  SystemPrompt.swift       — the (placeholder) system-prompt constant; attached to the request
                             only when non-empty
  Secrets.swift            — centralized key loading from the environment (ANTHROPIC_API_KEY,
                             ELEVENLABS_API_KEY); never logs/prints values
```

Deviations from the original suggested layout (all permitted by "adapt names as needed, keep
responsibilities separate"): `OverlayController`'s show/hide/position duties live in `main.swift`'s
app delegate; the request/response Codable structs are folded into `AnthropicClient.swift` as a
small `JSONValue` enum (we hand-roll JSON, so there are no generated model structs); `Secrets.swift`
was added for centralized key handling.

**State ownership:** `ChatViewModel` (`@MainActor`) is the single source of truth for the message
thread and in-flight request. The app delegate (in `main.swift`) owns the panel and hotkey.
`GlobalHotKey` just calls the toggle closure. `AnthropicClient` is an `actor` owning only the
in-memory conversation `history` (the one session). `Secrets` is read-only.

**Build order followed (sequential — each tested before the next):**
1. API client → 2. Chat UI → 3. Non-activating panel → 4. Global hotkey → 5. Verify web search.

---

## 4. Component specs

### 4.1 `AnthropicClient` (build first)

**Responsibility:** read the key, build a Messages API request to `claude-opus-4-8`, stream the
response, surface text deltas to the caller, handle web-search tool blocks gracefully.

**Key loading (centralized in `Secrets.swift`):** keys are read from the environment via
`ProcessInfo`, trimmed, and treated as missing if empty. `AnthropicClient` asks `Secrets` for the
key rather than reading the environment directly:
```swift
// Secrets.swift — single source for all keys; never logs/prints values.
static func value(_ key: Key) -> String? {
    guard let raw = ProcessInfo.processInfo.environment[key.rawValue] else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// AnthropicClient — on send, with no key, yields a .failed(.missingAPIKey) event
// (surfaced in the chat UI) instead of crashing.
guard let key = Secrets.value(.anthropic) else { /* emit missing-key message */ }
```
Never log, print, or hard-code the key.

**Where keys come from (local demo):** a gitignored `.env` at the repo root holds the keys;
`scripts/run.sh` sources it (exporting the vars) before `swift run`, so the app reads them through
`ProcessInfo`. No in-app `.env` parsing — the shell does it. `.env.example` documents the format.
See §6 for the run flow.

**`ELEVENLABS_API_KEY`:** read and validated by `Secrets` now (for CP4 readiness) but **not
consumed** — no speech code in CP1. It is *not* required this checkpoint, so its absence does not
trigger the setup banner. Launch logs presence only (`ELEVENLABS_API_KEY loaded` / `not set`).

**Request (verify exact shape via `/claude-api`):**
- Endpoint: `POST https://api.anthropic.com/v1/messages`
- Headers:
  - `x-api-key: <key>`
  - `anthropic-version: 2023-06-01`
  - `content-type: application/json`
- Body (conceptual — confirm field names/types against the skill):
  ```json
  {
    "model": "claude-opus-4-8",
    "max_tokens": 4096,
    "stream": true,
    "system": "…(placeholder — omitted when empty)…",
    "tools": [{ "type": "web_search_20260209", "name": "web_search" }],
    "messages": [ { "role": "user", "content": "..." }, ... ]
  }
  ```
- **Streaming:** set `"stream": true` and consume the SSE response via
  `URLSession.bytes(for:)`, parsing `event:` / `data:` lines. Append `text_delta` chunks to the
  current assistant message as they arrive.
- **`max_tokens`:** 4096 is fine for CP1 chat (streaming, so no timeout concern). Don't lowball.

**System prompt (placeholder):** the prompt text lives in `SystemPrompt.swift` as a single
constant. `encodeRequestBody()` attaches it as the top-level `system` field **only when it is
non-empty** — so a blank placeholder sends no `system` field and behaves exactly like having none.
The content is a deliberate stub for CP1; the real Chingu persona/behavior/formatting guidance is a
later-checkpoint job. (This is where a future "reply in plain text, no Markdown" instruction would
go, if formatting is ever handled at the source rather than in the UI.)

**Conversation history:** the API is **stateless** — send the full message thread on every
request (all prior user + assistant turns), not just the latest message. `ChatViewModel` keeps
the array; the client serializes it.

**Web search handling:** because the server-side tool runs on Anthropic's side, the response
stream may include `web_search_tool_result` / `server_tool_use` blocks in addition to text. For
CP1 you only need to **render the final text** to the user (you may ignore citation rendering —
just don't crash on non-text blocks). Confirm the streamed block types via `/claude-api`.

**`pause_turn`:** server-side tools can return `stop_reason: "pause_turn"` if the server loop
hits its limit. If you see it, re-send (message history + the assistant's partial content) to
continue. For CP1 a single continuation is enough; cap continuations (e.g. ≤ 3) to avoid loops.

**Errors to handle gracefully (show in UI, never crash):**
- Missing/empty key → "Set ANTHROPIC_API_KEY (see README)."
- Non-2xx HTTP (401 auth, 429 rate limit, 400 bad request, 5xx) → show a short message with the
  status; `URLSession` already retries nothing, so surface it.
- Network failure / no internet → "Couldn't reach Claude."
- Stream interruption mid-response → keep what arrived, mark the message done.

**Interface (suggested):**
```swift
func streamMessage(history: [Message]) -> AsyncThrowingStream<String, Error>
```
yielding text deltas. The view model accumulates them into the assistant message.

---

### 4.2 `ChatView` + `ChatViewModel` (build second, in a normal window first)

**`Message` model:**
```swift
struct Message: Identifiable {
    let id = UUID()
    enum Role { case user, assistant }
    let role: Role
    var text: String
    var isStreaming: Bool = false
}
```

**`ChatViewModel` (`@MainActor`, `ObservableObject`):**
- `@Published var messages: [Message] = []`
- `@Published var input: String = ""`
- `@Published var isSending: Bool = false`
- `func send()`:
  1. Trim `input`; ignore if empty or already sending.
  2. Append a `user` message; clear `input`.
  3. Append an empty `assistant` message with `isStreaming = true`.
  4. Call `AnthropicClient.streamMessage(history:)`; append each delta to the assistant
     message's `text` on the main actor.
  5. On finish/error: set `isStreaming = false`; on error, set the assistant text to a clear
     error string (or append an error bubble).

  > **As built (post parallel-dev seam).** `send()` is now a thin no-arg wrapper that trims
  > `input`, clears the field, and hands off to `submit(text:image:)` — the single entry point
  > the CP2/CP4 split is built around (see [`PARALLEL-CP2-CP4.md`](PARALLEL-CP2-CP4.md)). The
  > behavior above is unchanged for CP1: `image` defaults to `nil` (text-only) and the
  > `onAssistantResponseComplete` hook defaults to `nil` (no-op). `ChatView`'s `.onSubmit` /
  > Send button still call `model.send`, so the composer is untouched.

**`ChatView` (SwiftUI):**
- A scrollable message list (`ScrollView` + `LazyVStack`, or `List`). User bubbles right-aligned,
  assistant left-aligned — keep styling simple but legible. (Visual polish can lean on the
  `frontend-design` guidance, but don't over-invest in CP1.)
- **Auto-scroll to the newest message** as tokens stream in (`ScrollViewReader` + `.onChange`).
- Bottom: a `TextField` bound to `input`, with **placeholder "Write your question/prompt here"**
  that disappears once the user types (standard `TextField` placeholder behavior covers this).
- **Send on Enter:** `.onSubmit { vm.send() }` on the text field. Enter sends; the field clears.
- **One thread only.** No clear/new-chat control. Fixed-size window (see panel sizing below).
- While `isSending`, you may disable the field or show a subtle indicator — optional.

Get this fully working in a **plain `WindowGroup`** before moving to the panel, so UI bugs are
isolated from panel-focus bugs.

---

### 4.3 The non-activating panel (build third — the crux)

**This is the load-bearing component.** CP2–CP4 depend on the panel never stealing focus.
**As built:** `ChinguPanel.swift` (the `NSPanel` subclass) + the show/hide/position logic in the
app delegate (`main.swift`). (The original spec split this into `OverlayPanel` + `OverlayController`;
the responsibilities are the same, the files differ.)

**`ChinguPanel: NSPanel`** (matches the as-built initializer):
- Style mask includes **`.nonactivatingPanel`** (plus `.titled` + `.fullSizeContentView` for a
  borderless look; title bar hidden, transparent).
- `becomesKeyOnlyIfNeeded = true`
- `isFloatingPanel = true`
- `level = .statusBar` so it sits above other apps.
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` so it appears over
  fullscreen apps and on every Space.
- `hidesOnDeactivate = false`.
- `isOpaque = false`, `backgroundColor = .clear` (SwiftUI draws a custom rounded, blurred card).

**The focus crux (must solve):** a non-activating panel does **not** become key by default, but
the chat `TextField` needs keyboard input. The required behavior:
- Showing the panel must **not** deactivate the app behind it (no `NSApp.activate`).
- The text field must still receive typed characters when the user is interacting with the panel.
- Approach: let the panel **become key when the user actually clicks into the text field**
  (that's what `becomesKeyOnlyIfNeeded` enables) while remaining non-activating, so the
  *application* behind never deactivates even though the panel can take key focus for typing.
  Override `canBecomeKey` to return `true` and `canBecomeMain` to return `false`.
- **Acceptance test (do this manually):** focus another app (e.g. TextEdit) with a visible
  selection/caret; toggle Chingu on; type in Chingu. TextEdit must **not** visibly deactivate,
  and Chingu must receive the keystrokes. This is the single most important thing to verify in
  CP1.

**Positioning (top-center, below the notch):**
- Compute from the active screen's `visibleFrame` / `frame` and `safeAreaInsets` (the notch
  inset lives in `NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea` on notched Macs).
- Center horizontally; place the top edge just below the notch / menu bar.
- Handle the no-notch case (older/external displays) gracefully — sit just below the menu bar.
- Pick the screen with the mouse / key window, or `NSScreen.main`.

**Sizing:** fixed, not resizable. **As built: `420 × 520`** (the SwiftUI `ChatView` owns the frame;
the message list scrolls inside it).

**Show/hide (in the app delegate, `main.swift`):**
- Creates the panel once, hosting `ChatView` via `NSHostingView(rootView:)`.
- `togglePanel()` / `showPanel()` (and `panel.orderOut(nil)` to hide).
- On show: reposition on the current screen, then `panel.orderFrontRegardless()` followed by
  `panel.makeKey()`. `orderFrontRegardless` shows without activating our app; `makeKey()` lets the
  text field accept typing immediately (no click needed) — safe because the panel is
  non-activating, so the app behind stays active. (The spec floated `orderFront` + click-to-focus
  as an alternative; proactive `makeKey()` is the as-built choice for a better first-keystroke UX.)
- One shared `ChatViewModel` persists the thread across hide/show within a session (quitting still
  erases it, per spec).

---

### 4.4 `GlobalHotKey` (build fourth)

- A **system-wide** hotkey that works regardless of the focused app.
- **As built:** Carbon `RegisterEventHotKey` (no dependency), wrapped in
  `GlobalHotKey.swift`. The wrapper is `@MainActor`-isolated and routes the C event callback back
  to a Swift closure by hotkey id; the single hotkey is created once at launch and lives for the
  whole process (no dynamic unregister needed — see the comment in the file if hotkeys ever become
  dynamic).
- On press → the app delegate's `togglePanel()`.
- **Chosen combo: `⌃⌥⌘Space`** (Control-Option-Command-Space) — three modifiers on Space dodges
  `⌘Space` (Spotlight), `⌃Space` (input-source switch), and `⌥⌘Space` (which collided with Finder
  on some setups).
- **Note:** a global hotkey via Carbon/`RegisterEventHotKey` does **not** require the
  Accessibility permission (that's only for event taps / synthetic events, which are a CP3+
  concern). CP1's hotkey works with no TCC prompt.

---

### 4.5 Verify web search (build fifth)

- Ask a question that needs current info (e.g. *"What's the latest stable macOS version?"*).
- Confirm Claude invokes the server-side search and the streamed answer reflects current data.
- Confirm a non-search question (e.g. *"What is 49 × 52 + 10?"*) answers directly without issue.
- You don't need to render citations in CP1 — just don't crash on the search result blocks.

---

## 5. Acceptance criteria (CP1 "done")

All must hold:

1. App builds and launches with **no Dock-stealing window**; no crash when the key is unset
   (shows a "Setup needed" banner in the empty state, and a missing-key message on send, instead).
2. Pressing the global hotkey **toggles** the overlay from within any other app.
3. The overlay appears **top-center, below the notch**, fixed size, floating above other apps.
4. **Focus test passes:** showing the overlay and typing into it does **not** deactivate the app
   behind it, yet keystrokes land in Chingu's text field.
5. Text field shows the placeholder, clears on input, and **sends on Enter**.
6. A question streams a Claude response token-by-token into a scrollable thread; follow-ups work
   and include prior context (stateless history sent each time).
7. A current-info question returns a **web-search-informed** answer.
8. No CP2–CP4 features present. One thread only. Key never committed/logged.

---

## 6. Hand-off when CP1 is built

**Build:** `swift build` (or `./scripts/run.sh build`). **Run:** `./scripts/run.sh`.

**Provide the API key (local demo — `.env`):**
1. `cp .env.example .env`
2. Open `.env` and paste your key(s): `ANTHROPIC_API_KEY=sk-ant-...` (and `ELEVENLABS_API_KEY` is
   optional — CP4, leave blank).
3. `./scripts/run.sh` — the script sources `.env`, exports the vars, reports key **presence only**
   (never values), then launches via `swift run`.
   - Alternative: `export ANTHROPIC_API_KEY="sk-ant-..."` in your shell, then `swift run`.
   - The app **builds and launches without the key**; the empty state shows a "Setup needed"
     banner (and the first send shows a missing-key message) until it's set.

`.env` is gitignored; `.env.example` (placeholders only) is committed. Keys are never hard-coded,
never printed in logs, and only read via `ProcessInfo`.

**Hotkey:** `⌃⌥⌘Space` (Control-Option-Command-Space) toggles the overlay from any app.

**Test:** one plain question (`What is 49 × 52 + 10?`) and one current-info question
(`What's the latest stable macOS version?` — should show "Searching the web…" then a cited answer).
The focus test (§4.3) and hotkey need a real GUI session via `./scripts/run.sh`.

**Deviations from this spec:** SwiftPM executable instead of an Xcode project (§2); flat file
layout with `main.swift` and `Secrets.swift` (§3); `.env` + `scripts/run.sh` for secrets instead
of an Xcode scheme.

---

## 7. Known gotchas (read before building)

- **GUI apps don't inherit your shell `export`s automatically.** Launch via `./scripts/run.sh`
  (which sources `.env` and exports the keys before `swift run`), or `export` in the same shell you
  run `swift run` from. If `ProcessInfo` returns nil, the keys weren't in the launching process's
  environment. The in-app "Setup needed" banner makes this obvious.
- **Non-activating panel + text input is the classic trap.** Spend your debugging time here. The
  combination of `.nonactivatingPanel`, `becomesKeyOnlyIfNeeded`, `canBecomeKey = true`, and
  `canBecomeMain = false` is what makes typing work without activating Chingu. As built, the app
  calls `panel.makeKey()` on show so you can type immediately without an extra click — safe because
  the panel is non-activating. Verify with the focus test in §4.3.
- **SSE parsing:** Anthropic streams Server-Sent Events (`event:` + `data:` lines, JSON bodies).
  Parse line-by-line from `URLSession.bytes`; don't assume one chunk = one event. Accumulate.
- **Don't over-engineer.** No persistence, no settings, no SDK abstractions. Smallest thing that
  meets §5.
- **When unsure about the Anthropic request/response/SSE shape, use `/claude-api`** — never guess
  the API format from memory.
