# Handoff log

Written by the agent executing `docs/TASKS.md`, read by the owner who pulls the branch and tests on macOS. Keep every section current; newest entries at the top of each section.

## Summary

(One paragraph: which phases are done, what is unverified, and whether the branch is expected to compile on macOS.)

## Environment

- Swift version used:
- `nix` available:
- CI results visible to the agent:

## Test on the Mac first

Ordered checklist for the owner. Each item is a command plus the expected result. Always include:

1. `nix build .#default` or `swift build -c release`: builds.
2. `VESTAL_CONFIG=$PWD/examples/full.json .build/release/vestal`: looks identical to the old dashboard.
3. `vestal toggle` twice: shows then hides; the process stays alive.
4. While hidden, `top -pid $(pgrep -x vestal)` shows ~0% CPU.
5. Edit the config file while it is shown: the dashboard updates within ~1s.

## Unverified on macOS

Every change that could not be compiled or run here, with file:line and what to look for.

## Judgment calls

Decisions made without the owner, and why.

## Phase log

Per phase: commits, what changed, review findings and how they were resolved.
