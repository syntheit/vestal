# The render model

vestal turns config and data into a resolved tree of nodes, and a UI only draws that tree. Every text is a string, every size a number, every icon a name plus its glyph, every colour a palette name or `#rrggbbaa`. A UI never evaluates an expression, reads a source or runs an action: it lays out and draws nodes, and reports clicks and keys (`vestal docs protocol`).

`vestal render --format json` prints it; `--format tree` prints the same as an outline, the cheapest way for an agent to see what is on screen.

## Versions

- `protocol` is the major version, `1`. A breaking change bumps it.
- `minor` counts additive changes (new optional fields, new node types); it is `0`.
- Clients must ignore fields they don't know.
- A subscriber that declares an older `minor` gets newer node types as `text` nodes carrying their `alt`.

## Snapshot

```jsonc
{
  "type": "snapshot",
  "protocol": 1,
  "minor": 0,
  "seq": 1,
  "view": "main",
  "views": [ { "name": "main", "key": "1" }, { "name": "focus", "title": "Focus", "key": "2" } ],
  "visible": true,
  "theme": {
    "background": "aurora",
    "colors": { "text": "#ffffffff", "subtle": "#ffffff80", "dim": "#ffffff4d", "accent": "#7aa1f7ff", "…": "…" },
    "fonts": { "sans": null, "mono": null, "rounded": null },
    "icons": { "set": "phosphor", "fonts": { "regular": "Phosphor", "fill": "Phosphor-Fill" } }
  },
  "root": { "id": "main", "type": "stack", "axis": "v", "gap": 24, "align": "center", "maxWidth": 680, "padding": [48, 48, 48, 48], "width": "fill", "children": [ "…" ] },
  "popup": null,
  "diagnostics": []
}
```

| Field | |
|---|---|
| `seq` | Increases by one with every message that changes the tree (per subscriber). |
| `view`, `views` | The current view, and every view sorted by name (JSON objects keep no order), for UIs with a switcher. |
| `visible` | Whether the dashboard should be on screen. |
| `theme.colors` | Every palette name a node may use, resolved to `#rrggbbaa`. |
| `theme.fonts` | A family per role; `null` is the platform default. |
| `theme.icons` | The icon font family per weight; `mode` (`native` or `phosphor`) when the config sets `theme.icons`. |
| `root` | The view's tree. |
| `popup` | `null`, or `{"id": "popup", "width": 520, "node": <node>}`. |
| `diagnostics` | Problems found while rendering (below). |

## Nodes

Keys are sorted and defaults are left out, so output is deterministic.

**Common fields**

| Field | Default | |
|---|---|---|
| `id` | required | Unique in the tree (below). |
| `type` | required | One of the types below. |
| `width`, `height` | fit | A number, or `"fill"`. |
| `minWidth`, `maxWidth`, `minHeight`, `maxHeight` | none | |
| `padding` | `[0, 0, 0, 0]` | `[top, right, bottom, left]`, inside the frame. |
| `background` | none | A colour, painted on the padded frame. |
| `radius` | `0` | |
| `border` | none | `{ "color", "width" }` |
| `opacity` | `1` | Multiplies the subtree. |
| `clip` | `false` | |
| `spaceBefore` | none | Replaces the parent stack's `gap` before this node. |
| `alignSelf` | the parent's `align` | `start`, `center`, `end`, `stretch`. |
| `span` | `1` | Grid columns. |
| `action` | `false` | Clickable: the whole frame sends `invoke` with this id. |
| `alt` | none | Plain-text rendition. |

**Types**

| Type | Fields (default) | Draws |
|---|---|---|
| `stack` | `axis` (`v` or `h`), `gap` (0), `align` (`start`; also `center`, `end`, `stretch`, and `baseline` for `h`), `justify` (`start`, `center`, `end`, `between`), `children` | Nothing itself; lays out its children. |
| `grid` | `columns` (`[{ "width": number \| "fill" \| "fit", "align" }]`), `gap` (0), `rowGap` (0), `children` | Children row by row, honouring `span`; cells centred vertically. |
| `text` | `text`, `size` (13), `weight` (400), `font` (`sans`), `color` (`text`), `tracking` (0), `lines` (unlimited), `textAlign` (`start`) | One run of text, case already applied; cut at the tail with `…` beyond `lines`. |
| `icon` | `name`, `glyph` (one character; absent for `sf:` names), `weight` (`regular` or `fill`), `size` (13), `color` (`text`) | The glyph in the icon font, centred in a `size`×`size` box. |
| `bar` | `value` (0…1), `overlay` (0…1), `overlayPosition` (`above`), `color`, `trackColor`, `overlayColor`, `radius` (2) | A rounded track, the fill from the leading edge, the overlay above or below it. |
| `ring` | `value` (0…1), `sweep` (270), `thickness` (6), `color`, `trackColor`, `center` (a node) | An arc track with its gap at the bottom, the fill arc with round caps, and `center` inside. Its size is its `width`. |
| `spark` | `values`, `min`, `max`, `color`, `fill`, `strokeWidth` (1.5), `dot` (false) | A polyline, x evenly spaced, y scaled to `min`…`max`; fewer than two values draw nothing. |
| `divider` | `axis` (`h`), `thickness` (0.5), `color` (`dim`) | A rule filling the width (`h`) or the height (`v`). |
| `spacer` | `min` (0) | Nothing. |

