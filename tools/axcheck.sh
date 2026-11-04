#!/bin/bash
# Live setFrame check across every pair of connected displays. See tools/axcheck/main.swift.
# The test window is invisible and never takes focus, so it is safe to run while you work.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
S="$ROOT/Sources/Snapping"
swiftc "$ROOT/tools/axcheck/main.swift" "$S/AX.swift" "$S/Geometry.swift" "$S/Model.swift" "$S/Placement.swift" \
    -o "$OUT/axcheck" -framework AppKit -framework Carbon -framework ApplicationServices
"$OUT/axcheck"
