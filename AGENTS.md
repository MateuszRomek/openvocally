# OpenVocally

OpenVocally is push-to-talk dictation for macOS. Hold a shortcut, speak and release: the app transcribes on the Mac and pastes the text into the app you are using. It is written in Swift and SwiftUI, runs on Apple Silicon with macOS 15 or newer, and is open source under GPL-3.0-only.

This file is for everyone who changes the code, people and coding agents alike. `CLAUDE.md` imports it.

## Project rules

### 1. Dictation stays on the device

Audio is recorded, transcribed and pasted on the Mac. Network access is for model downloads, app updates and features the user opts into.

- Keep secrets in the Keychain. `scripts/check-banned-apis.sh` rejects secrets in `UserDefaults`.
- Request only the entitlements a feature needs, and list them in the pull request.

### 2. It feels instant

Dictation must feel instant. [`docs/latency-budgets.md`](docs/latency-budgets.md) sets the budgets in milliseconds, as absolute targets. The core three: recording feedback within 100 ms of the press (LB-01), pasted text within 250 ms of the release for the 5 s `en-short` fixture (LB-02), and no clipped first word (LB-03). The same file budgets Home and Transcripts.

- Keep the audio and transcription path off the main actor.
- A pull request that touches that path reports before and after numbers, measured the way `docs/latency-budgets.md` describes.
- Change a budget only in a pull request that says why.

### 3. It feels like a Mac app

`docs/design.md` holds the design system: one design language for the main window, Settings, onboarding and the overlay, monochrome chrome, and light and dark as equals.

- Build UI from native macOS controls first, then the `DesignSystem` components, then its tokens. `scripts/check-design-tokens.sh` fails on a literal font, spacing, color, material or animation curve outside the `DesignSystem` module.
- A new component gets a gallery entry and a row in `docs/design.md`. The Debug build's Design Gallery renders every token in light, dark and Increase Contrast, and previews Reduce Motion.
- Load the `apple-design` and `emil-design-eng` skills before UI or animation work.

### 4. User content stays out of logs

Transcripts, audio and clipboard contents are user content. Log them only with `privacy: .private`, and never log their text. Log through `Logger`; `scripts/check-banned-apis.sh` rejects `print`, `NSLog` and `dump` in app code.

## Build and run

`CONTRIBUTING.md` lists the main `make` targets and the setup. The `Makefile` has the rest.

- Run `make check` before opening a pull request. It runs the lint checks, the tests and the build. CI runs `make check` on every pull request and on every push to `main`.
- `make run` builds and opens the Debug app.
- Run `make smoke-idle` after scene or menu changes. It fails when the idle Debug app keeps the CPU busy, which is how a SwiftUI update loop shows up.
- Read app logs with `scripts/show-logs.sh <category>`.
- Every shell script in `scripts/` prints its usage with `--help`.

## Project settings

- Change project settings in `project.yml`. `make generate` builds the Xcode project from it, and the project is not committed.
- Debug builds use the bundle ID `com.openvocally.app.debug` and the name "OpenVocally Dev". Release builds use `com.openvocally.app`. The two keep separate permissions and data. Store user data under the bundle ID so that stays true.

## Writing code

- Load the `write-swift` skill before writing Swift.
- Warnings are errors, in the app and in the package. Fix the cause.
- When a lint script fails, its message names the fix. Follow it.
- Merge unfinished features behind a `FEATURE_<NAME>` compile-time flag, defined for Debug only: in `project.yml` for app code, and with `.define("FEATURE_<NAME>", .when(configuration: .debug))` in `OpenVocallyKit/Package.swift` for package code. Wrap only the entry points in `#if`, and remove the flag when the feature ships. Release binaries then carry no dormant code.

## Writing for an open repo

- `CONTRIBUTING.md` explains how to report bugs and suggest features. Pull requests from outside contributors are not accepted for now.
- Everything committed must read well to an outside contributor. Comments state their reason in full. `scripts/check-references.sh` fails on a reference to a private tracker, such as a decision ID or an issue number.
- `docs/design.md` and `docs/latency-budgets.md` are the standing docs. Put a pull request's reasoning in its description, not in new docs.

## Proving a change works

- The `verify-openvocally` skill drives the real Debug app and captures proof: dictation from a WAV fixture, the overlay, Transcripts, onboarding, the Design Gallery and idle CPU. Use it before calling a UI or dictation change done.
- `make dictation-harness` plays a WAV fixture through the real pipeline and checks the text, LB-01 and LB-02.

## Reviews

- `/code-review` for non-trivial logic.
- `/security-review` for changes to the clipboard, Keychain, network, permissions, entitlements or subprocesses.
- `/interrogate` for decisions that are hard to undo.

## Agent skills

Skills live in `.agents/skills/`. `.claude/skills/` exposes them to Claude Code, and `skills-lock.json` records where each one came from.

### Issue tracker

Issues live in GitHub Issues for `MateuszRomek/openvocally`, managed with `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

The repo uses these triage labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human` and `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

There is no glossary file and there are no ADRs. `docs/architecture.md` holds the architecture and the decisions worth knowing. See `docs/agents/domain.md`.
