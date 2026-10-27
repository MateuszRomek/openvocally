#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: scripts/agents/agents-shots.sh [shot ...]

Builds the fake claude and codex CLIs (the FakeAgentCLI target in OpenVocallyKit) and installs
them to $TMPDIR/openvocally-agents-shots/agent-fakes/<scenario>/<claude|codex>. Runs --version on every installed fake and
fails if one fails. Writes one "<scenario> <provider> <path>" line per fake to
.build/agents/fakes.txt. Builds the broken installs the fakes cannot model under
$TMPDIR/openvocally-agents-shots/fixtures: a dangling symlink, a non-executable file, a missing path, Homebrew-looking
Caskroom and Cellar copies (stubs that run a fake, for Update available), an npm-installed copy
with a stub npm that "updates" it, a stub brew that fails, and a stub that answers --version and
hangs on the sign-in check. Both live outside the checkout because the app
disclaims responsibility for the CLIs it runs: a CLI then has no grant of its own to ~/Desktop
or ~/Documents, where a checkout often lives, and would fail to start.

Then, holding the Debug app lock, opens the Debug app in the background once per row of the SHOTS
table: Settings, scrolled to Claude Code, with both providers pointed at fixtures, in the row's
appearance (light, dark, Increase Contrast). For each row it writes .build/agents/<shot>.png and
.build/agents/<shot>.ax.txt, the window's accessibility tree, and fails when the tree lacks a
status title the row expects. The update rows pass -agentsInstallUpdate, so the app runs the stub
npm or brew itself, and notice-opened passes -agentsOpenNotice, so Settings opens from the
sidebar notice with its scroll target already set. Shots default to every row (33 launches). Posts no clicks or keys,
runs no real claude or codex and makes no network request. Needs Screen Recording for the
terminal.
HELP
  exit 0
fi

cd "$(dirname "$0")/../.."

stage="${TMPDIR:-/tmp}"
stage="${stage%/}/openvocally-agents-shots"
root="$stage/agent-fakes"
out="$PWD/.build/agents"
mkdir -p "$out"

swift build --package-path OpenVocallyKit --target FakeAgentCLI
fake_cli="$(swift build --package-path OpenVocallyKit --show-bin-path)/FakeAgentCLI"
"$fake_cli" install "$root"

: >"$out/fakes.txt"
while read -r scenario provider; do
  [[ -n "$scenario" ]] || continue
  path="$root/$scenario/$provider"
  if ! "$path" --version >/dev/null; then
    echo "agents-shots: $path failed --version" >&2
    exit 1
  fi
  echo "$scenario $provider $path" >>"$out/fakes.txt"
done < <("$fake_cli" --list)
echo "$out/fakes.txt"

# Installs the fakes cannot model. The stubs exec a fake, which reads its scenario from its own
# path, so the stub's path decides ownership (Caskroom, Cellar) while the fake decides the answers.
fixtures="$stage/fixtures"
rm -rf "$fixtures"
cask="$fixtures/brew/Caskroom/claude-code/2.1.306"
cellar="$fixtures/brew/Cellar/codex/0.164.0/bin"
mkdir -p "$fixtures/dangling" "$fixtures/not-executable" "$fixtures/hang" "$cask" "$cellar"
stub() { # <path> <fake>
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$2" >"$1"
  chmod 755 "$1"
}
stub "$cask/claude" "$root/streamed-reply/claude"
stub "$cellar/codex" "$root/streamed-reply/codex"
for provider in claude codex; do
  ln -s "$fixtures/nowhere/$provider" "$fixtures/dangling/$provider"
  printf '#!/bin/sh\necho 1.0.0\n' >"$fixtures/not-executable/$provider"
  chmod 644 "$fixtures/not-executable/$provider"
done
# Answers --version like the fake and never answers the sign-in check, so it times out.
hang() { # <path> <version line>
  printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "%s"; exit 0; fi\nexec sleep 60\n' "$2" >"$1"
  chmod 755 "$1"
}
hang "$fixtures/hang/claude" "2.1.306 (Claude Code)"
hang "$fixtures/hang/codex" "codex-cli 0.164.0-alpha.11.1"
# An npm global install. The stub npm marks it updated, and from then on it answers 9.9.9.
npm_prefix="$fixtures/npm"
npm_cli="$npm_prefix/lib/node_modules/@anthropic-ai/claude-code/cli.js"
mkdir -p "$(dirname "$npm_cli")" "$npm_prefix/bin"
printf '#!/bin/sh\nif [ "$1" = --version ] && [ -e "%s/updated" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi\nexec "%s" "$@"\n' \
  "$npm_prefix" "$root/streamed-reply/claude" >"$npm_cli"
