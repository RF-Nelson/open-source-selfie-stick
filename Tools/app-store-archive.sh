#!/bin/sh
# Create a signed Release archive and App Store IPA locally. Does not upload or submit.
# Requires Xcode signed into the developer account with distribution signing access.
#
#   Tools/app-store-archive.sh       # timestamp build number
#   Tools/app-store-archive.sh 42    # explicit, previously unused build number
set -eu

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [build-number]" >&2
  exit 2
fi
case "${1:-}" in
  -h|--help)
    echo "Usage: $0 [build-number]"
    echo "Creates a local signed archive and App Store IPA in build/. Does not upload."
    exit 0
    ;;
esac

BUILD_NUMBER="${1:-$(date +%Y%m%d%H%M)}"
case "$BUILD_NUMBER" in
  ''|*[!0-9]*)
    echo "Build number must contain digits only." >&2
    exit 2
    ;;
esac

cd "$(dirname "$0")/.."
plutil -lint ShotCaller/PrivacyInfo.xcprivacy Tools/ExportOptions-AppStore.plist
mkdir -p build
# A fresh directory preserves earlier release artifacts, even if the build number is reused.
OUT=$(mktemp -d "$(pwd)/build/ShotCaller-AppStore-$BUILD_NUMBER-XXXXXX")
echo "Saving release artifacts to $OUT"

xcodebuild -project ShotCaller.xcodeproj -scheme ShotCaller -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$OUT/ShotCaller.xcarchive" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive

APP="$OUT/ShotCaller.xcarchive/Products/Applications/ShotCaller.app"
for RESOURCE in PrivacyInfo.xcprivacy PRIVACY.md; do
  if [ ! -f "$APP/$RESOURCE" ]; then
    echo "Missing $RESOURCE in archive. Run xcodegen generate, then archive again." >&2
    exit 1
  fi
done
plutil -lint "$APP/PrivacyInfo.xcprivacy"

xcodebuild -exportArchive \
  -archivePath "$OUT/ShotCaller.xcarchive" \
  -exportOptionsPlist Tools/ExportOptions-AppStore.plist \
  -exportPath "$OUT/export" \
  -allowProvisioningUpdates

echo "App Store archive: $OUT/ShotCaller.xcarchive"
echo "Local export: $OUT/export"
echo "Nothing was uploaded. Complete docs/APP_STORE_RELEASE.md before distributing this build."
