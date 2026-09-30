#!/usr/bin/env bash
# Run the Skills-pane benchmark (Tools/bench-skills.swift) against this tree.
#
#     Tools/bench-skills.sh          # 50 / 200 / 500 skill fixtures
#     Tools/bench-skills.sh real     # plus the roots pi.json declares on this machine
#
# Offline, no window, no network: same source set as run-tests.sh (Core +
# Surfaces + the two App files that only need Foundation), plus the benchmark's
# own main. Its output is what the `perf(views)` commit message quotes, so it is
# meant to be re-run rather than trusted.
#
# Kept out of `out/` by default: `build.sh` starts with `rm -rf out/`, and a
# benchmark is exactly the thing you want to run while a build is in flight.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${AGENTKIT_BENCH_OUT:-$REPO/.cache/bench}"
export TMPDIR="${AGENTKIT_TMP:-$REPO/.cache}"
mkdir -p "$TMPDIR/modules" "$TMPDIR/clang" "$OUT"

TARGET="${AGENTKIT_TARGET:-arm64-apple-macosx14.0}"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(
	find "$REPO/Sources/Core" "$REPO/Sources/Surfaces" -name '*.swift' | sort
	echo "$REPO/Sources/App/JSONEditController.swift"
	echo "$REPO/Sources/App/ProjectStore.swift"
)

swiftc -O -swift-version 5 -target "$TARGET" \
	-parse-as-library \
	-module-cache-path "$TMPDIR/modules" \
	-Xcc "-fmodules-cache-path=$TMPDIR/clang" \
	-framework Foundation -framework CryptoKit -framework SwiftUI \
	-o "$OUT/bench-skills" \
	"${SOURCES[@]}" \
	"$HERE/bench-skills.swift"

"$OUT/bench-skills" "$@"
