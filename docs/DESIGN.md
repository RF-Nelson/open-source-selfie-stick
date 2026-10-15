# Shot Caller — design notes

## What the product is

One sentence: *a second iPhone or iPad as the remote control for another one's camera.*

The 2016 app was named for the joke (a "selfie stick" made of two phones) and the joke hid the product. Everything in 2.0 — the name, the first screen, the icon — is chosen to say what the app does before the user has to work it out.

Principles, in priority order:

1. **The remote is used at arm's length or across a room.** One giant control, glanceable state, no fine text.
2. **The camera screen is a viewfinder.** The picture is the content; chrome stays out of its way. Same conventions as the system Camera app so nothing needs learning.
3. **Nothing happens silently.** Every capture is acknowledged on both screens (preview thumbnail, "saved" banner, progress bar). Every refusal says why and what to do.
4. **Consent is visible.** The camera's owner shows a code; the remote's owner types it. No auto-accept, no "OK to connect?" dialogs after the fact.

## Name

**Shot Caller** — decided 16 September 2026, replacing *Pair & Shoot* (23 August 2026). Whoever holds the remote calls the shot from wherever they're standing, including inside the frame. *Pair & Shoot* named the setup steps (pair, then shoot) and read as a pun on "point and shoot", a kind of camera, so it never said what the app is for. *Shot Caller* is 11 characters (no truncation under the icon), says "shot", and puts the person in control of the camera rather than behind it.

Name check (16 September 2026, US App Store search): nothing in Photo & Video uses it. The near-matches are all in other categories: *ShotCaller Basketball* (Sports), *Shot Caller: Muay Thai Timer* (Health & Fitness), *Shotcallers* (Business) and *SHOTCALLER - Shot List Planner* (Productivity, the closest in spirit). The phrase also has a slang sense (a gang leader, and the 2017 film); the app leans on the everyday one, the person in charge.

Where the name lives: `CFBundleDisplayName` and the usage strings in `Info.plist`, the target / folder / module `ShotCaller`, the package `ShotCallerCore`, the role picker title and the remote's empty-state hint, the Bonjour / Multipeer / Wi-Fi Aware service type `shotcaller`, the pairing tag `Pairing.appTag`, the filename given to saved photos, and these docs. Because the service type and pairing tag changed, a build from before the rename can't pair with one after it. The bundle ID stays `com.richardnelson.opensourceselfiestick` so the 2016 App Store listing carries over; the App Store Connect record is renamed in App Store Connect itself (an unreleased rename needs no new build). The GitHub repository can keep its old name (GitHub redirects renamed repositories) or be renamed to `shot-caller` whenever convenient.

App Store metadata: title *Shot Caller*, subtitle *Remote shutter for two iPhones* (exactly 30 characters). Apple's own Watch app **Camera Remote** does this job with a Watch; the pitch here is the same idea with any second iPhone or iPad, plus video and copies sent back.

Considered and set aside: *Pair & Shoot* (the name from 23 August to 16 September 2026; described the setup, not the benefit), *In the Shot* (the runner-up; says the benefit plainly but not the control), *Long Arm* (nods to the 2016 selfie stick but doesn't say camera), *Get In!* (could be a ride app), *Snap Remote* (Snapchat association), *Second Shooter* (photographers' jargon that doesn't say "remote"), *Shutter Link* (bland), *Camera Clicker* (truncates under the icon), *Remote Shutter* (generic, several existing apps, and it collides with Apple's *Camera Remote*).

## Visual system

**Two moods, on purpose.** The operating screens (camera, remote) are always dark — black canvas, white controls, one accent — like every camera app, because the content is the picture and the screens are used in the dark as often as in daylight. The role picker and settings sheets are ordinary system-styled screens that follow light/dark mode; they are read, not operated.

**Colour**

| Token | Light | Dark | Used for |
|---|---|---|---|
| Accent (brand blue) | `#2E4BE8` | `#7E93FF` | Role picker glyphs, focus ring of the code entry, links |
| Record | `#F5453B` | same | Record button, recording badge — semantic, never decorative |
| Success | `#5CCC8C` | same | "Saved", connected pill |
| Canvas | — | `#000000` | Operating screens |
| Panel / raised | — | `#1C1C1C` / `#2B2B2B` | Cards, banners, toasts |
| Muted ink | — | white at 62 % | Secondary text on black |

