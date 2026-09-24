# Vestal: macOS completion tasks

Branch: **`macos-v0.3`** (create it from `main`). Rules for building, reviewing and committing are in `/CLAUDE.md`. The reasons behind every decision are in `docs/PLAN.md`.

Legend: `[ ]` todo, `[x]` done and reviewed, `[~]` done as far as possible here but needs a Mac to verify (add a one-line reason).

Line references are from commit `9c17bfc`. Verify them before acting.

**Overall done-when:** running `examples/full.json` on macOS looks and behaves exactly like the dashboard at `9c17bfc`, except for the fixed bugs. The app stays resident, toggles over the socket, reloads its config live, and everything portable builds and passes tests on Linux.

---

## Invariants (check after every phase)

Each command must print nothing:

```sh
grep -rnE 'matv\.io|syntheit|dolarapi|Buenos_Aires|harbor|raven|conduit' Sources/     # personal values only in examples/
grep -rnE '/bin/bash|bash -c' Sources/
grep -rn '"/tmp' Sources/
grep -rlE '^import (AppKit|SwiftUI|Metal|MetalKit|IOKit|EventKit|CoreAudio|Carbon|QuartzCore)' Sources/VestalCore
grep -rnE '@Observable|#Preview|@Test\b' Sources/ Tests/
for f in Sources/VestalMac/*.swift; do head -5 "$f" | grep -q '#if os(macOS)' || echo "missing guard: $f"; done
```

Also: `swift build && swift test` pass on Linux.

---

## Phase 0: Setup

- [x] Create branch `macos-v0.3` from `main`.
- [x] Swift toolchain: if `swift --version` fails, install Swift **5.10.x** for this Linux distro (swift.org tarball or `swiftly`). Record the version in HANDOFF. If installing is impossible, record that and rely on `swiftc -parse` plus review.
- [x] Check whether `nix` is available (`nix --version`). If it is, use `nix flake check` / `nix eval` in phase 7. If not, record that.
- [x] Baseline: note in HANDOFF what `swift build` does on Linux today (expected to fail on AppKit). This proves why phase 2 is needed.
- [x] Add `.github/workflows/ci.yml`:
  - Job `linux`: ubuntu-latest, Swift 5.10, runs `swift build` and `swift test`.
  - Job `macos`: macos-14, runs `swift build -c release` (full app).
  - Trigger on push and pull_request.

  **Commit this workflow as its own separate commit.** If a push is rejected because the token lacks the `workflow` scope, drop that commit (`git rebase` it out, no force-push to shared branches is needed since the branch is new), move the file to `docs/ci.yml`, and note it in HANDOFF.
- [~] If you can read CI results (e.g. `gh run list`/`gh run view`, or the GitHub API), use the macOS job as a real compile check after every push. Record in HANDOFF whether this worked. *(Every push is refused with 403, so CI never ran; see HANDOFF Environment.)*

## Phase 1: Bug fixes (on the current layout, before moving files)

Each fix gets a regression test if the code is testable on Linux; otherwise add a comment explaining the invariant.

