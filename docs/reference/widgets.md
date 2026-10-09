# Widgets

A widget is a JSON object with a `type`. Define it under `widgets.<key>` and list the key in a view's `children`, or write it inline wherever a widget goes (`children`, `row`, `cases`, `default`, `empty`, `loading`, popups). A string where a widget goes is a reference to `widgets.<string>`.

`vestal docs widget/<type>` lists each type's fields with their kind (`vestal docs expressions`), default and an example. The types:

| Group | Types |
|---|---|
| Containers | `stack` (top to bottom), `row` (left to right), `grid` (aligned columns), `list` (an array as rows), `table` (a list with aligned columns), `switch` (one child picked by a value) |
| Primitives | `text`, `icon`, `progress` (bar), `gauge` (ring), `sparkline`, `keyValue`, `divider`, `spacer` |
| Charts | `bars`, `stackedBar`, `heatmap`, `timeline`, `image` |
| Clocks | `analog`, `flip` (the faces of the `clock` preset) |
| Built-in templates | `section`, `stat`, `badge`, and the v0.3 widgets `clock`, `systemBar`, `media` (alias `spotify`), `agendaList`, `systemHealth`, `keyValueList`, `weatherCard`, `claudeUsage`, `aiUsage` (Claude and Codex plan usage), and the system presets `cpuCores`, `memoryBreakdown`, `diskBreakdown`, `networkRates`, `topProcesses`, `batteryPower`, and the developer widgets `reviewQueue`, `ciStatus`, `commitActivity` and `flakeInputs`, and the homelab widgets `containers`, `tailnet`, `uptimeMonitors`, `backups` and `transfers`, and `headlines`, `cryptoTicker`, `watchlist`, `dayTimeline`, `nextMeeting`, `focusTimer`, `todoFile`, `habits`, `homeAssistant` and `nowPlaying` (`vestal docs presets`) |
| Your templates | any name under `templates` (`vestal docs templates`) |

## Fields every widget takes

| Field | Kind | Default | |
|---|---|---|---|
| `id` | structural | derived | A stable id segment for the node (`vestal docs render-model`). |
| `source` | name or definition | inherited | Sets `.` and `$data` for this subtree. An object is an inline source. |
| `input` | expr | none | Re-roots `.` for this subtree: `".current_condition[0]"`. |
| `vars` | object of expr | none | Binds `$name` for this subtree. |
| `when` | expr | shown | Hidden when it yields `false` or `null`. A hidden widget takes no space. |
| `loading` | `hide`, `show` or a widget | `hide` | While this widget's own `source` has never produced data. `show` renders with `.` = `null`. |
| `style` | object | inherited | Text style, inherited by everything under it (`vestal docs styling`). |
| `width`, `height` | number, `"fill"`, `"fit"` | `"fit"` | Points; `fill` takes the space the parent offers. |
| `minWidth`, `maxWidth` | number | none | |
| `padding` | number or `[top, right, bottom, left]` | `0` | |
| `background` | colour | none | Painted behind the padded frame. |
| `border` | object | none | `{"color": "accent@0.6", "width": 1}`: an outline along the padded frame, following `radius`. `color` defaults to `dim`, `width` to 1 (0 draws none); both may be `{"expr": …}`. |
| `radius` | number | `0` | Corner radius of the background and the border. |
| `opacity` | 0 to 1 | `1` | |
| `clip` | boolean | `false` | Clip the children to the frame. |
| `spaceBefore` | number | the parent's gap | Space before this child in a stack or row. Ignored on the first visible child. |
| `alignSelf` | `start`, `center`, `end`, `stretch` | the parent's `align` | |
| `span` | integer | `1` | Grid columns this child takes. |
| `action` | action or list | none | Run on click and on `key` (`vestal docs actions`). |
| `key` | key or `"auto"` | none | A key that runs `action` (`vestal docs keys`). |
| `keyHint` | text | the first text | Letters `"auto"` tries, in order. |
| `alt` | text | derived | Plain text for `vestal render --format tree` and text-only UIs. |

`size`, `weight` and `color` are also accepted directly on `text`, `icon` and templates, as shorthands for `style.<field>`.

## Layout in brief

