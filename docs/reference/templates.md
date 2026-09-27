# Templates

A template is a named, parameterised widget (or source) written in the config. Using one looks like using any widget type: `{"type": "<template>", "<param>": value, …}`. The built-in presets are templates too (`vestal docs presets`); `vestal print-config --templates` prints every template, built-ins included, and `vestal print-config --expanded` shows what each widget becomes.

## Defining one

```json
{
  "version": 1,
  "templates": {
    "metric": {
      "description": "A labelled percentage bar with a threshold colour",
      "params": {
        "label": { "type": "text", "required": true },
        "value": { "type": "expr", "required": true, "description": "0-100" },
        "warn": { "type": "number", "default": 70 },
        "bad": { "type": "number", "default": 90 }
      },
      "widget": {
        "type": "progress",
        "label": { "param": "label" },
        "labelWidth": 40,
        "value": { "param": "value" },
        "color": { "expr": "$value | step([[0, \"good\"], [$warn, \"warn\"], [$bad, \"bad\"]])" }
      }
    }
  },
  "widgets": {
    "cpu": { "type": "metric", "source": "system", "label": "CPU", "value": ".cpu.percent" },
    "disk": { "type": "metric", "source": "system", "label": "Disk", "value": ".disks[0].percent", "warn": 80, "bad": 95 }
  },
  "views": { "main": { "children": ["clock", "cpu", "disk"] } }
}
```

A template has:

| Key | |
|---|---|
| `description` | Shown by `vestal docs` and in `vestal schema --config`. |
| `params` | Name → `{ "type", "default", "required", "description", "enum" }`. |
| `widget` or `source` | The body: exactly one of the two. |
| `override` | `true` to replace the built-in template of the same name (below). |

Parameter types: data types `string`, `number`, `integer`, `boolean`, `array`, `object`, `any`, `duration`, `color`, `icon`, `source`, and code types `expr`, `text`, `widget`, `widgets`.

## How a template expands

Templates are expanded once, when the config loads, before anything is checked or drawn.

1. **Substitution.** An object that is exactly `{"param": "<name>"}` is replaced, anywhere in the body, by the parameter's value (or its `default`). `{"param": "privacy.command"}` reaches into an object parameter.
2. **Absence.** When that value is `null` or absent, the enclosing key (or array element) is removed, as if never written.
3. **Splicing.** A `{"param": …}` array element whose value is an array is spliced in place: `"children": [header, {"param": "children"}]`.
4. **Variables.** Data parameters are also bound as `$<name>` (and all together as `$params`) in every expression and text field of the body, and in its source-definition text. Code parameters (`expr`, `text`, `widget`, `widgets`) are only substituted, never bound, so an `expr` parameter named `value` doesn't hide the node's `$value`.
5. **Common fields.** Common widget fields on the instance (`source`, `when`, `width`, `spaceBefore`, `action`, …; `vestal docs widgets`) apply to the expanded root and win over the body's, except that `vars` merge, and a parameter named like a common field takes it instead.
6. **Checks.** An instance key that is neither a parameter nor a common field is a warning with a did-you-mean. A missing `required` parameter or a value of the wrong type is an error, and that widget isn't shown.
7. **Nesting.** Templates may use templates, 16 deep at most. A cycle is an error.
8. **Names.** A template may not take a primitive's name (`text`, `list`, …). A template named like a built-in is an error unless it sets `"override": true`, which replaces the built-in whole. To build on a preset, give yours a new name and use the preset inside it.

Reserved variable names (`value`, `data`, `item`, …; `vestal docs expressions`) can't be data parameter names.

## Source templates

A template with a `source` body goes where a source goes: under `sources`, or inline. The instance's keys are the parameters plus the common source keys (`refresh`, `when`, `timeout`, `transform`, `history`, `maxAge`), which win over the body's. The built-in `foyer` is one:

```json
{
  "version": 1,
  "templates": {
    "glances": {
      "description": "Host health from a Glances REST API (v4), in the system shape",
      "params": { "url": { "type": "string", "required": true } },
      "source": {
        "type": "http",
        "url": "{{ $url }}/api/4/all",
        "refresh": "5s",
        "when": "visible",
        "transform": "{ host: .system.hostname, cpu: { percent: .cpu.total }, memory: { percent: .mem.percent }, uptime: null }"
      }
    }
  },
  "sources": {
    "nas": { "type": "glances", "url": "http://nas.local:61208" }
  },
  "widgets": {
    "nasCpu": { "type": "text", "source": "nas", "text": "NAS CPU {{ .cpu.percent | round }}%" }
  },
  "views": { "main": { "children": ["clock", "nasCpu"] } }
}
```

A source template that takes a `url` can also be `systemHealth`'s `provider`.

## The v0.3 adapter

Three v0.3 behaviours link separate widgets, so a small adapter applies them before expansion, each reported by check-config as an info note with code `legacy`:

1. A `systemBar` without its own `claudeSource` takes its Claude options from the first `claudeUsage` widget (by key).
2. The first `systemBar` of the default view whose privacy item shows gets the key `p`.
3. Each `systemHealth` host with a `url` becomes the source `host:<name>` (`{"type": <provider>, "url": …, "refresh": <interval or 5s>}`).
