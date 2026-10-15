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
3. Confirm the registered bundle ID is `com.richardnelson.opensourceselfiestick` on the existing listing. The Release build signs with an empty entitlements file (`Config/ShotCaller-Release.entitlements`); the App ID may keep the Wi-Fi Aware capability for Debug builds, but the distribution profile must not be required to carry it. Confirm the app name **Shot Caller**, developer contact, copyright, territories, pricing, updated age rating questionnaire, and any required trader-status information in the account. Keep the review contact private in App Store Connect.
4. Capture current, accurate iPhone and iPad screenshots of the real app. The store description must say that remote use needs two compatible devices. Do not mention Wi-Fi Aware: the shipping build has no such option (decided 2026-10-10, see TRANSPORT.md). Do not promise universal range, instant transfers, or hardware validation that hasn't happened.
5. Review export-compliance answers for the shipped binary. `ITSAppUsesNonExemptEncryption` is currently `NO`; the implementation uses Apple-provided Bluetooth, Multipeer, Network/Wi-Fi Aware, and CryptoKit APIs. Confirm that this accurately covers the release's cryptography and intended distribution.
6. Finish the physical-device matrix below. Wi-Fi Aware is not in the submitted binary's behaviour (Debug-only test mode); the entitlement and `WiFiAwareServices` key remain declared for the internal builds, which is harmless to review but should be stated in the notes if asked.

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

These unsigned builds validate compilation, not distribution signing or actual radio/camera behavior. Archive a signed Release build with a unique build number, inspect its privacy report in Organizer, validate it, and inspect the resulting app bundle for `PrivacyInfo.xcprivacy` and `PRIVACY.md`. Confirm it contains **no** Wi-Fi Aware entitlement and no `WiFiAwareServices` key (`Tools/app-store-archive.sh` asserts both), and that an upgraded install still opens normally.

Run `Tools/app-store-archive.sh` (or pass an unused numeric build number) to create a signed Release archive and exported App Store IPA under `build/`. It checks that the archive contains the policy and privacy manifest. Each run preserves previous artifacts in a new directory. The script can update signing profiles through Xcode but **does not upload or submit**. Inspect and validate the archive in Organizer, then upload when ready.

