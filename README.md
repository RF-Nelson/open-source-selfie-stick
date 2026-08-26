<div align="center">
<img src="docs/icon.png" width="128" alt="Pair &amp; Shoot icon"><br><br>

# Pair &amp; Shoot

**Turn a second iPhone or iPad into a remote control for another one's camera.**<br>
Controls work anywhere over Bluetooth — no Wi-Fi needed — and photos/video come back fast over Wi-Fi automatically when both devices can reach each other, or slowly over Bluetooth on demand when they can't.

<img src="https://img.shields.io/badge/platform-iOS%2018%2B-lightgrey.svg?style=flat" alt="iOS 18+"> <img src="https://img.shields.io/badge/swift-6-orange.svg?style=flat" alt="Swift 6"> <img src="https://img.shields.io/badge/license-MPL--2.0-lightgrey.svg?style=flat" alt="MPL 2.0">
</div>

> **Status:** version 2.0 is a from-scratch rebuild of the 2016 app *Open Source Selfie Stick* (kept at tag [`v1.0-legacy`](../../tree/v1.0-legacy)). The layered Bluetooth + Wi-Fi transport, pairing, capture and smart send-back are **working and verified on two physical devices (iOS 26)**. The remaining milestone is the iOS 26 **Wi-Fi Aware** path — see [Status](#status).

## What it does

- **Two roles.** Open the app on both devices. One becomes the **camera**, the other the **remote**.
- **Pairing with a code.** The camera shows a 4-digit code; the remote types it in. No other device nearby can drive your camera, and the link is encrypted.
- **Photos and video.** The remote switches modes, cycles the flash, flips between front and back cameras, starts a countdown the people in the shot can see on the camera's screen, takes the picture or starts and stops recording.
- **Copies where you want them, smartly delivered.** The camera keeps its own copies (switchable). The remote can ask for full-resolution photos back (default on) and videos (default off — they're big). Every capture sends a small preview to the remote instantly either way. When a Wi-Fi lane is up, full files arrive in a second or two automatically; when you're on Bluetooth only, they're held and offered as a download (with a size/time warning and Full / Reduced / Small choices), and they flush automatically the moment a Wi-Fi lane appears.
- **Modern camera.** HEIF photos at full sensor resolution, HEVC video with stabilization, horizon-level rotation handling, tap to focus, pinch to zoom, Camera Control / volume-button shutter on the camera device.

## How it works

1. Open Pair &amp; Shoot on both devices and choose **Camera** on one, **Remote** on the other.
2. On the remote, tap the camera in the list and enter the code on its screen.
3. Shoot. Controls work over Bluetooth with no Wi-Fi at all. Full-resolution photos come back in a second or two when both devices share a Wi-Fi path; otherwise the remote shows a **Download** button (Bluetooth is slower).

**The connection is layered and automatic.** Bluetooth is the always-on base — discovery, the 4-digit pairing, and controls work anywhere, even in Airplane Mode. When both devices can reach each other over Wi-Fi/AWDL, the app bootstraps a Wi-Fi "fast lane" over the Bluetooth link and uses it for file transfers; if that isn't available, files fall back to Bluetooth. There's no mode to pick — it detects reachability by trying. (This replaced a Multipeer-only design that couldn't connect off-network.) See [docs/TRANSPORT.md](docs/TRANSPORT.md).

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
├─ Transport/                 PeerTransport protocol; LayeredTransport (default), BluetoothTransport + L2CAPStreamHandler, MultipeerTransport, WiFiAwareTransport, FakeTransport
├─ Camera/                    CameraDevice / MediaStore protocols, CameraHostModel (camera-side logic)
└─ Remote/                    RemoteModel (remote-side logic)
Tools/render-icon.swift       draws the app icon (light, dark, tinted)
```

- **Transport is a protocol.** Everything above the transport speaks `PeerTransport` and one `AsyncStream<TransportEvent>`. The default `LayeredTransport` composes a `BluetoothTransport` (Core Bluetooth over an L2CAP channel) with a `MultipeerTransport` "fast lane" it bootstraps over the Bluetooth link; `WiFiAwareTransport` (iOS 26) is an experimental opt-in; `FakeTransport` backs the tests. Only the concrete transports import their frameworks.
- **The wire protocol is typed.** Remote → camera is `RemoteCommand`; camera → remote is `CameraEvent`. The camera sends a full `CameraState` snapshot whenever anything changes, and the remote renders from it. Every message carries a protocol version; mismatched versions refuse to talk with a clear message on both screens.
- **Both role models are pure logic.** `CameraHostModel` and `RemoteModel` talk to a `PeerTransport`, a `CameraDevice` and a `MediaStore`; the app supplies AVFoundation, PhotoKit and Multipeer, the tests supply fakes. `EndToEndTests` drives a remote model against a camera model over two linked fake transports.
- **Pairing.** The camera advertises a random per-session challenge. The remote's invitation carries `HMAC-SHA256(key: SHA256(code), challenge + remoteName)`. The camera verifies before accepting, allows one remote at a time, and issues a new code after three wrong guesses. The Multipeer session itself is encrypted. This keeps strangers with the app out; it is not designed to resist someone sniffing the local network with custom tooling.
- **Files, delivered by channel.** Full-resolution photos are the original HEIF/JPEG (metadata intact); videos are HEVC `.mov`. Delivery is decoupled from intent: over Wi-Fi they send automatically; over Bluetooth they're held and sent on request (photos can be re-encoded smaller — Full / Reduced / Small — for a quicker Bluetooth transfer), with live progress and cancel on both ends, and they flush automatically when a Wi-Fi lane appears. The receiver saves to Photos with add-only permission. Measured throughput: ~1.5 MB/s over the Wi-Fi lane vs ~28 KB/s over Bluetooth L2CAP.

## Status

Done and **verified on two physical devices (iPhone 17 Pro Max + iPad, iOS 26)**:

- **Layered transport** — Bluetooth control anywhere (works in Airplane Mode), with an automatic Wi-Fi fast lane for file transfer that self-heals after AWDL drops.
- **Smart send-back** — instant thumbnails; auto-fast over Wi-Fi; defer + on-demand download (with size/time warning, Full/Reduced/Small compression, live progress, cancel) over Bluetooth; auto-flush when a Wi-Fi lane returns; a capture is never stranded if the lane drops mid-send.
- Pairing, capture, photo/video, countdown, flash, front/back — all working on hardware.
- Core package: **53 tests** (codec, pairing, both models, deferral/download flows, end-to-end). App builds for iOS device + Simulator SDKs under Swift 6 strict concurrency.

Remaining milestones:

- **Wi-Fi Aware (iOS 26)** — the experimental opt-in transport isn't finished; getting it working is the next major piece. See [docs/TRANSPORT.md](docs/TRANSPORT.md).
- First-run **permission onboarding** so the system prompts aren't a surprise (see [docs/TODO.md](docs/TODO.md)).
- iPad layout pass, localisation, manual exposure, a session gallery.

See [docs/TODO.md](docs/TODO.md) for the pre-review checklist and open decisions (including licensing).

## History

Version 1.0 (2016) was written in Swift 2 against iOS 8 and shipped to the App Store as *Open Source Selfie Stick*. It no longer builds with any current Xcode and would crash on any current iPhone, so 2.0 started from an empty tree, keeping the product idea, the App Store listing and the lessons. The original is preserved at tag `v1.0-legacy`, and the original write-up on Multipeer Connectivity is still a good read: [tutorial](https://gist.github.com/RF-Nelson/8a3e6319b0607cf6b181ae4ee00f6c4c).

## License

[MPL 2.0](LICENSE).
