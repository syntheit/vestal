# Functions

Every expression can call the jq builtins of vestal's jq subset (listed at the end of this page), the vestal functions below, and the config's own `functions` (`vestal docs expressions`). Try any of them with `vestal eval '<expr>' --null-input`.

Numbers may arrive as JSON numbers or as numeric strings: `"12.5"` works wherever a number is expected. Times may be epoch seconds or ISO 8601 strings. A formatter given `null` returns `null`, so a `{{ }}` hole over missing data stays empty; a value that isn't a number where one is needed is a runtime error.

## Formatting

Numbers are written the American way on every system, whatever its locale (`LC_NUMERIC`): `.` before decimals, and `,` between thousands only where a function groups them (`fmt_thousands`). Dates and times (`fmt_localized`) follow the system's locale.

| Function | Input → output | Example |
|---|---|---|
| `fmt_fixed(n)` | number → text with `n` decimals | `3.14159 \| fmt_fixed(2)` → `"3.14"` |
| `fmt_int` | number → whole number, truncated | `1234.9 \| fmt_int` → `"1234"` |
| `fmt_number` | whole numbers as they are, others with 2 decimals | `2.5` → `"2.50"`, `3` → `"3"` |
| `fmt_thousands`, `fmt_thousands(n)` | grouped digits with `,`, `n` decimals (default 0) | `1234567` → `"1,234,567"`; `1234.5 \| fmt_thousands(1)` → `"1,234.5"` |
| `fmt_compact` | short form | `1234` → `"1.2k"`, `3400000` → `"3.4M"`, `2.1e9` → `"2.1B"` |
| `fmt_percent`, `fmt_percent(n)` | a 0–100 number → percent | `41.6` → `"42%"`; `41.66 \| fmt_percent(1)` → `"41.7%"` |
| `fmt_bytes` | bytes → size | `80` → `"80B"`, `12288` → `"12K"`, `4194304` → `"4.0M"`, `1288490188` → `"1.2G"`, `12884901888` → `"12G"`, `1209462790553` → `"1.1T"` |
| `fmt_rate` | bytes per second → rate (no `/s`) | `524288` → `"512K"`, `1258291` → `"1.2M"` |
| `fmt_duration`, `fmt_duration(units)` | seconds → the two (or `units`) largest non-zero units | `273600` → `"3d 4h"`, `15120` → `"4h 12m"`, `2700` → `"45m"`; `273600 \| fmt_duration(1)` → `"3d"` |
| `fmt_uptime` | seconds → days, or hours under a day | `273600` → `"3d"`, `15120` → `"4h"` |
| `fmt_uptime_long` | seconds → days and hours, or hours and minutes | `273600` → `"3d 4h"`, `720` → `"0h 12m"` |
| `fmt_relative` | time → distance from now | `"5m ago"`, `"3h ago"`, `"2d ago"`, `"in 25m"`, `"now"` |
| `starts_in` | minutes → `"now"`, `"in 25m"`, `"in 2h 5m"` | `125 \| starts_in` → `"in 2h 5m"` |
| `fmt_time(pattern)`, `fmt_time(pattern; tz)` | time → an ICU date pattern, in the local zone or `tz` | `now \| fmt_time("HH:mm"; "Asia/Tokyo")` |
| `fmt_localized(skeleton)`, `fmt_localized(skeleton; tz)` | time → the locale's form of an ICU skeleton | `now \| fmt_localized("EEEEMMMMdy")` → `"Sunday, September 27, 2026"`; `"JJmm"`: hours and minutes in the locale's hour cycle (12-hour without AM/PM in `en_US`; for a fixed 24-hour time use `fmt_time("HH:mm")`) |
| `clock24` | 12-hour text → 24-hour | `"06:15 PM"` → `"18:15"`, `"06:15"` → `"6:15"` |
| `capitalize` | first letter upper-cased | `"exchange"` → `"Exchange"` |
| `titlecase` | every word capitalized | `"new york"` → `"New York"` |
| `truncate(n)` | text cut to `n` characters, with `…` when cut | `"Windowlicker" \| truncate(6)` → `"Window…"` |