chmod 755 "$npm_cli"
ln -s "$npm_cli" "$npm_prefix/bin/claude"
printf '#!/bin/sh\necho "changed 1 package"\ntouch "%s/updated"\n' "$npm_prefix" >"$npm_prefix/bin/npm"
chmod 755 "$npm_prefix/bin/npm"
# The Cellar copy's own brew, which fails the way a missing bottle does.
mkdir -p "$fixtures/brew/bin"
printf '#!/bin/sh\necho "==> Upgrading 1 outdated package"\necho "Error: codex: no bottle available!" >&2\nexit 1\n' \
  >"$fixtures/brew/bin/brew"
chmod 755 "$fixtures/brew/bin/brew"
"$fixtures/hang/claude" --version >/dev/null
"$npm_prefix/bin/claude" --version >/dev/null
"$cask/claude" --version >/dev/null
"$cellar/codex" --version >/dev/null

# Each pair sets both providers. The path must be absolute: open starts the app in /.
pair() { # <claude path or "off"> <codex path or "off">
  local args="-agentsSettings YES -agentsSearchOnly YES"
  local kind path
  for kind in Claude Codex; do
    if [[ "$kind" == Claude ]]; then path="$1"; else path="$2"; fi
    if [[ "$path" == off ]]; then
      args+=" -agents${kind}Enabled NO"
    else
      args+=" -agents${kind}Enabled YES -agents${kind}Path $path"
    fi
  done
  echo "$args"
}

# One row per state pair: name | status titles the .ax.txt must contain (";"-separated) |
# launch arguments. Every status shows for each provider at least once. Each row runs in three
# appearances, so the table makes 11 x 3 = 33 launches. A forced high-contrast NSAppearance draws
# the same pixels as dark, so the contrast shots use the real system setting and are skipped,
# and listed as skipped, while Increase Contrast is off.
STATES=(
  "available-update|Claude Code status, Available;Codex status, Available;Skipped a copy that doesn’t run.;Update Claude Code;Update Codex;Version, 2.1.306;Update available, 9.9.9;Updates Available|$(pair "$fixtures/dangling/claude" "$fixtures/dangling/codex") -agentsSearchDirectories $cask:$cellar -agentsLatest claude=9.9.9,codex=0.200.0"
  "update-notice|Update Available;Claude Code 9.9.9;Codex enabled, Disabled|$(pair "$cask/claude" off) -agentsLatest claude=9.9.9"
  "notice-opened|Claude Code status, Available;Version, 2.1.306;Update available, 9.9.9|$(pair "$cask/claude" off) -agentsLatest claude=9.9.9 -agentsOpenNotice YES"
  "update-done|Claude Code status, Available;Version, 9.9.9;Updated to 9.9.9. New sessions use it.|$(pair "$npm_prefix/bin/claude" off) -agentsLatest claude=9.9.9 -agentsInstallUpdate claude"
  "update-failed|Codex status, Available;Update Codex;brew exited with code 1: Error: codex: no bottle available!|$(pair off "$cellar/codex") -agentsLatest codex=0.200.0 -agentsInstallUpdate codex -agentsScrollTo codex"
  "notfound-signedout|Claude Code status, Not found;Codex status, Not authenticated;Copy codex login|$(pair "$fixtures/missing/claude" "$root/logged-out/codex")"
  "signedout-notfound|Claude Code status, Not authenticated;Codex status, Not found;Copy claude auth login|$(pair "$root/logged-out/claude" "$fixtures/missing/codex")"
  "needs-attention|Claude Code status, Needs attention;Codex status, Needs attention|$(pair "$fixtures/not-executable/claude" "$fixtures/not-executable/codex")"
  "unsupported|Claude Code status, Unsupported version;Codex status, Unsupported version|$(pair "$root/below-minimum-version/claude" "$root/below-minimum-version/codex")"
  "unconfirmed|Claude Code status, Couldn’t confirm sign-in;Codex status, Couldn’t confirm sign-in|$(pair "$fixtures/hang/claude" "$fixtures/hang/codex")"
  "disabled|Claude Code enabled, Disabled;Codex enabled, Disabled|$(pair off off)"
)
APPEARANCES=("light|aqua" "dark|darkAqua" "contrast|darkAqua")

