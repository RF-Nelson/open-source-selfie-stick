#!/bin/sh
# Install a Debug build of Pair & Shoot on a USB-connected iPhone/iPad and stream the logs that
# matter for peer-to-peer pairing (our transport + MultipeerConnectivity + AWDL/Bluetooth).
#
# Prereqs: the device connected by cable and "trusted"; Xcode signed in to the developer account;
# libimobiledevice installed (brew install libimobiledevice) for idevicesyslog.
#
#   Tools/device-debug.sh            # build, install, then stream logs
#   Tools/device-debug.sh --logs     # just stream logs (app already installed)
set -eu
cd "$(dirname "$0")/.."

DEV_ID=$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ {print $(NF-1); exit}')
if [ -z "${DEV_ID:-}" ]; then
  echo "No connected device found. Plug in the iPhone by cable, unlock it, and tap Trust."
  echo "Then re-run. (xcrun devicectl list devices)"
  exit 1
fi
echo "Device: $DEV_ID"

if [ "${1:-}" != "--logs" ]; then
  OUT="${TMPDIR:-/tmp}/PairAndShoot-debug"
  rm -rf "$OUT"; mkdir -p "$OUT"
  echo "Building Debug for device…"
  xcodebuild -project PairAndShoot.xcodeproj -scheme PairAndShoot -configuration Debug \
    -destination "id=$DEV_ID" -derivedDataPath "$OUT" -allowProvisioningUpdates build
  APP=$(find "$OUT/Build/Products/Debug-iphoneos" -maxdepth 1 -name '*.app' | head -1)
  echo "Installing $APP…"
  xcrun devicectl device install app --device "$DEV_ID" "$APP"
fi

echo "Streaming logs. Open Pair & Shoot on BOTH phones and try to pair. Ctrl-C to stop."
idevicesyslog 2>/dev/null | grep -iE 'pairandshoot|MCSession|Multipeer|MCNearby|awdl|com.apple.p2p|bluetooth|GCK' 
