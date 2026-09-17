<div align="center">
<img src="docs/icon.png" width="128" alt="Shot Caller icon"><br><br>

# Shot Caller

**Turn a second iPhone or iPad into a remote control for another one's camera.**<br>
Control a nearby camera over Bluetooth without a shared Wi-Fi network. Photos and videos transfer over Wi-Fi automatically when available, or over Bluetooth on demand.

<img src="https://img.shields.io/badge/platform-iOS%2018%2B-lightgrey.svg?style=flat" alt="iOS 18+"> <img src="https://img.shields.io/badge/swift-6-orange.svg?style=flat" alt="Swift 6"> <img src="https://img.shields.io/badge/license-MPL--2.0-lightgrey.svg?style=flat" alt="MPL 2.0">
</div>

> **Status:** version 2.0 rebuilds the 2016 app *Open Source Selfie Stick* (preserved at [`v1.0-legacy`](../../tree/v1.0-legacy)). The earlier Bluetooth + Wi-Fi implementation was verified on two physical devices running iOS 26. The current UX, permission, capture-recovery, and Wi-Fi Aware fixes still need a fresh physical-device acceptance run before release. See [Status](#status) and the [App Store release checklist](docs/APP_STORE_RELEASE.md).

## What it does

- **Two roles.** Open the app on both devices. One becomes the **camera**, the other the **remote**.
- **Pairing you control.** Automatic connection uses a four-digit code shown on the camera. Optional Wi-Fi Aware uses Apple's system pairing on supported devices.
- **Photos and video.** The remote switches modes, cycles the flash, flips between front and back cameras, starts a countdown the people in the shot can see on the camera's screen, takes the picture or starts and stops recording.
- **Copies where you want them.** Choose whether the camera saves to Photos and whether the remote requests photos or videos. The paired remote receives small previews either way. Full files transfer automatically over a Wi-Fi path; on Bluetooth they wait for a download request with a size/time estimate and photo-size choices. Files waiting for transfer are queued automatically when Wi-Fi becomes available. Failed Photos saves can be retried while the session remains open.
- **Camera controls.** HEIF photos and HEVC video where supported, stabilization, horizon-level rotation handling, tap to focus, pinch to zoom, and Camera Control / volume-button shutter on the camera device.
- **Permissions explained.** Each role has a first-use setup with optional saving. The remote does not ask for Camera or Microphone. Privacy & Help includes an offline policy and support access.

## How it works

1. Open Shot Caller on both devices and choose **Camera** on one, **Remote** on the other.
2. On the remote, tap the camera in the list and enter the code on its screen.
3. Shoot. Controls use Bluetooth; full files use a Wi-Fi path when available. Otherwise the remote offers a **Download** button (Bluetooth is slower). Keep both apps open while shooting and transferring.

**Automatic connection layers Bluetooth and Wi-Fi.** Bluetooth handles discovery, code pairing, and controls. It must stay enabled, including when using Airplane Mode. When both devices can reach each other over Wi-Fi/AWDL, the app establishes a Wi-Fi path for files. Otherwise full copies can be downloaded over Bluetooth.

**Wi-Fi Aware is optional.** On two supported devices running iOS/iPadOS 26 or later, turn on Wi-Fi Aware in the **Connection** section of both home screens before choosing roles. Open the camera's pairing control, then pair it on the remote using Apple's system prompt. This replaces the four-digit app code. The current implementation fixes the handoff between system pairing and data discovery; physical validation is still required. See [docs/TRANSPORT.md](docs/TRANSPORT.md).

## Building

Requirements: Xcode 26, an iOS 18+ device for each role (the Simulator has no camera; the camera role runs there with generated photos only).

```sh
git clone https://github.com/RF-Nelson/open-source-selfie-stick.git
cd open-source-selfie-stick
open ShotCaller.xcodeproj      # select your team under Signing & Capabilities, then run on a device
```

The project file is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and committed, so you don't need XcodeGen unless you change `project.yml` (`brew install xcodegen && xcodegen generate`).

Tests live in the Swift package and run without a simulator:

```sh
cd Packages/ShotCallerCore && swift test
```

They also run from Xcode's test navigator (the shared scheme includes them).

To put a build on TestFlight for internal testers, run `Tools/testflight-upload.sh` (archives, signs and uploads; Xcode must be signed in to the developer account). Those internal-only builds cannot be submitted for App Review.

For a public-release candidate, `Tools/app-store-archive.sh` creates a signed archive and App Store IPA locally without uploading. Complete [docs/APP_STORE_RELEASE.md](docs/APP_STORE_RELEASE.md) before distribution. [Privacy policy](docs/PRIVACY.md) · [Support](docs/SUPPORT.md).

## Architecture

```
ShotCaller/                   the app (SwiftUI, iOS 18+)
├─ App/                       entry point, role picker, device naming
├─ Design/                    theme and shared controls (shutter, mode switch, pills, banners)
├─ Camera/                    CaptureService (AVFoundation actor), preview view, PhotoKit store, camera screen
└─ Remote/                    remote screen, code entry
Packages/ShotCallerCore/      everything that doesn't need a device — with tests
├─ Protocol/                  RemoteCommand / CameraEvent (Codable, versioned) and the JSON codec
├─ Pairing/                   pairing code, per-session challenge, HMAC proof
├─ Transport/                 PeerTransport protocol; LayeredTransport (default), BluetoothTransport + L2CAPStreamHandler, MultipeerTransport, WiFiAwareTransport, FakeTransport
├─ Camera/                    CameraDevice / MediaStore protocols, CameraHostModel (camera-side logic)
└─ Remote/                    RemoteModel (remote-side logic)
Tools/render-icon.swift       draws the app icon (light, dark, tinted)
```

- **Transport is a protocol.** Everything above the transport speaks `PeerTransport` and one `AsyncStream<TransportEvent>`. The default `LayeredTransport` composes a `BluetoothTransport` (Core Bluetooth over an L2CAP channel) with a `MultipeerTransport` Wi-Fi path it establishes over the Bluetooth link. `WiFiAwareTransport` (iOS 26) is an optional alternative; `FakeTransport` backs the tests. Only the concrete transports import their frameworks.
- **The wire protocol is typed.** Remote → camera is `RemoteCommand`; camera → remote is `CameraEvent`. The camera sends a full `CameraState` snapshot whenever anything changes, and the remote renders from it. Every message carries a protocol version; mismatched versions refuse to talk with a clear message on both screens.
- **Both role models are pure logic.** `CameraHostModel` and `RemoteModel` talk to a `PeerTransport`, a `CameraDevice` and a `MediaStore`; the app supplies AVFoundation, PhotoKit and Multipeer, the tests supply fakes. `EndToEndTests` drives a remote model against a camera model over two linked fake transports.
- **Pairing.** After a connection is established, the camera sends a random per-session challenge. The remote proves the code over the data channel using `HMAC-SHA256(key: SHA256(code), challenge + remoteName)`. The camera verifies before accepting commands, allows one remote at a time, and issues a new code after three wrong guesses. The code is intended to keep an ordinary nearby app user from controlling the camera; it is not designed to resist custom sniffing or attack tooling. Wi-Fi Aware instead relies on system-authorized pairing.
- **Files, delivered by channel.** Full-resolution photos are the original HEIF/JPEG (metadata intact); videos are HEVC `.mov`. Delivery is decoupled from intent: over Wi-Fi they send automatically; over Bluetooth they're held and sent on request (photos can be re-encoded smaller — Full / Reduced / Small — for a quicker Bluetooth transfer), with live progress and cancel on both ends, and they flush automatically when a Wi-Fi lane appears. The receiver saves to Photos with add-only permission. Measured throughput: ~1.5 MB/s over the Wi-Fi lane vs ~28 KB/s over Bluetooth L2CAP.

## Status

The earlier implementation was **verified on two physical devices (iPhone 17 Pro Max + iPad, iOS 26)** for:

- Bluetooth control with optional Wi-Fi file transfer, including recovery after Wi-Fi drops.
- Previews, deferred Bluetooth downloads, photo compression, progress/cancel, and automatic delivery when Wi-Fi returns.
- Code pairing, photo/video capture, countdown, flash, and front/back camera switching.

Implemented since that hardware check:

- First-use setup per role, optional saving preferences, clearer permission recovery, adaptive screen layouts, and capture previews that distinguish receipt from a successful save.
- Wi-Fi Aware pairing/discovery handoff, reuse of the system-selected endpoint, and single-peer connection handling.
- Capture/save recovery and transfer lifecycle fixes, with meaningful model and transport regression coverage in the core package.
- A backgrounded remote reconnects to its camera without re-pairing; a denied microphone records silent video with a notice.
- Privacy manifest, bundled policy, release-only diagnostic privacy, and separate App Store archive tooling.

These changes still require physical testing on supported phones/iPads, older supported OS versions, and Wi-Fi Aware-compatible devices. No App Store submission or approval is implied. See [docs/TODO.md](docs/TODO.md) and the [release acceptance matrix](docs/APP_STORE_RELEASE.md).

## History

Version 1.0 (2016) was written in Swift 2 against iOS 8 and shipped to the App Store as *Open Source Selfie Stick*. It no longer builds with any current Xcode and would crash on any current iPhone, so 2.0 started from an empty tree, keeping the product idea, the App Store listing and the lessons. The original is preserved at tag `v1.0-legacy`, and the original write-up on Multipeer Connectivity is still a good read: [tutorial](https://gist.github.com/RF-Nelson/8a3e6319b0607cf6b181ae4ee00f6c4c).

## License

[MPL 2.0](LICENSE).
