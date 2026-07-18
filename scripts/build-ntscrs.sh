#!/usr/bin/env bash
# Build the ntscrs-capi dylib (C ABI over the ntsc-rs core library) and place
# it where the app looks for it (Vendor/ntscrs-capi/ntscrs_capi.dylib).
# Requires the Rust toolchain and the Vendor/ntsc-rs submodule.

set -euo pipefail
cd "$(dirname "$0")/../Vendor/ntscrs-capi"

if [[ ! -f ../ntsc-rs/crates/ntscrs/Cargo.toml ]]; then
  echo "Vendor/ntsc-rs submodule missing — run: git submodule update --init --recursive" >&2
  exit 1
fi

cargo build --release
install_name_tool -id @rpath/ntscrs_capi.dylib target/release/libntscrs_capi.dylib
cp target/release/libntscrs_capi.dylib ntscrs_capi.dylib
echo "built: Vendor/ntscrs-capi/ntscrs_capi.dylib"
