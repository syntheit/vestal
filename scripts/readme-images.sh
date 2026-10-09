#!/bin/sh
# Renders the README images into docs/images/ with the release binary,
# offscreen (no window), from the bundled sample data at a fixed time.
# Usage: scripts/readme-images.sh   (after: swift build -c release)
set -eu
cd "$(dirname "$0")/.."
BIN=${VESTAL_BIN:-.build/release/vestal}
OUT=docs/images
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

export TZ=UTC VESTAL_LOCALE=en_US@hours=h23 VESTAL_FONT_DIRS=Resources/icons

# Every starter sample is drawn at its own fixed time, scale 2.
"$BIN" gallery --out "$TMP" --scale 2 \
  --only starter-minimal starter-developer starter-media \
         starter-homelab starter-markets starter-agentops >/dev/null

# Hero: the default starter at screen size. The offscreen renderer cannot
# draw the aurora (see `vestal docs cli`), so the mesh background stands in.
sed 's/"background": "aurora"/"background": "mesh"/' \
  Resources/samples/starter-default/config.json > "$TMP/hero.json"
"$BIN" screenshot "$TMP/hero-full.png" --config "$TMP/hero.json" \
  --data Resources/samples/starter-default/data \
  --at 2026-09-27T17:03:22Z --size 1512x982 --scale 2 >/dev/null
sips --resampleWidth 2000 "$TMP/hero-full.png" --out "$OUT/hero.png" >/dev/null
echo "$OUT/hero.png $(wc -c < "$OUT/hero.png") bytes"

for id in minimal developer media homelab markets agentops; do
  src="$TMP/starter-$id.png"
  dst="$OUT/$id.png"
  sips --resampleWidth 1000 "$src" --out "$dst" >/dev/null
  if command -v pngquant >/dev/null 2>&1; then
    pngquant --force --skip-if-larger --quality 70-95 --output "$dst" "$dst" || true
  fi
  echo "$dst $(wc -c < "$dst") bytes"
done
