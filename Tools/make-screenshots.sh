#!/usr/bin/env bash
# Regenerate the screenshots under docs/ from the demo fixture.
#
#     Tools/make-screenshots.sh            # everything
#     Tools/make-screenshots.sh skills mcp # just these
#
# Everything in the pictures comes from Tools/make-demo.py: the providers, the
# sessions, the skills and the project paths are invented, and `AGENTKIT_HOME`
# makes the app resolve `~` inside that tree, so no real configuration is read.
#
# Capture is `screencapture -l` on the app's window, which reads the window's own
# backing store. Two false starts are worth recording:
#
#   * Rendering the view hierarchy from inside the app (`CALayer.render(in:)`)
#     looked appealing — no Screen Recording permission, no need for the window
#     to be in front — but it silently drops the sidebar, which is drawn through
#     an NSVisualEffectView the window server composites. The result was a very
#     convincing screenshot with an empty left column.
#   * `windowid -o` lists windows belonging to instances that have already quit,
#     so a previous run's dying window can be captured instead of the new one.
#     Instances are therefore serialised, and only on-screen windows are used.
#
# Requires the display to be awake: while it is asleep every window capture
# fails and a full-screen capture returns a stale blank frame.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="${AGENTKIT_DEMO:-/tmp/agentkit-demo}"
APP="$HERE/out/AgentKit.app/Contents/MacOS/AgentKit"
SHOTS="$HERE/docs"

[[ -x "$APP" ]] || { echo "!! build first: ./build.sh" >&2; exit 1; }

python3 "$HERE/Tools/make-demo.py" "$DEMO"
mkdir -p "$SHOTS"

# name  agent/surface  extra AGENTKIT_DOC_STATE
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
  "claude-settings:claude/settings:"
  "claude-mcp:claude/mcp:"
  "claude-sessions:claude/sessions:"
)

quit_app() {
  # `-x` on the process name, not `-f` on the command line: the swiftc invocation
  # in build.sh also contains the path to the binary, so a `-f` match killed the
  # compiler whenever a build overlapped a screenshot run.
  pkill -x AgentKit 2>/dev/null || true
  local waited=0
  while pgrep -x AgentKit >/dev/null 2>&1; do
    sleep 0.5
    waited=$((waited + 1))
    if [[ $waited -gt 20 ]]; then
      pkill -9 -x AgentKit 2>/dev/null || true
      break
    fi
  done
}

# The sidebar is the part a bad capture loses first, so it is what the acceptance
# check looks at: a blank left column compresses to almost nothing.
sidebar_bytes() {
  sips -c 420 230 --cropOffset 150 12 "$1" --out /tmp/.sidebar-probe.png >/dev/null 2>&1 || true
  stat -f%z /tmp/.sidebar-probe.png 2>/dev/null || echo 0
}

shoot() {
  local name="$1" target="$2" state="$3"
  local out="$SHOTS/$name.png"
  local doc_state="appearance:light"
  [[ -n "$state" ]] && doc_state="$doc_state,$state"

  local attempt wid pid bytes
  for attempt in 1 2 3; do
    quit_app
    rm -f "$out"
    env AGENTKIT_HOME="$DEMO" \
        AGENTKIT_OPEN="$target" \
        AGENTKIT_DOC_STATE="$doc_state" \
        "$APP" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
    pid=$!

    wid=""
    for _ in $(seq 1 30); do
      sleep 1
      kill -0 "$pid" 2>/dev/null || break
      wid="$(Tools/bin/windowid AgentKit 2>/dev/null || true)"
      [[ -n "$wid" ]] && break
    done

    if [[ -n "$wid" ]]; then
      sleep 3
      screencapture -x -o -l "$wid" "$out" 2>/dev/null || true
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    if [[ -f "$out" ]] && [[ "$(sidebar_bytes "$out")" -gt 6000 ]]; then
      sips -Z 1600 "$out" --out "$out" >/dev/null
      bytes="$(du -h "$out" | cut -f1)"
      printf '  %-20s %-6s %sx%s\n' "$name.png" "$bytes" \
        "$(sips -g pixelWidth "$out" 2>/dev/null | awk '/pixelWidth/{print $2}')" \
        "$(sips -g pixelHeight "$out" 2>/dev/null | awk '/pixelHeight/{print $2}')"
      return 0
    fi
    echo "  $name: attempt $attempt produced no usable window, retrying"
    sleep 2
  done

  echo "!! $name: gave up"
  rm -f "$out"
  return 1
}

echo "==> capturing"
failures=0
for entry in "${SHOTS_LIST[@]}"; do
  name="${entry%%:*}"
  rest="${entry#*:}"
  target="${rest%%:*}"
  state="${rest#*:}"
  [[ "$state" == "$rest" ]] && state=""

  if [[ $# -gt 0 ]]; then
    wanted=0
    for only in "$@"; do [[ "$only" == "$name" ]] && wanted=1; done
    [[ $wanted -eq 0 ]] && continue
  fi

  shoot "$name" "$target" "$state" || failures=$((failures + 1))
done
quit_app

echo "==> done: $SHOTS"
[[ $failures -eq 0 ]] || { echo "!! $failures shot(s) failed" >&2; exit 1; }
