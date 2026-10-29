# Overlay

While the user dictates, the dictation notch shows at the top edge of the display under the pointer. `notch.md` covers its scenes, appearances and live loop. This file covers what is about the panel rather than the scenes: showing over full-screen apps.

## Sub-features

- `overlay-full-screen` the notch shows over full-screen apps, also after another full-screen Space opened and closed while it was hidden.

## How to get to it (user POV)

- Dictate. The notch appears on the press.

## Driving it with the scripts

Preconditions:

- Screen Recording for the screenshots.

- **Every scene.** See `notch.md`.
- **During real dictation.** The dictation harness shows the real notch for each run, and LB-01 is measured when it first shows recording.
- **Full screen.** Run `.agents/skills/verify-openvocally/overlay-fullscreen.sh`. It closes a full-screen app while the notch is hidden, then shows the notch on another full-screen app's Space. It prints `PASS` (exit 0) when the log's check reads `unoccluded true` and `on active Space true`, `FAIL` (exit 1) when it doesn't, and `NOT REPRODUCED` (exit 2) when the full-screen sequence or the app didn't get ready, so the run proved nothing. Open `.build/overlay-fullscreen/shot.png`; it shows the notch over an empty full-screen window. Run it after any change to how `NotchHost` shows or hides its panels.
- **Motion.** Run `scripts/design/gallery-shots.sh motion` for the list of named animations. Judging motion needs a recording or the user's eye; a still proves only that the entries exist.

## Gotchas

- `run-debug.sh` returns once the app is open, and the lock goes with it. Keep a live loop inside `scripts/with-debug-app.sh` and quit the app with the cleanup script before the next check.
- The full-screen check takes over the main display for about 25 s. Warn the user before running it.
- The notch panels stay ordered in and hide at alpha 0. A panel ordered out while a full-screen Space closes loses every other full-screen Space until the app quits. On a full-screen Space, a check line with `unoccluded false` and `on active Space false` means a panel was ordered out somewhere.
