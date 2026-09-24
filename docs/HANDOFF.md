# Handoff log

Written by the agent executing `docs/TASKS.md`, read by the owner who pulls the branch and tests on macOS. Keep every section current; newest entries at the top of each section.

## Summary

(One paragraph: which phases are done, what is unverified, and whether the branch is expected to compile on macOS.)

In progress. Phases 0 to 3 done; phase 4 (runtime) in progress. Every macOS file compiles and links here against the macOS 14.4 SDK (see Environment), and CI's `macos` job (macos-14, Xcode 15.4) builds the release app and runs `swift test`, so the branch is expected to compile on macOS; runtime behaviour and the darwin Nix build are unverified (see "Unverified on macOS").

Invariants (TASKS) that still fail, and the phase that clears each:
- `"/tmp` literals: `Sources/VestalCore/AsyncData.swift` (`/tmp/dashboard-cache`, host health and calendar caches) and `Sources/VestalMac/SystemBridge.swift` (CPU ticks, network bytes and the Spotify cache: phase 4 deletes them; the privacy state file `/tmp/.privacy-mode`: phase 5 reads it from config).
- Personal values passed in phase 3: the generic JSON defaults replaced `DefaultConfig`'s Swift values, and the owner's setup is `examples/full.json`.

## Environment

- **macOS compile check on Linux: yes, since phase 2.** The official Swift 5.10.1 Linux toolchain can typecheck *and* compile `VestalCore`, `VestalMac` and `main.swift` for `arm64-apple-macosx14.0` (and `x86_64-…`) against the real macOS 14.4 SDK, the same `apple-sdk_14` store path nixpkgs uses for darwin (`/nix/store/c3xfmn0gi4zss7yzgh2k969xcjjyv5p0-macOS-SDK-14.4`, substituted from cache.nixos.org with `nix-store -r`). Recipe: a private resource dir with symlinks to the toolchain's `lib/swift/clang` and `lib/swift/shims` (the toolchain's Linux `dispatch` module map clashes with the SDK's) plus an `apinotes/os.apinotes` that restores the Darwin-toolchain renames the `os` overlay needs (`OS_os_log`→`OSLog`, `os_log_type_t`→`OSLogType`, `os_signpost_type_t`→`OSSignpostType`, `os_log_type_enabled`→`OSLog.isEnabled(self:type:)`, `_os_log_impl`/`_os_signpost_emit_with_name_impl` SwiftPrivate); then `swiftc -target arm64-apple-macosx14.0 -sdk $SDK -resource-dir $RES -module-name VestalCore -parse-as-library -emit-module -c -wmo Sources/VestalCore/*.swift`, the same for `VestalMac` with `-I` on the first module's output, then `main.swift`. It catches wrong API names, signatures, availability and actor isolation (checked with deliberate errors), and warnings show. It does not run anything or cover XCTest on Darwin. Phase 1 (`deefaee`) and phase 2 both compile this way with zero errors and zero warnings. Since phase 2 the three object files are also linked: `ld64.lld -arch arm64 -platform_version macos 14.0 14.4 -syslibroot $SDK -L $SDK/usr/lib/swift -L $SDK/usr/lib -F $SDK/System/Library/Frameworks -lSystem -rpath /usr/lib/swift <objs>` must report no undefined symbols.

