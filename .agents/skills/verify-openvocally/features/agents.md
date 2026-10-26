# Agents

OpenVocally runs coding agents through the user's own `claude` and `codex` command-line tools. Verification never needs those real tools: a fake CLI plays a fixed scenario for each provider, so a check gets the same answers on every run and touches no account.

## Sub-features

- `fake-clis` the fake `claude` and `codex` CLIs build, install and answer `--version`.
- `agents-shots` window captures of the Agents UI, one per row of the shots table. The table is empty until the Agents UI exists.

## How to get to it (user POV)

- The user installs `claude` or `codex` and signs in with it.
- The Debug app gets a setting for each provider's binary path together with the provider health checks. Until then, no screen in the app shows the agents.

## Driving it with the scripts

Preconditions:

- None beyond the baseline. Shots also need Screen Recording, once the table has rows.

- **Build and check the fakes.** Run `make agents-shots`. It builds the `FakeAgentCLI` target in `OpenVocallyKit`, installs the fakes to `.build/agent-fakes/<scenario>/<provider>` and runs `--version` on each. Exit code 0 and the path of `.build/agents/fakes.txt`, which lists one `<scenario> <provider> <path>` line per fake. With an empty shots table it ends with a line saying no Agents UI shots exist yet.
- **Pick a scenario.** The path selects the fake: the directory is the scenario and the file name (`claude` or `codex`) is the provider. Run `"$(swift build --package-path OpenVocallyKit --show-bin-path)/FakeAgentCLI" --list` for the scenarios. That list is the source of truth; don't copy it into this file.
- **Health answers.** Each fake answers `--version` the way the real CLI does. A scenario that models a signed-out or broken tool answers the health checks that way, so the app's provider health can be checked against it.
- **Point the app at a fake.** Set the provider's binary path to the absolute path of `.build/agent-fakes/<scenario>/<provider>`. A relative path fails, because `open` starts the app in `/`. A shot row passes it as a launch argument.
- **Add a shot.** Add a row to `SHOTS` in `scripts/agents/agents-shots.sh`: `"<png name>|<window title>|<launch arguments>"`. The launch arguments open the screen and set the binary path. The script opens the Debug app in the background per row, finds the window by title and writes `.build/agents/<png name>.png`. Pass PNG names as arguments to take only those shots.
- **Proof.** The `fakes.txt` path and, for shots, each PNG. Open each PNG and say what it shows.

## Gotchas

- Never run a check against the real `claude` or `codex` with the maintainer's sign-in without asking the maintainer first, each time. Those runs use their account and can change their files.
- The fakes are test doubles and must not ship. `scripts/check-banned-apis.sh` fails when `project.yml`, `App/` or a library product in `OpenVocallyKit/Package.swift` names `AgentFakes` or `FakeAgentCLI`, and `scripts/release.sh` fails when the Release bundle holds a file named `claude`, `codex` or `FakeAgentCLI`.
- `swift build` has no `FakeAgentCLI` product. Build it with `--target FakeAgentCLI`.
