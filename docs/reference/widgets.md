# Widgets

A widget is a JSON object with a `type`. Define it under `widgets.<key>` and list the key in a view's `children`, or write it inline wherever a widget goes (`children`, `row`, `cases`, `default`, `empty`, `loading`, popups). A string where a widget goes is a reference to `widgets.<string>`.

`vestal docs widget/<type>` lists each type's fields with their kind (`vestal docs expressions`), default and an example. The types:

| Group | Types |
|---|---|
| Containers | `stack` (top to bottom), `row` (left to right), `grid` (aligned columns), `list` (an array as rows), `table` (a list with aligned columns), `switch` (one child picked by a value) |
| Primitives | `text`, `icon`, `progress` (bar), `gauge` (ring), `sparkline`, `keyValue`, `divider`, `spacer` |
| Built-in templates | `section`, `stat`, `badge`, and the v0.3 widgets `clock`, `systemBar`, `media` (alias `spotify`), `agendaList`, `systemHealth`, `keyValueList`, `weatherCard`, `claudeUsage`, and `aiUsage` (Claude and Codex plan usage) (`vestal docs presets`) |
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
| `radius` | number | `0` | Corner radius of the background. |
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

A horizontal bar: `(value − min) / (max − min)`, clamped. Optional `label` before it, `text` after it (default `"{{ $value | round }}%"`; `""` for none), and an `overlay`, a second value on the same scale drawn `above` or `below` the fill. `width` is the bar's own width (default `fill`).

```json
{ "type": "progress", "source": "system", "label": "RAM", "labelWidth": 30, "value": ".memory.percent", "overlay": ".memory.pressure", "width": 120, "textWidth": 34, "color": "purple" }
```

### `gauge`

A ring with centre `text` (default `"{{ $value | round }}"`) and an optional `label` under it. `sweep` is the arc in degrees, with the gap at the bottom.

```json
{ "type": "gauge", "source": "system", "label": "CPU", "value": ".cpu.percent", "text": "{{ $value | round }}%", "color": { "steps": [[0, "good"], [70, "warn"], [90, "bad"]] } }
```

### `sparkline`

A line from `values` (an array of numbers), or from `value` plus `history`, which records the value on the widget's source at every fetch (`vestal docs sources`). `min` and `max` fix the scale; `fill` colours the area under the line; `dot` marks the last point. Fewer than two points draw nothing, keeping the size.

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
