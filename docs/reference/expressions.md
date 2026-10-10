# Expressions

Expressions are a subset of jq. Every field of the config is one of three kinds, and the kind decides how its string is read. `vestal schema` tags each field with `x-vestal-kind`, and `vestal docs widget/<type>` shows it in the Kind column.

## The three kinds of field

| Kind | Syntax | Example | Evaluated |
|---|---|---|---|
| **expr** | a jq expression, as a string | `"value": ".cpu.percent"` | every render that needs it |
| **text** | literal text with `{{ expr }}` holes | `"text": "CPU {{ .cpu.percent \| round }}%"` | every render that needs it |
| **literal** | a JSON value, or `{"expr": "<jq>"}` to compute it | `"size": 14`, `"color": {"expr": "if .ok then \"good\" else \"bad\" end"}` | once, or every render with `expr` |

Three rules cover the language:

- R1. A field of kind *expr* is always jq.
- R2. A field of kind *text* is literal, and each `{{ … }}` inside it is a jq expression whose first output is inserted. Strings go in as they are, numbers as jq's `tostring` writes them, `null` as nothing, and arrays and objects as compact JSON. `{{{{` writes a literal `{{`.
- R3. Any other scalar field (a number, a boolean, a color, an icon name, a width) may be written `{"expr": "<jq>"}` to compute it. Structural keys cannot: `type`, `id`, `children`, `row`, `cases`, a `source` given as a name, template names, and the keys of a source definition.

`{{ }}` needs no escaping in JSON or in Nix (Nix only interpolates `${`). jq's own `"\(…)"` still works inside an expression, but in a JSON string it must be written `\\(`.

Where each kind appears:

| Field | Kind | On |
|---|---|---|
| `value`, `values`, `overlay`, `max`, `min` | expr | text, progress, gauge, sparkline |
| `items`, `filter`, `sortBy`, `rowId` | expr | list, table (`items` may also be a JSON array: static data) |
| `when`, `input`, `vars.<name>` | expr | every widget |
| `on` | expr | switch |
| `transform`, `history.<name>.value` | expr | sources |
| `functions.<name>` | expr | top level |
| `text`, `label`, `title`, `prefix`, `suffix`, `placeholder`, `keyHint`, `alt`, `empty` (a string) | text | widgets |
| action `open`, `copy`, `run[]`, `view` | text | actions |
| source `url`, `argv[]`, `env.*`, `headers.*`, `path`, `ics` | text | sources, evaluated once when the config loads |
| `color`, `background`, `icon`, `name`, `size`, `weight`, `width`, `limit`, … | literal | widgets |

## What an expression sees

| Name | What it is |
|---|---|
| `.` | The data of the nearest `source` above this widget, after `input`. Inside a `list` or `table` row, the row's item. |
| `$data` | The nearest source's data, unaffected by rows or `input`. |
| `$item`, `$index` | The current row and its position from 0. Only inside a row. |
| `$parent` | The enclosing row's item, in a nested list. |
| `$value` | The node's own resolved `value`, in its color and style fields and in `text` or `suffix` next to a `value`. |
| `$sources` | Every named source's data: `$sources.system.cpu.percent`, `$sources["host:harbor"]`. |
| `$meta` | The nearest source's metadata: `{name, fetchedAt, age, ok, error, stale, loaded}`. `meta("name")` gives another source's. |
| `$history` | `$history.<source>.<name>`: an array of numbers, oldest first. |
| `$params`, `$<param>` | Template parameters that hold data (`vestal docs templates`). |
| `$widget` | The key of the enclosing entry in `widgets`, or `""` for an inline widget. |
| `$view` | The current view's name. |
| `$tz` | The local IANA time zone, such as `"Europe/Lisbon"`. |
| `$os` | `"macos"` or `"linux"`. Prefer a `platform` block. |
| `now` | The current time in epoch seconds. A node that calls it is re-evaluated every second while shown. |

