#!/usr/bin/env bash
# Offline verification of everything that does not need a window: the JSON
# round-trip guarantees, the path resolver, the frontmatter parser, the
# descriptor loader and the settings schema.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so a second agent can verify concurrently without replacing the
# test binary another run is executing (same note in build.sh).
export TMPDIR="${AGENTKIT_TMP:-$HERE/.cache}"
OUT="${AGENTKIT_OUT:-$HERE/out}"
mkdir -p "$TMPDIR/modules" "$TMPDIR/clang" "$OUT"

TARGET="${AGENTKIT_TARGET:-arm64-apple-macosx14.0}"

# JSONEditController is the single write path every pane shares; it only needs
# Foundation and Observation, so it is exercised here too.
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(
	find "$HERE/Sources/Core" "$HERE/Sources/Surfaces" -name '*.swift' | sort
	echo "$HERE/Sources/App/JSONEditController.swift"
	echo "$HERE/Sources/App/ProjectStore.swift"
)

swiftc -swift-version 5 -target "$TARGET" \
	-module-cache-path "$TMPDIR/modules" \
	-Xcc -fmodules-cache-path="$TMPDIR/clang" \
	-framework Foundation -framework CryptoKit -framework SwiftUI \
	-o "$OUT/agentkit-tests" \
	"${SOURCES[@]}" \
	"$HERE/Tests/main.swift"

"$OUT/agentkit-tests"
