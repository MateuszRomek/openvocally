# Idle health

An idle OpenVocally uses almost no CPU. A SwiftUI update loop can pin the main thread while nothing happens on screen, which drains the battery.

## Sub-features

- `idle-cpu` after launch work settles, the app averages 20% of one core or less over 10 s.

## How to get to it (user POV)

- Launch the app and leave it.

## Driving it with the scripts

Preconditions:

- None beyond the baseline.

- **Measure.** Run `make smoke-idle`. Exit code 0 and a line with the settle time and the measured percentage.
- **Proof.** Copy the script's last lines into the report; it writes no file.

## Gotchas

- Run it after any change to scenes, menus or `@Observable` state read by many views.
- "Never settled" after 60 s means launch work kept running. Check `scripts/show-logs.sh models 5m` before blaming SwiftUI.