The `format` field of `text`, table columns and `keyValue` items names these: `int`, `number`, `fixed:N`, `percent`, `percent:N`, `thousands`, `thousands:N`, `compact`, `bytes`, `rate`, `duration`, `duration:N`, `uptime`, `relative`, `startsIn`, `time:<pattern>`, `localized:<skeleton>`, and the v0.3 names `integer` and `decimal`.

Arguments see the piped input, not the row: inside `now | fmt_time("HH:mm"; …)` the argument's `.` is `now`. Use `$item.tz`, or bind first: `.tz as $z | now | fmt_time("HH:mm"; $z)`.

## Colours, icons and thresholds

| Function | Meaning | Example |
|---|---|---|
| `step(stops)` | `stops` is `[[threshold, result], …]` in ascending order: the result of the last stop whose threshold ≤ the input, or the first stop's result below them all. Any result type: colours, icon names, text. | `95 \| step([[0,"good"],[70,"warn"],[90,"bad"]])` → `"bad"` |
| `color_mix(a; b; t)` | blends two colours (palette names or hex) in sRGB, `t` from 0 to 1 → `"#rrggbbaa"` | `color_mix("good"; "bad"; .cpu.percent / 100)` |
| `alpha(a)` | a colour with its alpha multiplied by `a` | `"accent" \| alpha(0.15)` → `"#7aa1f726"` |

## Time and data

| Function | Meaning | Example |
|---|---|---|
| `to_epoch` | ISO 8601 (with or without fractional seconds and offset) or epoch → epoch seconds | `"2026-09-26T18:02:11Z" \| to_epoch` → `1790445731` |
| `tz_valid` | whether a text is a known IANA time zone | `"Europe/Lisbon" \| tz_valid` → `true` |
| `sun_context(sunrise; sunset)` | `"H:mm"` times → `"sets in 5h 17m"` and the like, from now | `sun_context(.sunrise; .sunset)` |
| `find(obj)` | array → the first element whose fields equal all of `obj`'s, else `null` | `find({casa: "blue"})` |
| `where(obj)` | array → every such element | `where({state: "on"})` |
| `uniq_by(f)` | like `unique_by`, but keeps the first of each and the order | `uniq_by(.label)` |
| `meeting_link` | a calendar entry (`url`, `location`, `notes`) or text → the link that joins the meeting, or `null`. Links to Zoom, Google Meet, Microsoft Teams, Webex and a few other call services win, wherever they are, else the first `http(s)` link; fields are scanned in the order url, location, notes. | `{url: null, notes: "Join: https://us02web.zoom.us/j/123."} \| meeting_link` → `"https://us02web.zoom.us/j/123"` |
| `pct(part; whole)` | `100 * part / whole`, `null` when `whole` is 0 | `pct(.used; .total)` |
| `meta(name)` | a source's metadata, as `$meta`: `{name, fetchedAt, age, ok, error, stale, loaded}` | `meta("weather").age` |
| `history(source; name)` | the same as `$history[source][name]` | `history("stats"; "cpu") \| last` |
| `history_times(source; name)` | the epoch times of those samples | |
| `path_get(path)` | resolves a v0.3 path (`rates.BRL`, `list[0].x`) against the input | `path_get("rates.BRL")` |

`$meta`: `fetchedAt` is the last successful fetch (or `null`), `age` its age in seconds, `ok` whether the latest fetch succeeded, `error` its message, `stale` whether the age is over twice the source's `refresh`, `loaded` whether there is data.

## Legacy helpers

These reuse the v0.3 Swift code, so the built-in presets match v0.3 exactly. New configs don't need them.

| Function | Meaning |
|---|---|
| `kv_legacy(item; defaultSource)` | a v0.3 `keyValueList` item (`label`, `source`, `match`, `pick`, `picks`, `format`) → `{label, text}`, or `null` when its data is missing |
| `weather_legacy(fields; units)` | weather JSON and v0.3 `fields` paths → `{location, condition, temp, sunrise, sunset}` |
| `foyer_health` | a foyer `/api/health` payload → the `system` data shape (`vestal docs source/system`); missing numbers are `0` |
| `host_health(host; provider)` | a v0.3 `systemHealth` host → `{data, ok, seen}` |
| `fmt_legacy(format)` | the v0.3 item formats: `"int"`, `"integer"`, `"decimal"`, `"%.2f"`, or `null` for as is |
