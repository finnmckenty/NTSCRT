#!/bin/bash
# Mac references for the Glitch port (run on the Mac from the repo root):
# - the receiver's field plans (engine test fixtures), from Receiver.swift and
#   GlitchParams.swift compiled as-is with port/scripts/glitch-ref;
# - rendered fields (CI compares), adding GlitchStage.swift with
#   port/scripts/glitch-ref-render.
set -euo pipefail
tmp=$(mktemp -d)
core="Sources/CrtCore/Receiver.swift Sources/CrtCore/CompositeSignal.swift Sources/CrtCore/GlitchParams.swift Sources/CrtCore/Tape.swift Sources/CrtCore/Deck.swift Sources/CrtCore/Transport.swift Sources/CrtCore/VcrStage.swift"
# shellcheck disable=SC2086
xcrun swiftc -O -o "$tmp/glitch-ref" $core port/scripts/glitch-ref/main.swift
# shellcheck disable=SC2086
xcrun swiftc -O -o "$tmp/glitch-ref-render" $core Sources/CrtCore/GlitchStage.swift port/scripts/glitch-ref-render/main.swift
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
tape 1.0 vcr=1 head_switch=4 afc_speed=0.1 transport_flutter=0.4 tape_creases=0.8 tracking_offset=0.5
vcr 3.3 vcr=1 tape_dropouts=0.7 tape_mold=0.6 tape_vaseline=0.4 head_dirt=0.5 dirt_buildup=0.8 head_wear=0.3 head_mismatch=0.5 hum=0.5
transport 3.3 vcr=1 tape_speed=2 tape_sticky=0.6 tape_mold=0.3 back_tension=0.7 tracking_offset=-0.3 tape_edge_damage=0.5 transport_flutter=0.3 head_switch=2
slack 2.0 vcr=1 tape_speed=1 back_tension=-0.8 tape_wear=0.7 tape_scratches=0.6
search 2.0 vcr=1 search_speed=4 tape_speed=1 tape_creases=0.4
dub 1.5 vcr=1 tape_generation=3 tape_speed=1 tape_wear=0.6 head_switch=1
heads 2.7 vcr=1 tape_speed=2 head_wear=0.8 head_dirt=0.7 dirt_buildup=0.6 head_mismatch=0.4 tape_dropouts=0.6 dropout_compensation=0
sticky 2.4 vcr=1 tape_sticky=0.9 back_tension=-1 transport_flutter=0.9 tape_mold=0.4
rf 3.3 rf=1 signal_strength=0.8 hum=0.1
rf-offset 3.3 rf=1 rf_offset=0.6 rf_crawl=0.5 signal_strength=0.85
rf-lost 3.3 rf=1 rf_offset=1
CASES
ffmpeg -loglevel error -y -i TestAssets/testpattern.png -vf scale=320:240:flags=area "$renders/in.png"
while read -r name time knobs; do
  # shellcheck disable=SC2086
  "$tmp/glitch-ref-render" "$renders/in.png" "$time" "$renders/$name.png" $knobs
  echo "$time $knobs" > "$renders/$name.args"
done <<'CASES'
roll 1.3 vertical_hold=0.5 brightness=0.7
ghost 1.3 ghost_level=-0.5 ghost_delay=3 signal_strength=0.3
tape 1.3 vcr=1 head_switch=4 tape_creases=0.9 search_speed=5 tape_dropouts=0.8 dropout_compensation=0
vcr-clean 1.3 vcr=1
vcr-used 1.3 vcr=1 tape_wear=0.3 tape_dropouts=0.15 tape_scratches=0.1
vcr-ep 1.3 vcr=1 tape_speed=2 tape_wear=0.5 tape_scratches=0.7 tape_sticky=0.4 back_tension=0.5 tracking_offset=0.4
vcr-dub 1.3 vcr=1 tape_generation=2 tape_speed=1 tape_wear=0.35 tape_dropouts=0.15
vcr-search 1.3 vcr=1 search_speed=3 transport_flutter=0.5
vcr-wrecked 1.3 vcr=1 tape_speed=2 tape_generation=1 tape_wear=0.9 tape_dropouts=0.9 tape_scratches=0.8 head_wear=0.6 tape_edge_damage=0.4 transport_flutter=0.8
vcr-heads 1.3 vcr=1 head_wear=0.8 head_dirt=0.5 tape_dropouts=0.5 tape_scratches=0.9
vcr-sticky 1.3 vcr=1 tape_speed=1 tape_sticky=0.9 back_tension=-1 transport_flutter=0.7 tape_dropouts=1 dropout_compensation=0
rf-plain 1.3 rf=1
rf-typical 1.3 rf=1 signal_strength=0.82 ghost_level=0.14 ghost_delay=0.4 hum=0.04 rf_crawl=0.25 rf_color=1.75 rf_smear=0.5 rf_soft=0.2
rf-rough 1.3 rf=1 signal_strength=0.72 ghost_level=0.24 ghost_delay=0.5 hum=0.1 rf_crawl=0.55 rf_color=2.65 rf_smear=0.75 rf_soft=0.35 rf_offset=0.3
rf-knobs 1.3 rf=1 rf_crawl=1 rf_color=0.6 rf_smear=1 rf_soft=0.6 rf_offset=0.5
rf-vcr 1.3 rf=1 vcr=1 tape_wear=0.3 rf_crawl=0.4 rf_smear=0.4 ghost_level=-0.3 ghost_delay=2
CASES
rm -rf "$tmp"
echo "made $(ls $plans/*.json | wc -l) plans, $(ls $renders/*.png | wc -l) renders"
