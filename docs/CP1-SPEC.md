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
- No Chingu-specific system prompt / persona layer — plain chat for now.
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
| Global hotkey | Carbon `RegisterEventHotKey`, **or** the `HotKey` SwiftPM package (thin wrapper — acceptable) |
| Networking | `URLSession` (native) — **no Alamofire, no third-party HTTP** |
| AI | Claude `claude-opus-4-8`, Anthropic **Messages API**, raw HTTPS (no Swift SDK exists) |
| Streaming | SSE over `URLSession.bytes(for:)` |
| Web search | Server-side tool `web_search_20260209` declared in the request |
| Secret | `ANTHROPIC_API_KEY` from `ProcessInfo.processInfo.environment` |

Minimum target: **macOS 13+** is fine for CP1 (ScreenCaptureKit's 14+ requirement is a CP2
concern). Use a recent Swift toolchain.

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

Keep it small. A reasonable layout (adapt names as needed, but keep these responsibilities
separate):

```
Chingu/
  ChinguApp.swift          — @main app entry, activation policy, wiring
  AppDelegate.swift        — NSApplicationDelegate: owns panel + hotkey lifecycle
  Overlay/
    OverlayPanel.swift     — the non-activating NSPanel subclass + positioning
    OverlayController.swift — shows/hides/toggles the panel, hosts SwiftUI via NSHostingView
  Hotkey/
    HotkeyManager.swift    — registers the global hotkey, calls a toggle closure
  UI/
    ChatView.swift         — SwiftUI: message list + input field
    ChatViewModel.swift    — @MainActor ObservableObject: holds messages, drives the API
    Message.swift          — model: id, role (user/assistant), text, isStreaming
  API/
    AnthropicClient.swift  — builds the request, streams the SSE response, yields deltas
    AnthropicModels.swift  — Codable request/response/SSE-event structs
```

**State ownership:** `ChatViewModel` is the single source of truth for the message thread and
the in-flight request. `OverlayController` owns the panel. `HotkeyManager` owns the hotkey and
just calls `OverlayController.toggle()`. `AnthropicClient` is stateless except for the request
it's currently streaming.

**Build order (sequential — test each before the next):**
1. API client → 2. Chat UI in a normal window → 3. Move UI into the non-activating panel →
4. Global hotkey → 5. Verify web search end-to-end.

---

## 4. Component specs

### 4.1 `AnthropicClient` (build first)

**Responsibility:** read the key, build a Messages API request to `claude-opus-4-8`, stream the
response, surface text deltas to the caller, handle web-search tool blocks gracefully.

**Key loading:**
```swift
guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
      !apiKey.isEmpty else {
    // Surface a clear, user-visible error in the chat UI — DO NOT crash.
    throw ChinguError.missingAPIKey
}
```
Never log, print, or hard-code the key.

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
    "tools": [{ "type": "web_search_20260209", "name": "web_search" }],
    "messages": [ { "role": "user", "content": "..." }, ... ]
  }
  ```
- **Streaming:** set `"stream": true` and consume the SSE response via
  `URLSession.bytes(for:)`, parsing `event:` / `data:` lines. Append `text_delta` chunks to the
  current assistant message as they arrive.
- **`max_tokens`:** 4096 is fine for CP1 chat (streaming, so no timeout concern). Don't lowball.

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

### 4.3 `OverlayPanel` + `OverlayController` (build third — the crux)

**This is the load-bearing component.** CP2–CP4 depend on the panel never stealing focus.

**`OverlayPanel: NSPanel`:**
- Init with style mask including **`.nonactivatingPanel`** (plus `.titled`/`.fullSizeContentView`
  as needed for a borderless look; hide the title bar).
- `becomesKeyOnlyIfNeeded = true`
- `isFloatingPanel = true`
- `level = .floating` (or higher, e.g. `.statusBar`-level) so it sits above other apps.
- `collectionBehavior` includes `.canJoinAllSpaces` and `.fullScreenAuxiliary` so it appears
  over fullscreen apps and on every Space.
- `hidesOnDeactivate = false`.
- Background: transparent/blurred as desired; `isOpaque = false`,
  `backgroundColor = .clear` if doing a custom rounded card.

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

**Sizing:** fixed width and height (the spec says fixed-size, scrollable history). Pick a
sensible size (e.g. ~`520 × 360`); the message list scrolls inside it. Don't make it resizable.

**`OverlayController`:**
- Creates the panel once, hosts `ChatView` via `NSHostingView(rootView:)`.
- `show()` / `hide()` / `toggle()`.
- On `show()`: position on the current screen, `orderFront(nil)` (or `makeKeyAndOrderFront` only
  if needed for the text field — prefer `orderFront` + click-to-focus to avoid activating).
- The `ChatViewModel` should be created once and shared (so the thread persists across
  hide/show within a session — quitting still erases it, per spec).

---

### 4.4 `HotkeyManager` (build fourth)

- Register a **system-wide** hotkey that works regardless of the focused app.
- Implementation: Carbon `RegisterEventHotKey` (no dependency) **or** the `HotKey` SwiftPM
  package (simpler; acceptable to add as the one dependency).
- On press → call `OverlayController.toggle()`.
- Pick a default combo unlikely to collide (e.g. `⌥⌘Space` / `Option-Command-Space`, or
  `⌃Space` if not taken). State the chosen combo in the run instructions.
- Unregister cleanly on quit.
- **Note:** a global hotkey via Carbon/`RegisterEventHotKey` does **not** require the
  Accessibility permission (that's only for event taps / synthetic events, which are a CP3+
  concern). CP1's hotkey should work with no TCC prompt.

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
   (shows a clear "set ANTHROPIC_API_KEY" message instead).
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

1. Confirm the project **builds**.
2. **Tell the user to paste their API key** with exact steps:
   - **Xcode project:** Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables
     → add `ANTHROPIC_API_KEY` = their key. Ensure the scheme is **not Shared** (Manage Schemes →
     uncheck Shared) so the key stays in local `xcuserdata/` (gitignored).
   - **SwiftPM / terminal run:** `export ANTHROPIC_API_KEY="sk-ant-..."` then run.
   - Make clear the app **builds and launches without the key**, but the first message shows a
     "key missing" notice until it's set.
3. State: how to run it, the chosen hotkey combo, and one plain-question + one web-search-question
   to test.
4. Note any deviations from this spec and why.

---

## 7. Known gotchas (read before building)

- **Xcode-launched apps don't inherit shell `export`s.** If `ProcessInfo` returns nil when run
  from Xcode, the key must be set in the **scheme's** Environment Variables, not just `~/.zshrc`.
  Surface a clear in-app message when the key is missing so this is obvious.
- **Non-activating panel + text input is the classic trap.** Spend your debugging time here. The
  combination of `.nonactivatingPanel`, `becomesKeyOnlyIfNeeded`, `canBecomeKey = true`, and
  `canBecomeMain = false` is what makes typing work without activating Chingu. Verify with the
  focus test in §4.3.
- **SSE parsing:** Anthropic streams Server-Sent Events (`event:` + `data:` lines, JSON bodies).
  Parse line-by-line from `URLSession.bytes`; don't assume one chunk = one event. Accumulate.
- **Don't over-engineer.** No persistence, no settings, no SDK abstractions. Smallest thing that
  meets §5.
- **When unsure about the Anthropic request/response/SSE shape, use `/claude-api`** — never guess
  the API format from memory.
