# Roadmap & open decisions

What's left before (and around) an App Store submission. Keep this current; delete items as they land.

## Release milestone: physical validation

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
