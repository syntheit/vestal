# Views

A view is one screen of widgets. The dashboard opens `defaultView` (default `main`) unless a view is named.

```json
{
  "version": 1,
  "defaultView": "main",
  "widgets": {
    "bigClock": { "type": "text", "text": "{{ now | fmt_time(\"HH:mm\") }}", "alignSelf": "center", "style": { "size": 120, "weight": "thin", "font": "mono" } }
  },
  "views": {
    "main": { "key": "1", "children": ["clock", "systemBar", "media", "agenda", "systems", "weather"] },
    "focus": { "key": "2", "title": "Focus", "gap": 32, "children": ["bigClock", "agenda"] }
  }
}
```

| Key | Default | |
|---|---|---|
| `children` | `[]` | Widget keys or inline widgets, top to bottom. |
| `order` | `[]` | v0.3's name for `children` (keys only). When both are set, `children` wins and check-config warns. |
| `title` | the name, capitalized | Shown by UIs that list views. |
| `key` | none | A key that switches to this view while the dashboard is open. |
| `layout` | `stack` | The root container: `stack` (top to bottom), `row` or `grid`. |
| `columns` | `2` | For `layout: "grid"`. |
| `gap` | `24` | Between root children (the presets set their own `spaceBefore`). |
| `align` | `center` | Cross-axis alignment of the root children. |
| `padding` | `48` | Inside `maxWidth`: a number or `[top, right, bottom, left]`. |
| `maxWidth` | `680` | The root is at most this wide, centred on the screen both ways. |
| `keys` | `{}` | Key bindings of this view only (`vestal docs keys`). |

- **Lists replace.** `views.main.children` in your file replaces the default list whole. To add a widget to the default dashboard, write the full list: `vestal print-config` shows the current one.
- **Spacing.** In a view written with `children`, the first *visible* child gets no space before it. A view written with v0.3's `order` keeps v0.3's rule: only the first *listed* entry gets none.
- **Switching.** `tab` and `shift+tab` cycle through the views (in key order) when there is more than one and those keys are unbound; a view's `key` jumps to it. From a shell or a compositor: `vestal show <view>` opens the dashboard on that view, and `vestal toggle <view>` hides it when it shows that view and shows that view otherwise. An unknown view exits 4.
- **Cost.** A view that isn't shown costs nothing: its `visible` sources aren't fetched and nothing in it is evaluated.

Check one without opening it: `vestal render --view focus`, or `vestal render --press 2` to go through its key.

## Popups

One popup at a time, opened by a `popup` action (`vestal docs actions`). The UI draws it centred over a `scrim` backdrop, in a card (`bg`, radius 14, a thin white border). Escape or a click on the backdrop closes it. Its content is an ordinary widget tree and updates live; its node ids start with `popup/`.
