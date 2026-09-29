#!/usr/bin/env bash
# Offline verification of everything that does not need a window: the JSON
# round-trip guarantees, the path resolver, the frontmatter parser, the
# descriptor loader and the settings schema.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TMPDIR="$HERE/.cache"
mkdir -p "$HERE/.cache/modules" "$HERE/.cache/clang" "$HERE/out"

TARGET="${AGENTKIT_TARGET:-arm64-apple-macosx14.0}"

# JSONEditController is the single write path every pane shares; it only needs
# Foundation and Observation, so it is exercised here too.
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(
	find "$HERE/Sources/Core" "$HERE/Sources/Surfaces" -name '*.swift' | sort
	echo "$HERE/Sources/App/JSONEditController.swift"
)

swiftc -swift-version 5 -target "$TARGET" \
	-module-cache-path "$HERE/.cache/modules" \
	-Xcc -fmodules-cache-path="$HERE/.cache/clang" \
	-framework Foundation -framework CryptoKit \
	-o "$HERE/out/agentkit-tests" \
	"${SOURCES[@]}" \
	"$HERE/Tests/main.swift"

"$HERE/out/agentkit-tests"
