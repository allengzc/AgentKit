#!/usr/bin/env bash
# Build AgentKit: a SwiftUI app that configures and manages local coding agents.
#
# No Xcode project and no build system — plain swiftc plus a hand-assembled
# bundle, so the whole thing is reproducible from a terminal and reviewable in
# a diff. Same shape as the other tools in this directory.
#
# AgentKit is deliberately NOT sandboxed: it must read and write ~/.pi,
# ~/.config, ~/.agents and project directories, and it launches Terminal on
# request. Sandboxing would break every one of those.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out"
APP="$OUT/AgentKit.app"
RES="$HERE/Resources"
SRC="$HERE/Sources"

# The DSH sandbox can deny the shared clang module cache; keep every cache local.
export TMPDIR="$HERE/.cache"
mkdir -p "$TMPDIR/modules" "$TMPDIR/clang"
CACHE_FLAGS=(
	-module-cache-path "$TMPDIR/modules"
	-Xcc "-fmodules-cache-path=$TMPDIR/clang"
)

TARGET="${AGENTKIT_TARGET:-arm64-apple-macosx14.0}"

echo "==> building tool helpers"
mkdir -p "$HERE/Tools/bin"
for tool in iconpath windowid; do
	swiftc -swift-version 5 -target "$TARGET" \
		"${CACHE_FLAGS[@]}" \
		-framework SwiftUI -framework CoreGraphics \
		-o "$HERE/Tools/bin/$tool" "$HERE/Tools/$tool.swift"
done

echo "==> cleaning"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Agents"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$SRC" -name '*.swift' | sort)
if [[ ${#SOURCES[@]} -eq 0 ]]; then
	echo "!! no Swift sources found under $SRC" >&2
	exit 1
fi
echo "==> compiling ${#SOURCES[@]} Swift file(s) for $TARGET"

swiftc -O -swift-version 5 -target "$TARGET" \
	"${CACHE_FLAGS[@]}" \
	-parse-as-library \
	-framework Cocoa -framework SwiftUI -framework AppKit \
	-framework CoreServices -framework CryptoKit \
	-o "$APP/Contents/MacOS/AgentKit" \
	"${SOURCES[@]}"

echo "==> assembling bundle"
cp "$RES/App-Info.plist" "$APP/Contents/Info.plist"
if [[ ! -f "$RES/AppIcon.icns" ]]; then
	echo "!! $RES/AppIcon.icns is missing; run Tools/make-icon.py" >&2
	exit 1
fi
cp "$RES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$RES/Agents/"*.json "$APP/Contents/Resources/Agents/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The descriptors are the app's data model; a bundle without them shows nothing.
DESCRIPTORS=$(find "$APP/Contents/Resources/Agents" -name '*.json' | wc -l | tr -d ' ')
if [[ "$DESCRIPTORS" -eq 0 ]]; then
	echo "!! no agent descriptors were bundled" >&2
	exit 1
fi
echo "    bundled $DESCRIPTORS agent descriptor(s)"

IDENTITY="${AGENTKIT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
	echo "!! no code signing identity found; set AGENTKIT_SIGN_IDENTITY" >&2
	exit 1
fi
echo "==> signing with: $IDENTITY"

codesign --force --sign "$IDENTITY" --timestamp=none "$APP" || true

echo "==> verifying"
codesign --verify --deep --strict "$APP" && echo "    signature ok"
# `codesign -d` piped into plutil used to make a successful build look failed
# under `pipefail`; the `|| true` keeps the diagnostic from being fatal.
codesign -d --entitlements - "$APP" 2>&1 | head -n 2 || true

echo "==> built: $APP"
