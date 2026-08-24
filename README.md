<div align="center">
<img src="docs/icon.png" width="128" alt="Pair &amp; Shoot icon"><br><br>

# Pair &amp; Shoot

**Turn a second iPhone or iPad into a remote control for another one's camera.**<br>
Photos and video over Wi-Fi — a shared network, or peer-to-peer with no network — with copies sent back to the remote if you want them.

<img src="https://img.shields.io/badge/platform-iOS%2018%2B-lightgrey.svg?style=flat" alt="iOS 18+"> <img src="https://img.shields.io/badge/swift-6-orange.svg?style=flat" alt="Swift 6"> <img src="https://img.shields.io/badge/license-MPL--2.0-lightgrey.svg?style=flat" alt="MPL 2.0">
</div>

> **Status:** version 2.0 is a from-scratch rebuild of the 2016 app *Open Source Selfie Stick* (kept at tag [`v1.0-legacy`](../../tree/v1.0-legacy)). The logic layer is complete and covered by tests; the app compiles for iOS 18–26 but has **not yet been exercised on two physical devices** — see [Status](#status).

## What it does

- **Two roles.** Open the app on both devices. One becomes the **camera**, the other the **remote**.
- **Pairing with a code.** The camera shows a 4-digit code; the remote types it in. No other device nearby can drive your camera, and the link is encrypted.
- **Photos and video.** The remote switches modes, cycles the flash, flips between front and back cameras, starts a countdown the people in the shot can see on the camera's screen, takes the picture or starts and stops recording.
- **Copies where you want them.** The camera keeps its own copies (switchable). The remote can ask for photos to be sent back (default on) and videos (default off — they're big). Every capture sends a small preview to the remote either way, so you always see what you just shot.
- **Modern camera.** HEIF photos at full sensor resolution, HEVC video with stabilization, horizon-level rotation handling, tap to focus, pinch to zoom, Camera Control / volume-button shutter on the camera device.

## How it works

1. Open Pair &amp; Shoot on both devices and choose **Camera** on one, **Remote** on the other.
2. On the remote, tap the camera in the list and enter the code on its screen.
3. Shoot. Photos arrive on the remote in a few seconds; videos stay on the camera unless you ask for them.

**Keep Wi-Fi on for both devices.** The same Wi-Fi network is most reliable; it also works with Wi-Fi on but no network joined (peer-to-peer Wi-Fi), which is less reliable. It does **not** work over Bluetooth alone: modern iOS carries MultipeerConnectivity's data channel over Wi-Fi (infrastructure or peer-to-peer/AWDL) and only ever used Bluetooth to assist discovery, so with Wi-Fi off there is no data path. See [docs/TRANSPORT.md](docs/TRANSPORT.md).

## Building

Requirements: Xcode 26, an iOS 18+ device for each role (the Simulator has no camera; the camera role runs there with generated photos only).

```sh
git clone https://github.com/RF-Nelson/open-source-selfie-stick.git
cd open-source-selfie-stick
open PairAndShoot.xcodeproj      # select your team under Signing & Capabilities, then run on a device
```

The project file is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and committed, so you don't need XcodeGen unless you change `project.yml` (`brew install xcodegen && xcodegen generate`).

Tests live in the Swift package and run without a simulator:

```sh
cd Packages/PairAndShootCore && swift test
```

They also run from Xcode's test navigator (the shared scheme includes them).

To put a build on TestFlight for internal testers, run `Tools/testflight-upload.sh` (archives, signs and uploads; Xcode must be signed in to the developer account).

## Architecture

```
PairAndShoot/                 the app (SwiftUI, iOS 18+)
├─ App/                       entry point, role picker, device naming
├─ Design/                    theme and shared controls (shutter, mode switch, pills, banners)
├─ Camera/                    CaptureService (AVFoundation actor), preview view, PhotoKit store, camera screen
└─ Remote/                    remote screen, code entry
Packages/PairAndShootCore/    everything that doesn't need a device — with tests
├─ Protocol/                  RemoteCommand / CameraEvent (Codable, versioned) and the JSON codec
├─ Pairing/                   pairing code, per-session challenge, HMAC proof
├─ Transport/                 PeerTransport protocol, MultipeerTransport, FakeTransport
├─ Camera/                    CameraDevice / MediaStore protocols, CameraHostModel (camera-side logic)
└─ Remote/                    RemoteModel (remote-side logic)
Tools/render-icon.swift       draws the app icon (light, dark, tinted)
```

- **Transport is a protocol.** `MultipeerTransport` is the only thing that imports MultipeerConnectivity. It turns the framework's delegate callbacks into one `AsyncStream<TransportEvent>`. Swapping in Network.framework or Wi-Fi Aware later touches nothing above it.
- **The wire protocol is typed.** Remote → camera is `RemoteCommand`; camera → remote is `CameraEvent`. The camera sends a full `CameraState` snapshot whenever anything changes, and the remote renders from it. Every message carries a protocol version; mismatched versions refuse to talk with a clear message on both screens.
- **Both role models are pure logic.** `CameraHostModel` and `RemoteModel` talk to a `PeerTransport`, a `CameraDevice` and a `MediaStore`; the app supplies AVFoundation, PhotoKit and Multipeer, the tests supply fakes. `EndToEndTests` drives a remote model against a camera model over two linked fake transports.
- **Pairing.** The camera advertises a random per-session challenge. The remote's invitation carries `HMAC-SHA256(key: SHA256(code), challenge + remoteName)`. The camera verifies before accepting, allows one remote at a time, and issues a new code after three wrong guesses. The Multipeer session itself is encrypted. This keeps strangers with the app out; it is not designed to resist someone sniffing the local network with custom tooling.
- **Files.** Photos are sent as the original HEIF/JPEG file (metadata intact). Videos are HEVC `.mov`. Transfers use Multipeer's resource API with progress on both ends; the receiver saves to Photos with add-only permission.

## Status

Done and verified on this machine:

- Core package: 35 tests covering the codec, pairing, both models and the end-to-end flow.
- App: builds for iOS device and Simulator SDKs under Swift 6 strict concurrency with no warnings.

Not yet done — needs two physical devices:

- Run the pairing flow, capture, video and transfers on real hardware (AVFoundation and Multipeer behaviour can't be tested without them).
- iPad layout pass, localisation, manual exposure controls, a session gallery, live preview on the remote.
- A Bluetooth-only transport (Core Bluetooth) for shutter control with Wi-Fi off — see [docs/TRANSPORT.md](docs/TRANSPORT.md).

### TODO
- [ ] Test a Bluetooth-only remote-control mode: shutter/controls over Bluetooth with Wi-Fi off (Core Bluetooth transport; media stays on the camera since BLE is too slow to transfer photos/video). See [docs/TRANSPORT.md](docs/TRANSPORT.md).

## History

Version 1.0 (2016) was written in Swift 2 against iOS 8 and shipped to the App Store as *Open Source Selfie Stick*. It no longer builds with any current Xcode and would crash on any current iPhone, so 2.0 started from an empty tree, keeping the product idea, the App Store listing and the lessons. The original is preserved at tag `v1.0-legacy`, and the original write-up on Multipeer Connectivity is still a good read: [tutorial](https://gist.github.com/RF-Nelson/8a3e6319b0607cf6b181ae4ee00f6c4c).

## License

[MPL 2.0](LICENSE).
