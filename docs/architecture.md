# Architecture

This page explains how OpenVocally is put together: the modules, the path one dictation takes, what runs where, and where data lives. Read it before your first change. The design system is in [design.md](design.md), and the latency targets are in [latency-budgets.md](latency-budgets.md).

## Two layers

The code is split into a Swift package and a thin app target.

- `OpenVocallyKit/` is a Swift package with one library per area. The package builds and tests with `make test`, without the generated Xcode project. `make test` first runs `make whisper` to build the whisper framework, then `swift test`.
- `App/` is the macOS app target. It composes the modules, owns the windows, menus and settings, and holds the screens.
- `project.yml` describes the Xcode project. `make generate` creates `OpenVocally.xcodeproj` from it.

### Package modules

| Module | What it does |
| --- | --- |
| `DictationCore` | The shared types and the dictation state machine, `DictationMachine`. It has no dependencies. |
| `Hotkeys` | The keyboard event tap, shortcut bindings, chords, one-key holds and double taps. |
| `AudioCapture` | Opens the selected microphone, records 16 kHz mono audio, follows device changes, and publishes levels for the overlay. |
| `Models` | The model catalog, pinned manifests and the downloader. |
| `Transcription` | Installs and loads models, and runs the Parakeet, Whisper and Apple speech engines. |
| `Paste` | Writes the transcript to the clipboard, posts Command-V, and restores the clipboard. |
| `Dictation` | `DictationPipeline`, which connects the state machine to capture, transcription, paste and storage. |
| `Overlay` | The recording indicator, shown as a notch or a floating island. |
| `SoundCues` | The start, cancel and error sounds. |
| `Storage` | The SQLite database (GRDB) for transcripts, sessions and shortcuts, and the recording archive. |
| `Reporting` | The statistics and charts data for Home. |
| `Diagnostics` | The diagnostics file for bug reports, with logs that leave out user content. |
| `DesignSystem` | Tokens and components shared by every screen. |

### App target

`App/Sources` has one folder per area. `App/` holds `AppModel`, the composition root that starts the modules in order and shuts them down in order. `Home`, `Transcripts`, `Models`, `Settings` and `Onboarding` hold the screens. `Debug/` holds the Design Gallery and the harnesses that drive the app in tests, and builds only in Debug.

## One dictation, start to finish

1. **Press.** The `Hotkeys` event tap sees the shortcut and sends a timestamped command into the pipeline.
2. **Record.** `AudioCapture` starts recording at the press and streams levels to the overlay.
3. **Transcribe early.** While you speak, `TranscriptionRuntime` transcribes the audio so far at each pause. Parakeet transcribes the whole recording. Whisper transcribes it in pieces of 10 to 15 seconds.
4. **Release.** Capture stops and returns the samples. The runtime trims the trailing quiet and reuses each early result whose input has not changed, so it only decodes what is new.
5. **Paste.** `Paster` saves the clipboard, writes the text, posts Command-V into the frontmost app and restores the clipboard. If no text field has focus, the text stays on the clipboard for 10 seconds so you can paste it yourself.
6. **Save.** `Storage` saves the transcript and the session, and Home and Transcripts update.

## The state machine decides, the pipeline acts

`DictationMachine` in `DictationCore` is a value type. Its `handle(_:)` method takes an event, such as a key press or a finished transcription, and returns effects, such as "start capture" or "paste". It does no work itself, so tests drive it with plain values.

Each completion carries a session ID. A completion for an old session, or for a stage the session has already left, changes nothing. That one rule settles races between the user's commands and slow work, such as a cancel that arrives while a transcription runs.

`DictationPipeline` owns the only copy of the machine. Hotkey events and completions enter one inbox, and one loop drains it. The loop never waits on a service. It turns each effect into a job on a queue, and the job sends its result back through the inbox. Capture jobs run in order, transcription jobs run in order, and recording and save jobs run in order on their own queue, so disk writes never delay a transcription.

## What runs off the main actor

Dictation must feel instant, so nothing on the audio and transcription path waits for the main actor.

| Work | Where it runs |
| --- | --- |
| Keyboard event tap | A dedicated thread owned by `Hotkeys` |
| Pipeline loop and its job queues | A detached task (`DictationPipeline.run()` is `@concurrent`) |
| Recording | `AudioCapture`, behind a watchdog that replaces a recorder whose call hangs |
| Model loading and transcription | The `TranscriptionRuntime` actor |
| Clipboard and paste | The `Paster` actor |
| Recording files | The `RecordingArchive` actor |
| Sound cues | The `CueOutput` actor in `SoundCues`, on its own serial queue |
| Database | A GRDB `DatabasePool` in WAL mode |

