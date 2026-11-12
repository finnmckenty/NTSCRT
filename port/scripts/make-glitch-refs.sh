#!/bin/bash
# Mac references for the Glitch port (run on the Mac from the repo root):
# - the receiver's field plans (engine test fixtures), from Receiver.swift and
#   GlitchParams.swift compiled as-is with port/scripts/glitch-ref;
# - rendered fields (CI compares), adding GlitchStage.swift with
#   port/scripts/glitch-ref-render.
set -euo pipefail
tmp=$(mktemp -d)
xcrun swiftc -O -o "$tmp/glitch-ref" Sources/CrtCore/Receiver.swift Sources/CrtCore/GlitchParams.swift port/scripts/glitch-ref/main.swift
xcrun swiftc -O -o "$tmp/glitch-ref-render" Sources/CrtCore/Receiver.swift Sources/CrtCore/GlitchParams.swift Sources/CrtCore/GlitchStage.swift port/scripts/glitch-ref-render/main.swift
plans=port/engine/tests/fixtures/glitch
renders=port/spike/ref-mac/glitch
while read -r name time knobs; do
  # shellcheck disable=SC2086
  "$tmp/glitch-ref" 320 240 "$time" $knobs > "$plans/$name.json"
  echo "$time $knobs" > "$plans/$name.args"
done <<'CASES'
healthy 1.0
vhold 3.3 vertical_hold=0.6
hhold 1.0 horizontal_hold=0.7
weak 3.3 signal_strength=0.12
tape 1.0 head_switch=4 afc_speed=0.1 timebase_jitter=1 crinkle=0.8 tracking=0.5
dropouts 3.3 dropouts=0.7 dropout_compensation=0 hum=0.5
CASES
ffmpeg -loglevel error -y -i TestAssets/testpattern.png -vf scale=320:240:flags=area "$renders/in.png"
while read -r name time knobs; do
  # shellcheck disable=SC2086
  "$tmp/glitch-ref-render" "$renders/in.png" "$time" "$renders/$name.png" $knobs
  echo "$time $knobs" > "$renders/$name.args"
done <<'CASES'
roll 1.3 vertical_hold=0.5 brightness=0.7
ghost 1.3 ghost_level=-0.5 ghost_delay=3 signal_strength=0.3
tape 1.3 head_switch=4 crinkle=0.9 search_speed=5 dropouts=0.8 dropout_compensation=0
CASES
rm -rf "$tmp"
echo "made $(ls $plans/*.json | wc -l) plans, $(ls $renders/*.png | wc -l) renders"
