# Transcripts

Home shows recent dictations and charts. Transcripts lists every dictation with search and a detail pane. Both must stay fast with 50,000 saved dictations.

## Sub-features

- `transcripts-open` Home and Transcripts open within budget.
- `transcripts-scroll` the list scrolls without dropped frames as pages load.
- `transcripts-select` selecting a row opens the detail without moving the list.
- `transcripts-sidebar` the sidebar collapses and expands smoothly.
- `transcripts-width` the window's minimum width holds on every screen.

## How to get to it (user POV)

- Open the main window from the menu bar and choose **Home** or **Transcripts** in the sidebar.

## Driving it with the scripts

Preconditions:

- None beyond the baseline. The harness seeds its own `seed-N.sqlite` in the Debug data folder and never opens the real `openvocally.sqlite`.

- **Timings.** Run `scripts/latency/transcripts-latency.sh --scenario open` for a 5 to 15 s check, or `scripts/latency/transcripts-latency.sh` for the full 50,000-row run of about a minute. It prints n, median, p95 and max per measurement.
- **Screens.** Run `scripts/latency/transcripts-latency.sh --screenshots`. It captures Transcripts with nothing selected and with the first row selected, then runs the detail and minimum width checks.
- **Proof.** Results and screenshots go to `.build/transcripts-latency/`.

## Gotchas

- It builds an optimized Debug app into `.build/DerivedData-perf`, a separate build from the other scripts. The first run takes a few minutes.
- The run fails unless the seeded database is back to exactly N rows afterwards.
- A watchdog samples a stuck main thread into `.build/transcripts-latency/` and kills the app after 300 s.
