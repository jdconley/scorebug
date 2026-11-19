#!/bin/bash
# capture-watch.sh <watch-simulator-udid> <out-dir>
# Raw Apple Watch screenshots: builds the Watch app, then launches it with match states passed in
# SCOREBUG_WATCH_STATE (a Debug Simulator-only hook in WatchLink), so no paired iPhone is needed.
set -euo pipefail
W=$1; OUT=$2
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUT"
(cd "$ROOT/ios" && xcodegen generate -q)
xcodebuild build -project "$ROOT/ios/Scorebug.xcodeproj" -scheme ScorebugWatch \
  -destination "platform=watchOS Simulator,id=$W" -derivedDataPath "$ROOT/ios/DerivedData/Watch" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -quiet
xcrun simctl boot "$W" 2>/dev/null || true
xcrun simctl bootstatus "$W" -b >/dev/null
xcrun simctl install "$W" "$ROOT/ios/DerivedData/Watch/Build/Products/Debug-watchsimulator/ScorebugWatch.app"

team() {
  printf '"left":{"slot":"team1","shortName":"WILDCATS","color":"#2563eb","points":%s,"sets":%s},' "$1" "$2"
  printf '"right":{"slot":"team2","shortName":"MUSTANGS","color":"#dc2626","points":%s,"sets":%s}' "$3" "$4"
}
snap() {
  SIMCTL_CHILD_SCOREBUG_WATCH_STATE="$2" xcrun simctl launch --terminate-running-process "$W" live.scorebug.app.watchkitapp >/dev/null
  sleep 4
  xcrun simctl io "$W" screenshot "$OUT/$1.png" >/dev/null 2>&1
  magick "$OUT/$1.png" -alpha off -strip "$OUT/$1.png"   # the App Store rejects alpha
}
base='"version":1,"matchId":"m","canScore":true,"canUndo":true,"ended":false,"busy":false,"isLive":true'
snap score "{$base,$(team 18 1 15 0),\"set\":2,\"asksToSwap\":false}"
snap setpoint "{$base,$(team 25 1 23 0),\"set\":2,\"asksToSwap\":false,\"prompt\":{\"title\":\"WILDCATS wins set 2?\",\"scoreLine\":\"25 – 23\",\"confirmLabel\":\"End match\"}}"
snap swap "{$base,$(team 0 1 0 1),\"set\":3,\"asksToSwap\":true}"
ls "$OUT"
