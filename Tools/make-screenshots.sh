#!/usr/bin/env bash
# Regenerate the screenshots under docs/ from the demo fixture.
#
#     Tools/make-screenshots.sh
#
# Everything in the pictures comes from Tools/make-demo.py: the providers, the
# sessions, the skills and the project paths are invented, and `AGENTKIT_HOME`
# makes the app resolve `~` inside that tree, so no real configuration is read.
#
# The window is captured with `screencapture -l`, which reads the window's own
# backing store — the app does not have to be in front, so running this does not
# take focus away from whatever else is on screen.
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
quit_app() {
  pkill -f "AgentKit.app/Contents/MacOS/AgentKit" 2>/dev/null || true
  local waited=0
  while pgrep -f "AgentKit.app/Contents/MacOS/AgentKit" >/dev/null 2>&1; do
    sleep 0.5
    waited=$((waited + 1))
    [[ $waited -gt 20 ]] && { pkill -9 -f "AgentKit.app/Contents/MacOS/AgentKit" 2>/dev/null || true; break; }
  done
}

previous_window=""

shoot() {
  local name="$1" target="$2" state="$3"
  local pid wid="" attempt

  # Every shot is taken in the same appearance, so a set of screenshots does not
  # mix light and dark depending on the time of day it was generated.
  local doc_state="appearance:light,size:1120x700"
  [[ -n "$state" ]] && doc_state="$doc_state,$state"

  quit_app

  env AGENTKIT_HOME="$DEMO" \
      AGENTKIT_PROJECT="$DEMO/projects/orchard-api" \
      AGENTKIT_OPEN="$target" \
      AGENTKIT_DOC_STATE="$doc_state" \
      "$APP" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
  pid=$!

  # The window appears once the first scan finishes, which takes a moment on a
  # cold start; poll for it rather than guessing a delay.
  local candidates=""
  for attempt in $(seq 1 40); do
    sleep 1
    kill -0 "$pid" 2>/dev/null || { echo "!! $name: the app exited"; return 1; }
    # Every window the process owns, including the menu-bar strips, the shadow
    # slivers and anything a previous instance left behind. Which of them is the
    # real one is decided below by looking at what comes out of the capture.
    candidates="$(Tools/bin/windowid -a -o AgentKit 2>/dev/null || true)"
    [[ -n "$candidates" ]] && break
  done
  [[ -n "$candidates" ]] || { echo "!! $name: no window appeared"; kill "$pid" 2>/dev/null || true; return 1; }

  sleep 3

  # Try each candidate until one captures as the main window. The frame is pinned
  # to 1120x700 points by `size:` in AGENTKIT_DOC_STATE, so anything that is not
  # roughly 2240x1400 pixels is a dialog, a menu-bar strip, or a torn surface from
  # an instance that has already exited.
  local captured=0 wid="" shot
  for attempt in $(seq 1 5); do
    for wid in $candidates; do
      [[ "$wid" == "$previous_window" ]] && continue
      shot="$SHOTS/.probe.png"
      rm -f "$shot"
      screencapture -x -o -l "$wid" "$shot" 2>/dev/null || continue
      [[ -f "$shot" ]] || continue
      local probe_w
      probe_w="$(sips -g pixelWidth "$shot" 2>/dev/null | awk '/pixelWidth/{print $2}')"
      if [[ -n "$probe_w" && "$probe_w" -ge 2000 ]]; then
        mv "$shot" "$SHOTS/$name.png"
        captured=1
        previous_window="$wid"
        break
      fi
      rm -f "$shot"
    done
    [[ $captured -eq 1 ]] && break
    sleep 2
    candidates="$(Tools/bin/windowid -a -o AgentKit 2>/dev/null || true)"
  done
  rm -f "$SHOTS/.probe.png"

  if [[ $captured -eq 0 ]]; then
    echo "!! $name: could not capture the main window"
    kill "$pid" 2>/dev/null || true
    return 1
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # Half-size copies keep the repository small; the full-size ones are only kept
  # for the icon, which needs the pixels.
  if [[ -f "$SHOTS/$name.png" ]]; then
    sips -Z 1600 "$SHOTS/$name.png" --out "$SHOTS/$name.png" >/dev/null
    printf '  %-20s %s\n' "$name.png" "$(du -h "$SHOTS/$name.png" | cut -f1)"
  fi
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

quit_app

echo "==> done: $SHOTS"
