#!/bin/zsh
# App Store screenshots from the Simulator, staged through the Debug-only ScreenshotMode
# (ShotCaller/App/ScreenshotMode.swift): both roles run in one process over an in-memory transport,
# and a photo from disk is what the camera sees. The Simulator has no Bluetooth and no camera, so
# this is the only way to photograph a connected session there.
#
#   Tools/screenshots.sh <photo> [out dir]        capture every scene on both devices
#   Tools/screenshots.sh --delete                 remove the simulator devices and the build
#   ONLY=iphone|ipad Tools/screenshots.sh …       one device family
#   PHOTO_IPAD=<photo> Tools/screenshots.sh …     a different picture for the iPad scenes
#
# The iPad scenes are landscape. simctl cannot rotate a device and an iPad app that supports
# multitasking cannot force its orientation, so the script opens the Simulator app on that device
# and clicks Device > Rotate Left through System Events (the terminal needs Accessibility access;
# the first run may prompt for it). It rotates back and quits the Simulator app when done.
#
# Devices: iPhone 17 Pro Max (1320x2868, the 6.9" slot) and iPad Pro 13-inch M4 (2064x2752 /
# 2752x2064, the 13" slot) on the installed iOS 26.5 runtime, created on first use. Booting one
# costs a few hundred MB of device data; --delete gives it back. Each scene is a fresh launch with
# the scene in SHOTCALLER_SCREENSHOT, then a wait for the staged session to reach the moment.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=com.richardnelson.opensourceselfiestick
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-5
IPHONE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
IPAD_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB
IPHONE_NAME="ShotCaller Screenshots iPhone"
IPAD_NAME="ShotCaller Screenshots iPad"
DERIVED=build/DerivedData-sim
APP=$DERIVED/Build/Products/Debug-iphonesimulator/ShotCaller.app
ME_IPHONE=${SHOTCALLER_IPHONE_NAME:-"Rich’s iPhone"}
ME_IPAD=${SHOTCALLER_IPAD_NAME:-"Rich’s iPad"}

device_id() {  # name -> udid or empty
  xcrun simctl list devices | grep -F "$1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true
}

if [[ "${1:-}" == "--delete" ]]; then
  for name in "$IPHONE_NAME" "$IPAD_NAME"; do
    id=$(device_id "$name")
    if [[ -n "$id" ]]; then
      xcrun simctl shutdown "$id" 2>/dev/null || true
      xcrun simctl delete "$id"
      echo "Deleted $name ($id)"
    fi
  done
  rm -rf "$DERIVED"
  echo "Removed $DERIVED"
  exit 0
fi

PHOTO=${1:?usage: Tools/screenshots.sh <photo> [out dir] | --delete}
PHOTO=$(cd "$(dirname "$PHOTO")" && pwd)/$(basename "$PHOTO")
PHOTO_IPAD=${PHOTO_IPAD:-$PHOTO}
PHOTO_IPAD=$(cd "$(dirname "$PHOTO_IPAD")" && pwd)/$(basename "$PHOTO_IPAD")
OUT=${2:-build/screenshots}
mkdir -p "$OUT"

echo "Building (Debug, simulator)…"
xcodebuild -project ShotCaller.xcodeproj -scheme ShotCaller -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[[ -d "$APP" ]] || { echo "No app at $APP"; exit 1; }

ensure_device() {  # name type -> udid
  local id
  id=$(device_id "$1")
  if [[ -z "$id" ]]; then
    id=$(xcrun simctl create "$1" "$2" "$RUNTIME")
    echo "Created $1 ($id)" >&2
  fi
  echo "$id"
}

prepare() {  # udid
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null
  xcrun simctl install "$1" "$APP"
  xcrun simctl privacy "$1" grant photos-add "$BUNDLE" 2>/dev/null || true
  xcrun simctl status_bar "$1" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
}

rotate() {  # udid "Rotate Left"|"Rotate Right" — through the Simulator app's Device menu
  open -a Simulator --args -CurrentDeviceUDID "$1"
  osascript -e 'delay 10' -e 'tell application "Simulator" to activate' \
    -e "tell application \"System Events\" to tell process \"Simulator\" to click menu item \"$2\" of menu \"Device\" of menu bar 1" >/dev/null
  sleep 2
}

# capture udid scene me peer photo wait-seconds file [turn]
# simctl always returns the portrait framebuffer; `turn` (sips degrees) uprights a rotated device's capture.
capture() {
  local id=$1 scene=$2 me=$3 peer=$4 photo=$5 wait=$6 file=$7 turn=${8:-0}
  xcrun simctl terminate "$id" "$BUNDLE" 2>/dev/null || true
  SIMCTL_CHILD_SHOTCALLER_SCREENSHOT="$scene" \
  SIMCTL_CHILD_SHOTCALLER_SCREENSHOT_PHOTO="$photo" \
  SIMCTL_CHILD_SHOTCALLER_SCREENSHOT_NAME="$me" \
  SIMCTL_CHILD_SHOTCALLER_SCREENSHOT_PEER="$peer" \
    xcrun simctl launch "$id" "$BUNDLE" >/dev/null
  sleep "$wait"
  xcrun simctl io "$id" screenshot --type=png "$OUT/$file" >/dev/null 2>&1
  [[ "$turn" == 0 ]] || sips -r "$turn" "$OUT/$file" >/dev/null
  xcrun simctl terminate "$id" "$BUNDLE" 2>/dev/null || true
  echo "$OUT/$file  $(sips -g pixelWidth -g pixelHeight "$OUT/$file" | awk '/pixel/ {printf "%s ", $2}')"
}

if [[ "${ONLY:-}" != "ipad" ]]; then
IPHONE=$(ensure_device "$IPHONE_NAME" "$IPHONE_TYPE")
prepare "$IPHONE"
capture "$IPHONE" remote-live      "$ME_IPHONE" "$ME_IPAD" "$PHOTO" 7  iphone-1-live.png
capture "$IPHONE" remote-countdown "$ME_IPHONE" "$ME_IPAD" "$PHOTO" 10 iphone-2-countdown.png
capture "$IPHONE" camera-live      "$ME_IPHONE" "$ME_IPAD" "$PHOTO" 7  iphone-3-camera.png
capture "$IPHONE" remote-saved     "$ME_IPHONE" "$ME_IPAD" "$PHOTO" 15 iphone-4-saved.png
xcrun simctl shutdown "$IPHONE"
fi

if [[ "${ONLY:-}" != "iphone" ]]; then
IPAD=$(ensure_device "$IPAD_NAME" "$IPAD_TYPE")
prepare "$IPAD"
rotate "$IPAD" "Rotate Left"
capture "$IPAD" remote-live     "$ME_IPAD" "$ME_IPHONE" "$PHOTO_IPAD" 7 ipad-1-live.png -90
capture "$IPAD" remote-settings "$ME_IPAD" "$ME_IPHONE" "$PHOTO_IPAD" 9 ipad-2-settings.png -90
rotate "$IPAD" "Rotate Right"
osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true
xcrun simctl shutdown "$IPAD"
fi

echo "Done. Review $OUT, then Tools/screenshots.sh --delete to reclaim the disk."
