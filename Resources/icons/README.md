# Phosphor icons

The icon set vestal bundles on every OS (docs/EXTENSIBILITY.md §8.6): Phosphor
Icons 2.1.2, MIT licence (`LICENSE`), by Helena Zhang and Tobias Fried.

Taken unchanged from the npm package `@phosphor-icons/web` 2.1.2
(`https://registry.npmjs.org/@phosphor-icons/web/-/web-2.1.2.tgz`,
sha256 `QOMJYJnKgYwEeXnOzmo3ZJRNUgDGe2QJL3vNi80dKwg=` in SRI base64):

| File | From the package |
|---|---|
| `Phosphor.ttf` | `src/regular/Phosphor.ttf` (the `regular` weight) |
| `Phosphor-Fill.ttf` | `src/fill/Phosphor-Fill.ttf` (the `fill` weight) |
| `regular.css`, `fill.css` | `src/regular/style.css`, `src/fill/style.css`: each icon's name and code point |
| `LICENSE` | `LICENSE` |

`nix/gen-iconmap.py` reads the two CSS files and writes
`Sources/VestalCore/Generated/IconMap.swift` (committed):

```sh
python3 nix/gen-iconmap.py
```

The Linux package installs the fonts to `$out/share/vestal/icons/`, where the
GTK UI looks for them. To update the set, replace these files from a newer
release and run the generator.
