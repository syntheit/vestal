# Developing vestal

Notes for working on vestal itself. For configuring it, start with [AGENTS.md](../../AGENTS.md) and [docs/CONFIG.md](../CONFIG.md).

## Build

```sh
swift build                    # debug
swift build -c release         # release
nix build 'path:.#default'     # the package (Vestal.app on macOS, vestal on Linux)
nix build 'path:.#site'        # the website, as static files
nix develop                    # a shell with the toolchain the package uses
```

The code targets Swift 5.10 (`swift-tools-version:5.9`), macOS 14 and up. There are no third-party SwiftPM dependencies, so the Nix build runs offline.

## Tests

The tests are XCTest, in `Tests/VestalCoreTests`. They import `VestalCore` without `@testable`.

- Linux: `nix flake check` builds vestal, runs the tests and smoke-tests the CLI. `swift test` in the dev shell does not work there (nixpkgs' Swift has no libIndexStore), so the `tests` check generates an entry point with `nix/gen-linuxmain.py`.
- macOS: `swift test` needs Xcode; the Command Line Tools have no XCTest.
- Web renderer: `node --test web/renderer/*.test.mjs`. Browser checks are in [web/README.md](../../web/README.md).

CI (`.github/workflows/ci.yml`) runs `nix flake check` on Linux and `swift build` plus `swift test` with Xcode 15.4 (Swift 5.10) on macOS.

## Code layout

| Path | What it holds |
| --- | --- |
| `Sources/VestalCore` | Everything portable (Foundation only): config loading and validation, the jq engine (`Expr`), sources, the render model, the CLI. Builds and tests on Linux. |
| `Sources/VestalMac` | The macOS app: SwiftUI renderer, hotkeys, EventKit, IOKit and CoreAudio bridges. Every file is wrapped in `#if os(macOS)`. |
| `Sources/VestalLinux` | The Linux app: GTK 4 with layer shell. |
| `Sources/CGtk4`, `CSQLite`, `CWaylandCapture` | C modules: GTK headers, the system SQLite (Thunderbird caches), Wayland screen capture for the Linux blurred backdrop. |
| `Sources/vestal` | `main.swift`, the entry point. |
| `web/renderer` | The web renderer used by the site and `vestal gallery`, dependency-free JavaScript. |
| `Resources` | Bundled fonts, Phosphor icons, background shaders, preset samples and starters. |
| `nix` | Package checks, the Home Manager module, the site build and the generators below. |
| `site` | The website; `node site/build.mjs` writes `site/dist`. See [site/README.md](../../site/README.md). |

## Generated files

These are committed. A test fails when one drifts from its source, so rerun the generator after editing the source and never merge them by hand.

| File | Source | Command |
| --- | --- | --- |
| `Sources/VestalCore/Generated/EmbeddedDocs.swift` | `AGENTS.md`, `docs/reference/*.md`, `docs/guide/*.md` | `python3 nix/gen-docs.py` |
| `Sources/VestalCore/Generated/IconMap.swift`, `web/renderer/icons.js` | `Resources/icons/*.css` | `python3 nix/gen-iconmap.py` |
| `Sources/VestalCore/Generated/EmbeddedShaders.swift` | `Resources/shaders` | `python3 nix/gen-shaders.py` |
| `docs/vestal.schema.json` | the widget and source registries | `vestal schema --out docs/vestal.schema.json` |
| `Tests/VestalCoreTests/Fixtures/expr-cases.json` | `expr-cases.txt`, run through the real jq | `scripts/gen-expr-fixtures.py` |

## More

- [expression-engine.md](expression-engine.md): the jq interpreter, its API and how it differs from jq 1.7.1.
- [docs/reference/render-model.md](../reference/render-model.md) and [protocol.md](../reference/protocol.md): the render model the three renderers draw.
