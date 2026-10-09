# Installing vestal

## macOS: DMG

1. Download `Vestal-<version>.dmg` from the GitHub releases page and open it.
2. Drag `Vestal.app` onto the `Applications` link.
3. Start it once from Applications. It has no Dock icon and no menu bar item; it shows the dashboard and then stays resident while hidden.

The app is signed with a Developer ID and notarized, so Gatekeeper opens it without a warning. macOS 14 (Sonoma) or later; Apple silicon and Intel.

To use the `vestal` command from a shell, put a small wrapper on your PATH (not a symlink: macOS finds the app's bundle, and so its permissions and fonts, from the path the program was started by):

```sh
printf '#!/bin/sh\nexec /Applications/Vestal.app/Contents/MacOS/vestal "$@"\n' | sudo tee /usr/local/bin/vestal >/dev/null
sudo chmod +x /usr/local/bin/vestal
```

## macOS: Homebrew

```sh
brew install --cask syntheit/vestal/vestal
```

This installs `Vestal.app` and puts a `vestal` wrapper on the PATH. `brew upgrade --cask vestal` updates it; `brew uninstall --zap --cask vestal` also removes the config, the data cache and the log.

## macOS or Linux: Nix

The flake provides the package and a Home Manager module (`programs.vestal`), which writes the config, starts vestal at login and signs the app on your machine. See the README and `nix/hm-module.nix`. Nix users do not need the DMG.

## First run

- **Config.** With no config file vestal runs on built-in defaults. Create `~/.config/vestal/config.json` (or `$XDG_CONFIG_HOME/vestal/config.json`); `examples/` in the repository has complete files, `vestal docs agents` explains the format, and `vestal check-config` checks a file. There is no `vestal init`; copy an example. The file is watched, and `vestal reload` reads it at once.
- **Hotkey.** None by default. Set `"hotkey": "f3"` (or `"cmd+shift+space"`) in the config. The key is taken from every app. Until then, `vestal toggle` (from a shell, skhd or Shortcuts) shows and hides the dashboard.
- **Calendar.** The first time the agenda source reads your calendars, macOS asks whether Vestal may access Calendar. Allow it (Full Access: it reads events only). Change it later in System Settings > Privacy & Security > Calendars.
- **Automation.** The first time the media widget talks to Music, Spotify or another player, macOS asks whether Vestal may control it. Allow it. Change it in System Settings > Privacy & Security > Automation.
- **Nothing else.** The screenshot command and the trackpad pinch gesture need no permission.

## Start at login

Off by default.

```sh
vestal login-item on       # register: runs `vestal daemon`, hidden, at login
vestal login-item status   # login-item: on | off | waiting for approval
vestal login-item off
```

macOS may ask you to approve it once in System Settings > General > Login Items & Extensions; `status` says when it is waiting. The command works from `Vestal.app` only (DMG or Homebrew), and the entry lives with the app: move or delete the app and macOS drops it. Nix users set `programs.vestal.launchAtLogin` instead; do not use both.

## Linux

Install through Nix (above). The Home Manager module starts a systemd user service; Wayland has no global hotkeys, so bind `vestal toggle` in the compositor (the module's `programs.vestal.hyprland.enable` does it for Hyprland).
