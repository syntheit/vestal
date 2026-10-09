<h1 align="center">vestal</h1>

<p align="center">
A full-screen dashboard on one key. Press it, glance, press it again.<br>
One config draws it on macOS and Linux, and your agent writes the config.
</p>

<p align="center">
<a href="https://vestal.matv.io"><img src="https://img.shields.io/badge/website-vestal.matv.io-5b6cf0" alt="Website"></a>
<a href="https://vestal.matv.io/docs/"><img src="https://img.shields.io/badge/docs-read-5b6cf0" alt="Docs"></a>
<a href="#install"><img src="https://img.shields.io/badge/install-brew%20%C2%B7%20dmg%20%C2%B7%20nix-5b6cf0" alt="Install"></a>
<img src="https://img.shields.io/badge/macOS-14%2B-555" alt="macOS 14+">
<img src="https://img.shields.io/badge/Linux-GTK%204-555" alt="Linux, GTK 4">
<a href="./LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-555" alt="License GPL-3.0"></a>
</p>

<p align="center"><img src="docs/images/hero.png" alt="The default dashboard over the aurora: a clock, this machine, music, agenda, hosts, currencies and weather"></p>

## Press a key. Glance. Press again.

- **One config.** `~/.config/vestal/config.json` drives the SwiftUI app on macOS and the GTK 4 app on Linux.
- **Your agent builds it.** Docs, schema, validation and offscreen screenshots ship in the binary, so an agent can write the config and look at the result.
- **About 50 widgets, 8 starters.** Pick a starter on the first run, then reshape it.

## Starters

<table>
<tr>
<td align="center" width="25%"><img src="docs/images/starter-default.png" alt="Default starter"><br><b>default</b></td>
<td align="center" width="25%"><img src="docs/images/starter-minimal.png" alt="Minimal starter"><br><b>minimal</b></td>
<td align="center" width="25%"><img src="docs/images/starter-developer.png" alt="Developer starter"><br><b>developer</b></td>
<td align="center" width="25%"><img src="docs/images/starter-media.png" alt="Media starter"><br><b>media</b></td>
</tr>
<tr>
<td align="center" width="25%"><img src="docs/images/starter-homelab.png" alt="Homelab starter"><br><b>homelab</b></td>
<td align="center" width="25%"><img src="docs/images/starter-markets.png" alt="Markets starter"><br><b>markets</b></td>
<td align="center" width="25%"><img src="docs/images/starter-agentops.png" alt="Agent ops starter"><br><b>agentops</b></td>
<td align="center" width="25%"><img src="docs/images/starter-focus.png" alt="Focus starter"><br><b>focus</b></td>
</tr>
</table>

## Clock faces

<p align="center"><img src="docs/images/clocks.png" alt="Eight clock faces: flip, analog, dot matrix, ring, thin, serif, stacked and condensed"></p>

<p align="center"><img src="docs/images/flip.webp" width="560" alt="The flip clock turning over a minute, over the aurora"></p>

## Backgrounds

<p align="center"><img src="docs/images/backgrounds.png" alt="Six of the backgrounds: aurora, mesh, sky, rain, topo and stars"></p>

## Widgets

<p align="center"><img src="docs/images/widgets.png" alt="Twelve widgets: now playing, review queue, watchlist, commit activity, agenda, AI plan usage, habits, focus timer, system health, CI status, containers and forecast"></p>

Every widget, at its real size with the line that adds it, is on [the site](https://vestal.matv.io/#widgets).

## Install

```sh
brew install --cask syntheit/vestal/vestal
vestal init            # writes ~/.config/vestal/config.json (vestal init --list shows the starters)
# then press cmd+shift+space to show it, and again to hide it
```

- **DMG:** download `Vestal-<version>.dmg` from [Releases](https://github.com/syntheit/vestal/releases/latest) and drag `Vestal.app` onto Applications.
- **Nix (macOS or Linux):** the flake has a Home Manager module, `programs.vestal`; see [install](https://vestal.matv.io/docs/install.html).

## More

[AGENTS.md](./AGENTS.md) (point your agent here) · [Docs](https://vestal.matv.io/docs/) · [llms.txt](https://vestal.matv.io/llms.txt) · [Changelog](./CHANGELOG.md) · [License: GPL-3.0](./LICENSE)
