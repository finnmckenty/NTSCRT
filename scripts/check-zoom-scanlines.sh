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
# Measures the drawable's own pixels via CRT_COMPOSITE_DUMP — never
# `screencapture`, which returns a 1x image of a 2x window and halves the
# scanline detail it's supposed to measure. Metric: mean adjacent-row
# luminance delta at the dump center. Measured at this config: fixed build
# ~7-9, v0.10.0 behavior ~2.7 — threshold 4.5.
#
# Needs a GUI session. Not part of the release gate (GUI launches don't
# belong in one); run it by hand when touching PreviewView.composite() or
# PreviewScaling.
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

# 1200pt wide keeps the preview drawable under 6x the default 320px downscale
# on both 1x and 2x displays, so the render/display split (the code path
# under test) is actually active — verified against the app's own scale log.
CRT_SOURCE="$SRC" CRT_NTSC_OFF=1 CRT_COMPARE_OFF=1 CRT_ZOOM=6 \
  CRT_WINDOW_SIZE=1200x1100 CRT_SCALE_LOG=1 \
  CRT_COMPOSITE_DUMP="$TMP/dump.png" "$BIN" > "$TMP/app.log" 2>&1 &
APP_PID=$!
disown $APP_PID

for _ in $(seq 1 30); do
  [ -f "$TMP/dump.png" ] && break
  sleep 1
done
kill $APP_PID 2>/dev/null || true
[ -f "$TMP/dump.png" ] || { echo "FAIL: no composite dump appeared"; exit 1; }

if grep -m1 "\[scale\] drawable" "$TMP/app.log" | grep -vq "needs-fit\|(x"; then
    : # log format changed; fall through, the metric still decides
fi
if ! grep -m1 "render" "$TMP/app.log" >/dev/null; then
    echo "FAIL: scale log missing — CRT_SCALE_LOG path changed?"; exit 1
fi
RENDER=$(grep -m1 "\[scale\] drawable" "$TMP/app.log" | sed -E 's/.*render ([0-9]+x[0-9]+).*/\1/')
DISPLAY_SZ=$(grep -m1 "\[scale\] drawable" "$TMP/app.log" | sed -E 's/.*display ([0-9]+x[0-9]+).*/\1/')
if [ "$RENDER" = "$DISPLAY_SZ" ]; then
    echo "SKIP: render==display ($RENDER) at this window/display combo; shrink CRT_WINDOW_SIZE"
    exit 1
fi

sips -s format bmp "$TMP/dump.png" --out "$TMP/dump.bmp" >/dev/null

python3 - "$TMP/dump.bmp" <<'EOF'
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
for x in range(w//2-80, w//2+80, 4):
    for y in range(absh//2-200, absh//2+200):
        total += abs(lum(x, y) - lum(x, y+1)); n += 1
m = total/n
print(f"row modulation: {m:.2f} (threshold 4.5)")
sys.exit(0 if m > 4.5 else 1)
EOF
STATUS=$?
[ $STATUS -eq 0 ] && echo "PASS: scanlines present under zoom" || echo "FAIL: zoomed preview has no scanline modulation"
exit $STATUS
