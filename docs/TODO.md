# Roadmap & open decisions

What's left before (and around) an App Store submission. Keep this current; delete items as they land.

## Release milestone: physical validation

**Where things stand (2026-10-12).** TestFlight internal build `202610121205` (uploaded 2026-10-12 from
the uncommitted working tree) contains everything through the live view and its Codex review; the previous
build `202609170310` had Codex's release pass (478f384) plus the review fixes (719c0e9).
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
8. **Mixed pair** (iPhone + iPad), both directions: identical code flow, no connection choice visible
   (decided 2026-10-10: Wi-Fi Aware left the shipping app; Debug builds keep an "Internal test" switch).
9. Internal only, Debug builds, Wi-Fi Aware test mode on both phones. **2026-10-10:**
   Rich-camera/Davia-remote failed (remote stuck in `preparing`), Davia-camera/Rich-remote connected
   in 3 s on the same build. The flow was reworked (waiting room, browser-only endpoints, fuller
   trace); see TRANSPORT.md § device run of 2026-10-10. Next run: both role directions, and read the
   paired-device list each side logs at listener/browser start.

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

## Remote live view (built 2026-10-11; needs the hardware pass)

Designed with Codex on 2026-10-10 (`docs/reviews/2026-10-10-codex.md`, "Remote live view") and built the
next day, on top of the still-uncommitted 2026-10-10 work (Rich chose to build before that device run).
What exists: wire protocol v4 (`startPreview`/`stopPreview`, `previewStarted`/`previewRefused`/
`previewEnded`), a binary `PreviewPacket` on lane 2 of the Wi-Fi leg only (`PeerTransport.sendPreview`;
the layered transport throws rather than touching Bluetooth), a demand-driven loop (the remote keeps one
frame request in flight; the camera serves only the newest; late answers are discarded), ≈480 px / 5 fps /
≤32 KiB clamped by the camera, skips for a running file transfer and for heat (`.serious` skips,
`.critical` ends, `.fair` shrinks to 320 px), a 10 s lease on the camera, `AVCaptureVideoDataOutput` +
`PreviewFrameEncoder` (CIContext JPEG, rotation baked in, not mirrored) attached only while a subscription
exists, the remote's `LiveViewStage` with the capture row beneath, a Live view switch in the remote's
settings, and the camera's "Sharing live view with …" pill (no Stop button: Rich's call). Reviewed by Codex the same day
(14 findings; 12 accepted and fixed: connection rotation pinned to 0°, no timeout reissue + age
watchdog, hardware cost / movie-output yield, serial tap transitions, request ids, host-side encode
deadline, frame validation + off-main decode, heat before transfer, stage height cap, purpose
strings, two-leg transport tests, integral crop). 32 new core tests (114 total).

**Seen on hardware 2026-10-15 (iPhone 17 Pro Max camera, Debug build → iPad Pro 11" remote, TestFlight
`202610121205`, same Wi-Fi):** Bluetooth connected, the Wi-Fi fast lane came up 2 s later, the live view
started 1 s after that (480 px / 5 fps / 32 KiB accepted), and a photo went over Wi-Fi 15 s in; Rich
reports the preview working. An earlier attempt the same evening showed "Live view needs a shared Wi-Fi
network" because the fast lane had not come up (cause not captured: the iPhone ran the TestFlight build,
which logs nothing; Local Network permission or a first-connect race are the suspects). Also seen: after
backgrounding the camera, the remote took almost a minute to reconnect — the first retry opened a channel
to a still-suspended app over a stale Bluetooth link and rode out the 30 s attempt timer. Fixed 2026-10-15
(TRANSPORT.md § Self-healing: shed the stale link first, 8 s channel-open deadline, 15 s × 8 reconnect
attempts); TestFlight 202610151546. Expect the reconnect within a few seconds of the camera returning.

**Later the same evening:** orientation correct for both cameras; the live view held for ~5 minutes; after
backgrounding the camera and reconnecting, the fast lane never returned (camera advertised, iPad never
invited) — fixed by recreating the Multipeer browser and session (TRANSPORT.md § Self-healing), together with
the Bluetooth-only footnote now explaining deferred downloads too and iPad settings sheets opening at full
height; TestFlight build 202610151537. A third cause of the missing lane turned up on the re-run (the
remote invited with a stale `MCPeerID` instance) and was fixed; **verified 2026-10-15 19:58Z** with Debug
builds on iPhone + iPad (both logs kept): camera backgrounded 10 s, L2CAP back 1 s after its return, Wi-Fi
lane 2 s later, live view 1 s after that. TestFlight 202610151554 has everything.

**2026-10-15, later:** a video did not reach the iPad with videos on and Wi-Fi up; no send attempt was
logged. The camera's own shutter always recorded with send-back off, so if the recording was started at
the camera that explains it — fixed by syncing the remote's copy preferences to the camera
(`setSendBack`); capture/send decisions are now traced. Verified by Rich the same evening ("It worked"); TestFlight
202610151606 carries it.

**Submission readiness (2026-10-15, evening):** done through the ASC API and the agent browser — version
2.0 created (id 5f9e36e7-0436-4927-a878-858452f1b48e) with the name "Shot Caller: Camera Remote", subtitle,
categories, description, keywords, promotional text, what's new, copyright, support/marketing/privacy URLs
(GitHub Pages, live), the review note (two devices, six steps), review contact carried over with no demo
account, the age-rating questionnaire re-answered (4+), App Privacy published as Data Not Collected, and
the App Store build 202610151616 (commit c2f9da7, `Tools/app-store-archive.sh` then an upload export)
attached. **Still missing: screenshots** — 6.9" iPhone (1320×2868, native on the iPhone 17 Pro Max) and
13" iPad (2064×2752; the 11" iPad's 1668×2388 captures go through a compositor frame). No demo video
(Rich's call). **Do not submit yet:** two other apps are WAITING_FOR_REVIEW (Goatacorn Goes to Japan!,
Goatacorn 2.0); the ship-app-store cadence rule is one app in review at a time, and `asc.mjs submit`
refuses while the queue is busy.

**Hardware still to do, in this order** (rows also in APP_STORE_RELEASE.md): the other role direction
and iPhone↔iPhone; rotation and handedness for both
cameras in both orientations (if frames come out rotated the wrong way, the mapping is
`CaptureService.previewFrame`'s angle→orientation switch); shutter latency with live view on vs off;
Bluetooth-only shows the footnote and no frames; Wi-Fi drop mid-view then return; a download while viewing
(frames pause, resume); a 10-minute live view for heat and battery; countdown and recording drawn over the
frame; app switcher shows no frame. Open: JPEG vs H.264 energy (only if JPEG proves costly), a Bluetooth
"framing snapshot" tier, remote tap-to-focus/zoom.

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
