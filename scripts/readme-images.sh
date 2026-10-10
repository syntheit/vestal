#!/bin/sh
# Renders the README images into docs/images/ with the release binary,
# offscreen (no window), from the bundled sample data at a fixed time.
# Usage: scripts/readme-images.sh   (after: swift build -c release)
# Needs swiftc (for scripts/montage.swift); the animated flip clock also
# needs ffmpeg with libwebp and is skipped without it.
set -eu
cd "$(dirname "$0")/.."
BIN=${VESTAL_BIN:-.build/release/vestal}
OUT=docs/images
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

export TZ=UTC VESTAL_LOCALE=en_US@hours=h23 VESTAL_FONT_DIRS=Resources/icons:Resources/fonts
AT=2026-09-27T17:03:22Z

swiftc -O -o "$TMP/montage" scripts/montage.swift
MONTAGE="$TMP/montage"

# Writes $1 downscaled to width $2 as $3 and prints its size.
fit() {
  sips --resampleWidth "$2" "$1" --out "$3" >/dev/null
  echo "$3 $(wc -c < "$3") bytes"
}

# Screenshot of a sample dashboard: starter id, size, output.
starter() {
  d=Resources/samples/starter-$1
  "$BIN" screenshot "$3" --config "$d/config.json" --data "$d/data" \
    --at "$AT" --size "$2" --scale 2 >/dev/null
}

# MARK: - Hero and starters

# Hero: the default starter at screen size, with its aurora.
starter default 1512x982 "$TMP/hero.png"
fit "$TMP/hero.png" 1600 "$OUT/hero.png"

# Every starter at the same screen size, for the grid.
for id in default minimal developer media homelab markets agentops focus; do
  starter "$id" 1512x982 "$TMP/starter-$id.png"
  fit "$TMP/starter-$id.png" 760 "$OUT/starter-$id.png"
done

# MARK: - Clock faces

# One dashboard with eight faces in a grid.
cat > "$TMP/clocks.json" <<'EOF'
{
  "version": 1,
  "theme": { "background": "none" },
  "widgets": {
    "faces": {
      "type": "grid", "width": "fill", "gap": 56, "rowGap": 72,
      "columns": [ { "width": "fill", "align": "center" }, { "width": "fill", "align": "center" },
                   { "width": "fill", "align": "center" }, { "width": "fill", "align": "center" } ],
      "children": [
        { "type": "clock", "face": "flip", "seconds": false },
        { "type": "clock", "face": "analog", "ticks": "minutes", "dateWindow": true },
        { "type": "clock", "face": "matrix", "seconds": false },
        { "type": "clock", "face": "ring" },
        { "type": "clock", "face": "thin" },
        { "type": "clock", "face": "serif", "date": "words" },
        { "type": "clock", "face": "stacked" },
        { "type": "clock", "face": "condensed" }
      ]
    }
  },
  "views": { "main": { "maxWidth": 2400, "padding": 48, "children": ["faces"] } }
}
EOF
"$BIN" screenshot "$TMP/clocks.png" --config "$TMP/clocks.json" \
  --at "$AT" --size 2400x860 --scale 1 >/dev/null
fit "$TMP/clocks.png" 1800 "$OUT/clocks.png"

# MARK: - Backgrounds

# One tile per background, its name in the middle, then a 3 by 2 grid.
for b in aurora mesh sky rain topo stars; do
  cat > "$TMP/bg-$b.json" <<EOF
{ "version": 1, "theme": { "background": "$b" },
  "widgets": { "name": { "type": "text", "text": "$b", "style": { "size": 30, "weight": "light", "font": "mono" } } },
  "views": { "main": { "children": ["name"] } } }
EOF
  "$BIN" screenshot "$TMP/bg-$b.png" --config "$TMP/bg-$b.json" \
    --at "$AT" --size 640x400 --scale 2 >/dev/null
done
"$MONTAGE" "$TMP/backgrounds.png" --columns 3 --width 600 --gap 16 --pad 0 --radius 14 \
  "$TMP"/bg-aurora.png "$TMP"/bg-mesh.png "$TMP"/bg-sky.png \
  "$TMP"/bg-rain.png "$TMP"/bg-topo.png "$TMP"/bg-stars.png