The brand blue carries over from the 2016 wordmark (a royal blue) so the App Store listing keeps its identity, brightened for screens.

**Type.** System SF throughout — no bundled fonts. Numerals that matter (pairing code, countdown, recording clock) use the rounded design at large sizes with monospaced digits, so they read across a room and don't jitter as they change. Labels on capsule controls are uppercase caption text with 1.2 pt tracking, matching the system Camera app.

**Controls** (all in `Design/Components.swift`):

- `ShutterButton` — 88 pt on the camera, 124 pt on the remote. White for photo, red for record, red square while recording, an × while a countdown is running (tap to cancel), a spinner while a capture is in flight.
- `ControlButton` — 48 pt circular glass buttons (Liquid Glass on iOS 26, material below), with an optional yellow badge (timer seconds).
- `ModeSwitch` — PHOTO / VIDEO capsule, locked while recording.
- `StatusPill` — connection state; green when linked.
- `ChannelPill` — sits next to the link pill when connected: "Bluetooth" (control-only, slow file transfer) or "Wi-Fi" (the fast lane is up), reflecting how photos/videos travel on the current link.
- `CountdownOverlay` — 180 pt rounded numerals with a numeric content transition; shown on **both** devices, because the people in the shot are looking at the camera.
- `TransferBanner` — one component for both directions (sending / receiving / saving / saved / failed) so progress looks the same everywhere.
- `CaptureThumbnail` — the "you just shot this" acknowledgement; video gets a play badge and duration.

## Screens

**Role picker.** Two cards, each with a one-line consequence ("Set it down or hand it to a friend" vs "Keep it in your hand"). A three-step *How it works* beneath. Nothing else — the choice is the whole screen.