`$secrets` and `$env` exist only in the text fields of source definitions, so a secret can never reach the screen or `vestal render` output.

These names are reserved: a template parameter or a `vars` entry may not use `value`, `data`, `item`, `index`, `parent`, `sources`, `meta`, `history`, `params`, `widget`, `view`, `tz`, `os`, `env` or `secrets` (check-config error).

`vars` binds names for a subtree. Each entry is an expression, and an entry may use the others it names:

```json
{
  "type": "text",
  "source": "system",
  "vars": { "used": ".memory.used / 1073741824", "total": ".memory.total / 1073741824" },
  "text": "{{ $used | fmt_fixed(1) }} of {{ $total | round }} GiB"
}
```

## Streams, nulls and errors

- jq expressions produce streams. A scalar field takes the first output. `items` collects all outputs into an array, and when the only output is an array it uses that array, so `".items"` and `".items[]"` both work.
- `null` is quiet. A `{{ }}` hole that is `null` inserts nothing. A `value` that is `null` shows the widget's `placeholder` (default `–`) and draws empty bars, rings and sparklines. `when` hides the widget on `null` and `false`.
- A runtime error (for example `tonumber` on `"n/a"`) never stops rendering: that field behaves as `null`, and the error goes to the render model's `diagnostics`, which `vestal render` prints.
- A compile error is found when the config loads: that widget is hidden, and `vestal check-config` reports the error with its position.
- Limits: one evaluation may take at most 100,000 steps and 50 ms, and produce at most 4 MiB. Past a limit it fails like any runtime error (`expr-limit`), so `range(1e9)` can't freeze the dashboard.
- jq's `//` treats `false` like `null`: `.enabled // true` is `true` when `.enabled` is `false`. Use `if .enabled == null then true else .enabled end`.

## Dot paths

The path fields `pick`, `picks.*` and `weatherCard`'s `fields.*` are dot paths: dot-separated field names (a leading dot optional) and `[N]` indexes, never jq. So there `rates.EUR` means the field `EUR` of `rates`. Every new expr field is strict jq: write `.rates.EUR`. When a new field looks like a dot path, check-config suggests the jq form.

## When things are evaluated

For every widget, vestal records the sources it reads (its `source`, `$sources.<name>`, `meta("<name>")`, `$history.<name>`; a computed key such as `$sources[$x]` counts as every source) and whether it calls `now`. A widget is evaluated again when one of those sources gets new data, when the dashboard is shown, and every second while shown if it calls `now`. Nothing in the widget tree is evaluated while the dashboard is hidden. Source `transform`s and `history` values run whenever their source fetches.

## User functions

`functions` defines jq functions without arguments, callable from every expression:

```json
{
  "version": 1,
  "functions": {
    "gib": ". / 1073741824 | fmt_fixed(1) + \" GiB\"",
    "ha_num": ".state | tonumber? // null"
  },
  "widgets": {
    "memory": { "type": "text", "source": "system", "text": "RAM {{ .memory.used | gib }} of {{ .memory.total | gib }}" }
  },
  "views": { "main": { "children": ["clock", "memory"] } }
}
```

Names match `^[a-z_][a-z0-9_]*$` and may not shadow a jq builtin or a vestal function. A function may call the others; a cycle is an error.

## Trying an expression

`vestal eval` evaluates exactly as a widget would, with the vestal functions and the config's `functions`:

```text
$ vestal eval '.cpu.percent | step([[0,"good"],[70,"warn"],[90,"bad"]])' --source system
"good"
$ vestal eval --template 'CPU {{ .cpu.percent | round }}%' --source system
CPU 12%
$ vestal eval '[1,2,3] | map(. * 2)' --null-input
[2,4,6]
```

`--input <file>` evaluates against a file, `--var name=<json>` binds `$name`, `--at <time>` freezes `now`, and `--json` wraps the result as `{"ok": true, "outputs": [...]}`. A compile error prints the position with a caret and exits 3. `vestal docs functions` lists every function.
