# Pair & Shoot — design notes

## What the product is

One sentence: *a second iPhone or iPad as the remote control for another one's camera.*

The 2016 app was named for the joke (a "selfie stick" made of two phones) and the joke hid the product. Everything in 2.0 — the name, the first screen, the icon — is chosen to say what the app does before the user has to work it out.

Principles, in priority order:

1. **The remote is used at arm's length or across a room.** One giant control, glanceable state, no fine text.
2. **The camera screen is a viewfinder.** The picture is the content; chrome stays out of its way. Same conventions as the system Camera app so nothing needs learning.
3. **Nothing happens silently.** Every capture is acknowledged on both screens (preview thumbnail, "saved" banner, progress bar). Every refusal says why and what to do.
4. **Consent is visible.** The camera's owner shows a code; the remote's owner types it. No auto-accept, no "OK to connect?" dialogs after the fact.

## Name

Working title: **Pair & Shoot** — a riff on *point and shoot* that literally describes the flow (pair the two devices, then shoot). It's short enough not to truncate under the icon, says "camera", and implies "two devices".

Ranked alternatives, all of which explain the product better than the old name:

| Name | For | Against |
|---|---|---|
| **Pair & Shoot** | Says pair + camera; memorable; fits under the icon | Pun may feel cute to some |
| **Snap Remote** | Literal; brandable as one word | "Snap" evokes Snapchat |
| **Second Shooter** | Photographers' term for an assistant; warm | Non-photographers may not get "remote" |
| **Shutter Link** | Literal, technical | Bland |
| **Camera Clicker** | Plain-language remote metaphor | Truncates under the icon at 14 characters |
| **Remote Shutter** | Most literal | Generic, several existing apps, and Apple's own Watch app is *Camera Remote* |

App Store metadata can carry the explanation regardless of the name: title (30 characters) plus subtitle (30 characters), e.g. *Pair & Shoot* / *Remote shutter for two iPhones*. Note that Apple's Watch app **Camera Remote** does exactly this with a Watch; this app's pitch is the same idea with a second iPhone or iPad, plus video and copies sent back.

Renaming later costs: the target/folder name in `project.yml` and on disk, `CFBundleDisplayName` in `Info.plist`, the string in `RolePickerView`, and `docs/`. The bundle ID and the Bonjour service type can stay.

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
- `CountdownOverlay` — 180 pt rounded numerals with a numeric content transition; shown on **both** devices, because the people in the shot are looking at the camera.
- `TransferBanner` — one component for both directions (sending / receiving / saving / saved / failed) so progress looks the same everywhere.
- `CaptureThumbnail` — the "you just shot this" acknowledgement; video gets a play badge and duration.

## Screens

**Role picker.** Two cards, each with a one-line consequence ("Set it down or hand it to a friend" vs "Keep it in your hand"). A three-step *How it works* beneath. Nothing else — the choice is the whole screen.

**Camera.** Full-bleed preview. Top row: close · link pill · flash · flip · settings. Bottom: mode switch, local timer, shutter, last-capture thumbnail. While no remote is linked, a translucent card floats above the bottom bar with the 4-digit code in 48 pt numerals and the exact words to say to the other person. The card disappears the moment a remote connects; the pill turns green and names the remote. Countdown numerals fill the screen. A recording badge with a clock sits top-centre. Permission denied replaces everything with the reason, an *Open Settings* button and a way back — never `exit(0)`.

**Remote — discovery.** A spinner and the instruction while nothing is found; then a list of cameras by name. Tapping one opens the code sheet: four boxes, number pad up immediately, auto-submits on the fourth digit.

**Remote — control deck.** From the top: camera name pill and settings; a stage that shows the countdown, the recording clock, or the last capture (200 pt) with a session count; the transfer banner when a file is moving; flash · timer · flip; the mode switch; the 124 pt shutter; one line of plain text saying where the next capture will end up ("Photos come back to this device", "Videos stay on the camera").

**Settings sheets.** Camera: keep copies in Photos, issue a new code, nickname. Remote: send photos / send videos (with the honest note about Bluetooth), countdown length, nickname. Medium detents — they're quick toggles, not destinations.

## Icon

A shutter button (ring and dot) with the signal arcs of a remote on either side — the two things the app is about, drawn as flat shapes that survive the 29 pt size. Brand-blue gradient in light mode; the same glyph in blue-tinted white on near-black for iOS 18's dark icons; a white-on-transparent version for the tinted style. Rendered by `Tools/render-icon.swift`, so it can be re-tuned in code and regenerated in a second.

## Accessibility

Every control has a label. The shutter's label changes with its meaning ("Take photo", "Stop recording", "Cancel countdown"). Numerals announce their meaning ("Pairing code 4 8 2 1", "3 seconds"). Dynamic Type applies to all text except the large numerals, which are sized for distance rather than reading. Hit targets are 48 pt or larger.

## Open questions

- Final name (see above).
- iPad: layouts work but nothing is tailored; the remote deck would suit a two-column layout in landscape.
- Live preview on the remote: needs a frame stream (`MCSession.startStream`) or a different transport; explicitly out of scope for 2.0.
- Manual controls (ISO, white balance) from the 2016 app: planned as sliders on the camera screen, not yet built.