The main actor runs SwiftUI, `AppModel`, the overlay and the settings. It reads pipeline state from the `updates` stream and never blocks the pipeline. The overlay window never becomes the key window, so it cannot take focus from the app that receives the paste.

## Speech models

Five models ship in the catalog (`OpenVocallyKit/Sources/Models/ModelCatalog.swift`):

- Parakeet v3 and Parakeet Ultra run on Core ML through FluidAudio.
- Whisper Turbo runs on whisper.cpp with Metal. `make whisper` builds whisper.cpp from a pinned commit with one patch from `scripts/whisper`.
- Apple Dictation and Apple Speech run through SpeechAnalyzer on macOS 26 or newer. macOS installs their files, one set per language.

`ModelID.provider` is the one switch from a model to where it comes from: `.hosted(HostedModel)` for the three models OpenVocally downloads, `.system(SystemModel)` for the two that macOS installs. Every other fact about a model, such as its engine, its install path and how it loads, derives from that value. A new model or engine fails the build at each switch that must handle it.

The app downloads no hosted model until the user picks one. `ModelDownloader` fetches each file from Hugging Face at a pinned revision into a hidden folder, checks its size and SHA-256 against `ModelManifests.swift`, and then moves the model into place. `scripts/models/pin-manifests.py` generates the manifests. `ModelFolder` is the only reader of a manifest, so tests swap in small ones by building a folder with them.

`Provisioner` (`OpenVocallyKit/Sources/Transcription/Provisioner.swift`) checks, installs and removes both kinds. A system model needs a language before it can be checked or loaded. `ResolvedModel` holds a model together with that language, and it is what the runtime loads, so a system model without a language cannot reach the loader.

`ModelLibrary` owns what the Models screen shows. It keeps one entry per model in `ModelStates`, and each entry runs at most one piece of work at a time: a check, an install or a removal. An entry's result is written only with the token its work was given, so a slow check cannot overwrite an install that finished after it started. Views read `state(of:)` and never ask which kind of model they show. After every change the library works out what the runtime should hold and applies it from one task, in order.

`TranscriptionRuntime` loads the active model at launch and after a model change. It unloads the model after 20 idle minutes and loads it again at the next dictation. The dictation harness loads a model through `Provisioner.prepare` and the runtime alone, so it never starts `ModelLibrary` or changes the stored active model.

## Storage

All data lives under `~/Library/Application Support/<bundle ID>`. Debug and Release builds have different bundle IDs, so they never share data.

- `openvocally.sqlite` is the database. Migrations are named, ordered and append-only. A shipped migration is never edited. A new one comes with a committed snapshot (`scripts/storage/record-snapshot.sh`) that the tests check.
- `recordings/` holds the audio of a dictation while it transcribes. The audio of a failed dictation stays in `recordings/failed` for 7 days.
- `local-models/` holds the downloaded models.

Preferences, such as the overlay style and the sound volume, live in `UserDefaults`. Secrets would go in the Keychain. The app stores none today.

## Updates

Every build links Sparkle, but only a build whose `Info.plist` names a feed creates an updater (`App/Sources/App/Updates.swift`). Release builds made by `scripts/release.sh` set the feed. The script sets the feed URL and the EdDSA public key in `Info.plist`, signs and notarizes the app, adds the update to `appcast.xml`, and creates the GitHub release. Installed apps read `appcast.xml` from `main`.

A build without a feed URL has no updater. That covers every build from source. A scheduled check never opens a window, because a window that takes focus during dictation would receive the paste. The app shows a found update in its menu instead.

## Rules the build enforces

`make lint` runs scripts that turn project rules into errors. Each failure message names the fix.

- `scripts/check-banned-apis.sh` rejects `print`, `fatalError`, secrets in `UserDefaults`, and concurrency escape hatches without a stated reason.
- `scripts/check-design-tokens.sh` rejects literal fonts, spacing, colors and animation curves outside `DesignSystem`.
- `scripts/check-public-api.py` rejects a `public` symbol that no other module uses.
- `scripts/check-references.sh` rejects comments that cite a private tracker.
- `scripts/attributions/generate.py --check` keeps the third-party credits in the README, the About panel and the license files in sync with `scripts/attributions/components.json`.