- [x] **Launch crash on duplicate host initials.** `main.swift:96` builds `Dictionary(uniqueKeysWithValues:)` from host first letters. Two hosts starting with the same letter crash at launch. Fix: the first unused letter wins, and later hosts try their next letters. An optional per-host `key` in config comes in phase 5. The keys `p` (privacy), `i` (info) and Escape are reserved and must never map to a host.
- [x] **Modifier keys.** Host shortcuts fire even with Cmd/Ctrl/Option held. Only unmodified letters (Shift allowed) should trigger hosts.
- [x] **Host health polling storm.** `DashboardView.swift:130-135` calls `getServers(useCache:false)` every **1s**, which spawns one `foyer-api` per host per second. Make it 5s (config comes in phase 4). Health polling must stop while the dashboard is hidden (phase 6 finishes this).
- [x] **`shell()` pipe deadlock.** `AsyncData.swift:~590-606` reads stdout only after the child exits. Output bigger than the pipe buffer (~64KB) blocks the child, the call times out, and the host shows offline. Read stdout concurrently (readabilityHandler or read-to-end on a background queue) and wait for exit with a timeout that kills the child.
- [x] **Shell injection and `/bin/bash`.** `AsyncData.swift:316,424` interpolate the config URL into `bash -c`, and `AsyncData.swift:593`/`SystemBridge.swift:278` hardcode `/bin/bash`. NixOS has no `/bin/bash`. Replace them with a `runCommand(argv:timeout:)` helper that uses `Process` with an argv array and resolves the executable on `PATH` plus `~/.nix-profile/bin`, `/etc/profiles/per-user/$USER/bin`, `/run/current-system/sw/bin`, `/opt/homebrew/bin`, `/usr/local/bin`. Put the helper in a portable file; it moves to `VestalCore` in phase 2.
- [x] **Unsafe SIGTERM handler.** `main.swift:180` uses `signal()` with a closure that calls Dispatch, which is not async-signal-safe. Use `DispatchSource.makeSignalSource` (with `signal(SIGTERM, SIG_IGN)` first). Phase 6 reuses this for SIGHUP.
- [x] **Dead legacy caches.** `getCachedWeather/parseWeather` and `getCachedExchange/parseExchange` read pipe-format files that nothing has written since C3a. Delete them. The first frame should render from `AppRuntime`'s disk cache (`~/Library/Caches/Vestal/*.json`) synchronously if it's present.
- [x] **Slow data never refreshes.** The `slow` task in `DashboardView.swift:137-147` runs once, so weather, exchange and agenda go stale while the dashboard is open. The proper fix comes in phase 4. For now, re-read runtime snapshots whenever the runtime reports new data (a simple callback is fine).
- [x] **Spotify AppleScript on the main thread.** `DashboardView.swift:261` runs `NSAppleScript` every 3s on the main actor. Move it to a background serial queue and publish the result on main.
- [x] **Calendar cache format.** It breaks on titles containing `|` or a newline. Phase 4 replaces it; if you touch it earlier, use JSON.
- [x] README says macOS 13+; `Package.swift` says 14. Make the README say 14.

Commit per logical fix or small group. Review, then push.

## Phase 2: Split into `VestalCore` and `VestalMac`

Target layout:

```
Package.swift
Sources/VestalCore/     portable: Foundation only (+ FoundationNetworking on Linux via #if canImport)
Sources/VestalMac/      macOS UI + platform impls; every file wrapped in #if os(macOS) ... #endif
Sources/vestal/main.swift   entry: CLI dispatch (portable), then on macOS starts VestalMac's app
Tests/VestalCoreTests/  XCTest
```

- [x] `Package.swift`: library `VestalCore`; target `VestalMac` depending on `VestalCore` (link the macOS frameworks only there, using `linkerSettings` with `.when(platforms: [.macOS])`); executable `vestal` depending on both; test target `VestalCoreTests`. It must build on both Linux and macOS. Keep tools-version 5.9 and `platforms: [.macOS(.v14)]`.
- [x] Move the portable code into `VestalCore` and make the needed API `public`: Config, ConfigLoader, DefaultConfig, JSONPath, Formatters, BuildInfo, Runtime/AppRuntime (minus UI), the fetch logic from AsyncData (http, foyer JSON parsing, exchange/weather picking), ClaudeUsage parsing, and the command runner from phase 1.
- [x] Define platform protocols in `VestalCore` (names are a suggestion):
  - `SystemStatsProvider`: cpu, memory, temperature, battery, network rates, disk, uptime.
  - `MediaProvider`: now playing, play/pause.
  - `CalendarProvider`: upcoming events.
  - `AudioProvider`: volume and mute.
  - `PrivacyProvider`: state and toggle.

  `VestalMac` implements them with the existing Mach/SMC/IOKit/CoreAudio/AppleScript/EventKit code. Move the code; don't rewrite it.
