#!/usr/bin/env bash
# PostToolUse hook on Skill. Records that agent mode was entered in this session.
set -u
input=$(cat)
skill=$(printf '%s' "$input" | jq -r '.tool_input.skill // empty')
session=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ "$skill" = "agent-mode" ] && [ -n "$session" ] || exit 0
marker_dir="${TMPDIR:-/tmp}/claude-agent-mode"
mkdir -p "$marker_dir" && : > "$marker_dir/$session"
