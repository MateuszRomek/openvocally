# Overlay

While the user dictates, a small overlay shows at the notch or as an island at the top or bottom edge. It shows starting, recording with a level meter, transcribing, pasting, complete, and alerts such as a Bluetooth mic connecting.

## Sub-features

- `overlay-states` each dictation phase has its own look.
- `overlay-style` notch or island.
- `overlay-placement` island at the top or the bottom edge.
- `overlay-motion` the overlay expands, swaps content, collapses and hides.
- `overlay-full-screen` the overlay shows over full-screen apps, also after another full-screen Space opened and closed while it was hidden.

## How to get to it (user POV)

- Dictate. The overlay appears on the press.
- Choose the style and placement in Settings or in the onboarding overlay step.

## Driving it with the scripts

Preconditions:

- Screen Recording for the screenshots.

- **Every state, still.** Run `scripts/design/gallery-shots.sh overlay`. Open `.build/design-gallery/overlay.png`. It shows each overlay state in light, dark and both Increase Contrast columns.
- **Live loop.** Run `scripts/with-debug-app.sh env RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh -overlayDemo YES -overlayStyle island -overlayPlacement islandTop`. The overlay loops through every state. Run `scripts/show-logs.sh overlay-demo 2m`; it prints one line per state, such as `recording with meter`. Then run `.agents/skills/verify-openvocally/cleanup.sh`.
- **During real dictation.** The dictation harness shows the real overlay for each run, and LB-01 is measured when it first shows recording.
- **Full screen.** Run `.agents/skills/verify-openvocally/overlay-fullscreen.sh`. It closes a full-screen app while the overlay is hidden, then shows the overlay on another full-screen app's Space. It prints `PASS` (exit 0) when the log's check reads `unoccluded true` and `on active Space true`, `FAIL` (exit 1) when it doesn't, and `NOT REPRODUCED` (exit 2) when the full-screen sequence or the app didn't get ready, so the run proved nothing. Open `.build/overlay-fullscreen/shot.png`; it shows the overlay over an empty full-screen window. Run it after any change to how `OverlayHost` shows or hides its panels.
- **Motion.** Run `scripts/design/gallery-shots.sh motion` for the list of named animations. Judging motion needs a recording or the user's eye; a still proves only that the entries exist.

## Gotchas

- `run-debug.sh` returns once the app is open, and the lock goes with it. Keep the live loop inside `scripts/with-debug-app.sh` and quit the app with the cleanup script before the next check.
- On a Mac without a notch, the notch style falls back to the top island.
- The full-screen check takes over the main display for about 25 s. Warn the user before running it.
- The overlay panels stay ordered in and hide at alpha 0. A panel ordered out while a full-screen Space closes loses every other full-screen Space until the app quits. On a full-screen Space, a check line with `unoccluded false` and `on active Space false` means a panel was ordered out somewhere.