- A stack or row places its visible children in order with `gap` between them (a child's `spaceBefore` replaces the gap before it).
- `fill` takes the space left over on that axis, shared equally among `fill` siblings. A container with a `fill` child is itself `fill` on that axis. Without a size a widget fits its content.
- Text wraps unless `lines` limits it; then it is cut with `…`. Nothing scrolls: content taller than the screen is cut off at the bottom, so keep lists short with `limit`.
- A view's root is at most `maxWidth` (680) wide, centred on the screen both ways (`vestal docs views`).

## Containers

### `stack`

Children top to bottom. `align` places them across (`start`, `center`, `end`, `stretch`); `justify` distributes leftover height (`start`, `center`, `end`, `between`).

```json
{ "type": "stack", "gap": 4, "align": "center", "children": [
  { "type": "text", "text": "{{ now | fmt_time(\"HH:mm\") }}", "style": { "size": "display", "weight": "thin", "font": "mono" } },
  { "type": "text", "text": "{{ now | fmt_localized(\"EEEEMMMMd\") }}", "style": { "color": "subtle" } }
] }
```

### `row`

Children left to right. Same fields as `stack`; `align` defaults to `center` and also takes `baseline` (first text baselines line up). A `spacer` pushes what follows to the end.

```json
{ "type": "row", "gap": 10, "width": "fill", "source": "system", "children": [
  { "type": "icon", "name": "cpu", "size": 12, "color": "subtle" },
  { "type": "text", "text": "{{ .cpu.percent | round }}%", "style": { "font": "mono" } },
  { "type": "spacer" },
  { "type": "text", "text": "up {{ .uptime | fmt_uptime_long }}", "style": { "color": "dim" } }
] }
```

### `grid`

Children row by row in aligned columns. `columns` is a count of equal `fill` columns, or a list of `{"width": number | "fill" | "fit", "align": "start" | "center" | "end"}`. A child may set `span`. `gap` is between columns, `rowGap` between rows.

```json
{ "type": "grid", "columns": [ { "width": 80 }, { "width": "fill" } ], "gap": 12, "rowGap": 6, "source": "system", "children": [
  { "type": "text", "text": "CPU", "style": { "color": "subtle" } },
  { "type": "progress", "value": ".cpu.percent", "text": "" },
  { "type": "text", "text": "Memory", "style": { "color": "subtle" } },
  { "type": "progress", "value": ".memory.percent", "text": "" }
] }
```

### `list`

An array as rows: the only way to iterate. `items` is an expression (all its outputs, or its single array) or a JSON array of static data. Then, in order: `filter` (keep an item when true), `sortBy` (ascending, stable), `reverse`, `limit`. In `row`, `.` is the item, and `$item`, `$index` and `$parent` (the outer row's item) are bound. `rowId` gives each row a stable identity (use a real id such as `.url`, so a refresh redraws only the rows that changed). `direction` is `column`, `row` or `grid` (with `columns`). `empty` is text or a widget shown with no rows; without it an empty list is hidden.

```json
{
  "type": "list",
  "source": "system",
  "items": ".disks",
  "sortBy": ".percent",
  "reverse": true,
  "limit": 3,
  "rowId": ".mount",
  "empty": "No disks",
  "row": { "type": "text", "text": "{{ .mount }}: {{ .free | fmt_bytes }} free", "lines": 1 }
}
```

### `table`

A list whose columns line up across rows. `items`, `filter`, `sortBy`, `reverse`, `limit`, `rowId` and `empty` work as for `list`. Each column is `{"header", "text"}` or `{"header", "value", "format"}`, with `width` (points, `fill` or `fit`), `align`, `style` and `color` (which may use `$value`). `header: false` hides the header row (size 10, semibold, `dim`, upper case). `rowAction` is an action per row.

```json
{
  "type": "table",
  "source": "system",
  "items": ".disks",
  "columns": [
    { "header": "Mount", "text": "{{ .mount }}", "style": { "font": "mono" } },
    { "header": "Used", "value": ".percent", "format": "percent", "align": "end", "color": { "steps": [[0, "text"], [80, "warn"], [95, "bad"]] } },
    { "header": "Free", "value": ".free", "format": "bytes", "align": "end", "style": { "color": "subtle" } }
  ]
}
```

### `switch`

One child picked by a value: `on` is evaluated and turned into text, `cases` maps values to widgets, and `default` is used when none matches (without it, nothing is drawn).

```json
{
  "type": "switch",
  "source": "media",
  "on": ".state",
  "cases": {
    "playing": { "type": "icon", "name": "play", "weight": "fill", "color": "good" },
    "paused": { "type": "icon", "name": "pause", "weight": "fill", "color": "subtle" }
  },
  "default": { "type": "text", "text": "off", "style": { "color": "dim" } }
}
```

## Primitives

### `text`

Text, from `text` (with `{{ }}` holes), or from `value` run through `format` between `prefix` and `suffix` (`placeholder` when the value is `null`). An optional leading `icon` is drawn in the text's colour at 0.8 times its size. `lines` limits the lines (cut with `…`); `align` places the text in its frame.

```json
{ "type": "text", "source": "system", "icon": "hard-drives", "value": ".disks[0].free", "format": "bytes", "suffix": " free", "style": { "size": 12, "color": "subtle" } }
```

### `icon`

A glyph from the bundled Phosphor set (`vestal icons <query>`), `regular` or `fill`. `name` may be computed:

```json
{ "type": "icon", "source": "system", "name": { "expr": ".battery.percent // 0 | step([[0,\"battery-empty\"],[13,\"battery-low\"],[38,\"battery-medium\"],[63,\"battery-high\"],[88,\"battery-full\"]])" }, "size": 12, "color": "good" }
```

### `progress`

A horizontal bar: `(value − min) / (max − min)`, clamped. Optional `label` before it, `text` after it (default `"{{ $value | round }}%"`; `""` for none), and an `overlay`, a second value on the same scale drawn `above` or `below` the fill. `start` (same scale) moves where the fill begins, so the fill covers `start` to `value`: a range bar for a low-to-high span. `tick` (same scale) draws a thin mark, `tickColor` its colour (default white at about 55%): where usage would be at an even pace, say. `width` is the bar's own width (default `fill`).

```json
{ "type": "progress", "source": "system", "label": "RAM", "labelWidth": 30, "value": ".memory.percent", "overlay": ".memory.pressure", "width": 120, "textWidth": 34, "color": "purple" }
```

### `gauge`

A ring with center `text` (default `"{{ $value | round }}"`) and an optional `label` under it. `sweep` is the arc in degrees, with the gap at the bottom; 360 closes the ring and starts it at the top. `dot` (with `dotColor`, default `text`) draws a dot on the fill's end; `ticks` marks the outside (that many marks, every fourth longer, the ring moves in to make room); `labels` (up to four texts, with `{{ }}` holes) sit inside the ring at the quarters of the sweep. `center` is a widget drawn in the middle instead of `text`. The `clock` preset's `ring` face is a gauge with all of these.

```json
{ "type": "gauge", "size": 272, "thickness": 5, "sweep": 360, "ticks": 24, "dot": true, "value": "$fraction", "min": 0, "max": 1,
  "labels": ["00", "06", "12", "18"], "center": { "type": "text", "text": "{{ now | fmt_time(\"HH:mm\") }}" } }
```

```json
{ "type": "gauge", "source": "system", "label": "CPU", "value": ".cpu.percent", "text": "{{ $value | round }}%", "color": { "steps": [[0, "good"], [70, "warn"], [90, "bad"]] } }
```

### `analog`

A round clock the UI draws and runs by itself, from the time in `zone` (default: the system's): the render model carries the options once, and the UI moves the hands, so the core pushes nothing per frame. `size` is its diameter (default 236 without ticks, 260 with); `ticks` is `none` (a hairline ring, a dot at twelve, short hands), `hours` (twelve marks) or `minutes` (sixty, heavier at the hours); `seconds` is `false`, `true` or `"step"` (the red hand moves once a second) or `"sweep"` (every frame, while the dashboard is shown; with reduced motion it steps); `dateWindow` shows the day of the month in a window at three o'clock; `numerals` draws 1 to 12. `color` (hands, ticks, numerals; `text`), `faceColor`, `secondsColor` (`bad`) and `pivotColor` (`accent`, or the seconds color with a seconds hand) are palette colors. A hidden dashboard runs nothing: no frames and no timers.

```json
{ "type": "analog", "size": 260, "ticks": "minutes", "seconds": "sweep", "dateWindow": true, "zone": "Asia/Tokyo" }
```

### `flip`

Split-flap tiles: one per character of `text` (digits; `:` is a colon and a space a gap), then the characters of `small` on smaller tiles (seconds). `size` (90) is the big tiles' font size and `smallSize` (40) the small ones'; the tiles' look comes from `color` (`text`) and `tileColor` (default: the palette's `bg`, lightened; the lower half is a little darker). When a later render changes a character, that tile folds over (170 ms for each half) while the others stay; `animate: false`, and reduced motion, swap the character instead.

```json
{ "type": "flip", "text": "{{ now | fmt_time(\"HH:mm\") }}", "small": "{{ now | fmt_time(\"ss\") }}" }
```

### `sparkline`

A line from `values` (an array of numbers), or from `value` plus `history`, which records the value on the widget's source at every fetch (`vestal docs sources`). `min` and `max` fix the scale; `fill` colours the area under the line; `dot` marks the last point, or `dotAt` (0 to 1, a fraction of the width, `dotColor` for its colour) a point along the line, such as the sun on its arc. Fewer than two points draw nothing, keeping the size.

```json
{ "type": "sparkline", "source": "system", "value": ".cpu.percent", "history": { "size": 120 }, "min": 0, "max": 100, "height": 32, "fill": "accent@0.15", "dot": true }
```

### `keyValue`

Labelled values side by side. Each item has a `label` and a `value` (with `format`) or a `text`, and may have its own `source`, `vars`, `when`, `color`, `action` and `key`. An item whose source has no data, whose `when` is false or whose value is `null` is skipped; the widget is hidden when every item is.

```json
{
  "type": "keyValue",
  "source": "system",
  "items": [
    { "label": "CPU", "value": ".cpu.percent", "format": "percent" },
    { "label": "Load", "text": "{{ .cpu.load[0] | fmt_fixed(2) }}" },
    { "label": "Battery", "when": ".battery != null", "value": ".battery.percent", "format": "percent" }
  ]
}
```

### `divider`

A rule: `axis: "h"` (default) fills the width, `v` the height.

```json
{ "type": "divider", "thickness": 1, "color": "track" }
```

### `spacer`

Flexible space along the parent's axis: in a row it pushes the rest to the end. With a fixed `width` or `height` it is a fixed gap.

```json
{ "type": "spacer", "height": 12 }
```

## Charts

Five primitives draw many values at once. They share `sparkline`'s conventions: data is an expression (or a literal array), colours are palette names, `name@alpha`, `{"steps": …}` or `{"expr": …}`, and sizes are points (`theme.scale` multiplies them). A `null` data field draws an empty chart of the same size, or shows the widget's `placeholder` text when it has one; an empty array is data, not null, and draws an empty chart. Every chart has an `alt` (a summary of its values) for `vestal render --format tree` and for clients older than render-model minor 1 (`vestal docs render-model`).

### `bars`

A bar chart. `values` is an expression (or a literal array) giving numbers, or objects `{"value", "label", "color"}`; a `null` value is an empty slot. `max` is the value of a full bar (a number or an expression; default the largest value). `color` is one colour for every bar, or `{"steps": …}` applied to each bar's value; an object's own `color` wins.

`orientation: "vertical"` (default) draws columns, 160 wide and 48 tall unless `width` and `height` say otherwise (`height` is the columns' height). The columns share the width, `gap` (3) apart, or are `barWidth` wide, in which case the widget is as wide as they are. With `labels: true` (default `false`) each `label` is drawn small and dim under its column; an empty label draws nothing, and a label wider than its column is cut with `…`, so label every Nth bar for a long series. `orientation: "horizontal"` draws a row per bar: its `label` before the bar, the bar (`barWidth` thick, 6; `gap` between rows, 6), and its value after it, rounded, or through `format` (a text format name, as on `text`). `labels` defaults to `true` there; `labelWidth` fixes the label column's width (default the widest label). Horizontal bars fill the width.

```json
{ "type": "bars", "source": "system", "values": "[{value: .cpu.load[0], label: \"1m\"}, {value: .cpu.load[1], label: \"5m\"}, {value: .cpu.load[2], label: \"15m\"}]", "labels": true, "barWidth": 24, "gap": 8, "height": 48, "color": { "steps": [[0, "good"], [2, "warn"], [4, "bad"]] } }
```

```json
{ "type": "bars", "source": "system", "orientation": "horizontal", "values": "[.disks[] | {value: .percent, label: .mount}]", "max": 100, "format": "percent", "color": { "steps": [[0, "good"], [80, "warn"], [95, "bad"]] } }
```

### `stackedBar`

One bar split into coloured segments. `segments` is an expression (or a literal array) giving objects `{"value", "label", "color"}`; segments whose value is not above 0 are dropped. `total` (a number or an expression; default the segments' sum) is the whole bar: what the segments leave is drawn in `trackColor` (`track`); segments that add up to more than `total` share the bar. A segment without a `color` takes the widget's `color` (which may use `steps` of its value), else a cycle of palette colours (`accent`, `purple`, `cyan`, `teal`, `orange`, `good`, `warn`, `bad`). `height` is 8 and the width fills; `radius` defaults to half the height. With `legend: true` a row of colour dots and labels (segments with no label are left out) goes under the bar.

```json
{ "type": "stackedBar", "source": "system", "legend": true, "segments": "[{value: .disks[0].used, label: \"Used \\(.disks[0].used | fmt_bytes)\", color: \"accent\"}, {value: .disks[0].free, label: \"Free \\(.disks[0].free | fmt_bytes)\", color: \"good@0.5\"}]" }
```

### `heatmap`

A grid of square cells, as GitHub draws contributions. `values` is an expression (or a literal array) giving numbers; `null` is an empty cell, drawn in `trackColor` (`track`). They fill `rows` (7) cells down a column and then the next column (`direction: "columns"`, default), or across a row and then the next row (`"rows"`, with `rows` rows). `cell` (8) is a cell's size, `gap` (2) the space between cells, `radius` (2) a cell's corner; the widget is as large as its cells. Colours: `scale` is two colours, low and high (default `["accent@0.2", "accent"]`), mixed by where a value is between `min` and `max` (default the smallest and largest value; all equal is the high colour); or `steps` is `[[threshold, colour], …]`, a value taking the last stop at or below it, the first when below all.

```json
{ "type": "heatmap", "values": [0, 2, 5, 1, 0, 0, 0, 3, 4, 8, 6, 2, 0, 1, 0, 1, 2, 3, 1, 0, 0, 0, 5, 9, 12, 7, 3, 0, null, null, null], "scale": ["good@0.2", "good"], "cell": 10, "gap": 3 }
```

### `timeline`

A horizontal time axis with items. `from` and `to` are the times at its edges: epoch seconds, ISO 8601 (as written, or an expression giving one; without an offset it is UTC, as in `to_epoch`); the default is today, midnight to midnight in the config's time zone. `items` is an expression (or a literal array) giving objects `{"start", "end", "label", "color"}` with times like `from`; no `end` is a point marker. Items outside the range are dropped and the rest cut at its edges; overlapping items go on separate rows. `color` is the colour of items without their own (`accent`). Under the axis go tick labels at a sensible step (5 minutes to a week, at most nine of them) in the clock's 12 or 24 hour setting (`fmt_localized`). Height is 36 and the width fills. A label is drawn inside its bar when it fits, else left out. With `now` (default `true`) a thin `nowColor` (`accent`) line marks the current time, to the minute, and the dashboard redraws as time passes.

```json
{ "type": "timeline", "source": "calendar", "from": "now | fmt_time(\"yyyy-MM-dd'T'08:00:00xxx\") | to_epoch", "to": "now | fmt_time(\"yyyy-MM-dd'T'20:00:00xxx\") | to_epoch", "items": "[.[] | select(.allDay | not) | {start, end, label: .title}]", "height": 44 }
```

### `image`

A picture. `src` is a file path (`~` expanded) or an http(s) URL; it is text, so `{{ }}` holes work (`"src": "{{ .artUrl }}"`), and so does `{"expr": …}`. `width` and `height` default to 48, `fit` is `cover` (default: fill the frame, cropping) or `contain` (the whole picture), and `radius` (6) rounds the picture. A URL is fetched once, off the UI's thread, at most 5 MB, into vestal's cache directory (`~/Library/Caches/Vestal/images` on macOS, `$XDG_CACHE_HOME/vestal/images` or `~/.cache/vestal/images` on Linux), named by a hash of the URL, and fetched again only if the URL changes; `vestal render` never fetches. While it has no picture, because the file is missing or unreadable, the fetch is still running or it failed (tried again after five minutes), the widget draws an empty rounded rectangle in the `track` colour, never an error. The render model carries the local file's path, not the picture (`vestal docs render-model`).

```json
{ "type": "image", "src": "~/Pictures/avatar.png", "width": 64, "height": 64, "radius": 12 }
```
