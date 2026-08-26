# Pair & Shoot — notes for Claude Code

iOS app (SwiftUI, Swift 6, iOS 18+) that makes one iPhone/iPad a remote control for another's camera. Named "Pair & Shoot" (decided 2026-08-23); bundle ID stays `com.richardnelson.opensourceselfiestick` (the 2016 App Store listing). Open source under MPL-2.0.

**Status (2026-08-26):** the default **layered transport** (Bluetooth control everywhere + an automatic Wi-Fi fast lane for files) and **smart send-back** (defer over Bluetooth, auto-fast over Wi-Fi, on-demand download with compression + cancel, auto-flush + re-offer on lane changes) are **working and verified on two physical devices (iOS 26)**. Remaining milestones: **Wi-Fi Aware** (iOS 26 opt-in, unfinished), permission onboarding, and the open-source license decision (leaning keep MPL-2.0). Roadmap in `docs/TODO.md`; transport design in `docs/TRANSPORT.md`.

## Commands

- Generate the Xcode project (only after editing `project.yml`): `xcodegen generate`
- Build (no simulator boot — this Mac has little RAM; never `simctl boot`):
  `xcodebuild -project PairAndShoot.xcodeproj -scheme PairAndShoot -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
- Device build: same with `-sdk iphoneos -destination 'generic/platform=iOS'`
- Tests (fast, native macOS, no simulator): `cd Packages/PairAndShootCore && swift test`
- TestFlight upload (archive + upload, internal testing only): `Tools/testflight-upload.sh` — Xcode must be signed in to richfnelson@gmail.com; the internal group "App Store Connect Users" gets Xcode builds automatically
- Icon: `swift Tools/render-icon.swift` (writes the three appearances into the asset catalog and `docs/icon.png`)

## Layout

- `Packages/PairAndShootCore` — all logic, no UI, no AVFoundation. Protocol (`Messages.swift`), pairing, `PeerTransport` and its implementations (`LayeredTransport` — the default: Bluetooth control + auto Wi-Fi fast lane; `BluetoothTransport` + `L2CAPStreamHandler`; `MultipeerTransport`; `WiFiAwareTransport`; `FakeTransport`), `CameraHostModel`, `RemoteModel`. Transport architecture in `docs/TRANSPORT.md`. Tests here.
- `PairAndShoot/` — the app. `Camera/CaptureService.swift` is the AVFoundation actor; `Camera/CameraScreen.swift` and `Remote/RemoteScreen.swift` are the two operating screens; `Design/` holds the theme and shared controls.
- `docs/DESIGN.md` — product, naming, visual system, screen behaviour.

## Conventions

- Swift 6 language mode, strict concurrency, no default main-actor isolation. Models are `@MainActor @Observable`; the capture service is an `actor`; anything crossing Multipeer/AVFoundation delegate boundaries converts to `Sendable` values at the boundary.
- New capabilities go through the protocol: add a `RemoteCommand`/`CameraEvent` case, handle it in `CameraHostModel.execute` and `RemoteModel`, add a test. Bump `WireProtocol.version` only for breaking changes.
- Transport is `PeerTransport` behind `TransportFactory`. The default is `LayeredTransport` (Bluetooth control + auto Wi-Fi fast lane); control/messages ride Bluetooth, files ride Wi-Fi when up. **Delivery is decoupled from intent:** the camera defers full files on Bluetooth (`CaptureResult.fileAvailable`), the remote requests them (`requestFile`/`cancelTransfer`), and they auto-flush when a fast lane appears. See `docs/TRANSPORT.md` before touching transport/send-back.
- Hardware debugging: the app writes `Documents/transport.log` (`Trace.log`); pull it with `xcrun devicectl device copy from ... --source Documents` (copy the **directory**, not the single file). Both phones can be USB-cabled for reliable install/log-pull; `idevicecrashreport -u <udid> -k <dir>` pulls crash `.ips` files. `idevicesyslog` is unreliable here.
- Local buttons on the camera screen call `model.perform(_:)` with the same commands a remote would send, so both paths stay identical.
- Both screens are always dark; the role picker follows the system appearance. Use the components in `Design/Components.swift` before inventing new ones.
- Don't add third-party dependencies.

## History

The 2016 Swift 2 app is preserved at tag `v1.0-legacy` and was assessed as not worth porting; nothing from it is meant to be copied line by line.
