#!/usr/bin/env bash
# Build AgentKit and install it into /Applications.
#
# Only the app bundle is copied. Nothing in ~/.pi, ~/.config or ~/.agents is
# touched: AgentKit writes to a config file only when you press 保存 and confirm
# the diff.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/out/AgentKit.app"
TARGET="/Applications/AgentKit.app"

"$HERE/build.sh"

if [[ ! -d "$APP" ]]; then
	echo "!! build did not produce $APP" >&2
	exit 1
fi

echo "==> installing to $TARGET"
# Quit a running copy first: replacing the bundle under a live process makes
# macOS keep showing the old one.
if pgrep -f "$TARGET/Contents/MacOS/AgentKit" >/dev/null 2>&1; then
	echo "    quitting the running copy"
	osascript -e 'tell application "AgentKit" to quit' >/dev/null 2>&1 || true
	pkill -f "$TARGET/Contents/MacOS/AgentKit" >/dev/null 2>&1 || true
	sleep 1
fi

rm -rf "$TARGET"
cp -R "$APP" "$TARGET"

# The quarantine bit is not set on a locally built bundle, but a copy from a
# download would be; clearing it keeps Gatekeeper from blocking first launch.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

echo "==> verifying"
codesign --verify --deep --strict "$TARGET" && echo "    signature ok"

# Seed the user descriptor directory with a README so the extensibility story is
# discoverable without reading the source.
USER_DIR="${AGENTKIT_CONFIG_DIR:-$HOME/.config/agentkit}/agents"
mkdir -p "$USER_DIR"
if [[ ! -f "$USER_DIR/README.md" ]]; then
	cat > "$USER_DIR/README.md" <<'EOF'
# AgentKit 描述文件目录

放一份 JSON 描述文件在这里，AgentKit 就会多出一个 agent。

- 文件名随意，以 .json 结尾即可。
- `id` 与内置描述文件相同的，会**整体覆盖**内置的那一份（侧边栏会标「自定义描述」）。
- 想加一个新 agent 又不确定怎么写，就复制 `/Applications/AgentKit.app/Contents/Resources/Agents/pi.json` 改。
- 写坏了不会导致 App 崩溃：侧边栏会给出解析失败的原因，其它 agent 照常可用。
EOF
	echo "    seeded $USER_DIR/README.md"
fi
echo "    user descriptors: $USER_DIR"

cat <<EOF

==> 完成

  打开:        open -a AgentKit
  直接进某个面板: AGENTKIT_OPEN=pi/settings open -a AgentKit
  换一个配置根:  PI_CODING_AGENT_DIR=/path/to/agent open -a AgentKit
  日志:        log show --last 5m --info --predicate 'subsystem == "com.allengzc.agentkit"'

EOF
