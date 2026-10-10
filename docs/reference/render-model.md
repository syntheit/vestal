# The render model

vestal turns config and data into a resolved tree of nodes, and a UI only draws that tree. Every text is a string, every size a number, every icon a name plus its glyph, every color a palette name or `#rrggbbaa`. A UI never evaluates an expression, reads a source or runs an action: it lays out and draws nodes, and reports clicks and keys (`vestal docs protocol`).

`vestal render --format json` prints it; `--format tree` prints the same as an outline, the cheapest way for an agent to see what is on screen.

## Versions

- `protocol` is the major version, `1`. A breaking change bumps it.
- `minor` counts additive changes (new optional fields, new node types); it is `3`. Minor 1 added `pages` and the `page` input, and the node types `bars`, `stackedBar`, `heatmap`, `timeline` and `image`. Minor 2 added the node types `analog` and `flip`, the `display` role in `theme.fonts` (a client that predates it uses the role's family from `sans`), and the `ring` fields `dot`, `dotColor`, `ticks` and `labels` (a client that predates them draws a plain ring). Minor 3 added the node types `moon` and `matrix`, the `analog` value `ticks: "dots"` and field `nightFaceColor` (a client that predates them draws the dial without dots and one fill), and the `bar` fields `tickOverhang` and `gradient` (a client that predates the fields draws a plain bar).
- Clients must ignore fields they don't know.
- A subscriber that declares an older `minor` gets newer node types as `text` nodes carrying their `alt`.

## Snapshot

```jsonc
{
  "type": "snapshot",
  "protocol": 1,
  "minor": 3,
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
| `pages` | Present with two or more pages: `items` (the pages in paging order, each `{name, title, key}`), `index` (the current view's place in `items`, absent when it is not a page), `direction` (`1` or `-1`: which way the last change of view went; absent when there was none or it has no direction), and the settings `transition`, `indicator`, `swipe` and `wrap` (`vestal docs views`). A UI draws the transition on a change of `view`, and the dots when `indicator` is `dots`. |
| `visible` | Whether the dashboard should be on screen. |
| `theme.colors` | Every palette name a node may use, resolved to `#rrggbbaa`. |
| `theme.fonts` | A family per role (`sans`, `mono`, `rounded`, and `display` when set: the clock and big-number family); `null` is the platform default. The config's `typeface` is already resolved into it. A text node's `font` is a role or a family name. |
| `theme.icons` | The icon font family per weight; `mode` (`native` or `phosphor`) when the config sets `theme.icons`. |
| `theme.dim` | The config's `theme.dim`, clamped to 0 to 1, when it sets one: the opacity of `bg` over the blurred desktop for `aurora` and `blur`. Absent: the UI's default (0.5 in the GTK UI; no tint in the macOS UI). |
| `theme.backdrop` | The config's `theme.backdrop` (`self`, `compositor` or `none`) when it sets one. Absent: `self` in the GTK UI where the compositor can capture the screen; the macOS UI ignores it. |
| `theme.blur` | The config's `theme.blur`, clamped to 0 to 200, when it sets one: the radius in points of the GTK UI's own blur. Absent: 48. |
| `root` | The view's tree. |
| `popup` | `null`, or `{"id": "popup", "width": 520, "node": <node>}`. |
| `diagnostics` | Problems found while rendering (below). |

## Nodes

Keys are sorted and defaults are left out, so output is deterministic.

Common fields

| Field | Default | |
|---|---|---|
| `id` | required | Unique in the tree (below). |
| `type` | required | One of the types below. |
| `width`, `height` | fit | A number, or `"fill"`. |
| `minWidth`, `maxWidth`, `minHeight`, `maxHeight` | none | |
| `padding` | `[0, 0, 0, 0]` | `[top, right, bottom, left]`, inside the frame. |
| `background` | none | A color, painted on the padded frame. |
| `radius` | `0` | |
| `border` | none | `{ "color", "width" }` |
| `opacity` | `1` | Multiplies the subtree. |
| `clip` | `false` | |
| `spaceBefore` | none | Replaces the parent stack's `gap` before this node. |
| `alignSelf` | the parent's `align` | `start`, `center`, `end`, `stretch`. |
| `span` | `1` | Grid columns. |
| `action` | `false` | Clickable: the whole frame sends `invoke` with this id. |
| `alt` | none | Plain-text rendition. |

Types

| Type | Fields (default) | Draws |
|---|---|---|
| `stack` | `axis` (`v` or `h`), `gap` (0), `align` (`start`; also `center`, `end`, `stretch`, and `baseline` for `h`), `justify` (`start`, `center`, `end`, `between`), `children` | Nothing itself; lays out its children. |
| `grid` | `columns` (`[{ "width": number \| "fill" \| "fit", "align" }]`), `gap` (0), `rowGap` (0), `children` | Children row by row, honoring `span`; cells centered vertically. |
| `text` | `text`, `size` (13), `weight` (400), `font` (`sans`), `color` (`text`), `tracking` (0), `lines` (unlimited), `textAlign` (`start`) | One run of text, case already applied; cut at the tail with `…` beyond `lines`. |
| `icon` | `name`, `glyph` (one character; absent for `sf:` names), `weight` (`regular` or `fill`), `size` (13), `color` (`text`) | The glyph in the icon font, centered in a `size`×`size` box. |
| `bar` | `value` (0…1), `start` (0), `overlay` (0…1), `overlayPosition` (`above`), `tick` (0…1), `tickColor`, `tickOverhang` (0), `gradient`, `color`, `trackColor`, `overlayColor`, `radius` (2) | A rounded track, the fill from `start` to `value`, the overlay above or below it, and a 1.5 point mark at `tick` that reaches `tickOverhang` points above and below the bar. `gradient` (two or more colors) runs left to right across the fill itself instead of `color`. |
| `ring` | `value` (0…1), `sweep` (270), `thickness` (6), `color`, `trackColor`, `center` (a node), `dot` (false), `dotColor` (`text`), `ticks` (0), `labels` (`[]`) | An arc track with its gap at the bottom, the fill arc with round caps, and `center` inside. A `sweep` of 360 has no gap and starts at the top. `dot` draws a dot, `thickness` × 1.1 in radius, on the fill's end. `ticks` marks the outside: that many marks evenly spaced over the sweep (a full circle: round it; an arc: the first and last on its ends), every fourth longer and brighter (`text` at 50%, 1.5 wide, against 20%, 1 wide), and the arc moves 15 points inwards to leave room. `labels` (up to four) are drawn inside the arc, 20 points from it, in the same way along the sweep, in `dim`, size 10, mono. Its size is its `width`. |
| `spark` | `values`, `min`, `max`, `color`, `fill`, `strokeWidth` (1.5), `dot` (false), `dotAt` (0…1), `dotColor` | A polyline, x evenly spaced, y scaled to `min`…`max`; fewer than two values draw nothing. A dot on the last point, or with `dotAt` at that fraction of the width, on the line. |
| `divider` | `axis` (`h`), `thickness` (0.5), `color` (`dim`) | A rule filling the width (`h`) or the height (`v`). |
| `spacer` | `min` (0) | Nothing. |
| `bars` | `values` (one number per column), `max` (1), `colors` (one per column), `barWidth` (columns share the width), `gap` (3) | Columns from the left edge on the bottom line, each `value / max` tall (clamped, at least 1 when above 0), corners rounded by 2. |
| `stackedBar` | `segments` (`[{ "value": 0…1, "color" }]`), `trackColor` (`track`), `radius` (4) | A track and the segments from the leading edge, each `value` of the width, all inside one rounded shape. |
| `heatmap` | `cells` (a color or `null` per cell), `rows` (7), `direction` (`columns`), `cell` (8), `gap` (2), `radius` (2), `trackColor` (`track`) | Square cells. `columns`: cell `i` is at column `i / rows`, row `i % rows`. `rows`: row-major with `ceil(count / rows)` columns. `null` draws a `trackColor` cell; positions past the last cell draw nothing. |
| `timeline` | `items` (`[{ "start", "end", "label", "color", "lane" }]`), `ticks` (`[{ "at", "label" }]`), `lanes` (1), `now`, `nowColor` (`accent`) | A time axis, everything as fractions 0…1 of the width (`end` absent: a point marker). The bottom 12 points are tick labels (dim, 9); above them a faint line at each tick, the items on `lanes` equal rows 2 apart (a bar at least 3 wide, corners 3; a point is a dot at most 8 across), then a 1.5 wide `nowColor` line at `now`. An item's `label` is drawn inside its bar (10, medium, in `bg`) only when it fits with 4 either side and the lane is 12 or taller; a tick label only when it clears the previous one by 4. |
| `analog` | `size` (236), `ticks` (`hours`; `none`, `minutes`, `dots`), `seconds` (`none`; `step`, `sweep`), `dateWindow` (false), `numerals` (false), `zone` (the system's), `color` (`text`), `faceColor`, `nightFaceColor`, `secondsColor` (`bad`), `pivotColor` (`accent`) | A round clock the UI draws and runs by itself: the core sends it once and never again for a tick. The UI reads the time in `zone` and moves the hands: the hour and minute hands continuously, the seconds hand once a second (`step`) or every frame (`sweep`), and only while the dashboard is shown (nothing runs, and no timer, while it is hidden). Reduced motion turns `sweep` into `step`. `size` is its width and height. The face is a circle (`faceColor`, stroked in `color` at 20%); with `ticks` `none` it has a dot at twelve, short hands and no tails, otherwise sixty marks (`minutes`) or twelve (`hours`), heavier at the hours, and hands with tails. `dots` is for a dial of about 64: twelve dots (larger at 12, 3, 6 and 9) on a radius 5 inside the edge, hands 15 and 23 long with no tails, and a small pivot. With `nightFaceColor` the UI fills the face with it instead of `faceColor` while the hour in `zone` is before 07:00 or from 19:00, so a world dial turns dark at night without the core sending anything. `dateWindow` is a box with the day of the month right of the pivot; `numerals` draw 1 to 12. The seconds hand has a counterweight dot. Proportions are fixed by the face's size (`AnalogGeometry` in VestalCore). |
| `flip` | `text`, `small` (`""`), `size` (90), `smallSize` (40), `color` (`text`), `tile`, `tileBottom`, `animate` (true) | Split-flap tiles in a row with their bottoms on one line: one tile per character of `text` (80 × 114 at `size` 90, scaling with it), then the characters of `small` on smaller tiles (36 × 52 at `smallSize` 40, 14 apart from the big ones). `:` is two small squares in a colon cell, a space a gap. Each tile is two halves, `tile` above and `tileBottom` below, with a seam. The UI keeps the characters it last drew: when a later model changes a tile's character it folds over (the top half falls to the seam over 170 ms, then the new bottom half rises over 170 ms) and the other tiles stay; a node that is new, or whose number of tiles changed, appears without a fold, as does everything with `animate` false or under reduced motion. Its size follows from the text (`FlipLayout` in VestalCore). |
| `matrix` | `text` (digits, `:`, anything else a blank digit), `cells` (`dots`; `segments`), `size` (84), `color` (`cyan`), `offColor` | A display panel with every cell present: `dots` is a 5 by 7 grid per digit (dots 12 apart, radius 4.3, 72 per digit and 24 per colon at size 84, less the last gap), `segments` seven slanted (skew −6°) segments per digit (56 per digit, 22 per colon, 86 high); lit cells in `color`, the rest in `offColor` (`text` at 6.5%). The UI derives the cells from `text` alone, so a changing `text` is the only update. Its size is the panel's (the height is `size`, 84 default; the width follows the text). |
| `moon` | `phase` (0…1), `size` (22), `color` (`#e8e4d4ff`), `trackColor` | A disc in `trackColor` with the lit part over it: the right side while `phase` is at most 0.5 (waxing), the left after. The terminator is a half ellipse as wide as `\|cos(2π phase)\|` of the radius (the radius is `size / 2 - 1`), bulging into the lit side for a crescent and the dark side for a gibbous moon. Its size is `size`. |
| `image` | `path`, `fit` (`cover`), `radius` (6) | The picture in the file at `path`, scaled to `cover` the frame (cropped) or to be `contained` in it, clipped to a rounded rectangle. No `path`, or a file that can't be read: an empty rounded rectangle in `track`. |

Config types map onto these: `row` → `stack` h; `list` and `table` → `stack` or `grid`; `progress` → a `stack` h of `text`, `bar`, `text`; `gauge` → a `stack` v of `ring` and `text`; `sparkline` → `spark`; `switch` → the chosen case; `bars` (vertical) → `bars`, or a `stack` v of `bars` and a `stack` h of `text` labels; `bars` (horizontal) → a `grid` of `text`, `bar`, `text` rows; `stackedBar` → `stackedBar`, or a `stack` v of it and a `stack` h of dot (`bar`) and `text` entries; `heatmap`, `timeline` and `image` → themselves; `analog` and `flip` → themselves, and `gauge` also takes `dot`, `dotColor`, `ticks`, `labels` and a `center` widget. Templates disappear.

`image.path` is a path on the machine running vestal, never bytes. For a local `src` it is the file itself (`~` expanded). For an http(s) `src` vestal fetches the picture (at most 5 MB, off the UI's thread) into its cache directory, in `images/` named by the SHA-256 of the URL, and `path` is that file; until it arrives `path` is absent and a patch brings it. A client that draws the model on the same machine reads the file; one that can't reach it draws the empty state.

The core can't measure text, so the label of a timeline item and its tick labels are drawn by the UI, which decides what fits. Every other label of these types is a `text` node.

## Layout

Units are logical points (macOS points, Wayland logical pixels).

1. A number is exact; `fill` takes what the parent offers on that axis; absent means fit (the content's size, capped by the offer). A container with a `fill` child on an axis is itself `fill` there, unless it has a fixed size.
2. Stacks place children in order with each child's `spaceBefore`, else the `gap`, before every child but the first. Fixed and fit children are measured first; the rest is shared equally by the `fill` children (never below 0). `alignSelf` or `align` places each child across; `stretch` makes it as wide as the stack. `justify` spreads leftover space when no child fills.
3. Grids: fixed columns take their width, `fit` columns their widest cell, `fill` columns share the rest. A row is as tall as its tallest cell.
4. `padding` is inside the frame; `background`, `border` and `radius` paint the padded frame; `min…`/`max…` clamp after sizing (`maxWidth` includes padding).
5. The root is centered on the screen both ways, `min(maxWidth, window width)` wide.
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
{ "id": "main/exchange/1/@EUR/1", "field": "text", "severity": "error", "code": "expr-runtime", "message": "tonumber: cannot parse \"n/a\" as a number" }
```

Expression runtime errors, unknown icons and colors used at render time, duplicate row ids, failed sources. UIs needn't show them; `vestal render` prints them, and `vestal render --strict` exits 3 when there are any.
