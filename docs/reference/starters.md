# Starters

A starter is a complete, forkable config: pick one, write it with `vestal init`, then change it with your agent (`vestal docs agents`). Each is a whole dashboard of several pages built from the presets (`vestal docs presets`); none holds personal data, and every secret is declared under `secrets` (the GitHub ones run `gh auth token`, so log in once with `gh auth login`).

```text
vestal init --list                  # id, title and pitch of every starter
vestal init --starter developer     # write it to the config path
vestal init --starter developer --print     # just print it
vestal init --starter developer --force     # replace a file you have; it is copied to config.json.bak-<timestamp> first
vestal init --path ~/vestal.json    # write somewhere else
```

Without `--starter`, `init` writes `default`. The file goes to `$VESTAL_CONFIG`, else `$XDG_CONFIG_HOME/vestal/config.json` (`~/.config/vestal/config.json`), and an existing file is never replaced without `--force`. When that file is a link into `/nix/store` (Home Manager owns it), `init` changes nothing and prints the Nix line below instead. `init` also prints what you must provide (each starter's "needs", below) and how to edit it with your agent.

Under Nix, `programs.vestal.starter = "<id>";` makes the starter the base of the config file, and `programs.vestal.settings` merges over it with vestal's own rules: objects merge key by key, lists and scalars replace, `null` removes a key.

```nix
programs.vestal = {
  enable = true;
  starter = "developer";
  settings = {
    hotkey = "f3";                       # replaces the starter's
    theme.background = "blur";           # one key of an object
    pages.order = [ "main" "builds" ];   # a list replaces the starter's
  };
};
```

**The hotkey.** Every starter sets `"hotkey": "cmd+shift+space"`; vestal's built-in defaults have none. Spotlight is `cmd+space` and macOS 14 and 15 bind nothing to `cmd+shift+space` by default (the input source shortcuts are `ctrl+space` and `ctrl+opt+space`), so it works out of the box; change `hotkey` if another app has it. On Linux, Wayland has no global hotkeys: bind `vestal toggle` in the compositor (with Home Manager, `programs.vestal.hyprland.enable` turns this same key into a Hyprland bind, `SUPER SHIFT, space`).

A starter can also be a page or a single widget block (`kind` in its `starter.json`); today all eight are dashboards. Each has a sample (`starter-<id>`) that `vestal gallery --only starter-<id>` draws with fixture data, and the gallery README lists them under dashboards.

## `default`: Default

Today's dashboard: time, this machine, music, agenda, your hosts, rates and weather. Background: `aurora`.

Clock: `mono` face, `system` typeface (unchanged), `hour12: "auto"`.

Pages: **Main** (key 1), **Focus** (key 2).

You provide:

- Calendar access (macOS asks the first time; on Linux set an `ics` or `caldav` calendar source)
- Optional: your own hosts under `systems` (`vestal docs preset/systemHealth`)
- Optional: a location for the weather (wttr.in guesses it from your IP)
- Linux: Wayland has no global hotkeys, so bind `vestal toggle` in your compositor (Hyprland: bind = SUPER SHIFT, space, exec, vestal toggle; Home Manager: programs.vestal.hyprland.enable)

Screenshot: `vestal gallery --only starter-default --out <dir>` writes `<dir>/starter-default.png`.

```sh
vestal init --starter default
```

```nix
programs.vestal.starter = "default";
```

## `minimal`: Minimal

A big clock, the date and the next event. Nothing to read twice. Background: `sky`.

Clock: `serif` face with the date in words, `instrument` typeface, `hour12: "auto"`.

Pages: **Main** (key 1).

You provide:

- Calendar access (macOS asks the first time; on Linux set an `ics` or `caldav` calendar source)
- Linux: Wayland has no global hotkeys, so bind `vestal toggle` in your compositor (Hyprland: bind = SUPER SHIFT, space, exec, vestal toggle; Home Manager: programs.vestal.hyprland.enable)

Screenshot: `vestal gallery --only starter-minimal --out <dir>` writes `<dir>/starter-minimal.png`.

```sh
vestal init --starter minimal
```

```nix
programs.vestal.starter = "minimal";
```

## `developer`: Developer

Reviews waiting on you, CI per repo, plan usage and your commit rhythm. Background: `topo`.

Clock: `mono` face, `inter` typeface, `hour12: "auto"`. The compact density keeps it, small.

Pages: **Main** (key 1), **Reviews** (key 2), **Builds** (key 3).

You provide:

- GitHub login (`gh auth login`); the `github` secret runs `gh auth token`
- Your repositories: replace `acme/*` in the `ci` widgets and the paths in `commits`
- Optional: the Nix flake to watch in `flake` (needs `nix` on the PATH)
- Claude Code or Codex logins for the plan usage rows (`vestal docs ai-usage`)
- Linux: Wayland has no global hotkeys, so bind `vestal toggle` in your compositor (Hyprland: bind = SUPER SHIFT, space, exec, vestal toggle; Home Manager: programs.vestal.hyprland.enable)

Screenshot: `vestal gallery --only starter-developer --out <dir>` writes `<dir>/starter-developer.png`.

```sh
vestal init --starter developer
```

```nix
programs.vestal.starter = "developer";
```

## `homelab`: Homelab

Hosts, monitors, containers, backups and the tailnet, two columns wide. Background: `aurora`.

Clock: `condensed` face at size 84, `inter` typeface, `hour12: "auto"`.

Pages: **Overview** (key 1), **nas** (key 2), **Network** (key 3).

You provide:

- Hosts running foyer (or a source in its shape) for `systems`; replace `nas.example.com`
- An Uptime Kuma status page URL and slug in the `status` source (or switch to `healthchecks`)
- Docker or Podman on the machine or over ssh (`ssh://nas`, key without a prompt)
- Backup status files from your backup wrappers (`vestal docs preset/backups`)
- Tailscale CLI (`tailscale`) on the PATH
- Linux: Wayland has no global hotkeys, so bind `vestal toggle` in your compositor (Hyprland: bind = SUPER SHIFT, space, exec, vestal toggle; Home Manager: programs.vestal.hyprland.enable)

Screenshot: `vestal gallery --only starter-homelab --out <dir>` writes `<dir>/starter-homelab.png`.

```sh
vestal init --starter homelab
```

```nix
programs.vestal.starter = "homelab";
```

## `markets`: Markets

A watchlist, crypto and exchange rates with intraday lines. Background: `mesh`.

Clock: `flip` face without seconds, `plex` typeface, `hour12: "auto"`.

Pages: **Markets** (key 1), **Main** (key 2).

You provide:

- Nothing to sign in to: Yahoo Finance, CoinGecko and open.er-api.com need no key
- Your own tickers in `quotes` and coins in `coins`
- Linux: Wayland has no global hotkeys, so bind `vestal toggle` in your compositor (Hyprland: bind = SUPER SHIFT, space, exec, vestal toggle; Home Manager: programs.vestal.hyprland.enable)

Screenshot: `vestal gallery --only starter-markets --out <dir>` writes `<dir>/starter-markets.png`.

```sh
vestal init --starter markets
```

```nix
programs.vestal.starter = "markets";
```

## `focus`: Focus

A timer, the one task, today's list and habits. Tab away to everything else. Background: `grain`.

Clock: `breathe` face, `geist` typeface, `hour12: "auto"`.

Pages: **Focus** (key 1), **Main** (key 2).

You provide:

- A markdown checklist at `~/notes/todo.md` with a `## Today` heading (`- [ ] task`); ticking writes that file
- Optional: `~/.local/share/vestal/habits.json` (`vestal docs preset/habits`)
- Calendar access for the next-event line (macOS asks the first time)
- Linux: Wayland has no global hotkeys, so bind `vestal toggle` in your compositor (Hyprland: bind = SUPER SHIFT, space, exec, vestal toggle; Home Manager: programs.vestal.hyprland.enable)

Screenshot: `vestal gallery --only starter-focus --out <dir>` writes `<dir>/starter-focus.png`.

```sh
vestal init --starter focus
```

```nix
programs.vestal.starter = "focus";
```

## `media`: Media

Now playing, large. The background takes the album's colors. Background: `artmesh`.

Clock: `thin` face (small, on the now-playing page), `instrument` typeface, `hour12: "auto"`.

Pages: **Now playing** (key 1), **Main** (key 2).

You provide:

- A music player: Spotify or Music on macOS (allow Automation the first time), any MPRIS player with `playerctl` on Linux
- Optional: a player name in the `player` of the `now` widget
- Linux: Wayland has no global hotkeys, so bind `vestal toggle` in your compositor (Hyprland: bind = SUPER SHIFT, space, exec, vestal toggle; Home Manager: programs.vestal.hyprland.enable)

Screenshot: `vestal gallery --only starter-media --out <dir>` writes `<dir>/starter-media.png`.

```sh
vestal init --starter media
```

```nix
programs.vestal.starter = "media";
```

## `agentops`: Agent ops

Plan headroom, running agents and what needs you, for a day of delegated work. Background: `flow`.

Clock: `ring` face, `inter` typeface, `hour12: "auto"`.

Pages: **Ops** (key 1), **Main** (key 2), **Reviews** (key 3).

You provide:

- Claude Code and/or Codex logged in on this machine (`vestal docs ai-usage`)
- An agents file at `~/.local/state/vestal/agents.json`: a JSON list of {id, state (running, input, done, failed), repo, task, note, elapsed} that your agent hooks write
- GitHub login (`gh auth login`); the `github` secret runs `gh auth token`
- Your repositories: replace `acme/*` in the `ci` widgets
- Linux: Wayland has no global hotkeys, so bind `vestal toggle` in your compositor (Hyprland: bind = SUPER SHIFT, space, exec, vestal toggle; Home Manager: programs.vestal.hyprland.enable)

Screenshot: `vestal gallery --only starter-agentops --out <dir>` writes `<dir>/starter-agentops.png`.

```sh
vestal init --starter agentops
```

```nix
programs.vestal.starter = "agentops";
```
