#!/bin/sh
# Archives Pair & Shoot and uploads it to TestFlight (internal testing only; it can't be
# submitted to the App Store from this build). Needs Xcode signed in to the developer
# account (Xcode > Settings > Accounts) so signing and the upload can be managed automatically.
#
#   Tools/testflight-upload.sh            # build number = current timestamp
#   Tools/testflight-upload.sh 42         # explicit build number
set -eu
cd "$(dirname "$0")/.."

BUILD_NUMBER="${1:-$(date +%Y%m%d%H%M)}"
OUT="${TMPDIR:-/tmp}/PairAndShoot-testflight"
rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild -project PairAndShoot.xcodeproj -scheme PairAndShoot -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$OUT/PairAndShoot.xcarchive" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive

xcodebuild -exportArchive \
  -archivePath "$OUT/PairAndShoot.xcarchive" \
  -exportOptionsPlist Tools/ExportOptions.plist \
  -exportPath "$OUT/export" \
  -allowProvisioningUpdates

echo "Uploaded build $BUILD_NUMBER. It shows up in TestFlight once Apple finishes processing (usually 5-15 minutes)."
