# Keys

While the dashboard is open, keys run actions. (The key that opens it is `hotkey` on macOS; on Linux bind `vestal toggle` in the compositor, for example Hyprland's `bind = , Home, exec, vestal toggle`.)

A key is written like the `hotkey`: `"h"`, `"2"`, `"tab"`, `"shift+tab"`, `"space"`, `"enter"`, `"left"`, `"right"`, `"up"`, `"down"`, `"f5"`, with the modifiers `cmd` (alias `super`), `ctrl`, `alt` and `shift` joined by `+`. Letters are case-insensitive.

```json
{
  "version": 1,
  "keys": {
    "r": { "refresh": "*" },
    "g": { "open": "https://github.com/pulls/review-requested" },
    "m": { "media": "playPause", "source": "media" }
  },
  "widgets": {
    "news": { "type": "text", "text": "Hacker News", "key": "n", "action": { "open": "https://news.ycombinator.com" } }
  },
  "views": { "main": { "children": ["clock", "news"] } }
}
```

Where bindings come from, highest precedence first:

1. widget `key`s inside the open popup;
2. widget `key`s in the current view (the key runs that widget's `action`);
3. the view's `keys`;
4. the top-level `keys`, and the views' `key` shorthands;
5. `left` and `right`, which go to the previous and next page, and `tab` and `shift+tab`, which cycle the pages (`vestal docs views`).

`escape` (close the popup, else hide the dashboard) and `alt+i` (the info popup) are reserved: binding them is an error.

A widget's key is bound only while that widget is drawn on the current view, and widget keys beat the view's `keys` and the top-level ones, so a preset can bind plain keys without taking them from other pages: `focusTimer` binds space, `R` and `N`, and a top-level `r` still works on every view without it. In a view that does have the widget, the widget wins.

**`"key": "auto"`** gives a widget the first letter of its `keyHint` (letters only, in order) that no other binding took. Explicit keys are assigned first, then `auto` ones in tree order. `auto` never assigns `i` or `p` (v0.3's info and privacy keys). The `systemHealth` preset gives each host `auto` with its name as the hint, so `h` opens `harbor`.

check-config reports keys that aren't keys (`invalid-key`) and bindings of the reserved ones (`key-conflict`). When two widgets bind the same key explicitly, the first in tree order wins: check with `vestal render --press <key>`.

Test a key without a screen: `vestal render --press h` renders the model after pressing `h` (it opens popups and switches views, but never runs a command).
