# App Store release checklist

Last reviewed: September 16, 2026. These checks prepare a submission; they do not guarantee acceptance. Physical-device verification and the App Store Connect account work below still need to be completed for the release candidate.

## Included in this codebase

- Contextual usage descriptions for Camera, Microphone, add-only Photos, Bluetooth, and Local Network.
- `ShotCaller/PrivacyInfo.xcprivacy`: no tracking or developer data collection; `CA92.1` for app-owned preferences; `C617.1` for metadata/size of temporary capture and transfer files inside the app container. The internal core package is statically linked into the app executable, covered by the app's manifest.
- A bundled, offline privacy policy in `docs/PRIVACY.md`, shown through **Privacy & Help**. Update that source when privacy behavior changes; it is copied into the app by `project.yml`.
- Release builds do not evaluate or write transport trace messages. Debug builds retain the existing local diagnostic workflow.
- No third-party SDKs, accounts, advertising, purchases, or server backend.

## Owner actions before submission

1. Publish `PRIVACY.md` and `SUPPORT.md` at stable, publicly accessible HTTPS URLs. A repository file URL is usable only once the file is actually available publicly. Verify both links while signed out and enter them in App Store Connect. The app currently offers the existing public GitHub issues page for support; confirm the maintainer will monitor it and add a private contact route if needed. Do not submit placeholder URLs or unmonitored contact details.
2. Complete the privacy questionnaire for the exact release binary. The current implementation supports **Data Not Collected**: captures go directly to the user's paired device, not to the developer or an SDK vendor. This is an assessment based on Apple's collection definition, not an automatic result of the manifest. Reassess if support uploads, analytics, or remote services are added.
3. Confirm the registered bundle ID is `com.richardnelson.opensourceselfiestick` on the existing listing and the distribution profile includes the Wi-Fi Aware Publish/Subscribe entitlement. Confirm the app name **Shot Caller**, developer contact, copyright, territories, pricing, updated age rating questionnaire, and any required trader-status information in the account. Keep the review contact private in App Store Connect.
4. Capture current, accurate iPhone and iPad screenshots of the real app. The store description must say that remote use needs two compatible devices; distinguish ordinary Bluetooth/Wi-Fi support from optional Wi-Fi Aware. Do not promise universal range, instant transfers, or hardware validation that hasn't happened.
5. Review export-compliance answers for the shipped binary. `ITSAppUsesNonExemptEncryption` is currently `NO`; the implementation uses Apple-provided Bluetooth, Multipeer, Network/Wi-Fi Aware, and CryptoKit APIs. Confirm that this accurately covers the release's cryptography and intended distribution.
6. Finish the physical-device matrix below. If optional Wi-Fi Aware is not reliable, resolve that before including it in the submitted binary. Labeling a broken feature “experimental” does not make the app ready for review.

