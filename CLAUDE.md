# Pair & Shoot — notes for Claude Code

iOS app (SwiftUI, Swift 6, iOS 18+) that makes one iPhone/iPad a remote control for another's camera over MultipeerConnectivity. Working title "Pair & Shoot"; bundle ID stays `com.richardnelson.opensourceselfiestick` (the 2016 App Store listing).

## Commands

- Generate the Xcode project (only after editing `project.yml`): `xcodegen generate`
- Build (no simulator boot — this Mac has little RAM; never `simctl boot`):
  `xcodebuild -project PairAndShoot.xcodeproj -scheme PairAndShoot -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
- Device build: same with `-sdk iphoneos -destination 'generic/platform=iOS'`
- Tests (fast, native macOS, no simulator): `cd Packages/PairAndShootCore && swift test`
- Icon: `swift Tools/render-icon.swift` (writes the three appearances into the asset catalog and `docs/icon.png`)

## Layout

- `Packages/PairAndShootCore` — all logic, no UI, no AVFoundation. Protocol (`Messages.swift`), pairing, `PeerTransport` + `MultipeerTransport` + `FakeTransport`, `CameraHostModel`, `RemoteModel`. Tests here.
- `PairAndShoot/` — the app. `Camera/CaptureService.swift` is the AVFoundation actor; `Camera/CameraScreen.swift` and `Remote/RemoteScreen.swift` are the two operating screens; `Design/` holds the theme and shared controls.
- `docs/DESIGN.md` — product, naming, visual system, screen behaviour.

## Conventions

- Swift 6 language mode, strict concurrency, no default main-actor isolation. Models are `@MainActor @Observable`; the capture service is an `actor`; anything crossing Multipeer/AVFoundation delegate boundaries converts to `Sendable` values at the boundary.
- New capabilities go through the protocol: add a `RemoteCommand`/`CameraEvent` case, handle it in `CameraHostModel.execute` and `RemoteModel`, add a test. Bump `WireProtocol.version` only for breaking changes.
- Local buttons on the camera screen call `model.perform(_:)` with the same commands a remote would send, so both paths stay identical.
- Both screens are always dark; the role picker follows the system appearance. Use the components in `Design/Components.swift` before inventing new ones.
- Don't add third-party dependencies.

## History

The 2016 Swift 2 app is preserved at tag `v1.0-legacy` and was assessed as not worth porting; nothing from it is meant to be copied line by line.
