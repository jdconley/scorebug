#!/bin/bash
# capture.sh <simulator-udid> <out-dir> [preview]
# Raw App Store screenshots: runs StoreMediaTests on one simulator against the local Worker
# (ios/AppUITests/LocalWorker), with the camera reading a clip made from gym.jpg (a generated
# photo of an empty gym: no real people in store media) and Go Live publishing to
# an SRT listener on this Mac, so the live screen really is live. Landscape shots come back
# made upright. With "preview" it runs only the preview take (see preview.sh), touching
# <out-dir>/.recording-ready just before the test starts. Needs srt-live-transmit
# (brew install srt), ffmpeg and ImageMagick 7.
set -euo pipefail
SIM=$1; OUT=$2; MODE=${3:-shots}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$ROOT/ios/AppUITests/LocalWorker"
W="$ROOT/apps/control-plane/node_modules/.bin/wrangler"
LOG=$(mktemp -d)
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

# A tripod-still camera: the photo with sensor grain and quiet room tone.
CLIP="$LOG/input.mov"
ffmpeg -v error -y -loop 1 -framerate 30 -i "$ROOT/ios/AppStore/gym.jpg" \
  -f lavfi -i "anoisesrc=color=brown:amplitude=0.02:sample_rate=48000" \
  -filter_complex "[0:v]scale=1920:1080:flags=lanczos,noise=alls=4:allf=t,format=yuv420p[v];[1:a]lowpass=f=900,aformat=channel_layouts=mono[a]" \
  -map "[v]" -map "[a]" -t 240 -c:v libx264 -preset veryfast -crf 26 -g 60 -c:a aac -b:a 64k "$CLIP"

pnpm --dir "$ROOT" --filter @scorebug/protocol build >/dev/null
(cd "$WORKER" && rm -rf .state && "$W" d1 migrations apply scorebug-dev --local --persist-to .state >/dev/null)
srt-live-transmit "srt://:9000?mode=listener" file://con >/dev/null 2>"$LOG/srt.log" &
SRT=$!
(cd "$WORKER" && exec "$W" dev --ip 127.0.0.1 --port 8787 --persist-to .state \
  --var "DEV_PUBLISH_URL:srt://127.0.0.1:9000?streamid=store") >"$LOG/worker.log" 2>&1 &
WRANGLER=$!
trap 'kill $SRT $WRANGLER 2>/dev/null; pkill -P $WRANGLER 2>/dev/null || true' EXIT
until curl -sf http://127.0.0.1:8787/healthz >/dev/null; do sleep 1; done

(cd "$ROOT/ios" && xcodegen generate -q)
xcodebuild build-for-testing -project "$ROOT/ios/Scorebug.xcodeproj" -scheme Scorebug \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$ROOT/ios/DerivedData/Sim" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -quiet

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl uninstall "$SIM" live.scorebug.app 2>/dev/null || true
xcrun simctl install "$SIM" "$ROOT/ios/DerivedData/Sim/Build/Products/Debug-iphonesimulator/Scorebug.app"
DATA=$(xcrun simctl get_app_container "$SIM" live.scorebug.app data)
mkdir -p "$DATA/Library/Application Support/Scorebug/QA"
cp "$CLIP" "$DATA/Library/Application Support/Scorebug/QA/input.mov"
xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4 --dataNetwork wifi

rm -f "$OUT"/*.png "$OUT/marks.txt"
if [ "$MODE" = preview ]; then
  TESTS=(-only-testing:ScorebugAppUITests/StoreMediaTests/testPreview SCOREBUG_STORE_PREVIEW=1)
  touch "$OUT/.recording-ready"
else
  TESTS=(-only-testing:ScorebugAppUITests/StoreMediaTests)
fi
# xcodebuild sometimes sits for minutes after the last test ends: stop it once the run is over.
xcodebuild test-without-building -project "$ROOT/ios/Scorebug.xcodeproj" -scheme Scorebug \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$ROOT/ios/DerivedData/Sim" \
  "${TESTS[@]}" SCOREBUG_STORE_MEDIA="$OUT" SCOREBUG_TEST_API_URL=http://127.0.0.1:8787 \
  >"$LOG/test.log" 2>&1 &
XCODEBUILD=$!
until grep -q "^Test Suite 'Selected tests' \(passed\|failed\)" "$LOG/test.log" || ! kill -0 $XCODEBUILD 2>/dev/null; do
  sleep 2
done
sleep 5; kill $XCODEBUILD 2>/dev/null || true
grep -E "error:|passed \(|failed \(" "$LOG/test.log" || true

# XCUIScreen saves landscape screens as portrait pixels with an EXIF orientation: make the pixels
# upright and drop the tag, so every tool sees the same picture.
for f in "$OUT"/*.png; do [ -f "$f" ] && magick "$f" -auto-orient -strip "$f"; done
grep -q "Accepted SRT source connection" "$LOG/srt.log" && echo "stream: went live" || echo "stream: never connected"
ls "$OUT"