Apple requires functional submission metadata, support contact access, and an accessible policy. See [App Review Guidelines 1.5, 2.1, 2.3, and 5.1.1](https://developer.apple.com/app-store/review/guidelines/). Privacy answers should follow [Apple's App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/); approved API reasons are documented in [NSPrivacyAccessedAPITypeReasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons).

## Build and validate

App Store uploads currently require Xcode 26 or later with the iOS/iPadOS 26 SDK or later; the app may still deploy to iOS 18. Check [Apple's current SDK requirements](https://developer.apple.com/news/upcoming-requirements/?id=04282026a) again when submitting.

```sh
xcodegen generate
cd Packages/ShotCallerCore && swift test
```

From the repository root, build both SDK targets without booting a simulator:

```sh
xcodebuild -project ShotCaller.xcodeproj -scheme ShotCaller -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ShotCaller.xcodeproj -scheme ShotCaller -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

These unsigned builds validate compilation, not distribution signing or actual radio/camera behavior. Archive a signed Release build with a unique build number, inspect its privacy report in Organizer, validate it, and inspect the resulting app bundle for `PrivacyInfo.xcprivacy` and `PRIVACY.md`. Confirm it contains the declared Wi-Fi Aware entitlement and that an upgraded install still opens normally.

Run `Tools/app-store-archive.sh` (or pass an unused numeric build number) to create a signed Release archive and exported App Store IPA under `build/`. It checks that the archive contains the policy and privacy manifest. Each run preserves previous artifacts in a new directory. The script can update signing profiles through Xcode but **does not upload or submit**. Inspect and validate the archive in Organizer, then upload when ready.

**The existing `Tools/testflight-upload.sh` is for internal testing only.** Its export options set `testFlightInternalTestingOnly` to true. That uploaded build cannot be submitted for App Review. The separate `Tools/ExportOptions-AppStore.plist` uses local export and disables that restriction. Do not accidentally reuse the internal-only export options for public distribution. See [Apple's build upload guide](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds) and [export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance).

## Physical-device acceptance matrix

Record device models, OS versions, app build, connection method, and the result for each run. Unit tests and SDK builds cannot validate DeviceDiscoveryUI, radios, entitlement provisioning, permission prompts, or real capture behavior.

| Scenario | Required result |
| --- | --- |
| Fresh install; each role | The explanation precedes relevant permission prompts; choosing Remote does not prompt for Camera or Microphone. |
| Deny Camera; return from Settings | Camera explains the problem and recovers after permission is granted. Remote remains usable. |
| Deny Photos or Microphone | The app clearly reports saving/audio limitations and preserves supported capture/control behavior. |
| Deny Bluetooth / Local Network | Useful recovery instructions; no endless spinner or crash; control/transfer fallback behaves as described. |
| Default transport, iOS 18 + current iOS | Pair, reject a wrong code, capture a photo/video, receive a copy, disconnect, reconnect. |
| Bluetooth only / Wi-Fi returns | Deferred download, size choice, progress, cancel, and automatic fast transfer work without duplicate saves. |
| Wi-Fi Aware, two compatible devices | System pair, connect, photo/video transfer, both role directions, cancel/retry, reconnect, then pair another peer. |
| Wi-Fi Aware state changes | Revoke a system pairing, leave/re-enter the role, toggle transport, background/foreground, and relaunch; no stale peer or crash loop. |
| Unsupported Wi-Fi Aware device / iOS 18 | Default transport works and unavailable Wi-Fi Aware cannot be enabled. |
| Permissions changed while backgrounded | Return to a clear usable state; no silent claim that an unsaved file reached Photos. |
| iPhone + iPad, portrait + landscape | Controls, sheets, shutter, notices, and policy remain readable with Larger Text and VoiceOver. |
| Release upgrade and clean install | Policy loads offline, support link opens, no `transport.log` is newly written, and old preferences don't trap startup. |

Apple lists supported Wi-Fi Aware hardware in the [framework documentation](https://developer.apple.com/documentation/WiFiAware); use the app's runtime support check instead of assuming support from the model name.

## Notes for App Review

Use the following notes after verifying the corresponding behavior in the submitted build:

> Shot Caller uses one nearby iPhone or iPad as a camera and a second as its remote. Install the submitted build on both devices (iOS/iPadOS 18 or later). No account, subscription, or purchase is required. Keep both apps open with Bluetooth and Wi-Fi enabled.
>
> Choose Camera on one device and Remote on the other. On the remote, select the camera and enter the four-digit code displayed on the camera. Grant Camera access on the camera device and add-only Photos access when saving copies. Microphone access adds sound to videos. Take a photo with the remote, then switch to video to start and stop recording. Bluetooth carries controls; a Wi-Fi path speeds up full-file delivery. The app also supports downloading a waiting file over Bluetooth.
>
> Optional Wi-Fi Aware uses Apple's system pairing on two supported devices running iOS/iPadOS 26 or later. Enable it in the Connection section of both home screens before choosing Camera and Remote. Open the camera's pairing control and use the remote's pairing control to choose it and confirm system pairing. This path does not use the app's four-digit code. Default Bluetooth/Wi-Fi remains available on other supported devices.
>
> Privacy & Help is accessible from the role picker and contains the full offline policy and support link. Camera captures and previews are exchanged directly with the paired remote. The app cannot browse existing Photos content and includes no accounts, analytics, advertising, or developer server.

Add the actual tested hardware/OS versions and private review contact in App Store Connect. Do not include personal pairing codes or test photos in public metadata.
