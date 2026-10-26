# Agents

OpenVocally runs coding agents through the user's own `claude` and `codex` command-line tools. Verification never needs those real tools: a fake CLI plays a fixed scenario for each provider, so a check gets the same answers on every run and touches no account.

## Sub-features

- `fake-clis` the fake `claude` and `codex` CLIs build, install and answer `--version`.
- `agents-shots` captures of Settings → Claude Code and Codex in every provider status, each in light, dark and Increase Contrast, with an accessibility tree per capture.

## How to get to it (user POV)

- The user installs `claude` or `codex` and signs in with it.
- Debug builds only (`FEATURE_AGENTS`): Settings, after History, has a Claude Code and a Codex section. Each has an Enabled switch (off by default), the status, the sign-in or install command with a copy button, Update available with an Update button and a result line (only for an install whose updater the app can run; others show advice), the location (how it was installed, with Choose…, Use Detected, Show in Finder and Copy Path in a ⋯ menu, and Choose… in view while no copy runs), one quiet line for skipped copies with each note in its help tag and VoiceOver value, the version and the launch arguments.

## Driving it with the scripts

Preconditions:

- None beyond the baseline. Shots also need Screen Recording for the terminal.

- **Build and check the fakes.** Run `make agents-shots`. It builds the `FakeAgentCLI` target in `OpenVocallyKit`, installs the fakes to `$TMPDIR/openvocally-agents-shots/agent-fakes/<scenario>/<provider>` and runs `--version` on each. Exit code 0 and the path of `.build/agents/fakes.txt`, which lists one `<scenario> <provider> <path>` line per fake, then the shots below.
- **Pick a scenario.** The path selects the fake: the directory is the scenario and the file name (`claude` or `codex`) is the provider. Run `"$(swift build --package-path OpenVocallyKit --show-bin-path)/FakeAgentCLI" --list` for the scenarios. That list is the source of truth; don't copy it into this file.
- **Health answers.** Each fake answers `--version` the way the real CLI does. A scenario that models a signed-out or broken tool answers the health checks that way, so the app's provider health can be checked against it.
- **Point the app at a fake.** Pass `-agentsClaudeEnabled YES -agentsClaudePath <abs path>` (and `-agentsCodexEnabled`, `-agentsCodexPath`). These are the saved settings' own keys, so the launch argument overrides them without writing the user's defaults. A relative path is ignored, because `open` starts the app in `/`.
- **Debug launch arguments** (`App/Sources/Debug/AgentsHarness.swift`):
  - `-agentsSettings YES` opens Settings in a window as tall as the screen, scrolls to `-agentsScrollTo claude|codex` (default `claude`) and skips the hotkeys and the dictation pipeline. The service then keeps its settings and update cache in a scratch defaults domain seeded only from the launch-argument domain, never from the user's persistent Dev defaults.
  - `-agentsSearchOnly YES` tries only the chosen path, then each `<dir>/<claude|codex>` in `-agentsSearchDirectories /a:/b`. No login shell and no known locations, so a CLI installed on the Mac never runs.
  - `-agentsLatest claude=9.9.9,codex=0.200.0` answers the latest-version check with no network.
  - `-agentsAppearance aqua|darkAqua` sets the app's appearance. Increase Contrast cannot be forced: a high-contrast `NSAppearance` draws the same pixels as dark (measured, 0 of 1,032,960 pixels differ).
  - `-agentsOpenNotice YES` starts on Home and, as soon as the first check finds an update, opens the sidebar's update notice the way a click does: Settings opens with its scroll target already set, so the shot proves the first scroll lands on the provider. It replaces `-agentsScrollTo`.
  - `-agentsInstallUpdate claude|codex` runs that provider's update once both settle, as the Update button does, so a shot shows the result with no click.
  - `-agentsReadyFile <abs file>` creates the file once both providers settle and any update has finished. The script then runs `scripts/lib/ax-dump.swift`, which checks that the section heading is in the tree and writes the window's accessibility tree as an outside client, the way VoiceOver reads it, one `role | label | value` line per element. It needs the Accessibility permission for the terminal that runs the script.
- **Shots.** Run `make agents-shots`. Besides the fakes it builds `$TMPDIR/openvocally-agents-shots/fixtures`, outside the checkout, because a CLI the app runs has no grant of its own to `~/Desktop` or `~/Documents`: a dangling symlink, a non-executable file, a missing path, `brew/Caskroom/claude-code/<v>/claude` and `brew/Cellar/codex/<v>/bin/codex` stubs that run the signed-in fake (Homebrew ownership, so `-agentsLatest` shows Update available), an npm install (`npm/lib/node_modules/@anthropic-ai/claude-code/cli.js`) whose stub `npm/bin/npm` makes it answer 9.9.9, a `brew/bin/brew` stub that fails, and a stub that answers `--version` and hangs on the sign-in check. `STATES` in the script has 11 rows, each setting both providers; each row runs in light, dark and Increase Contrast, so a full run makes 33 launches. `update-notice` shows the sidebar's agent update notice (the shot is the whole window, sidebar included), `notice-opened` the Settings the notice opens, scrolled to Claude Code, `update-done` a finished npm update and `update-failed` a failed brew update. The contrast shots need Increase Contrast turned on in System Settings > Accessibility > Display; while it is off the script skips them and names them on stderr, so a run without it never counts as contrast proof. Every status shows for each provider at least once: Available with Update available and a skipped-copy note, Not found, Not authenticated, Needs attention, Unsupported version, Couldn't confirm sign-in and Disabled. Each shot writes `.build/agents/<state>-<light|dark|contrast>.png` and `.ax.txt`, and the script fails when an `.ax.txt` lacks a status title its row expects. Pass shot names to take only those.
- **Proof.** The `fakes.txt` path, each PNG and its `.ax.txt`. Open each PNG and say what it shows.

## Gotchas

- Never run a check against the real `claude` or `codex` with the maintainer's sign-in without asking the maintainer first, each time. Those runs use their account and can change their files.
- The fakes are test doubles and must not ship. `scripts/check-banned-apis.sh` fails when `project.yml`, `App/` or a library product in `OpenVocallyKit/Package.swift` names `AgentFakes` or `FakeAgentCLI`, and `scripts/release.sh` fails when the Release bundle holds a file named `claude`, `codex` or `FakeAgentCLI`.
- `swift build` has no `FakeAgentCLI` product. Build it with `--target FakeAgentCLI`.