- [x] `BuildInfo` stays substitutable by the flake (`let commit  = "dev"` literal, exact spacing), or update the flake's `substituteInPlace` to match.
- [x] Views keep their exact visual output. This phase moves files and draws boundaries; it does not redesign anything.
- [x] Tests (Linux): Config decoding round-trips; `AnyJSON.matches`; JSONPath (indexes, nested, missing paths); duration parsing (`30s`, `5m`, `4h`, `1d`, invalid); `PickItem` exchange picking against a recorded dolarapi fixture; weather field picking against a recorded wttr.in `j1` fixture; foyer health JSON parsing against a fixture; ClaudeUsage JSONL parsing against a fixture. Fixtures go in `Tests/VestalCoreTests/Fixtures/`. Build them from the code's own field expectations; do not fetch live.
- [~] Update `flake.nix` to build with SwiftPM rather than raw `swiftc`: nixpkgs `swift` + `swiftpm` (the `swiftpm` setup hook runs `swift build -c release`), plus `swiftPackages.stdenv` if that is needed. Keep darwin-only for now. If you judge that SwiftPM under Nix is too risky to leave unverified, keep raw `swiftc` with one invocation per module (`-emit-module`/`-emit-library` for VestalCore, then the app with `-I`/`-L`), and explain the choice in HANDOFF. Either way, mark it `[~]` "verify with `nix build` on swift". *(Verify with `nix build .#default` on swift. SwiftPM via `package.nix`; the same file builds the CLI on Linux with the pinned nixpkgs.)*

## Phase 3: Config complete

- [ ] **Loader:** `$VESTAL_CONFIG`, then `$XDG_CONFIG_HOME/vestal/config.json` (fallback `~/.config/vestal/config.json`), then none. Drop the Application Support path. Return a `LoadedConfig` with the resolved path, the merged `Config`, and a list of warnings. On a parse error, keep the defaults, record the error as a warning (with line/column if Foundation gives it), and surface it in `vestal status` and `check-config`.
- [ ] **Merge:** implement a deep merge over `[String: Any]`/JSON values, as specified in PLAN "Layering". Order: defaults, then the user file, then the user's `platform.macos` or `platform.linux`. Decode after merging. Tests: object merge, array replace, `null` delete, platform override, and that `platform` is stripped before decoding.
- [ ] **Defaults as JSON:** express the built-in defaults as a JSON document (a Swift string literal or a bundled resource; the string literal is simpler under Nix), so merging happens at the JSON level. Remove the Swift-struct `DefaultConfig` or derive it from the JSON.
- [ ] **Generic defaults** (no personal data):
  - `clock`: local time only, no world clocks.
  - `systemBar`: `["uptime","disk","battery","network"]`.
  - `media`: type `media`, `hideWhenOff: true`.
  - `agenda`: `calendar` source, `maxEvents: 5`.
  - `systems`: local host only.
  - `weather`: wttr.in auto-location.
  - `views.main.order` accordingly.
- [ ] **`examples/full.json`:** the owner's exact current setup, i.e. what `DefaultConfig.swift` at `9c17bfc` expresses: BA/NYC/CHI clocks, hosts swift (local), harbor, raven and conduit (`https://<host>.matv.io`, provider foyer), dolarapi blue/oficial/bolsa and BRL from `syntheit/exchange-rates`, systemBar `["uptime","disk","battery","claudeUsage","network","privacy"]`, the weather fields, and the view order `clock, systemBar, spotify, agenda, systems, exchange, weather`. Also include every option added in phases 4 and 5 that is needed to reproduce today's hardcoded behaviour (Claude limits 8,000,000 / 95,000,000, the privacy command `~/.local/bin/toggle-privacy` with state file `/tmp/.privacy-mode`, media player Spotify). Test: `examples/full.json` loads with zero warnings and yields the expected widgets and order.
- [ ] **Schema additions** (document every one in `docs/CONFIG.md`):
  - Source `command`: `argv: [String]`, `timeout` (duration, default `10s`), `refresh`, `parse` (`json`|`raw`), `env: {String:String}` (optional).
  - Source `calendar` (alias `eventkit`): `refresh`, `days` (lookahead, default 1), `calendars: [String]?` (name filter).
  - Host: `name` optional for `source: "local"` (defaults to the short hostname), `key` (optional shortcut letter), `interval` (health poll interval, default `5s`).
  - Widget `claudeUsage`: `path` (default `~/.claude/projects`), `fiveHourLimit`, `weeklyLimit`. It can be used in `systemBar.show` as `claudeUsage`; its options then come from a widget of type `claudeUsage` if one exists.
  - Widget `media` (rename from `spotify`; keep `spotify` as an accepted alias): `player` (default `Spotify` on macOS), `hideWhenOff`.
  - `privacy` options on `systemBar` (or its own widget): `command: [String]` (toggle) and `stateFile: String`. The privacy item is hidden if these are not configured.
  - `theme.background`: `aurora` | `blur` | `none`.
  - Weather `units`: `metric` | `imperial`.
  - Top-level `platform: { macos: {...}, linux: {...} }`.
