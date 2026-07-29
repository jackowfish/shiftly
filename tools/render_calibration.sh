#!/bin/bash
# Renders the calibration screens to PNGs. See render-calibration/main.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/calibration-shots}"
BIN="$(mktemp -d)/render"

# main.swift and AppDelegate.swift are excluded: one owns top-level code that
# would clash with the tool's own, the other pulls in the whole menu bar app.
SOURCES=$(find "$ROOT/Sources" -name '*.swift' \
    ! -name 'main.swift' ! -name 'AppDelegate.swift' | sort)

# shellcheck disable=SC2086
swiftc -O $SOURCES "$ROOT/tools/render-calibration/main.swift" -o "$BIN"
"$BIN" "$OUT"
