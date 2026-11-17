#!/usr/bin/env bash
# Archives Scorebug (iPhone + embedded Watch app) and uploads it to App Store
# Connect, where the internal TestFlight group gets every build automatically.
# Signs with Xcode cloud signing through an Admin App Store Connect API key:
#   ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
#
#   TEAM_ID=… ASC_KEY_ID=… ASC_ISSUER_ID=… ios/release/testflight.sh   # build number = UTC timestamp
#   BUILD_NUMBER=42 ios/release/testflight.sh
#
# CI runs this on every push to main that changes the app (.github/workflows/native.yml, job
# "TestFlight upload"), with the key from the ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 secrets.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ios="$(dirname "$here")"
team="${TEAM_ID:?set TEAM_ID to the Apple developer team ID}"
build="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
key_id="${ASC_KEY_ID:?set ASC_KEY_ID to the App Store Connect API key ID}"
issuer="${ASC_ISSUER_ID:?set ASC_ISSUER_ID to the App Store Connect issuer ID}"
key_path="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8}"
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key_path" -authenticationKeyID "$key_id"
  -authenticationKeyIssuerID "$issuer")
out="${OUT_DIR:-$(mktemp -d)}"

xcodegen generate --spec "$ios/Project.yml" >/dev/null
xcodebuild -project "$ios/Scorebug.xcodeproj" -scheme Scorebug -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$out/Scorebug.xcarchive" \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$build" \
  "${auth[@]}" archive
xcodebuild -exportArchive -archivePath "$out/Scorebug.xcarchive" \
  -exportOptionsPlist "$here/ExportOptions.plist" -exportPath "$out/export" "${auth[@]}"

echo "Uploaded build $build. It appears in App Store Connect > Scorebug Live > TestFlight after processing."
