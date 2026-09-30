# Vestal

A full-screen dashboard overlay you toggle with a key. Press it, see what
matters at a glance, press it again and it's gone.

Runs on macOS (SwiftUI) and Linux (GTK 4 on Hyprland) from the same JSON
config. It stays resident while hidden and uses almost nothing.

## Install

Vestal ships as a Nix flake with a Home Manager module:

```nix
# flake.nix
inputs.vestal.url = "github:syntheit/vestal";

# Home Manager
{
  imports = [ inputs.vestal.homeManagerModules.default ];

  programs.vestal = {
    enable = true;
    settings = {
      hotkey = "f3";
    };
  };
}
```

`settings` is written to `~/.config/vestal/config.json`. Every option is
documented in [nix/hm-module.nix](./nix/hm-module.nix).

## Configure

The config is one JSON file layered over built-in defaults. See
[docs/CONFIG.md](./docs/CONFIG.md) for every key and
[examples/](./examples) for complete configs.

The CLI can check and preview a config without showing it:

```sh
vestal check-config config.json
vestal render --config config.json
vestal screenshot out.png --config config.json
```

`vestal docs` prints the full reference. [AGENTS.md](./AGENTS.md) covers
having an LLM agent write the config for you.

## Usage

```sh
vestal toggle     # show or hide (starts vestal if needed)
vestal reload     # re-read the config
vestal status     # sources, warnings, errors
vestal help       # everything else
```

## Build

```sh
nix build         # or: swift build -c release
nix flake check
```

macOS 14+ and Swift 5.10.

## License

[GPL-3.0](./LICENSE)
