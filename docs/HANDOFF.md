# Handoff log

Written by the agent executing `docs/TASKS.md`, read by the owner who pulls the branch and tests on macOS. Keep every section current; newest entries at the top of each section.

## Summary

(One paragraph: which phases are done, what is unverified, and whether the branch is expected to compile on macOS.)

In progress. Phase 0 done.

## Environment

- Swift version used: **5.10.1** (`swift-5.10.1-RELEASE`, x86_64 Linux). `download.swift.org` is blocked by the session's egress proxy, so the official toolchain came from the `swift:5.10.1-noble` Docker Hub image (the toolchain layer, verified against its sha256 digest) and is unpacked at `/opt/swift-official`. nixpkgs' Swift at the `flake.lock` revision is also **5.10.1**, so both toolchains match the Nix build on the Mac.
- nixpkgs' Linux Swift lacks `libIndexStore.so`, so `swift test` (XCTest discovery) only works with the official toolchain. nixpkgs' `swift build` works if `LD_LIBRARY_PATH` includes libdispatch (nixpkgs' own `swift-format` derivation does the same).
- `nix` available: **yes, installed by the agent** (Nix 2.24.10, single-user, `/nix`). GitHub tarball downloads are blocked, so the locked nixpkgs (`d233902…`, NAR hash `sha256-30sZ…BZE=`) was fetched with `git fetch --depth 1` and added to the store by hand; its NAR hash matches `flake.lock` exactly, so flake commands resolve it offline. Binaries come from `cache.nixos.org` (reachable).
- CI results visible to the agent: **no.** Every `git push` to `syntheit/vestal` is refused with HTTP 403 ("Claude doesn't have GitHub access to syntheit/vestal for your organization"), for `macos-v0.3` and for the session branch alike. Read access (`git ls-remote`) works. Without a push, GitHub Actions never runs, so the macOS job could not be used as a compile check. All work is committed locally on `macos-v0.3`; the fix is to reconnect GitHub / install the Claude GitHub App for the repo (see "Test on the Mac first", step 0 for how to get the branch without a push).

## Test on the Mac first

Ordered checklist for the owner. Each item is a command plus the expected result. Always include:

0. Get the branch. If `git fetch origin macos-v0.3` finds nothing, the agent could not push (see Environment); use the git bundle attached to the session instead: `git fetch /path/to/vestal-macos-v0.3.bundle macos-v0.3:macos-v0.3`.
1. `nix build .#default` or `swift build -c release`: builds.
2. `VESTAL_CONFIG=$PWD/examples/full.json .build/release/vestal`: looks identical to the old dashboard.
3. `vestal toggle` twice: shows then hides; the process stays alive.
4. While hidden, `top -pid $(pgrep -x vestal)` shows ~0% CPU.
5. Edit the config file while it is shown: the dashboard updates within ~1s.

## Unverified on macOS

Every change that could not be compiled or run here, with file:line and what to look for.

## Judgment calls

Decisions made without the owner, and why.

- **CI workflow kept in `.github/workflows/ci.yml`.** TASKS says to move it to `docs/ci.yml` only if the push fails for lack of the `workflow` scope. Here every push fails (no repo access at all), so that rule never triggered and the file stays where GitHub expects it. The Linux job uses the official `swift:5.10` container; the macOS job selects Xcode 15.4 (Swift 5.10) when the runner has it, and also runs `swift test` so Darwin Foundation differences in `VestalCore` show up.

## Phase log

Per phase: commits, what changed, review findings and how they were resolved.

### Phase 0: Setup

- `5c3ae65` Add CI workflow (linux build+test, macos release build). Separate commit, as TASKS asks.
- Branch `macos-v0.3` created from `main` (`9c603b5`).
- Baseline: `swift build` on Linux at `9c603b5` fails immediately: `Sources/Vestal/main.swift:1:8: error: no such module 'AppKit'` (and the emit-module step fails). Nothing in the package is buildable on Linux, which is why phase 2 exists.
