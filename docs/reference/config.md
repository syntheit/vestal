# The config file

One JSON file drives vestal on macOS and Linux. `vestal schema` prints its JSON Schema; `vestal check-config` checks a file against it and against the rules below. The key tables after this text are generated from the same registry.

The other topics go deeper: `sources`, `widgets`, `expressions`, `functions`, `templates`, `presets`, `styling`, `icons`, `views`, `keys`, `actions`. Under Home Manager, the same JSON is `programs.vestal.settings` (`vestal docs agents` shows the patterns).

## Where vestal looks

1. `$VESTAL_CONFIG`, if it is set and not empty. A leading `~/` expands to your home directory.
2. `$XDG_CONFIG_HOME/vestal/config.json` if `XDG_CONFIG_HOME` is an absolute path, otherwise `~/.config/vestal/config.json`, if the file exists.
3. Otherwise the built-in defaults alone.

`vestal status` shows the file a running instance loaded (`config:`). If `~/.config/vestal/config.json` is a symlink into `/nix/store`, Home Manager writes it from `programs.vestal.settings`: edit that Nix source instead.

## Layers and merging

The effective config is three layers, each merged over the one before:

1. the built-in defaults (`vestal print-config` with no file shows them),
2. your file, without its `platform` key,
3. your file's `platform.macos` or `platform.linux` block, on that OS only.

Merging works on the JSON:

- Objects merge key by key, recursively. `{"theme": {"background": "blur"}}` keeps the default palette.
- Lists and plain values replace the lower layer's. Lists are never concatenated: to add a widget to `views.main.children`, write the whole list (`vestal print-config` shows the current one).
- An explicit `null` deletes the key: `{"widgets": {"media": null}}` removes the default media widget.
- A source or widget named like a default one merges into it, even with another `type`. Use a new name to start clean.

`vestal print-config --origins` prints every value with the layer it came from, as `pointer  value  layer`.

## Decoding

Decoding is permissive, and nothing in the config stops vestal from starting:

- Unknown keys are ignored.
- A value of the wrong JSON type counts as absent, and the key's default applies (not the built-in layer's value, which the merge already replaced).
- A count below 1 counts as absent.
- An entry that can't be used is dropped by itself: a source or widget without `type`, a host without `name` (only a local host may omit it), a world clock without `label` or `tz`, an item without `label`.
- A file that is not valid JSON, or whose top level is not an object, is ignored whole; the defaults apply. A trailing comma is invalid on every OS; a UTF-8 byte order mark is fine.

`vestal check-config` reports every one of these, with an RFC 6901 pointer into your file, the layer, a line and column, and a did-you-mean where one fits. `--json` gives the same as data.

## Durations

A whole number above zero and `s`, `m`, `h` or `d`: `"30s"`, `"5m"`, `"4h"`, `"1d"`. An invalid one is reported and the key's default applies.

## The platform block

```json
{
  "hotkey": "f3",
  "platform": { "linux": { "hotkey": "home" } }
}
```

`platform` holds a `macos` and a `linux` object. Each takes any top-level key and is merged over the rest of the file on that OS only. Blocks don't nest. `check-config` checks the other OS's block too and tags those findings (`[linux] ...`); `--platform linux` checks as Linux would load the file.
