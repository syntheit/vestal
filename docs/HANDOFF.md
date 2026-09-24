# Handoff log

Written by the agent executing `docs/TASKS.md`, read by the owner who pulls the branch and tests on macOS. Keep every section current; newest entries at the top of each section.

## Summary

(One paragraph: which phases are done, what is unverified, and whether the branch is expected to compile on macOS.)

In progress. Phases 0 and 1 done; phase 2 (package split) implemented and awaiting review. Every macOS file compiles here against the macOS 14.4 SDK (see Environment), so the branch is expected to compile on macOS; runtime behaviour and the darwin Nix build are unverified (see "Unverified on macOS"). The CI `macos` job is the independent check.

## Environment

- **macOS compile check on Linux: yes, since phase 2.** The official Swift 5.10.1 Linux toolchain can typecheck *and* compile `VestalCore`, `VestalMac` and `main.swift` for `arm64-apple-macosx14.0` (and `x86_64-…`) against the real macOS 14.4 SDK, the same `apple-sdk_14` store path nixpkgs uses for darwin (`/nix/store/c3xfmn0gi4zss7yzgh2k969xcjjyv5p0-macOS-SDK-14.4`, substituted from cache.nixos.org with `nix-store -r`). Recipe: a private resource dir with symlinks to the toolchain's `lib/swift/clang` and `lib/swift/shims` (the toolchain's Linux `dispatch` module map clashes with the SDK's) plus an `apinotes/os.apinotes` that restores the Darwin-toolchain renames the `os` overlay needs (`OS_os_log`→`OSLog`, `os_log_type_t`→`OSLogType`, `os_signpost_type_t`→`OSSignpostType`, `os_log_type_enabled`→`OSLog.isEnabled(self:type:)`, `_os_log_impl`/`_os_signpost_emit_with_name_impl` SwiftPrivate); then `swiftc -target arm64-apple-macosx14.0 -sdk $SDK -resource-dir $RES -module-name VestalCore -parse-as-library -emit-module -c -wmo Sources/VestalCore/*.swift`, the same for `VestalMac` with `-I` on the first module's output, then `main.swift`. It catches wrong API names, signatures, availability and actor isolation (checked with deliberate errors), and warnings show. It does not link, run, or cover XCTest on Darwin. Phase 1 (`deefaee`) and phase 2 both compile this way with zero errors and zero warnings.