- [ ] **Unknown-key warnings:** `check-config` reports unknown top-level, source, widget and view keys, unknown widget/source `type`s, view `order` entries that name missing widgets, widgets whose `source` names a missing source, and invalid durations. Decoding stays permissive; warnings never stop the app.
- [ ] Remove the `extras` field (it never worked; see Config.swift:125-127) or make it actually capture unknown keys. Removal is preferred.
- [ ] **CLI:** `vestal check-config [path]` (exit code 0 means ok even with warnings, 1 means parse error) and `vestal print-config [path]` (effective merged JSON, pretty and sorted). Both run on Linux. Tests cover their core functions.
- [ ] Write `docs/CONFIG.md`: resolution order, layering and merge rules, the `platform` block, every source and widget type with every key, type and default, and one complete example. It must match the decoder exactly; the final review checks this.

## Phase 4: Runtime (C3b) and live data

- [ ] `AppRuntime` in `VestalCore` handles all source types: `http`, `command`, `calendar` (through `CalendarProvider`, injected by the platform layer). Unsupported source types on a platform produce a snapshot error, not a crash.
- [ ] **Updates are pushed, not polled.** Replace `waitForData`'s 500ms polling with a subscription API (`AsyncStream<SourceSnapshot>` per source, or a callback registry). The macOS layer adapts this into an `ObservableObject` with `@Published` for SwiftUI. No `@Observable`.
- [ ] Each snapshot has `data`, `fetchedAt`, `lastError`; `lastError` is shown by `vestal status`. Keep the disk cache (the platform cache dir: `~/Library/Caches/Vestal` on macOS, `$XDG_CACHE_HOME/vestal` on Linux). Serve the cache immediately on startup, then refresh if it's stale.
- [ ] **Visibility-aware scheduling:** the runtime has `setVisible(Bool)`. Source refreshes (minutes to hours) keep running while hidden. Host health polling, system stats and media polling run **only while visible**. On show, anything older than its interval refreshes at once.
- [ ] Foyer health goes through the `command` machinery: provider `foyer` builds argv `["foyer-api","--host",url,"/api/health"]`. A host can instead name any `source` whose JSON matches the foyer health schema.
- [ ] Delete `/tmp/dashboard-cache`, `/tmp/.dashboard_cpu_ticks` and `/tmp/.dashboard_net_bytes`. CPU and network deltas are kept in memory now that the process is resident.
- [ ] Remove unused API (`AppRuntime.stop/snapshot/data` if still unused, `SourceSnapshot.lastError` becomes used).
- [ ] Tests with a fake clock and fake fetchers: scheduling intervals, the stale-on-show refresh, cache load on startup, error snapshots, command timeout and kill, argv execution (run `/usr/bin/env echo`-style commands), and PATH resolution.

## Phase 5: Config-driven UI

