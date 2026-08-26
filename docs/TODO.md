# Roadmap & open decisions

What's left before (and around) an App Store submission. Keep this current; delete items as they land.

## Major milestone: Wi-Fi Aware (iOS 26)

The default transport is layered Bluetooth + Wi-Fi and is working on hardware. **Wi-Fi Aware is the
remaining transport milestone** — an experimental opt-in (`WiFiAwareTransport`, `TransportFactory`'s
`useWiFiAware` toggle) that isn't finished. Background and the earlier connection-lifetime fix are in
`docs/TRANSPORT.md`. Goal: a reliable iOS-26 system-pairing path that connects and transfers, then
decide whether it earns a place beside the layered default or stays an experiment.

## Pre-review

- **First-run permission onboarding.** The system prompts (Bluetooth, Camera, Microphone, Local
  Network, Photos) currently fire ad hoc — e.g. the Bluetooth prompt appears the first time a role
  opens the transport, which is surprising mid-task. Add a first-launch screen that explains what the
  app will ask for and why, then triggers the prompts in sequence after the user taps OK. No
  unexplained popups. _Reported 2026-08-26 during Bluetooth transport bring-up._
- iPad layout pass, localisation, manual exposure, a session gallery.

## Nice to have

- **Degraded-link detection.** Use measured throughput as a health signal: if the Wi-Fi fast lane is
  "up" but transferring at Bluetooth-like rates (congested/fringe AWDL), flag it or fall back
  deliberately. (The transport already knows which channel is active, so this is about *quality*, not
  *which* channel.)
- Allow the shutter during a quick Wi-Fi auto-download while still pausing it for a slow Bluetooth
  download (today it's paused for any in-flight download — acceptable per testing).

## Open decision: open source & license

Currently **[MPL-2.0](../LICENSE)**. Leaning toward keeping the project open source. License options:

- **Keep MPL-2.0** (weak, file-level copyleft). Modifications to the project's own files stay open;
  the code can still be combined with proprietary code. **App Store-safe.** Good default for "share
  it and keep improvements to the shared code open." _Recommended unless we specifically want maximum
  permissive adoption._
- **MIT / Apache-2.0** (permissive). Anyone can do anything, including proprietary forks, with no
  obligation to contribute back. Apache-2.0 adds an explicit patent grant. Best for maximum adoption.
- **Avoid GPL-family** for an App Store app — GPL's terms conflict with App Store distribution (this
  is the issue that got VLC pulled). Don't go here.

Decision pending. Since the repo is already MPL-2.0 and it's App Store-safe, "keep MPL-2.0" is the
low-friction choice; switch to Apache-2.0 only if broad permissive reuse is the goal.
