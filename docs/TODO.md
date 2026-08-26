# Pre-review TODO

Things to finish before submitting Pair & Shoot for App Store review. Keep this list current;
delete items as they land.

## Permissions & onboarding

- **First-run permission onboarding.** Right now the system permission prompts (Bluetooth, Camera,
  Microphone, Local Network, Photos) fire ad hoc — e.g. the Bluetooth prompt appears the first time a
  role opens the Bluetooth transport, which is surprising mid-task. Add a first-launch onboarding
  screen that explains the app will ask for these permissions and why, then triggers the prompts in
  sequence after the user taps OK. Goal: no unexplained popups; the user knows what's coming.
  _Reported 2026-08-26 during Bluetooth transport bring-up._
