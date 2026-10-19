# Contributing to OpenVocally

Thank you for your interest in OpenVocally. You can help by reporting bugs, suggesting features and pointing out unclear or wrong documentation, all through [GitHub Issues](https://github.com/MateuszRomek/openvocally/issues). Search the existing issues first, and add to an open issue rather than opening a new one.

Questions are welcome as issues too.

To report a security problem, follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Pull requests are not accepted for now

OpenVocally does not accept pull requests from outside contributors for now. A pull request opened against this repository is closed without review. You are welcome to fork the project and change it under the terms of its [license](LICENSE). The build instructions and code rules below also help when you build or change your own copy.

## Report a bug

Open an issue with the bug report template. A good report includes:

- What you did, step by step.
- What you expected, and what happened instead.
- Your macOS version, your Mac's chip, the OpenVocally version, and the speech model you use. **Settings > Support > Version** shows the version and build.

To attach logs, use **Settings > Support > Diagnostics > Export**. The file holds your settings and recent app logs. Transcripts, audio and device names stay out of it.

Do not paste dictated text, recordings or clipboard contents that you would not publish. Describe the problem instead.

## Suggest a feature

Open an issue with the feature request template. Describe the task you are trying to do and what gets in your way today. A problem statement is more useful than a finished design.

## Build from source

You need:

- An Apple Silicon Mac with macOS 15 or newer
- Xcode 27 or newer
- XcodeGen (`brew install xcodegen`)
- The Xcode Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)

Run these commands from the repo root:

| Command | What it does |
| --- | --- |
| `make generate` | Builds the patched whisper.cpp framework if needed and generates `OpenVocally.xcodeproj`. Run it after you pull or add a file to `App/`. |
| `make test` | Runs the package tests. |
| `make build` | Builds a Debug app into `.build/DerivedData`. |
| `make run` | Builds and opens the Debug app. |
| `make check` | Runs the lint checks, the tests and the build. CI runs the same target. |
| `make install` | Builds a signed Release app, installs it in `/Applications` and opens it. |

To work in Xcode, run `make generate` and open `OpenVocally.xcodeproj`. The project file is generated from `project.yml` and is not committed. Change project settings in `project.yml`, because `make generate` overwrites changes made in Xcode.

Debug builds use the bundle ID `com.openvocally.app.debug` and the name "OpenVocally Dev". Release builds use `com.openvocally.app`. The two keep separate permissions, preferences and data, so a Debug build never touches your real history.

### Keep permissions across installs

Run `scripts/setup-signing.sh` once before your first `make install`. It creates a self-signed code signing identity in your login keychain. With it, macOS keeps the Microphone and Accessibility permissions across rebuilds. Without it, the app is signed ad hoc, macOS treats each install as a new app, and `make install` prints the `tccutil reset` commands that clear the stale permissions.

Builds from source have no updater. Only release builds check for updates.

### Read the logs

`scripts/show-logs.sh <category>` prints the app's log for one category, such as `pipeline`, `paste` or `updates`.

## Follow the code rules

Every change to OpenVocally follows these rules. `make check` enforces most of them.

- `make check` passes. Warnings are errors in both the app and the package. Fix the cause instead of silencing the warning. When a lint script fails, its message names the fix.
- Project settings change in `project.yml`, never in the generated Xcode project.
- UI uses native macOS controls first, then the `DesignSystem` components and tokens described in [docs/design.md](docs/design.md). A new component gets an entry in the Design Gallery (`App/Sources/Debug/DesignGallery.swift`) and a row in `docs/design.md`.
- An unfinished feature lands behind a `FEATURE_<NAME>` compile-time flag that is defined for Debug only. App code adds the flag to the Debug `SWIFT_ACTIVE_COMPILATION_CONDITIONS` in `project.yml`. Package code uses `.define("FEATURE_<NAME>", .when(configuration: .debug))` in `OpenVocallyKit/Package.swift`. Wrap only the entry points in `#if`, and remove the flag when the feature ships. Release binaries then carry no dormant code.
- User content stays out of logs. Log transcripts, audio and clipboard contents only with `privacy: .private`, and never log their text.
- Secrets go in the Keychain.
- A new entitlement or permission is listed in the change description, with the reason the feature needs it.
- A change to the audio or transcription path keeps that work off the main actor, and reports latency before and after, measured as [docs/latency-budgets.md](docs/latency-budgets.md) describes.
- After a change to a scene or a menu, `make smoke-idle` passes. It opens the Debug app and fails when the app is busy while idle.
- Comments stand on their own. Do not cite issue numbers or private notes in code comments.

## Work with a coding agent

Instructions for coding agents live in [AGENTS.md](AGENTS.md). The rules there are the same rules as above, with more detail.