- [ ] `DashboardView` renders `views.main.order`. Each key names a widget, and each widget renders by its `type` through a switch: `clock`, `systemBar`, `media`, `agendaList`, `systemHealth`, `keyValueList`, `weatherCard`, `claudeUsage`. Unknown types render nothing and log once.
- [ ] Split the monolith into one SwiftUI view per widget type, **moving code with identical modifiers**. Parity with `examples/full.json` is the acceptance test.
- [ ] Honour `title` (e.g. "Currencies" hardcoded at `DashboardView.swift:592`), `hideWhenOff` (hardcoded at `:68`), `units` (°C hardcoded at `AsyncData.swift:91`), `systemBar.show` **order** (not only presence), `theme.background` (`aurora` = the current Metal view, `blur` = visual effect only, `none` = solid palette background) and `theme.palette` (keep Tokyo Night as the only palette, in a `Palette` struct so more can be added; an unknown name falls back with a warning).
- [ ] The host key map comes from config (`key` or auto-assigned, per phase 1 rules). The `SystemDetailView` popup works for local and remote hosts. The local host's detail no longer assumes the name `swift` (`DashboardView.swift:225`).
- [ ] ClaudeUsage limits and path, privacy command and state file, and media player all come from config (phase 3 schema).

## Phase 6: Resident process, IPC, hotkey, reload

- [ ] **IPC in `VestalCore`:** a unix socket server and client over POSIX sockets (Darwin/Glibc). Newline-delimited request `toggle|show|hide|reload|status|quit`; the response is one JSON line (`{"ok":true}` or a status object). Stale sockets: if connect fails, unlink and bind. A live socket means another instance is running, so exit 0 with a message. Socket path per PLAN. Tests on Linux: server and client round-trip, stale socket recovery, second instance refused.
- [ ] **CLI:** bare `vestal` starts the resident instance and shows it (same as today). `vestal daemon` starts it hidden (used by launchd). `toggle/show/hide/reload/status/quit` connect to the socket. `show`/`toggle` with no running instance spawn bare `vestal` detached and exit. `status` prints: running, pid, config path, warnings, and each source's age and last error. `help` lists everything.
- [ ] **macOS window lifecycle:** hide means `orderOut` and return focus to the previously active app; show means reposition to the current screen (the one with the mouse), `makeKeyAndOrderFront`, and activate. Escape hides (it no longer quits). Quit only via `SIGTERM` or a `quit` IPC command.
- [ ] **Zero cost while hidden:** pause the Metal aurora (`MTKView.isPaused = true`, or stop the display link), cancel the clock and stats `.task` loops (drive them from runtime visibility, not view lifetime), and tell the runtime `setVisible(false)`. Record in HANDOFF how the owner can verify this with `top -pid`.
- [ ] **Built-in hotkey** (`VestalMac`): Carbon `RegisterEventHotKey` (needs no Accessibility permission). The parser lives in `VestalCore` and is tested: `f1`–`f20`, letters, digits, `space`, `escape`, `home`, `end`, and modifiers `cmd`, `ctrl`, `alt`/`opt`, `shift`, joined with `+`. `hotkey: null` registers nothing. The default config has `hotkey: null` (skhd on swift still binds F3; a built-in F3 as well would toggle twice). Re-register on reload.
- [ ] **Reload:** `vestal reload`, `SIGHUP` (DispatchSource), and a directory watch on the config file's parent (DispatchSource on macOS; inotify comes later on Linux, so leave a stub or protocol). Debounce 300ms. Reload re-merges, swaps the runtime's sources (keep snapshots for unchanged sources, cancel removed ones), re-registers the hotkey, and re-renders. A config that fails to parse keeps the old config and reports a warning.
- [ ] Keep the pid-less design: delete the pid file code and `detachedRelaunch`'s pid use.

## Phase 7: Packaging and Nix module

