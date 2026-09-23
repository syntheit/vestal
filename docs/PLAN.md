# Vestal plan

Durable context for vestal work. Claude session history is deleted after a while; this file is not.

## Goals

- **Nix-native.** The config is a file Nix can write. No settings UI until the options are stable.
- **Config model.** Views hold widgets. Sources are defined once; widgets pick fields out of them with JSONPath ("destructuring"). Users configure widgets; they do not build UI.
- **The app owns fetching.** One scheduler, shared sources, disk cache, per-source refresh intervals.
- **Built-in hotkey** that coexists with Karabiner/skhd.
- **Cross-platform, one config.** The same config file drives macOS (host "swift", F3) and Linux (host "mantle", NixOS + Hyprland, Home key). Both are full-screen with a blurred background.
- **Near-zero cost when hidden.** No UI timers, no render loop, no per-second polling while hidden.
- **Shippable.** Signed `.app`, launch at login, home-manager module shipped from this flake. Later: notarized DMG and brew cask.

## Decisions

### Config
- JSON, top-level `version: 1`. Unknown keys are ignored when decoding; `vestal check-config` warns about them.
- **Resolution order:** `$VESTAL_CONFIG`, else `$XDG_CONFIG_HOME/vestal/config.json` (default `~/.config/vestal/config.json`) on **both** platforms, else no user file. The old `~/Library/Application Support/Vestal/config.json` path is dropped (nothing used it).
- **Layering:** built-in defaults, then the user file, then the user file's `platform.<os>` block (`macos` or `linux`). Deep merge on JSON objects: objects merge key by key, arrays and scalars replace, and an explicit `null` deletes the key (so users can remove a default widget).
- **Built-in defaults are generic:** local clock, system bar, media, calendar, weather (auto-location), local host health. Nothing personal. The owner's full setup lives in `examples/full.json` and, later, in their Nix config.
- **Widgets are dispatched by `type`,** not by their key name. Several widgets of the same type are allowed. Views list widget keys in `order`.
- **Sources:** `http`, `command`, `calendar`. `command` runs an argv array (never `bash -c` with interpolation) with a timeout, and resolves executables on `PATH` plus the Nix profile dirs. `calendar` uses EventKit on macOS and a Linux backend later; `eventkit` stays accepted as an alias.
- The local host in `systemHealth` uses the machine's short hostname unless `name` is set, so one config works on swift and mantle.

### Process model
- One resident process per user. It shows and hides a window; it does not quit on hide.
- The CLI (`vestal toggle|show|hide|reload|status`) talks to it over a unix domain socket: `$XDG_RUNTIME_DIR/vestal.sock` if set, else `$TMPDIR/vestal-<uid>.sock`. The socket also enforces single-instance. No pid files.
- `show`/`toggle` with no running instance launch one, then deliver the command.
- The built-in hotkey is set by `hotkey` in the config (e.g. `"f3"`, `"cmd+shift+space"`). `null` means external bind only (the default, so skhd setups keep working).
- Reload: `vestal reload`, `SIGHUP`, and a watch on the config file's directory (Nix swaps a symlink, so watching the file inode is not enough).

### Code layout
- `VestalCore`: portable library (Foundation only, `FoundationNetworking` on Linux). It holds config, merge, loader, JSONPath, formatters, the runtime/scheduler, sources, the IPC protocol and server/client, CLI parsing, and **protocols** for platform services (system stats, media, calendar, hotkey, window).
- The macOS UI and platform implementations live in a macOS-only target. Every file there is wrapped in `#if os(macOS)` so `swift build` works on Linux.
- A single `vestal` executable. On Linux it currently supports the CLI-only commands (`version`, `help`, `check-config`, `print-config`, and client commands); the Linux UI comes later.
- The UI toolkit for Linux is **undecided**. `VestalCore` must not assume one. A future Linux UI either links `VestalCore` (Swift) or talks to a headless `vestal` daemon over the socket.

### Packaging
- The flake builds `Vestal.app` (Info.plist with LSUIElement, calendar and Apple Events usage strings) and `bin/vestal`.
- The flake exports `homeManagerModules.default` (`programs.vestal`). It writes `xdg.configFile."vestal/config.json"`, installs a launchd agent (macOS) or systemd user service (Linux), and optionally signs the app at activation time (Nix builds cannot reach the keychain).
- Bundle id: `io.matv.vestal`.

## Status

**2026-09-23:**
- Done: C1 schema and loader, C2 clock, C3a http runtime, C4 foyer/agenda/systemBar/exchange picks, weather fields, CLI toggle/show/hide/version.
- `~/nix` consumes vestal via `inputs.vestal` plus its own `home/modules/vestal-darwin.nix`, with `settings = {}` (bundled defaults), toggled by skhd F3 through `pgrep`/`pkill`.
- The `~/nix` repo is under a commit freeze. All work in this plan happens in this repo; adopting it in `~/nix` is a later, local step.
- Next: execute `docs/TASKS.md` on branch `macos-v0.3`.

## Linux (after the macOS phases)

- Target: mantle, replacing the tmux dashboard on `special:dashboard` (Home key) in `~/nix/home/modules/hyprland.nix`.
- Needs: a layer-shell overlay with exclusive keyboard focus and Hyprland blur; Linux implementations of the platform protocols (`/proc`, hwmon, `/sys/class/power_supply`, PipeWire/wpctl, MPRIS over D-Bus); a Linux calendar backend (ICS/CalDAV).
- Open question: the UI toolkit.