- Swift version used: **5.10.1** (`swift-5.10.1-RELEASE`, x86_64 Linux). `download.swift.org` is blocked by the session's egress proxy, so the official toolchain came from the `swift:5.10.1-noble` Docker Hub image (the toolchain layer, verified against its sha256 digest) and is unpacked at `/opt/swift-official`. nixpkgs' Swift at the `flake.lock` revision is also **5.10.1**, so both toolchains match the Nix build on the Mac.
- nixpkgs' Linux Swift lacks `libIndexStore.so`, so `swift test` (XCTest discovery) only works with the official toolchain. nixpkgs' `swift build` works if `LD_LIBRARY_PATH` includes libdispatch (nixpkgs' own `swift-format` derivation does the same).
- `nix` available: **yes, installed by the agent** (Nix 2.24.10, single-user, `/nix`). GitHub tarball downloads are blocked, so the locked nixpkgs (`d233902…`, NAR hash `sha256-30sZ…BZE=`) was fetched with `git fetch --depth 1` and added to the store by hand; its NAR hash matches `flake.lock` exactly, so flake commands resolve it offline. Binaries come from `cache.nixos.org` (reachable).
- CI results visible to the agent: **yes, since phase 1.** Pushes used to be refused with HTTP 403 (no GitHub App access to `syntheit/vestal`); the owner fixed the access, pushes to `macos-v0.3` now work, and the GitHub Actions runs are readable through the GitHub API. The coordinating agent pushes and checks the `linux` and `macos` jobs after each push, so the macOS job is the real compile check for `VestalMac`.

## Test on the Mac first

Ordered checklist for the owner. Each item is a command plus the expected result. Always include:

0. Get the branch: `git fetch origin macos-v0.3 && git checkout macos-v0.3`.
1. `nix build .#default` or `swift build -c release`: builds. Run `rm -rf .build` first: phase 2 renamed the targets (`Vestal` became `VestalCore`, `VestalMac` and `vestal`), and on a case-insensitive disk a stale `Vestal.build` shadows `vestal.build`.
2. `VESTAL_CONFIG=$PWD/examples/full.json .build/release/vestal`: looks identical to the old dashboard. `.build/release/vestal check-config examples/full.json` prints `examples/full.json: ok`. Without `VESTAL_CONFIG` and without `~/.config/vestal/config.json`, vestal now shows the generic built-in dashboard (no world clocks, no currencies, only this Mac under its hostname); that is intended since phase 3.
3. `vestal toggle` twice: shows then hides; the process stays alive.
4. While hidden, `top -pid $(pgrep -x vestal)` shows ~0% CPU.
5. Edit the config file while it is shown: the dashboard updates within ~1s.

## Unverified on macOS

Every change that could not be compiled or run here, with file:line and what to look for.

Since phase 2 every macOS file is also compiled here against the macOS 14.4 SDK (see Environment), so API names, signatures and actor isolation are checked. What remains unverified is runtime behaviour and the Nix build on the Mac.

### Phase 3 (config)

- **Config file location** (`Sources/VestalCore/ConfigLoader.swift`). `~/Library/Application Support/Vestal/config.json` is no longer read (PLAN drops it). The file is `$VESTAL_CONFIG`, else `$XDG_CONFIG_HOME/vestal/config.json`, else `~/.config/vestal/config.json`. If the Mac has a file at the old path, move it.
- **Startup log** (`Sources/VestalMac/App.swift:16-25`). `log stream --predicate 'process == "vestal"'` shows `[vestal] config <path>: 4 sources, 8 widgets, 1 views, 0 warnings` for `examples/full.json`, then one line per warning. The messages are passed as `NSLog("%@", …)` arguments because they quote config values, which may contain `%`.
- **Local host name** (`Sources/VestalCore/Config.swift`, `LocalHost.shortName`). A local host without `name` shows `gethostname()` up to the first dot. `examples/full.json` still names it `swift`, so only the defaults (no config file) show the Mac's hostname; a long hostname is cut by the 60pt name column.
- **Parse error positions** (`Sources/VestalCore/AnyJSON.swift`, `locate`). On macOS the line and column come from Objective-C `JSONSerialization` (its `NSJSONSerializationErrorIndex`, or else its "around line L, column C" text, whose column counts from 0); Linux was tested. Check: `printf '{\n  "hotkey": x\n}\n' > /tmp/bad.json && vestal check-config /tmp/bad.json` should say `line 2, column 13`. A truncated file may get no position on macOS.
- **Dashboard unchanged.** The views still read the same widget keys (`clock`, `systemBar`, `agenda`, `systems`, `exchange`, `weather`) and ignore `views.main.order`, titles, units, `player`, host `key`, privacy and Claude options until phase 5. Until then the privacy item follows `show` alone and `p` still runs the old hardcoded script, even though check-config already describes the phase 5 rule.

### Phase 2 (package split)

- **Nix build with SwiftPM** (`package.nix`, `flake.nix`). `nix build .#default` on swift. The same `package.nix` builds the CLI on Linux with the pinned nixpkgs (SwiftPM, `--product vestal`, BuildInfo stamped), but darwin differs: the frameworks come from nixpkgs' `apple-sdk` 14.4, and SwiftPM passes its own `-target arm64-apple-macosx14.0` after the one the nixpkgs Swift wrapper adds (the later flag should win; the SDK minimum is 14.0 either way). If it fails, the raw-`swiftc` fallback from TASKS (one invocation per module) is the plan B. Then `./result/bin/vestal version` shows the short commit.
- **App entry** (`Sources/VestalMac/App.swift:15-35`). `VestalApp.run()` now owns the `NSApplication` setup that was top-level code in `main.swift`. It enters the main actor with `MainActor.assumeIsolated` (Swift 5.10 treats synchronous top-level code as nonisolated) and keeps the weakly held delegate alive with `withExtendedLifetime`. Look for: the window appears at launch (a released delegate would mean no window and no error).
- **Platform adapters** (`Sources/VestalMac/MacPlatform.swift:13-52`). Thin classes over the moved `SystemBridge` functions. The dashboard should look exactly as before: CPU/RAM/temperature bars, battery, volume, now playing, privacy icons.
- **System bar strings** (`Sources/VestalMac/SystemBridge.swift:183-196`, `Sources/VestalCore/Formatters.swift`). Uptime (`3d 4h`/`4h 12m`), disk (`245/494GB`), battery time left, the agenda's "in 25m" and the weather's "sets in 2h 5m" are now produced by `Format` (tested byte for byte on Linux). They should read exactly as before.
- **Calendar through `CalendarProvider`** (`MacPlatform.swift:55-94`, `Sources/VestalCore/AsyncData.swift` `getTodayEvents(from:)`). Access request and query now use one `EKEventStore` each, created off the main thread; the request's store is kept alive until the answer arrives. If calendar access was never granted, the prompt still appears and the agenda fills after granting; with access already granted, today's events show as before.
- **HTTP fetches without async URLSession** (`Sources/VestalCore/Runtime.swift:127`, `:247-293`). corelibs Foundation has no `data(for:)`, so every platform now uses `dataTask` plus a continuation (cancelling the task cancels the request). Weather and exchange must still load; `log stream --predicate 'process == "vestal"'` must not show `[vestal] source … fetch failed`.
- **CLI** (`Sources/vestal/main.swift`). `vestal version`, `vestal help`, `vestal toggle|show|hide` behave as before on macOS.
- **Battery time label** (`Sources/VestalMac/DashboardView.swift:410`). It is now `Text(Format.batteryRemaining(minutes:))`, a verbatim `String`; `9c17bfc` passed a string literal, i.e. a `LocalizedStringKey`, whose integer interpolations SwiftUI formats for the locale. Identical in locales with Latin digits (so on swift); only a locale with other digits could render the two differently. Look for: "2h 5m" / "45m" next to the battery percentage, as before.

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

- **Phase 3: `examples/full.json` reproduces `9c17bfc`, not its old defaults' wording.** The exchange widget is titled "Currencies" (the old view ignored the config's "Exchange" and hardcoded "Currencies"). The local host keeps `"name": "swift"` for exact parity; dropping it makes the name follow the hostname, which suits one config shared by swift and mantle. The media widget keeps the key `spotify` (TASKS' order) with type `media`, and `"media": null` deletes the default `media` widget so the merged config has no stray entry. Privacy uses `["bash", "~/.local/bin/toggle-privacy"]` and `/tmp/.privacy-mode`, as phase 1 runs it today (a personal path in an example, not in `Sources/`).
- **Phases 4/5 must expand `~/` in every argv element.** CONFIG.md promises it for command sources and the privacy command, and `examples/full.json` relies on it (`bash` gets the script path as an argument, and bash does not expand `~` there). `CommandRunner` only expands `argv[0]` today; `CommandRunner.expandTilde` is the helper.
- **Decoding never fails as a whole.** A wrong-typed value counts as absent (the key's own default applies; the built-in layer's value was already merged away, which the warning says), and a source, widget, host, world clock or item missing a required key is dropped alone (`Lossy`), each with a check-config warning. Before, one bad value made the whole file fall back to the defaults.
- **Warnings are computed from the merged JSON, next to the decoder** (`ConfigValidator`): per-type key tables in `Config.swift` drive both. Besides TASKS' list they flag wrong JSON types, required keys, duplicate or reserved host keys, order entries listed twice, a missing `views.main`, agenda/weather sources of the wrong kind, and `privacy` listed in `show` without both options. check-config also merges and checks the other OS's `platform` block, tagged `[linux]`/`[macos]`, since the same file serves both machines.
- **check-config exits 1 for an unreadable or missing file too**, not only for a parse error: in both cases the file is not in effect. print-config prints nothing and exits 1 then; otherwise it prints the merged tree before decoding (unknown keys stay visible) with warnings on stderr.
- **print-config has its own pretty printer** (`AnyJSON.prettyPrinted`): two-space indent, sorted keys, `{}`/`[]` for empty containers, the same bytes on both platforms (corelibs' `JSONEncoder` prints empty containers across two lines). Scalars are still escaped by `JSONEncoder`.
- **Removed `fixedLocation` and the widget-level `pick`** along with `extras`: nothing ever read them. They now draw an unknown-key warning.
- **`AnyJSON.matches` compares an int selector with a decimal exactly** (`Int(exactly:)`). The old `Int(o) == i` matched 3.5 against 3 and trapped on a huge value.
- **Parse error positions come from `JSONSerialization`.** JSONDecoder's error has no position on Linux (an internal enum), so after it fails the same bytes go through `JSONSerialization`, whose message or `NSJSONSerializationErrorIndex` gives the offset. "Unexpected end of file" points at the end of the file.
- **The same JSON parses everywhere** (phase 3 review). corelibs accepts a trailing comma (`{"a": 1,}`) and rejects a UTF-8 byte order mark; Darwin does the opposite. vestal rejects trailing commas itself (a string-aware scan before decoding, with line and column) and skips a leading BOM, so check-config on Linux answers for the Mac too.
- **Counts and limits below 1 count as absent** (phase 3 review): `maxEvents`, `days`, `fiveHourLimit` and `weeklyLimit`, with a warning that names the default used. `maxEvents: -1` used to reach `prefix(-1)`, which traps.
- **`XDG_CONFIG_HOME` that is relative is ignored** (the XDG spec says so), and when it is set there is no fallback to `~/.config`. `$VESTAL_CONFIG` gets `~/` expansion.
- **`systemBar.show` absent or empty still means every item**, as the current view does.
- **The hotkey string is only type-checked until phase 6**, when the parser (track B) exists.
- **The fd leak test counts pipes and sockets only.** Under load (another agent's stress run) it failed with a stable +6 fds: `eventpoll`/`eventfd`/`timerfd` triples, the run loops corelibs creates on each dispatch worker thread that spins `waitUntilExit()`. They live with the thread, not the run. The test also waits up to 3s for pipes to close; it still fails when the `waitUntilExit()` fix is removed.
- **Tests read `examples/full.json` and `docs/CONFIG.md`** through `#filePath` (the example must load with zero warnings; CONFIG.md's defaults block must equal `DefaultConfig`, and its complete example must load with zero warnings). A Nix `checks` derivation that runs `swift test` needs `examples/` and `docs/CONFIG.md` in its source fileset.

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

### Phase 3: Config

- `adbbbf1` Load the config in layers over generic JSON defaults. `AnyJSON` holds the whole JSON tree and reports parse errors with line and column. `ConfigLoader` resolves `$VESTAL_CONFIG`, then `$XDG_CONFIG_HOME/vestal/config.json` or `~/.config/vestal/config.json`, and merges defaults, the file and its `platform.<os>` block (objects key by key, lists and scalars replace, `null` deletes). `DefaultConfig` is a generic JSON document. Decoding is permissive (a bad entry drops alone, a wrong type counts as absent) and `ConfigValidator` reports what it ignored. `examples/full.json` is the `9c17bfc` setup. `extras`, `fixedLocation` and the widget-level `pick` are gone.
- `c9689c9` Add check-config and print-config. The core is `ConfigCommands` in VestalCore (tested); exit codes 0 ok, 1 unreadable or unparsable, 2 usage.
- `44c1fb9` Document the config in docs/CONFIG.md. A test keeps its defaults block equal to `DefaultConfig` and loads its complete example with zero warnings.
- `0cf1e28` Count only pipes and sockets in the fd leak test (it failed under another agent's stress run; see Judgment calls).
- `825cb72` Record phase 3 notes in HANDOFF.
- `98dcc14` Address phase 3 review findings (below).
- Review (1 subagent, `91b72cc..825cb72`): 1 medium and 7 low findings, all fixed in `98dcc14`:
  - medium: `maxEvents: -1` decoded as -1 and reached `prefix(-1)`, which traps. Counts and limits below 1 now decode as absent, and the warning names the default used.
  - `ConfigDuration.parse` trapped on overflow (`"999999999999999999m"`), in check-config and at startup. Now it is an invalid duration.
  - "A wrong-typed value counts as absent, so the default applies" only holds for a key's own default: the merge has already replaced the built-in layer's value. CONFIG.md says so, and the warnings now end "treated as absent; the built-in value is not restored".
  - CONFIG.md now says that redefining a default source or widget under its own name keeps the default's other keys, and how to avoid that.
  - Darwin's "around line L, column C" message counts columns from 0; the fallback now adds 1 (the test had the same off-by-one).
  - A leading UTF-8 byte order mark is skipped (Darwin accepted one, corelibs did not).
  - Trailing commas are rejected on every platform, with line and column (corelibs accepted them, Darwin did not); documented.
  - The `examples/full.json` test compares the whole decoded config with a literal built from `9c17bfc`'s `DefaultConfig` plus the documented deltas, so URLs, time zones, refresh intervals and every match, pick and format are pinned.
- Verification: `swift build && swift test` on Linux (133 tests pass); `mac-typecheck` of all three modules against the macOS 14.4 SDK plus the `ld64.lld` link: no errors, no warnings, no undefined symbols. CI run #4 (`825cb72`) is green: `linux`, and `macos` (Xcode 15.4 release build and `swift test`).

### Phase 2: Package split

- `51d7530` Split package into VestalCore and VestalMac. `VestalCore` (Foundation only; config, loader, JSONPath, formatters, runtime, AsyncData fetch/parse logic, ClaudeUsage, CommandRunner, HostKeys, platform protocols and their value types), `VestalMac` (views, `SystemBridge`, `MacPlatform` adapters, `VestalApp.run()`; every file inside `#if os(macOS)`), executable `vestal` (CLI dispatch, then `VestalApp.run()` on macOS). HTTP through a `dataTask` continuation (no async `URLSession` in corelibs). Display strings moved to `Format`, byte for byte.
- `f3c44f7` Treat a missing exchange pick key as empty (see Judgment calls).
- `64f236e` Add VestalCore tests with fixtures. 78 XCTest cases: config decoding and round trips, `AnyJSON.matches`, JSONPath, durations, exchange and weather picking, foyer health, ClaudeUsage, `Format`, `HostKeys`, `CommandRunner` (argv, PATH resolution, timeout and kill, large output, fd leak).
- `913ca0d` Build with SwiftPM in the flake. `package.nix` (SwiftPM, BuildInfo stamped); verified on Linux with the pinned nixpkgs, darwin still `[~]`.
- `fb0b316` Record phase 2 notes in HANDOFF.
- Review (1 subagent, `a17cbb0..fb0b316`): no high or medium findings. Two lows, both resolved in this log: the invariants that still fail were not written down (now under Summary), and the battery time label changed from a `LocalizedStringKey` to a verbatim `String` (kept, noted under "Unverified on macOS", phase 2).
- Verification: `swift build && swift test` on Linux (78 tests pass); `mac-typecheck` of all three modules against the macOS 14.4 SDK with zero errors and warnings; the reviewer also linked the arm64 objects with `ld64.lld` against SDK 14.4: no undefined symbols. CI run #3 (`fb0b316`) is green: `macos` on macos-14 (release build and `swift test`, Xcode 15.4) and `linux`.

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
