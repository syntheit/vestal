# Vestal

A keypress-toggled, full-screen dashboard overlay. Press a key, see everything
that matters at a glance, press it again and it is gone.

Native Swift / SwiftUI on macOS. ~20 MB RAM. Zero CPU while hidden. A Linux
version (NixOS + Hyprland) comes next and will run from the same config file.

## Status

Pre-release, extracted from a personal nix-darwin setup. The macOS app is
configured by one JSON file ([docs/CONFIG.md](./docs/CONFIG.md)) and ships as a
Nix flake with a Home Manager module. On Linux the package builds the `vestal`
command-line tool only; the Linux UI does not exist yet.

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
| `package` | this flake's package | The vestal package to use. |
| `settings` | `{ }` | The config ([docs/CONFIG.md](./docs/CONFIG.md)), written to `$XDG_CONFIG_HOME/vestal/config.json` (usually `~/.config/vestal/config.json`) with `version = 1` added unless set. It is layered over the built-in defaults. The default `{ }` writes no file: vestal then runs on its built-in defaults, or on a file you manage yourself. |
| `launchAtLogin` | `true` | macOS: a launchd agent starts `vestal daemon` (hidden) at login and restarts it if it crashes, but not after `vestal quit`. Its output goes to `~/Library/Logs/vestal.log`. Linux: nothing yet; a systemd user service comes with the Linux daemon. |
| `signingIdentity` | `null` | macOS: a code signing identity from your keychain (`security find-identity -v -p codesigning`). See below. |

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
vestal status          # pid, build, config file, warnings, each source's age and error
vestal quit            # quit (also on SIGTERM); Escape and hide only hide it
vestal check-config [path]   # check a config file
vestal print-config [path]   # the effective config, defaults merged in
```

vestal stays running while hidden and costs next to nothing then. `hide`,
`reload`, `status` and `quit` never start it: they exit 1 when it is not
running. Exit codes: 0 ok, 1 error or not running, 2 usage. `vestal daemon`
exits 0 when vestal already runs, or replaces a running instance of another
build. The built-in hotkey (`hotkey` in the config) toggles too. The Linux
package has the command-line tool only for now: starting the dashboard there
exits 1.

## Build

Requires macOS 14+ and Swift 5.10 (Xcode 15.3 or later) for the app.

```sh
nix build          # macOS: result/Applications/Vestal.app and result/bin/vestal
                   # Linux: result/bin/vestal, the command-line tool only
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
- v0.4: Nix module and app bundle (done); notarized DMG and Homebrew cask (open)
- v0.5: public launch

## License

See [LICENSE](./LICENSE).
