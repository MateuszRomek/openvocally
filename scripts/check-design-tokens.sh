#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: scripts/check-design-tokens.sh [path ...]

Fails when UI code outside the DesignSystem module writes a font, spacing, padding,
corner radius, system color, material, Liquid Glass, animation curve, switch or button
style as a literal
instead of a design token (docs/design.md). Scans App/Sources and OpenVocallyKit/Sources
by default. A line ending in // allowed: <reason> is allowed.
HELP
  exit 0
fi

cd "$(dirname "$0")/.."

# One rule per line: pattern, a planted line the pattern must catch, the fix. Tab-separated.
# read -d '' rather than $(cat <<...): bash 3.2 mis-parses unbalanced parens in a heredoc inside $( ).
rules=''
IFS= read -r -d '' rules <<'RULES' || true
\.font\(	.font(.system(size: 12))	Use .textStyle(_:) with a TextStyle.
spacing: *[1-9]	VStack(spacing: 8)	Use Space, for example spacing: Space.s.points.
\.padding\([^)]*[0-9]	.padding(.horizontal, 14)	Use .padding(Space) or an OverlayMetrics value.
cornerRadius: *[0-9]	RoundedRectangle(cornerRadius: 12)	Use Radius, for example Radius.card.shape.
(^|[^A-Za-z])Color\.(red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|black|white)([^A-Za-z]|$)	.background(Color.blue)	Use .token(SemanticColor).
[(,] *\.(red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|black|white)([^A-Za-z]|$)	.foregroundStyle(.green)	Use .token(SemanticColor).
(ultraThin|thin|regular|thick|ultraThick)Material	.background(.thinMaterial)	Use .surface(.card, in:).
\.glassEffect\(	.glassEffect(.regular, in: .capsule)	Use .surface(.control, in:), and only on controls.
(duration|response|dampingFraction|bounce|blendDuration): *[0-9]	.animation(.smooth(duration: 0.18), value: x)	Use a Motion token.
(withAnimation|\.animation)\( *\.[a-z]	withAnimation(.spring) { x = 1 }	Use a Motion token.
(^|[^A-Za-z])Animation\.[a-z]	let a = Animation.easeOut	Use a Motion token.
toggleStyle\(\.switch\)	Toggle("On", isOn: $on).toggleStyle(.switch)	Use .switchStyle(), which tints the switch green.
\.buttonStyle\( *\.(bordered|borderedProminent|borderless|plain|link|glass|glassProminent)([^A-Za-z]|$)	Button("Go") {}.buttonStyle(.borderedProminent)	Use .appButton(_:size:) with a ButtonVariant and ControlScale.
RULES
rules="${rules%$'\n'}"

status=0
while IFS=$'\t' read -r pattern planted message; do
  if ! printf '%s\n' "$planted" | grep -qE "$pattern"; then
    echo "check-design-tokens: the rule for '$message' no longer catches: $planted" >&2
    status=1
  fi
done <<<"$rules"
((status == 0)) || exit 1

roots=("$@")
((${#roots[@]})) || roots=(App/Sources OpenVocallyKit/Sources)

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(find "${roots[@]}" -name '*.swift' -not -path 'OpenVocallyKit/Sources/DesignSystem/*' | sort)
((${#files[@]})) || exit 0

while IFS=$'\t' read -r pattern planted message; do
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    line="${hit#*:*:}"
    if [[ "$line" =~ //\ allowed:\ [^[:space:]] ]]; then
      continue
    fi
    echo "$hit" >&2
    echo "  $message" >&2
    status=1
  done < <(grep -nHE "$pattern" "${files[@]}" || true)
done <<<"$rules"

if ((status != 0)); then
  echo "UI literal outside the design tokens. Use the token named above (docs/design.md), add one to OpenVocallyKit/Sources/DesignSystem, or end the line with // allowed: <reason>." >&2
fi
exit "$status"
