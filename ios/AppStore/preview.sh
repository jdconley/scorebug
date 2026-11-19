#!/bin/bash
# preview.sh <iphone-simulator-udid> <out-dir>
# The App Store app preview (1920x886, landscape iPhone 6.3"-class) and the website's clip: records
# the Simulator while StoreMediaTests/testPreview plays the end of a live set, then cuts it at the
# marks the test writes. Same local setup as capture.sh (local Worker, SRT listener, gym clip).
set -euo pipefail
SIM=$1; OUT=$2
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RAW=$(mktemp -d)
"$ROOT/ios/AppStore/capture.sh" "$SIM" "$RAW" preview &
CAPTURE=$!
# Start recording once the app is installed and the test is about to launch it.
until [ -f "$RAW/.recording-ready" ] || ! kill -0 $CAPTURE 2>/dev/null; do sleep 0.5; done
xcrun simctl io "$SIM" recordVideo --codec h264 --force "$RAW/take.mov" 2>"$RAW/record.log" &
RECORD=$!
# The video's first frame is when simctl says so, a second or two after launch.
until grep -q "Recording started" "$RAW/record.log" 2>/dev/null; do sleep 0.05; done
START=$(python3 -c 'import time; print(time.time())')
wait $CAPTURE
kill -INT $RECORD; wait $RECORD || true

start=$(awk '$1=="start"{print $2}' "$RAW/marks.txt" 2>/dev/null); end=$(awk '$1=="end"{print $2}' "$RAW/marks.txt" 2>/dev/null)
[ -n "$start" ] && [ -n "$end" ] || { echo "preview: the take didn't finish (no marks)" >&2; exit 1; }
from=$(python3 -c "print(round($start - $START - 0.5, 2))"); length=$(python3 -c "print(min(29.5, round($end - $start, 2)))")
# The recording is the portrait framebuffer: turn it upright, fit 1920x886, add quiet room tone
# (App Store previews need an audio track), and fade in and out.
ffmpeg -v error -y -ss "$from" -t "$length" -i "$RAW/take.mov" \
  -f lavfi -t "$length" -i "anoisesrc=color=brown:amplitude=0.012:sample_rate=44100" \
  -filter_complex "[0:v]transpose=2,scale=1920:886:force_original_aspect_ratio=increase,crop=1920:886,fps=30,format=yuv420p,fade=in:0:15,fade=out:st=$(python3 -c "print($length-0.6)"):d=0.6[v];[1:a]lowpass=f=700,aformat=channel_layouts=stereo,afade=in:d=0.5,afade=out:st=$(python3 -c "print($length-0.6)"):d=0.6[a]" \
  -map "[v]" -map "[a]" -c:v libx264 -profile:v high -level 4.0 -b:v 6M -maxrate 8M -bufsize 12M \
  -c:a aac -b:a 256k -ar 44100 -movflags +faststart "$OUT/iphone-preview.mp4"
ffprobe -v error -show_entries format=duration:stream=width,height,codec_name -of compact "$OUT/iphone-preview.mp4"
