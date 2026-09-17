# Roadmap & open decisions

What's left before (and around) an App Store submission. Keep this current; delete items as they land.

## Release milestone: physical validation

**Where things stand (2026-09-17, master @ 719c0e9, pushed).** TestFlight internal build
`202609170310` contains Codex's release pass (478f384) plus the review fixes (719c0e9).
*Verified:* 78 core tests pass; device-SDK build succeeds; archive, export and upload succeeded.
*Not verified:* anything on hardware — no radio, permission-prompt, capture or layout behaviour from
either commit has run on a device. Record results against the matrix in
[APP_STORE_RELEASE.md](APP_STORE_RELEASE.md).

**Run order on the two devices (default Automatic connection first):**
1. Fresh install on both; pick roles; confirm the setup sheet precedes prompts and Remote never asks
   for Camera/Microphone.
2. Pair with the code (try one wrong code), take a photo, record a video, confirm copies arrive.
3. Wi-Fi off on one device: deferred photo → Download (each size), cancel mid-download, download
   again; Wi-Fi back on → pending files flush by themselves.
4. Background/return checks and the microphone check listed below.
5. Deny Photos on each role: shot is kept as "unsaved", retry after granting in Settings.
6. Close the camera mid-recording and with unsaved shots: warning, then the recording is saved.
7. iPad + landscape + Larger Text pass over both screens.
8. Only then Wi-Fi Aware (toggle on both home screens), if both devices support it.

**Decided, don't re-litigate:** `Trace` stays DEBUG-only (TestFlight builds write no
`transport.log`; use `Tools/device-debug.sh` for a cabled Debug install when something fails). The
"Open Photos" buttons stay removed in favour of the in-app preview. The shutter stays paused during
a download (see Nice to have).

The earlier default Bluetooth + Wi-Fi flow was verified on two physical devices running iOS 26.
The current changes need a new device acceptance run. Wi-Fi Aware's system-pairing-to-data handoff,
selected endpoint, and single-peer connection handling are implemented, with model/transport
regression coverage. This does not verify Apple's pairing UI or the radio path on real devices.
Test two compatible devices, reconnect, cancellation, a second pairing, both role directions,
permission changes, and photo/video delivery. See [TRANSPORT.md](TRANSPORT.md).

Also exercise on hardware: background the remote mid-session and return (it should reconnect to the
same camera without asking for the code); background the camera and return; cancel a Bluetooth
download (no "failed" banner on the camera, and the file can be requested again); record video with
Microphone denied (silent video plus a notice, not a refusal).

Wi-Fi Aware watch item: after a session ends the camera cancels its listener and the host model
immediately re-advertises, so a new listener task can start while the cancelled one is still
unwinding. If the device run shows a publish conflict there, make the new listener await the old one
(as `suspendForPairing` already does).

## Pre-review

- **Verify the first-use setup on devices.** Role-specific explanations and optional saving are
  implemented. Camera authorization is limited to the camera role; Microphone is requested for
  video; Photos uses add-only authorization. Exercise denied/restricted access and return from
  Settings, including failed-save recovery.
- **Verify layouts and accessibility.** Adaptive iPhone/iPad layouts and accessible controls are
  implemented; test portrait/landscape, Larger Text, and VoiceOver on hardware.
- **Complete release account work.** Publish policy/support URLs, confirm the support route and
  distribution entitlement, capture screenshots, and complete App Store Connect declarations.
  Use [APP_STORE_RELEASE.md](APP_STORE_RELEASE.md) for the exact acceptance matrix and review notes.
  The new App Store archive script exports locally; the existing TestFlight script remains internal-only.

## Nice to have

- **Degraded-link detection.** Use measured throughput as a health signal: if the Wi-Fi fast lane is
  "up" but transferring at Bluetooth-like rates (congested/fringe AWDL), flag it or fall back
  deliberately. (The transport already knows which channel is active, so this is about *quality*, not
  *which* channel.)
- Allow the shutter during a quick Wi-Fi auto-download while still pausing it for a slow Bluetooth
  download. Recording stop/countdown cancel must remain available during transfers.
- Localisation, manual exposure, and a session gallery.

## License

The repository remains under **[MPL-2.0](../LICENSE)**. This release preparation does not change the
license. Any relicensing is a separate owner decision; a license choice is not an App Store approval guarantee.
