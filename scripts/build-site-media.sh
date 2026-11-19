#!/bin/bash
# scripts/build-site-media.sh <raw-iphone-dir> <raw-watch-dir> <app-preview.mp4>
# The website's images and video, into apps/control-plane/public/media (served as static assets):
#   app-*.{webp,jpg}   app screens from ios/AppStore/capture.sh, at 1x and 2x display width
#   watch.{webp,png}   the Watch scoring screen from ios/AppStore/capture-watch.sh
#   style-*.{webp,jpg} the scorebug styles over the gym, drawn by the match container's renderer
#   stream.mp4 + .jpg  what viewers see on YouTube: the gym with the score changing, silent loop
#   app.mp4 + .jpg     the App Store preview (ios/AppStore/preview.sh), silent, for the page
# Needs ffmpeg, cwebp and ImageMagick 7.
set -euo pipefail
IPHONE=$1; WATCH=$2; PREVIEW=$3
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/apps/control-plane/public/media"
TMP=$(mktemp -d)
mkdir -p "$OUT"
rm -f "$OUT"/*

image() { # <src> <name> <display-width>
  local name=$2 width=$3
  for scale in 1 2; do
    local suffix=""; [ $scale = 2 ] && suffix="@2x"
    magick "$1" -resize "$((width * scale))x" -strip "$TMP/$name$suffix.png"
    cwebp -quiet -q 82 "$TMP/$name$suffix.png" -o "$OUT/$name$suffix.webp"
    magick "$TMP/$name$suffix.png" -quality 80 "$OUT/$name$suffix.jpg"
  done
}
image "$IPHONE/live.png" app-live 640
image "$IPHONE/scorer.png" app-scorer 220
magick "$WATCH/score.png" -strip "$OUT/watch.png"; cwebp -quiet -q 85 "$OUT/watch.png" -o "$OUT/watch.webp"

pnpm --dir "$ROOT" --filter @scorebug/home-daemon exec tsx scripts/render-sample.ts "$TMP/overlay" >/dev/null
for style in bar lowerThird setCard; do
  magick "$ROOT/ios/AppStore/gym.jpg" -resize 1920x1080! "$TMP/overlay/style-$style.png" -composite "$TMP/style-$style.png"
  image "$TMP/style-$style.png" "style-$style" 320
done

# What viewers see: the gym with a little grain, the score moving every 1.5 s, 12 s, looping.
list="$TMP/scores.txt"; : > "$list"
for i in 0 1 2 3 4 5 6 7; do printf "file '%s'\nduration 1.5\n" "$TMP/overlay/score-$i.png" >> "$list"; done
printf "file '%s'\n" "$TMP/overlay/score-7.png" >> "$list"
ffmpeg -v error -y -loop 1 -framerate 30 -i "$ROOT/ios/AppStore/gym.jpg" -f concat -safe 0 -i "$list" \
  -filter_complex "[0:v]scale=1920:1080,noise=alls=3:allf=t[bg];[1:v]fps=30[ov];[bg][ov]overlay=0:0:shortest=1,scale=1280:720,format=yuv420p[v]" \
  -map "[v]" -t 12 -an -c:v libx264 -preset slow -crf 26 -movflags +faststart "$OUT/stream.mp4"
ffmpeg -v error -y -ss 11.5 -i "$OUT/stream.mp4" -frames:v 1 -q:v 4 "$OUT/stream.jpg"

ffmpeg -v error -y -i "$PREVIEW" -an -vf "scale=1280:-2" -c:v libx264 -preset slow -crf 26 -movflags +faststart "$OUT/app.mp4"
ffmpeg -v error -y -ss 1 -i "$OUT/app.mp4" -frames:v 1 -q:v 4 "$OUT/app.jpg"
du -sh "$OUT"; ls "$OUT"