**Camera.** Until a remote is connected the screen is a **waiting room**, not a viewfinder: black canvas, the top row (close · link pill · settings) and one centred message. Automatic shows "Waiting for a remote", the 4-digit code in 64 pt numerals and the exact words to say to the other person. In Debug builds only, the internal Wi-Fi Aware test mode shows one big **Pair remote** button (Apple's pairing view) when nothing is paired yet, or "Waiting for your remote" plus a small *Pair a different remote* once something is; Release builds never show these. Showing the live preview and capture controls before anything is connected read as "ready to shoot" and confused people (decided 2026-10-10). The camera's own shutter delivers copies the way the remote's settings ask (the remote sends its preferences after pairing; 2026-10-15). The moment a remote connects the full-bleed preview appears: top row close · link pill (green, named) · settings; bottom: mode switch, local timer, shutter, last-capture thumbnail. Countdown numerals fill the screen. A recording badge with a clock sits top-centre. Permission denied replaces everything with the reason, an *Open Settings* button and a way back — never `exit(0)`.

**Remote — discovery.** A spinner and the instruction while nothing is found; then a list of cameras by name. Tapping one opens the code sheet: four boxes, number pad up immediately, auto-submits on the fourth digit.

**Remote — control deck.** From the top: camera name pill, a **channel pill** ("Bluetooth" or "Wi-Fi") showing how files travel, and settings; the stage; the transfer banner (live progress) when a file is moving; flash · timer · flip; the mode switch; the large shutter (dimmed and paused while a download runs). **The stage is the live view when the Wi-Fi lane is up** (decided 2026-10-11): the latest frame from the camera, aspect-fit, with a green *Live* pill, the countdown numerals and the recording clock drawn over it, and a *Paused* pill plus the reason when the camera is skipping frames (a download, heat) or a frame is late. Under it, a compact row keeps the last-shot thumbnail, the session count, the saved-here status and the **Download** / **Cancel** button, so the deferred-original workflow stays in reach while framing. Over Bluetooth alone the stage is the older one — the countdown, the recording clock, or a size-adaptive preview of the last capture with its status and the green **Download full photo/video** button (size and estimated seconds, Full / Reduced / Small, then a red **Cancel**) — with one footnote: "Live view and automatic photo delivery need a shared Wi-Fi network. Over Bluetooth you can still take photos and videos, and download each one when you want it." (reworded 2026-10-15 at Rich's request so the Bluetooth deferral is explained in the same breath). Settings sheets open at full height on iPad (a half sheet there only grew once scrolled). Live view has a switch in the remote's settings (on by default); the camera shows a **Sharing live view with <remote>** pill while frames flow (no Stop button, decided 2026-10-11: disconnecting the remote is the way to end it).

**Deferred delivery.** Delivery is decoupled from intent (see `docs/TRANSPORT.md`): the thumbnail is instant, full files come fast over Wi-Fi automatically, and over Bluetooth they're offered as a download and flush automatically when Wi-Fi returns — the UI adapts rather than making the user pick a mode.

**Settings sheets.** Camera: keep copies in Photos, issue a new code, nickname. Remote: send photos / send videos (with the honest note about Bluetooth), countdown length, nickname. Medium and large detents keep the settings readable at larger text sizes.

## Icon

A shutter button (ring and dot) with the signal arcs of a remote on either side — the two things the app is about, drawn as flat shapes that survive the 29 pt size. Brand-blue gradient in light mode; the same glyph in blue-tinted white on near-black for iOS 18's dark icons; a white-on-transparent version for the tinted style. Rendered by `Tools/render-icon.swift`, so it can be re-tuned in code and regenerated in a second.

## Accessibility

Every control has a label. The shutter's label changes with its meaning ("Take photo", "Stop recording", "Cancel countdown"). Numerals announce their meaning ("Pairing code 4 8 2 1", "3 seconds"). Dynamic Type applies to all text except the large numerals, which are sized for distance rather than reading. Hit targets are 48 pt or larger.

## Open questions

- Verify the adaptive two-column remote and compact camera layouts on physical iPads and large-text settings.
- Remote live view (built 2026-10-11, not yet verified on hardware): a silent composition preview over the Wi-Fi fast lane only, one frame per request, ≈480 px / 5 fps / ≤32 KiB per frame, paused for file delivery, loss of foreground demand or thermal pressure; Bluetooth shutter control and deferred full-resolution delivery stay independent of it. Remote focus and zoom are a separate follow-on. The frame is rotated the way a capture taken now would be and is not mirrored (the camera's own screen mirrors the front camera; the saved photo does not), so the remote predicts the saved composition.
- Manual controls (ISO, white balance) from the 2016 app: planned as sliders on the camera screen, not yet built.

## Release-readiness UX pass (September 2026)

First-use setup explains permissions after a role is selected. Saving copies is optional and remembered; Remote does not ask for Camera or Microphone. The home screen has no connection selection (removed 2026-10-10: Wi-Fi Aware is a Debug-only internal test mode, see TRANSPORT.md) and offers offline Privacy & Help. Wi-Fi Aware follows Apple's sample: pair in the system views, dismiss them, then the listener/browser own the service. The remote remembers which camera was chosen in the picker and connects by itself when the browser finds it; it never connects to a picker endpoint directly. Pairing again is offered as a small secondary action even when a device is remembered; **Done** closes a pairing view that stayed open (re-pairing an already paired device does not change the registry, so the camera cannot close it by itself).

Capture thumbnails open an in-app preview with explicit original-save status; the app does not use an undocumented Photos URL scheme. A video's thumbnail and preview are a single still frame, never playback (the app holds add-only Photos access and the remote may only have the thumbnail), so video thumbnails carry a play badge with the duration and the preview sheet says "still frame from your video, watch it in Photos" in its first line (decided 2026-10-10). Failed saves retain originals for retry during the session. Closing with unsaved originals warns before discarding them. Camera recording is finalized on background/close, and stopping a recording remains possible during file transfers. Backgrounding either device drops the link; a paired remote that returns to the foreground reconnects to the same camera with the code it already proved (up to three tries), and a camera that returns is rediscovered by its waiting remote, so a glance at another app never forces re-pairing. A denied microphone records video without sound and says so on the camera rather than refusing to record. Visual/VoiceOver verification on real devices remains part of release acceptance.
