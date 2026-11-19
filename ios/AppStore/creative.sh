#!/bin/bash
# creative.sh <out-dir>
# The App Store's header (3840x1646) and search result (3840x2560) art, as PNG (the upload takes PNG): the gym, softened and
# darkened, with the real scorebug (drawn by the match container's renderer) large in the middle,
# where every device keeps it. No alpha. Needs ImageMagick 7.
set -euo pipefail
OUT=$1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
mkdir -p "$OUT"
pnpm --dir "$ROOT" --filter @scorebug/home-daemon render-scorebug "$TMP" --media >/dev/null
magick "$TMP/store-bar-4k.png" -trim +repage "$TMP/bug.png"

art() { # <name> <width> <height> <bug-width>
  local w=$2 h=$3 bw=$4
  magick "$ROOT/ios/AppStore/gym.jpg" -resize "${w}x${h}^" -gravity center -extent "${w}x${h}" \
    -blur 0x6 -modulate 70,85 \
    \( -size "${w}x${h}" radial-gradient:"rgba(11,13,16,0)"-"rgba(11,13,16,0.85)" \) -composite \
    \( "$TMP/bug.png" -resize "${bw}x" \( +clone -background black -shadow 60x40+0+30 \) +swap \
       -background none -layers merge +repage \) -gravity center -composite \
    -alpha off -define png:compression-level=9 "$OUT/$1.png"
}
art header 3840 1646 1500
art search 3840 2560 1900
ls -la "$OUT"/header.png "$OUT"/search.png
