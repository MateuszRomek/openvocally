# Agents

OpenVocally runs coding agents through the user's own `claude` and `codex` command-line tools. Verification never needs those real tools: a fake CLI plays a fixed scenario for each provider, so a check gets the same answers on every run and touches no account.

## Sub-features

- `fake-clis` the fake `claude` and `codex` CLIs build, install and answer `--version`.
- `agents-shots` window captures of the Agents screen: the empty state, a seeded project list and Folder missing, each in light and dark, and in Increase Contrast while that system setting is on.

## How to get to it (user POV)

- In the Debug build (`FEATURE_AGENTS`), the sidebar shows Agents between Transcripts and Models. The Agents screen has two panes: the thread list, with each project as a header over its newest threads, and the selected thread's conversation. The folder button in the Threads header adds a folder as a project. A project header's "…" menu, its context menu and its VoiceOver actions have Rename…, Locate…, Show in Finder and Remove from List. A Release build has none of it: `scripts/check-unshipped-features.sh` fails when Agents code reaches the Release package build, and `scripts/release.sh` checks the app.
- The user installs `claude` or `codex` and signs in with it. Threads that run them come in a later change.

## Driving it with the scripts

Preconditions:

- Shots need Screen Recording for the terminal.

- **Build and check the fakes.** Run `make agents-shots`. It builds the `FakeAgentCLI` target in `OpenVocallyKit`, installs the fakes to `.build/agent-fakes/<scenario>/<provider>` and runs `--version` on each. Exit code 0 and the path of `.build/agents/fakes.txt`, which lists one `<scenario> <provider> <path>` line per fake. With an empty shots table it ends with a line saying no Agents UI shots exist yet.
- **Pick a scenario.** The path selects the fake: the directory is the scenario and the file name (`claude` or `codex`) is the provider. Run `"$(swift build --package-path OpenVocallyKit --show-bin-path)/FakeAgentCLI" --list` for the scenarios. That list is the source of truth; don't copy it into this file.
- **Health answers.** Each fake answers `--version` the way the real CLI does. A scenario that models a signed-out or broken tool answers the health checks that way, so the app's provider health can be checked against it.
- **Seed the Agents screen.** `-agentsScenario <name> -dataFolder <absolute path>` seeds the scratch data folder and opens the Agents screen: `empty`, `projects` (four projects, one a subfolder, one renamed, one thread waiting on a request) or `folder-missing` (`projects` with one folder deleted, its header marked Folder missing). An unknown name logs a fault and quits. Without `-dataFolder` the app logs a fault and quits, so a scenario never writes the real data. The app writes `<data folder>/agents-ready` once the window shows the seeded projects. `-debugAppearance light|dark` forces the appearance. `-sidebarCollapsed YES` or `NO` opens the main window with its sidebar hidden or shown, whatever the window last saved. Every shot passes one, and `agents-projects-collapsed` uses `YES` to check the title bar's left end. No argument can force Increase Contrast: `NSAppearance(named: .accessibilityHighContrastAqua)` returns plain Aqua, so the script takes the contrast shots only while System Settings › Accessibility › Display › Increase contrast is on, and says when it skips them.
- **Point the app at a fake.** Set the provider's binary path to the absolute path of `.build/agent-fakes/<scenario>/<provider>`. A relative path fails, because `open` starts the app in `/`. A shot row passes it as a launch argument.
- **Take the shots.** Run `make agents-shots`. The `SHOTS` table in `scripts/agents/agents-shots.sh` has one `agents-<scenario>-<appearance>` row per scenario and appearance; read it there. Each row gets a fresh scratch `-dataFolder` (the `@DATA@` placeholder). The script opens the Debug app in the background per row, waits for `agents-ready`, finds the window titled "Agents" and writes `.build/agents/<png name>.png`. Pass PNG names as arguments to take only those shots.
- **Real database check.** The script records the modification time and size of the real Debug `openvocally.sqlite`, `-wal` and `-shm` before the first launch and after the last quit, and fails when any changed. Its last line says the real database is unchanged.
- **Measure the thread list.** `scripts/agents/agents-bench.sh` seeds the `large` scenario (40 projects of 300 threads with 20 items each) off screen and prints the median and max of the list's first value and of a stored item reaching the list again. `--screen` opens the Debug app on the same scenario and times the Agents screen's creation to its first list drawn, read from `agents-ready`. It refuses to run while another checkout's Dev app is open, because all Debug builds share one bundle ID and one instance.
- **Check keyboard and VoiceOver reach.** `scripts/agents/agents-a11y.sh` opens the `projects` scenario and reads the window's accessibility tree. It fails unless every project header offers Rename to VoiceOver and has a "More for <project>" button that takes keyboard focus. The terminal needs Accessibility access.
- **Add a shot.** Add a row to `SHOTS`: `"<png name>|<window title>|<launch arguments>"`.
- **Proof.** The `fakes.txt` path, each PNG and the unchanged-database line. Open each PNG and say what it shows.

## Gotchas

- Never run a check against the real `claude` or `codex` with the maintainer's sign-in without asking the maintainer first, each time. Those runs use their account and can change their files.
- The fakes are test doubles and must not ship. `scripts/check-banned-apis.sh` fails when `project.yml`, `App/` or a library product in `OpenVocallyKit/Package.swift` names `AgentFakes` or `FakeAgentCLI`, and `scripts/release.sh` fails when the Release bundle holds a file named `claude`, `codex` or `FakeAgentCLI`.
- `swift build` has no `FakeAgentCLI` product. Build it with `--target FakeAgentCLI`.
