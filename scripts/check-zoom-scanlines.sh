#!/bin/bash
# Regression check: scanlines must survive zooming in with integer scale on.
#
# The integer-scale path renders at a whole-multiple floor (so the shader has
# room to draw scanlines) and box-averages down to the display size. That
# average can flatten scanlines almost completely (a 6x -> 2x fit leaves ~4%
# of the modulation), so the zoomed composite must sample the FULL render,
# not the fit texture — while keeping letterbox geometry at the display size
# so toggling integer scale never appears to change the zoom level.
#
# This launches the app zoomed 6x with the CRT shader on (NTSC off), captures
# the window, and measures mean adjacent-row luminance delta in the preview
# center. Measured: broken build 0.8, fixed build 18.7, unzoomed 1.5 —
# threshold 6.
#
# Needs a GUI session and Screen Recording permission for `screencapture`.
# Not part of the release gate (GUI captures don't belong in one); run it
# by hand when touching PreviewView.composite() or PreviewScaling.
#
# Usage: scripts/check-zoom-scanlines.sh [source-image]
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-docs/header.webp}"
BIN=".build/release/crt-app"
[ -f "$BIN" ] || { echo "build first: swift build -c release --product crt-app"; exit 1; }
[ -f "$SRC" ] || { echo "no source image: $SRC"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; kill $APP_PID 2>/dev/null || true' EXIT

cat > "$TMP/win.swift" <<'EOF'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list {
    guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid,
          let num = w[kCGWindowNumber as String] as? Int,
          let bounds = w[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, width > 300 else { continue }
    print(num)
}
EOF

# 1200pt wide keeps the preview drawable under 6x the default 320px downscale
# on both 1x and 2x displays, so the render/display split (the code path
# under test) is actually active — verified against the app's own scale log.
CRT_SOURCE="$SRC" CRT_NTSC_OFF=1 CRT_COMPARE_OFF=1 CRT_ZOOM=6 \
  CRT_WINDOW_SIZE=1200x1100 CRT_SCALE_LOG=1 "$BIN" > "$TMP/app.log" 2>&1 &
APP_PID=$!
disown $APP_PID
sleep 9

WIN=$(swift "$TMP/win.swift" $APP_PID | head -1)
[ -n "$WIN" ] || { echo "FAIL: app window not found"; exit 1; }
screencapture -x -o -l "$WIN" "$TMP/shot.png"
kill $APP_PID 2>/dev/null || true

if ! grep -q "sampled" "$TMP/app.log"; then
    echo "FAIL: composite scale log missing — capture path changed?"; exit 1
fi
if grep -m1 "\[scale\] drawable" "$TMP/app.log" | grep -q "(x0)"; then
    echo "SKIP: render==display at this window/display combo; shrink CRT_WINDOW_SIZE"
    exit 1
fi

W=$(sips -g pixelWidth "$TMP/shot.png" | tail -1 | awk '{print $2}')
H=$(sips -g pixelHeight "$TMP/shot.png" | tail -1 | awk '{print $2}')
# Sample right of the sidebar, vertically centred — inside the zoomed preview.
sips -c 400 400 --cropOffset $((H/2-200)) $((W/2+100)) "$TMP/shot.png" \
     --out "$TMP/crop.png" >/dev/null
sips -s format bmp "$TMP/crop.png" --out "$TMP/crop.bmp" >/dev/null

python3 - "$TMP/crop.bmp" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
off = struct.unpack('<I', d[10:14])[0]
w, h = struct.unpack('<ii', d[18:26])
bpp = struct.unpack('<H', d[28:30])[0] // 8
absh = abs(h); row = (w*bpp + 3) & ~3
def lum(x, y):
    yy = (absh-1-y) if h > 0 else y
    i = off + yy*row + x*bpp
    return 0.2126*d[i+2] + 0.7152*d[i+1] + 0.0722*d[i]
total = n = 0
for x in range(w//2-60, w//2+60, 4):
    for y in range(absh//2-100, absh//2+100):
        total += abs(lum(x, y) - lum(x, y+1)); n += 1
m = total/n
print(f"row modulation: {m:.2f} (threshold 6.0)")
sys.exit(0 if m > 6.0 else 1)
EOF
STATUS=$?
[ $STATUS -eq 0 ] && echo "PASS: scanlines present under zoom" || echo "FAIL: zoomed preview has no scanline modulation"
exit $STATUS
