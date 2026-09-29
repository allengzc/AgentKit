#!/usr/bin/env bash
# Regenerate the screenshots under docs/ from the demo fixture.
#
#     Tools/make-screenshots.sh
#
# Everything in the pictures comes from Tools/make-demo.py: the providers, the
# sessions, the skills and the project paths are invented, and `AGENTKIT_HOME`
# makes the app resolve `~` inside that tree, so no real configuration is read.
#
# Each image is rendered by the app itself (`AGENTKIT_DOC_STATE=snapshot:…`),
# not captured with `screencapture`. Screen capture needs permission for anything
# narrower than a whole display, and it cannot see a window that is not on the
# active Space, so it is unreliable on a machine someone is using. Asking AppKit
# to draw its own view hierarchy needs neither, and gives the same bytes every
# time. The app quits as soon as it has written the file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="${AGENTKIT_DEMO:-/tmp/agentkit-demo}"
APP="$HERE/out/AgentKit.app/Contents/MacOS/AgentKit"
SHOTS="$HERE/docs"

[[ -x "$APP" ]] || { echo "!! build first: ./build.sh" >&2; exit 1; }
command -v rsvg-convert >/dev/null || echo "(note: rsvg-convert is only needed for the icon)"

python3 "$HERE/Tools/make-demo.py" "$DEMO"
mkdir -p "$SHOTS"

# name  agent/surface  AGENTKIT_DOC_STATE
SHOTS_LIST=(
  "settings:pi/settings:"
  "models:pi/models:"
  "mcp:pi/mcp:"
  "skills:pi/skills:expand:references"
  "sessions:pi/sessions:"
  "subagents:pi/subagents:"
  "instructions:pi/instructions:preview:1"
  "diff:pi/settings:diff:1"
  "codex-settings:codex/settings:"
  "codex-mcp:codex/mcp:"
  "codex-models:codex/models:"
  "codex-sessions:codex/sessions:"
)

# The app writes to a fixed bundle id, so two instances must never overlap: a
# window belonging to a previous, still-exiting instance can be captured instead
# of the new one, and the result looks like a layout bug.
previous_window=""

shoot() {
  local name="$1" target="$2" state="$3"
  local out="$SHOTS/$name.png"

  # Every shot is taken in the same appearance, so a set of screenshots does not
  # mix light and dark depending on the time of day it was generated.
  local doc_state="appearance:light,snapshot:$out"
  [[ -n "$state" ]] && doc_state="$doc_state,$state"

  rm -f "$out"
  env AGENTKIT_HOME="$DEMO" \
      AGENTKIT_OPEN="$target" \
      AGENTKIT_DOC_STATE="$doc_state" \
      "$APP" -ApplePersistenceIgnoreState YES >/dev/null 2>&1

  if [[ ! -f "$out" ]]; then
    echo "!! $name: the app produced no snapshot"
    return 1
  fi

  # Half-size copies keep the repository small.
  sips -Z 1600 "$out" --out "$out" >/dev/null
  local width
  width="$(sips -g pixelWidth "$out" 2>/dev/null | awk '/pixelWidth/{print $2}')"
  printf '  %-20s %s  %sx%s\n' "$name.png" "$(du -h "$out" | cut -f1)" "$width" \
    "$(sips -g pixelHeight "$out" 2>/dev/null | awk '/pixelHeight/{print $2}')"
}

echo "==> capturing"
for entry in "${SHOTS_LIST[@]}"; do
  name="${entry%%:*}"
  rest="${entry#*:}"
  target="${rest%%:*}"
  state="${rest#*:}"
  [[ "$state" == "$rest" ]] && state=""
  shoot "$name" "$target" "$state" || true
done



echo "==> done: $SHOTS"
