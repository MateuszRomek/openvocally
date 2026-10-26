# Notch

In Debug builds with `FEATURE_NOTCH`, dictation draws through a black notch at the top edge of the display under the pointer. It grows a strip beside the notch for connecting, starting, recording with a live meter, stopping, transcribing, pasting and complete, and drops a larger notice below it for manual paste and every failure.

## Sub-features

- `notch-scenes` each scene has its own look: hidden, connecting, starting, recording, stopping, transcribing, pasting, complete, manual paste and one notice per failure reason.
- `notch-appearance` light, dark and both Increase Contrast appearances.
- `notch-reduce-motion` the Reduce Motion variant crossfades instead of resizing and freezes the meter.
- `notch-displays` the notch follows the pointer to any display, with or without a hardware notch.

## How to get to it (user POV)

- Run a Debug build and dictate. The notch grows on the press, on the display under the pointer.

## Driving it with the scripts

Preconditions:

- Screen Recording for the screenshots.

- **Every scene, still.** Run `scripts/design/gallery-shots.sh notch notch-reduce-motion`. Open `.build/design-gallery/notch.png` and `notch-reduce-motion.png`. Each shows every scene at the simulated notch's size in the Light, Dark and both Increase Contrast columns. The window opens over the main display's visible area and shrinks to fit it.
- **The real panel on every display.** Run `.agents/skills/verify-openvocally/notch-shots.sh [variant ...]`. It opens the app once per variant (`default`, `light`, `dark`, `increase-contrast-light`, `increase-contrast-dark`, `reduce-motion`), walks every scene on every display and captures only the notch panel. Open each contact sheet it prints, `.build/notch-shots/<display>-<variant>.png`; the per-scene PNGs sit in `.build/notch-shots/<display>-<variant>/`. A display with a hardware notch is named `display<id>-notch`.
- **Launch arguments.** `-notchProbe <file>` shows one scene at a time from a file holding `<x> <y> <scene>`, with the pointer in global points. Scene names are those above, with failures as `failed-<reason>`, such as `failed-noSpeech`. It logs `notch probe shown <scene> display <id> window <n>` in category overlay-demo once the scene settles. `-notchAppearance aqua|darkAqua|highContrastAqua|highContrastDarkAqua` forces the panels' appearance. `-notchReduceMotion YES` forces the Reduce Motion variant.
- **Live loop.** Run `scripts/with-debug-app.sh env RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh -overlayDemo YES`, then `scripts/show-logs.sh overlay-demo 2m` and `.agents/skills/verify-openvocally/cleanup.sh`. To record one transition, add `-overlayDemoScenario paste` (starting 150 ms, shorter than the 300 ms connecting deadline, recording with the meter 2.5 s, transcribing 700 ms, pasting 200 ms, complete 650 ms, hidden 1.5 s) or `-overlayDemoScenario manualPaste` (starting, recording with the meter, transcribing 500 ms, manual paste for its full 10 s countdown, hidden 1.5 s). Without it the loop walks every state.

## Gotchas

- The notch exists only in Debug builds, behind the compile-time flag `FEATURE_NOTCH`. Release builds draw the overlay instead.
- A display without a hardware notch draws a simulated 185 by 32 point notch on its top edge, and nothing while hidden, so the `hidden` row of a contact sheet has no capture.
- A built-in display has a notch only while the lid is open. With the lid closed, only the gallery's simulated geometry shows the hardware case.
- `starting` turns into `connecting` after 300 ms, so the probe captures it early, and it can still be mid-fade.
- Stills prove each scene's look only. Judging motion needs a recording or the user's eye.
