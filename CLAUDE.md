# CLAUDE.md

Guidance for AI coding agents working in this repo. Read this first, then the spec for whatever
you're building.

## What Chingu is

A Mac-native AI companion (hackathon project). A floating, **non-activating** overlay panel
appears below the notch on a global hotkey; one chat thread streams Claude responses (with web
search). It's built in **checkpoints**, each independently demoable:

- **CP1 (done):** overlay + hotkey + streaming chat + web search. ✅ on `main`.
- **CP2:** capture a screenshot on Enter, send it to Claude as an image.
- **CP3:** on-screen pointing (circles via the Accessibility API). *Comes after CP2.*
- **CP4:** speech in/out via ElevenLabs.

## Build & run

- **Build:** `swift build`  (this is a Swift Package, **not** an Xcode project — no `.xcodeproj`).
- **Run:** `./scripts/run.sh`  (loads `.env`, exports keys, then `swift run Chingu`). Build only:
  `./scripts/run.sh build`.
- **Toolchain:** Swift 6, macOS 14+. `Package.swift` declares one executable target, `Chingu`.
- Keep `swift build` **green before every push** — a broken `main`/branch blocks the other agent.

## Secrets — never commit, log, or hardcode

Keys come from the environment (`ProcessInfo`), loaded from a **gitignored `.env`** by
`scripts/run.sh`. `.env.example` is the tracked template. Access keys only via
`Secrets.value(.anthropic)` / `Secrets.value(.elevenLabs)` — never read the environment directly,
never print a key value. `ANTHROPIC_API_KEY` is required now; `ELEVENLABS_API_KEY` is loaded and
reported at launch but only consumed in CP4.

## Anthropic API — use the skill, never guess

When you touch anything Claude/Anthropic-shaped (request bodies, SSE streaming, image/vision
blocks, tool use, model IDs), invoke the **`/claude-api` skill** for the authoritative current
shape. Do **not** rely on training-prior memory for the API format. The model is
`claude-opus-4-8` (multimodal — handles vision in CP2 with no model change). There is no official
Anthropic Swift SDK; we hand-write the JSON request and parse SSE with `URLSession` (see
`AnthropicClient.swift`).

## Architecture (Sources/Chingu/)

- `main.swift` — `NSApplication` bootstrap (accessory app, no Dock icon), panel positioning,
  hotkey wiring. The app delegate owns the panel and hotkey.
- `ChinguPanel.swift` — the **non-activating `NSPanel`**. This is the load-bearing piece: it shows
  UI and takes keyboard input **without** deactivating the app behind it. CP2–CP4 all depend on
  this. Don't break the focus model.
- `ChatView.swift` / `ChatViewModel.swift` — SwiftUI chat + its `@MainActor` view model (single
  source of truth for the thread). `ChatViewModel` holds the **parallel-dev seams** (see below).
- `AnthropicClient.swift` — an `actor`: builds the request, streams SSE, handles web search +
  `pause_turn`. Owns the in-memory conversation history (one session, no persistence).
- `Secrets.swift` — centralized key loading.
- `SystemPrompt.swift` — placeholder system prompt (intentionally minimal in CP1).
- `GlobalHotKey.swift` — Carbon `RegisterEventHotKey` wrapper. Hotkey: **⌃⌥⌘K**.

## Parallel development (CP2 ∥ CP4) — READ BEFORE CODING

CP2 (screenshots) and CP4 (speech) are built **at the same time by two people** on separate
branches off `main`. The full contract is in **`docs/PARALLEL-CP2-CP4.md`** — its **§0 is the
hard rules for AI agents**. Summary:

- **Stay in your file lane.** New capability → **new file**. Don't grow shared files beyond your
  designated slot. If a change needs the other checkpoint's file, **stop and ask the human**.
- **The seam is a locked contract — don't reshape it.** `ChatViewModel.submit(text:image:)` is the
  single chat entry point; `ChatViewModel.onAssistantResponseComplete` is the reply hook. CP2
  fills the `image`; CP4 calls `submit(text:)` and sets the hook. Don't rename or re-sign either.
- **AppDelegate additions** go in your own `extension AppDelegate { }` (in your own new file), plus
  **at most one line** in `applicationDidFinishLaunching`. Don't refactor the AppDelegate body.
- **Merge order:** CP2 first (it touches the request shape), then CP4 rebases onto it. CP3 branches
  off `main` after CP2 lands.
- **No new SwiftPM dependencies** — CP2 (ScreenCaptureKit) and CP4 (AVFoundation, `URLSession`)
  use system frameworks only. If you think you need a package, stop and ask the human.

## Specs — keep them in sync

- `docs/SPEC.md` — product spec (all checkpoints). `docs/CP1-SPEC.md` / `docs/CP2-SPEC.md` /
  `docs/CP4-SPEC.md` — per-checkpoint build specs. `README.md` — run-level overview.
- **After a code change, update the relevant spec** so docs and code don't drift. This is an
  explicit project requirement.
- Per-agent Cursor handoff prompts live in `handoff/`.

## Conventions

- Match the surrounding code's style, comment density, and idiom. The existing files are
  well-commented; keep that bar.
- Errors surface in the chat UI, never crash (see `AnthropicError` for the pattern).
- One chat thread, no persistence — quitting erases the session. Don't add a "new chat" control.
- **Git:** don't commit, branch, or push unless the human explicitly asks. The humans own the
  branch/merge protocol.

## Known CP1 display bugs (intentionally unfixed)

Raw Markdown renders literally in bubbles, and a missing space can appear when a web-searched
reply spans multiple text blocks. The user chose to leave these for a later pass — don't "fix"
them unprompted.
