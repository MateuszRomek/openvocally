---
name: verify-openvocally
description: Drive the real OpenVocally macOS Debug app and capture proof without a human. Covers dictation (WAV fixture as the microphone, real model, overlay, LB-01 and LB-02), the overlay, Transcripts, onboarding, the Design Gallery and idle CPU. Use it to prove a change works on the running app, before saying a UI or dictation change is done, or when a PR asks for latency numbers or screenshots.
---

# Verify OpenVocally

OpenVocally is a SwiftUI menu bar and window app for macOS 26 on Apple Silicon. Every check here runs the Debug build at `.build/DerivedData/Build/Products/Debug/OpenVocally.app` (bundle ID `com.openvocally.app.debug`). The scripts post no clicks or keys and never take focus. The user may be working on the same Mac, so never drive the app with synthetic input.

There is one Debug app per checkout. All its builds share the bundle ID, preferences and Application Support folder, so two scripts cannot drive it at once. Every launch script holds `.build/debug-app.lock` through `scripts/with-debug-app.sh` and waits up to 900 s for the previous holder. Don't launch the app outside these scripts while another one runs.

## Doctor

Run this first, and again whenever a script fails in a way you don't understand:

```
.agents/skills/verify-openvocally/doctor.sh
```

It is read-only. It prints whether the build exists and is current, the version, running Debug copies, the lock holder, the signing identity, the installed speech models and whether this terminal has Screen Recording. It exits 1 when the app is not built or another script holds the lock.

- `signing: -` means the app is ad-hoc signed. macOS may then ask for Microphone and Accessibility again after each build. The harnesses below need neither, so they still run.
- `models: none` blocks the dictation harness. Ask the user to install a model in the app; don't download one yourself.
- `screen recording: not granted` makes the screenshot scripts capture blank windows. Only the user can grant it.

## Launch

Each script builds the app, launches it in the background with the arguments its scenario needs, waits for it, and quits it at the end. You don't start the app separately.

| Goal | Command | Ready when |
| --- | --- | --- |
| Dictation end to end | `make dictation-harness` or `scripts/latency/dictation-harness.sh --runs 3` | `results.jsonl` ends with a `"summary":true` line |
| Screens of one feature | `make gallery-shots`, `make onboarding-shots`, `scripts/latency/transcripts-latency.sh --screenshots` | the script prints each PNG path |
| Idle health | `make smoke-idle` | the script prints the settle time and the CPU percentage |
| Diagnostics export | `make diagnostics-export` | the script prints `PASS`, the log scope line and the build time |
| A manual look | `RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh <app arguments>` | `scripts/show-logs.sh app 2m` shows the launch |

`scripts/run-debug.sh` alone does not hold the lock after it returns. Wrap a manual session in `scripts/with-debug-app.sh <command>` when other agents may run checks.

## Drive

The app has no automation API. It is driven by launch arguments, read in the Debug build only:

- `-dictationHarness <scenario.json> -harnessOutput <path> -dataFolder <dir>` runs the dictation pipeline on WAV fixtures. `scripts/latency/dictation-harness.sh` writes the scenario.
- `-designGallery YES -designGallerySection <section>` opens the Design Gallery on one section.
- `-onboarding YES -onboardingStep <step>` opens onboarding on one step. `-modelFolder <dir>` swaps in an empty model folder.
- `-overlayDemo YES -overlayStyle notch|island -overlayPlacement islandTop|islandBottom` loops the overlay through every state.
- `-diagnosticsExport <path>` writes the diagnostics file and quits. `-diagnosticsSecret <text>` first logs the text with default privacy, so the script can check the file leaves it out. `-diagnosticsSettings YES` shows Settings scrolled to the Support section without activating the app.
- `-transcriptsHarness YES -seedTranscripts <rows> -harnessOutput <path>` seeds and times Transcripts. `scripts/latency/transcripts-latency.sh` builds it optimized and passes the rest.

Each feature file under `features/` gives the exact commands. `features/README.md` is the index.

## Evidence

Every script writes its proof under `.build`, and the proof outlives cleanup:

| Script | Evidence |
| --- | --- |
| `dictation-harness.sh` | `.build/dictation-harness/<timestamp>/` (one folder per model with `--model`) with `scenario.json`, `results.jsonl` (text, word error rate and timings per run) and `latency.txt` (LB-01 and LB-02 from the unified log) |
| `gallery-shots.sh` | `.build/design-gallery/<section>.png` |
| `onboarding/shots.sh` | `.build/onboarding-shots/<step>.png` |
| `transcripts-latency.sh` | `.build/transcripts-latency/` |
| `diagnostics-export.sh` | `.build/diagnostics-export/diagnostics.txt` |
| `smoke-idle.sh` | its output only, so copy the last lines into your report |

Read the app's own log with `scripts/show-logs.sh <category> [duration]`. Categories are app, capture, dictation-harness, hotkeys, latency, models, overlay, overlay-demo, paste, pipeline, screens, sound, storage, transcription, transcripts and transcripts-harness. In zsh, a bare `log` is a builtin, so always use the script.

Proof standards:

- Exercise the real path. The dictation harness replaces only the three boundaries a script cannot reach: the microphone (a WAV fixture), the key press (a scripted press and release) and the paste (recorded, never posted). The pipeline, the model, the overlay and the history save are the real ones.
- Open every PNG you cite and say what it shows. A blank or wrong window passes a lazy check.
- Check side effects, not only the screen. For dictation, read `results.jsonl` for the text and `latency.txt` for the signpost counts.
- The harness writes history to a scratch `-dataFolder` under `TMPDIR`. The real database at `~/Library/Application Support/com.openvocally.app.debug/openvocally.sqlite` must not change. If your change touches storage, compare its modification time before and after.
- Never log or paste transcript text from the user's own data. Fixture text is fine.

## Cleanup

```
.agents/skills/verify-openvocally/cleanup.sh
```

It waits for the lock, quits only the Debug builds of this checkout and leaves every evidence folder in place. The scripts already quit what they launch, so you need it after an interrupted run or a manual session. Never stop the app by process name. `OpenVocally` also matches the installed Release app the user may be running.

## Helpers

- `.agents/skills/verify-openvocally/doctor.sh` checks the instance. Its `--help` lists what it reads.
- `.agents/skills/verify-openvocally/cleanup.sh` quits the Debug builds.
- `scripts/with-debug-app.sh <command>` runs any command under the Debug app lock.
- `scripts/lib/window-id.swift` prints a process's window number, so `screencapture -l` captures that window even when others cover it. The screenshot scripts compile it to `.build/window-id`.
- `scripts/lib/signing-identity.sh` prints the signing identity the build scripts use.

Keep `features/` current with `/maintain-verification-skill` when a feature or script changes.