- Swift version used: **5.10.1** (`swift-5.10.1-RELEASE`, x86_64 Linux). `download.swift.org` is blocked by the session's egress proxy, so the official toolchain came from the `swift:5.10.1-noble` Docker Hub image (the toolchain layer, verified against its sha256 digest) and is unpacked at `/opt/swift-official`. nixpkgs' Swift at the `flake.lock` revision is also **5.10.1**, so both toolchains match the Nix build on the Mac.
- nixpkgs' Linux Swift lacks `libIndexStore.so`, so `swift test` (XCTest discovery) only works with the official toolchain. nixpkgs' `swift build` works if `LD_LIBRARY_PATH` includes libdispatch (nixpkgs' own `swift-format` derivation does the same).
- `nix` available: **yes, installed by the agent** (Nix 2.24.10, single-user, `/nix`). GitHub tarball downloads are blocked, so the locked nixpkgs (`d233902…`, NAR hash `sha256-30sZ…BZE=`) was fetched with `git fetch --depth 1` and added to the store by hand; its NAR hash matches `flake.lock` exactly, so flake commands resolve it offline. Binaries come from `cache.nixos.org` (reachable).
- CI results visible to the agent: **yes, since phase 1.** Pushes used to be refused with HTTP 403 (no GitHub App access to `syntheit/vestal`); the owner fixed the access, pushes to `macos-v0.3` now work, and the GitHub Actions runs are readable through the GitHub API. The coordinating agent pushes and checks the `linux` and `macos` jobs after each push, so the macOS job is the real compile check for `VestalMac`.

## Test on the Mac first

Ordered checklist for the owner. Each item is a command plus the expected result. Always include:

0. Get the branch: `git fetch origin macos-v0.3 && git checkout macos-v0.3`.
1. `nix build .#default` or `swift build -c release`: builds. Run `rm -rf .build` first: phase 2 renamed the targets (`Vestal` became `VestalCore`, `VestalMac` and `vestal`), and on a case-insensitive disk a stale `Vestal.build` shadows `vestal.build`.
2. `VESTAL_CONFIG=$PWD/examples/full.json .build/release/vestal`: looks identical to the old dashboard.
3. `vestal toggle` twice: shows then hides; the process stays alive.
4. While hidden, `top -pid $(pgrep -x vestal)` shows ~0% CPU.
5. Edit the config file while it is shown: the dashboard updates within ~1s.

## Unverified on macOS

Every change that could not be compiled or run here, with file:line and what to look for.

Since phase 2 every macOS file is also compiled here against the macOS 14.4 SDK (see Environment), so API names, signatures and actor isolation are checked. What remains unverified is runtime behaviour and the Nix build on the Mac.

### Phase 2 (package split)

- **Nix build with SwiftPM** (`package.nix`, `flake.nix`). `nix build .#default` on swift. The same `package.nix` builds the CLI on Linux with the pinned nixpkgs (SwiftPM, `--product vestal`, BuildInfo stamped), but darwin differs: the frameworks come from nixpkgs' `apple-sdk` 14.4, and SwiftPM passes its own `-target arm64-apple-macosx14.0` after the one the nixpkgs Swift wrapper adds (the later flag should win; the SDK minimum is 14.0 either way). If it fails, the raw-`swiftc` fallback from TASKS (one invocation per module) is the plan B. Then `./result/bin/vestal version` shows the short commit.
- **App entry** (`Sources/VestalMac/App.swift:15-35`). `VestalApp.run()` now owns the `NSApplication` setup that was top-level code in `main.swift`. It enters the main actor with `MainActor.assumeIsolated` (Swift 5.10 treats synchronous top-level code as nonisolated) and keeps the weakly held delegate alive with `withExtendedLifetime`. Look for: the window appears at launch (a released delegate would mean no window and no error).
- **Platform adapters** (`Sources/VestalMac/MacPlatform.swift:13-52`). Thin classes over the moved `SystemBridge` functions. The dashboard should look exactly as before: CPU/RAM/temperature bars, battery, volume, now playing, privacy icons.
- **System bar strings** (`Sources/VestalMac/SystemBridge.swift:183-196`, `Sources/VestalCore/Formatters.swift`). Uptime (`3d 4h`/`4h 12m`), disk (`245/494GB`), battery time left, the agenda's "in 25m" and the weather's "sets in 2h 5m" are now produced by `Format` (tested byte for byte on Linux). They should read exactly as before.
- **Calendar through `CalendarProvider`** (`MacPlatform.swift:55-94`, `Sources/VestalCore/AsyncData.swift` `getTodayEvents(from:)`). Access request and query now use one `EKEventStore` each, created off the main thread; the request's store is kept alive until the answer arrives. If calendar access was never granted, the prompt still appears and the agenda fills after granting; with access already granted, today's events show as before.
- **HTTP fetches without async URLSession** (`Sources/VestalCore/Runtime.swift:127`, `:247-293`). corelibs Foundation has no `data(for:)`, so every platform now uses `dataTask` plus a continuation (cancelling the task cancels the request). Weather and exchange must still load; `log stream --predicate 'process == "vestal"'` must not show `[vestal] source … fetch failed`.
- **CLI** (`Sources/vestal/main.swift`). `vestal version`, `vestal help`, `vestal toggle|show|hide` behave as before on macOS.

### Phase 1 (bug fixes)

Line numbers are at `deefaee`, before phase 2 moved the files: `CommandRunner.swift`, `AsyncData.swift` and `Runtime.swift` are now in `Sources/VestalCore/`; the views and `SystemBridge.swift` are in `Sources/VestalMac/`; the app-delegate half of `main.swift` is `Sources/VestalMac/App.swift`. All of these compile for macOS now; the checks below are about behaviour.

- **Fd leak check for the command runner** (`Sources/Vestal/CommandRunner.swift`, the whole file on Darwin). Leave the dashboard open for a few minutes (host health spawns `foyer-api` every 5s): `lsof -p $(pgrep -x vestal) | grep -c PIPE` must stay flat. On Linux the equivalent leak (2 fds per run in corelibs Foundation) is fixed and measured flat over 200 runs; Darwin Foundation is a different implementation.
- **Host popup cancellation** (`Sources/Vestal/DashboardView.swift:184-199`). Open a remote host (its letter), press Esc before it loads, open it again: no "offline" flash. With one host open, press another host's letter: the popup shows "loading…", never the previous host's numbers.
- **Spotify loop and play/pause** (`DashboardView.swift:139-147`, `:43`, `:471`). Click play/pause: the icon flips at once and does not flip back on the next 3s poll. Quit Spotify: the media row disappears within ~3s. If Spotify hangs, CPU/RAM/battery keep updating (they are on the separate "fast" loop).
- **NSAppleScript off the main thread** (`Sources/Vestal/SystemBridge.swift:377-390`). `NSAppleScript` now runs on a background serial queue. Apple does not document it as thread-safe (old docs said main thread only). Look for: now-playing updates, no crash, no Console errors from vestal. If it misbehaves, the fallback is `osascript -e …` through `CommandRunner` (argv, off the main thread).
- **Agenda loop** (`DashboardView.swift:163-171`). With the network off, the agenda still appears right after launch (it no longer waits for weather/exchange).
- **Runtime refresh ordering** (`DashboardView.swift:172`, `:306-312`; `Sources/Vestal/Runtime.swift:133`). Weather and exchange update while the dashboard stays open: set `"refresh": "1m"` on the weather source and watch the temperature/condition change or at least re-render without a relaunch.
- **Host health polling** (`DashboardView.swift:149-156`). `pgrep -fl foyer-api` shows at most one process per host at a time, every 5s (it was every second).
- **Key monitor** (`Sources/Vestal/main.swift:166-185`). A host letter opens its popup; Shift+letter and letter with Caps Lock on do too. Cmd/Ctrl/Option/Fn (Globe) + letter do nothing in vestal. `p` toggles privacy. Two configured hosts with the same initial no longer crash at launch; the second gets its next free letter (`HostKeys`).
- **SIGTERM** (`main.swift:188-196`). `pkill -x vestal` quits cleanly. Side effect to check: `signal(SIGTERM, SIG_IGN)` is inherited by every child (ignored dispositions survive exec), so `foyer-api` and `toggle-privacy` ignore SIGTERM; a timed-out child dies from the SIGKILL one second later. Check that `toggle-privacy` still works and leaves no strays (`pgrep -fl toggle-privacy` empty afterwards).
- **Privacy toggle** (`SystemBridge.swift:278-290`). Press `p` or click the mic/camera icons: `/tmp/.privacy-mode` appears and disappears, and the icon follows within a second. It runs `bash ~/.local/bin/toggle-privacy` (bash from PATH, `/bin/bash` under launchd's minimal PATH). Failures and non-zero exits show in `log stream --predicate 'process == "vestal"'` as `[vestal] toggle-privacy …`.
- **First frame from the runtime cache** (`Sources/Vestal/AsyncData.swift:39-56`). Quit, turn the network off, relaunch: weather and exchange render at once from `~/Library/Caches/Vestal/*.json`.
- **Foyer through argv** (`AsyncData.swift:301-335`, `:412-422`). Hosts show health when `foyer-api` is only on the Nix profile path and vestal runs under launchd (minimal PATH).
- **Calendar cache as JSON** (`AsyncData.swift:557-567`). An event titled `a | b` renders intact. An old pipe-format `/tmp/dashboard-cache/calendar` fails to decode, which reads as "no cache" and re-queries EventKit.

## Judgment calls

Decisions made without the owner, and why.

- **Platform protocols are thin adapters over the moved `SystemBridge` code.** TASKS says to move the Mach/SMC/IOKit/CoreAudio/AppleScript code, not rewrite it. `SystemBridge` moved to `VestalMac` nearly unchanged (it returns the portable value types now); `MacPlatform` wraps it in `SystemStatsProvider`, `MediaProvider`, `AudioProvider` and `PrivacyProvider` classes, and the EventKit code from `AsyncData` became `EventKitCalendar`. Phase 4 moves the CPU/network deltas into the stats instance, which is when the code itself should move into the class.
- **More display strings moved to `Format` than the minimum.** Besides uptime, disk and rates, the battery time left, the agenda's "in 25m" and the weather's sun context are pure functions of numbers and times, so they moved too and are covered by tests. Output is byte-identical.
- **A missing exchange pick key renders as empty.** Writing the tests showed that an item whose `picks` lacked `buy` or `sell` resolved an empty path, i.e. the whole matched object, and rendered its dictionary dump. A missing key now gives "". An explicit `""` path still means "the element itself". Configs with both keys (all real ones) are unaffected.
- **Executable target `vestal` in `Sources/vestal/`, as TASKS lays out.** On a case-insensitive disk that directory name only differs in case from the old `Sources/Vestal/`; git handles the checkout, and a stale `.build` should be removed once (see "Test on the Mac first").
- **`VestalApp.run()` claims the main actor with `MainActor.assumeIsolated`.** Verified on Linux with Swift 5.10.1: synchronous top-level code is nonisolated, so calling a `@MainActor` entry point from `main.swift` is a compile error. The old code only compiled because AppKit's isolation is imported as preconcurrency.
- **Linux `vestal`.** `version` and `help` work. Bare `vestal` and `toggle|show|hide` print that the dashboard is macOS-only and exit 1, rather than relaunching a binary that can't show anything.
- **Linux cache dir now, not in phase 4.** `SourceCache` used `~/Library/Caches/Vestal` everywhere; on Linux it is now `$XDG_CACHE_HOME/vestal` (default `~/.cache/vestal`), as PLAN specifies. macOS is unchanged.
- **`CalendarProvider.events(from:to:calendars:)` already takes the name filter** that phase 3's `calendars` option needs. The app passes `nil` (all calendars, as before).
- **Tests use only public API** (no `@testable import`), so `swift test -c release` works too, which nixpkgs' `swiftpm` check phase uses if phase 7 enables it. Fixtures are written from the fields the code reads, with neutral values (a Lisbon weather report, a made-up foyer host); nothing was fetched.
- **The flake calls a `package.nix`** (`pkgs.callPackage ./package.nix { commit = …; }`) instead of an inline derivation, so the Linux proof built the exact committed file, and phase 7's Linux outputs can reuse it. Its source is a `lib.fileset` of `Package.swift`, `Sources` and `Tests`, so docs edits don't rebuild. `meta.platforms` stays darwin until phase 7.

- **Phase 1 regression tests landed in phase 2.** TASKS wants a regression test per Linux-testable fix, but in phase 1 the only target imported AppKit, so nothing could be built or tested on Linux. The tests for `HostKeys` and `CommandRunner` were written with `VestalCoreTests` in phase 2. Until then each fix carries a comment stating its invariant.
- **Privacy toggle runs `bash <script>`.** Parity with the old `/bin/bash script` call: the script needs neither a shebang nor the executable bit. `bash` is resolved on PATH plus the Nix/Homebrew dirs (the invariant only forbids a hardcoded `/bin/bash` and `bash -c`). The script path is an argument, not argv[0], so its `~` is expanded before the call.
- **Superseded fetches are dropped, not cancelled.** Play/pause and runtime refreshes use generation counters: a result that started before the latest click or refresh is discarded. Cancelling instead would have hit `waitForData`, which spun flat out on cancellation; that loop now also returns `nil` when cancelled.
- **Caps Lock does not block host keys.** Only Shift and Caps Lock are allowed with a host or privacy letter; every other device-independent modifier (Cmd, Ctrl, Option, Fn/Globe, ...) passes the key through.

- **CI stays on `macos-14` for now, but it has an expiry date.** GitHub retires the `macos-14` image on 2026-11-02 (brownouts that fail jobs from 2026-10-05; see actions/runner-images#13518). TASKS asks for `macos-14`, and it is the only hosted image with Xcode 15.4, i.e. Swift 5.10, the Nix toolchain. The job pins it through `DEVELOPER_DIR` and asserts `Swift version 5.10`, so it fails loudly rather than drifting to a newer compiler. When the image goes away: set `runs-on: macos-15` and point `DEVELOPER_DIR` at its oldest Xcode (16.0, Swift 6.0 in Swift 5 mode), and drop the version assert. That compiler accepts a few Swift 6-only constructs that the 5.10 Nix build rejects, so a `nix build .#default` job would be the faithful long-term check.
- **CI workflow kept in `.github/workflows/ci.yml`.** TASKS says to move it to `docs/ci.yml` only if the push fails for lack of the `workflow` scope. Here every push fails (no repo access at all), so that rule never triggered and the file stays where GitHub expects it. The Linux job uses the official `swift:5.10` container; the macOS job selects Xcode 15.4 (Swift 5.10) when the runner has it, and also runs `swift test` so Darwin Foundation differences in `VestalCore` show up.

## Phase log

Per phase: commits, what changed, review findings and how they were resolved.

### Phase 1: Bug fixes

- `6674685` Add argv command runner and collision-free host keys. `CommandRunner.run(argv:timeout:environment:)`: `Process` with an argv array, executable resolved on `PATH` plus `~/.nix-profile/bin`, `/etc/profiles/per-user/$USER/bin`, `/run/current-system/sw/bin`, `/opt/homebrew/bin`, `/usr/local/bin` (the child gets the same PATH); stdout and stderr drained concurrently by dispatch read sources; timeout and task cancellation send SIGTERM, then SIGKILL after 1s. `HostKeys.assign`: first free letter of each host name, `p` and `i` reserved.
- `4b01997` Fix shell injection, pipe deadlock, polling storm, stale and dead caches. Foyer health goes through `CommandRunner` with argv `["foyer-api","--host",url,"/api/health"]`; `shell()` and every `bash -c`/`/bin/bash` are gone. Host health polls every 5s instead of 1s. The pipe-format weather/exchange caches are deleted; the first frame reads `AppRuntime`'s disk cache. The runtime posts `runtimeSourceUpdated` after each fetch and the view re-reads weather and exchange. Spotify's AppleScript runs on a background serial queue. The calendar cache is JSON.
- `a744c23` Fix host key crash, modifier shortcuts and SIGTERM handler. Host keys from `HostKeys`; shortcuts ignore modified keystrokes; SIGTERM through `DispatchSource.makeSignalSource` after `signal(SIGTERM, SIG_IGN)`.
- `ea73400` README: macOS 14.
- `deefaee` Address phase 1 review findings (below).
- Review (1 subagent), findings and resolutions:
  - A cancelled host-detail fetch returned `ok:false` and painted a false "offline"; switching hosts showed the old host's numbers. Fixed: re-check `!Task.isCancelled && expandedHost == host` after the fetch, reset the detail when the host changes.
  - corelibs Foundation 5.10 leaked 2 fds per `CommandRunner` run on Linux (the `Process` stays alive until `waitUntilExit()`). Fixed: call it on non-Darwin after the exit; measured flat over 200 runs.
  - `CommandRunner` comments now say that on Linux the "child exited, grandchild holds the pipes" path cannot trigger (exit is detected through a socketpair the descendants inherit) and that SIGTERM is often blocked in children spawned from Dispatch threads, so SIGKILL does the work.
  - The privacy toggle ran the script as argv[0] (needed +x and a shebang, unlike the old `/bin/bash script`) and swallowed errors. Now `bash <expanded path>`, with launch failures and non-zero exits logged.
  - Spotify's AppleScript could stall the stats loop, and slow runtime sources delayed the agenda. Each now has its own `.task` loop (3s and 300s).
  - A Spotify poll started before a play/pause click could revert the optimistic icon; overlapping runtime refreshes could finish out of order. Fixed with generation counters (no cancellation, see Judgment calls).
  - Fn/Globe+letter opened hosts. The key monitor now rejects every device-independent modifier except Shift and Caps Lock.
  - Comments tripped the invariant greps (`@Observable` in `Runtime.swift`, `harbor` in `DashboardView`/`AsyncData`). Reworded.
- Verification here: `swiftc -parse` on every edited file; `swiftc -typecheck` of the portable files (`CommandRunner`, `HostKeys`, `Config*`, `JSONPath`, `Formatters`, `BuildInfo`, `ClaudeUsage`) on Linux; the fd-leak harness above. `Runtime.swift` still fails to typecheck on Linux (`URLSession` needs `FoundationNetworking` and has no async `data(for:)` in corelibs 5.10); phase 2 fixes that. The macOS-only changes are listed under "Unverified on macOS".

### Phase 0: Setup

- `5c3ae65` Add CI workflow (linux build+test, macos release build). Separate commit, as TASKS asks.
- Branch `macos-v0.3` created from `main` (`9c603b5`).
- `Harden CI workflow`: review follow-ups (pin Xcode loudly, skip `swift test` until a test target exists, `checkout@v5`, 30-minute job timeouts). Until phase 2 the Linux job is expected to fail on `import AppKit`.
- Review (1 subagent): 5 findings, all taken (see above and the `macos-14` judgment call).
- Baseline: `swift build` on Linux at `9c603b5` fails immediately: `Sources/Vestal/main.swift:1:8: error: no such module 'AppKit'` (and the emit-module step fails). Nothing in the package is buildable on Linux, which is why phase 2 exists.
