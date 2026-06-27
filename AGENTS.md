# AGENTS.md

Cross-tool guidance for AI coding agents (Cursor, etc.) working in this repo. **The full
guidance lives in [`CLAUDE.md`](CLAUDE.md)** — read it first. This file is the same contract in
brief, for tools that look for `AGENTS.md`.

## TL;DR

**Chingu** is a Mac-native AI companion (hackathon project): a non-activating overlay panel below
the notch, toggled by a global hotkey, streaming Claude responses with web search. Built in
checkpoints — **CP1 (chat) is done**; **CP2 (screenshots)** and **CP4 (speech)** are being built
in parallel right now; CP3 (pointing) comes after CP2.

## Build & run

- Build: `swift build` (Swift Package, **not** Xcode — Swift 6, macOS 14+).
- Run: `./scripts/run.sh` (loads `.env`, then `swift run Chingu`).
- Keep `swift build` **green before every push**.

## The rules that matter most

1. **Read your spec first.** `docs/PARALLEL-CP2-CP4.md` (§0 = hard rules for agents) →
   `docs/CP2-SPEC.md` or `docs/CP4-SPEC.md` → `docs/SPEC.md`. Per-agent Cursor prompts are in
   `handoff/`.
2. **Stay in your file lane.** New capability → new file. Don't edit the other checkpoint's files.
   If you think you must, **stop and ask the human.**
3. **Don't reshape the locked seam.** `ChatViewModel.submit(text:image:)` (chat entry) and
   `ChatViewModel.onAssistantResponseComplete` (reply hook). CP2 fills `image`; CP4 calls
   `submit(text:)` + sets the hook. Don't rename or re-sign them.
4. **Anthropic/Claude code → use the `/claude-api` skill, never guess.** Model is
   `claude-haiku-4-5`. No Swift SDK; hand-written JSON + `URLSession` SSE.
5. **Secrets:** only via `Secrets.value(...)`. Never hardcode, print, or commit a key. `.env` is
   gitignored.
6. **No new SwiftPM dependencies** — system frameworks only. Ask the human if you think otherwise.
7. **Don't run git** (commit/branch/push) unless the human asks. Merge order: CP2 → then CP4
   rebases.
8. **Keep specs in sync** — update the relevant `docs/*-SPEC.md` after a code change.

See [`CLAUDE.md`](CLAUDE.md) for architecture, file-by-file notes, and the known-issues list.
