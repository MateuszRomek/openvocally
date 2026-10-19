# Overlay

While the user dictates, a small overlay shows at the notch or as an island at the top or bottom edge. It shows starting, recording with a level meter, transcribing, pasting, complete, and alerts such as a Bluetooth mic connecting.

## Sub-features

- `overlay-states` each dictation phase has its own look.
- `overlay-style` notch or island.
- `overlay-placement` island at the top or the bottom edge.
- `overlay-motion` the overlay expands, swaps content, collapses and hides.

## How to get to it (user POV)

- Dictate. The overlay appears on the press.
- Choose the style and placement in Settings or in the onboarding overlay step.

## Driving it with the scripts

Preconditions:

- Screen Recording for the screenshots.

- **Every state, still.** Run `scripts/design/gallery-shots.sh overlay`. Open `.build/design-gallery/overlay.png`. It shows each overlay state in light, dark and both Increase Contrast columns.
- **Live loop.** Run `scripts/with-debug-app.sh env RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh -overlayDemo YES -overlayStyle island -overlayPlacement islandTop`. The overlay loops through every state. Run `scripts/show-logs.sh overlay-demo 2m`; it prints one line per state, such as `recording with meter`. Then run `.agents/skills/verify-openvocally/cleanup.sh`.
- **During real dictation.** The dictation harness shows the real overlay for each run, and LB-01 is measured when it first shows recording.
- **Motion.** Run `scripts/design/gallery-shots.sh motion` for the list of named animations. Judging motion needs a recording or the user's eye; a still proves only that the entries exist.

## Gotchas

- `run-debug.sh` returns once the app is open, and the lock goes with it. Keep the live loop inside `scripts/with-debug-app.sh` and quit the app with the cleanup script before the next check.
- On a Mac without a notch, the notch style falls back to the top island.
