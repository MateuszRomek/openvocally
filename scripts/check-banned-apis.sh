#!/bin/sh
set -eu

if [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
Usage: scripts/check-banned-apis.sh

Fails on banned APIs in app code: print, NSLog, dump, fatalError, unowned and secrets in
UserDefaults. Fails on a concurrency escape hatch (@preconcurrency, nonisolated(unsafe),
@unchecked Sendable) unless the line ends with "// allowed: <reason>". Fails on a shell
script that resets permissions or matches processes by name unless the line ends with
"# allowed: <reason>". Fails on MenuBarExtra(isInserted:) bound to a projected value.
Fails on composedMessage, and on OSLogStore or import OSLog outside
OpenVocallyKit/Sources/Diagnostics/LogArchive.swift. Fails when a target other than FakeAgentCLI,
AgentFakesTestSupport, AgentFakesTests and AgentsTests depends on AgentFakes in
OpenVocallyKit/Package.swift. Fails when a file in OpenVocallyKit/Sources/Agents other than
Subprocess.swift starts a process, or one other than LoginEnvironment.swift passes "-c".
Fails when a file in OpenVocallyKit/Sources/Agents does not open with #if FEATURE_AGENTS, so a
Release build compiles the module empty.
EOF
  exit 0
fi
pattern='(^|[^A-Za-z_.])(print|debugPrint|NSLog|dump)\(|fatalError\(|\bunowned\b|UserDefaults\.standard\.set\([^)]*(token|key|secret|password)'
if grep -rnE "$pattern" --include='*.swift' App/Sources OpenVocallyKit/Sources; then
  echo "Banned API in app code. Use Logger with privacy annotations, typed errors and the Keychain instead." >&2
  exit 1
fi

escape_hatch='@preconcurrency|nonisolated\(unsafe\)|@unchecked[[:space:]]+Sendable'
status=0
for hit in $(grep -rnE "$escape_hatch" --include='*.swift' App/Sources OpenVocallyKit/Sources OpenVocallyKit/Tests | cut -d: -f1,2); do
  line=$(sed -n "${hit#*:}p" "${hit%%:*}")
  if ! printf '%s\n' "$line" | grep -qE '// allowed: [^ ]'; then
    echo "$hit: $line" >&2
    status=1
  fi
done
if [ "$status" -ne 0 ]; then
  echo "Concurrency escape hatch without a reason. Fix the isolation instead, or end the line with // allowed: <why the isolation is safe>." >&2
  exit 1
fi

shared_state='(^|[^A-Za-z_-])(tccutil[[:space:]]+reset|pkill|pgrep[^|;&]*[[:space:]]-[A-Za-z]*f)'
status=0
for file in $(git ls-files --cached --others --exclude-standard -- '*.sh' | grep -vxE 'scripts/(check-banned-apis|lint-scripts)\.sh'); do
  for n in $(grep -nE "$shared_state" "$file" | cut -d: -f1); do
    line=$(sed -n "${n}p" "$file")
    if ! printf '%s\n' "$line" | grep -qE '# allowed: [^ ]'; then
      echo "$file:$n: $line" >&2
      status=1
    fi
  done
done
if [ "$status" -ne 0 ]; then
  echo "Script resets permissions or matches processes by name or pattern. These hit every app with the same bundle ID or name. Match the exact executable path instead, or end the line with # allowed: <why it is safe>." >&2
  exit 1
fi

if find App/Sources OpenVocallyKit/Sources -name '*.swift' -exec perl -0ne 'print "$ARGV\n" if /isInserted:\s*\$/' {} + | grep .; then
  echo "MenuBarExtra(isInserted:) bound to a projected value. SwiftUI writes the same value back on every update and rebuilds the main menu in a loop at 100% CPU. Pass a Binding that writes only when the value changes, as App/Sources/App/OpenVocallyApp.swift does." >&2
  exit 1
fi

if grep -rn 'composedMessage' --include='*.swift' App/Sources OpenVocallyKit/Sources OpenVocallyKit/Tests; then
  echo "composedMessage reveals default-private log values in process. Rebuild the line with LogRedactor.redact." >&2
  exit 1
fi

if grep -rnE 'OSLogStore|^[[:space:]]*import[[:space:]]+OSLog\b' --include='*.swift' App/Sources OpenVocallyKit/Sources OpenVocallyKit/Tests \
  | grep -v '^OpenVocallyKit/Sources/Diagnostics/LogArchive\.swift:'; then
  echo "Read logs only through Diagnostics/LogArchive.swift, which redacts each entry as it reads it." >&2
  exit 1
fi

# Splits the targets array at its top-level commas, so a dependency list that spans several lines,
# or names AgentFakes as .target(name:) or .product(name:), still belongs to its target. A target's
# first name: is its own.
if ! python3 -I - OpenVocallyKit/Package.swift <<'PY'
import re, sys
text = re.sub(r"(?m)^\s*//.*$", "", open(sys.argv[1]).read())
blocks, current, depth, quoted = [], "", 0, False
for ch in text[re.search(r"(?m)^\s*targets:\s*\[", text).end():]:
    if ch == '"':
        quoted = not quoted
    elif not quoted and ch in "([":
        depth += 1
    elif not quoted and ch in ")]":
        if depth == 0:
            break
        depth -= 1
    elif not quoted and ch == "," and depth == 0:
        blocks.append(current)
        current = ""
        continue
    current += ch
blocks.append(current)
allowed = {"AgentFakes", "FakeAgentCLI", "AgentFakesTestSupport", "AgentFakesTests", "AgentsTests"}
found = False
for block in blocks:
    name = re.search(r'name:\s*"([^"]+)"', block)
    if name and name.group(1) not in allowed and '"AgentFakes"' in block[name.end():]:
        print(f"OpenVocallyKit/Package.swift: target {name.group(1)} depends on AgentFakes")
        found = True
sys.exit(1 if found else 0)
PY
then
  echo "AgentFakes is a test double. Only FakeAgentCLI, AgentFakesTestSupport, AgentFakesTests and AgentsTests may depend on it in OpenVocallyKit/Package.swift." >&2
  exit 1
fi

if grep -nE '\.library\(.*(AgentFakes|FakeAgentCLI)' OpenVocallyKit/Package.swift \
  || grep -rnE 'AgentFakes|FakeAgentCLI' project.yml App/; then
  echo "AgentFakes and FakeAgentCLI are test doubles. Remove them from library products in OpenVocallyKit/Package.swift, from project.yml and from App/. The app selects a fake only through a provider's binary path." >&2
  exit 1
fi

agents=OpenVocallyKit/Sources/Agents
if grep -rnE 'posix_spawn|Process\(|\bexecv|\bsystem\(|popen\(' --include='*.swift' "$agents" \
  | grep -v "^$agents/Subprocess\.swift:"; then
  echo "Only $agents/Subprocess.swift may start a process. Call Subprocess.run, which never uses a shell, gives the child its own process group and kills it on timeout." >&2
  exit 1
fi

if grep -rn '"-c"' --include='*.swift' "$agents" | grep -v "^$agents/LoginEnvironment\.swift:"; then
  echo "Only $agents/LoginEnvironment.swift may pass \"-c\" to a shell, with its constant command. Pass the executable and an argument array to Subprocess.run instead; launch arguments come from LaunchArguments.split()." >&2
  exit 1
fi

# Comments and blank lines may surround it; the first code line opens the flag, the last closes
# it, and no column-0 #else or #elseif gives Release a branch.
unflagged=$(find "$agents" -name '*.swift' -exec awk '
  function check() { if (file != "" && (first !~ /^#if FEATURE_AGENTS[[:space:]]*$/ || last !~ /^#endif[[:space:]]*$/ || branch)) print file }
  FNR == 1 { check(); file = FILENAME; first = ""; last = ""; branch = 0 }
  /^[[:space:]]*$/ || /^[[:space:]]*\/\// { next }
  { if (first == "") first = $0; last = $0 }
  /^#(else|elseif)/ { branch = 1 }
  END { check() }
' {} +)
if [ -n "$unflagged" ]; then
  printf '%s\n' "$unflagged" >&2
  echo "Every file in $agents must start with #if FEATURE_AGENTS and end with #endif, with no top-level #else, so Release builds carry no Agents code. Wrap the whole file in the flag; only comments may come before it." >&2
  exit 1
fi