fit "$TMP/backgrounds.png" 1600 "$OUT/backgrounds.png"

# MARK: - Widgets

# Twelve widget samples, each from its own config and data with no
# background, trimmed and packed into three columns.
WIDGETS="nowPlaying agendaList systemHealth reviewQueue ciStatus aiPlan containers watchlist habits forecast commitActivity focusTimer"
for id in $WIDGETS; do
  d=Resources/samples/$id
  meta=$(python3 - "$d" "$TMP/w-$id.json" <<'EOF'
import json, sys
d, out = sys.argv[1], sys.argv[2]
c = json.load(open(d + "/config.json"))
c.setdefault("theme", {})["background"] = "none"
json.dump(c, open(out, "w"))
s = json.load(open(d + "/sample.json"))
print(s["at"], "%dx%d" % tuple(s["size"]))
EOF
)
  set -- $meta
  if [ -d "$d/data" ]; then
    "$BIN" screenshot "$TMP/w-$id.png" --config "$TMP/w-$id.json" --data "$d/data" --at "$1" --size "$2" --scale 2 >/dev/null
  else
    "$BIN" screenshot "$TMP/w-$id.png" --config "$TMP/w-$id.json" --at "$1" --size "$2" --scale 2 >/dev/null
  fi
done
set --
for id in $WIDGETS; do set -- "$@" "$TMP/w-$id.png"; done
"$MONTAGE" "$TMP/widgets.png" --columns 3 --width 680 --gap 16 --pad 16 --radius 14 \
  --trim 40 --bg 101116 --masonry "$@"
fit "$TMP/widgets.png" 1800 "$OUT/widgets.png"

# MARK: - Asking an agent

# The results of three of the site's agent requests, each drawn from its
# sample (config, data and time) over the aurora.
for id in word-heatmap hn-nix weekend-garden; do
  d=Resources/samples/agent-$id
  if [ ! -d "$d" ]; then
    echo "no $d; kept $OUT/ask-$id.png as it is" >&2
    continue
  fi
  set -- $(python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); print(s["at"], "%dx%d" % tuple(s["size"]))' "$d/sample.json")
  "$BIN" screenshot "$TMP/ask-$id.png" --config "$d/config.json" --data "$d/data" --at "$1" --size "$2" --scale 2 >/dev/null
  fit "$TMP/ask-$id.png" 1200 "$OUT/ask-$id.png"
done
set --

# MARK: - Flip clock, animated

# Ten seconds across a minute at 10 frames a second; the aurora drifts
# forward and back so the loop has no jump in the background.
if command -v ffmpeg >/dev/null 2>&1; then
  cat > "$TMP/flip.json" <<'EOF'
{ "version": 1, "theme": { "background": "aurora" },
  "widgets": { "clock": { "type": "clock", "face": "flip", "seconds": true } },
  "views": { "main": { "children": ["clock"] } } }
EOF
  mkdir -p "$TMP/flip"
  base=1790528635   # 2026-09-27T17:03:55Z
  i=0
  while [ "$i" -lt 100 ]; do
    tri=$(( i < 50 ? i : 100 - i ))
    "$BIN" screenshot "$TMP/flip/$(printf %03d "$i").png" --config "$TMP/flip.json" \
      --at $(( base + i / 10 )) --size 760x380 --scale 2 \
      --background-time "$(( 14 + tri * 8 / 100 )).$(( tri * 8 % 100 / 10 ))$(( tri * 8 % 10 ))" >/dev/null
    i=$(( i + 1 ))
  done
  ffmpeg -hide_banner -loglevel error -y -framerate 10 -i "$TMP/flip/%03d.png" \
    -vf scale=760:-1:flags=lanczos -c:v libwebp_anim -quality 80 -loop 0 "$OUT/flip.webp"
  echo "$OUT/flip.webp $(wc -c < "$OUT/flip.webp") bytes"
else
  echo "ffmpeg not found; kept $OUT/flip.webp as it is" >&2
fi
