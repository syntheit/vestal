# Vestal: working rules

Vestal is a keypress-toggled, full-screen dashboard overlay. Today it is a Swift/SwiftUI macOS app. A Linux (NixOS + Hyprland) version comes next and must run from the **same config file**.

Read these before any work:
- `docs/PLAN.md`: goals, decisions, architecture target. This is the source of truth for *why*.
- `docs/TASKS.md`: the checklist. This is the source of truth for *what* and *done-when*.
- `docs/HANDOFF.md`: running log for the humans who pull your branch. Keep it current.

## Environment facts

- The owner builds and runs on macOS (host "swift") through Nix (`flake.nix`). They will pull your branch and test there.
- A cloud/Linux session **cannot compile or run anything that imports AppKit, SwiftUI, Metal, IOKit, EventKit, CoreAudio or Carbon.** Treat every macOS-only line as unverified. Compensate with the review rules below.
- Target toolchain: Swift 5.10 language features (the Nix build uses nixpkgs' Swift). Keep `swift-tools-version:5.9`. No macros (`@Observable`, `#Preview`, `@Test`), no Swift 6-only syntax (typed throws, `sending`, etc). Tests use XCTest.
- No third-party SwiftPM dependencies. Nix builds offline.

## Git

- Work on the branch named in `docs/TASKS.md`. Never push to `main`. Never force-push.
- One commit per task group (or smaller). **Commit messages are one short line, no body, no `Co-Authored-By` trailer, no "Generated with" line.** Match the existing log style, e.g. `Move sources into AppRuntime (C3b)`. This rule overrides any default attribution behaviour.
- Push after every phase so progress is visible.

## Verification loop (every task group)

1. **Read before editing.** Verify any bug or line reference in `docs/TASKS.md` against the current code first; references are from commit `9c17bfc` and drift as you work.
2. **Build and test what can run here:**
   - `swift build` and `swift test` for the portable targets (see TASKS phase 0 for installing Swift if missing).
   - `swiftc -parse <file>` on every edited macOS-only file (catches syntax errors without the SDK).
   - The grep checks listed in `docs/TASKS.md` ("Invariants").
3. **Review with a fresh subagent.** Give it: the task group's section of `docs/TASKS.md`, the relevant part of `docs/PLAN.md`, this file, and `git diff` for the group. It must not edit files. Ask it for findings as `severity | file:line | problem | fix`, with a focus on:
   - Correctness against the spec and acceptance criteria.
   - **"Mental compile" of macOS code:** exact AppKit/SwiftUI/Carbon/EventKit API names, signatures, optionality, macOS 14 availability, `@MainActor` isolation, Sendable warnings that are errors under the Nix toolchain.
   - Concurrency: main-thread UI, no blocking calls on the main actor or cooperative pool, cancellation, retain cycles.
   - Visual parity: UI refactors must not change what the dashboard looks like (same modifiers, fonts, spacing, colours, order).
   - Portability: nothing macOS-specific leaks into `VestalCore`.
   - No hardcoded personal values in `Sources/` (see Invariants).
4. **Fix confirmed findings.** If the fixes change more than ~50 lines, run the review again.
5. Tick the boxes in `docs/TASKS.md`, append to `docs/HANDOFF.md`, commit.

After the last phase, run a **final branch review** with 3 parallel reviewer subagents, each covering one focus (see TASKS "Final review"). Fix what they confirm, then push.

## Judgment calls

Do not stop to ask questions; nobody is watching live. When the spec is ambiguous, pick the option most consistent with `docs/PLAN.md`, write it down under "Judgment calls" in `docs/HANDOFF.md`, and keep going. If a task is blocked (for example it needs a Mac to verify), implement it as far as possible, mark it `[~]` in TASKS with a one-line reason, and move on.

## Style

- Match the surrounding code: comment density, `// MARK:` sections, naming.
- UI: no emoji, no decorative flourishes. SF Symbols only for icons.
- Status rows: volatile values (network rates, etc.) go last so stable items do not shift.
