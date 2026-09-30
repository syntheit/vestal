# Render-model fixtures

Hand-built render models, written for the Linux UI before the render engine
existed. `vestal render-file <file>` draws them on Linux; `RenderModelTests` decodes and round-trips them.

| File | What |
|---|---|
| `dashboard.json` | `examples/full.json` as v0.3 draws it: clock with world clocks, system bar, Spotify row, agenda, systems (four hosts, one offline), currencies, weather. Sizes, weights, colours and spacing follow the v0.3 SwiftUI views and the built-in presets. |
| `dashboard-patch.json` | A patch on `dashboard.json` (seq 2, base 1): the clock ticks, conduit comes back, privacy mode turns on, a long track title truncates. Each op replaces one subtree. |
| `dashboard-popup.json` | The dashboard with the `hostDetail` popup for harbor. |
| `nodes.json` | Every node type and common field: grid column kinds and `span`, rings with centres, sparklines, dividers, spacers, backgrounds, borders, opacity, clip, actions, text sizes/weights/fonts/tracking/lines/alignment, baseline and `justify: between` rows, an unknown node type and an `sf:` icon. |

The data is illustrative. These stay as the UI's drawing fixtures; the engine's
goldens replace `dashboard.json` as the reference once they match it.
