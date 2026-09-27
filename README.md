# Vestal

A keypress-toggled, full-screen dashboard overlay. Press a key, see everything
that matters at a glance, press it again and it is gone.

Native Swift / SwiftUI on macOS. ~20 MB RAM. Zero CPU while hidden. A Linux
version (NixOS + Hyprland) comes next and will run from the same config file.

## Status

Pre-release, extracted from a personal nix-darwin setup. The macOS app is
configured by one JSON file ([docs/CONFIG.md](./docs/CONFIG.md)) and ships as a
Nix flake with a Home Manager module. On Linux the Linux UI does not exist
yet: `vestal daemon` runs headless (sources, the socket, config reload, system
stats in `vestal status`), groundwork for a UI that comes later.

## Configured by your agent

There is no settings screen. vestal is configured by one JSON file (or the Nix
attrset that writes it), and it is built to be edited by your own LLM agent:
ask it for "my review queue, BTC with a 24h sparkline, and CPU in red when it's
pegged" and it writes the config. v0.4 gives it everything it needs, in the
binary:

- **A config language, not a widget list:** 6 containers and 8 primitives
  (`stack`, `row`, `grid`, `list`, `table`, `switch`, `text`, `icon`,
  `progress`, `gauge`, `sparkline`, `keyValue`, …), jq expressions and
  `{{ }}` text, parameterised templates, views switched by keys, and actions
  (`run`, `open`, `copy`, `refresh`, `popup`, `media`, …). The v0.3 widgets
  are presets written in it, and v0.3 configs load unchanged.
- **Data from anywhere:** `http` (with secrets kept out of the config),
  `command` (never a shell), `file`, RSS/Atom/JSON feeds, `.ics` calendars,
  histories for sparklines, and the built-in `system`, `media`, `calendar` and
  `claude` sources with the same shape on macOS and Linux.
- **Tools for the agent:** `vestal docs` (every widget, source, function and
  key, plus complete recipes), `vestal schema`, `vestal check-config --json`
  (JSON pointers and did-you-mean), `vestal fetch --shape`, `vestal eval`,
  `vestal render` (the screen as text or JSON), `vestal explain`,
  `vestal screenshot`, `vestal capabilities`.
- **A render model any UI can draw**, streamed over the socket
  (`vestal subscribe`); the macOS and Linux UIs draw the same model.

The agent's loop, in five lines:

```sh
vestal capabilities; vestal docs agents          # what works here, and how to write a config
vestal fetch <source> --config draft.json --shape  # look at the data
vestal check-config --json draft.json            # errors with pointers and suggestions
vestal eval '<jq>' --source <source> --config draft.json; vestal render --config draft.json
vestal screenshot /tmp/v.png --config draft.json # look at it, then deploy the draft
```

[AGENTS.md](./AGENTS.md) (also `vestal docs agents`) walks an agent through
it, with eleven complete recipes; [examples/showcase/](./examples/showcase)
has them as files.

## Install with Home Manager

The flake exports `homeManagerModules.default`, which sets up `programs.vestal`:

```nix
# flake.nix
inputs.vestal.url = "github:syntheit/vestal";

# your Home Manager configuration
{ inputs, ... }:
{
  imports = [ inputs.vestal.homeManagerModules.default ];

  programs.vestal = {
    enable = true;
    settings = {
      hotkey = "f3";
      theme.background = "blur";
    };
  };
}
```

| Option | Default | |
|---|---|---|
| `enable` | `false` | Install `vestal` and set it up. |
| `package` | this flake's package | The vestal package to use. To build it with your own nixpkgs (on NixOS this shares GTK and glibc with the system and its graphics drivers), apply `overlays.default` and use `pkgs.vestal`. |
| `settings` | `{ }` | The config ([docs/CONFIG.md](./docs/CONFIG.md)), written to `$XDG_CONFIG_HOME/vestal/config.json` (usually `~/.config/vestal/config.json`) with `version = 1` added unless set. It is layered over the built-in defaults. The default `{ }` writes no file: vestal then runs on its built-in defaults, or on a file you manage yourself. |
| `extraPackages` | `[ ]` | Packages whose programs the daemon runs: they come first on the PATH of the launch agent or the systemd service, where `command` sources, `run` actions and `command` secrets find them (for example `[ pkgs.gh ]`). On Linux, `playerctl` and `wireplumber` (`wpctl`) are always added, for the `media` source and the volume. |
| `launchAtLogin` | `true` | macOS: a launchd agent starts `vestal daemon` (hidden) at login and restarts it if it crashes, but not after `vestal quit`. Its output goes to `~/Library/Logs/vestal.log`. Linux: a systemd user service runs `vestal daemon`, headless until the Linux UI exists; `vestal status` shows its sources and this machine's stats. It is part of `graphical-session.target` and restarts after a crash; it needs `WAYLAND_DISPLAY` (or `DISPLAY`) in the systemd user environment, which Home Manager's Hyprland module imports with `wayland.windowManager.hyprland.systemd.enable` (the default), as UWSM does. Its log: `journalctl --user -u vestal`. |
| `signingIdentity` | `null` | macOS: a code signing identity from your keychain (`security find-identity -v -p codesigning`). See below. |
| `hyprland.enable` | `false` | Linux: adds to `wayland.windowManager.hyprland.settings` a `bind` that runs `vestal toggle`, and `layerrule`s for the layer namespace `vestal`. Needs Hyprland 0.53 or later (`match:` rules) and `configType = "hyprlang"`. |
| `hyprland.bind` | from the hotkey | The bind's `"MODS, key"`. By default the hotkey vestal uses on Linux (`settings.platform.linux.hotkey`, else `settings.hotkey`) in Hyprland's syntax: `"home"` is `", Home"`, `"super+d"` (`"cmd+d"`) is `"SUPER, D"`. `null`: no bind. |
| `hyprland.blur`, `.ignoreAlpha`, `.animation`, `.noAnim` | `true`, `0.3`, `null`, `false` | The `blur`, `ignore_alpha`, `animation` and `no_anim` layer rules. |