Config types map onto these: `row` → `stack` h; `list` and `table` → `stack` or `grid`; `progress` → a `stack` h of `text`, `bar`, `text`; `gauge` → a `stack` v of `ring` and `text`; `sparkline` → `spark`; `switch` → the chosen case. Templates disappear.

## Layout

Units are logical points (macOS points, Wayland logical pixels).

1. A number is exact; `fill` takes what the parent offers on that axis; absent means fit (the content's size, capped by the offer). A container with a `fill` child on an axis is itself `fill` there, unless it has a fixed size.
2. **Stacks** place children in order with each child's `spaceBefore`, else the `gap`, before every child but the first. Fixed and fit children are measured first; the rest is shared equally by the `fill` children (never below 0). `alignSelf` or `align` places each child across; `stretch` makes it as wide as the stack. `justify` spreads leftover space when no child fills.
3. **Grids**: fixed columns take their width, `fit` columns their widest cell, `fill` columns share the rest. A row is as tall as its tallest cell.
4. `padding` is inside the frame; `background`, `border` and `radius` paint the padded frame; `min…`/`max…` clamp after sizing (`maxWidth` includes padding).
5. The root is centred on the screen both ways, `min(maxWidth, window width)` wide.
6. A fit text is as wide as its line, capped by the offer; it wraps unless `lines` is 1. `baseline` lines up the first baselines of text children.
7. Hidden widgets have no node.
8. Nothing scrolls: content taller than the window is clipped at the bottom.

Fonts differ between OSes, so layouts match in structure, not to the pixel. The core can't measure text, so overflow is found by the renderer: `vestal screenshot --frames` writes every node's frame with `clipped` and `truncated` flags.

## Node ids

Ids are stable across updates, which keeps patches small.

| Node | Id |
|---|---|
| a view's root | `<view>` |
| a root child from `widgets` | `<view>/<widget key>` |
| any other child | `<parent id>/<its id field, or its index in the config's children>` (the index in the config, so hiding a sibling doesn't renumber) |
| a list or table row | `<list id>/@<rowId>`, with `/`, `@` and `%` percent-encoded; a duplicate gets `~2`, `~3` |
| a switch's case | `<switch id>/=<case>`, the default `=*` |
| a template instance | the instance's id; the body's nodes use their index paths |
| the popup | `popup/…` |

`vestal explain <id or widget key>` tells everything about one node: its template chain, source, `vars`, `when`, and fields as written and resolved.

## Patches

After a snapshot, changes come as patches:

```jsonc
{ "type": "patch", "protocol": 1, "seq": 2, "base": 1, "ops": [
  { "op": "replace", "id": "main/claude/0/1", "node": { "id": "main/claude/0/1", "type": "text", "text": "19% / 21%", "size": 12, "font": "mono", "color": "subtle" } }
] }
```

| Op | Fields | |
|---|---|---|
| `replace` | `id`, `node` | Swap that subtree. |
| `root` | `node`, `view` | A new root (a view switch or a reload). |
| `popup` | `popup` (object or `null`) | |
| `theme` | `theme` | After a reload that changed it. |
| `views` | `views` | |
| `diagnostics` | `diagnostics` | The full list. |

The diff runs top-down: a node whose own fields or ordered child ids changed is replaced whole; otherwise its children are compared. Apply ops in order. When `base` isn't the last `seq` you applied, ask for a fresh snapshot.

## Diagnostics

```jsonc
{ "id": "main/exchange/1/@BRL/1", "field": "text", "severity": "error", "code": "expr-runtime", "message": "tonumber: cannot parse \"n/a\" as a number" }
```

Expression runtime errors, unknown icons and colours used at render time, duplicate row ids, failed sources. UIs needn't show them; `vestal render` prints them, and `vestal render --strict` exits 3 when there are any.
