# Vestal

A native macOS dashboard. Press a key, see everything that matters at a glance.

Native Swift / SwiftUI. ~20 MB RAM. Zero CPU when idle.

## Status

Pre-release, extracted from a personal nix-darwin setup. v1 is a faithful port of
the original; widgets-with-config refactor follows. Not yet ready for general use.

## Build

Requires macOS 13+ and Swift 5.9+.

```sh
swift build -c release
.build/release/vestal
```

## Roadmap

- v0.1 — standalone build (this commit)
- v0.2 — Codable config schema, widgets-with-config, runtime scheduler/cache
- v0.3 — CLI control surface (`vestal toggle/show/hide/reload`), built-in hotkey
- v0.4 — Nix module, brew cask, notarized DMG
- v0.5 — public launch

## License

See [LICENSE](./LICENSE).
