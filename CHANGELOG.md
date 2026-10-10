# Changelog

All notable changes to Vestal. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.5.0] - 2026-10-09

This release covers everything since 0.3.0 (there was no 0.4 release). Every 0.3 config
still means what it did.

### Added

- Linux: a GTK 4 and layer-shell UI for Hyprland and other Wayland
  compositors, drawn from the same config as the macOS app.
- A new config language. Expressions are jq. Build any widget from
  primitives (text, rows, columns, stacks, bars, rings, sparklines, images),
  write your own templates and presets, define views and key bindings, and run
  actions (open, copy, run a command, timer, toggle a todo). The eight 0.3
  widgets are now built-in presets with the same names.
- About 50 widgets as presets: system, time and weather, developer,
  homelab, feeds and markets, media, and personal (day timeline, next
  meeting, focus timer, todo file, habits). `vestal docs preset/<name>` shows
  each one.
- Chart primitives: bars, stacked bars, heatmap, timeline and image.
- Pages: several views in one dashboard, with arrows, swipe, transitions
  and page dots.
- 12 backgrounds, drawn by shaders, including the aurora, sky, rain and
  blur, with a `dim` setting.
- 11 clock faces: analog, flip, day ring, dot matrix, seven-segment and
  text faces, with world-clock subdials and a moon phase.
- Typefaces and bundled fonts, with a `typeface` key and a display role.
- Starters and `vestal init`: eight starter dashboards, each with a clock
  face and typeface. `vestal init` writes one (backing up your config), and
  `programs.vestal.starter` does the same in Nix.
- Calendars from more places: CalDAV servers (iCloud included),
  Thunderbird's local calendars, and ics URLs with Basic auth.
- Claude and Codex usage is read from the OAuth usage endpoint, with the CLI
  as fallback.
- New sources: astro (sunrise, sunset, moon), timer, flake, and files or
  directories of JSON. HTTP sources accept secrets in headers and bodies.
- `vestal gallery` renders every widget and background offscreen.
- A web renderer that draws the same model in a browser, and a website at
  vestal.matv.io with live renders.
- Agent kit: `vestal docs`, `vestal schema`, `vestal check-config` with
  suggestions, `vestal render --press <key>`, and `AGENTS.md`, so an LLM can
  write your config.
- The pinch gesture (`gesture = "pinch"`) opens and closes the dashboard on a
  trackpad.
- macOS release pipeline: a signed and notarized Vestal.app in a DMG, a
  Homebrew cask, and `vestal login-item`.

### Changed

- Media on macOS follows the players' notifications instead of polling, and
  keeps only Spotify and Music.
- Claude and Codex usage is one row.
- Timeline labels end in an ellipsis when cut.
- The 0.3 SwiftUI views are gone; the render model draws everything.

### Fixed

- Volume is rounded to the nearest percent, not truncated.
- Credentials for CalDAV are sent only to the entry host and iCloud
  partitions.
- 401 answers reach the calendar code instead of being swallowed by the URL
  loader.
- Sweeping clock hands center correctly after a resize and end cleanly when
  the config is rescanned.

### Performance

- Shown with no background: about 2 % of a core. Hidden: 0 %.
- Renders send patches, not the whole model; unchanged renders send nothing.
- Backgrounds and the aurora draw on their own link at `backgroundFPS`;
  sweeping hands turn in Core Animation (GTK at 30 fps).
- AppleScript is compiled once; layouts are cached.

## Earlier

0.3.0 was the first version: the clock, system bar, Claude usage, media,
agenda, hosts, currencies and weather widgets on macOS, configured in JSON.