# One row per screenshot: PNG name | expected titles | launch arguments.
SHOTS=()
for state in "${STATES[@]}"; do
  IFS='|' read -r base expected args <<<"$state"
  for appearance in "${APPEARANCES[@]}"; do
    IFS='|' read -r suffix name <<<"$appearance"
    SHOTS+=("$base-$suffix|$expected|$args -agentsAppearance $name")
  done
done

if [[ "${DEBUG_APP_LOCK_HELD:-}" != 1 ]]; then
  exec scripts/with-debug-app.sh scripts/agents/agents-shots.sh "$@"
fi

selected=("$@")
app="$PWD/.build/DerivedData/Build/Products/Debug/OpenVocally Dev.app"
executable="$app/Contents/MacOS/OpenVocally"
window_id="$PWD/.build/window-id"
swiftc -O scripts/lib/window-id.swift -o "$window_id"
ax_dump="$PWD/.build/ax-dump"
swiftc -O scripts/lib/ax-dump.swift -o "$ax_dump"

running() {
  ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid }'
}

quit_app() {
  for pid in $(running); do
    kill "$pid"
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
  done
}

# Launch Services can still list the quit copy for a moment and refuse the open with -600.
# -ApplePersistenceIgnoreState: windows saved by a hand-run session would open instead of the shot.
open_shot() {
  for _ in $(seq 1 10); do
    open -g "$app" --args "$@" -ApplePersistenceIgnoreState YES 2>/dev/null && return 0
    sleep 0.5
  done
  open -g "$app" --args "$@" -ApplePersistenceIgnoreState YES
}

# The app prohibits a second instance per bundle ID, so while another checkout's Dev app runs,
# open starts nothing here and every shot would time out.
other="$(ps -axo comm= | grep "/OpenVocally Dev.app/Contents/MacOS/OpenVocally$" | grep -vxF "$executable" | head -n 1 || true)"
if [[ -n "$other" ]]; then
  echo "agents-shots: quit the other Dev app first: $other" >&2
  exit 2
fi

contrast_on=0
[[ "$(defaults read com.apple.universalaccess increaseContrast 2>/dev/null)" == 1 ]] && contrast_on=1

failed=0
first=1
skipped=()
for row in "${SHOTS[@]}"; do
  IFS='|' read -r name expected args <<<"$row"
  if ((${#selected[@]})) && [[ " ${selected[*]} " != *" $name "* ]]; then
    continue
  fi
  if [[ "$name" == *-contrast ]] && ((!contrast_on)); then
    skipped+=("$name")
    continue
  fi
  ax="$out/$name.ax.txt"
  ready="$out/$name.ready"
  rm -f "$ax" "$ready" "$out/$name.png" "$npm_prefix/updated"
  heading="Claude Code"
  [[ "$args" == *"-agentsScrollTo codex"* ]] && heading="Codex"
  read -r -a launch <<<"$args -agentsReadyFile $ready"
  if ((first)); then
    RUN_DEBUG_BACKGROUND=1 scripts/run-debug.sh "${launch[@]}" -ApplePersistenceIgnoreState YES
    first=0
  else
    quit_app
    open_shot "${launch[@]}"
  fi
  # The app writes the tree once both providers settle; the hang stub takes the 5 s timeout.
  status=1
  for _ in $(seq 1 80); do
    sleep 0.5
    [[ -e "$ready" ]] || continue
    pid="$(running | head -n 1)"
    [[ -n "$pid" ]] || continue
    if window="$("$window_id" "$pid")"; then status=0; break; fi
  done
  if ((status == 0)) && ! "$ax_dump" "$pid" Settings "$heading" "$ax"; then
    echo "agents-shots: could not read the accessibility tree for $name" >&2
    failed=1
  fi
  if ((status != 0)); then
    echo "agents-shots: no settled Settings window for $name" >&2
    quit_app
    exit 1
  fi
  screencapture -x -o -l "$window" "$out/$name.png"
  echo "$out/$name.png"
  IFS=';' read -r -a titles <<<"$expected"
  for title in "${titles[@]}"; do
    if ! grep -qF -- "$title" "$ax"; then
      echo "agents-shots: $ax lacks \"$title\"" >&2
      failed=1
    fi
  done
done
quit_app
if ((${#skipped[@]})); then
  echo "agents-shots: skipped ${skipped[*]}: turn on Increase Contrast in System Settings > Accessibility > Display and run them again" >&2
fi
exit "$failed"