- [ ] **Flake:** build `Vestal.app`: `Contents/MacOS/vestal`, `Contents/Info.plist` with `CFBundleIdentifier io.matv.vestal`, `CFBundleName Vestal`, `CFBundleShortVersionString` = the version, `LSUIElement true`, `NSCalendarsUsageDescription` and `NSCalendarsFullAccessUsageDescription`, `NSAppleEventsUsageDescription`, `LSMinimumSystemVersion 14.0`. `$out/bin/vestal` is a wrapper or symlink to the bundle binary so the CLI works and calendar permission attaches to the bundle. Keep the BuildInfo commit substitution.
- [ ] **Flake:** add `x86_64-linux` and `aarch64-linux` package outputs building the CLI-only `vestal` (VestalCore + CLI). Add `devShells.default` with Swift on both platforms. Add `checks` that run `swift test` on Linux if that works offline under Nix; otherwise mark it `[~]`.
- [ ] **Flake:** export `homeManagerModules.default` (`programs.vestal`):
  - `enable`, `package` (default: this flake's package for the system).
  - `settings` (`(pkgs.formats.json {}).type`), written to `xdg.configFile."vestal/config.json"`.
  - `launchAtLogin` (bool, default true): on darwin a `launchd.agents.vestal` running `vestal daemon` with `KeepAlive` and `RunAtLoad`, with `PATH` set to include the Nix profile dirs; on Linux a `systemd.user.services.vestal`, which for now is only defined when the package supports a daemon on Linux (guard it; the Linux UI does not exist yet).
  - `signingIdentity` (nullable string): if set, activation copies the app to `~/Applications/Vestal.app` and runs `codesign --force --deep --sign "<identity>"`, and the launchd agent points at the copy. This mirrors how the owner signs another app today: Nix builds cannot access the keychain.
  - Activation runs `vestal reload` if an instance is running.
- [ ] Document the module in the README with a minimal example, and a migration note for `~/nix`: replace `home/modules/vestal-darwin.nix` with `inputs.vestal.homeManagerModules.default`, move the config from `examples/full.json` into `programs.vestal.settings` (or `builtins.fromJSON (builtins.readFile ...)`), drop the `toggle-vestal` script, point skhd F3 at `vestal toggle`, or set `hotkey = "f3"` and delete the skhd line.
- [ ] If `nix` is available: `nix flake check` and `nix eval .#homeManagerModules.default` at least parse. Otherwise mark `[~]`.
- [ ] Bump version to `0.3.0` (flake + BuildInfo). Update the README roadmap to match reality: v0.2 and v0.3 are done; v0.4 is the Nix module and app bundle (done), with notarized DMG and cask still open; v0.5 is public launch.

## Phase 8 (stretch, only if 0–7 are done): Linux groundwork

These run and are testable on Linux, which makes them good use of this environment. They do not add a Linux UI.

- [ ] `VestalCore` Linux implementations (`#if os(Linux)`) of `SystemStatsProvider` (`/proc/stat`, `/proc/meminfo`, `/sys/class/hwmon/*/temp*_input` or `thermal_zone`, `/sys/class/power_supply/BAT*`, `/proc/net/dev`, `statvfs`, `/proc/uptime`), `AudioProvider` (`wpctl get-volume @DEFAULT_AUDIO_SINK@`) and `MediaProvider` (`playerctl metadata`/`play-pause`). Tests parse fixture files of each `/proc`/`/sys` format.
- [ ] `vestal daemon` on Linux runs headless: runtime, IPC, and `status` showing live sources and stats. This lets a future UI of any toolkit connect to it.
- [ ] Generate `docs/vestal.schema.json` (JSON Schema for the config) and add a test that `examples/full.json` and the defaults validate against it structurally (a small hand-rolled check is fine; no dependencies).

---

## Final review (after the last phase you complete)

Run 3 reviewer subagents in parallel over `git diff main...HEAD`. Each gets `CLAUDE.md`, `docs/PLAN.md` and this file:

1. **Correctness and concurrency:** logic bugs, races, main-actor violations, leaks, error handling, IPC edge cases.
2. **macOS compile risk:** a line-by-line "mental compile" of every `VestalMac` file and every `#if os(macOS)` block against the macOS 14 SDK and Swift 5.10. List every API it is not sure of.
3. **Config contract and portability:** `docs/CONFIG.md` vs the decoder vs `examples/full.json` vs the defaults vs the Nix module options; invariants; nothing platform-specific in `VestalCore` outside `#if os(...)`.

Fix confirmed findings, re-run the invariants and `swift test`, update HANDOFF, push.
