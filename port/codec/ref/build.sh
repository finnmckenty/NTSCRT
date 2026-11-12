#!/bin/bash
# Build the Mac reference CLI: ref/main.swift compiled with the Mac app's own
# Sources/CrtCodec/*.swift, untouched, optimized as the app builds them (the
# CrtCodec target is always -O). Output: ref/build/ntscrt-codec-ref.
# Nothing of the Mac app is modified.
#
# Parity check, from port/:
#   codec/ref/build.sh
#   codec/ref/build/ntscrt-codec-ref run codec/ref/cases.json codec/ref/build/mac
#   cargo run --release -p ntscrt-codec --example parity -- codec/ref/cases.json codec/ref/build/mac
# (PARITY_FRAMES=1 adds each output's mean difference.)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
mkdir -p "$here/build"
swiftc -O -module-name CrtCodecRef \
  "$repo"/Sources/CrtCodec/*.swift "$here/main.swift" \
  -framework Accelerate \
  -o "$here/build/ntscrt-codec-ref"
echo "$here/build/ntscrt-codec-ref"
