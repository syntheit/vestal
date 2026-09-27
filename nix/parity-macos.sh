#!/usr/bin/env bash
# The macOS parity check of EXTENSIBILITY.md §13.4 (TASKS-v0.4 6b), offscreen:
# examples/full.json with the fixture data of Tests/VestalCoreTests/Fixtures/full
# at a fixed time, drawn by the v0.4 renderer (`vestal screenshot`) and by the
# v0.3 views (`vestal render-file --legacy <fixture dir>`, the same data through
# v0.3's own derivations), then compared pixel by pixel. No window is shown and
# no running instance is contacted.
#
#   nix/parity-macos.sh [vestal binary] [output dir]
#
# Defaults: .build/release/vestal (else .build/debug/vestal), docs/screenshots/macos.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=${1:-}
if [ -z "$bin" ]; then
  bin=.build/release/vestal
  [ -x "$bin" ] || bin=.build/debug/vestal
fi
out=${2:-docs/screenshots/macos}
mkdir -p "$out"
at=2026-09-27T17:03:22Z
fixtures=Tests/VestalCoreTests/Fixtures/full
export TZ=America/Argentina/Buenos_Aires
export VESTAL_LOCALE=en_US@hours=h23
export VESTAL_FONT_DIRS="$PWD/Resources/icons"
common=(--config examples/full.json --data "$fixtures" --at "$at" --size 1512x982 --scale 2)

"$bin" screenshot "$out/v04-full.png" "${common[@]}" >/dev/null
"$bin" screenshot "$out/v04-full-popup.png" "${common[@]}" --press h >/dev/null
"$bin" screenshot "$out/v04-full-info.png" "${common[@]}" --press alt+i >/dev/null
"$bin" render-file --legacy "$fixtures" --at "$at" --config examples/full.json --screenshot "$out/v03-full.png" 2>/dev/null
"$bin" render-file --legacy "$fixtures" --at "$at" --config examples/full.json --popup harbor --screenshot "$out/v03-full-popup.png" 2>/dev/null

for pair in full full-popup; do
  printf '%-11s 2%% fuzz: %s differ; 0.4%% fuzz (about 1/255 a channel): %s differ\n' "$pair" \
    "$(swift nix/image-diff.swift "$out/v04-$pair.png" "$out/v03-$pair.png")" \
    "$(swift nix/image-diff.swift "$out/v04-$pair.png" "$out/v03-$pair.png" --fuzz 0.4)"
done
