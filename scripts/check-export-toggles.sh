#!/bin/bash
# In-app check that every Export route follows the CRT on/off toggle.
#
# The exporter-level tests in the release gate (ExportShaderToggleTests)
# prove the exporters honor `shaderEnabled`. What they can't see is whether
# the app's Export buttons pass the toggle along — and that wiring is exactly
# where this bug (and the ignored Loop count before it) lived. This runs the
# app's own settings builders and export methods, the ones the buttons call,
# with the toggle on and then off for every route:
#
#   image source → PNG, video-from-still (MP4), GIF
#   video source → MP4, GIF
#
# and requires scanlines to be present with it on and gone with it off.
#
# Needs a GUI session (it launches the app), so it isn't part of the release
# gate; run it when touching ExportPopover, AppState's export builders, or
# the exporters.
#
# Usage: scripts/check-export-toggles.sh [image]
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=".build/release/crt-app"
[ -f "$BIN" ] || { echo "build first: swift build -c release --product crt-app"; exit 1; }
# Flat gray by default: a picture with lines of its own (the old default,
# docs/header.webp, at the default 320-px chunky downscale) shows row
# structure with the CRT off too and fails the on > 3 × off rule on
# routes that are fine.
IMG="${1:-TestAssets/flat-gray.png}"
[ -f "$IMG" ] || { echo "no source image: $IMG"; exit 1; }

OUT=$(mktemp -d)
APP_PID=""
trap 'rm -rf "$OUT"; [ -n "$APP_PID" ] && kill $APP_PID 2>/dev/null || true' EXIT

run() {   # source, label
    CRT_SOURCE="$1" CRT_EXPORT_TOGGLE_CHECK="$OUT/$2" "$BIN" > "$OUT/$2.log" 2>&1 &
    APP_PID=$!
    disown $APP_PID
    for _ in $(seq 1 300); do
        kill -0 $APP_PID 2>/dev/null || break
        sleep 1
    done
    kill $APP_PID 2>/dev/null || true
    APP_PID=""
    grep TOGGLECHK "$OUT/$2.log" || echo "TOGGLECHK (no result — did the app start?)"
}

echo "== image source: $IMG"
A=$(run "$IMG" image); echo "$A"
# The clip the image pass just exported doubles as the video source.
CLIP="$OUT/image/still-mp4-off.mp4"
echo "== video source"
if [ -f "$CLIP" ]; then B=$(run "$CLIP" video); echo "$B"; else B="missing clip"; echo "$B"; fi

if echo "$A" | grep -q "ALL PASS" && echo "$B" | grep -q "ALL PASS"; then
    echo "PASS: every export route follows the CRT toggle"
else
    echo "FAIL"
    exit 1
fi