**The existing `Tools/testflight-upload.sh` is for internal testing only.** Its export options set `testFlightInternalTestingOnly` to true. That uploaded build cannot be submitted for App Review. The separate `Tools/ExportOptions-AppStore.plist` uses local export and disables that restriction. Do not accidentally reuse the internal-only export options for public distribution. See [Apple's build upload guide](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds) and [export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance).

## Physical-device acceptance matrix

Record device models, OS versions, app build, connection method, and the result for each run. Unit tests and SDK builds cannot validate DeviceDiscoveryUI, radios, entitlement provisioning, permission prompts, or real capture behavior.

| Scenario | Required result |
| --- | --- |
| Fresh install; each role | The explanation precedes relevant permission prompts; choosing Remote does not prompt for Camera or Microphone. |
| Deny Camera; return from Settings | Camera explains the problem and recovers after permission is granted. Remote remains usable. |
| Deny Photos or Microphone | The app clearly reports saving/audio limitations and preserves supported capture/control behavior. With Microphone denied, video records without sound and the camera shows a notice. |
| Background the remote, then the camera, mid-session | The link drops; on return the remote reconnects to the same camera without asking for the code. A recording in progress is finished and saved first. |
| Deny Bluetooth / Local Network | Useful recovery instructions; no endless spinner or crash; control/transfer fallback behaves as described. |
| Default transport, iOS 18 + current iOS | Pair, reject a wrong code, capture a photo/video, receive a copy, disconnect, reconnect. |
| Bluetooth only / Wi-Fi returns | Deferred download, size choice, progress, cancel, and automatic fast transfer work without duplicate saves. |
| Mixed pair: iPhone + iPad (no Wi-Fi Aware hardware), both directions | Identical Bluetooth/code flow; no connection choice anywhere; existing Wi-Fi Aware system pairings on the iPhones cause no sheet or listener activity. |
| Release build inspection | No connection toggle, no "Internal test" strings, and `TransportFactory.make` has no Wi-Fi Aware branch (it is `#if DEBUG`). |
| Internal only (Debug builds): Wi-Fi Aware test mode | System pair, connect, transfer, both directions, idle 3+ min, reconnect. Results do not substitute for the shipping matrix. |
| Permissions changed while backgrounded | Return to a clear usable state; no silent claim that an unsaved file reached Photos. |
| Live view on a shared Wi-Fi network, both role directions, iPhone↔iPhone and iPhone↔iPad | First frame within a few seconds of the Wi-Fi pill turning green; steady ≈5 fps; countdown numerals and the recording clock draw over the frame; the camera shows "Sharing live view with …"; disconnecting the remote from the camera ends the view. |
| Live view orientation | Back and front cameras, portrait and landscape on both devices: the frame is upright, handedness matches the saved photo (not the camera's mirrored selfie preview), and nothing is double-rotated. |
| Live view vs. control latency | Shutter, cancel-countdown and stop-recording feel no slower with live view on than off; a download pauses the view ("Live view paused while downloading.") and it resumes by itself. |
| Live view over Bluetooth only, and Wi-Fi drop/return | No frames and the footnote "Live view and automatic photo delivery need a shared Wi-Fi network…" over Bluetooth; a mid-view Wi-Fi drop clears the frame with that footnote; the view returns when the lane does. |
| Live view, 10 minutes | No thermal warning on the camera, no runaway battery drain; the app switcher shows no frame; Live view off in settings stops the camera's frame tap. |
| iPhone + iPad, portrait + landscape | Controls, sheets, shutter, notices, and policy remain readable with Larger Text and VoiceOver. |
| Release upgrade and clean install | Policy loads offline, support link opens, no `transport.log` is newly written, and old preferences don't trap startup. |

Apple lists supported Wi-Fi Aware hardware in the [framework documentation](https://developer.apple.com/documentation/WiFiAware); use the app's runtime support check instead of assuming support from the model name.

## Notes for App Review

The note below goes in the **Notes** field of the version's App Review Information, and stays there on
every build (release notes go in the release-notes field; see the ship-app-store runbook on why the
note is never overwritten). Paste it verbatim after confirming each step against the submitted build:

> **This app needs two devices to review.** Shot Caller turns one iPhone or iPad into a camera and a second iPhone or iPad into its remote control. One device alone can show the setup screens, the role picker and Privacy & Help, but cannot take a picture: the camera deliberately keeps its viewfinder and shutter hidden until a remote is connected, so a single-device review will see a "Waiting for a remote" screen with a four-digit code and nothing else. Please install the build on two devices running iOS or iPadOS 18 or later (an iPhone and an iPad are fine), with Bluetooth on and both on the same Wi-Fi network.
>
> **Steps, in order (about three minutes):**
> 1. On device A, open Shot Caller and choose **Camera**. Allow Camera access when asked (the explanation screen comes first). Device A now shows a four-digit code.
> 2. On device B, open Shot Caller and choose **Remote**. Allow Bluetooth when asked; it never asks for Camera or Microphone. Device A's name appears in the list within a few seconds. Tap it and type the four digits shown on device A.
> 3. Device A's viewfinder appears. On device B, the remote shows the camera's name, a channel pill ("Wi-Fi" when both devices share a Wi-Fi network, otherwise "Bluetooth"), a live view of what the camera sees (Wi-Fi only), the flash, timer and camera-switch buttons, a Photo/Video switch and the shutter.
> 4. Tap the shutter on device B: device A takes the photo, a thumbnail appears on device B within a second or two and, over Wi-Fi, the full-resolution photo is saved to device B's Photos (device B asks for add-only Photos access the first time). Over Bluetooth alone the photo is held on the camera and device B offers a **Download** button with a size and time estimate instead.
> 5. Switch to **Video** on device B, tap the shutter to start recording (device A asks for Microphone access the first time; if denied, video records without sound and says so), tap again to stop. The clip is saved on device A and, if "Videos" is on in device B's settings, sent to device B the same way as a photo.
> 6. Optional: set a 3 or 10 second timer on device B; the countdown shows on device A's screen. Tap the gear on device B for the copy settings and the Live view switch. Device A's settings cover whether it keeps its own copies.
>
> **What the app is and is not.** Shot Caller is a camera remote, open source (MPL-2.0) and a rewrite of "Open Source Selfie Stick" from 2016 on this same listing. It is free, with no in-app purchases, subscriptions, ads, accounts or analytics, and it makes no network requests to any server: controls travel over Bluetooth (Core Bluetooth, an L2CAP channel) and, when both devices share a Wi-Fi network, photos, videos and the live view travel directly between the two devices over a peer-to-peer link (Multipeer Connectivity). Nothing leaves the two devices; the App Privacy answer is Data Not Collected. Local Network access is requested only for that direct link. The live view is small frames sent on request to the paired remote only, never stored; the camera device shows "Sharing live view with …" while it is on. It is a universal app with full VoiceOver labels; every control is a plain button, nothing is gesture-only.
>
> Privacy & Help on the first screen contains the complete offline privacy policy and the support link.

No demo video is attached (decided 2026-10-15): the note's steps are the demonstration. Add the tested
hardware/OS versions and build number in the review information, and keep the review contact private in
App Store Connect. No personal pairing codes or test photos in public metadata.

**TestFlight "What to Test" note for builds from 2026-10-15 on:**

> Update both devices before testing. Connection is Bluetooth, with faster photo and video delivery and a live view on the remote when both devices share a Wi-Fi network. Try: pairing with the code, a photo and a video from the remote and from the camera's own shutter, backgrounding the camera and coming back (it should reconnect within seconds), and the live view in portrait and landscape with both cameras.