Every activation also runs `vestal reload`, so a running dashboard picks up the
new config at once. It never starts vestal and never fails the activation.

### Signing on macOS

macOS ties calendar and automation (Apple Events) permissions to the app's code
signature. A Nix build is ad-hoc signed and changes with every rebuild, so macOS
may ask for those permissions again after an update. Nix builds cannot reach
the keychain, so with `signingIdentity` set the module signs at activation
instead:

- it copies `Vestal.app` to `~/Applications/Vestal.app` and runs
  `codesign --force --deep --timestamp=none --sign "<identity>"` on the copy
  (Xcode is not needed), only when the build or the identity changed, and
  restarts the launch agent onto it;
- the launch agent and the `vestal` command run that copy;
- if signing fails it prints a warning and activation carries on: a copy that
  was signed with an identity stays, with its permissions, even if it is an
  older build; otherwise this build is installed signed ad hoc;
- when `signingIdentity` is unset again, activation removes the copy it
  installed. It never touches a `~/Applications/Vestal.app` it did not install.

### Migrating `~/nix`

1. Replace `home/modules/vestal-darwin.nix` with the module:
   `imports = [ inputs.vestal.homeManagerModules.default ];` and
   `programs.vestal.enable = true;`.
2. The built-in defaults are generic now, so move your setup into
   `programs.vestal.settings`: the contents of
   [examples/full.json](./examples/full.json), either as Nix attributes or with
   `settings = builtins.fromJSON (builtins.readFile ./vestal.json);`.
3. Drop the `toggle-vestal` script. vestal stays resident now and is driven
   through its own commands.
4. Point the skhd F3 binding at `vestal toggle`. Or set `settings.hotkey = "f3"`
   and delete the skhd line; do not keep both, or F3 toggles twice.
5. If you sign another app at activation, set `signingIdentity` to the same
   identity.
6. `bin/vestal` is now a wrapper that execs the store's
   `Applications/Vestal.app/Contents/MacOS/vestal`: anything that copied or
   signed `${vestal}/bin/vestal` into its own `.app` should use that path
   instead, or switch to the module's `signingIdentity`.

## Usage

```sh
vestal                 # start the dashboard and show it (or show the running one)
vestal daemon          # start it hidden (the launch agent does this)
vestal toggle          # show or hide; show and toggle start vestal if needed
vestal show | hide
vestal reload          # re-read the config (also on SIGHUP and when the file changes)
vestal status          # pid, build, config file, warnings, each source's age and error,
                       # and this machine's stats (--json for the same as JSON)
vestal quit            # quit (also on SIGTERM); Escape and hide only hide it
vestal version         # print the version and the commit it was built from
vestal help            # print this usage
vestal check-config [path]   # check a config file (--json: pointers and suggestions)
vestal print-config [path]   # the effective config, defaults merged in
vestal docs [topic]          # the built-in documentation; start with `vestal docs agents`
vestal schema                # the config's JSON Schema
vestal sources               # every source, its state and who reads it
vestal fetch <source>        # a source's data now (--shape: an outline of its paths)
vestal eval '<jq>'           # evaluate an expression as a widget would
vestal render                # the screen as an outline (--json: the render model)
vestal explain <widget>      # why a widget shows what it shows, or nothing
vestal screenshot <out.png>  # the screen as a PNG
vestal capabilities          # what works on this machine
vestal subscribe             # the live render-model stream, for UI authors
```

vestal stays running while hidden and costs next to nothing then. `hide`,
`reload`, `status` and `quit` never start it: they exit 1 when it is not
running. Exit codes: 0 ok, 1 error or not running, 2 usage, 3 the config has
errors, 4 not found, 5 not supported here (`vestal docs cli`). `vestal daemon`
exits 0 when vestal already runs, or replaces a running instance of another
build. The built-in hotkey (`hotkey` in the config) toggles too. On Linux
there is no UI yet: vestal runs headless, and `show`, `hide` and `toggle` only
change the visibility it reports (and say so).

## Build

Requires macOS 14+ and Swift 5.10 (Xcode 15.3 or later) for the app.

```sh
nix build          # macOS: result/Applications/Vestal.app and result/bin/vestal
                   # Linux: result/bin/vestal, the CLI and the headless daemon
nix flake check    # builds, smoke-tests the CLI, checks Info.plist and the
                   # Home Manager module; on Linux also runs the test suite
nix develop        # a shell with the Swift toolchain the package uses
```

Without Nix:

```sh
swift build -c release
.build/release/vestal
swift test
```

`swift test` needs a toolchain with test discovery (Xcode, or swift.org's
toolchain on Linux). nixpkgs' Linux Swift lacks it, so inside `nix develop` on
Linux run the tests through the flake instead:
`nix build .#checks.x86_64-linux.tests -L` (or `aarch64-linux`).

## Roadmap

- v0.1: standalone build (done)
- v0.2: config schema, widgets from config, runtime scheduler and cache (done)
- v0.3: resident process with CLI control (`vestal toggle/show/hide/reload`),
  built-in hotkey (done)
- v0.4: extensibility: the config language, sources, templates, the render
  model and the agent kit (`vestal docs`, `schema`, `check-config --json`,
  `fetch --shape`, `eval`, `render`, `screenshot`); the Linux UI; Nix module
  and app bundle (done); notarized DMG and Homebrew cask (open)
- v0.5: public launch

## License

See [LICENSE](./LICENSE).
