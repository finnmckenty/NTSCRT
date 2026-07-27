#!/usr/bin/env bash
# Run the unit tests.
#
#   ./scripts/test.sh [extra swift test args]
#
# XCTest ships with full Xcode, not the Command Line Tools, so this points
# DEVELOPER_DIR at Xcode for the duration rather than requiring
# `sudo xcode-select -s`. Everything else in this repo builds fine with the
# CLT, so the switch is deliberately scoped to testing.
#
# Separate scratch path on purpose: the Xcode toolchain and the CLT one
# produce incompatible build databases, and sharing .build makes every switch
# a full rebuild.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    echo "tests need full Xcode (XCTest isn't in the Command Line Tools)." >&2
    echo "install Xcode, or set DEVELOPER_DIR to it." >&2
    exit 1
  fi
fi

exec swift test --scratch-path .build-tests "$@"
