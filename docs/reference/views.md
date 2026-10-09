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
| `gap` | `24` (`12` with `theme.density` `compact`) | Between root children (the presets set their own `spaceBefore`). |
| `align` | `center` | Cross-axis alignment of the root children. |
| `padding` | `48` | Inside `maxWidth`: a number or `[top, right, bottom, left]`. |
| `maxWidth` | `680` | The root is at most this wide, centred on the screen both ways. |
| `keys` | `{}` | Key bindings of this view only (`vestal docs keys`). |
| `enabled` | `true` | `false` turns the view off (see Pages). |

- **Lists replace.** `views.main.children` in your file replaces the default list whole. To add a widget to the default dashboard, write the full list: `vestal print-config` shows the current one.
- **Spacing.** In a view written with `children`, the first *visible* child gets no space before it. A view written with v0.3's `order` keeps v0.3's rule: only the first *listed* entry gets none.
- **Switching.** `left`, `right`, `tab` and `shift+tab` page through the views (in key order, or `pages.order`) when there is more than one and those keys are unbound; a view's `key` jumps to it. A swipe pages too (see Pages). From a shell or a compositor: `vestal show <view>` opens the dashboard on that view, and `vestal toggle <view>` hides it when it shows that view and shows that view otherwise. An unknown view exits 4.
- **Cost.** A view that isn't shown costs nothing: its `visible` sources aren't fetched and nothing in it is evaluated.

Check one without opening it: `vestal render --view focus`, or `vestal render --press 2` to go through its key.

## Pages

With two or more views the dashboard pages like a phone's home screens: `left` and `right` (and a two-finger swipe) move between the views, the old page slides out and the new one in, and a row of dots shows where you are. One view draws exactly as before, with no dots. The top-level `pages` object (all keys optional):

| Key | Default | |
|---|---|---|
| `order` | the views in key order, then by name | The views to page through, in order. A view not listed stays reachable by its `key` and `vestal show`, but is not paged to. A name that isn't an enabled view is a check-config warning and is skipped. |
| `transition` | `"slide"` | How a change of page is drawn: `"slide"` (the old page leaves sideways while the new one comes in, 250 ms), `"fade"` (a crossfade, 180 ms) or `"none"`. With reduced motion on (macOS "Reduce motion", GTK `gtk-enable-animations` off), `slide` is a short fade. A jump to a view that is not a page also fades. |
| `indicator` | `"dots"` | `"dots"`: one dot per page near the bottom of the screen, the current one in the accent colour; drawn only with two or more pages. `"none"`. |
| `swipe` | `true` | A two-finger horizontal swipe on the trackpad pages. The page follows the fingers and goes on past about 12 % of the screen width or with a quick flick, else springs back. |
| `wrap` | `false` | Whether `right` on the last page goes to the first (and `left` on the first to the last). `tab` and `shift+tab` always cycle round. |

`left` and `right` go to the previous and next page, and `tab` and `shift+tab` keep cycling, unless you bind those keys yourself: your bindings win (see keys). On Linux the swipe assumes natural scrolling.

Set `enabled` to `false` on a view to turn it off, as you would a lock screen: it has no key, is not paged to, `vestal show <view>` exits 4 as for an unknown view, and nothing in it is evaluated. If `defaultView` is disabled, check-config warns and the first enabled page is shown instead.

```json
{
  "pages": { "order": ["main", "focus"], "transition": "slide", "indicator": "dots", "swipe": true, "wrap": true },
  "views": {
    "main": { "key": "1", "children": ["clock", "systemBar", "agenda"] },
    "focus": { "key": "2", "children": ["agenda"] },
    "stats": { "key": "3", "enabled": false, "children": ["systemBar"] }
  }
}
```

Under Home Manager the same settings are Nix, and a page can be toggled like a lock screen:

```nix
programs.vestal.settings = {
  pages = { order = [ "main" "focus" ]; transition = "fade"; wrap = true; };
  views.stats.enabled = false;
};
```

`vestal render --press right` renders the next page. The render model carries `pages` (the page list, the current index and the direction of the last change) when there are two or more pages, so a client can draw the dots and the transition (`vestal docs render-model`).

## Popups

One popup at a time, opened by a `popup` action (`vestal docs actions`). The UI draws it centred over a `scrim` backdrop, in a card (`bg`, radius 14, a thin white border). Escape or a click on the backdrop closes it. Its content is an ordinary widget tree and updates live; its node ids start with `popup/`.
